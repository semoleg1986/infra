#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

K6_SCRIPT="${SCRIPT_DIR}/load/scenarios/auth-throttle-guard.k6.js" \
K6_VUS="${K6_VUS:-20}" \
K6_DURATION="${K6_DURATION:-2m}" \
"${SCRIPT_DIR}/load_auth_burst.sh"
