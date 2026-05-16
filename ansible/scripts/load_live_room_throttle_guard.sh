#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_DIR="${SCRIPT_DIR}/load"

export K6_SCRIPT="${K6_SCRIPT:-${LOAD_DIR}/scenarios/live-room-throttle-guard.k6.js}"

exec "${SCRIPT_DIR}/load_live_room_burst.sh"
