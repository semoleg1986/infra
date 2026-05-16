#!/usr/bin/env bash
set -euo pipefail

# Smoke check for production contour:
# auth -> users -> course -> payments(optional) -> student learning -> parent read

AUTH_BASE_URL="${AUTH_BASE_URL:-http://127.0.0.1:8000}"
USERS_BASE_URL="${USERS_BASE_URL:-http://127.0.0.1:8002}"
COURSE_BASE_URL="${COURSE_BASE_URL:-http://127.0.0.1:8001}"
LIVE_BASE_URL="${LIVE_BASE_URL:-http://127.0.0.1:8010}"
ATTR_BASE_URL="${ATTR_BASE_URL:-http://127.0.0.1:8003}"
PAYMENTS_BASE_URL="${PAYMENTS_BASE_URL:-http://127.0.0.1:8004}"
BONUS_BASE_URL="${BONUS_BASE_URL:-http://127.0.0.1:8006}"
COMMERCIAL_CATALOG_BASE_URL="${COMMERCIAL_CATALOG_BASE_URL:-http://127.0.0.1:8007}"
SMOKE_PAYMENTS_ENABLED="${SMOKE_PAYMENTS_ENABLED:-0}"
SMOKE_BONUS_ENABLED="${SMOKE_BONUS_ENABLED:-0}"
SMOKE_BONUS_COURSE_COMPLETION_POINTS="${SMOKE_BONUS_COURSE_COMPLETION_POINTS:-25}"
SMOKE_LEARNING_ENABLED="${SMOKE_LEARNING_ENABLED:-1}"
SMOKE_LIVE_ENABLED="${SMOKE_LIVE_ENABLED:-0}"
SMOKE_ATTRIBUTION_ENABLED="${SMOKE_ATTRIBUTION_ENABLED:-0}"
SMOKE_PAYMENTS_PROVISION_RELATIONS="${SMOKE_PAYMENTS_PROVISION_RELATIONS:-1}"
SMOKE_PAYMENTS_COURSE_ID="${SMOKE_PAYMENTS_COURSE_ID:-}"
SMOKE_PAYMENTS_OFFER_ID="${SMOKE_PAYMENTS_OFFER_ID:-}"
SMOKE_LEARNING_LESSON1_ID="${SMOKE_LEARNING_LESSON1_ID:-}"
SMOKE_LEARNING_LESSON2_ID="${SMOKE_LEARNING_LESSON2_ID:-}"

ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin12345}"
SESSION_FINGERPRINT="${SESSION_FINGERPRINT:-prod-smoke-$(date +%s)}"

SERVICE_TOKEN="${SERVICE_TOKEN:-sometokencourse}"
ATTR_SERVICE_TOKEN="${ATTR_SERVICE_TOKEN:-${SERVICE_TOKEN}}"
BONUS_SERVICE_TOKEN="${BONUS_SERVICE_TOKEN:-${SERVICE_TOKEN}}"
METRICS_TOKEN="${METRICS_TOKEN:-${SERVICE_TOKEN}}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

log() {
  printf '[smoke] %s\n' "$*"
}

if [[ "${SMOKE_LIVE_ENABLED}" == "1" && "${SMOKE_PAYMENTS_ENABLED}" != "1" ]]; then
  log "ERROR live smoke requires SMOKE_PAYMENTS_ENABLED=1"
  exit 1
fi

if [[ "${SMOKE_LIVE_ENABLED}" == "1" && "${SMOKE_LEARNING_ENABLED}" != "1" ]]; then
  log "ERROR live smoke requires SMOKE_LEARNING_ENABLED=1"
  exit 1
fi

if [[ "${SMOKE_ATTRIBUTION_ENABLED}" == "1" && "${SMOKE_PAYMENTS_ENABLED}" != "1" ]]; then
  log "ERROR attribution smoke requires SMOKE_PAYMENTS_ENABLED=1"
  exit 1
fi

if [[ "${SMOKE_BONUS_ENABLED}" == "1" && "${SMOKE_PAYMENTS_ENABLED}" != "1" ]]; then
  log "ERROR bonus smoke requires SMOKE_PAYMENTS_ENABLED=1"
  exit 1
fi

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

