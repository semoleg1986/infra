#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

K6_SCRIPT="${SCRIPT_DIR}/load/scenarios/payment-throttle-guard.k6.js" \
"${SCRIPT_DIR}/load_payment_access_progress.sh"
