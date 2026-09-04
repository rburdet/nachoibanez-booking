#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
source .env
set +a

BACKUP_DIR="backups"
RETENTION_DAYS=14
TIMESTAMP="$(date +%Y-%m-%d_%H%M%S)"
DUMP_FILE="${BACKUP_DIR}/calendso_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"
docker compose exec -T database pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$DUMP_FILE"

find "$BACKUP_DIR" -name 'calendso_*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete

rclone copy "$DUMP_FILE" "r2:${R2_BUCKET_NAME}/backups/"
