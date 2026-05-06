#!/usr/bin/env bash
set -euo pipefail

AUTH_BASE_URL="${AUTH_BASE_URL:-http://127.0.0.1:8000}"
USERS_BASE_URL="${USERS_BASE_URL:-http://127.0.0.1:8002}"
USERS_CONTAINER_NAME="${USERS_CONTAINER_NAME:-curs_users_service}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin12345}"
CHAOS_ITERATIONS="${CHAOS_ITERATIONS:-30}"
CHAOS_INTERVAL_SECONDS="${CHAOS_INTERVAL_SECONDS:-1}"
CHAOS_RESTART_AT_ITERATION="${CHAOS_RESTART_AT_ITERATION:-10}"
SESSION_PREFIX="${SESSION_PREFIX:-chaos-users-restart}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

login_success=0
login_fail=0
me_success=0
me_fail=0
users_success=0
users_fail=0
users_post_restart_success=0
auth_post_restart_success=0
restart_triggered=0
restart_completed=0

log() {
  printf '[chaos-users-restart] %s\n' "$*"
}

json_get() {
  local file="$1"
  local expr="$2"
  python3 - "$file" "$expr" <<'PY'
import json
import sys

path = sys.argv[2].split(".")
value = json.load(open(sys.argv[1], "r", encoding="utf-8"))
for part in path:
    if isinstance(value, dict):
        value = value.get(part)
    elif isinstance(value, list):
        try:
            value = value[int(part)]
        except Exception:
            value = None
    else:
        value = None
    if value is None:
        break
if value is None:
    sys.exit(1)
if isinstance(value, (dict, list)):
    print(json.dumps(value, ensure_ascii=False))
else:
    print(value)
PY
}

login_admin() {
  local iter="$1"
  local out_file="$2"
  local body_file="${TMP_DIR}/login-${iter}.json"
  cat >"${body_file}" <<JSON
{
  "email": "${ADMIN_EMAIL}",
  "password": "${ADMIN_PASSWORD}",
  "session_fingerprint": "${SESSION_PREFIX}-${iter}"
}
JSON
  curl -sS -o "${out_file}" -w '%{http_code}' \
    -X POST "${AUTH_BASE_URL}/v1/auth/login" \
    -H "Content-Type: application/json" \
    --data-binary "@${body_file}"
}

probe_me() {
  local token="$1"
  local out_file="$2"
  curl -sS -o "${out_file}" -w '%{http_code}' \
    -X GET "${AUTH_BASE_URL}/v1/auth/me" \
    -H "Authorization: Bearer ${token}"
}

probe_users_admin_list() {
  local token="$1"
  local out_file="$2"
  curl -sS -o "${out_file}" -w '%{http_code}' \
    -X GET "${USERS_BASE_URL}/v1/admin/users?limit=1&offset=0" \
    -H "Authorization: Bearer ${token}"
}

probe_users_health() {
  local out_file="$1"
  curl -sS -o "${out_file}" -w '%{http_code}' \
    -X GET "${USERS_BASE_URL}/healthz"
}

if ! command -v curl >/dev/null 2>&1; then
  log "ERROR curl is required"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  log "ERROR python3 is required"
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  log "ERROR docker is required"
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  log "ERROR docker daemon is not available"
  exit 1
fi

if (( CHAOS_RESTART_AT_ITERATION < 1 || CHAOS_RESTART_AT_ITERATION > CHAOS_ITERATIONS )); then
  log "ERROR CHAOS_RESTART_AT_ITERATION must be between 1 and CHAOS_ITERATIONS"
  exit 1
fi

log "AUTH_BASE_URL=${AUTH_BASE_URL}"
log "USERS_BASE_URL=${USERS_BASE_URL}"
log "USERS_CONTAINER_NAME=${USERS_CONTAINER_NAME}"
log "CHAOS_ITERATIONS=${CHAOS_ITERATIONS}"
log "CHAOS_INTERVAL_SECONDS=${CHAOS_INTERVAL_SECONDS}"
log "CHAOS_RESTART_AT_ITERATION=${CHAOS_RESTART_AT_ITERATION}"

