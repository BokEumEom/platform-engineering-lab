#!/usr/bin/env bash
set -euo pipefail

MODE="dry-run"
if [[ "${1:-}" == "--execute" ]]; then
  MODE="execute"
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$(cd "${ROOT_DIR}/../infrastructure-engineering-harness" 2>/dev/null && pwd || true)}"
OUTPUT_ROOT="${OUTPUT_ROOT:-${ROOT_DIR}/.ops-benchmark}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${OUTPUT_ROOT}/${RUN_ID}"
ORDERS_MANIFEST="${ROOT_DIR}/gitops/apps/demo-app/orders.yaml"
QUERY_FILE="${ROOT_DIR}/observability/agent-prometheus-queries.json"
PROM_GATEWAY_URL="${PROM_GATEWAY_URL:-http://127.0.0.1:8080}"
PROM_HOST="${PROM_HOST:-prometheus.lab.local}"
FAULT_LATENCY_MS="${FAULT_LATENCY_MS:-800}"
FAULT_ERROR_RATE_PERCENT="${FAULT_ERROR_RATE_PERCENT:-25}"
TRAFFIC_REQUESTS="${TRAFFIC_REQUESTS:-80}"
BASELINE_MAX_POLLS="${BASELINE_MAX_POLLS:-8}"
BASELINE_POLL_SECONDS="${BASELINE_POLL_SECONDS:-15}"
RECOVERY_MAX_POLLS="${RECOVERY_MAX_POLLS:-28}"
RECOVERY_POLL_SECONDS="${RECOVERY_POLL_SECONDS:-15}"
PYTHON_BIN=""
FAULT_COMMIT=""
RECOVERY_COMMIT=""
FAULT_ACTIVE=0

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

resolve_python() {
  if command -v python3 >/dev/null 2>&1; then command -v python3; return; fi
  if command -v python >/dev/null 2>&1; then command -v python; return; fi
  fail "required Python interpreter not found: install python3 or provide python"
}

set_orders_fault() {
  local latency="$1" error_rate="$2"
  "${PYTHON_BIN}" - "${ORDERS_MANIFEST}" "${latency}" "${error_rate}" <<'PY'
from pathlib import Path
import re, sys
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
for name, value in {"FAULT_LATENCY_MS": sys.argv[2], "FAULT_ERROR_RATE_PERCENT": sys.argv[3]}.items():
    pattern = rf'(?ms)(- name: {re.escape(name)}\s*\n\s*value:\s*")[^"]*(")'
    text, count = re.subn(pattern, rf'\g<1>{value}\g<2>', text, count=1)
    if count != 1:
        raise SystemExit(f"expected exactly one {name} literal in {path}")
path.write_text(text, encoding="utf-8")
PY
}

orders_fault_values() {
  "${PYTHON_BIN}" - "${ORDERS_MANIFEST}" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
for name in ("FAULT_LATENCY_MS", "FAULT_ERROR_RATE_PERCENT"):
    match = re.search(rf'(?ms)- name: {name}\s*\n\s*value:\s*"([^"]*)"', text)
    print(f"{name}={match.group(1) if match else 'MISSING'}")
PY
}

initial_fault_is_clear() {
  "${PYTHON_BIN}" - "${ORDERS_MANIFEST}" <<'PY'
from pathlib import Path
import re, sys
text = Path(sys.argv[1]).read_text(encoding="utf-8")
values = {}
for name in ("FAULT_LATENCY_MS", "FAULT_ERROR_RATE_PERCENT"):
    match = re.search(rf'(?ms)- name: {name}\s*\n\s*value:\s*"([^"]*)"', text)
    values[name] = match.group(1) if match else None
raise SystemExit(0 if values == {"FAULT_LATENCY_MS": "0", "FAULT_ERROR_RATE_PERCENT": "0"} else 1)
PY
}

