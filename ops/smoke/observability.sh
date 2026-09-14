#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$(cd "${ROOT_DIR}/../infrastructure-engineering-harness" 2>/dev/null && pwd || true)}"
GATEWAY_URL="${OBS_GATEWAY_URL:-http://127.0.0.1:8080}"
LOKI_HOST="${LOKI_HOST:-loki.lab.local}"
TEMPO_HOST="${TEMPO_HOST:-tempo.lab.local}"
ALERTMANAGER_HOST="${ALERTMANAGER_HOST:-alertmanager.lab.local}"
PROM_HOST="${PROM_HOST:-prometheus.lab.local}"
HTTPS_GATEWAY_IP="${HTTPS_GATEWAY_IP:-127.0.0.1}"
HTTPS_GATEWAY_PORT="${HTTPS_GATEWAY_PORT:-8443}"
OBS_MAX_POLLS="${OBS_MAX_POLLS:-12}"
OBS_POLL_SECONDS="${OBS_POLL_SECONDS:-10}"
OUT_DIR="${OBS_OUT_DIR:-${ROOT_DIR}/.ops-smoke/$(date -u +%Y%m%dT%H%M%SZ)-observability}"
PYTHON_BIN=""

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"; }

resolve_python() {
  if command -v python3 >/dev/null 2>&1; then command -v python3; return; fi
  if command -v python >/dev/null 2>&1; then command -v python; return; fi
  fail "python3 or python is required"
}

api_get() {
  local host="$1" path="$2"
  curl -fsS -H "Host: ${host}" "${GATEWAY_URL}${path}"
}

https_status() {
  local host="$1"
  curl -k -sS -o /dev/null -w '%{http_code}' \
    --resolve "${host}:${HTTPS_GATEWAY_PORT}:${HTTPS_GATEWAY_IP}" \
    "https://${host}:${HTTPS_GATEWAY_PORT}/" || true
}

assert_route() {
  local route="$1" payload summary rc
  payload="$(kubectl get httproute "${route}" -n monitoring -o json)"
  set +e
  summary="$(printf '%s' "${payload}" | "${PYTHON_BIN}" -c '
import json,sys
obj=json.load(sys.stdin)
parents=(obj.get("status") or {}).get("parents") or []
healthy=0
for parent in parents:
    c={x.get("type"): x.get("status") for x in (parent.get("conditions") or [])}
    healthy += int(c.get("Accepted")=="True" and c.get("ResolvedRefs")=="True")
print(f"healthyParents={healthy}/{len(parents)}")
raise SystemExit(0 if parents and healthy == len(parents) else 1)
')"
  rc=$?
  set -e
  printf '  %-24s %s\n' "${route}" "${summary}"
  [[ "${rc}" -eq 0 ]] || fail "HTTPRoute monitoring/${route} is not Accepted/ResolvedRefs"
}

loki_entry_count() {
  "${PYTHON_BIN}" -c '
import json,sys
p=json.load(sys.stdin)
result=((p.get("data") or {}).get("result") or [])
print(sum(len(stream.get("values") or []) for stream in result))
'
}

tempo_trace_count() {
  "${PYTHON_BIN}" -c '
import json,sys
p=json.load(sys.stdin)
print(len(p.get("traces") or []))
'
}

