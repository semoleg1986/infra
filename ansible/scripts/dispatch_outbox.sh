#!/usr/bin/env bash
set -euo pipefail

SERVICE="${SERVICE:-all}"
LIMIT="${LIMIT:-100}"

log() {
  printf '[dispatch-outbox] %s\n' "$*"
}

run_dispatch() {
  local service_name="$1"
  local workdir="$2"
  log "dispatching ${service_name} outbox with limit=${LIMIT}"
  cd "${workdir}"
  sudo docker compose -f compose.yaml exec "${service_name}" \
    python -m src.interface.http.main dispatch-outbox --limit "${LIMIT}"
}

case "${SERVICE}" in
  payments_service)
    run_dispatch "payments_service" "/opt/curs/payments_service"
    ;;
  course_service)
    run_dispatch "course_service" "/opt/curs/course_service"
    ;;
  all)
    run_dispatch "payments_service" "/opt/curs/payments_service"
    run_dispatch "course_service" "/opt/curs/course_service"
    ;;
  *)
    printf 'Unsupported SERVICE=%s\n' "${SERVICE}" >&2
    exit 1
    ;;
esac

log "OK"