safety_cleanup() {
  local rc=$?
  if [[ "${MODE}" == "execute" && "${FAULT_ACTIVE}" == "1" ]]; then
    set +e
    log "SAFETY RECOVERY: benchmark exited while the injected fault may still be active"
    set_orders_fault 0 0
    git -C "${ROOT_DIR}" add "${ORDERS_MANIFEST}"
    if ! git -C "${ROOT_DIR}" diff --cached --quiet; then
      if git -C "${ROOT_DIR}" commit -m "experiment: safety recover orders-service fault" >/dev/null \
        && git -C "${ROOT_DIR}" push origin HEAD:main >/dev/null; then
        echo "Safety recovery was committed and pushed to main." >&2
      else
        echo "WARNING: automatic safety recovery could not be pushed." >&2
        echo "MANUAL RECOVERY REQUIRED: set FAULT_LATENCY_MS=0 and FAULT_ERROR_RATE_PERCENT=0 in ${ORDERS_MANIFEST}, commit, and push main." >&2
      fi
    else
      echo "Local fault profile is already clear; verify origin/main and Argo CD reconciliation." >&2
    fi
    set -e
  fi
  exit "${rc}"
}
trap safety_cleanup EXIT

wait_for_demo_app() {
  log "waiting for Argo CD demo-app reconciliation"
  local sync health
  for _ in $(seq 1 40); do
    sync="$(kubectl get application demo-app -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl get application demo-app -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]; then
      for d in web catalog orders inventory payments recommendations; do
        kubectl rollout status "deployment/${d}" -n demo-app --timeout=120s >/dev/null
      done
      log "demo-app reconciled: ${sync}/${health}"
      return 0
    fi
    sleep 5
  done
  fail "demo-app did not reach Synced/Healthy"
}

generate_traffic() {
  local count="$1" ok=0 failed=0 code
  log "generating ${count} requests through MetalLB/Envoy HTTPS path"
  for _ in $(seq 1 "${count}"); do
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' --resolve web.lab.local:8443:127.0.0.1 https://web.lab.local:8443/ || true)"
    if [[ "${code}" == "200" ]]; then ok=$((ok + 1)); else failed=$((failed + 1)); fi
    sleep 0.1
  done
  printf 'traffic: ok=%s failed=%s\n' "${ok}" "${failed}" | tee -a "${RUN_DIR}/traffic.log"
}

collect_stage() {
  local stage="$1"
  local k8s="${RUN_DIR}/${stage}-k8s.json" prom="${RUN_DIR}/${stage}-prometheus.json" review="${RUN_DIR}/${stage}-review.json"

  log "collecting ${stage} Kubernetes evidence"
  "${HARNESS_DIR}/agent" k8s-evidence --namespace demo-app --output "${k8s}"

  log "collecting ${stage} Prometheus evidence through MetalLB/Envoy Gateway"
  "${HARNESS_DIR}/agent" prometheus-evidence \
    --url "${PROM_GATEWAY_URL}" \
    --host-header "${PROM_HOST}" \
    --query-file "${QUERY_FILE}" \
    --namespace demo-app \
    --service platform-api \
    --output "${prom}"

  log "running ${stage} Ops review"
  "${HARNESS_DIR}/agent" ops-review --k8s "${k8s}" --prometheus "${prom}" --output "${review}" || true

  "${PYTHON_BIN}" - "${review}" <<'PY'
import json, sys
from pathlib import Path
review = json.loads(Path(sys.argv[1]).read_text())
print(f"state={review.get('state')} release_guidance={review.get('release_guidance')}")
missing = review.get("evidence", {}).get("missing_required", [])
if missing:
    print("  missing_required:")
    for ref in missing: print(f"    - {ref}")
for finding in review.get("findings", []):
    print(f"  {finding.get('severity')} {finding.get('id')}: {finding.get('observation')}")
PY
}

baseline_healthy() {
  "${PYTHON_BIN}" - "${RUN_DIR}/baseline-review.json" <<'PY'
import json, sys
from pathlib import Path
r = json.loads(Path(sys.argv[1]).read_text())
missing = r.get("evidence", {}).get("missing_required", [])
blocking = [f for f in r.get("findings", []) if f.get("severity") in {"P0", "P1"}]
raise SystemExit(0 if r.get("state") == "healthy" and not missing and not blocking else 1)
PY
}

