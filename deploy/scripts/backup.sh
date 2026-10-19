#!/usr/bin/env bash
# ============================================================================
# Backup the Trypr database AND uploaded files. Run ON THE DROPLET.
#
#   ./deploy/scripts/backup.sh                 # one backup now
#   ./deploy/scripts/backup.sh --install-cron  # nightly at 03:45
#
# Writes deploy/backups/trypr-db-<stamp>.dump (pg_restore format) and trypr-uploads-<stamp>.tar.gz,
# keeps 14 days. These live on the same disk as the data: copy them off the droplet too
# (e.g. `./deploy.sh pull-backups` from your laptop).
#
# Restore:  docker compose --env-file .env.production exec -T db pg_restore -U trypr -d trypr --clean --if-exists < dump
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO_ROOT="$(pwd)"
BACKUP_DIR="${REPO_ROOT}/deploy/backups"
COMPOSE="docker compose --env-file .env.production"

if [[ "${1:-}" == "--install-cron" ]]; then
  line="45 3 * * * ${REPO_ROOT}/deploy/scripts/backup.sh >> ${BACKUP_DIR}/cron.log 2>&1"
  mkdir -p "$BACKUP_DIR"
  ( crontab -l 2>/dev/null | grep -vF "deploy/scripts/backup.sh" ; echo "$line" ) | crontab -
  echo "Installed: $line"
  exit 0
fi

set -a; source .env.production; set +a
mkdir -p "$BACKUP_DIR"
stamp="$(date +%Y%m%d-%H%M%S)"

$COMPOSE ps --status running --services | grep -qx db || { echo "ERROR: db container is not running" >&2; exit 1; }

dump="${BACKUP_DIR}/trypr-db-${stamp}.dump"
$COMPOSE exec -T -e PGPASSWORD="${DB_PASSWORD}" db pg_dump -Fc --no-owner --no-acl -U "${DB_USER}" "${DB_NAME}" > "$dump"
[[ -s "$dump" ]] || { rm -f "$dump"; echo "ERROR: empty dump" >&2; exit 1; }

docker run --rm -v trypr-uploads:/data:ro -v "${BACKUP_DIR}:/backup" alpine \
  tar czf "/backup/trypr-uploads-${stamp}.tar.gz" -C /data .

find "$BACKUP_DIR" -name 'trypr-*' -mtime +14 -delete
echo "Backup OK: $(basename "$dump") ($(du -h "$dump" | cut -f1)), uploads archive written."
