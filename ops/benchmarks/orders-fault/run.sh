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
PROM_PORT="${PROM_PORT:-19090}"
PROM_URL="http://127.0.0.1:${PROM_PORT}"
FAULT_LATENCY_MS="${FAULT_LATENCY_MS:-800}"
FAULT_ERROR_RATE_PERCENT="${FAULT_ERROR_RATE_PERCENT:-25}"
TRAFFIC_REQUESTS="${TRAFFIC_REQUESTS:-80}"
RECOVERY_MAX_POLLS="${RECOVERY_MAX_POLLS:-28}"
RECOVERY_POLL_SECONDS="${RECOVERY_POLL_SECONDS:-15}"
PYTHON_BIN=""

PF_PID=""
FAULT_COMMIT=""
RECOVERY_COMMIT=""

log() {
  printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

cleanup() {
  if [[ -n "${PF_PID}" ]] && kill -0 "${PF_PID}" 2>/dev/null; then
    kill "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

resolve_python() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "$(command -v python3)"
    return 0
  fi
  if command -v python >/dev/null 2>&1; then
    printf '%s\n' "$(command -v python)"
    return 0
  fi
  fail "required Python interpreter not found: install python3 or provide python"
}

set_orders_fault() {
  local latency="$1"
  local error_rate="$2"
  "${PYTHON_BIN}" - "${ORDERS_MANIFEST}" "${latency}" "${error_rate}" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
latency = sys.argv[2]
error_rate = sys.argv[3]
text = path.read_text(encoding="utf-8")

patterns = {
    "FAULT_LATENCY_MS": latency,
    "FAULT_ERROR_RATE_PERCENT": error_rate,
}
for name, value in patterns.items():
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
import re
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
for name in ("FAULT_LATENCY_MS", "FAULT_ERROR_RATE_PERCENT"):
    match = re.search(rf'(?ms)- name: {name}\s*\n\s*value:\s*"([^"]*)"', text)
    print(f"{name}={match.group(1) if match else 'MISSING'}")
PY
}

wait_for_demo_app() {
  log "waiting for Argo CD demo-app reconciliation"
  local i sync health
  for i in $(seq 1 40); do
    sync="$(kubectl get application demo-app -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl get application demo-app -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]]; then
      kubectl rollout status deployment/orders -n demo-app --timeout=120s >/dev/null
      kubectl rollout status deployment/web -n demo-app --timeout=120s >/dev/null
      log "demo-app reconciled: ${sync}/${health}"
      return 0
    fi
    sleep 5
  done
  fail "demo-app did not reach Synced/Healthy"
}

generate_traffic() {
  local count="$1"
  local ok=0
  local failed=0
  local code
  log "generating ${count} requests through MetalLB/Envoy HTTPS path"
  for _ in $(seq 1 "${count}"); do
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' \
      --resolve web.lab.local:8443:127.0.0.1 \
      https://web.lab.local:8443/ || true)"
    if [[ "${code}" == "200" ]]; then
      ok=$((ok + 1))
    else
      failed=$((failed + 1))
    fi
    sleep 0.1
  done
  printf 'traffic: ok=%s failed=%s\n' "${ok}" "${failed}" | tee -a "${RUN_DIR}/traffic.log"
}

collect_stage() {
  local stage="$1"
  local k8s="${RUN_DIR}/${stage}-k8s.json"
  local prom="${RUN_DIR}/${stage}-prometheus.json"
  local review="${RUN_DIR}/${stage}-review.json"

  log "collecting ${stage} Kubernetes evidence"
  "${HARNESS_DIR}/agent" k8s-evidence \
    --namespace demo-app \
    --output "${k8s}"

  log "collecting ${stage} Prometheus evidence"
  "${HARNESS_DIR}/agent" prometheus-evidence \
    --url "${PROM_URL}" \
    --query-file "${QUERY_FILE}" \
    --namespace demo-app \
    --service platform-api \
    --output "${prom}"

  log "running ${stage} Ops review"
  "${HARNESS_DIR}/agent" ops-review \
    --k8s "${k8s}" \
    --prometheus "${prom}" \
    --output "${review}"

  "${PYTHON_BIN}" - "${review}" <<'PY'
import json
import sys
from pathlib import Path

review = json.loads(Path(sys.argv[1]).read_text())
print(f"state={review.get('state')} release_guidance={review.get('release_guidance')}")
for finding in review.get("findings", []):
    print(f"  {finding.get('severity')} {finding.get('id')}: {finding.get('observation')}")
PY
}

prometheus_service() {
  if [[ -n "${PROMETHEUS_SERVICE:-}" ]]; then
    printf '%s\n' "${PROMETHEUS_SERVICE}"
    return
  fi
  kubectl get svc -n monitoring -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep -E 'prometheus$' \
    | head -n 1
}

start_prometheus_proxy() {
  local service
  service="$(prometheus_service)"
  [[ -n "${service}" ]] || fail "unable to resolve Prometheus Service; set PROMETHEUS_SERVICE explicitly"
  log "starting read-only Prometheus port-forward: ${service} -> ${PROM_PORT}"
  kubectl port-forward -n monitoring "svc/${service}" "${PROM_PORT}:9090" \
    >"${RUN_DIR}/prometheus-port-forward.log" 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 20); do
    if curl -fsS "${PROM_URL}/-/ready" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  fail "Prometheus port-forward did not become ready"
}

