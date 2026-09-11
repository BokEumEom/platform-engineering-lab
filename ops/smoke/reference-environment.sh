#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$(cd "${ROOT_DIR}/../infrastructure-engineering-harness" 2>/dev/null && pwd || true)}"
PROM_GATEWAY_URL="${PROM_GATEWAY_URL:-http://127.0.0.1:8080}"
PROM_HOST="${PROM_HOST:-prometheus.lab.local}"
HTTPS_GATEWAY_IP="${HTTPS_GATEWAY_IP:-127.0.0.1}"
HTTPS_GATEWAY_PORT="${HTTPS_GATEWAY_PORT:-8443}"
PROM_POLL_SECONDS="${PROM_POLL_SECONDS:-15}"
PROM_MAX_POLLS="${PROM_MAX_POLLS:-10}"
OUT_DIR="${OUT_DIR:-${ROOT_DIR}/.ops-smoke/$(date -u +%Y%m%dT%H%M%SZ)}"
PYTHON_BIN=""

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

resolve_python() {
  if command -v python3 >/dev/null 2>&1; then command -v python3; return; fi
  if command -v python >/dev/null 2>&1; then command -v python; return; fi
  fail "python3 or python is required"
}

https_status() {
  local host="$1"
  curl -k -sS -o /dev/null -w '%{http_code}' \
    --resolve "${host}:${HTTPS_GATEWAY_PORT}:${HTTPS_GATEWAY_IP}" \
    "https://${host}:${HTTPS_GATEWAY_PORT}/" || true
}

prom_query() {
  local query="$1"
  curl -fsS -G \
    -H "Host: ${PROM_HOST}" \
    --data-urlencode "query=${query}" \
    "${PROM_GATEWAY_URL}/api/v1/query"
}

assert_argo_app() {
  local app="$1" sync health
  sync="$(kubectl get application "${app}" -n argocd -o jsonpath='{.status.sync.status}')"
  health="$(kubectl get application "${app}" -n argocd -o jsonpath='{.status.health.status}')"
  printf '  %-24s sync=%-10s health=%s\n' "${app}" "${sync}" "${health}"
  [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]] \
    || fail "Argo CD application ${app} is not Synced/Healthy"
}

assert_namespace_gateway_access() {
  local ns="$1" value
  value="$(kubectl get namespace "${ns}" -o jsonpath='{.metadata.labels.gateway-access}' 2>/dev/null || true)"
  printf '  %-24s gateway-access=%s\n' "${ns}" "${value:-<missing>}"
  [[ "${value}" == "true" ]] || fail "namespace ${ns} is not allowed to attach routes to platform-gateway"
}

assert_route() {
  local ns="$1" route="$2"
  local accepted resolved
  accepted="$(kubectl get httproute "${route}" -n "${ns}" -o jsonpath='{range .status.parents[*].conditions[?(@.type=="Accepted")]}{.status}{end}' 2>/dev/null || true)"
  resolved="$(kubectl get httproute "${route}" -n "${ns}" -o jsonpath='{range .status.parents[*].conditions[?(@.type=="ResolvedRefs")]}{.status}{end}' 2>/dev/null || true)"
  printf '  %-24s/%-20s Accepted=%-5s ResolvedRefs=%s\n' "${ns}" "${route}" "${accepted:-?}" "${resolved:-?}"
  [[ "${accepted}" == "True" && "${resolved}" == "True" ]] \
    || fail "HTTPRoute ${ns}/${route} is not Accepted/ResolvedRefs"
}

count_platform_services() {
  "${PYTHON_BIN}" -c '
import json,sys
p=json.load(sys.stdin)
services={r.get("metric",{}).get("platform_service") for r in p.get("data",{}).get("result",[])}
services.discard(None)
print(len(services))
'
}

print_platform_services() {
  "${PYTHON_BIN}" -c '
import json,sys
p=json.load(sys.stdin)
services=sorted({r.get("metric",{}).get("platform_service") for r in p.get("data",{}).get("result",[]) if r.get("metric",{}).get("platform_service")})
print(", ".join(services))
'
}

