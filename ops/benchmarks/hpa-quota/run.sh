#!/usr/bin/env bash
set -euo pipefail

MODE="dry-run"
[[ "${1:-}" == "--execute" ]] && MODE="execute"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$(cd "${ROOT_DIR}/../infrastructure-engineering-harness" 2>/dev/null && pwd || true)}"
TF_DIR="${ROOT_DIR}/terraform/reference-environment"
HPA_MANIFEST="${ROOT_DIR}/gitops/apps/demo-app/hpa.yaml"
QUERY_FILE="${ROOT_DIR}/observability/agent-prometheus-queries.json"
OUTPUT_ROOT="${OUTPUT_ROOT:-${ROOT_DIR}/.ops-benchmark}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-hpa-quota"
RUN_DIR="${OUTPUT_ROOT}/${RUN_ID}"
PROM_GATEWAY_URL="${PROM_GATEWAY_URL:-http://127.0.0.1:8080}"
PROM_HOST="${PROM_HOST:-prometheus.lab.local}"
BASELINE_HPA_MAX="${BASELINE_HPA_MAX:-6}"
TARGET_HPA_MAX="${TARGET_HPA_MAX:-8}"
TARGET_REQUESTS_CPU="${TARGET_REQUESTS_CPU:-2}"
LOAD_CONCURRENCY="${LOAD_CONCURRENCY:-12}"
DETECTION_MAX_POLLS="${DETECTION_MAX_POLLS:-20}"
DETECTION_POLL_SECONDS="${DETECTION_POLL_SECONDS:-15}"
POSTCHECK_MAX_POLLS="${POSTCHECK_MAX_POLLS:-12}"
POSTCHECK_POLL_SECONDS="${POSTCHECK_POLL_SECONDS:-10}"
PYTHON_BIN=""
LOAD_PIDS=()
HPA_CHANGED=0
TF_CONSTRAINED=0

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

resolve_python() {
  if command -v python3 >/dev/null 2>&1; then command -v python3; return; fi
  if command -v python >/dev/null 2>&1; then command -v python; return; fi
  fail "python3 or python is required"
}

hpa_max() {
  "${PYTHON_BIN}" - "${HPA_MANIFEST}" <<'PY'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text()
m=re.search(r'(?m)^\s*maxReplicas:\s*(\d+)\s*$', text)
print(m.group(1) if m else "MISSING")
PY
}

set_hpa_max() {
  local value="$1"
  "${PYTHON_BIN}" - "${HPA_MANIFEST}" "${value}" <<'PY'
from pathlib import Path
import re,sys
path=Path(sys.argv[1])
text=path.read_text()
text,count=re.subn(r'(?m)^(\s*maxReplicas:\s*)\d+(\s*)$', rf'\g<1>{sys.argv[2]}\g<2>', text, count=1)
if count != 1:
    raise SystemExit("expected exactly one web HPA maxReplicas")
path.write_text(text)
PY
}

commit_and_push_hpa() {
  local message="$1"
  git -C "${ROOT_DIR}" add "${HPA_MANIFEST}"
  git -C "${ROOT_DIR}" diff --cached --quiet && fail "no GitOps HPA change staged"
  git -C "${ROOT_DIR}" commit -m "${message}" >/dev/null
  git -C "${ROOT_DIR}" push origin HEAD:main >/dev/null
  git -C "${ROOT_DIR}" rev-parse HEAD
}

revision_matches() {
  local observed="$1" expected="$2"
  [[ -n "${observed}" && ( "${observed}" == "${expected}" || "${expected}" == "${observed}"* || "${observed}" == "${expected}"* ) ]]
}

