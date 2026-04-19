#!/usr/bin/env bash
set -euo pipefail

# Creates per-database PostgreSQL backups from dockerized postgres container.
# Output: BACKUP_ROOT/<timestamp>/<db>.dump

POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-curs_postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups/postgres}"
DBS="${DBS:-auth_service_prod,users_service_prod,course_service_prod,attribution_service_prod,live_class_service_prod,payments_service_prod}"

timestamp="$(date +%Y%m%d_%H%M%S)"
backup_dir="${BACKUP_ROOT}/${timestamp}"

mkdir -p "${backup_dir}"

echo "[backup] container=${POSTGRES_CONTAINER}"
echo "[backup] output=${backup_dir}"
echo "[backup] databases=${DBS}"

IFS=',' read -r -a dbs <<< "${DBS}"
for db in "${dbs[@]}"; do
  db="$(echo "${db}" | xargs)"
  if [[ -z "${db}" ]]; then
    continue
  fi

  out_file="${backup_dir}/${db}.dump"
  echo "[backup] dumping ${db} -> ${out_file}"
  docker exec -e "PGPASSWORD=${POSTGRES_PASSWORD}" "${POSTGRES_CONTAINER}" \
    pg_dump -U "${POSTGRES_USER}" -d "${db}" -Fc -f "/tmp/${db}.dump"
  docker cp "${POSTGRES_CONTAINER}:/tmp/${db}.dump" "${out_file}"
  docker exec "${POSTGRES_CONTAINER}" rm -f "/tmp/${db}.dump"
done

echo "[backup] done: ${backup_dir}"
