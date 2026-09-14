#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HARNESS_DIR="${HARNESS_DIR:-$(cd "${ROOT_DIR}/../infrastructure-engineering-harness" 2>/dev/null && pwd || true)}"
OPS_REVIEW_FILE="${OPS_REVIEW_FILE:-}"
LOKI_EVIDENCE_FILE="${LOKI_EVIDENCE_FILE:-}"
TEMPO_EVIDENCE_FILE="${TEMPO_EVIDENCE_FILE:-}"
OUTPUT_FILE="${MULTISIGNAL_OUTPUT_FILE:-${ROOT_DIR}/.ops-smoke/multi-signal-review.json}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${HARNESS_DIR}" && -f "${HARNESS_DIR}/scripts/multisignal_review.py" ]] || fail "Harness multi-signal review CLI not found"
[[ -f "${OPS_REVIEW_FILE}" ]] || fail "Ops review evidence not found: ${OPS_REVIEW_FILE}"
[[ -f "${LOKI_EVIDENCE_FILE}" ]] || fail "Loki evidence not found: ${LOKI_EVIDENCE_FILE}"
[[ -f "${TEMPO_EVIDENCE_FILE}" ]] || fail "Tempo evidence not found: ${TEMPO_EVIDENCE_FILE}"

PYTHON_BIN="$(command -v python3 || command -v python || true)"
[[ -n "${PYTHON_BIN}" ]] || fail "python3 or python is required"

"${PYTHON_BIN}" "${HARNESS_DIR}/scripts/multisignal_review.py" \
  --ops-review "${OPS_REVIEW_FILE}" \
  --loki "${LOKI_EVIDENCE_FILE}" \
  --tempo "${TEMPO_EVIDENCE_FILE}" \
  --output "${OUTPUT_FILE}"

"${PYTHON_BIN}" - "${OUTPUT_FILE}" <<'PY'
import json,sys
from pathlib import Path
p=json.loads(Path(sys.argv[1]).read_text())
print(f"  status={p.get('status')}")
print(f"  correlation_count={p.get('correlation_count')}")
print(f"  decision_effect={p.get('decision_effect')}")
print(f"  ops_state={p.get('ops_state')} release_guidance={p.get('release_guidance')}")
if p.get("decision_effect") != "enrichment_only":
    raise SystemExit("multi-signal evidence must not mutate the base Ops decision")
if int(p.get("correlation_count") or 0) < 1:
    raise SystemExit("no Loki trace_id matched a Tempo trace")
if p.get("source_unavailable"):
    raise SystemExit(f"source unavailable: {p['source_unavailable']}")
PY

echo "MULTI-SIGNAL CORRELATION PASS"
