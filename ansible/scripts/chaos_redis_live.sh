#!/usr/bin/env bash
set -euo pipefail

AUTH_BASE_URL="${AUTH_BASE_URL:-http://127.0.0.1:8000}"
USERS_BASE_URL="${USERS_BASE_URL:-http://127.0.0.1:8002}"
COURSE_BASE_URL="${COURSE_BASE_URL:-http://127.0.0.1:8001}"
PAYMENTS_BASE_URL="${PAYMENTS_BASE_URL:-http://127.0.0.1:8004}"
LIVE_BASE_URL="${LIVE_BASE_URL:-http://127.0.0.1:8010}"
REDIS_CONTAINER_NAME="${REDIS_CONTAINER_NAME:-curs_redis}"
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin12345}"
PARENT_PASSWORD="${PARENT_PASSWORD:-parent12345}"
STUDENT_PASSWORD="${STUDENT_PASSWORD:-student12345}"
SERVICE_TOKEN="${SERVICE_TOKEN:-sometokencourse}"
CHAOS_ITERATIONS="${CHAOS_ITERATIONS:-20}"
CHAOS_INTERVAL_SECONDS="${CHAOS_INTERVAL_SECONDS:-1}"
CHAOS_RESTART_AT_ITERATION="${CHAOS_RESTART_AT_ITERATION:-8}"
SESSION_PREFIX="${SESSION_PREFIX:-chaos-redis-live}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

join_success=0
join_fail=0
leave_success=0
leave_fail=0
attendance_success=0
attendance_fail=0
post_restart_join_success=0
post_restart_attendance_success=0
restart_triggered=0
restart_completed=0

log() {
  printf '[chaos-redis-live] %s\n' "$*"
}

request_json() {
  local method="$1"
  local url="$2"
  local body_file="$3"
  local out_file="$4"
  shift 4
  local status
  if [[ -n "${body_file}" ]]; then
    status="$(curl -sS -o "${out_file}" -w '%{http_code}' -X "${method}" "${url}" "$@" --data-binary "@${body_file}" || true)"
  else
    status="$(curl -sS -o "${out_file}" -w '%{http_code}' -X "${method}" "${url}" "$@" || true)"
  fi
  printf '%s' "${status}"
}

