#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOAD_BONUS_ENABLED="${LOAD_BONUS_ENABLED:-${K6_BONUS_ENABLED:-1}}" \
LOAD_BONUS_AMOUNT="${LOAD_BONUS_AMOUNT:-${K6_BONUS_AMOUNT:-30}}" \
"${SCRIPT_DIR}/load_payment_access_progress.sh"