commit_and_push() {
  local message="$1"
  git -C "${ROOT_DIR}" add "${ORDERS_MANIFEST}"
  if git -C "${ROOT_DIR}" diff --cached --quiet; then
    fail "no GitOps change was staged for: ${message}"
  fi
  git -C "${ROOT_DIR}" commit -m "${message}"
  git -C "${ROOT_DIR}" push origin HEAD:main
  git -C "${ROOT_DIR}" rev-parse HEAD
}

fault_detected() {
  local review="${RUN_DIR}/fault-review.json"
  [[ -f "${review}" ]] || return 1
  "${PYTHON_BIN}" - "${review}" <<'PY'
import json
import sys
from pathlib import Path
r = json.loads(Path(sys.argv[1]).read_text())
ids = {f.get("id") for f in r.get("findings", [])}
required = {
    "dependency.orders_fault_injection_correlated",
}
raise SystemExit(0 if required <= ids and r.get("state") in {"acute", "at_risk"} else 1)
PY
}

recovery_verified() {
  local review="${RUN_DIR}/recovery-review.json"
  [[ -f "${review}" ]] || return 1
  "${PYTHON_BIN}" - "${review}" <<'PY'
import json
import sys
from pathlib import Path
r = json.loads(Path(sys.argv[1]).read_text())
blocking = [f for f in r.get("findings", []) if f.get("severity") in {"P0", "P1"}]
raise SystemExit(0 if r.get("state") == "healthy" and not blocking else 1)
PY
}

