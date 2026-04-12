#!/usr/bin/env bash
set -euo pipefail

# Smoke check for production contour:
# auth -> users (admin create teacher + internal lookup) -> course (admin create course)

AUTH_BASE_URL="${AUTH_BASE_URL:-http://127.0.0.1:8000}"
USERS_BASE_URL="${USERS_BASE_URL:-http://127.0.0.1:8002}"
COURSE_BASE_URL="${COURSE_BASE_URL:-http://127.0.0.1:8001}"

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin12345}"
SESSION_FINGERPRINT="${SESSION_FINGERPRINT:-prod-smoke-$(date +%s)}"

SERVICE_TOKEN="${SERVICE_TOKEN:-sometokencourse}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
  printf '[smoke] %s\n' "$*"
}

request_json() {
  # usage: request_json METHOD URL BODY_FILE OUT_BODY_FILE [HEADER...]
  local method="$1"
  local url="$2"
  local body_file="$3"
  local out_file="$4"
  shift 4
  local status
  if [[ -n "${body_file}" ]]; then
    status="$(curl -sS -o "${out_file}" -w '%{http_code}' -X "${method}" "${url}" "$@" --data-binary "@${body_file}")"
  else
    status="$(curl -sS -o "${out_file}" -w '%{http_code}' -X "${method}" "${url}" "$@")"
  fi
  printf '%s' "${status}"
}

assert_2xx() {
  local status="$1"
  local body_file="$2"
  local step="$3"
  if [[ ! "${status}" =~ ^2 ]]; then
    log "ERROR ${step}: HTTP ${status}"
    cat "${body_file}"
    echo
    exit 1
  fi
}

log "Health checks"
for url in \
  "${AUTH_BASE_URL}/healthz" \
  "${USERS_BASE_URL}/healthz" \
  "${COURSE_BASE_URL}/healthz"; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' "${url}")"
  if [[ "${code}" != "200" ]]; then
    log "ERROR health check failed for ${url}: HTTP ${code}"
    exit 1
  fi
done

log "Admin login"
LOGIN_PAYLOAD="${TMP_DIR}/login.json"
cat > "${LOGIN_PAYLOAD}" <<JSON
{
  "email": "${ADMIN_EMAIL}",
  "password": "${ADMIN_PASSWORD}",
  "session_fingerprint": "${SESSION_FINGERPRINT}"
}
JSON

LOGIN_OUT="${TMP_DIR}/login.out.json"
LOGIN_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/login" "${LOGIN_PAYLOAD}" "${LOGIN_OUT}" -H "Content-Type: application/json")"
assert_2xx "${LOGIN_STATUS}" "${LOGIN_OUT}" "admin login"

ACCESS_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "${LOGIN_OUT}")"
if [[ -z "${ACCESS_TOKEN}" ]]; then
  log "ERROR admin login: access_token is empty"
  exit 1
fi

SMOKE_ID="$(date +%s)"
TEACHER_USER_ID="teacher-smoke-${SMOKE_ID}"
TEACHER_EMAIL="teacher.smoke.${SMOKE_ID}@example.com"

log "Create teacher in users_service"
TEACHER_PAYLOAD="${TMP_DIR}/teacher.json"
cat > "${TEACHER_PAYLOAD}" <<JSON
{
  "user_id": "${TEACHER_USER_ID}",
  "email": "${TEACHER_EMAIL}",
  "display_name": "Smoke Teacher ${SMOKE_ID}",
  "roles": ["teacher"]
}
JSON

TEACHER_OUT="${TMP_DIR}/teacher.out.json"
TEACHER_STATUS="$(request_json "POST" "${USERS_BASE_URL}/v1/admin/users" "${TEACHER_PAYLOAD}" "${TEACHER_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${TEACHER_STATUS}" "${TEACHER_OUT}" "create teacher"

TEACHER_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("user_id",""))' "${TEACHER_OUT}")"
if [[ -z "${TEACHER_ID}" ]]; then
  log "ERROR create teacher: user_id is empty"
  cat "${TEACHER_OUT}"
  echo
  exit 1
fi

log "Internal teacher lookup from users_service"
INTERNAL_OUT="${TMP_DIR}/internal.out.json"
INTERNAL_STATUS="$(request_json "GET" "${USERS_BASE_URL}/internal/v1/teachers/${TEACHER_ID}" "" "${INTERNAL_OUT}" -H "X-Service-Token: ${SERVICE_TOKEN}")"
assert_2xx "${INTERNAL_STATUS}" "${INTERNAL_OUT}" "internal teacher lookup"

log "Create course in course_service"
COURSE_PAYLOAD="${TMP_DIR}/course.json"
cat > "${COURSE_PAYLOAD}" <<JSON
{
  "title": "Smoke Course ${SMOKE_ID}",
  "teacher_id": "${TEACHER_ID}",
  "starts_at": "2026-09-01T09:00:00Z",
  "duration_days": 30
}
JSON

COURSE_OUT="${TMP_DIR}/course.out.json"
COURSE_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/admin/courses" "${COURSE_PAYLOAD}" "${COURSE_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${COURSE_STATUS}" "${COURSE_OUT}" "create course"

COURSE_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("course_id",""))' "${COURSE_OUT}")"
if [[ -z "${COURSE_ID}" ]]; then
  log "ERROR create course: course_id is empty"
  cat "${COURSE_OUT}"
  echo
  exit 1
fi

log "OK"
log "teacher_id=${TEACHER_ID}"
log "course_id=${COURSE_ID}"

