#!/usr/bin/env bash
set -euo pipefail

# Minimal production observability baseline check:
# 1) Disk usage threshold
# 2) Docker container state/health
# 3) HTTP health endpoints
# 4) Recent 5xx pattern in service logs
#
# Exit code:
#   0 = all checks passed
#   1 = at least one check failed (use in cron/monitoring)

DISK_WARN_PCT="${DISK_WARN_PCT:-90}"
DISK_CRIT_PCT="${DISK_CRIT_PCT:-95}"
LOG_TAIL_LINES="${LOG_TAIL_LINES:-400}"
LOG_5XX_WARN_COUNT="${LOG_5XX_WARN_COUNT:-5}"

DOCKER_PREFIX="${DOCKER_PREFIX:-curs_}"

AUTH_BASE_URL="${AUTH_BASE_URL:-http://127.0.0.1:8000/healthz}"
USERS_BASE_URL="${USERS_BASE_URL:-http://127.0.0.1:8002/healthz}"
COURSE_BASE_URL="${COURSE_BASE_URL:-http://127.0.0.1:8001/healthz}"
ATTR_BASE_URL="${ATTR_BASE_URL:-http://127.0.0.1:8003/healthz}"
PAYMENTS_BASE_URL="${PAYMENTS_BASE_URL:-http://127.0.0.1:8004/healthz}"
BONUS_BASE_URL="${BONUS_BASE_URL:-http://127.0.0.1:8006/healthz}"
LIVE_BASE_URL="${LIVE_BASE_URL:-http://127.0.0.1:8010/healthz}"
WEB_BASE_URL="${WEB_BASE_URL:-http://127.0.0.1:3000/api/health}"
ADMIN_BASE_URL="${ADMIN_BASE_URL:-http://127.0.0.1:3001/api/health}"
STUDIO_BASE_URL="${STUDIO_BASE_URL:-http://127.0.0.1:3002/api/health}"

failed=0

log() {
  printf '[ops-check] %s\n' "$*"
}

warn() {
  printf '[ops-check][WARN] %s\n' "$*"
}

err() {
  printf '[ops-check][ERROR] %s\n' "$*"
}

check_disk() {
  local used_pct
  used_pct="$(df --output=pcent / | tail -1 | tr -dc '0-9')"
  log "disk usage on / = ${used_pct}%"
  if (( used_pct >= DISK_CRIT_PCT )); then
    err "disk usage is CRITICAL (>= ${DISK_CRIT_PCT}%)"
    failed=1
  elif (( used_pct >= DISK_WARN_PCT )); then
    warn "disk usage is high (>= ${DISK_WARN_PCT}%)"
  fi
}

check_containers() {
  log "checking docker container states"
  mapfile -t lines < <(docker ps -a --format '{{.Names}}|{{.Status}}' | grep "^${DOCKER_PREFIX}" || true)
  if [[ "${#lines[@]}" -eq 0 ]]; then
    err "no containers with prefix ${DOCKER_PREFIX} found"
    failed=1
    return
  fi

  local name status
  for row in "${lines[@]}"; do
    name="${row%%|*}"
    status="${row#*|}"
    if [[ "${status}" != Up* ]]; then
      err "${name} not running: ${status}"
      failed=1
      continue
    fi
    if [[ "${status}" == *"(unhealthy)"* ]]; then
      err "${name} unhealthy: ${status}"
      failed=1
    fi
  done
}

check_http() {
  log "checking HTTP health endpoints"
  local url code
  for url in \
    "${AUTH_BASE_URL}" \
    "${USERS_BASE_URL}" \
    "${COURSE_BASE_URL}" \
    "${ATTR_BASE_URL}" \
    "${PAYMENTS_BASE_URL}" \
    "${BONUS_BASE_URL}" \
    "${LIVE_BASE_URL}" \
    "${WEB_BASE_URL}" \
    "${ADMIN_BASE_URL}" \
    "${STUDIO_BASE_URL}"; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' "${url}" || true)"
    if [[ "${code}" != "200" && "${code}" != "204" ]]; then
      err "health check failed: ${url} -> HTTP ${code}"
      failed=1
    fi
  done
}

check_recent_5xx() {
  log "checking recent 5xx patterns in logs"
  local service count
  for service in \
    "${DOCKER_PREFIX}auth_service" \
    "${DOCKER_PREFIX}users_service" \
    "${DOCKER_PREFIX}course_service" \
    "${DOCKER_PREFIX}attribution_service" \
    "${DOCKER_PREFIX}payments_service" \
    "${DOCKER_PREFIX}bonus_wallet_service" \
    "${DOCKER_PREFIX}live_class_service" \
    "${DOCKER_PREFIX}web_app" \
    "${DOCKER_PREFIX}admin_app" \
    "${DOCKER_PREFIX}studio_app"; do
    if ! docker ps -a --format '{{.Names}}' | grep -q "^${service}$"; then
      continue
    fi
    count="$(docker logs --tail "${LOG_TAIL_LINES}" "${service}" 2>&1 | grep -Ec 'HTTP/[0-9.]*" 5[0-9]{2}| 5[0-9]{2} |Internal Server Error|Traceback' || true)"
    if (( count >= LOG_5XX_WARN_COUNT )); then
      warn "${service} has ${count} potential 5xx/error patterns in last ${LOG_TAIL_LINES} log lines"
    fi
  done
}

main() {
  check_disk
  check_containers
  check_http
  check_recent_5xx

  if (( failed != 0 )); then
    err "FAILED"
    exit 1
  fi
  log "OK"
}

main "$@"
