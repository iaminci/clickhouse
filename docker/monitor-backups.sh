#!/bin/bash

CONTAINER_NAME="clickhouse-server"
BACKUP_DIR="./clickhouse-backups"
CH_USER="admin"
CH_PASSWORD="password"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Check container health
if ! docker ps | grep -q ${CONTAINER_NAME}; then
    log "ERROR: Container ${CONTAINER_NAME} is not running"
    exit 1
fi

# Check backup directory
if [ ! -d "${BACKUP_DIR}" ]; then
    log "ERROR: Backup directory ${BACKUP_DIR} does not exist"
    exit 1
fi

# List recent backups
log "Recent backups:"
ls -lah "${BACKUP_DIR}" | grep -E "(full_backup_|incremental_backup_)" | tail -10

# Check backup disk usage
log "Backup disk usage:"
du -sh "${BACKUP_DIR}"

# Verify latest backup integrity
LATEST_BACKUP=$(find "${BACKUP_DIR}" -name "*backup_*" -type d | sort -r | head -n1)
if [ -n "$LATEST_BACKUP" ]; then
    BACKUP_NAME=$(basename "$LATEST_BACKUP")
    log "Verifying latest backup: ${BACKUP_NAME}"
    
    # Test backup by trying to read metadata
    if docker exec ${CONTAINER_NAME} test -f "/var/lib/clickhouse/backups/${BACKUP_NAME}/.backup"; then
        log "Backup integrity check: PASSED"
    else
        log "Backup integrity check: FAILED - Missing .backup file"
    fi
fi

# Check ClickHouse status
log "ClickHouse server status:"
docker exec ${CONTAINER_NAME} clickhouse-client \
    --user="${CH_USER}" \
    --password="${CH_PASSWORD}" \
    --query="SELECT version()" || log "ERROR: Cannot connect to ClickHouse"

log "Backup monitoring completed"