main() {
  for cmd in kubectl curl; do require_cmd "${cmd}"; done
  PYTHON_BIN="$(resolve_python)"
  mkdir -p "${OUT_DIR}"

  log "Observability Gateway routes"
  for route in loki-agent loki tempo-agent tempo alertmanager-agent alertmanager; do
    assert_route "${route}"
  done

  log "Observability HTTPS endpoints"
  for host in "${LOKI_HOST}" "${TEMPO_HOST}" "${ALERTMANAGER_HOST}"; do
    code="$(https_status "${host}")"
    printf '  %-28s HTTP %s\n' "${host}" "${code}"
    [[ "${code}" =~ ^[234][0-9][0-9]$ ]] || fail "unexpected HTTPS Gateway response for ${host}: ${code}"
  done

  log "Loki API through MetalLB/Envoy"
  api_get "${LOKI_HOST}" "/loki/api/v1/labels" | tee "${OUT_DIR}/loki-labels.json" >/dev/null
  "${PYTHON_BIN}" - "${OUT_DIR}/loki-labels.json" <<'PY'
import json,sys
from pathlib import Path
p=json.loads(Path(sys.argv[1]).read_text())
raise SystemExit(0 if p.get("status")=="success" else 1)
PY
  echo "  Loki labels API: success"

  log "Tempo API through MetalLB/Envoy"
  api_get "${TEMPO_HOST}" "/ready" | tee "${OUT_DIR}/tempo-ready.txt"

  log "Alertmanager API through MetalLB/Envoy"
  api_get "${ALERTMANAGER_HOST}" "/api/v2/status" | tee "${OUT_DIR}/alertmanager-status.json" >/dev/null
  "${PYTHON_BIN}" - "${OUT_DIR}/alertmanager-status.json" <<'PY'
import json,sys
from pathlib import Path
p=json.loads(Path(sys.argv[1]).read_text())
raise SystemExit(0 if isinstance(p, dict) and p else 1)
PY
  echo "  Alertmanager status API: success"

  log "Generating traceable application traffic"
  ok=0
  for _ in $(seq 1 30); do
    code="$(curl -k -sS -o /dev/null -w '%{http_code}' --resolve web.lab.local:8443:127.0.0.1 https://web.lab.local:8443/ || true)"
    [[ "${code}" == "200" ]] && ok=$((ok + 1))
    sleep 0.1
  done
  printf '  successful requests: %s/30\n' "${ok}"
  [[ "${ok}" == "30" ]] || fail "application traffic failed during observability smoke"

  log "Waiting for Loki application logs"
  loki_ok=0
  for attempt in $(seq 1 "${OBS_MAX_POLLS}"); do
    now_ns="$(${PYTHON_BIN} -c 'import time; print(time.time_ns())')"
    start_ns="$(${PYTHON_BIN} - "${now_ns}" <<'PY'
import sys
print(int(sys.argv[1]) - 15*60*1_000_000_000)
PY
)"
    loki_json="$(curl -fsS -G -H "Host: ${LOKI_HOST}" \
      --data-urlencode 'query={namespace="demo-app"}' \
      --data-urlencode "start=${start_ns}" \
      --data-urlencode "end=${now_ns}" \
      --data-urlencode 'limit=100' \
      --data-urlencode 'direction=backward' \
      "${GATEWAY_URL}/loki/api/v1/query_range")"
    printf '%s\n' "${loki_json}" >"${OUT_DIR}/loki-demo-app.json"
    count="$(printf '%s' "${loki_json}" | loki_entry_count)"
    printf '  poll %s/%s: log entries=%s\n' "${attempt}" "${OBS_MAX_POLLS}" "${count}"
    if [[ "${count}" -gt 0 ]]; then loki_ok=1; break; fi
    [[ "${attempt}" == "${OBS_MAX_POLLS}" ]] || sleep "${OBS_POLL_SECONDS}"
  done
  [[ "${loki_ok}" == "1" ]] || fail "Loki did not expose demo-app logs; inspect ${OUT_DIR}"

  log "Waiting for Tempo traces"
  tempo_ok=0
  for attempt in $(seq 1 "${OBS_MAX_POLLS}"); do
    end_s="$(date +%s)"
    start_s="$((end_s - 900))"
    tempo_json="$(curl -fsS -G -H "Host: ${TEMPO_HOST}" \
      --data-urlencode "start=${start_s}" \
      --data-urlencode "end=${end_s}" \
      --data-urlencode 'limit=20' \
      "${GATEWAY_URL}/api/search")"
    printf '%s\n' "${tempo_json}" >"${OUT_DIR}/tempo-search.json"
    count="$(printf '%s' "${tempo_json}" | tempo_trace_count)"
    printf '  poll %s/%s: traces=%s\n' "${attempt}" "${OBS_MAX_POLLS}" "${count}"
    if [[ "${count}" -gt 0 ]]; then tempo_ok=1; break; fi
    [[ "${attempt}" == "${OBS_MAX_POLLS}" ]] || sleep "${OBS_POLL_SECONDS}"
  done
  [[ "${tempo_ok}" == "1" ]] || fail "Tempo did not expose recent traces; inspect ${OUT_DIR}"

  log "Alert signal visibility"
  curl -fsS -G -H "Host: ${PROM_HOST}" \
    --data-urlencode 'query=count(ALERTS{alertstate="firing"}) or vector(0)' \
    "${GATEWAY_URL}/api/v1/query" \
    | tee "${OUT_DIR}/firing-alerts.json" >/dev/null
  "${PYTHON_BIN}" - "${OUT_DIR}/firing-alerts.json" <<'PY'