write_metadata() {
  cat >"${RUN_DIR}/metadata.txt" <<EOF
run_id=${RUN_ID}
mode=${MODE}
platform_repo=${ROOT_DIR}
harness_repo=${HARNESS_DIR}
python_bin=${PYTHON_BIN}
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
  [[ "$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "platform repo must be on main"
  git -C "${ROOT_DIR}" diff --quiet || fail "platform repo has unstaged changes"
  git -C "${ROOT_DIR}" diff --cached --quiet || fail "platform repo has staged changes"
  git -C "${ROOT_DIR}" fetch origin main
  [[ "$(git -C "${ROOT_DIR}" rev-parse HEAD)" == "$(git -C "${ROOT_DIR}" rev-parse origin/main)" ]] || fail "local main must match origin/main"

  kubectl get application demo-app -n argocd >/dev/null
  kubectl get deployment web catalog orders -n demo-app >/dev/null

  if ! curl -k -fsS --resolve web.lab.local:8443:127.0.0.1 https://web.lab.local:8443/ >/dev/null; then
    fail "Gateway HTTPS path is unavailable; verify the Docker TCP proxy before the benchmark"
  fi

  log "current orders fault profile"
  orders_fault_values | tee "${RUN_DIR}/initial-fault-profile.txt"

  if [[ "${MODE}" != "execute" ]]; then
    cat <<EOF

DRY RUN ONLY

This benchmark will:
  1. capture baseline Kubernetes + Prometheus evidence;
  2. commit/push orders fault injection to main;
  3. wait for Argo CD reconciliation and generate Gateway traffic;
  4. run the Infrastructure Engineering Agent Ops review;
  5. commit/push remediation (FAULT_* back to zero);
  6. collect fresh evidence until P0/P1 symptoms clear;
  7. run ops-compare and require verified_recovery=true.

Requested fault:
  FAULT_LATENCY_MS=${FAULT_LATENCY_MS}
  FAULT_ERROR_RATE_PERCENT=${FAULT_ERROR_RATE_PERCENT}

No mutation was performed.
To execute intentionally:
  OPS_BENCHMARK_ACK=platform-engineering-lab \\
    bash ops/benchmarks/orders-fault/run.sh --execute
EOF
    exit 0
  fi

  [[ "${OPS_BENCHMARK_ACK:-}" == "platform-engineering-lab" ]] \
    || fail "set OPS_BENCHMARK_ACK=platform-engineering-lab for intentional mutation"

  start_prometheus_proxy

  generate_traffic 20
  collect_stage baseline

  log "injecting controlled orders fault through GitOps"
  set_orders_fault "${FAULT_LATENCY_MS}" "${FAULT_ERROR_RATE_PERCENT}"
  FAULT_COMMIT="$(commit_and_push "experiment: inject orders-service fault")"
  wait_for_demo_app

  for attempt in $(seq 1 8); do
    generate_traffic "${TRAFFIC_REQUESTS}"
    collect_stage fault
    if fault_detected; then
      log "Ops Agent detected correlated orders fault"
      break
    fi
    if [[ "${attempt}" == "8" ]]; then
      fail "Ops Agent did not detect the expected orders fault after repeated fresh evidence"
    fi
    sleep 15
  done

  log "remediating through GitOps"
  set_orders_fault 0 0
  RECOVERY_COMMIT="$(commit_and_push "experiment: recover orders-service fault")"
  wait_for_demo_app

  for attempt in $(seq 1 "${RECOVERY_MAX_POLLS}"); do
    generate_traffic 25
    collect_stage recovery
    if recovery_verified; then
      log "fresh evidence is operationally healthy"
      break
    fi
    if [[ "${attempt}" == "${RECOVERY_MAX_POLLS}" ]]; then
      fail "recovery metrics did not clear within the benchmark guard window"
    fi
    sleep "${RECOVERY_POLL_SECONDS}"
  done

  log "comparing fault and recovery reviews"
  "${HARNESS_DIR}/agent" ops-compare \
    --before "${RUN_DIR}/fault-review.json" \
    --after "${RUN_DIR}/recovery-review.json" \
    --output "${RUN_DIR}/revalidation.json"

  write_metadata

  "${PYTHON_BIN}" - "${RUN_DIR}/revalidation.json" <<'PY'
import json
import sys
from pathlib import Path
result = json.loads(Path(sys.argv[1]).read_text())
print(json.dumps({
    "verified_recovery": result.get("verified_recovery"),
    "resolved": result.get("resolved"),
    "persistent_blocking": result.get("persistent_blocking"),
    "new_blocking": result.get("new_blocking"),
    "learning_candidates": result.get("learning_candidates"),
}, indent=2))
raise SystemExit(0 if result.get("verified_recovery") else 1)
PY

  log "BENCHMARK PASS: ${RUN_DIR}"
}

main "$@"
