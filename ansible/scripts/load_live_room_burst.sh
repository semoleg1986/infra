#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_DIR="${SCRIPT_DIR}/load"
K6_SCRIPT="${LOAD_DIR}/live-room-burst.k6.js"

AUTH_BASE_URL="${AUTH_BASE_URL:-http://127.0.0.1:8000}"
USERS_BASE_URL="${USERS_BASE_URL:-http://127.0.0.1:8002}"
COURSE_BASE_URL="${COURSE_BASE_URL:-http://127.0.0.1:8001}"
PAYMENTS_BASE_URL="${PAYMENTS_BASE_URL:-http://127.0.0.1:8004}"
LIVE_BASE_URL="${LIVE_BASE_URL:-http://127.0.0.1:8010}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin12345}"
PARENT_PASSWORD="${PARENT_PASSWORD:-parent12345}"
STUDENT_PASSWORD="${STUDENT_PASSWORD:-student12345}"
SERVICE_TOKEN="${SERVICE_TOKEN:-sometokencourse}"
K6_VUS="${K6_VUS:-10}"
K6_DURATION="${K6_DURATION:-2m}"
K6_THINK_TIME_SECONDS="${K6_THINK_TIME_SECONDS:-0.2}"
K6_USER_POOL_SIZE="${K6_USER_POOL_SIZE:-}"
K6_ROOM_POOL_SIZE="${K6_ROOM_POOL_SIZE:-}"
K6_SETUP_TIMEOUT="${K6_SETUP_TIMEOUT:-20m}"
K6_DOCKER_IMAGE="${K6_DOCKER_IMAGE:-grafana/k6:0.49.0}"

log() {
  printf '[load-live-room-burst] %s\n' "$*"
}

if ! command -v docker >/dev/null 2>&1; then
  log "ERROR docker is required"
  exit 1
fi

if [[ ! -f "${K6_SCRIPT}" ]]; then
  log "ERROR k6 script not found: ${K6_SCRIPT}"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  log "ERROR docker daemon is not available"
  exit 1
fi

log "AUTH_BASE_URL=${AUTH_BASE_URL}"
log "USERS_BASE_URL=${USERS_BASE_URL}"
log "COURSE_BASE_URL=${COURSE_BASE_URL}"
log "PAYMENTS_BASE_URL=${PAYMENTS_BASE_URL}"
log "LIVE_BASE_URL=${LIVE_BASE_URL}"
log "K6_VUS=${K6_VUS}"
log "K6_DURATION=${K6_DURATION}"
log "K6_THINK_TIME_SECONDS=${K6_THINK_TIME_SECONDS}"
log "K6_USER_POOL_SIZE=${K6_USER_POOL_SIZE:-auto}"
log "K6_ROOM_POOL_SIZE=${K6_ROOM_POOL_SIZE:-auto}"
log "K6_SETUP_TIMEOUT=${K6_SETUP_TIMEOUT}"
log "K6_DOCKER_IMAGE=${K6_DOCKER_IMAGE}"
log "Using Docker host network for server-local traffic"

exec docker run --rm \
  --network host \
  -v "${LOAD_DIR}:/work/load:ro" \
  -e AUTH_BASE_URL="${AUTH_BASE_URL}" \
  -e USERS_BASE_URL="${USERS_BASE_URL}" \
  -e COURSE_BASE_URL="${COURSE_BASE_URL}" \
  -e PAYMENTS_BASE_URL="${PAYMENTS_BASE_URL}" \
  -e LIVE_BASE_URL="${LIVE_BASE_URL}" \
  -e ADMIN_EMAIL="${ADMIN_EMAIL}" \
  -e ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
  -e PARENT_PASSWORD="${PARENT_PASSWORD}" \
  -e STUDENT_PASSWORD="${STUDENT_PASSWORD}" \
  -e SERVICE_TOKEN="${SERVICE_TOKEN}" \
  -e K6_VUS="${K6_VUS}" \
  -e K6_DURATION="${K6_DURATION}" \
  -e K6_THINK_TIME_SECONDS="${K6_THINK_TIME_SECONDS}" \
  -e K6_USER_POOL_SIZE="${K6_USER_POOL_SIZE}" \
  -e K6_ROOM_POOL_SIZE="${K6_ROOM_POOL_SIZE}" \
  -e K6_SETUP_TIMEOUT="${K6_SETUP_TIMEOUT}" \
  "${K6_DOCKER_IMAGE}" \
  run /work/load/live-room-burst.k6.js