fault_detected() {
  "${PYTHON_BIN}" - "${RUN_DIR}/fault-review.json" <<'PY'
import json, sys
from pathlib import Path
r = json.loads(Path(sys.argv[1]).read_text())
ids = {f.get("id") for f in r.get("findings", [])}
raise SystemExit(0 if "dependency.orders_fault_injection_correlated" in ids and r.get("state") in {"acute", "at_risk"} else 1)
PY
}

recovery_verified() {
  "${PYTHON_BIN}" - "${RUN_DIR}/recovery-review.json" <<'PY'
import json, sys
from pathlib import Path
r = json.loads(Path(sys.argv[1]).read_text())
blocking = [f for f in r.get("findings", []) if f.get("severity") in {"P0", "P1"}]
raise SystemExit(0 if r.get("state") == "healthy" and not blocking else 1)
PY
}

commit_and_push() {
  local message="$1"
  git -C "${ROOT_DIR}" add "${ORDERS_MANIFEST}"
  git -C "${ROOT_DIR}" diff --cached --quiet && fail "no GitOps change was staged for: ${message}"
  git -C "${ROOT_DIR}" commit -m "${message}" >/dev/null
  git -C "${ROOT_DIR}" push origin HEAD:main >/dev/null
  git -C "${ROOT_DIR}" rev-parse HEAD
}

write_metadata() {
  cat >"${RUN_DIR}/metadata.txt" <<EOF
run_id=${RUN_ID}
mode=${MODE}
platform_repo=${ROOT_DIR}
harness_repo=${HARNESS_DIR}
python_bin=${PYTHON_BIN}
prometheus_gateway_url=${PROM_GATEWAY_URL}
prometheus_host=${PROM_HOST}
fault_latency_ms=${FAULT_LATENCY_MS}
fault_error_rate_percent=${FAULT_ERROR_RATE_PERCENT}
fault_commit=${FAULT_COMMIT}
recovery_commit=${RECOVERY_COMMIT}
EOF
}

