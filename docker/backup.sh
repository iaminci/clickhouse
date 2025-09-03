#!/bin/bash

set -e

# Automatically export all variables
set -a
source .env
set +a

# Configuration
CONTAINER_NAME="clickhouse-server"
BACKUP_DIR="./clickhouse-backups"  # This maps to your mounted volume
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="incremental_backup_${TIMESTAMP}"
DATABASE_NAME="default"
RETENTION_DAYS=7
CH_USER="$CLICKHOUSE_USER"
CH_PASSWORD="$CLICKHOUSE_PASSWORD"
REMOTE_UPLOAD="minio"   # use 's3' or 'minio' to upload or leave empty to skip
S3_BUCKET_NAME="$S3_BUCKET_NAME"
STATE_FILE="./backup_state.json"
SKIP_ON_NO_CHANGES="false"  # Set to false to disable change detection
AWS_ENDPOINT_URL="http://192.168.0.215:9000"    # For MinIO required
AWS_PROFILE="minio-local"   # For MinIO required

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a ./clickhouse-backup.log
}

# Function to get current database state (focusing on data changes only)
get_database_state() {
    # Use a more stable query format that focuses only on data size
    docker exec ${CONTAINER_NAME} clickhouse-client \
        --user="${CH_USER}" \
        --password="${CH_PASSWORD}" \
        --query="
        SELECT 
            name as table_name,
            COALESCE(total_rows, 0) as total_rows,
            COALESCE(total_bytes, 0) as total_bytes
        FROM system.tables 
        WHERE database = '${DATABASE_NAME}'
        AND engine LIKE '%MergeTree%'
        ORDER BY name
        FORMAT TSV" 2>/dev/null || echo ""
}

# Function to compare states and detect changes
has_changes() {
    local current_state="$1"
    
    if [[ ! -f "$STATE_FILE" ]]; then
        log "No previous state file found - assuming changes exist"
        return 0  # Changes exist (first run)
    fi
    
    local previous_state=$(cat "$STATE_FILE" 2>/dev/null || echo "")
    
    if [[ -z "$previous_state" ]]; then
        log "Previous state file is empty - assuming changes exist"
        return 0  # Changes exist
    fi
    
    # Normalize whitespace and sort both states for stable comparison
    local current_normalized=$(echo "$current_state" | sort | tr -s ' \t')
    local previous_normalized=$(echo "$previous_state" | sort | tr -s ' \t')
    
    if [[ "$current_normalized" == "$previous_normalized" ]]; then
        log "No changes detected - database state unchanged"
        return 1  # No changes
    fi
    
    # Detailed comparison for logging
    log "Changes detected - analyzing differences:"
    
    # Create temporary files for comparison
    echo "$current_normalized" > /tmp/current_state.tsv
    echo "$previous_normalized" > /tmp/previous_state.tsv
    
    # Show what changed
    if command -v diff >/dev/null 2>&1; then
        local changes=$(diff /tmp/previous_state.tsv /tmp/current_state.tsv 2>/dev/null || true)
        if [[ -n "$changes" ]]; then
            log "  → Table changes detected:"
            echo "$changes" | while read -r line; do
                if [[ "$line" =~ ^\< ]]; then
                    local content=$(echo "$line" | cut -c3-)
                    log "    - Removed: $content"
                elif [[ "$line" =~ ^\> ]]; then
                    local content=$(echo "$line" | cut -c3-)
                    log "    + Added: $content"
                fi
            done
        fi
    else
        # Fallback: show current vs previous line counts
        local current_lines=$(echo "$current_state" | wc -l | xargs)
        local previous_lines=$(echo "$previous_state" | wc -l | xargs)
        log "  → Table count: $previous_lines → $current_lines"
    fi
    
    # Clean up temporary files
    rm -f /tmp/current_state.tsv /tmp/previous_state.tsv
    
    return 0  # Changes exist
}

# Function to save current state
save_current_state() {
    local current_state="$1"
    # Normalize and sort the state before saving
    echo "$current_state" | sort | tr -s ' \t' > "$STATE_FILE"
    log "Current database state saved to $STATE_FILE"
}

log "Starting backup process with timestamp: $TIMESTAMP"

# Check if container is running
if ! docker ps | grep -q ${CONTAINER_NAME}; then
    log "ERROR: Container ${CONTAINER_NAME} is not running"
    exit 1
fi

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Get current database state for change detection
CURRENT_STATE=""
if [[ "$SKIP_ON_NO_CHANGES" == "true" ]]; then
    log "Change detection enabled - checking for database changes..."
    
    log "Getting current database state..."
    CURRENT_STATE=$(get_database_state)
    
    if [[ -z "$CURRENT_STATE" ]]; then
        log "WARNING: Could not retrieve database state - proceeding with backup"
    else
        # Debug: show current state (first few lines)
        STATE_PREVIEW=$(echo "$CURRENT_STATE" | head -3)
        log "Current state preview:"
        log "$STATE_PREVIEW"
        
        if ! has_changes "$CURRENT_STATE"; then
            log "No changes detected since last backup - skipping backup creation"
            log "To force backup creation, set SKIP_ON_NO_CHANGES=false or delete $STATE_FILE"
            exit 0
        fi
        log "Changes detected - proceeding with backup creation"
    fi
else
    log "Change detection disabled - proceeding with backup creation"
fi

