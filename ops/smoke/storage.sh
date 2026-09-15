#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROM_GATEWAY_URL="${PROM_GATEWAY_URL:-http://127.0.0.1:8080}"
PROM_HOST="${PROM_HOST:-prometheus.lab.local}"
NAMESPACE="${STORAGE_NAMESPACE:-demo-app}"
STATEFULSET="${STORAGE_STATEFULSET:-storage-probe}"
PVC_PATTERN="${STORAGE_PVC_PATTERN:-data-storage-probe-.*}"
OUT_DIR="${STORAGE_OUT_DIR:-${ROOT_DIR}/.ops-smoke/$(date -u +%Y%m%dT%H%M%SZ)-storage}"
PYTHON_BIN="$(command -v python3 || command -v python || true)"

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${PYTHON_BIN}" ]] || fail "python3 or python is required"
command -v kubectl >/dev/null 2>&1 || fail "kubectl is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
mkdir -p "${OUT_DIR}"

prom_query() {
  local name="$1" query="$2"
  curl -fsS -G -H "Host: ${PROM_HOST}" \
    --data-urlencode "query=${query}" \
    "${PROM_GATEWAY_URL}/api/v1/query" \
    | tee "${OUT_DIR}/${name}.json"
}

result_count() {
  "${PYTHON_BIN}" -c '
import json,sys
p=json.load(sys.stdin)
print(len(((p.get("data") or {}).get("result") or [])))
'
}

scalar_value() {
  "${PYTHON_BIN}" -c '
import json,sys
p=json.load(sys.stdin)
r=((p.get("data") or {}).get("result") or [])
print(r[0].get("value", [None, "0"])[1] if r else "0")
'
}

log "Stateful storage workload"
kubectl rollout status "statefulset/${STATEFULSET}" -n "${NAMESPACE}" --timeout=180s

pvc_name="$(kubectl get pvc -n "${NAMESPACE}" -l app=storage-probe -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${pvc_name}" ]] || fail "storage-probe PVC not found"
phase="$(kubectl get pvc "${pvc_name}" -n "${NAMESPACE}" -o jsonpath='{.status.phase}')"
capacity="$(kubectl get pvc "${pvc_name}" -n "${NAMESPACE}" -o jsonpath='{.status.capacity.storage}')"
printf '  pvc=%s phase=%s capacity=%s\n' "${pvc_name}" "${phase}" "${capacity}"
[[ "${phase}" == "Bound" ]] || fail "PVC ${NAMESPACE}/${pvc_name} is not Bound"

log "PVC object metrics through Prometheus"
info_json="$(prom_query pvc-info "kube_persistentvolumeclaim_info{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
info_count="$(printf '%s' "${info_json}" | result_count)"
requested_json="$(prom_query pvc-requested "kube_persistentvolumeclaim_resource_requests_storage_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
requested_count="$(printf '%s' "${requested_json}" | result_count)"
printf '  pvc_info_series=%s requested_capacity_series=%s\n' "${info_count}" "${requested_count}"
[[ "${info_count}" -gt 0 && "${requested_count}" -gt 0 ]] || fail "kube-state-metrics PVC series are missing"

log "PVC filesystem metrics through kubelet"
capacity_json="$(prom_query pvc-volume-capacity "kubelet_volume_stats_capacity_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
used_json="$(prom_query pvc-volume-used "kubelet_volume_stats_used_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
available_json="$(prom_query pvc-volume-available "kubelet_volume_stats_available_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
capacity_count="$(printf '%s' "${capacity_json}" | result_count)"
used_count="$(printf '%s' "${used_json}" | result_count)"
available_count="$(printf '%s' "${available_json}" | result_count)"
printf '  capacity_series=%s used_series=%s available_series=%s\n' "${capacity_count}" "${used_count}" "${available_count}"
[[ "${capacity_count}" -gt 0 && "${used_count}" -gt 0 && "${available_count}" -gt 0 ]] || fail "kubelet volume stats are not available for the storage-probe PVC"

ratio_json="$(prom_query pvc-usage-ratio "kubelet_volume_stats_used_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"} / clamp_min(kubelet_volume_stats_capacity_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}, 1)")"
ratio="$(printf '%s' "${ratio_json}" | scalar_value)"
printf '  usage_ratio=%s\n' "${ratio}"

log "PVC STORAGE SMOKE PASS"
echo "Evidence: ${OUT_DIR}"
