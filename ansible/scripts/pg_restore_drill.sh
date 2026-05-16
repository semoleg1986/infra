#!/usr/bin/env bash
set -euo pipefail

# Restores backups into *_drill databases for restore verification.
# Expected backup files: BACKUP_DIR/<db>.dump

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-curs_postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
BACKUP_DIR="${BACKUP_DIR:-}"
RESTORE_SUFFIX="${RESTORE_SUFFIX:-_drill}"
DBS="${DBS:-auth_service_prod,users_service_prod,course_service_prod,commercial_catalog_service_prod,attribution_service_prod,live_class_service_prod,payments_service_prod,bonus_wallet_service_prod}"

if [[ -z "${BACKUP_DIR}" ]]; then
  echo "[restore] BACKUP_DIR is required"
  echo "Usage: BACKUP_DIR=/path/to/20260419_120000 ./scripts/pg_restore_drill.sh"
  exit 1
fi

if [[ ! -d "${BACKUP_DIR}" ]]; then
  echo "[restore] BACKUP_DIR does not exist: ${BACKUP_DIR}"
  exit 1
fi

echo "[restore] container=${POSTGRES_CONTAINER}"
echo "[restore] backup_dir=${BACKUP_DIR}"
echo "[restore] suffix=${RESTORE_SUFFIX}"
echo "[restore] databases=${DBS}"

IFS=',' read -r -a dbs <<< "${DBS}"
for db in "${dbs[@]}"; do
  db="$(echo "${db}" | xargs)"
  if [[ -z "${db}" ]]; then
    continue
  fi

  src_file="${BACKUP_DIR}/${db}.dump"
  target_db="${db}${RESTORE_SUFFIX}"
  if [[ ! -f "${src_file}" ]]; then
    echo "[restore] skip ${db}: file not found (${src_file})"
    continue
  fi

  echo "[restore] ${db} -> ${target_db}"
  docker cp "${src_file}" "${POSTGRES_CONTAINER}:/tmp/${db}.dump"

  docker exec -e "PGPASSWORD=${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
    psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "DROP DATABASE IF EXISTS \"${target_db}\";"
  docker exec -e "PGPASSWORD=${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
    psql -U "${POSTGRES_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE \"${target_db}\";"

  docker exec -e "PGPASSWORD=${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
    pg_restore -U "${POSTGRES_USER}" -d "${target_db}" --clean --if-exists --no-owner --no-privileges "/tmp/${db}.dump"

  # Lightweight verification: at least one user table exists.
  table_count="$(docker exec -e "PGPASSWORD=${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
    psql -U "${POSTGRES_USER}" -d "${target_db}" -tA \
    -c "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');")"
  echo "[restore] ${target_db}: user_tables=${table_count}"

  docker exec "${POSTGRES_CONTAINER}" rm -f "/tmp/${db}.dump"
done

echo "[restore] done"
