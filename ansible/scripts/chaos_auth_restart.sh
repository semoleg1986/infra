#!/usr/bin/env bash
set -euo pipefail

AUTH_BASE_URL="${AUTH_BASE_URL:-http://127.0.0.1:8000}"
USERS_BASE_URL="${USERS_BASE_URL:-http://127.0.0.1:8002}"
AUTH_CONTAINER_NAME="${AUTH_CONTAINER_NAME:-curs_auth_service}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin12345}"
CHAOS_ITERATIONS="${CHAOS_ITERATIONS:-30}"
CHAOS_INTERVAL_SECONDS="${CHAOS_INTERVAL_SECONDS:-1}"
CHAOS_RESTART_AT_ITERATION="${CHAOS_RESTART_AT_ITERATION:-10}"
SESSION_PREFIX="${SESSION_PREFIX:-chaos-auth-restart}"

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
  printf '[chaos-auth-restart] %s\n' "$*"
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

fetch_jwks_kid() {
  local out_file="$1"
  if ! curl -sS --max-time 5 "${AUTH_BASE_URL}/.well-known/jwks.json" >"${out_file}" 2>/dev/null; then
    return 1
  fi
  json_get "${out_file}" "keys.0.kid"
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
log "AUTH_CONTAINER_NAME=${AUTH_CONTAINER_NAME}"
log "CHAOS_ITERATIONS=${CHAOS_ITERATIONS}"
log "CHAOS_INTERVAL_SECONDS=${CHAOS_INTERVAL_SECONDS}"
log "CHAOS_RESTART_AT_ITERATION=${CHAOS_RESTART_AT_ITERATION}"

pre_kid="${TMP_DIR}/jwks-before.json"
post_kid="${TMP_DIR}/jwks-after.json"
before_kid="$(fetch_jwks_kid "${pre_kid}" 2>/dev/null || true)"
if [[ -n "${before_kid}" ]]; then
  log "Initial JWKS kid=${before_kid}"
else
  log "Initial JWKS kid=<unavailable>"
fi

for ((i = 1; i <= CHAOS_ITERATIONS; i++)); do
  phase="before-restart"
  if (( restart_completed == 1 )); then
    phase="after-restart"
  fi

  if (( i == CHAOS_RESTART_AT_ITERATION )); then
    log "Restarting ${AUTH_CONTAINER_NAME}"
    restart_triggered=1
    docker restart "${AUTH_CONTAINER_NAME}" >/dev/null
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
    if [[ -n "${access_token}" ]]; then
      me_out="${TMP_DIR}/me-${i}.out.json"
      me_status="$(probe_me "${access_token}" "${me_out}" || true)"
      if [[ "${me_status}" == "200" ]]; then
        me_success=$((me_success + 1))
      else
        me_fail=$((me_fail + 1))
        log "iter=${i} phase=${phase} me_status=${me_status}"
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
      me_fail=$((me_fail + 1))
      users_fail=$((users_fail + 1))
      log "iter=${i} phase=${phase} login succeeded but access_token is empty"
    fi
  else
    login_fail=$((login_fail + 1))
    detail="$(cat "${login_out}" 2>/dev/null || true)"
    log "iter=${i} phase=${phase} login_status=${login_status} body=${detail}"
  fi

  sleep "${CHAOS_INTERVAL_SECONDS}"
done

after_kid="$(fetch_jwks_kid "${post_kid}" 2>/dev/null || true)"
if [[ -n "${after_kid}" ]]; then
  log "Final JWKS kid=${after_kid}"
else
  log "Final JWKS kid=<unavailable>"
fi

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

if [[ -n "${before_kid}" || -n "${after_kid}" ]]; then
  log "jwks_kid_before=${before_kid:-<unavailable>}"
  log "jwks_kid_after=${after_kid:-<unavailable>}"
fi

if (( auth_post_restart_success == 0 )); then
  log "RESULT auth did not recover within drill window"
  exit 1
fi

if (( users_post_restart_success == 0 )); then
  log "RESULT auth recovered, but users_service never accepted fresh tokens after auth restart"
  log "HINT this is expected if auth_service still rotates ephemeral JWT keys and users_service keeps stale JWKS in memory"
  exit 2
fi

log "RESULT auth and users recovered after auth restart"