assert_2xx() {
  local status="$1"
  local body_file="$2"
  local step="$3"
  if [[ ! "${status}" =~ ^2 ]]; then
    log "ERROR ${step}: HTTP ${status}"
    cat "${body_file}" 2>/dev/null || true
    echo
    exit 1
  fi
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

probe_live_health() {
  local out_file="$1"
  request_json "GET" "${LIVE_BASE_URL}/healthz" "" "${out_file}"
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
log "COURSE_BASE_URL=${COURSE_BASE_URL}"
log "PAYMENTS_BASE_URL=${PAYMENTS_BASE_URL}"
log "LIVE_BASE_URL=${LIVE_BASE_URL}"
log "REDIS_CONTAINER_NAME=${REDIS_CONTAINER_NAME}"
log "CHAOS_ITERATIONS=${CHAOS_ITERATIONS}"
log "CHAOS_INTERVAL_SECONDS=${CHAOS_INTERVAL_SECONDS}"
log "CHAOS_RESTART_AT_ITERATION=${CHAOS_RESTART_AT_ITERATION}"

SMOKE_ID="$(date +%s)"
TEACHER_USER_ID="teacher-chaos-live-${SMOKE_ID}"
TEACHER_EMAIL="teacher.chaos.live.${SMOKE_ID}@example.com"
PARENT_EMAIL="parent.chaos.live.${SMOKE_ID}@example.com"
STUDENT_EMAIL="student.chaos.live.${SMOKE_ID}@example.com"

log "Bootstrap admin login"
ADMIN_LOGIN_PAYLOAD="${TMP_DIR}/admin-login.json"
cat >"${ADMIN_LOGIN_PAYLOAD}" <<JSON
{
  "email": "${ADMIN_EMAIL}",
  "password": "${ADMIN_PASSWORD}",
  "session_fingerprint": "${SESSION_PREFIX}-admin"
}
JSON
ADMIN_LOGIN_OUT="${TMP_DIR}/admin-login.out.json"
ADMIN_LOGIN_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/login" "${ADMIN_LOGIN_PAYLOAD}" "${ADMIN_LOGIN_OUT}" -H "Content-Type: application/json")"
assert_2xx "${ADMIN_LOGIN_STATUS}" "${ADMIN_LOGIN_OUT}" "bootstrap admin login"
ADMIN_ACCESS_TOKEN="$(json_get "${ADMIN_LOGIN_OUT}" "access_token")"

log "Create teacher"
TEACHER_PAYLOAD="${TMP_DIR}/teacher.json"
cat >"${TEACHER_PAYLOAD}" <<JSON
{
  "user_id": "${TEACHER_USER_ID}",
  "email": "${TEACHER_EMAIL}",
  "display_name": "Chaos Redis Teacher ${SMOKE_ID}",
  "roles": ["teacher"]
}
JSON
TEACHER_OUT="${TMP_DIR}/teacher.out.json"
TEACHER_STATUS="$(request_json "POST" "${USERS_BASE_URL}/v1/admin/users" "${TEACHER_PAYLOAD}" "${TEACHER_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${TEACHER_STATUS}" "${TEACHER_OUT}" "create teacher"

log "Create course"
COURSE_PAYLOAD="${TMP_DIR}/course.json"
cat >"${COURSE_PAYLOAD}" <<JSON
{
  "title": "Chaos Redis Live Course ${SMOKE_ID}",
  "teacher_id": "${TEACHER_USER_ID}",
  "starts_at": "2026-09-01T09:00:00Z",
  "duration_days": 30
}
JSON
COURSE_OUT="${TMP_DIR}/course.out.json"
COURSE_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/admin/courses" "${COURSE_PAYLOAD}" "${COURSE_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${COURSE_STATUS}" "${COURSE_OUT}" "create course"
COURSE_ID="$(json_get "${COURSE_OUT}" "course_id")"

MODULE_ID="module-chaos-live-${SMOKE_ID}"
LESSON_ID="lesson-chaos-live-${SMOKE_ID}-1"

log "Create and publish lesson structure"
MODULE_PAYLOAD="${TMP_DIR}/module.json"
cat >"${MODULE_PAYLOAD}" <<JSON
{
  "module_id": "${MODULE_ID}",
  "title": "Chaos Redis Module ${SMOKE_ID}",
  "description": "chaos",
  "is_required": true
}
JSON
MODULE_OUT="${TMP_DIR}/module.out.json"
MODULE_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/admin/courses/${COURSE_ID}/modules" "${MODULE_PAYLOAD}" "${MODULE_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${MODULE_STATUS}" "${MODULE_OUT}" "create module"

LESSON_PAYLOAD="${TMP_DIR}/lesson.json"
cat >"${LESSON_PAYLOAD}" <<JSON
{
  "lesson_id": "${LESSON_ID}",
  "title": "Chaos Redis Lesson 1",
  "description": "chaos",
  "content_type": "video",
  "content_ref": "cdn://chaos/live/${SMOKE_ID}/1",
  "duration_minutes": 15,
  "is_preview": false
}
JSON
LESSON_OUT="${TMP_DIR}/lesson.out.json"
LESSON_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/admin/courses/${COURSE_ID}/modules/${MODULE_ID}/lessons" "${LESSON_PAYLOAD}" "${LESSON_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${LESSON_STATUS}" "${LESSON_OUT}" "create lesson"

LESSON_PATCH_PAYLOAD="${TMP_DIR}/lesson.patch.json"
printf '{\n  "status": "published"\n}\n' >"${LESSON_PATCH_PAYLOAD}"
LESSON_PATCH_OUT="${TMP_DIR}/lesson.patch.out.json"
LESSON_PATCH_STATUS="$(request_json "PATCH" "${COURSE_BASE_URL}/v1/admin/courses/${COURSE_ID}/modules/${MODULE_ID}/lessons/${LESSON_ID}" "${LESSON_PATCH_PAYLOAD}" "${LESSON_PATCH_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${LESSON_PATCH_STATUS}" "${LESSON_PATCH_OUT}" "publish lesson"

MODULE_PATCH_PAYLOAD="${TMP_DIR}/module.patch.json"
printf '{\n  "status": "published"\n}\n' >"${MODULE_PATCH_PAYLOAD}"
MODULE_PATCH_OUT="${TMP_DIR}/module.patch.out.json"
MODULE_PATCH_STATUS="$(request_json "PATCH" "${COURSE_BASE_URL}/v1/admin/courses/${COURSE_ID}/modules/${MODULE_ID}" "${MODULE_PATCH_PAYLOAD}" "${MODULE_PATCH_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${MODULE_PATCH_STATUS}" "${MODULE_PATCH_OUT}" "publish module"

COURSE_PUBLISH_OUT="${TMP_DIR}/course.publish.out.json"
COURSE_PUBLISH_STATUS="$(request_json "POST" "${COURSE_BASE_URL}/v1/admin/courses/${COURSE_ID}/publish" "" "${COURSE_PUBLISH_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}")"
assert_2xx "${COURSE_PUBLISH_STATUS}" "${COURSE_PUBLISH_OUT}" "publish course"

log "Register parent"
PARENT_REGISTER_PAYLOAD="${TMP_DIR}/parent-register.json"
cat >"${PARENT_REGISTER_PAYLOAD}" <<JSON
{
  "email": "${PARENT_EMAIL}",
  "password": "${PARENT_PASSWORD}",
  "default_role": "parent"
}
JSON
PARENT_REGISTER_OUT="${TMP_DIR}/parent-register.out.json"
PARENT_REGISTER_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/register" "${PARENT_REGISTER_PAYLOAD}" "${PARENT_REGISTER_OUT}" -H "Content-Type: application/json")"
assert_2xx "${PARENT_REGISTER_STATUS}" "${PARENT_REGISTER_OUT}" "register parent"

log "Parent login"
PARENT_LOGIN_PAYLOAD="${TMP_DIR}/parent-login.json"
cat >"${PARENT_LOGIN_PAYLOAD}" <<JSON
{
  "email": "${PARENT_EMAIL}",
  "password": "${PARENT_PASSWORD}",
  "session_fingerprint": "${SESSION_PREFIX}-parent"
}
JSON
PARENT_LOGIN_OUT="${TMP_DIR}/parent-login.out.json"
PARENT_LOGIN_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/login" "${PARENT_LOGIN_PAYLOAD}" "${PARENT_LOGIN_OUT}" -H "Content-Type: application/json")"
assert_2xx "${PARENT_LOGIN_STATUS}" "${PARENT_LOGIN_OUT}" "parent login"
PARENT_ACCESS_TOKEN="$(json_get "${PARENT_LOGIN_OUT}" "access_token")"
PARENT_ME_OUT="${TMP_DIR}/parent-me.out.json"
PARENT_ME_STATUS="$(request_json "GET" "${AUTH_BASE_URL}/v1/auth/me" "" "${PARENT_ME_OUT}" -H "Authorization: Bearer ${PARENT_ACCESS_TOKEN}")"
assert_2xx "${PARENT_ME_STATUS}" "${PARENT_ME_OUT}" "parent auth me"
PAYMENT_PARENT_ID="$(json_get "${PARENT_ME_OUT}" "account_id")"

log "Create parent profile"
PARENT_PAYLOAD="${TMP_DIR}/parent.json"
cat >"${PARENT_PAYLOAD}" <<JSON
{
  "user_id": "${PAYMENT_PARENT_ID}",
  "email": "${PARENT_EMAIL}",
  "display_name": "Chaos Redis Parent ${SMOKE_ID}",
  "roles": ["parent"]
}
JSON
PARENT_OUT="${TMP_DIR}/parent.out.json"
PARENT_STATUS="$(request_json "POST" "${USERS_BASE_URL}/v1/admin/users" "${PARENT_PAYLOAD}" "${PARENT_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${PARENT_STATUS}" "${PARENT_OUT}" "create parent profile"

log "Register student"
STUDENT_REGISTER_PAYLOAD="${TMP_DIR}/student-register.json"
cat >"${STUDENT_REGISTER_PAYLOAD}" <<JSON
{
  "email": "${STUDENT_EMAIL}",
  "password": "${STUDENT_PASSWORD}",
  "default_role": "student"
}
JSON
STUDENT_REGISTER_OUT="${TMP_DIR}/student-register.out.json"
STUDENT_REGISTER_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/register" "${STUDENT_REGISTER_PAYLOAD}" "${STUDENT_REGISTER_OUT}" -H "Content-Type: application/json")"
assert_2xx "${STUDENT_REGISTER_STATUS}" "${STUDENT_REGISTER_OUT}" "register student"

log "Student login"
STUDENT_LOGIN_PAYLOAD="${TMP_DIR}/student-login.json"
cat >"${STUDENT_LOGIN_PAYLOAD}" <<JSON
{
  "email": "${STUDENT_EMAIL}",
  "password": "${STUDENT_PASSWORD}",
  "session_fingerprint": "${SESSION_PREFIX}-student"
}
JSON
STUDENT_LOGIN_OUT="${TMP_DIR}/student-login.out.json"
STUDENT_LOGIN_STATUS="$(request_json "POST" "${AUTH_BASE_URL}/v1/auth/login" "${STUDENT_LOGIN_PAYLOAD}" "${STUDENT_LOGIN_OUT}" -H "Content-Type: application/json")"
assert_2xx "${STUDENT_LOGIN_STATUS}" "${STUDENT_LOGIN_OUT}" "student login"
STUDENT_ACCESS_TOKEN="$(json_get "${STUDENT_LOGIN_OUT}" "access_token")"
STUDENT_ME_OUT="${TMP_DIR}/student-me.out.json"
STUDENT_ME_STATUS="$(request_json "GET" "${AUTH_BASE_URL}/v1/auth/me" "" "${STUDENT_ME_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}")"
assert_2xx "${STUDENT_ME_STATUS}" "${STUDENT_ME_OUT}" "student auth me"
PAYMENT_STUDENT_ID="$(json_get "${STUDENT_ME_OUT}" "user_id")"
STUDENT_ACCOUNT_ID="$(json_get "${STUDENT_ME_OUT}" "account_id")"

log "Create student profile"
STUDENT_PAYLOAD="${TMP_DIR}/student.json"
cat >"${STUDENT_PAYLOAD}" <<JSON
{
  "user_id": "${PAYMENT_STUDENT_ID}",
  "email": "${STUDENT_EMAIL}",
  "display_name": "Chaos Redis Student ${SMOKE_ID}",
  "roles": ["student"]
}
JSON
STUDENT_OUT="${TMP_DIR}/student.out.json"
STUDENT_STATUS="$(request_json "POST" "${USERS_BASE_URL}/v1/admin/users" "${STUDENT_PAYLOAD}" "${STUDENT_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${STUDENT_STATUS}" "${STUDENT_OUT}" "create student profile"

log "Create parent-student link"
LINK_PAYLOAD="${TMP_DIR}/parent-student-link.json"
cat >"${LINK_PAYLOAD}" <<JSON
{
  "parent_id": "${PAYMENT_PARENT_ID}",
  "student_id": "${PAYMENT_STUDENT_ID}",
  "note": "chaos-redis-live"
}
JSON
LINK_OUT="${TMP_DIR}/parent-student-link.out.json"
LINK_STATUS="$(request_json "POST" "${USERS_BASE_URL}/v1/admin/links" "${LINK_PAYLOAD}" "${LINK_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${LINK_STATUS}" "${LINK_OUT}" "create parent-student link"

log "Create payment access"
PAYMENT_PAYLOAD="${TMP_DIR}/payment-intent-bootstrap.json"
cat >"${PAYMENT_PAYLOAD}" <<JSON
{
  "parent_id": "${PAYMENT_PARENT_ID}",
  "student_id": "${PAYMENT_STUDENT_ID}",
  "course_id": "${COURSE_ID}",
  "idempotency_key": "chaos-redis-live-${SMOKE_ID}"
}
JSON
PAYMENT_OUT="${TMP_DIR}/payment-bootstrap.out.json"
PAYMENT_STATUS="$(request_json "POST" "${PAYMENTS_BASE_URL}/v1/parent/payments/intents" "${PAYMENT_PAYLOAD}" "${PAYMENT_OUT}" -H "Authorization: Bearer ${PARENT_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${PAYMENT_STATUS}" "${PAYMENT_OUT}" "create payment intent"
PAYMENT_INTENT_ID="$(json_get "${PAYMENT_OUT}" "payment_intent_id")"

APPROVE_PAYLOAD="${TMP_DIR}/payment-approve-bootstrap.json"
printf '{}\n' >"${APPROVE_PAYLOAD}"
APPROVE_OUT="${TMP_DIR}/payment-approve-bootstrap.out.json"
APPROVE_STATUS="$(request_json "POST" "${PAYMENTS_BASE_URL}/v1/admin/payments/${PAYMENT_INTENT_ID}/approve" "${APPROVE_PAYLOAD}" "${APPROVE_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
if [[ ! "${APPROVE_STATUS}" =~ ^2 ]] && ! grep -q "уже существует active доступ" "${APPROVE_OUT}" 2>/dev/null; then
  log "ERROR approve payment intent: HTTP ${APPROVE_STATUS}"
  cat "${APPROVE_OUT}" 2>/dev/null || true
  echo
  exit 1
fi

log "Create live room"
LIVE_ROOM_PAYLOAD="${TMP_DIR}/live-room.json"
cat >"${LIVE_ROOM_PAYLOAD}" <<JSON
{
  "courseId": "${COURSE_ID}",
  "lessonId": "${LESSON_ID}",
  "participantsLimit": 5
}
JSON
LIVE_ROOM_OUT="${TMP_DIR}/live-room.out.json"
LIVE_ROOM_STATUS="$(request_json "POST" "${LIVE_BASE_URL}/v1/live/rooms" "${LIVE_ROOM_PAYLOAD}" "${LIVE_ROOM_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}" -H "Content-Type: application/json")"
assert_2xx "${LIVE_ROOM_STATUS}" "${LIVE_ROOM_OUT}" "create live room"
LIVE_ROOM_ID="$(json_get "${LIVE_ROOM_OUT}" "roomId")"

log "Bootstrap setup complete"

for ((i = 1; i <= CHAOS_ITERATIONS; i++)); do
  phase="before-restart"
  if (( restart_completed == 1 )); then
    phase="after-restart"
  fi

  if (( i == CHAOS_RESTART_AT_ITERATION )); then
    log "Restarting ${REDIS_CONTAINER_NAME}"
    restart_triggered=1
    docker restart "${REDIS_CONTAINER_NAME}" >/dev/null
    restart_completed=1
    phase="after-restart"
    log "Restart completed"
  fi

  JOIN_OUT="${TMP_DIR}/join-${i}.out.json"
  JOIN_STATUS="$(request_json "POST" "${LIVE_BASE_URL}/v1/live/rooms/${LIVE_ROOM_ID}/join" "" "${JOIN_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}" -H "Content-Type: application/json")"
  if [[ "${JOIN_STATUS}" == "201" || "${JOIN_STATUS}" == "200" ]]; then
    join_success=$((join_success + 1))
    if (( restart_completed == 1 )); then
      post_restart_join_success=$((post_restart_join_success + 1))
    fi
  else
    join_fail=$((join_fail + 1))
    detail="$(cat "${JOIN_OUT}" 2>/dev/null || true)"
    log "iter=${i} phase=${phase} join_status=${JOIN_STATUS} body=${detail}"
  fi

  LEAVE_PAYLOAD="${TMP_DIR}/leave-${i}.json"
  printf '{}\n' >"${LEAVE_PAYLOAD}"
  LEAVE_OUT="${TMP_DIR}/leave-${i}.out.json"
  LEAVE_STATUS="$(request_json "POST" "${LIVE_BASE_URL}/v1/live/rooms/${LIVE_ROOM_ID}/leave" "${LEAVE_PAYLOAD}" "${LEAVE_OUT}" -H "Authorization: Bearer ${STUDENT_ACCESS_TOKEN}" -H "Content-Type: application/json")"
  if [[ "${LEAVE_STATUS}" == "201" || "${LEAVE_STATUS}" == "200" ]]; then
    leave_success=$((leave_success + 1))
  else
    leave_fail=$((leave_fail + 1))
    detail="$(cat "${LEAVE_OUT}" 2>/dev/null || true)"
    log "iter=${i} phase=${phase} leave_status=${LEAVE_STATUS} body=${detail}"
  fi

  ATTENDANCE_OUT="${TMP_DIR}/attendance-${i}.out.json"
  ATTENDANCE_STATUS="$(request_json "GET" "${LIVE_BASE_URL}/v1/live/rooms/${LIVE_ROOM_ID}/attendance" "" "${ATTENDANCE_OUT}" -H "Authorization: Bearer ${ADMIN_ACCESS_TOKEN}")"
  if [[ "${ATTENDANCE_STATUS}" == "200" ]]; then
    attendance_success=$((attendance_success + 1))
    if (( restart_completed == 1 )); then
      post_restart_attendance_success=$((post_restart_attendance_success + 1))
    fi
  else
    attendance_fail=$((attendance_fail + 1))
    detail="$(cat "${ATTENDANCE_OUT}" 2>/dev/null || true)"
    log "iter=${i} phase=${phase} attendance_status=${ATTENDANCE_STATUS} body=${detail}"
  fi

  if (( restart_completed == 1 )); then
    HEALTH_OUT="${TMP_DIR}/live-health-${i}.out.txt"
    HEALTH_STATUS="$(probe_live_health "${HEALTH_OUT}")"
    if [[ "${HEALTH_STATUS}" != "200" ]]; then
      detail="$(cat "${HEALTH_OUT}" 2>/dev/null || true)"
      log "iter=${i} phase=${phase} live_health_status=${HEALTH_STATUS} body=${detail}"
    fi
  fi

  sleep "${CHAOS_INTERVAL_SECONDS}"
done

log "Summary"
log "restart_triggered=${restart_triggered}"
log "join_success=${join_success}"
log "join_fail=${join_fail}"
log "leave_success=${leave_success}"
log "leave_fail=${leave_fail}"
log "attendance_success=${attendance_success}"
log "attendance_fail=${attendance_fail}"
log "post_restart_join_success=${post_restart_join_success}"
log "post_restart_attendance_success=${post_restart_attendance_success}"

if (( post_restart_join_success == 0 )); then
  log "RESULT live join path did not recover after redis restart"
  exit 1
fi

if (( post_restart_attendance_success == 0 )); then
  log "RESULT live attendance path did not recover after redis restart"
  exit 2
fi

log "RESULT live join/leave/attendance recovered after redis restart"
