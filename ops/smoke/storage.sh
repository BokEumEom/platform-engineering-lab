#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROM_GATEWAY_URL="${PROM_GATEWAY_URL:-http://127.0.0.1:8080}"
PROM_HOST="${PROM_HOST:-prometheus.lab.local}"
NAMESPACE="${STORAGE_NAMESPACE:-demo-app}"
STATEFULSET="${STORAGE_STATEFULSET:-storage-probe}"
PVC_PATTERN="${STORAGE_PVC_PATTERN:-data-storage-probe-.*}"
ARGO_APP="${STORAGE_ARGO_APP:-demo-app}"
ARGO_NAMESPACE="${ARGO_NAMESPACE:-argocd}"
RECONCILE_MAX_POLLS="${STORAGE_RECONCILE_MAX_POLLS:-24}"
RECONCILE_POLL_SECONDS="${STORAGE_RECONCILE_POLL_SECONDS:-5}"
METRIC_MAX_POLLS="${STORAGE_METRIC_MAX_POLLS:-12}"
METRIC_POLL_SECONDS="${STORAGE_METRIC_POLL_SECONDS:-5}"
OUT_DIR="${STORAGE_OUT_DIR:-${ROOT_DIR}/.ops-smoke/$(date -u +%Y%m%dT%H%M%SZ)-storage}"
PYTHON_BIN="$(command -v python3 || command -v python || true)"

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${PYTHON_BIN}" ]] || fail "python3 or python is required"
for cmd in kubectl curl git; do command -v "${cmd}" >/dev/null 2>&1 || fail "${cmd} is required"; done
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

wait_for_storage_reconciliation() {
  local expected revision sync health exists attempt
  expected="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
  log "Argo CD storage reconciliation"
  printf '  expected_revision=%s\n' "${expected}"

  for attempt in $(seq 1 "${RECONCILE_MAX_POLLS}"); do
    revision="$(kubectl get application "${ARGO_APP}" -n "${ARGO_NAMESPACE}" -o jsonpath='{.status.sync.revision}' 2>/dev/null || true)"
    sync="$(kubectl get application "${ARGO_APP}" -n "${ARGO_NAMESPACE}" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
    health="$(kubectl get application "${ARGO_APP}" -n "${ARGO_NAMESPACE}" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
    if kubectl get statefulset "${STATEFULSET}" -n "${NAMESPACE}" >/dev/null 2>&1; then exists="yes"; else exists="no"; fi

    printf '  poll %s/%s: revision=%s sync=%s health=%s statefulset=%s\n' \
      "${attempt}" "${RECONCILE_MAX_POLLS}" "${revision:-<none>}" "${sync:-<none>}" "${health:-<none>}" "${exists}"

    if [[ "${revision}" == "${expected}" && "${sync}" == "Synced" && "${health}" == "Healthy" && "${exists}" == "yes" ]]; then
      return 0
    fi

    [[ "${attempt}" == "${RECONCILE_MAX_POLLS}" ]] || sleep "${RECONCILE_POLL_SECONDS}"
  done

  fail "Argo ${ARGO_NAMESPACE}/${ARGO_APP} did not reconcile ${expected} with StatefulSet ${NAMESPACE}/${STATEFULSET}; inspect kubectl -n ${ARGO_NAMESPACE} get application ${ARGO_APP} -o yaml"
}

wait_for_probe_metrics() {
  local attempt probe_json probe_count
  for attempt in $(seq 1 "${METRIC_MAX_POLLS}"); do
    probe_json="$(prom_query storage-probe-usage "storage_probe_usage_ratio{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
    probe_count="$(printf '%s' "${probe_json}" | result_count)"
    printf '  fallback poll %s/%s: storage_probe_usage_ratio series=%s\n' "${attempt}" "${METRIC_MAX_POLLS}" "${probe_count}"
    if [[ "${probe_count}" -gt 0 ]]; then
      printf '%s' "${probe_json}"
      return 0
    fi
    [[ "${attempt}" == "${METRIC_MAX_POLLS}" ]] || sleep "${METRIC_POLL_SECONDS}"
  done
  return 1
}

wait_for_storage_reconciliation

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

log "PVC filesystem usage metrics"
capacity_json="$(prom_query pvc-volume-capacity "kubelet_volume_stats_capacity_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
used_json="$(prom_query pvc-volume-used "kubelet_volume_stats_used_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
available_json="$(prom_query pvc-volume-available "kubelet_volume_stats_available_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
capacity_count="$(printf '%s' "${capacity_json}" | result_count)"
used_count="$(printf '%s' "${used_json}" | result_count)"
available_count="$(printf '%s' "${available_json}" | result_count)"
printf '  kubelet capacity_series=%s used_series=%s available_series=%s\n' "${capacity_count}" "${used_count}" "${available_count}"

if [[ "${capacity_count}" -gt 0 && "${used_count}" -gt 0 && "${available_count}" -gt 0 ]]; then
  metric_source="kubelet_csi"
  ratio_json="$(prom_query pvc-usage-ratio "kubelet_volume_stats_used_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"} / clamp_min(kubelet_volume_stats_capacity_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}, 1)")"
  ratio="$(printf '%s' "${ratio_json}" | scalar_value)"
else
  echo "  standard kubelet/CSI volume stats unavailable; trying deterministic storage-probe fallback"
  if ! ratio_json="$(wait_for_probe_metrics)"; then
    fail "neither kubelet/CSI volume stats nor storage-probe fallback metrics are available"
  fi
  metric_source="storage_probe_fallback"
  ratio="$(printf '%s' "${ratio_json}" | scalar_value)"
  fill_json="$(prom_query storage-probe-fill "storage_probe_fill_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
  requested_probe_json="$(prom_query storage-probe-requested "storage_probe_requested_capacity_bytes{namespace=\"${NAMESPACE}\",persistentvolumeclaim=~\"${PVC_PATTERN}\"}")"
  printf '  fallback fill_bytes=%s requested_capacity_bytes=%s\n' \
    "$(printf '%s' "${fill_json}" | scalar_value)" \
    "$(printf '%s' "${requested_probe_json}" | scalar_value)"
fi

printf '  metric_source=%s usage_ratio=%s\n' "${metric_source}" "${ratio}"
printf '%s\n' "${metric_source}" >"${OUT_DIR}/metric-source.txt"

log "PVC STORAGE SMOKE PASS"
echo "Evidence: ${OUT_DIR}"
