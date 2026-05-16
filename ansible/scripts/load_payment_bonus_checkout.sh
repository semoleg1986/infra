#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

K6_SCRIPT="${SCRIPT_DIR}/load/scenarios/payment-bonus-checkout.k6.js" \
K6_BONUS_ENABLED="${K6_BONUS_ENABLED:-1}" \
K6_BONUS_AMOUNT="${K6_BONUS_AMOUNT:-30}" \
"${SCRIPT_DIR}/load_payment_access_progress.sh"
