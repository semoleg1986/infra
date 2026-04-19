#!/usr/bin/env bash
set -euo pipefail

# Rotates backup directories by age and count.
#
# Defaults:
#   BACKUP_ROOT=~/backups/postgres
#   KEEP_DAYS=14
#   KEEP_LAST=14
#
# Removes dirs older than KEEP_DAYS, then enforces KEEP_LAST newest dirs.

BACKUP_ROOT="${BACKUP_ROOT:-$HOME/backups/postgres}"
KEEP_DAYS="${KEEP_DAYS:-14}"
KEEP_LAST="${KEEP_LAST:-14}"

if [[ ! -d "${BACKUP_ROOT}" ]]; then
  echo "[rotate] backup root does not exist, nothing to do: ${BACKUP_ROOT}"
  exit 0
fi

echo "[rotate] root=${BACKUP_ROOT} keep_days=${KEEP_DAYS} keep_last=${KEEP_LAST}"

# 1) Remove directories older than KEEP_DAYS
while IFS= read -r -d '' dir; do
  echo "[rotate] remove old: ${dir}"
  rm -rf "${dir}"
done < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime +"${KEEP_DAYS}" -print0)

# 2) Keep only newest KEEP_LAST directories
mapfile -t dirs < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | awk '{print $2}')
count="${#dirs[@]}"
if (( count > KEEP_LAST )); then
  for ((i=KEEP_LAST; i<count; i++)); do
    echo "[rotate] remove extra: ${dirs[$i]}"
    rm -rf "${dirs[$i]}"
  done
fi

echo "[rotate] done"
