#!/usr/bin/env bash
set -euo pipefail

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-curs_postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
RESTORE_SUFFIX="${RESTORE_SUFFIX:-_drill}"
DBS="${DBS:-auth_service_prod,users_service_prod,course_service_prod,commercial_catalog_service_prod,attribution_service_prod,live_class_service_prod,payments_service_prod,bonus_wallet_service_prod}"

echo "[restore-cleanup] container=${POSTGRES_CONTAINER}"
echo "[restore-cleanup] suffix=${RESTORE_SUFFIX}"
echo "[restore-cleanup] databases=${DBS}"

IFS=',' read -r -a dbs <<< "${DBS}"
for db in "${dbs[@]}"; do
  db="$(echo "${db}" | xargs)"
  if [[ -z "${db}" ]]; then
    continue
  fi

  target_db="${db}${RESTORE_SUFFIX}"
  echo "[restore-cleanup] dropping ${target_db}"
  docker exec -e "PGPASSWORD=${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
    psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${target_db}\";"
done

echo "[restore-cleanup] done"
