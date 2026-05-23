#!/usr/bin/env bash
set -euo pipefail

# Web-facing student invite smoke:
# parent login -> create child -> create invite -> child accept invite -> child /api/auth/me

WEB_BASE_URL="${WEB_BASE_URL:-http://127.0.0.1:3000}"
PARENT_EMAIL="${PARENT_EMAIL:-test3parent@mail.com}"
PARENT_PASSWORD="${PARENT_PASSWORD:-}"
STUDENT_PASSWORD="${STUDENT_PASSWORD:-student-pass-123}"
SESSION_FINGERPRINT="${SESSION_FINGERPRINT:-web-invite-smoke-$(date +%s)}"

if [[ -z "${PARENT_PASSWORD}" ]]; then
  echo "[invite-smoke] ERROR PARENT_PASSWORD is required" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

PARENT_COOKIES="${TMP_DIR}/parent.cookies"
CHILD_COOKIES="${TMP_DIR}/child.cookies"

log() {
  printf '[invite-smoke] %s\n' "$*"
}

request_json() {
  # usage: request_json METHOD URL BODY_FILE OUT_BODY_FILE [curl args...]
  local method="$1"
  local url="$2"
  local body_file="$3"
  local out_file="$4"
  shift 4

  curl -sS -o "${out_file}" -w '%{http_code}' -X "${method}" "${url}" "$@" \
    --data-binary "@${body_file}"
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

log "Health"
HEALTH_CODE="$(curl -sS -o /dev/null -w '%{http_code}' "${WEB_BASE_URL}/api/health")"
if [[ "${HEALTH_CODE}" != "200" ]]; then
  log "ERROR health: HTTP ${HEALTH_CODE}"
  exit 1
fi

SMOKE_ID="$(date +%s)"
CHILD_EMAIL="web-invite-smoke-${SMOKE_ID}@example.com"

log "Parent login"
LOGIN_PAYLOAD="${TMP_DIR}/login.json"
cat > "${LOGIN_PAYLOAD}" <<JSON
{
  "email": "${PARENT_EMAIL}",
  "password": "${PARENT_PASSWORD}",
  "session_fingerprint": "${SESSION_FINGERPRINT}-parent"
}
JSON
LOGIN_OUT="${TMP_DIR}/login.out.json"
LOGIN_STATUS="$(request_json "POST" "${WEB_BASE_URL}/api/auth/login" "${LOGIN_PAYLOAD}" "${LOGIN_OUT}" -c "${PARENT_COOKIES}" -H "Content-Type: application/json")"
assert_2xx "${LOGIN_STATUS}" "${LOGIN_OUT}" "parent login"
PARENT_USER_ID="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "parent" in d["user"]["roles"]; print(d["user"]["user_id"])' "${LOGIN_OUT}")"
log "Parent login OK user_id=${PARENT_USER_ID}"

log "Create child"
CHILD_PAYLOAD="${TMP_DIR}/child.json"
cat > "${CHILD_PAYLOAD}" <<JSON
{
  "email": "${CHILD_EMAIL}",
  "display_name": "Web Invite Smoke ${SMOKE_ID}"
}
JSON
CHILD_OUT="${TMP_DIR}/child.out.json"
CHILD_STATUS="$(request_json "POST" "${WEB_BASE_URL}/api/parent/me/students" "${CHILD_PAYLOAD}" "${CHILD_OUT}" -b "${PARENT_COOKIES}" -H "Content-Type: application/json")"
assert_2xx "${CHILD_STATUS}" "${CHILD_OUT}" "create child"
STUDENT_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["user_id"])' "${CHILD_OUT}")"
log "Create child OK student_id=${STUDENT_ID}"

log "Create invite"
INVITE_PAYLOAD="${TMP_DIR}/invite.json"
cat > "${INVITE_PAYLOAD}" <<JSON
{
  "ttl_seconds": 86400,
  "idempotency_key": "web-invite-smoke-${SMOKE_ID}",
  "delivery_channel": "link"
}
JSON
INVITE_OUT="${TMP_DIR}/invite.out.json"
INVITE_STATUS="$(request_json "POST" "${WEB_BASE_URL}/api/parent/me/students/${STUDENT_ID}/invite" "${INVITE_PAYLOAD}" "${INVITE_OUT}" -b "${PARENT_COOKIES}" -H "Content-Type: application/json")"
assert_2xx "${INVITE_STATUS}" "${INVITE_OUT}" "create invite"
INVITE_TOKEN="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["status"] == "pending"; print(d["invite_token"])' "${INVITE_OUT}")"
if [[ -z "${INVITE_TOKEN}" ]]; then
  log "ERROR create invite: invite_token is empty"
  exit 1
fi
log "Create invite OK"

log "Accept invite"
ACCEPT_PAYLOAD="${TMP_DIR}/accept.json"
cat > "${ACCEPT_PAYLOAD}" <<JSON
{
  "token": "${INVITE_TOKEN}",
  "password": "${STUDENT_PASSWORD}",
  "session_fingerprint": "${SESSION_FINGERPRINT}-student"
}
JSON
ACCEPT_OUT="${TMP_DIR}/accept.out.json"
ACCEPT_STATUS="$(request_json "POST" "${WEB_BASE_URL}/api/auth/invites/accept" "${ACCEPT_PAYLOAD}" "${ACCEPT_OUT}" -c "${CHILD_COOKIES}" -H "Content-Type: application/json")"
assert_2xx "${ACCEPT_STATUS}" "${ACCEPT_OUT}" "accept invite"
python3 - "${ACCEPT_OUT}" "${STUDENT_ID}" <<'PY'
import json
import sys

path, expected_student_id = sys.argv[1], sys.argv[2]
data = json.load(open(path))
assert data["user"]["user_id"] == expected_student_id, data
assert data["user"]["roles"] == ["student"], data
print(f"[invite-smoke] Accept invite OK account_id={data['user']['account_id']}")
PY

log "Child /api/auth/me"
ME_OUT="${TMP_DIR}/me.out.json"
ME_CODE="$(curl -sS -o "${ME_OUT}" -w '%{http_code}' -b "${CHILD_COOKIES}" "${WEB_BASE_URL}/api/auth/me")"
assert_2xx "${ME_CODE}" "${ME_OUT}" "child me"
python3 - "${ME_OUT}" "${STUDENT_ID}" <<'PY'
import json
import sys

path, expected_student_id = sys.argv[1], sys.argv[2]
data = json.load(open(path))
assert data["user_id"] == expected_student_id, data
assert data["roles"] == ["student"], data
assert data["status"] == "active", data
print(f"[invite-smoke] Child me OK user_id={data['user_id']} status={data['status']}")
PY

log "OK"
