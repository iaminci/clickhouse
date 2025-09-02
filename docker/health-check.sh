#!/bin/bash

CONTAINER_NAME="clickhouse-server"
CH_USER="admin"
CH_PASSWORD="password"
BACKUP_DIR="./clickhouse-backups"

# Check if latest backup is recent (within 25 hours for daily backups)
LATEST_BACKUP=$(find "${BACKUP_DIR}" -name "full_backup_*" -type d -mtime -1 | head -n1)

if [ -z "$LATEST_BACKUP" ]; then
    echo "ALERT: No recent full backup found!"
    exit 1
fi

# Check ClickHouse connectivity
if ! docker exec ${CONTAINER_NAME} clickhouse-client \
    --user="${CH_USER}" --password="${CH_PASSWORD}" \
    --query="SELECT 1" >/dev/null 2>&1; then
    echo "ALERT: Cannot connect to ClickHouse!"
    exit 1
fi

echo "OK: All checks passed"