#!/bin/bash
set -e

CONTAINER_NAME="clickhouse-server"
BACKUP_NAME="$1"
RESTORE_TYPE="$2"  # "full" or "incremental"
CH_USER="admin"
CH_PASSWORD="password"

if [ -z "$BACKUP_NAME" ]; then
    echo "Usage: $0 <backup_name> [restore_type]"
    echo ""
    echo "Available backups:"
    docker exec ${CONTAINER_NAME} ls -la /var/lib/clickhouse/backups/ 2>/dev/null || echo "No backups found"
    exit 1
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Verify backup exists
if ! docker exec ${CONTAINER_NAME} test -d "/var/lib/clickhouse/backups/${BACKUP_NAME}"; then
    log "ERROR: Backup ${BACKUP_NAME} not found"
    exit 1
fi

log "Starting restore from backup: ${BACKUP_NAME}"

# Create a temporary database for restoration
TEMP_DB="restored_$(date +%s)"
log "Creating temporary database: ${TEMP_DB}"

docker exec ${CONTAINER_NAME} clickhouse-client \
    --user="${CH_USER}" \
    --password="${CH_PASSWORD}" \
    --query="CREATE DATABASE IF NOT EXISTS ${TEMP_DB}"

# Restore to temporary database first
log "Restoring backup to temporary database..."
docker exec ${CONTAINER_NAME} clickhouse-client \
    --user="${CH_USER}" \
    --password="${CH_PASSWORD}" \
    --query="RESTORE DATABASE default AS ${TEMP_DB} FROM Disk('backups', '${BACKUP_NAME}')"

# Verify restoration
TABLE_COUNT=$(docker exec ${CONTAINER_NAME} clickhouse-client \
    --user="${CH_USER}" \
    --password="${CH_PASSWORD}" \
    --query="SELECT COUNT(*) FROM system.tables WHERE database = '${TEMP_DB}'" 2>/dev/null || echo "0")

log "Restored ${TABLE_COUNT} tables to temporary database"

if [ "${TABLE_COUNT}" -eq "0" ]; then
    log "ERROR: No tables were restored. Check backup integrity."
    exit 1
fi

# Option to replace current database (dangerous!)
read -p "Do you want to replace the current 'default' database? [y/N]: " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "WARNING: This will drop the current 'default' database!"
    read -p "Are you absolutely sure? Type 'YES' to continue: " confirmation
    
    if [ "$confirmation" = "YES" ]; then
        log "Dropping current default database..."
        docker exec ${CONTAINER_NAME} clickhouse-client \
            --user="${CH_USER}" \
            --password="${CH_PASSWORD}" \
            --query="DROP DATABASE IF EXISTS default"
        
        log "Renaming restored database to default..."
        docker exec ${CONTAINER_NAME} clickhouse-client \
            --user="${CH_USER}" \
            --password="${CH_PASSWORD}" \
            --query="RENAME DATABASE ${TEMP_DB} TO default"
        
        log "Database restoration completed successfully!"
    else
        log "Restoration cancelled. Temporary database ${TEMP_DB} preserved for inspection."
    fi
else
    log "Restoration completed to temporary database: ${TEMP_DB}"
    log "You can inspect the data and manually copy what you need."
fi