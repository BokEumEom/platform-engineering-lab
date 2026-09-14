#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_ROOT="${OUT_ROOT:-${ROOT_DIR}/.ops-smoke/${RUN_ID}-full}"

mkdir -p "${OUT_ROOT}"

OUT_DIR="${OUT_ROOT}/platform" \
  bash "${ROOT_DIR}/ops/smoke/reference-environment.sh"

OBS_OUT_DIR="${OUT_ROOT}/observability" \
  bash "${ROOT_DIR}/ops/smoke/observability.sh"

OPS_REVIEW_FILE="${OUT_ROOT}/platform/review.json" \
LOKI_EVIDENCE_FILE="${OUT_ROOT}/observability/loki-evidence.json" \
TEMPO_EVIDENCE_FILE="${OUT_ROOT}/observability/tempo-evidence.json" \
MULTISIGNAL_OUTPUT_FILE="${OUT_ROOT}/observability/multi-signal-review.json" \
  bash "${ROOT_DIR}/ops/smoke/multisignal-correlation.sh"

printf '\nFULL REFERENCE ENVIRONMENT SMOKE PASS\n'
printf 'Evidence: %s\n' "${OUT_ROOT}"