# Determine backup type based on existing backups
BACKUP_TYPE="full"
BASE_BACKUP=""
BACKUP_NAME=""

# Find the latest full backup
LAST_FULL_BACKUP=$(find "${BACKUP_DIR}" -name "full_backup_*" -type d 2>/dev/null | sort -r | head -n1)

# Check if there's already a full backup today
TODAY_FULL_BACKUP=$(find "${BACKUP_DIR}" -name "full_backup_$(date +%Y%m%d)*" -type d 2>/dev/null | head -n1)

# Find the most recent backup (any type)
PREV_BACKUP=$(find "${BACKUP_DIR}" -maxdepth 1 -type d \( -name "full_backup_*" -o -name "increment_backup_*" \) 2>/dev/null | sort -r | head -n1)

# Determine if we should create incremental or full backup
if [[ -z "$TODAY_FULL_BACKUP" || -z "$PREV_BACKUP" || -z "$LAST_FULL_BACKUP" ]]; then
    # Create full backup
    BACKUP_TYPE="full"
    BACKUP_NAME="full_backup_${TIMESTAMP}"
    log "Creating full backup: $BACKUP_NAME"
    
    if [[ -z "$LAST_FULL_BACKUP" ]]; then
        log "Reason: No previous full backup found"
    elif [[ -z "$TODAY_FULL_BACKUP" ]]; then
        log "Reason: No full backup exists for today"
    fi
else
    # Create incremental backup
    BACKUP_TYPE="incremental"
    BACKUP_NAME="increment_backup_${TIMESTAMP}"
    BASE_BACKUP=$(basename "$PREV_BACKUP")
    log "Creating incremental backup: $BACKUP_NAME (based on: $BASE_BACKUP)"
fi

# Create backup directory path
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_NAME}"
mkdir -p "$BACKUP_PATH"

# Execute backup command
if [[ "$BACKUP_TYPE" == "full" ]]; then
    log "Executing full backup command..."
    docker exec ${CONTAINER_NAME} clickhouse-client \
        --user="${CH_USER}" \
        --password="${CH_PASSWORD}" \
        --query="BACKUP DATABASE ${DATABASE_NAME} TO Disk('backups', '${BACKUP_NAME}') SETTINGS backup_threads=4"
else
    log "Executing incremental backup command..."
    docker exec ${CONTAINER_NAME} clickhouse-client \
        --user="${CH_USER}" \
        --password="${CH_PASSWORD}" \
        --query="BACKUP DATABASE ${DATABASE_NAME} TO Disk('backups', '${BACKUP_NAME}') SETTINGS base_backup=Disk('backups', '${BASE_BACKUP}'), backup_threads=4"
fi

log "Backup creation completed: ${BACKUP_NAME}"

# Verify backup was created
if docker exec ${CONTAINER_NAME} test -d "/var/lib/clickhouse/backups/${BACKUP_NAME}"; then
    log "Backup verification successful"
    
    # Get backup size
    BACKUP_SIZE=$(docker exec ${CONTAINER_NAME} du -sh "/var/lib/clickhouse/backups/${BACKUP_NAME}" | cut -f1)
    log "Backup size: ${BACKUP_SIZE}"
    
    # Copy backup from container to host
    log "Copying backup to host directory..."
    docker cp "${CONTAINER_NAME}:/var/lib/clickhouse/backups/${BACKUP_NAME}/." "${BACKUP_PATH}/"
    
    # Create metadata file
    cat > "${BACKUP_PATH}/metadata.txt" << EOF
Backup Type: ${BACKUP_TYPE}
Base backup: ${BASE_BACKUP:-"N/A"}
Timestamp: ${TIMESTAMP}
Database: ${DATABASE_NAME}
Created: $(date)
EOF
    
    log "Backup copied to: ${BACKUP_PATH}"
else
    log "ERROR: Backup verification failed"
    exit 1
fi

# Save current state after successful backup (only if change detection is enabled)
if [[ "$SKIP_ON_NO_CHANGES" == "true" && -n "$CURRENT_STATE" ]]; then
    save_current_state "$CURRENT_STATE"
fi

# Clean up very old backups based on retention days
log "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -maxdepth 1 -type d \( -name "full_backup_*" -o -name "increment_backup_*" \) -mtime +${RETENTION_DAYS} -exec rm -rf {} \; 2>/dev/null || true

# Copy to remote storage (S3, minio, etc.)
if [ "${REMOTE_UPLOAD}" = "s3" ]; then
    log "Uploading backup to S3..."
    # Add your S3 upload logic here
    aws s3 sync "${BACKUP_DIR}/${BACKUP_NAME}" "s3://${S3_BUCKET_NAME}/${BACKUP_NAME}/"
elif [ "${REMOTE_UPLOAD}" = "minio" ]; then
    log "Uploading backup to minio..."
    # Add your minio upload logic here
    export AWS_ENDPOINT_URL="$AWS_ENDPOINT_URL"
    aws s3 sync "${BACKUP_DIR}/${BACKUP_NAME}" "s3://${S3_BUCKET_NAME}/${BACKUP_NAME}/"  --endpoint-url $AWS_ENDPOINT_URL --profile $AWS_PROFILE
else
    log "REMOTE_UPLOAD env is empty skipping remote upload."
fi

log "BACKUP COMPLETED SUCCESSFULLY: ${BACKUP_NAME} (${BACKUP_TYPE})"