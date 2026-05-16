#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOAD_DIR="${SCRIPT_DIR}/load"
K6_SCRIPT="${K6_SCRIPT:-${LOAD_DIR}/scenarios/auth-success-baseline.k6.js}"
K6_SCRIPT_RELATIVE="${K6_SCRIPT#${LOAD_DIR}/}"
K6_SCRIPT_IN_CONTAINER="/work/load/${K6_SCRIPT_RELATIVE}"

AUTH_BASE_URL="${AUTH_BASE_URL:-http://127.0.0.1:8000}"
LOAD_VUS="${LOAD_VUS:-${K6_VUS:-20}}"
LOAD_DURATION="${LOAD_DURATION:-${K6_DURATION:-2m}}"
LOAD_THINK_TIME_SECONDS="${LOAD_THINK_TIME_SECONDS:-${K6_THINK_TIME_SECONDS:-0.2}}"
LOAD_USER_POOL_SIZE="${LOAD_USER_POOL_SIZE:-${K6_USER_POOL_SIZE:-}}"
LOAD_SETUP_TIMEOUT="${LOAD_SETUP_TIMEOUT:-${K6_SETUP_TIMEOUT:-15m}}"
K6_DOCKER_IMAGE="${K6_DOCKER_IMAGE:-grafana/k6:0.49.0}"

log() {
  printf '[load-auth-burst] %s\n' "$*"
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
log "LOAD_VUS=${LOAD_VUS}"
log "LOAD_DURATION=${LOAD_DURATION}"
log "LOAD_THINK_TIME_SECONDS=${LOAD_THINK_TIME_SECONDS}"
log "LOAD_USER_POOL_SIZE=${LOAD_USER_POOL_SIZE:-auto}"
log "LOAD_SETUP_TIMEOUT=${LOAD_SETUP_TIMEOUT}"
log "K6_DOCKER_IMAGE=${K6_DOCKER_IMAGE}"
log "K6_SCRIPT_IN_CONTAINER=${K6_SCRIPT_IN_CONTAINER}"
log "Using Docker host network for server-local traffic"

exec docker run --rm \
  --network host \
  -v "${LOAD_DIR}:/work/load:ro" \
  -e AUTH_BASE_URL="${AUTH_BASE_URL}" \
  -e AUTH_REGISTER_ENABLED="${AUTH_REGISTER_ENABLED:-true}" \
  -e AUTH_EMAIL="${AUTH_EMAIL:-}" \
  -e AUTH_PASSWORD="${AUTH_PASSWORD:-}" \
  -e AUTH_DEFAULT_ROLE="${AUTH_DEFAULT_ROLE:-parent}" \
  -e LOAD_VUS="${LOAD_VUS}" \
  -e LOAD_DURATION="${LOAD_DURATION}" \
  -e LOAD_THINK_TIME_SECONDS="${LOAD_THINK_TIME_SECONDS}" \
  -e LOAD_USER_POOL_SIZE="${LOAD_USER_POOL_SIZE}" \
  -e LOAD_SETUP_TIMEOUT="${LOAD_SETUP_TIMEOUT}" \
  "${K6_DOCKER_IMAGE}" \
  run "${K6_SCRIPT_IN_CONTAINER}"