is_already_active_access_error() {
  local status="$1"
  local body_file="$2"
  [[ "${status}" == "400" ]] && grep -q "уже существует active доступ" "${body_file}"
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

  code="$(curl -sS -o /dev/null -w '%{http_code}' "${COMMERCIAL_CATALOG_BASE_URL}/healthz")"
  if [[ "${code}" != "200" ]]; then
    log "ERROR health check failed for ${COMMERCIAL_CATALOG_BASE_URL}/healthz: HTTP ${code}"
    exit 1
  fi
fi

if [[ "${SMOKE_BONUS_ENABLED}" == "1" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' "${BONUS_BASE_URL}/healthz")"
  if [[ "${code}" != "200" ]]; then
    log "ERROR health check failed for ${BONUS_BASE_URL}/healthz: HTTP ${code}"
    exit 1
  fi
fi

if [[ "${SMOKE_LIVE_ENABLED}" == "1" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' "${LIVE_BASE_URL}/healthz")"
  if [[ "${code}" != "200" ]]; then
    log "ERROR health check failed for ${LIVE_BASE_URL}/healthz: HTTP ${code}"
    exit 1
  fi
fi

if [[ "${SMOKE_ATTRIBUTION_ENABLED}" == "1" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' "${ATTR_BASE_URL}/healthz")"
  if [[ "${code}" != "200" ]]; then
    log "ERROR health check failed for ${ATTR_BASE_URL}/healthz: HTTP ${code}"
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

log "Create published learning structure in course_service"
MODULE_PAYLOAD="${TMP_DIR}/module.json"
cat > "${MODULE_PAYLOAD}" <<JSON
{
  "module_id": "module-smoke-${SMOKE_ID}",
  "title": "Smoke Module ${SMOKE_ID}",
  "description": "smoke",
  "is_required": true
}
JSON
MODULE_OUT="${TMP_DIR}/module.out.json"
MODULE_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/admin/courses/${COURSE_ID}/modules" "${MODULE_PAYLOAD}" "${MODULE_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${MODULE_STATUS}" "${MODULE_OUT}" "create module"

MODULE_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("modules", [{}])[0].get("module_id","") if isinstance(d.get("modules"), list) and d.get("modules") else "module-smoke")' "${MODULE_OUT}")"
if [[ -z "${MODULE_ID}" || "${MODULE_ID}" == "module-smoke" ]]; then
  MODULE_ID="module-smoke-${SMOKE_ID}"
fi

for LESSON_NUM in 1 2; do
  REQUESTED_LESSON_ID="lesson-smoke-${SMOKE_ID}-${LESSON_NUM}"
  LESSON_PAYLOAD="${TMP_DIR}/lesson-${LESSON_NUM}.json"
  cat > "${LESSON_PAYLOAD}" <<JSON
{
  "lesson_id": "${REQUESTED_LESSON_ID}",
  "title": "Smoke Lesson ${LESSON_NUM}",
  "description": "smoke",
  "content_type": "video",
  "content_ref": "cdn://smoke/${SMOKE_ID}/${LESSON_NUM}",
  "duration_minutes": 15,
  "is_preview": false
}
JSON
  LESSON_OUT="${TMP_DIR}/lesson-${LESSON_NUM}.out.json"
  LESSON_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/admin/courses/${COURSE_ID}/modules/${MODULE_ID}/lessons" "${LESSON_PAYLOAD}" "${LESSON_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
  assert_2xx "${LESSON_STATUS}" "${LESSON_OUT}" "create lesson ${LESSON_NUM}"

  LESSON_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("lesson_id",""))' "${LESSON_OUT}")"
  if [[ -z "${LESSON_ID}" ]]; then
    LESSON_ID="${REQUESTED_LESSON_ID}"
  fi

  if [[ "${LESSON_NUM}" == "1" ]]; then
    LESSON1_ID="${LESSON_ID}"
  else
    LESSON2_ID="${LESSON_ID}"
  fi

  LESSON_PATCH_PAYLOAD="${TMP_DIR}/lesson-${LESSON_NUM}.patch.json"
  cat > "${LESSON_PATCH_PAYLOAD}" <<JSON
{
  "status": "published"
}
JSON
  LESSON_PATCH_OUT="${TMP_DIR}/lesson-${LESSON_NUM}.patch.out.json"
  LESSON_PATCH_STATUS="$(request_json "PATCH" "${COURSE_BASE_URL}/v1/admin/courses/${COURSE_ID}/modules/${MODULE_ID}/lessons/${LESSON_ID}" "${LESSON_PATCH_PAYLOAD}" "${LESSON_PATCH_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
  assert_2xx "${LESSON_PATCH_STATUS}" "${LESSON_PATCH_OUT}" "publish lesson ${LESSON_NUM}"
done

MODULE_PATCH_PAYLOAD="${TMP_DIR}/module.patch.json"
cat > "${MODULE_PATCH_PAYLOAD}" <<JSON
{
  "status": "published"
}
JSON
MODULE_PATCH_OUT="${TMP_DIR}/module.patch.out.json"
MODULE_PATCH_STATUS="$(request_json "PATCH" "${COURSE_BASE_URL}/v1/admin/courses/${COURSE_ID}/modules/${MODULE_ID}" "${MODULE_PATCH_PAYLOAD}" "${MODULE_PATCH_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${MODULE_PATCH_STATUS}" "${MODULE_PATCH_OUT}" "publish module"

COURSE_PUBLISH_OUT="${TMP_DIR}/course.publish.out.json"
COURSE_PUBLISH_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/admin/courses/${COURSE_ID}/publish" "" "${COURSE_PUBLISH_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
assert_2xx "${COURSE_PUBLISH_STATUS}" "${COURSE_PUBLISH_OUT}" "publish course"

PAYMENT_STUDENT_ID="${SMOKE_PAYMENTS_STUDENT_ID:-student-smoke-${SMOKE_ID}}"
PAYMENT_PARENT_ID="${SMOKE_PAYMENTS_PARENT_ID:-parent-smoke-${SMOKE_ID}}"
PAYMENT_COURSE_ID="${SMOKE_PAYMENTS_COURSE_ID:-${COURSE_ID}}"
PAYMENT_OFFER_ID="${SMOKE_PAYMENTS_OFFER_ID:-}"
STUDENT_EMAIL="student.smoke.${SMOKE_ID}@example.com"
STUDENT_PASSWORD="${SMOKE_STUDENT_PASSWORD:-student12345}"
PARENT_EMAIL="parent.smoke.${SMOKE_ID}@example.com"
PARENT_PASSWORD="${SMOKE_PARENT_PASSWORD:-parent12345}"

if [[ "${SMOKE_PAYMENTS_ENABLED}" == "1" ]]; then
  if [[ "${SMOKE_PAYMENTS_PROVISION_RELATIONS}" == "1" ]]; then
    log "Register parent in auth_service"
    PARENT_REGISTER_PAYLOAD="${TMP_DIR}/parent.register.json"
    cat > "${PARENT_REGISTER_PAYLOAD}" <<JSON
{
  "email": "${PARENT_EMAIL}",
  "password": "${PARENT_PASSWORD}",
  "default_role": "parent"
}
JSON
    PARENT_REGISTER_OUT="${TMP_DIR}/parent.register.out.json"
    PARENT_REGISTER_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/register" "${PARENT_REGISTER_PAYLOAD}" "${PARENT_REGISTER_OUT}" -H "Content-Type: application/json")"
    assert_2xx "${PARENT_REGISTER_STATUS}" "${PARENT_REGISTER_OUT}" "register parent auth"

    log "Parent login in auth_service"
    PARENT_LOGIN_PAYLOAD="${TMP_DIR}/parent.login.json"
    cat > "${PARENT_LOGIN_PAYLOAD}" <<JSON
{
  "email": "${PARENT_EMAIL}",
  "password": "${PARENT_PASSWORD}",
  "session_fingerprint": "parent-smoke-${SMOKE_ID}"
}
JSON
    PARENT_LOGIN_OUT="${TMP_DIR}/parent.login.out.json"
    PARENT_LOGIN_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/login" "${PARENT_LOGIN_PAYLOAD}" "${PARENT_LOGIN_OUT}" -H "Content-Type: application/json")"
    assert_2xx "${PARENT_LOGIN_STATUS}" "${PARENT_LOGIN_OUT}" "parent login"

    PARENT_ACCESS_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "${PARENT_LOGIN_OUT}")"
    PARENT_ME_OUT="${TMP_DIR}/parent.me.out.json"
    PARENT_ME_STATUS="$(request_json "GET" "${AUTH_BASE_URL}/v1/auth/me" "" "${PARENT_ME_OUT}" -H "Authorization: Bearer ${PARENT_ACCESS_TOKEN}")"
    assert_2xx "${PARENT_ME_STATUS}" "${PARENT_ME_OUT}" "parent auth me"
    PAYMENT_PARENT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["account_id"])' "${PARENT_ME_OUT}")"

    log "Create parent in users_service"
    PARENT_PAYLOAD="${TMP_DIR}/parent.json"
    cat > "${PARENT_PAYLOAD}" <<JSON
{
  "user_id": "${PAYMENT_PARENT_ID}",
  "email": "${PARENT_EMAIL}",
  "display_name": "Smoke Parent ${SMOKE_ID}",
  "roles": ["parent"]
}
JSON
    PARENT_OUT="${TMP_DIR}/parent.out.json"
    PARENT_STATUS="$(request_json "POST" "${USERS_BASE_URL}/v1/admin/users" "${PARENT_PAYLOAD}" "${PARENT_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
    assert_2xx "${PARENT_STATUS}" "${PARENT_OUT}" "create parent"

    log "Register student in auth_service"
    STUDENT_REGISTER_PAYLOAD="${TMP_DIR}/student.register.json"
    cat > "${STUDENT_REGISTER_PAYLOAD}" <<JSON
{
  "email": "${STUDENT_EMAIL}",
  "password": "${STUDENT_PASSWORD}",
  "default_role": "student"
}
JSON
    STUDENT_REGISTER_OUT="${TMP_DIR}/student.register.out.json"
    STUDENT_REGISTER_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/register" "${STUDENT_REGISTER_PAYLOAD}" "${STUDENT_REGISTER_OUT}" -H "Content-Type: application/json")"
    assert_2xx "${STUDENT_REGISTER_STATUS}" "${STUDENT_REGISTER_OUT}" "register student auth"

    log "Student login in auth_service"
    STUDENT_LOGIN_PAYLOAD="${TMP_DIR}/student.login.json"
    cat > "${STUDENT_LOGIN_PAYLOAD}" <<JSON
{
  "email": "${STUDENT_EMAIL}",
  "password": "${STUDENT_PASSWORD}",
  "session_fingerprint": "student-smoke-${SMOKE_ID}"
}
JSON
    STUDENT_LOGIN_OUT="${TMP_DIR}/student.login.out.json"
    STUDENT_LOGIN_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/login" "${STUDENT_LOGIN_PAYLOAD}" "${STUDENT_LOGIN_OUT}" -H "Content-Type: application/json")"
    assert_2xx "${STUDENT_LOGIN_STATUS}" "${STUDENT_LOGIN_OUT}" "student login"

    STUDENT_ACCESS_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "${STUDENT_LOGIN_OUT}")"
    STUDENT_ME_OUT="${TMP_DIR}/student.me.out.json"
    STUDENT_ME_STATUS="$(request_json "GET" "${AUTH_BASE_URL}/v1/auth/me" "" "${STUDENT_ME_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}")"
    assert_2xx "${STUDENT_ME_STATUS}" "${STUDENT_ME_OUT}" "student auth me"
    STUDENT_ACCOUNT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["account_id"])' "${STUDENT_ME_OUT}")"
    PAYMENT_STUDENT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user_id"])' "${STUDENT_ME_OUT}")"

    log "Create student in users_service"
    STUDENT_PAYLOAD="${TMP_DIR}/student.json"
    cat > "${STUDENT_PAYLOAD}" <<JSON
{
  "user_id": "${PAYMENT_STUDENT_ID}",
  "email": "${STUDENT_EMAIL}",
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

  if [[ -z "${PAYMENT_OFFER_ID}" ]]; then
    log "ERROR payments smoke requires SMOKE_PAYMENTS_OFFER_ID"
    exit 1
  fi

  log "Resolve offer snapshot in commercial_catalog_service"
  OFFER_OUT="${TMP_DIR}/offer.out.json"
  OFFER_STATUS="$(request_json "GET" "${COMMERCIAL_CATALOG_BASE_URL}/internal/v1/offers/${PAYMENT_OFFER_ID}" "" "${OFFER_OUT}" -H "X-Service-Token: ${SERVICE_TOKEN}")"
  assert_2xx "${OFFER_STATUS}" "${OFFER_OUT}" "resolve offer snapshot"

  OFFER_COURSE_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("course_id",""))' "${OFFER_OUT}")"
  if [[ -z "${OFFER_COURSE_ID}" ]]; then
    log "ERROR resolve offer snapshot: course_id is empty"
    cat "${OFFER_OUT}"
    echo
    exit 1
  fi

  if [[ -n "${SMOKE_PAYMENTS_COURSE_ID}" && "${PAYMENT_COURSE_ID}" != "${OFFER_COURSE_ID}" ]]; then
    log "ERROR offer snapshot course_id mismatch: expected ${PAYMENT_COURSE_ID}, got ${OFFER_COURSE_ID}"
    cat "${OFFER_OUT}"
    echo
    exit 1
  fi

  PAYMENT_COURSE_ID="${OFFER_COURSE_ID}"

  BONUS_REQUESTED_AMOUNT=0
  if [[ "${SMOKE_BONUS_ENABLED}" == "1" ]]; then
    BONUS_REQUESTED_AMOUNT=30
    log "Accrue bonus balance in bonus_wallet_service"
    BONUS_ACCRUAL_PAYLOAD="${TMP_DIR}/bonus_accrual.json"
    cat > "${BONUS_ACCRUAL_PAYLOAD}" <<JSON
{
  "parent_id": "${PAYMENT_PARENT_ID}",
  "amount": ${BONUS_REQUESTED_AMOUNT},
  "reason_code": "smoke_reward",
  "reference_id": "smoke-${SMOKE_ID}",
  "idempotency_key": "smoke-bonus-accrual-${SMOKE_ID}"
}
JSON
    BONUS_ACCRUAL_OUT="${TMP_DIR}/bonus_accrual.out.json"
    BONUS_ACCRUAL_STATUS="$(request_json "POST" "${BONUS_BASE_URL}/internal/v1/bonus/accruals" "${BONUS_ACCRUAL_PAYLOAD}" "${BONUS_ACCRUAL_OUT}" -H "X-Service-Token: ${BONUS_SERVICE_TOKEN}" -H "Content-Type: application/json")"
    assert_2xx "${BONUS_ACCRUAL_STATUS}" "${BONUS_ACCRUAL_OUT}" "accrue bonus balance"
  fi

  log "Create payment intent in payments_service"
  PAYMENT_PAYLOAD="${TMP_DIR}/payment_intent.json"
  cat > "${PAYMENT_PAYLOAD}" <<JSON
{
  "parent_id": "${PAYMENT_PARENT_ID}",
  "student_id": "${PAYMENT_STUDENT_ID}",
  "offer_id": "${PAYMENT_OFFER_ID}",
  "bonus_amount": ${BONUS_REQUESTED_AMOUNT},
  "idempotency_key": "smoke-pay-${SMOKE_ID}-${RANDOM}"
}
JSON

  PAYMENT_OUT="${TMP_DIR}/payment.out.json"
  PAYMENT_STATUS="$(request_json "POST" "${PAYMENTS_BASE_URL}/v1/parent/payments/intents" "${PAYMENT_PAYLOAD}" "${PAYMENT_OUT}" -H "Authorization: Bearer ${PARENT_ACCESS_TOKEN}" -H "Content-Type: application/json")"
  assert_2xx "${PAYMENT_STATUS}" "${PAYMENT_OUT}" "create payment intent"

  PAYMENT_INTENT_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("payment_intent_id",""))' "${PAYMENT_OUT}")"
  if [[ -z "${PAYMENT_INTENT_ID}" ]]; then
    log "ERROR create payment intent: payment_intent_id is empty"
    cat "${PAYMENT_OUT}"
    echo
    exit 1
  fi

  if [[ "${SMOKE_BONUS_ENABLED}" == "1" ]]; then
    ALLOWED_BONUS_AMOUNT="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("bonus_amount",0))' "${PAYMENT_OUT}")"
    if [[ "${ALLOWED_BONUS_AMOUNT}" != "${BONUS_REQUESTED_AMOUNT}" ]]; then
      log "ERROR create payment intent: expected bonus_amount=${BONUS_REQUESTED_AMOUNT}, got ${ALLOWED_BONUS_AMOUNT}"
      cat "${PAYMENT_OUT}"
      echo
      exit 1
    fi
  fi

  log "Approve payment intent in payments_service"
  APPROVE_PAYLOAD="${TMP_DIR}/payment_approve.json"
  cat > "${APPROVE_PAYLOAD}" <<JSON
{}
JSON
  APPROVE_OUT="${TMP_DIR}/payment_approve.out.json"
  APPROVE_STATUS="$(request_json "POST" "${PAYMENTS_BASE_URL}/v1/admin/payments/${PAYMENT_INTENT_ID}/approve" "${APPROVE_PAYLOAD}" "${APPROVE_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
  if is_already_active_access_error "${APPROVE_STATUS}" "${APPROVE_OUT}"; then
    log "Approve payment intent returned already-active access (idempotent OK)"
    ACCESS_GRANT_ID="already-active"
  else
    assert_2xx "${APPROVE_STATUS}" "${APPROVE_OUT}" "approve payment intent"

    ACCESS_GRANT_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("access_grant_id",""))' "${APPROVE_OUT}")"
    if [[ -z "${ACCESS_GRANT_ID}" ]]; then
      log "ERROR approve payment intent: access_grant_id is empty"
      cat "${APPROVE_OUT}"
      echo
      exit 1
    fi
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

  if [[ "${SMOKE_BONUS_ENABLED}" == "1" ]]; then
    log "Check bonus balance after approve"
    BONUS_BALANCE_OUT="${TMP_DIR}/bonus_balance.out.json"
    BONUS_BALANCE_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/internal/v1/bonus/balance/${PAYMENT_PARENT_ID}" "" "${BONUS_BALANCE_OUT}" -H "X-Service-Token: ${BONUS_SERVICE_TOKEN}")"
    assert_2xx "${BONUS_BALANCE_STATUS}" "${BONUS_BALANCE_OUT}" "bonus balance after approve"
    BONUS_BALANCE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("balance",-1))' "${BONUS_BALANCE_OUT}")"
    if [[ "${BONUS_BALANCE}" != "0" ]]; then
      log "ERROR bonus balance after approve: expected 0, got ${BONUS_BALANCE}"
      cat "${BONUS_BALANCE_OUT}"
      echo
      exit 1
    fi

    log "Parent reads own bonus balance"
    BONUS_PARENT_BALANCE_OUT="${TMP_DIR}/bonus_parent_balance.out.json"
    BONUS_PARENT_BALANCE_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/v1/parent/bonus/balance" "" "${BONUS_PARENT_BALANCE_OUT}" -H "Authorization: Bearer ${PARENT_ACCESS_TOKEN}")"
    assert_2xx "${BONUS_PARENT_BALANCE_STATUS}" "${BONUS_PARENT_BALANCE_OUT}" "parent bonus balance"
    BONUS_PARENT_BALANCE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("balance",-1))' "${BONUS_PARENT_BALANCE_OUT}")"
    if [[ "${BONUS_PARENT_BALANCE}" != "0" ]]; then
      log "ERROR parent bonus balance after approve: expected 0, got ${BONUS_PARENT_BALANCE}"
      cat "${BONUS_PARENT_BALANCE_OUT}"
      echo
      exit 1
    fi

    log "Parent reads own bonus ledger"
    BONUS_PARENT_LEDGER_OUT="${TMP_DIR}/bonus_parent_ledger.out.json"
    BONUS_PARENT_LEDGER_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/v1/parent/bonus/ledger?limit=20&offset=0" "" "${BONUS_PARENT_LEDGER_OUT}" -H "Authorization: Bearer ${PARENT_ACCESS_TOKEN}")"
    assert_2xx "${BONUS_PARENT_LEDGER_STATUS}" "${BONUS_PARENT_LEDGER_OUT}" "parent bonus ledger"
    BONUS_PARENT_LEDGER_HAS_REDEEM="$(python3 -c 'import json,sys; items=json.load(open(sys.argv[1])); print(str(any(item.get("operation")=="redeem_commit" for item in items)).lower())' "${BONUS_PARENT_LEDGER_OUT}")"
    if [[ "${BONUS_PARENT_LEDGER_HAS_REDEEM}" != "true" ]]; then
      log "ERROR parent bonus ledger: redeem_commit not found"
      cat "${BONUS_PARENT_LEDGER_OUT}"
      echo
      exit 1
    fi

    log "Admin reads bonus account snapshot"
    BONUS_ADMIN_ACCOUNT_OUT="${TMP_DIR}/bonus_admin_account.out.json"
    BONUS_ADMIN_ACCOUNT_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/v1/admin/bonus/accounts/${PAYMENT_PARENT_ID}" "" "${BONUS_ADMIN_ACCOUNT_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    assert_2xx "${BONUS_ADMIN_ACCOUNT_STATUS}" "${BONUS_ADMIN_ACCOUNT_OUT}" "admin bonus account snapshot"
    BONUS_ADMIN_ACCOUNT_BALANCE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("balance",-1))' "${BONUS_ADMIN_ACCOUNT_OUT}")"
    if [[ "${BONUS_ADMIN_ACCOUNT_BALANCE}" != "0" ]]; then
      log "ERROR admin bonus account snapshot after approve: expected 0, got ${BONUS_ADMIN_ACCOUNT_BALANCE}"
      cat "${BONUS_ADMIN_ACCOUNT_OUT}"
      echo
      exit 1
    fi

    log "Admin reads filtered bonus ledger"
    BONUS_ADMIN_LEDGER_OUT="${TMP_DIR}/bonus_admin_ledger.out.json"
    BONUS_ADMIN_LEDGER_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/v1/admin/bonus/accounts/${PAYMENT_PARENT_ID}/ledger?reason_code=payment_redeem_commit&limit=20&offset=0" "" "${BONUS_ADMIN_LEDGER_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    assert_2xx "${BONUS_ADMIN_LEDGER_STATUS}" "${BONUS_ADMIN_LEDGER_OUT}" "admin bonus ledger"
    BONUS_ADMIN_LEDGER_HAS_REDEEM="$(python3 -c 'import json,sys; items=json.load(open(sys.argv[1])); print(str(any(item.get("operation")=="redeem_commit" for item in items)).lower())' "${BONUS_ADMIN_LEDGER_OUT}")"
    if [[ "${BONUS_ADMIN_LEDGER_HAS_REDEEM}" != "true" ]]; then
      log "ERROR admin bonus ledger: redeem_commit not found"
      cat "${BONUS_ADMIN_LEDGER_OUT}"
      echo
      exit 1
    fi

    log "Admin creates and deactivates bonus rule"
    BONUS_RULE_PAYLOAD="${TMP_DIR}/bonus_rule.create.json"
    cat > "${BONUS_RULE_PAYLOAD}" <<JSON
{
  "trigger_type": "course_completed",
  "threshold": 1,
  "points": 25
}
JSON
    BONUS_RULE_CREATE_OUT="${TMP_DIR}/bonus_rule.create.out.json"
    BONUS_RULE_CREATE_STATUS="$(request_json "POST" "${BONUS_BASE_URL}/v1/admin/bonus/rules" "${BONUS_RULE_PAYLOAD}" "${BONUS_RULE_CREATE_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
    assert_2xx "${BONUS_RULE_CREATE_STATUS}" "${BONUS_RULE_CREATE_OUT}" "create bonus rule"
    BONUS_RULE_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("rule_id",""))' "${BONUS_RULE_CREATE_OUT}")"
    if [[ -z "${BONUS_RULE_ID}" ]]; then
      log "ERROR create bonus rule: rule_id is empty"
      cat "${BONUS_RULE_CREATE_OUT}"
      echo
      exit 1
    fi

    BONUS_RULES_OUT="${TMP_DIR}/bonus_rules.out.json"
    BONUS_RULES_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/v1/admin/bonus/rules?active_only=true" "" "${BONUS_RULES_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    assert_2xx "${BONUS_RULES_STATUS}" "${BONUS_RULES_OUT}" "list bonus rules"
    BONUS_RULES_HAS_CREATED="$(python3 -c 'import json,sys; items=json.load(open(sys.argv[1])); rule_id=sys.argv[2]; print(str(any(item.get("rule_id")==rule_id and item.get("is_active") is True for item in items)).lower())' "${BONUS_RULES_OUT}" "${BONUS_RULE_ID}")"
    if [[ "${BONUS_RULES_HAS_CREATED}" != "true" ]]; then
      log "ERROR list bonus rules: created rule not found"
      cat "${BONUS_RULES_OUT}"
      echo
      exit 1
    fi

    BONUS_RULE_DEACTIVATE_OUT="${TMP_DIR}/bonus_rule.deactivate.out.json"
    BONUS_RULE_DEACTIVATE_STATUS="$(request_json "POST" "${BONUS_BASE_URL}/v1/admin/bonus/rules/${BONUS_RULE_ID}/deactivate" "" "${BONUS_RULE_DEACTIVATE_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    assert_2xx "${BONUS_RULE_DEACTIVATE_STATUS}" "${BONUS_RULE_DEACTIVATE_OUT}" "deactivate bonus rule"
    BONUS_RULE_DEACTIVATED="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1])).get("is_active",True)).lower())' "${BONUS_RULE_DEACTIVATE_OUT}")"
    if [[ "${BONUS_RULE_DEACTIVATED}" != "false" ]]; then
      log "ERROR deactivate bonus rule: expected is_active=false"
      cat "${BONUS_RULE_DEACTIVATE_OUT}"
      echo
      exit 1
    fi

    log "Admin reads bonus summary report"
    BONUS_SUMMARY_OUT="${TMP_DIR}/bonus_summary.out.json"
    BONUS_SUMMARY_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/v1/admin/bonus/reports/summary" "" "${BONUS_SUMMARY_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    assert_2xx "${BONUS_SUMMARY_STATUS}" "${BONUS_SUMMARY_OUT}" "bonus summary report"

    log "Admin reads bonus reason breakdown"
    BONUS_BREAKDOWN_OUT="${TMP_DIR}/bonus_breakdown.out.json"
    BONUS_BREAKDOWN_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/v1/admin/bonus/reports/by-reason?limit=50&offset=0" "" "${BONUS_BREAKDOWN_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    assert_2xx "${BONUS_BREAKDOWN_STATUS}" "${BONUS_BREAKDOWN_OUT}" "bonus reason breakdown"
    BONUS_BREAKDOWN_HAS_SMOKE_REWARD="$(python3 -c 'import json,sys; items=json.load(open(sys.argv[1])); print(str(any(item.get("reason_code")=="smoke_reward" for item in items)).lower())' "${BONUS_BREAKDOWN_OUT}")"
    if [[ "${BONUS_BREAKDOWN_HAS_SMOKE_REWARD}" != "true" ]]; then
      log "ERROR bonus reason breakdown: smoke_reward not found"
      cat "${BONUS_BREAKDOWN_OUT}"
      echo
      exit 1
    fi

    log "Admin exports bonus ledger csv"
    BONUS_LEDGER_CSV_OUT="${TMP_DIR}/bonus_ledger.csv"
    curl -sS -H "Authorization: Bearer ${ACCESS_TOKEN}" "${BONUS_BASE_URL}/v1/admin/bonus/reports/ledger.csv?parent_id=${PAYMENT_PARENT_ID}" > "${BONUS_LEDGER_CSV_OUT}"
    if ! grep -q "smoke_reward" "${BONUS_LEDGER_CSV_OUT}"; then
      log "ERROR bonus ledger csv: smoke_reward row missing"
      cat "${BONUS_LEDGER_CSV_OUT}"
      echo
      exit 1
    fi
  fi

  if [[ "${SMOKE_ATTRIBUTION_ENABLED}" == "1" ]]; then
    TODAY_UTC="$(date -u +%F)"
    ATTR_CHANNEL="ads"
    ATTR_CAMPAIGN="smoke-campaign-${SMOKE_ID}"
    ATTR_SOURCE="blogger"
    ATTR_MEDIUM="influencer"

    log "Create referral token in attribution_service"
    ATTR_TOKEN_PAYLOAD="${TMP_DIR}/attr.token.json"
    cat > "${ATTR_TOKEN_PAYLOAD}" <<JSON
{
  "channel": "${ATTR_CHANNEL}",
  "reuse_policy": "shared_campaign",
  "campaign": "${ATTR_CAMPAIGN}",
  "source": "${ATTR_SOURCE}",
  "medium": "${ATTR_MEDIUM}",
  "course_id": "${PAYMENT_COURSE_ID}",
  "discount_type": "percent",
  "discount_value": 10,
  "discount_cap": 15
}
JSON
    ATTR_TOKEN_OUT="${TMP_DIR}/attr.token.out.json"
    ATTR_TOKEN_STATUS="$(request_json "POST" "${ATTR_BASE_URL}/v1/admin/referral-tokens" "${ATTR_TOKEN_PAYLOAD}" "${ATTR_TOKEN_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
    assert_2xx "${ATTR_TOKEN_STATUS}" "${ATTR_TOKEN_OUT}" "create attribution token"
    REFERRAL_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["token"])' "${ATTR_TOKEN_OUT}")"
    if [[ -z "${REFERRAL_TOKEN}" ]]; then
      log "ERROR create attribution token: token is empty"
      cat "${ATTR_TOKEN_OUT}"
      echo
      exit 1
    fi

    log "Track referral click in attribution_service"
    ATTR_CLICK_PAYLOAD="${TMP_DIR}/attr.click.json"
    cat > "${ATTR_CLICK_PAYLOAD}" <<JSON
{
  "anonymous_id": "anon-smoke-${SMOKE_ID}",
  "source_url": "https://example.com/smoke/${SMOKE_ID}",
  "utm_source": "${ATTR_SOURCE}",
  "utm_medium": "${ATTR_MEDIUM}",
  "utm_campaign": "${ATTR_CAMPAIGN}"
}
JSON
    ATTR_CLICK_OUT="${TMP_DIR}/attr.click.out.json"
    ATTR_CLICK_STATUS="$(request_json "POST" "${ATTR_BASE_URL}/v1/public/referrals/${REFERRAL_TOKEN}/click" "${ATTR_CLICK_PAYLOAD}" "${ATTR_CLICK_OUT}" -H "Content-Type: application/json")"
    assert_2xx "${ATTR_CLICK_STATUS}" "${ATTR_CLICK_OUT}" "track attribution click"

    log "Resolve discount in attribution_service"
    ATTR_RESOLVE_PAYLOAD="${TMP_DIR}/attr.resolve.json"
    cat > "${ATTR_RESOLVE_PAYLOAD}" <<JSON
{
  "course_id": "${PAYMENT_COURSE_ID}",
  "referral_token": "${REFERRAL_TOKEN}",
  "parent_id": "${PAYMENT_PARENT_ID}"
}
JSON
    ATTR_RESOLVE_OUT="${TMP_DIR}/attr.resolve.out.json"
    ATTR_RESOLVE_STATUS="$(request_json "POST" "${ATTR_BASE_URL}/v1/internal/discount/resolve" "${ATTR_RESOLVE_PAYLOAD}" "${ATTR_RESOLVE_OUT}" -H "X-Service-Token: ${ATTR_SERVICE_TOKEN}" -H "Content-Type: application/json")"
    assert_2xx "${ATTR_RESOLVE_STATUS}" "${ATTR_RESOLVE_OUT}" "resolve attribution discount"
    ATTR_DISCOUNT_VALID="$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["valid"]).lower())' "${ATTR_RESOLVE_OUT}")"
    if [[ "${ATTR_DISCOUNT_VALID}" != "true" ]]; then
      log "ERROR resolve attribution discount: expected valid=true"
      cat "${ATTR_RESOLVE_OUT}"
      echo
      exit 1
    fi

    log "Record requested conversion in attribution_service"
    ATTR_REQUESTED_PAYLOAD="${TMP_DIR}/attr.requested.json"
    python3 - "${ATTR_RESOLVE_OUT}" "${ATTR_REQUESTED_PAYLOAD}" "${ACCESS_GRANT_ID}" "${PAYMENT_COURSE_ID}" "${PAYMENT_STUDENT_ID}" "${PAYMENT_PARENT_ID}" "${REFERRAL_TOKEN}" <<'PY'
import json
import sys
resolve = json.load(open(sys.argv[1]))
payload = {
    "access_grant_id": sys.argv[3],
    "course_id": sys.argv[4],
    "student_id": sys.argv[5],
    "parent_id": sys.argv[6],
    "token": sys.argv[7],
    "channel": resolve["channel"],
    "discount": resolve["discount"],
}
json.dump(payload, open(sys.argv[2], "w"))
PY
    ATTR_REQUESTED_OUT="${TMP_DIR}/attr.requested.out.json"
    ATTR_REQUESTED_STATUS="$(request_json "POST" "${ATTR_BASE_URL}/v1/internal/conversions/requested" "${ATTR_REQUESTED_PAYLOAD}" "${ATTR_REQUESTED_OUT}" -H "X-Service-Token: ${ATTR_SERVICE_TOKEN}" -H "Content-Type: application/json")"
    assert_2xx "${ATTR_REQUESTED_STATUS}" "${ATTR_REQUESTED_OUT}" "record requested conversion"

    log "Process payment confirmed event in attribution_service"
    ATTR_CONFIRMED_PAYLOAD="${TMP_DIR}/attr.payment_confirmed.json"
    cat > "${ATTR_CONFIRMED_PAYLOAD}" <<JSON
{
  "event_id": "smoke-payment-confirmed-${SMOKE_ID}",
  "access_grant_id": "${ACCESS_GRANT_ID}",
  "paid_amount": {
    "amount": 100,
    "currency": "USD"
  },
  "approved_by_admin_id": "admin-smoke"
}
JSON
    ATTR_CONFIRMED_OUT="${TMP_DIR}/attr.payment_confirmed.out.json"
    ATTR_CONFIRMED_STATUS="$(request_json "POST" "${ATTR_BASE_URL}/v1/internal/events/payment-confirmed" "${ATTR_CONFIRMED_PAYLOAD}" "${ATTR_CONFIRMED_OUT}" -H "X-Service-Token: ${ATTR_SERVICE_TOKEN}" -H "Content-Type: application/json")"
    assert_2xx "${ATTR_CONFIRMED_STATUS}" "${ATTR_CONFIRMED_OUT}" "process payment confirmed event"

    log "Read attribution campaign stats"
    ATTR_STATS_OUT="${TMP_DIR}/attr.stats.out.json"
    ATTR_STATS_STATUS="$(request_json "GET" "${ATTR_BASE_URL}/v1/admin/campaigns/stats?date_from=${TODAY_UTC}&date_to=${TODAY_UTC}&channel=${ATTR_CHANNEL}&campaign=${ATTR_CAMPAIGN}&source=${ATTR_SOURCE}&medium=${ATTR_MEDIUM}&limit=10&offset=0" "" "${ATTR_STATS_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    assert_2xx "${ATTR_STATS_STATUS}" "${ATTR_STATS_OUT}" "read attribution campaign stats"
    ATTR_STATS_MATCH="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); campaign=sys.argv[2]; print(str(any(item.get("campaign")==campaign and item.get("clicks",0) >= 1 and item.get("requested",0) >= 1 and item.get("paid",0) >= 1 for item in d.get("items", []))).lower())' "${ATTR_STATS_OUT}" "${ATTR_CAMPAIGN}")"
    if [[ "${ATTR_STATS_MATCH}" != "true" ]]; then
      log "ERROR attribution campaign stats: expected campaign aggregate not found"
      cat "${ATTR_STATS_OUT}"
      echo
      exit 1
    fi

    log "Read attribution campaign stats csv"
    ATTR_CSV_OUT="${TMP_DIR}/attr.stats.csv"
    curl -sS -H "Authorization: Bearer ${ACCESS_TOKEN}" "${ATTR_BASE_URL}/v1/admin/campaigns/stats.csv?date_from=${TODAY_UTC}&date_to=${TODAY_UTC}&channel=${ATTR_CHANNEL}&campaign=${ATTR_CAMPAIGN}&source=${ATTR_SOURCE}&medium=${ATTR_MEDIUM}" > "${ATTR_CSV_OUT}"
    if ! grep -q "${ATTR_CAMPAIGN}" "${ATTR_CSV_OUT}"; then
      log "ERROR attribution campaign csv: campaign row missing"
      cat "${ATTR_CSV_OUT}"
      echo
      exit 1
    fi
  fi

  if [[ "${SMOKE_LEARNING_ENABLED}" == "1" ]]; then
    if [[ "${PAYMENT_COURSE_ID}" == "${COURSE_ID}" ]]; then
      TARGET_LESSON1_ID="${LESSON1_ID}"
      TARGET_LESSON2_ID="${LESSON2_ID}"
    else
      TARGET_LESSON1_ID="${SMOKE_LEARNING_LESSON1_ID}"
      TARGET_LESSON2_ID="${SMOKE_LEARNING_LESSON2_ID}"

      if [[ -z "${TARGET_LESSON1_ID}" || -z "${TARGET_LESSON2_ID}" ]]; then
        log "ERROR learning smoke for external payment course requires SMOKE_LEARNING_LESSON1_ID and SMOKE_LEARNING_LESSON2_ID"
        log "payment_course_id=${PAYMENT_COURSE_ID}"
        log "created_course_id=${COURSE_ID}"
        exit 1
      fi
    fi

    log "Student complete first lesson"
    STUDENT_COMPLETE1_OUT="${TMP_DIR}/student.complete1.out.json"
    STUDENT_COMPLETE1_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/student/courses/${PAYMENT_COURSE_ID}/lessons/${TARGET_LESSON1_ID}/complete" "" "${STUDENT_COMPLETE1_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}")"
    assert_2xx "${STUDENT_COMPLETE1_STATUS}" "${STUDENT_COMPLETE1_OUT}" "student complete lesson 1"
    COURSE_STATUS_1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["course_status"])' "${STUDENT_COMPLETE1_OUT}")"
    if [[ "${COURSE_STATUS_1}" != "in_progress" ]]; then
      log "ERROR student complete lesson 1: expected in_progress, got ${COURSE_STATUS_1}"
      cat "${STUDENT_COMPLETE1_OUT}"
      echo
      exit 1
    fi

    log "Student complete second lesson"
    STUDENT_COMPLETE2_OUT="${TMP_DIR}/student.complete2.out.json"
    STUDENT_COMPLETE2_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/student/courses/${PAYMENT_COURSE_ID}/lessons/${TARGET_LESSON2_ID}/complete" "" "${STUDENT_COMPLETE2_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}")"
    assert_2xx "${STUDENT_COMPLETE2_STATUS}" "${STUDENT_COMPLETE2_OUT}" "student complete lesson 2"
    COURSE_STATUS_2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["course_status"])' "${STUDENT_COMPLETE2_OUT}")"
    if [[ "${COURSE_STATUS_2}" != "completed" ]]; then
      log "ERROR student complete lesson 2: expected completed, got ${COURSE_STATUS_2}"
      cat "${STUDENT_COMPLETE2_OUT}"
      echo
      exit 1
    fi

    if [[ "${SMOKE_BONUS_ENABLED}" == "1" ]]; then
      log "Check bonus balance after course completion"
      BONUS_BALANCE_AFTER_LEARNING_OUT="${TMP_DIR}/bonus.balance.after_learning.out.json"
      BONUS_BALANCE_AFTER_LEARNING_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/internal/v1/bonus/balance/${PAYMENT_PARENT_ID}" "" "${BONUS_BALANCE_AFTER_LEARNING_OUT}" -H "X-Service-Token: ${BONUS_SERVICE_TOKEN}")"
      assert_2xx "${BONUS_BALANCE_AFTER_LEARNING_STATUS}" "${BONUS_BALANCE_AFTER_LEARNING_OUT}" "bonus balance after course completion"
      BONUS_BALANCE_AFTER_LEARNING="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("balance",-1))' "${BONUS_BALANCE_AFTER_LEARNING_OUT}")"
      if [[ "${BONUS_BALANCE_AFTER_LEARNING}" != "${SMOKE_BONUS_COURSE_COMPLETION_POINTS}" ]]; then
        log "ERROR bonus balance after course completion: expected ${SMOKE_BONUS_COURSE_COMPLETION_POINTS}, got ${BONUS_BALANCE_AFTER_LEARNING}"
        cat "${BONUS_BALANCE_AFTER_LEARNING_OUT}"
        echo
        exit 1
      fi

      log "Parent reads bonus balance after course completion"
      BONUS_PARENT_BALANCE_AFTER_LEARNING_OUT="${TMP_DIR}/bonus_parent_balance.after_learning.out.json"
      BONUS_PARENT_BALANCE_AFTER_LEARNING_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/v1/parent/bonus/balance" "" "${BONUS_PARENT_BALANCE_AFTER_LEARNING_OUT}" -H "Authorization: Bearer ${PARENT_ACCESS_TOKEN}")"
      assert_2xx "${BONUS_PARENT_BALANCE_AFTER_LEARNING_STATUS}" "${BONUS_PARENT_BALANCE_AFTER_LEARNING_OUT}" "parent bonus balance after learning"
      BONUS_PARENT_BALANCE_AFTER_LEARNING="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("balance",-1))' "${BONUS_PARENT_BALANCE_AFTER_LEARNING_OUT}")"
      if [[ "${BONUS_PARENT_BALANCE_AFTER_LEARNING}" != "${SMOKE_BONUS_COURSE_COMPLETION_POINTS}" ]]; then
        log "ERROR parent bonus balance after course completion: expected ${SMOKE_BONUS_COURSE_COMPLETION_POINTS}, got ${BONUS_PARENT_BALANCE_AFTER_LEARNING}"
        cat "${BONUS_PARENT_BALANCE_AFTER_LEARNING_OUT}"
        echo
        exit 1
      fi

      log "Admin reads bonus account after course completion"
      BONUS_ADMIN_ACCOUNT_AFTER_LEARNING_OUT="${TMP_DIR}/bonus_admin_account.after_learning.out.json"
      BONUS_ADMIN_ACCOUNT_AFTER_LEARNING_STATUS="$(request_json "GET" "${BONUS_BASE_URL}/v1/admin/bonus/accounts/${PAYMENT_PARENT_ID}" "" "${BONUS_ADMIN_ACCOUNT_AFTER_LEARNING_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
      assert_2xx "${BONUS_ADMIN_ACCOUNT_AFTER_LEARNING_STATUS}" "${BONUS_ADMIN_ACCOUNT_AFTER_LEARNING_OUT}" "admin bonus account after learning"
      BONUS_ADMIN_ACCOUNT_AFTER_LEARNING_BALANCE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("balance",-1))' "${BONUS_ADMIN_ACCOUNT_AFTER_LEARNING_OUT}")"
      if [[ "${BONUS_ADMIN_ACCOUNT_AFTER_LEARNING_BALANCE}" != "${SMOKE_BONUS_COURSE_COMPLETION_POINTS}" ]]; then
        log "ERROR admin bonus account after course completion: expected ${SMOKE_BONUS_COURSE_COMPLETION_POINTS}, got ${BONUS_ADMIN_ACCOUNT_AFTER_LEARNING_BALANCE}"
        cat "${BONUS_ADMIN_ACCOUNT_AFTER_LEARNING_OUT}"
        echo
        exit 1
      fi
    fi

    log "Student read own progress"
    STUDENT_PROGRESS_OUT="${TMP_DIR}/student.progress.out.json"
    STUDENT_PROGRESS_STATUS="$(request_json "GET" "${COURSE_BASE_URL}/v1/student/courses/${PAYMENT_COURSE_ID}/progress" "" "${STUDENT_PROGRESS_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}")"
    assert_2xx "${STUDENT_PROGRESS_STATUS}" "${STUDENT_PROGRESS_OUT}" "student progress"
    STUDENT_PROGRESS_PERCENT="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["progress_percent"])' "${STUDENT_PROGRESS_OUT}")"
    if [[ "${STUDENT_PROGRESS_PERCENT}" != "100.0" ]]; then
      log "ERROR student progress: expected 100.0, got ${STUDENT_PROGRESS_PERCENT}"
      cat "${STUDENT_PROGRESS_OUT}"
      echo
      exit 1
    fi

    log "Admin/parent view progress"
    PARENT_PROGRESS_OUT="${TMP_DIR}/parent.progress.out.json"
    PARENT_PROGRESS_STATUS="$(request_json "GET" "${COURSE_BASE_URL}/v1/parent/students/${PAYMENT_STUDENT_ID}/courses/progress?status=completed&limit=10&offset=0" "" "${PARENT_PROGRESS_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    assert_2xx "${PARENT_PROGRESS_STATUS}" "${PARENT_PROGRESS_OUT}" "parent progress read"
    PARENT_PROGRESS_MATCH="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(str(any(item.get("course_id")==sys.argv[2] and item.get("status")=="completed" for item in d.get("items", []))).lower())' "${PARENT_PROGRESS_OUT}" "${PAYMENT_COURSE_ID}")"
    if [[ "${PARENT_PROGRESS_MATCH}" != "true" ]]; then
      log "ERROR parent progress read: completed course not found"
      cat "${PARENT_PROGRESS_OUT}"
      echo
      exit 1
    fi

    log "Admin/parent view completed courses"
    PARENT_COMPLETED_OUT="${TMP_DIR}/parent.completed.out.json"
    PARENT_COMPLETED_STATUS="$(request_json "GET" "${COURSE_BASE_URL}/v1/parent/students/${PAYMENT_STUDENT_ID}/courses/completed?limit=10&offset=0" "" "${PARENT_COMPLETED_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
    assert_2xx "${PARENT_COMPLETED_STATUS}" "${PARENT_COMPLETED_OUT}" "parent completed read"
    PARENT_COMPLETED_MATCH="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(str(any(item.get("course_id")==sys.argv[2] and item.get("completed_at") for item in d.get("items", []))).lower())' "${PARENT_COMPLETED_OUT}" "${PAYMENT_COURSE_ID}")"
    if [[ "${PARENT_COMPLETED_MATCH}" != "true" ]]; then
      log "ERROR parent completed read: course not found"
      cat "${PARENT_COMPLETED_OUT}"
      echo
      exit 1
    fi

    if [[ "${SMOKE_LIVE_ENABLED}" == "1" ]]; then
      log "Create live room in live_class_service"
      LIVE_ROOM_PAYLOAD="${TMP_DIR}/live.room.json"
      cat > "${LIVE_ROOM_PAYLOAD}" <<JSON
{
  "courseId": "${PAYMENT_COURSE_ID}",
  "lessonId": "${TARGET_LESSON1_ID}",
  "participantsLimit": 5
}
JSON
      LIVE_ROOM_OUT="${TMP_DIR}/live.room.out.json"
      LIVE_ROOM_STATUS="$(request_json "POST" "${LIVE_BASE_URL}/v1/live/rooms" "${LIVE_ROOM_PAYLOAD}" "${LIVE_ROOM_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
      assert_2xx "${LIVE_ROOM_STATUS}" "${LIVE_ROOM_OUT}" "create live room"

      LIVE_ROOM_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["roomId"])' "${LIVE_ROOM_OUT}")"
      if [[ -z "${LIVE_ROOM_ID}" ]]; then
        log "ERROR create live room: roomId is empty"
        cat "${LIVE_ROOM_OUT}"
        echo
        exit 1
      fi

      log "Student join live room with active course access"
      LIVE_JOIN_OUT="${TMP_DIR}/live.join.out.json"
      LIVE_JOIN_STATUS="$(request_json "POST" "${LIVE_BASE_URL}/v1/live/rooms/${LIVE_ROOM_ID}/join" "" "${LIVE_JOIN_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}" -H "Content-Type: application/json")"
      assert_2xx "${LIVE_JOIN_STATUS}" "${LIVE_JOIN_OUT}" "student live join"

      log "Student leave live room"
      LIVE_LEAVE_PAYLOAD="${TMP_DIR}/live.leave.json"
      cat > "${LIVE_LEAVE_PAYLOAD}" <<JSON
{}
JSON
      LIVE_LEAVE_OUT="${TMP_DIR}/live.leave.out.json"
      LIVE_LEAVE_STATUS="$(request_json "POST" "${LIVE_BASE_URL}/v1/live/rooms/${LIVE_ROOM_ID}/leave" "${LIVE_LEAVE_PAYLOAD}" "${LIVE_LEAVE_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}" -H "Content-Type: application/json")"
      assert_2xx "${LIVE_LEAVE_STATUS}" "${LIVE_LEAVE_OUT}" "student live leave"

      log "Admin reads live attendance"
      LIVE_ATTENDANCE_OUT="${TMP_DIR}/live.attendance.out.json"
      LIVE_ATTENDANCE_STATUS="$(request_json "GET" "${LIVE_BASE_URL}/v1/live/rooms/${LIVE_ROOM_ID}/attendance" "" "${LIVE_ATTENDANCE_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}")"
      assert_2xx "${LIVE_ATTENDANCE_STATUS}" "${LIVE_ATTENDANCE_OUT}" "live attendance read"
      LIVE_ATTENDANCE_MATCH="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); student_account_id=sys.argv[2]; print(str(any(item.get("accountId")==student_account_id and item.get("sessionCount")==1 and item.get("lastLeftAt") for item in d)).lower())' "${LIVE_ATTENDANCE_OUT}" "${STUDENT_ACCOUNT_ID}")"
      if [[ "${LIVE_ATTENDANCE_MATCH}" != "true" ]]; then
        log "ERROR live attendance read: student attendance record not found"
        cat "${LIVE_ATTENDANCE_OUT}"
        echo
        exit 1
      fi

      log "Register denied student in auth_service"
      DENIED_STUDENT_EMAIL="student.denied.${SMOKE_ID}@example.com"
      DENIED_STUDENT_PASSWORD="${SMOKE_STUDENT_PASSWORD:-student12345}"
      DENIED_REGISTER_PAYLOAD="${TMP_DIR}/student.denied.register.json"
      cat > "${DENIED_REGISTER_PAYLOAD}" <<JSON
{
  "email": "${DENIED_STUDENT_EMAIL}",
  "password": "${DENIED_STUDENT_PASSWORD}",
  "default_role": "student"
}
JSON
      DENIED_REGISTER_OUT="${TMP_DIR}/student.denied.register.out.json"
      DENIED_REGISTER_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/register" "${DENIED_REGISTER_PAYLOAD}" "${DENIED_REGISTER_OUT}" -H "Content-Type: application/json")"
      assert_2xx "${DENIED_REGISTER_STATUS}" "${DENIED_REGISTER_OUT}" "register denied student auth"

      log "Denied student login in auth_service"
      DENIED_LOGIN_PAYLOAD="${TMP_DIR}/student.denied.login.json"
      cat > "${DENIED_LOGIN_PAYLOAD}" <<JSON
{
  "email": "${DENIED_STUDENT_EMAIL}",
  "password": "${DENIED_STUDENT_PASSWORD}",
  "session_fingerprint": "student-denied-smoke-${SMOKE_ID}"
}
JSON
      DENIED_LOGIN_OUT="${TMP_DIR}/student.denied.login.out.json"
      DENIED_LOGIN_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/login" "${DENIED_LOGIN_PAYLOAD}" "${DENIED_LOGIN_OUT}" -H "Content-Type: application/json")"
      assert_2xx "${DENIED_LOGIN_STATUS}" "${DENIED_LOGIN_OUT}" "denied student login"
      DENIED_STUDENT_ACCESS_TOKEN="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["access_token"])' "${DENIED_LOGIN_OUT}")"

      log "Denied student cannot join live room without course access"
      LIVE_DENIED_JOIN_OUT="${TMP_DIR}/live.denied.join.out.json"
      LIVE_DENIED_JOIN_STATUS="$(request_json "POST" "${LIVE_BASE_URL}/v1/live/rooms/${LIVE_ROOM_ID}/join" "" "${LIVE_DENIED_JOIN_OUT}" -H "Authorization: Bearer ${DENIED_STUDENT_ACCESS_TOKEN}" -H "Content-Type: application/json")"
      if [[ "${LIVE_DENIED_JOIN_STATUS}" != "403" ]]; then
        log "ERROR denied live join: expected HTTP 403, got ${LIVE_DENIED_JOIN_STATUS}"
        cat "${LIVE_DENIED_JOIN_OUT}"
        echo
        exit 1
      fi

      log "Live metrics"
      LIVE_METRICS_OUT="${TMP_DIR}/live.metrics.out.txt"
      curl -sS -H "Authorization: Bearer ${METRICS_TOKEN}" "${LIVE_BASE_URL}/metrics" > "${LIVE_METRICS_OUT}"
      if ! grep -q 'live_room_participant_joins_total' "${LIVE_METRICS_OUT}"; then
        log "ERROR live metrics: join metric family missing"
        cat "${LIVE_METRICS_OUT}"
        echo
        exit 1
      fi
      if ! grep -q 'live_room_attendance_sessions_total' "${LIVE_METRICS_OUT}"; then
        log "ERROR live metrics: attendance sessions metric family missing"
        cat "${LIVE_METRICS_OUT}"
        echo
        exit 1
      fi

      log "Close live room"
      LIVE_CLOSE_PAYLOAD="${TMP_DIR}/live.close.json"
      cat > "${LIVE_CLOSE_PAYLOAD}" <<JSON
{}
JSON
      LIVE_CLOSE_OUT="${TMP_DIR}/live.close.out.json"
      LIVE_CLOSE_STATUS="$(request_json "POST" "${LIVE_BASE_URL}/v1/live/rooms/${LIVE_ROOM_ID}/close" "${LIVE_CLOSE_PAYLOAD}" "${LIVE_CLOSE_OUT}" -H "Authorization: Bearer ${ACCESS_TOKEN}" -H "Content-Type: application/json")"
      assert_2xx "${LIVE_CLOSE_STATUS}" "${LIVE_CLOSE_OUT}" "close live room"
    fi
  fi
fi

log "OK"
log "teacher_id=${TEACHER_ID}"
log "course_id=${COURSE_ID}"