import json,sys
from pathlib import Path
p=json.loads(Path(sys.argv[1]).read_text())
r=((p.get("data") or {}).get("result") or [])
value=r[0].get("value", [None, "?"])[1] if r else "?"
print(f"  firing alerts visible to Prometheus: {value}")
raise SystemExit(0 if p.get("status")=="success" else 1)
PY

  if [[ -n "${HARNESS_DIR}" && -f "${HARNESS_DIR}/scripts/loki_evidence.py" && -f "${HARNESS_DIR}/scripts/tempo_evidence.py" ]]; then
    log "Harness multi-signal read-only evidence"
    "${PYTHON_BIN}" "${HARNESS_DIR}/scripts/loki_evidence.py" \
      --url "${GATEWAY_URL}" \
      --host-header "${LOKI_HOST}" \
      --query-file "${ROOT_DIR}/observability/agent-loki-queries.json" \
      --lookback-seconds 900 \
      --output "${OUT_DIR}/loki-evidence.json"
    "${PYTHON_BIN}" "${HARNESS_DIR}/scripts/tempo_evidence.py" \
      --url "${GATEWAY_URL}" \
      --host-header "${TEMPO_HOST}" \
      --search-file "${ROOT_DIR}/observability/agent-tempo-searches.json" \
      --lookback-seconds 900 \
      --trace-id-file "${OUT_DIR}/loki-evidence.json" \
      --max-trace-ids 20 \
      --output "${OUT_DIR}/tempo-evidence.json"
    "${PYTHON_BIN}" - "${OUT_DIR}/loki-evidence.json" "${OUT_DIR}/tempo-evidence.json" <<'PY'
import json,sys
from pathlib import Path
loki=json.loads(Path(sys.argv[1]).read_text())
tempo=json.loads(Path(sys.argv[2]).read_text())
unavailable=[o.get("id") for b in (loki,tempo) for o in b.get("observations",[]) if o.get("status")=="unavailable"]
log_entries=sum(int((o.get("value") or {}).get("entry_count") or 0) for o in loki.get("observations",[]))
trace_count=sum(int((o.get("value") or {}).get("trace_count") or 0) for o in tempo.get("observations",[]))
exact_observed=sum(1 for o in tempo.get("observations",[]) if o.get("signal")=="trace_by_id" and o.get("status")=="observed")
exact_not_found=sum(1 for o in tempo.get("observations",[]) if o.get("signal")=="trace_by_id" and o.get("status")=="not_found")
requested=(tempo.get("scope") or {}).get("exact_trace_ids_requested",0)
print(f"  Harness Loki entries={log_entries}")
print(f"  Harness Tempo search traces={trace_count}")
print(f"  exact Tempo follow-up: requested={requested} observed={exact_observed} not_found={exact_not_found}")
print(f"  unavailable={unavailable}")
raise SystemExit(0 if not unavailable and log_entries > 0 and trace_count > 0 and exact_observed > 0 else 1)
PY
  else
    log "Harness Loki/Tempo evidence CLI not found; skipped adapter smoke"
  fi

  log "MULTI-SIGNAL OBSERVABILITY SMOKE PASS"
  echo "Evidence: ${OUT_DIR}"
}

main "$@"