for ((i = 1; i <= CHAOS_ITERATIONS; i++)); do
  phase="before-restart"
  if (( restart_completed == 1 )); then
    phase="after-restart"
  fi

  if (( i == CHAOS_RESTART_AT_ITERATION )); then
    log "Restarting ${USERS_CONTAINER_NAME}"
    restart_triggered=1
    docker restart "${USERS_CONTAINER_NAME}" >/dev/null
    restart_completed=1
    phase="after-restart"
    log "Restart completed"
  fi

  login_out="${TMP_DIR}/login-${i}.out.json"
  login_status="$(login_admin "${i}" "${login_out}" || true)"
  if [[ "${login_status}" =~ ^2 ]]; then
    login_success=$((login_success + 1))
    if (( restart_completed == 1 )); then
      auth_post_restart_success=$((auth_post_restart_success + 1))
    fi

    access_token="$(json_get "${login_out}" "access_token" 2>/dev/null || true)"
    if [[ -z "${access_token}" ]]; then
      me_fail=$((me_fail + 1))
      users_fail=$((users_fail + 1))
      log "iter=${i} phase=${phase} login succeeded but access_token is empty"
      sleep "${CHAOS_INTERVAL_SECONDS}"
      continue
    fi

    me_out="${TMP_DIR}/me-${i}.out.json"
    me_status="$(probe_me "${access_token}" "${me_out}" || true)"
    if [[ "${me_status}" == "200" ]]; then
      me_success=$((me_success + 1))
    else
      me_fail=$((me_fail + 1))
      detail="$(cat "${me_out}" 2>/dev/null || true)"
      log "iter=${i} phase=${phase} me_status=${me_status} body=${detail}"
    fi

    users_out="${TMP_DIR}/users-${i}.out.json"
    users_status="$(probe_users_admin_list "${access_token}" "${users_out}" || true)"
    if [[ "${users_status}" == "200" ]]; then
      users_success=$((users_success + 1))
      if (( restart_completed == 1 )); then
        users_post_restart_success=$((users_post_restart_success + 1))
      fi
    else
      users_fail=$((users_fail + 1))
      detail="$(cat "${users_out}" 2>/dev/null || true)"
      log "iter=${i} phase=${phase} users_status=${users_status} body=${detail}"
    fi
  else
    login_fail=$((login_fail + 1))
    detail="$(cat "${login_out}" 2>/dev/null || true)"
    log "iter=${i} phase=${phase} login_status=${login_status} body=${detail}"
  fi

  if (( restart_completed == 1 )); then
    health_out="${TMP_DIR}/users-health-${i}.out.txt"
    health_status="$(probe_users_health "${health_out}" || true)"
    if [[ "${health_status}" != "200" ]]; then
      detail="$(cat "${health_out}" 2>/dev/null || true)"
      log "iter=${i} phase=${phase} users_health_status=${health_status} body=${detail}"
    fi
  fi

  sleep "${CHAOS_INTERVAL_SECONDS}"
done

log "Summary"
log "restart_triggered=${restart_triggered}"
log "login_success=${login_success}"
log "login_fail=${login_fail}"
log "me_success=${me_success}"
log "me_fail=${me_fail}"
log "users_success=${users_success}"
log "users_fail=${users_fail}"
log "auth_post_restart_success=${auth_post_restart_success}"
log "users_post_restart_success=${users_post_restart_success}"

if (( auth_post_restart_success == 0 )); then
  log "RESULT auth did not stay available while users_service was restarting"
  exit 1
fi

if (( users_post_restart_success == 0 )); then
  log "RESULT auth stayed available, but users_service did not recover within drill window"
  exit 2
fi

log "RESULT auth stayed available and users recovered after users_service restart"