main() {
  for cmd in kubectl curl; do require_cmd "${cmd}"; done
  PYTHON_BIN="$(resolve_python)"
  mkdir -p "${OUT_DIR}"

  log "Kubernetes context"
  kubectl config current-context

  log "Argo CD applications"
  for app in platform demo-app observability-config; do assert_argo_app "${app}"; done

  log "Gateway namespace admission"
  for ns in platform-system demo-app monitoring; do assert_namespace_gateway_access "${ns}"; done

  log "Gateway and HTTPRoutes"
  programmed="$(kubectl get gateway platform-gateway -n platform-system -o jsonpath='{range .status.conditions[?(@.type=="Programmed")]}{.status}{end}' 2>/dev/null || true)"
  printf '  platform-gateway Programmed=%s\n' "${programmed:-?}"
  [[ "${programmed}" == "True" ]] || fail "platform-gateway is not Programmed"
  assert_route demo-app web
  assert_route monitoring grafana
  assert_route monitoring prometheus
  assert_route platform-system argocd

  log "Six-service rollout state"
  for d in web catalog orders inventory payments recommendations; do
    kubectl rollout status "deployment/${d}" -n demo-app --timeout=30s
  done

  log "Gateway endpoints"
  for host in web.lab.local grafana.lab.local prometheus.lab.local argocd.lab.local; do
    code="$(https_status "${host}")"
    printf '  %-28s HTTP %s\n' "${host}" "${code}"
    if [[ "${host}" == "web.lab.local" ]]; then
      [[ "${code}" == "200" ]] || fail "application Gateway response is HTTP ${code}"
    else
      [[ "${code}" =~ ^[23][0-9][0-9]$ ]] || fail "unexpected Gateway response for ${host}: HTTP ${code}"
    fi
  done

  log "Prometheus API through MetalLB/Envoy"
  curl -fsS -H "Host: ${PROM_HOST}" "${PROM_GATEWAY_URL}/-/ready" | tee "${OUT_DIR}/prometheus-ready.txt"

  log "Generating application traffic through real HTTPS path"
  ok=0
  for _ in $(seq 1 30); do
    code="$(https_status web.lab.local)"
    [[ "${code}" == "200" ]] && ok=$((ok + 1))
    sleep 0.1
  done
  printf '  successful requests: %s/30\n' "${ok}"
  [[ "${ok}" == "30" ]] || fail "application Gateway traffic is not fully healthy"

  log "Waiting for six-service Prometheus recording rules"
  ready=0
  for attempt in $(seq 1 "${PROM_MAX_POLLS}"); do
    raw="$(prom_query 'http_requests_total{namespace="demo-app"}')"
    err="$(prom_query 'platform:http_error_ratio:5m')"
    p95="$(prom_query 'platform:http_p95_latency_seconds:5m')"
    printf '%s\n' "${raw}" >"${OUT_DIR}/raw-http-requests.json"
    printf '%s\n' "${err}" >"${OUT_DIR}/error-ratio-5m.json"
    printf '%s\n' "${p95}" >"${OUT_DIR}/p95-latency-5m.json"

    raw_count="$(printf '%s' "${raw}" | count_platform_services)"
    err_count="$(printf '%s' "${err}" | count_platform_services)"
    p95_count="$(printf '%s' "${p95}" | count_platform_services)"
    printf '  poll %s/%s: raw=%s error_ratio=%s p95=%s services\n' \
      "${attempt}" "${PROM_MAX_POLLS}" "${raw_count}" "${err_count}" "${p95_count}"

    if [[ "${raw_count}" -ge 6 && "${err_count}" -ge 6 && "${p95_count}" -ge 6 ]]; then
      printf '  raw services:   %s\n' "$(printf '%s' "${raw}" | print_platform_services)"
      printf '  error services: %s\n' "$(printf '%s' "${err}" | print_platform_services)"
      printf '  p95 services:   %s\n' "$(printf '%s' "${p95}" | print_platform_services)"
      ready=1
      break
    fi
    [[ "${attempt}" == "${PROM_MAX_POLLS}" ]] || sleep "${PROM_POLL_SECONDS}"
  done
  [[ "${ready}" == "1" ]] || fail "Prometheus does not expose complete six-service raw/error/P95 evidence; inspect ${OUT_DIR}"

  if [[ -n "${HARNESS_DIR}" && -x "${HARNESS_DIR}/agent" ]]; then
    log "Harness read-only baseline"
    "${HARNESS_DIR}/agent" k8s-evidence \
      --namespace demo-app \
      --output "${OUT_DIR}/k8s.json"
    "${HARNESS_DIR}/agent" prometheus-evidence \
      --url "${PROM_GATEWAY_URL}" \
      --host-header "${PROM_HOST}" \
      --query-file "${ROOT_DIR}/observability/agent-prometheus-queries.json" \
      --namespace demo-app \
      --service platform-api \
      --output "${OUT_DIR}/prometheus.json"
    review_rc=0
    "${HARNESS_DIR}/agent" ops-review \
      --k8s "${OUT_DIR}/k8s.json" \
      --prometheus "${OUT_DIR}/prometheus.json" \
      --output "${OUT_DIR}/review.json" || review_rc=$?
    "${PYTHON_BIN}" - "${OUT_DIR}/review.json" <<'PY'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
print(f"  state={r.get('state')} release_guidance={r.get('release_guidance')}")
print(f"  topology={r.get('topology')}")
print(f"  missing_required={r.get('evidence',{}).get('missing_required',[])}")
for f in r.get('findings',[]):
    print(f"  {f.get('severity')} {f.get('id')}: {f.get('observation')}")
PY
    [[ "${review_rc}" -eq 0 ]] || fail "Harness baseline is not operationally complete; inspect ${OUT_DIR}/review.json"
  else
    log "Harness not found; skipped Agent baseline (set HARNESS_DIR to include it)"
  fi

  log "REFERENCE ENVIRONMENT SMOKE PASS"
  echo "Evidence: ${OUT_DIR}"
}

main "$@"
