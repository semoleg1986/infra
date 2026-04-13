#!/usr/bin/env bash
set -euo pipefail

# Smoke check for production contour:
# auth -> users -> course -> payments(optional)

AUTH_BASE_URL="${AUTH_BASE_URL:-http://127.0.0.1:8000}"
USERS_BASE_URL="${USERS_BASE_URL:-http://127.0.0.1:8002}"
COURSE_BASE_URL="${COURSE_BASE_URL:-http://127.0.0.1:8001}"
PAYMENTS_BASE_URL="${PAYMENTS_BASE_URL:-http://127.0.0.1:8004}"
SMOKE_PAYMENTS_ENABLED="${SMOKE_PAYMENTS_ENABLED:-0}"
SMOKE_PAYMENTS_PROVISION_RELATIONS="${SMOKE_PAYMENTS_PROVISION_RELATIONS:-0}"
SMOKE_PAYMENTS_COURSE_ID="${SMOKE_PAYMENTS_COURSE_ID:-course-1}"

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

if [[ "${SMOKE_PAYMENTS_ENABLED}" == "1" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' "${PAYMENTS_BASE_URL}/healthz")"
  if [[ "${code}" != "200" ]]; then
    log "ERROR health check failed for ${PAYMENTS_BASE_URL}/healthz: HTTP ${code}"
    exit 1
  fi
fi

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
PAYMENT_PARENT_ID="${SMOKE_PAYMENTS_PARENT_ID:-parent-1}"
PAYMENT_STUDENT_ID="${SMOKE_PAYMENTS_STUDENT_ID:-student-1}"
PAYMENT_COURSE_ID="${SMOKE_PAYMENTS_COURSE_ID}"

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

if [[ "${SMOKE_PAYMENTS_ENABLED}" == "1" ]]; then
  if [[ "${SMOKE_PAYMENTS_PROVISION_RELATIONS}" == "1" ]]; then
    log "Create parent in users_service"
    PARENT_PAYLOAD="${TMP_DIR}/parent.json"
    cat > "${PARENT_PAYLOAD}" <<JSON
{
  "user_id": "${PAYMENT_PARENT_ID}",
  "email": "parent.smoke.${SMOKE_ID}@example.com",
  "display_name": "Smoke Parent ${SMOKE_ID}",
  "roles": ["parent"]
}
JSON
    PARENT_OUT="${TMP_DIR}/parent.out.json"
    PARENT_STATUS="$(request_json "POST" "${USERS_BASE_URL}/v1/admin/users" "${PARENT_PAYLOAD}" "${PARENT_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
    assert_2xx "${PARENT_STATUS}" "${PARENT_OUT}" "create parent"

    log "Create student in users_service"
    STUDENT_PAYLOAD="${TMP_DIR}/student.json"
    cat > "${STUDENT_PAYLOAD}" <<JSON
{
  "user_id": "${PAYMENT_STUDENT_ID}",
  "email": "student.smoke.${SMOKE_ID}@example.com",
  "display_name": "Smoke Student ${SMOKE_ID}",
  "roles": ["student"]
}
JSON
    STUDENT_OUT="${TMP_DIR}/student.out.json"
    STUDENT_STATUS="$(request_json "POST" "${USERS_BASE_URL}/v1/admin/users" "${STUDENT_PAYLOAD}" "${STUDENT_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
    assert_2xx "${STUDENT_STATUS}" "${STUDENT_OUT}" "create student"

    log "Create parent-student link in users_service"
    LINK_PAYLOAD="${TMP_DIR}/parent_student_link.json"
    cat > "${LINK_PAYLOAD}" <<JSON
{
  "parent_id": "${PAYMENT_PARENT_ID}",
  "student_id": "${PAYMENT_STUDENT_ID}",
  "note": "smoke"
}
JSON
    LINK_OUT="${TMP_DIR}/parent_student_link.out.json"
    LINK_STATUS="$(request_json "POST" "${USERS_BASE_URL}/v1/admin/links" "${LINK_PAYLOAD}" "${LINK_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
    assert_2xx "${LINK_STATUS}" "${LINK_OUT}" "create parent-student link"
  fi

  log "Create payment intent in payments_service"
  PAYMENT_PAYLOAD="${TMP_DIR}/payment_intent.json"
  cat > "${PAYMENT_PAYLOAD}" <<JSON
{
  "parent_id": "${PAYMENT_PARENT_ID}",
  "student_id": "${PAYMENT_STUDENT_ID}",
  "course_id": "${PAYMENT_COURSE_ID}",
  "idempotency_key": "smoke-pay-${SMOKE_ID}-${RANDOM}"
}
JSON

  PAYMENT_OUT="${TMP_DIR}/payment.out.json"
  PAYMENT_STATUS="$(request_json "POST" "${PAYMENTS_BASE_URL}/v1/parent/payments/intents" "${PAYMENT_PAYLOAD}" "${PAYMENT_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
  assert_2xx "${PAYMENT_STATUS}" "${PAYMENT_OUT}" "create payment intent"

  PAYMENT_INTENT_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("payment_intent_id",""))' "${PAYMENT_OUT}")"
  if [[ -z "${PAYMENT_INTENT_ID}" ]]; then
    log "ERROR create payment intent: payment_intent_id is empty"
    cat "${PAYMENT_OUT}"
    echo
    exit 1
  fi

  log "Approve payment intent in payments_service"
  APPROVE_PAYLOAD="${TMP_DIR}/payment_approve.json"
  cat > "${APPROVE_PAYLOAD}" <<JSON
{}
JSON
  APPROVE_OUT="${TMP_DIR}/payment_approve.out.json"
  APPROVE_STATUS="$(request_json "POST" "${PAYMENTS_BASE_URL}/v1/admin/payments/${PAYMENT_INTENT_ID}/approve" "${APPROVE_PAYLOAD}" "${APPROVE_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
  assert_2xx "${APPROVE_STATUS}" "${APPROVE_OUT}" "approve payment intent"

  ACCESS_GRANT_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("access_grant_id",""))' "${APPROVE_OUT}")"
  if [[ -z "${ACCESS_GRANT_ID}" ]]; then
    log "ERROR approve payment intent: access_grant_id is empty"
    cat "${APPROVE_OUT}"
    echo
    exit 1
  fi

  log "Internal access check from payments_service"
  PAYMENTS_INTERNAL_OUT="${TMP_DIR}/payments_internal.out.json"
  PAYMENTS_INTERNAL_STATUS="$(request_json "GET" "${PAYMENTS_BASE_URL}/internal/v1/access/${PAYMENT_COURSE_ID}/${PAYMENT_STUDENT_ID}" "" "${PAYMENTS_INTERNAL_OUT}" -H "X-Service-Token: ${SERVICE_TOKEN}")"
  assert_2xx "${PAYMENTS_INTERNAL_STATUS}" "${PAYMENTS_INTERNAL_OUT}" "internal payments access check"

  HAS_ACCESS="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(str(d.get("has_access", False)).lower())' "${PAYMENTS_INTERNAL_OUT}")"
  if [[ "${HAS_ACCESS}" != "true" ]]; then
    log "ERROR internal payments access check: has_access=false"
    cat "${PAYMENTS_INTERNAL_OUT}"
    echo
    exit 1
  fi

  log "payments_intent_id=${PAYMENT_INTENT_ID}"
  log "payments_access_grant_id=${ACCESS_GRANT_ID}"
fi

log "OK"
log "teacher_id=${TEACHER_ID}"
log "course_id=${COURSE_ID}"
