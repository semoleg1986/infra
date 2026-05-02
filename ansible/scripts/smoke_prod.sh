#!/usr/bin/env bash
set -euo pipefail

# Smoke check for production contour:
# auth -> users -> course -> payments(optional) -> student learning -> parent read

AUTH_BASE_URL="${AUTH_BASE_URL:-http://127.0.0.1:8000}"
USERS_BASE_URL="${USERS_BASE_URL:-http://127.0.0.1:8002}"
COURSE_BASE_URL="${COURSE_BASE_URL:-http://127.0.0.1:8001}"
PAYMENTS_BASE_URL="${PAYMENTS_BASE_URL:-http://127.0.0.1:8004}"
SMOKE_PAYMENTS_ENABLED="${SMOKE_PAYMENTS_ENABLED:-0}"
SMOKE_LEARNING_ENABLED="${SMOKE_LEARNING_ENABLED:-1}"
SMOKE_PAYMENTS_PROVISION_RELATIONS="${SMOKE_PAYMENTS_PROVISION_RELATIONS:-1}"
SMOKE_PAYMENTS_COURSE_ID="${SMOKE_PAYMENTS_COURSE_ID:-}"

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
  LESSON_ID="lesson-smoke-${SMOKE_ID}-${LESSON_NUM}"
  LESSON_PAYLOAD="${TMP_DIR}/lesson-${LESSON_NUM}.json"
  cat > "${LESSON_PAYLOAD}" <<JSON
{
  "lesson_id": "${LESSON_ID}",
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
  PAYMENT_STATUS="$(request_json "POST" "${PAYMENTS_BASE_URL}/v1/parent/payments/intents" "${PAYMENT_PAYLOAD}" "${PAYMENT_OUT}" -H "Authorization: Bearer ${PARENT_ACCESS_TOKEN}" -H "Content-Type: application/json")"
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

  if [[ "${SMOKE_LEARNING_ENABLED}" == "1" ]]; then
    LESSON1_ID="lesson-smoke-${SMOKE_ID}-1"
    LESSON2_ID="lesson-smoke-${SMOKE_ID}-2"

    log "Student complete first lesson"
    STUDENT_COMPLETE1_OUT="${TMP_DIR}/student.complete1.out.json"
    STUDENT_COMPLETE1_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/student/courses/${PAYMENT_COURSE_ID}/lessons/${LESSON1_ID}/complete" "" "${STUDENT_COMPLETE1_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}")"
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
    STUDENT_COMPLETE2_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/student/courses/${PAYMENT_COURSE_ID}/lessons/${LESSON2_ID}/complete" "" "${STUDENT_COMPLETE2_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}")"
    assert_2xx "${STUDENT_COMPLETE2_STATUS}" "${STUDENT_COMPLETE2_OUT}" "student complete lesson 2"
    COURSE_STATUS_2="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["course_status"])' "${STUDENT_COMPLETE2_OUT}")"
    if [[ "${COURSE_STATUS_2}" != "completed" ]]; then
      log "ERROR student complete lesson 2: expected completed, got ${COURSE_STATUS_2}"
      cat "${STUDENT_COMPLETE2_OUT}"
      echo
      exit 1
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
  fi
fi

log "OK"
log "teacher_id=${TEACHER_ID}"
log "course_id=${COURSE_ID}"