wait_for_hpa_revision() {
  local expected_revision="$1" expected_max="$2"
  log "waiting for Argo CD demo-app revision ${expected_revision:0:7} and web HPA max=${expected_max}"
  local sync health revision live_max
  for attempt in $(seq 1 60); do
    sync="$(kubectl get application demo-app -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl get application demo-app -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    revision="$(kubectl get application demo-app -n argocd -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
    live_max="$(kubectl get hpa web -n demo-app -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || true)"
    if [[ "${sync}" == "Synced" && "${health}" == "Healthy" ]] \
      && revision_matches "${revision}" "${expected_revision}" \
      && [[ "${live_max}" == "${expected_max}" ]]; then
      log "GitOps HPA reconciled: revision=${revision:0:7} max=${live_max}"
      return 0
    fi
    if (( attempt % 6 == 0 )); then
      printf '  waiting: sync=%s health=%s revision=%s live_max=%s expected=%s\n' \
        "${sync:-?}" "${health:-?}" "${revision:0:7}" "${live_max:-?}" "${expected_max}"
    fi
    sleep 5
  done
  fail "web HPA did not reconcile expected revision/max"
}

quota_cpu_hard() {
  kubectl get resourcequota demo-app-capacity -n demo-app -o jsonpath='{.status.hard.requests\.cpu}' 2>/dev/null || true
}

quota_cpu_used() {
  kubectl get resourcequota demo-app-capacity -n demo-app -o jsonpath='{.status.used.requests\.cpu}' 2>/dev/null || true
}

wait_for_quota() {
  local expected="$1"
  for _ in $(seq 1 30); do
    local hard
    hard="$(quota_cpu_hard)"
    [[ "${hard}" == "${expected}" ]] && return 0
    sleep 2
  done
  fail "ResourceQuota requests.cpu did not reach ${expected}; current=$(quota_cpu_hard)"
}

terraform_apply() {
  local profile="$1"
  terraform -chdir="${TF_DIR}" apply -input=false -auto-approve -var-file="${profile}.tfvars"
}

start_load() {
  log "starting concurrent Gateway load: workers=${LOAD_CONCURRENCY}"
  rm -f "${RUN_DIR}/load.stop"
  for worker in $(seq 1 "${LOAD_CONCURRENCY}"); do
    (
      ok=0
      failed=0
      while [[ ! -e "${RUN_DIR}/load.stop" ]]; do
        code="$(curl -k -sS -o /dev/null -w '%{http_code}' --resolve web.lab.local:8443:127.0.0.1 https://web.lab.local:8443/ || true)"
        if [[ "${code}" == "200" ]]; then ok=$((ok + 1)); else failed=$((failed + 1)); fi
      done
      printf 'worker=%s ok=%s failed=%s\n' "${worker}" "${ok}" "${failed}" >>"${RUN_DIR}/load.log"
    ) &
    LOAD_PIDS+=("$!")
  done
}

stop_load() {
  [[ ${#LOAD_PIDS[@]} -eq 0 ]] && return 0
  touch "${RUN_DIR}/load.stop"
  for pid in "${LOAD_PIDS[@]}"; do wait "${pid}" 2>/dev/null || true; done
  LOAD_PIDS=()
  log "load stopped"
  [[ -f "${RUN_DIR}/load.log" ]] && tail -n 20 "${RUN_DIR}/load.log" || true
}

collect_k8s() {
  local output="$1"
  "${HARNESS_DIR}/agent" k8s-evidence --namespace demo-app --output "${output}"
}

capacity_review() {
  local k8s="$1" output="$2" warning_age="$3"
  "${HARNESS_DIR}/agent" capacity-review \
    --k8s "${k8s}" \
    --workload web \
    --target-hpa-max "${TARGET_HPA_MAX}" \
    --target-requests-cpu "${TARGET_REQUESTS_CPU}" \
    --warning-max-age-seconds "${warning_age}" \
    --output "${output}"
}

proposal_present() {
  "${PYTHON_BIN}" - "$1" <<'PY'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
ids={f.get("id") for f in r.get("findings",[])}
raise SystemExit(0 if r.get("proposal") and "capacity.web_hpa_quota_correlated" in ids else 1)
PY
}

postcheck_capacity_ok() {
  "${PYTHON_BIN}" - "$1" <<'PY'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
ids={f.get("id") for f in r.get("findings",[])}
summary=r.get("evidence_summary",{})
d=summary.get("deployment") or {}
ready=int(d.get("ready") or 0)
desired=int(d.get("desired") or 0)
blocked="capacity.resource_quota_blocking_scaleout" in ids or "capacity.web_hpa_quota_correlated" in ids
raise SystemExit(0 if not blocked and desired > 0 and ready >= desired else 1)
PY
}

print_proposal_policy() {
  "${PYTHON_BIN}" - "${RUN_DIR}/capacity-review.json" "${RUN_DIR}/policy.json" <<'PY'
import json,sys
from pathlib import Path
review=json.loads(Path(sys.argv[1]).read_text())
policy=json.loads(Path(sys.argv[2]).read_text())
print(json.dumps({"proposal": review.get("proposal"), "policy": policy}, indent=2))
PY
}

proposal_digest() {
  "${PYTHON_BIN}" - "${RUN_DIR}/capacity-review.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
proposal=json.loads(Path(sys.argv[1]).read_text())["proposal"]
canonical=json.dumps(proposal, sort_keys=True, separators=(",",":"), ensure_ascii=False)
print(hashlib.sha256(canonical.encode()).hexdigest())
PY
}

require_approval() {
  local digest="$1"
  local approved="${OPS_CAPACITY_APPROVAL:-}"
  if [[ -n "${approved}" ]]; then
    [[ "${approved}" == "${digest}" ]] || fail "OPS_CAPACITY_APPROVAL must equal the exact proposal digest ${digest}"
    log "explicit approval matched the exact proposal digest"
    return 0
  fi
  [[ -t 0 ]] || fail "interactive approval required; rerun with OPS_CAPACITY_APPROVAL=${digest}"
  local answer
  printf '\nType APPROVE %s to authorize this exact proposal: ' "${digest:0:12}"
  read -r answer
  [[ "${answer}" == "APPROVE ${digest:0:12}" ]] || fail "change not approved"
  log "interactive approval accepted for proposal ${digest:0:12}"
}

capture_resource_snapshot() {
  kubectl get hpa web -n demo-app -o json >"${RUN_DIR}/hpa-before-approval.json"
  kubectl get resourcequota demo-app-capacity -n demo-app -o json >"${RUN_DIR}/quota-before-approval.json"
}

authorize_change() {
  capture_resource_snapshot
  PYTHONPATH="${HARNESS_DIR}" "${PYTHON_BIN}" - \
    "${RUN_DIR}/capacity-review.json" \
    "${RUN_DIR}/policy.json" \
    "${RUN_DIR}/hpa-before-approval.json" \
    "${RUN_DIR}/quota-before-approval.json" \
    "${RUN_DIR}/approval.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
from runtime.change_control import ChangeControl
from runtime.provenance import ResourceProvenanceIndex

review=json.loads(Path(sys.argv[1]).read_text())
policy=json.loads(Path(sys.argv[2]).read_text())
hpa=json.loads(Path(sys.argv[3]).read_text())
quota=json.loads(Path(sys.argv[4]).read_text())
proposal=review["proposal"]
resource_ids=("k8s:hpa:demo-app/web", "k8s:resourcequota:demo-app/demo-app-capacity")
snapshot={"hpa": hpa, "quota": quota}
canonical=json.dumps(snapshot, sort_keys=True, separators=(",",":"))
graph_id="graph-"+hashlib.sha256(canonical.encode()).hexdigest()
provenance=ResourceProvenanceIndex(graph_id=graph_id, resource_ids=frozenset(resource_ids))
control=ChangeControl()
change=control.stage(
    proposal,
    resource_graph_id=graph_id,
    resource_ids=list(resource_ids),
    policy_revision=policy["policy_revision"],
)
grant=control.grant(change)
check=control.validate_apply(
    change,
    grant,
    current_resource_graph_id=graph_id,
    current_policy_revision=policy["policy_revision"],
    provenance=provenance,
    bound_scope=list(resource_ids),
)
if not check.allowed:
    raise SystemExit(check.code)
control.consume(grant)
Path(sys.argv[5]).write_text(json.dumps({
    "change_id": change.change_id,
    "change_revision": change.revision,
    "proposal_digest": change.proposal_digest,
    "approval_id": grant.approval_id,
    "outcome": grant.outcome,
    "resource_graph_id": graph_id,
    "policy_revision": policy["policy_revision"],
    "apply_check": check.code,
    "consumed": True,
}, indent=2)+"\n")
print(f"approval={grant.approval_id} apply_check={check.code}")
PY
}

collect_ops_review() {
  local stage="$1"
  collect_k8s "${RUN_DIR}/${stage}-k8s.json"
  "${HARNESS_DIR}/agent" prometheus-evidence \
    --url "${PROM_GATEWAY_URL}" \
    --host-header "${PROM_HOST}" \
    --query-file "${QUERY_FILE}" \
    --namespace demo-app \
    --service platform-api \
    --output "${RUN_DIR}/${stage}-prometheus.json"
  "${HARNESS_DIR}/agent" ops-review \
    --k8s "${RUN_DIR}/${stage}-k8s.json" \
    --prometheus "${RUN_DIR}/${stage}-prometheus.json" \
    --output "${RUN_DIR}/${stage}-review.json" || true
}

ops_healthy() {
  "${PYTHON_BIN}" - "$1" <<'PY'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
blocking=[f for f in r.get("findings",[]) if f.get("severity") in {"P0","P1"}]
raise SystemExit(0 if r.get("state")=="healthy" and not blocking and not r.get("evidence",{}).get("missing_required",[]) else 1)
PY
}

cleanup() {
  local rc=$?
  stop_load
  if [[ "${MODE}" == "execute" ]]; then
    set +e
    if [[ "${TF_CONSTRAINED}" == "1" ]]; then
      log "SAFETY: restoring Terraform baseline quota"
      terraform_apply baseline >/dev/null 2>&1
    fi
    if [[ "${HPA_CHANGED}" == "1" ]]; then
      log "SAFETY: restoring GitOps web HPA max=${BASELINE_HPA_MAX}"
      git -C "${ROOT_DIR}" fetch origin main >/dev/null 2>&1
      git -C "${ROOT_DIR}" reset --hard origin/main >/dev/null 2>&1
      set_hpa_max "${BASELINE_HPA_MAX}"
      git -C "${ROOT_DIR}" add "${HPA_MANIFEST}"
      if ! git -C "${ROOT_DIR}" diff --cached --quiet; then
        git -C "${ROOT_DIR}" commit -m "experiment: safety rollback web HPA capacity" >/dev/null 2>&1 \
          && git -C "${ROOT_DIR}" push origin HEAD:main >/dev/null 2>&1
      fi
    fi
    set -e
  fi
  exit "${rc}"
}
trap cleanup EXIT

main() {
  for cmd in git kubectl curl terraform; do require_cmd "${cmd}"; done
  PYTHON_BIN="$(resolve_python)"
  [[ -x "${HARNESS_DIR}/agent" ]] || fail "Harness Agent not found; set HARNESS_DIR"
  mkdir -p "${RUN_DIR}"

  log "preflight"
  [[ "$(git -C "${ROOT_DIR}" rev-parse --abbrev-ref HEAD)" == "main" ]] || fail "platform repo must be on main"
  git -C "${ROOT_DIR}" diff --quiet || fail "platform repo has unstaged changes"
  git -C "${ROOT_DIR}" diff --cached --quiet || fail "platform repo has staged changes"
  git -C "${ROOT_DIR}" fetch origin main
  [[ "$(git -C "${ROOT_DIR}" rev-parse HEAD)" == "$(git -C "${ROOT_DIR}" rev-parse origin/main)" ]] || fail "local main must match origin/main"
  [[ "$(hpa_max)" == "${BASELINE_HPA_MAX}" ]] || fail "web HPA main baseline must be maxReplicas=${BASELINE_HPA_MAX}"
  curl -k -fsS --resolve web.lab.local:8443:127.0.0.1 https://web.lab.local:8443/ >/dev/null || fail "Gateway app path unavailable"

  terraform -chdir="${TF_DIR}" init -input=false
  terraform -chdir="${TF_DIR}" validate

  if [[ "${MODE}" != "execute" ]]; then
    terraform -chdir="${TF_DIR}" plan -input=false -var-file=baseline.tfvars -out="${RUN_DIR}/baseline.tfplan"
    terraform -chdir="${TF_DIR}" plan -input=false -var-file=constrained.tfvars -out="${RUN_DIR}/constrained.tfplan"
    cat <<EOF

DRY RUN ONLY

Scenario #2 will:
  1. apply Terraform baseline ResourceQuota
  2. apply constrained requests.cpu=900m as the controlled incident
  3. generate concurrent HTTPS load until HPA + quota evidence correlates
  4. ask the Agent for a cross-owner remediation proposal
  5. classify risk with change-policy
  6. require explicit proposal-digest approval
  7. create and revalidate the one-shot ChangeControl grant only after approval
  8. restore Terraform CPU headroom and raise GitOps HPA max ${BASELINE_HPA_MAX}->${TARGET_HPA_MAX}
  9. run live post-checks
 10. stop load and rollback the temporary HPA change to ${BASELINE_HPA_MAX}

No cluster mutation beyond Terraform provider initialization was performed.
To execute intentionally:
  OPS_CAPACITY_ACK=platform-engineering-lab \\
    bash ops/benchmarks/hpa-quota/run.sh --execute
EOF
    return 0
  fi

  [[ "${OPS_CAPACITY_ACK:-}" == "platform-engineering-lab" ]] || fail "set OPS_CAPACITY_ACK=platform-engineering-lab"

  log "applying safe Terraform baseline"
  terraform_apply baseline
  wait_for_quota "2"
  printf 'quota baseline: hard=%s used=%s\n' "$(quota_cpu_hard)" "$(quota_cpu_used)"

  log "collecting baseline Ops evidence"
  collect_ops_review baseline
  ops_healthy "${RUN_DIR}/baseline-review.json" || fail "baseline Ops review must be healthy before capacity injection"

  log "injecting constrained ResourceQuota through Terraform"
  TF_CONSTRAINED=1
  terraform_apply constrained
  wait_for_quota "900m"
  printf 'quota constrained: hard=%s used=%s\n' "$(quota_cpu_hard)" "$(quota_cpu_used)"

  start_load

  log "waiting for HPA saturation + ResourceQuota correlation"
  detected=0
  for attempt in $(seq 1 "${DETECTION_MAX_POLLS}"); do
    collect_k8s "${RUN_DIR}/capacity-k8s.json"
    capacity_review "${RUN_DIR}/capacity-k8s.json" "${RUN_DIR}/capacity-review.json" 180
    if proposal_present "${RUN_DIR}/capacity-review.json"; then
      detected=1
      log "Agent correlated HPA saturation with ResourceQuota rejection"
      break
    fi
    printf '  detection poll %s/%s: hpa current=%s desired=%s max=%s quota=%s/%s\n' \
      "${attempt}" "${DETECTION_MAX_POLLS}" \
      "$(kubectl get hpa web -n demo-app -o jsonpath='{.status.currentReplicas}' 2>/dev/null || true)" \
      "$(kubectl get hpa web -n demo-app -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || true)" \
      "$(kubectl get hpa web -n demo-app -o jsonpath='{.spec.maxReplicas}' 2>/dev/null || true)" \
      "$(quota_cpu_used)" "$(quota_cpu_hard)"
    [[ "${attempt}" == "${DETECTION_MAX_POLLS}" ]] || sleep "${DETECTION_POLL_SECONDS}"
  done
  [[ "${detected}" == "1" ]] || fail "capacity incident did not become reproducible; inspect ${RUN_DIR} and tune LOAD_CONCURRENCY"

  "${HARNESS_DIR}/agent" change-policy \
    --proposal "${RUN_DIR}/capacity-review.json" \
    --output "${RUN_DIR}/policy.json"
  print_proposal_policy
  digest="$(proposal_digest)"
  log "proposal digest: ${digest}"

  require_approval "${digest}"
  authorize_change

  log "executing approved Terraform capacity remediation"
  terraform_apply baseline
  TF_CONSTRAINED=0
  wait_for_quota "2"

  log "executing approved GitOps HPA remediation"
  set_hpa_max "${TARGET_HPA_MAX}"
  HPA_CHANGED=1
  HPA_COMMIT="$(commit_and_push_hpa "experiment: raise web HPA capacity")"
  wait_for_hpa_revision "${HPA_COMMIT}" "${TARGET_HPA_MAX}"

  log "post-check under continued load"
  post_ok=0
  sleep 30
  for attempt in $(seq 1 "${POSTCHECK_MAX_POLLS}"); do
    collect_k8s "${RUN_DIR}/postcheck-k8s.json"
    capacity_review "${RUN_DIR}/postcheck-k8s.json" "${RUN_DIR}/postcheck-capacity.json" 30
    if postcheck_capacity_ok "${RUN_DIR}/postcheck-capacity.json"; then
      post_ok=1
      log "capacity post-check passed: no fresh quota block and deployment ready>=desired"
      break
    fi
    [[ "${attempt}" == "${POSTCHECK_MAX_POLLS}" ]] || sleep "${POSTCHECK_POLL_SECONDS}"
  done
  [[ "${post_ok}" == "1" ]] || fail "approved capacity remediation failed post-check"

  stop_load

  log "rolling back temporary GitOps HPA increase to pre-scenario baseline"
  set_hpa_max "${BASELINE_HPA_MAX}"
  ROLLBACK_COMMIT="$(commit_and_push_hpa "experiment: rollback web HPA capacity")"
  wait_for_hpa_revision "${ROLLBACK_COMMIT}" "${BASELINE_HPA_MAX}"
  HPA_CHANGED=0

  log "final verification"
  collect_ops_review final
  for attempt in $(seq 1 12); do
    if ops_healthy "${RUN_DIR}/final-review.json"; then break; fi
    [[ "${attempt}" == "12" ]] && fail "final Ops review did not return healthy"
    sleep 15
    collect_ops_review final
  done
  [[ "$(quota_cpu_hard)" == "2" ]] || fail "Terraform quota baseline was not preserved"
  [[ "$(kubectl get hpa web -n demo-app -o jsonpath='{.spec.maxReplicas}')" == "${BASELINE_HPA_MAX}" ]] || fail "GitOps HPA rollback not verified"

  log "HPA/QUOTA BENCHMARK PASS: ${RUN_DIR}"
}

main "$@"