main() {
  for cmd in git kubectl curl; do require_cmd "${cmd}"; done
  PYTHON_BIN="$(resolve_python)"
  [[ -n "${HARNESS_DIR}" && -x "${HARNESS_DIR}/agent" ]] || fail "Infrastructure Engineering Agent not found; set HARNESS_DIR"
  [[ -f "${ORDERS_MANIFEST}" ]] || fail "orders manifest not found"
  [[ -f "${QUERY_FILE}" ]] || fail "Prometheus query profile not found"
  mkdir -p "${RUN_DIR}"

  log "preflight"
  log "Python interpreter: ${PYTHON_BIN}"
  log "Prometheus evidence path: ${PROM_GATEWAY_URL} Host=${PROM_HOST}"
  [[ "$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "platform repo must be on main"
  git -C "${ROOT_DIR}" diff --quiet || fail "platform repo has unstaged changes"
  git -C "${ROOT_DIR}" diff --cached --quiet || fail "platform repo has staged changes"
  git -C "${ROOT_DIR}" fetch origin main
  [[ "$(git -C "${ROOT_DIR}" rev-parse HEAD)" == "$(git -C "${ROOT_DIR}" rev-parse origin/main)" ]] || fail "local main must match origin/main"

  kubectl get application demo-app -n argocd >/dev/null
  kubectl get deployment web catalog orders inventory payments recommendations -n demo-app >/dev/null

  curl -k -fsS --resolve web.lab.local:8443:127.0.0.1 https://web.lab.local:8443/ >/dev/null \
    || fail "Gateway HTTPS application path is unavailable; verify the Docker TCP proxy"
  curl -fsS -H "Host: ${PROM_HOST}" "${PROM_GATEWAY_URL}/-/ready" >/dev/null \
    || fail "Prometheus Gateway path is unavailable; verify the :8080 Docker Gateway proxy and HTTPRoute/prometheus-agent"

  log "current orders fault profile"
  orders_fault_values | tee "${RUN_DIR}/initial-fault-profile.txt"
  initial_fault_is_clear || fail "benchmark requires a clean starting profile: FAULT_LATENCY_MS=0 and FAULT_ERROR_RATE_PERCENT=0"

  if [[ "${MODE}" != "execute" ]]; then
    cat <<EOF

DRY RUN ONLY

Prometheus evidence path:
  ${PROM_GATEWAY_URL} with Host: ${PROM_HOST}
  -> local Docker TCP proxy :8080
  -> MetalLB Gateway IP :80
  -> Envoy Gateway
  -> monitoring-kube-prometheus-prometheus:9090

This benchmark will capture a healthy baseline, inject an orders-service GitOps fault,
collect multi-service evidence, remediate through GitOps, and require verified recovery.
If execution exits while the injected fault may still be active, a best-effort GitOps
safety recovery resets FAULT_* to zero without hiding the original failure.

No mutation was performed.
To execute intentionally:
  OPS_BENCHMARK_ACK=platform-engineering-lab \\
    bash ops/benchmarks/orders-fault/run.sh --execute
EOF
    exit 0
  fi

  [[ "${OPS_BENCHMARK_ACK:-}" == "platform-engineering-lab" ]] || fail "set OPS_BENCHMARK_ACK=platform-engineering-lab for intentional mutation"

  log "warming baseline telemetry"
  local baseline_ready=0
  for attempt in $(seq 1 "${BASELINE_MAX_POLLS}"); do
    generate_traffic 20
    collect_stage baseline
    if baseline_healthy; then
      baseline_ready=1
      log "baseline gate passed: healthy and fresh evidence confirmed"
      break
    fi
    if [[ "${attempt}" != "${BASELINE_MAX_POLLS}" ]]; then
      log "baseline evidence not ready yet (${attempt}/${BASELINE_MAX_POLLS}); waiting for another scrape/evaluation cycle"
      sleep "${BASELINE_POLL_SECONDS}"
    fi
  done
  [[ "${baseline_ready}" == "1" ]] || { write_metadata; fail "baseline evidence stayed incomplete/unhealthy; no fault was injected"; }

  log "injecting controlled orders fault through GitOps"
  set_orders_fault "${FAULT_LATENCY_MS}" "${FAULT_ERROR_RATE_PERCENT}"
  FAULT_ACTIVE=1
  FAULT_COMMIT="$(commit_and_push "experiment: inject orders-service fault")"
  wait_for_demo_app

  for attempt in $(seq 1 8); do
    generate_traffic "${TRAFFIC_REQUESTS}"
    collect_stage fault
    if fault_detected; then log "Ops Agent detected correlated orders fault"; break; fi
    [[ "${attempt}" != "8" ]] || fail "Ops Agent did not detect the expected orders fault after repeated fresh evidence"
    sleep 15
  done

  log "remediating through GitOps"
  set_orders_fault 0 0
  RECOVERY_COMMIT="$(commit_and_push "experiment: recover orders-service fault")"
  FAULT_ACTIVE=0
  wait_for_demo_app

  for attempt in $(seq 1 "${RECOVERY_MAX_POLLS}"); do
    generate_traffic 25
    collect_stage recovery
    if recovery_verified; then log "fresh evidence is operationally healthy"; break; fi
    [[ "${attempt}" != "${RECOVERY_MAX_POLLS}" ]] || fail "recovery metrics did not clear within the benchmark guard window"
    sleep "${RECOVERY_POLL_SECONDS}"
  done

  log "comparing fault and recovery reviews"
  "${HARNESS_DIR}/agent" ops-compare \
    --before "${RUN_DIR}/fault-review.json" \
    --after "${RUN_DIR}/recovery-review.json" \
    --output "${RUN_DIR}/revalidation.json"

  write_metadata
  "${PYTHON_BIN}" - "${RUN_DIR}/revalidation.json" <<'PY'
import json, sys
from pathlib import Path
r = json.loads(Path(sys.argv[1]).read_text())
print(json.dumps({k: r.get(k) for k in ("verified_recovery", "resolved", "persistent_blocking", "new_blocking", "learning_candidates")}, indent=2))
raise SystemExit(0 if r.get("verified_recovery") else 1)
PY
  log "BENCHMARK PASS: ${RUN_DIR}"
}

main "$@"
