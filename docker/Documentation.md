# ClickHouse Docker Backup Automation Guide

## Overview
This guide is tailored for your specific ClickHouse Docker setup with automated full and incremental backups plus point-in-time recovery.

## Required Configuration Files

### 1. backups.xml Configuration
Create/update your `./backups.xml` file:

```xml
<clickhouse>
    <!-- Backup configuration -->
    <backup>
        <!-- Allow backups to local disk -->
        <allowed_disk>backups</allowed_disk>
        <allowed_disk>default</allowed_disk>
    </backup>
    
    <!-- Storage configuration for backups -->
    <storage_configuration>
        <disks>
            <backups>
                <type>local</type>
                <path>/var/lib/clickhouse/backups/</path>
            </backups>
        </disks>
        
        <policies>
            <backup_policy>
                <volumes>
                    <main>
                        <disk>backups</disk>
                    </main>
                </volumes>
            </backup_policy>
        </policies>
    </storage_configuration>
    
    <!-- Optional: Enable query log for point-in-time recovery -->
    <query_log>
        <database>system</database>
        <table>query_log</table>
        <partition_by>toYYYYMM(event_date)</partition_by>
        <flush_interval_milliseconds>7500</flush_interval_milliseconds>
    </query_log>
</clickhouse>
```

### 2. s3.xml Configuration (Optional - for remote backups)
If you want to enable S3 backups, uncomment the s3.xml line and create:

```xml
<clickhouse>
    <storage_configuration>
        <disks>
            <s3_backup>
                <type>s3</type>
                <endpoint>https://your-bucket.s3.amazonaws.com/clickhouse-backups/</endpoint>
                <access_key_id>YOUR_ACCESS_KEY</access_key_id>
                <secret_access_key>YOUR_SECRET_KEY</secret_access_key>
                <region>us-east-1</region>
                <server_side_encryption_configuration>
                    <rule>
                        <apply_server_side_encryption_by_default>
                            <sse_algorithm>AES256</sse_algorithm>
                        </apply_server_side_encryption_by_default>
                    </rule>
                </server_side_encryption_configuration>
            </s3_backup>
        </disks>
        
        <policies>
            <s3_backup_policy>
                <volumes>
                    <main>
                        <disk>s3_backup</disk>
                    </main>
                </volumes>
            </s3_backup_policy>
        </policies>
    </storage_configuration>
    
    <backup>
        <allowed_disk>s3_backup</allowed_disk>
    </backup>
</clickhouse>
```

## Backup Strategy Options

### Option 1: Using Native ClickHouse BACKUP Commands (Recommended for your setup)

Your current setup is perfect for using native ClickHouse backup commands since you already have the backup volume mounted.

## Automated Backup Scripts

### Full Backup Script (`full-backup.sh`)
```bash
#!/bin/bash
set -e

# Configuration matching your Docker setup
CONTAINER_NAME="clickhouse-server"
BACKUP_DIR="./clickhouse-backups"  # This maps to your mounted volume
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="full_backup_${TIMESTAMP}"
RETENTION_DAYS=30
CH_USER="admin"
CH_PASSWORD="password"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/clickhouse-backup.log
}

# Create backup directory on host
mkdir -p "${BACKUP_DIR}"

log "Starting full backup: ${BACKUP_NAME}"

# Check if container is running
if ! docker ps | grep -q ${CONTAINER_NAME}; then
    log "ERROR: Container ${CONTAINER_NAME} is not running"
    exit 1
fi

# Full backup using native BACKUP command
docker exec ${CONTAINER_NAME} clickhouse-client \
    --user="${CH_USER}" \
    --password="${CH_PASSWORD}" \
    --query="BACKUP DATABASE default TO Disk('backups', '${BACKUP_NAME}') SETTINGS backup_threads=4"

log "Full backup completed: ${BACKUP_NAME}"

# Verify backup was created
if docker exec ${CONTAINER_NAME} test -d "/var/lib/clickhouse/backups/${BACKUP_NAME}"; then
    log "Backup verification successful"
    
    # Get backup size
    BACKUP_SIZE=$(docker exec ${CONTAINER_NAME} du -sh "/var/lib/clickhouse/backups/${BACKUP_NAME}" | cut -f1)
    log "Backup size: ${BACKUP_SIZE}"
else
    log "ERROR: Backup verification failed"
    exit 1
fi

# Cleanup old backups (keeping last X days)
log "Cleaning up backups older than ${RETENTION_DAYS} days"
find "${BACKUP_DIR}" -name "full_backup_*" -type d -mtime +${RETENTION_DAYS} -exec rm -rf {} \; 2>/dev/null || true

# Optional: Copy to remote storage (S3, etc.)
if [ "${ENABLE_S3_UPLOAD:-false}" = "true" ]; then
    log "Uploading backup to S3..."
    # Add your S3 upload logic here
    # aws s3 sync "${BACKUP_DIR}/${BACKUP_NAME}" "s3://your-bucket/clickhouse-backups/${BACKUP_NAME}/"
fi

log "Full backup process completed successfully"
```

### Incremental Backup Script (`incremental-backup.sh`)
```bash
#!/bin/bash
set -e

# Configuration
CONTAINER_NAME="clickhouse-server"
BACKUP_DIR="./clickhouse-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_NAME="incremental_backup_${TIMESTAMP}"
CH_USER="admin"
CH_PASSWORD="password"

# Function to log messages
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a /var/log/clickhouse-backup.log
}

# Find the latest full backup
LATEST_FULL=$(find "${BACKUP_DIR}" -name "full_backup_*" -type d 2>/dev/null | sort -r | head -n1)

if [ -z "$LATEST_FULL" ]; then
    log "No full backup found. Creating full backup first."
    ./full-backup.sh
    exit 0
fi

BASE_BACKUP_NAME=$(basename ${LATEST_FULL})
log "Starting incremental backup: ${BACKUP_NAME}"
log "Base backup: ${BASE_BACKUP_NAME}"

# Check if container is running
if ! docker ps | grep -q ${CONTAINER_NAME}; then
    log "ERROR: Container ${CONTAINER_NAME} is not running"
    exit 1
fi

# Get list of tables modified since last backup
LAST_BACKUP_TIME=$(docker exec ${CONTAINER_NAME} stat -c %Y "/var/lib/clickhouse/backups/${BASE_BACKUP_NAME}" 2>/dev/null || echo 0)

# Create incremental backup
# Note: ClickHouse native backup doesn't support true incremental backups
# This approach backs up tables that have been modified
MODIFIED_TABLES=$(docker exec ${CONTAINER_NAME} clickhouse-client \
    --user="${CH_USER}" \
    --password="${CH_PASSWORD}" \
    --query="
    SELECT DISTINCT name
    FROM system.tables 
    WHERE database = 'default' 
    AND engine LIKE '%MergeTree%'
    AND metadata_modification_time > toDateTime(${LAST_BACKUP_TIME})
    FORMAT TSV" | tr '\n' ' ')

if [ -z "${MODIFIED_TABLES// }" ]; then
    log "No tables modified since last backup. Skipping incremental backup."
    exit 0
fi

log "Tables to backup: ${MODIFIED_TABLES}"

# Backup modified tables only
for table in ${MODIFIED_TABLES}; do
    log "Backing up table: ${table}"
    docker exec ${CONTAINER_NAME} clickhouse-client \
        --user="${CH_USER}" \
        --password="${CH_PASSWORD}" \
        --query="BACKUP TABLE default.${table} TO Disk('backups', '${BACKUP_NAME}/${table}')"
done

# Create backup metadata
docker exec ${CONTAINER_NAME} bash -c "echo 'Base backup: ${BASE_BACKUP_NAME}' > /var/lib/clickhouse/backups/${BACKUP_NAME}/metadata.txt"
docker exec ${CONTAINER_NAME} bash -c "echo 'Tables: ${MODIFIED_TABLES}' >> /var/lib/clickhouse/backups/${BACKUP_NAME}/metadata.txt"
docker exec ${CONTAINER_NAME} bash -c "echo 'Timestamp: ${TIMESTAMP}' >> /var/lib/clickhouse/backups/${BACKUP_NAME}/metadata.txt"

log "Incremental backup completed: ${BACKUP_NAME}"
```

### Point-in-Time Recovery and Restore Script (`restore.sh`)
```bash
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
```

### Backup Monitoring Script (`monitor-backups.sh`)
```bash
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
```

## Automation Setup

### 1. Make Scripts Executable
```bash
chmod +x full-backup.sh
chmod +x incremental-backup.sh
chmod +x restore.sh
chmod +x monitor-backups.sh
```

### 2. Cron Job Setup
Add to crontab (`crontab -e`):
```bash
# Full backup every day at 2 AM
0 2 * * * /path/to/your/scripts/full-backup.sh >> /var/log/clickhouse-backup.log 2>&1

# Incremental backup every 4 hours during business hours
0 6,10,14,18,22 * * * /path/to/your/scripts/incremental-backup.sh >> /var/log/clickhouse-backup.log 2>&1

# Weekly monitoring and verification
0 3 * * 0 /path/to/your/scripts/monitor-backups.sh >> /var/log/clickhouse-backup.log 2>&1

# Daily log rotation to prevent log files from growing too large
0 0 * * * logrotate /etc/logrotate.d/clickhouse-backup
```

### 3. Log Rotation Configuration
Create `/etc/logrotate.d/clickhouse-backup`:
```
/var/log/clickhouse-backup.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 644 root root
}
```

## Testing Your Setup

### 1. Test Full Backup
```bash
# Run a test full backup
./full-backup.sh

# Check if backup was created
ls -la ./clickhouse-backups/
```

### 2. Test Incremental Backup
```bash
# Create some test data
docker exec clickhouse-server clickhouse-client \
    --user=admin --password=password \
    --query="CREATE TABLE IF NOT EXISTS test_table (id UInt64, name String) ENGINE = MergeTree() ORDER BY id"

docker exec clickhouse-server clickhouse-client \
    --user=admin --password=password \
    --query="INSERT INTO test_table VALUES (1, 'test')"

# Run incremental backup
./incremental-backup.sh
```

### 3. Test Restore
```bash
# Test restore (use a test backup)
./restore.sh full_backup_YYYYMMDD_HHMMSS
```

## Environment Variables (Optional)
Create a `.env` file for easier configuration:
```bash
# .env file
CLICKHOUSE_USER=admin
CLICKHOUSE_PASSWORD=password
CONTAINER_NAME=clickhouse-server
BACKUP_RETENTION_DAYS=30
ENABLE_S3_UPLOAD=false
S3_BUCKET=your-backup-bucket
AWS_ACCESS_KEY_ID=your-access-key
AWS_SECRET_ACCESS_KEY=your-secret-key
```

Then update your scripts to use these variables:
```bash
# At the top of your scripts
source .env 2>/dev/null || true
```

## S3 Integration (Optional)

### 1. Enable S3 Configuration
Uncomment the s3.xml line in your docker-compose.yml and create the s3.xml file as shown above.

### 2. S3 Upload Script (`s3-upload.sh`)
```bash
#!/bin/bash
set -e

BACKUP_NAME="$1"
BACKUP_DIR="./clickhouse-backups"
S3_BUCKET="${S3_BUCKET:-your-backup-bucket}"

if [ -z "$BACKUP_NAME" ]; then
    echo "Usage: $0 <backup_name>"
    exit 1
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

if [ -d "${BACKUP_DIR}/${BACKUP_NAME}" ]; then
    log "Uploading ${BACKUP_NAME} to S3..."
    aws s3 sync "${BACKUP_DIR}/${BACKUP_NAME}" "s3://${S3_BUCKET}/clickhouse-backups/${BACKUP_NAME}/" --delete
    log "Upload completed"
else
    log "ERROR: Backup ${BACKUP_NAME} not found"
    exit 1
fi
```

## Monitoring and Alerting

### 1. Health Check Script (`health-check.sh`)
```bash
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
```

### 2. Integration with Monitoring Systems
For Prometheus/Grafana monitoring, you can expose metrics:

```bash
# Add to your monitoring script
echo "clickhouse_backup_last_success_timestamp $(date +%s)" > /var/lib/node_exporter/textfile_collector/clickhouse_backup.prom
echo "clickhouse_backup_size_bytes $(du -sb ./clickhouse-backups | cut -f1)" >> /var/lib/node_exporter/textfile_collector/clickhouse_backup.prom
```

## Best Practices for Your Setup

### 1. Storage and Security
- **Backup Location**: Your `./clickhouse-backups` directory should be on a separate disk/mount from your ClickHouse data
- **Permissions**: Ensure the backup directory has proper ownership:
  ```bash
  sudo chown -R $(docker exec clickhouse-server id -u clickhouse):$(docker exec clickhouse-server id -g clickhouse) ./clickhouse-backups
  ```
- **Encryption**: For sensitive data, consider encrypting backups:
  ```bash
  # Add to your backup scripts
  tar -czf - "${BACKUP_DIR}/${BACKUP_NAME}" | gpg --symmetric --cipher-algo AES256 > "${BACKUP_NAME}.tar.gz.gpg"
  ```

### 2. Performance Optimization
- **Backup Threads**: Adjust `backup_threads` in your backup commands based on your system:
  ```sql
  BACKUP DATABASE default TO Disk('backups', 'backup_name') SETTINGS backup_threads=8
  ```
- **Compression**: Enable compression in your ClickHouse config:
  ```xml
  <compression>
      <case>
          <min_part_size>10000000000</min_part_size>
          <min_part_size_ratio>0.01</min_part_size_ratio>
          <method>lz4</method>
      </case>
  </compression>
  ```

### 3. Monitoring Integration
- **Docker Health Check**: Your existing health check is good, but you can extend it:
  ```yaml
  healthcheck:
    test: ["CMD-SHELL", "clickhouse-client --user=admin --password=password --query='SELECT 1' && test -d /var/lib/clickhouse/backups || exit 1"]
  ```

### 4. Network and Resources
- **Docker Resource Limits**: Add resource limits to prevent backup operations from affecting performance:
  ```yaml
  deploy:
    resources:
      limits:
        memory: 4G
        cpus: '2.0'
  ```

## Troubleshooting Your Setup

### Common Issues and Solutions

1. **Permission Denied Errors**
   ```bash
   # Fix ownership of backup directory
   docker exec clickhouse-server chown -R clickhouse:clickhouse /var/lib/clickhouse/backups
   ```

2. **Container Not Found**
   ```bash
   # Verify container name matches
   docker ps --filter name=clickhouse-server
   ```

3. **Backup Directory Not Accessible**
   ```bash
   # Check volume mount
   docker exec clickhouse-server ls -la /var/lib/clickhouse/backups
   ```

4. **Authentication Errors**
   ```bash
   # Test connection
   docker exec clickhouse-server clickhouse-client --user=admin --password=password --query="SELECT version()"
   ```

5. **Disk Space Issues**
   ```bash
   # Monitor disk usage
   docker exec clickhouse-server df -h /var/lib/clickhouse
   du -sh ./clickhouse-backups/
   ```

### Debugging Commands

```bash
# Check ClickHouse logs
docker logs clickhouse-server --tail=100

# Verify backup configuration
docker exec clickhouse-server clickhouse-client --user=admin --password=password --query="SELECT * FROM system.disks WHERE name = 'backups'"

# List available backups
docker exec clickhouse-server clickhouse-client --user=admin --password=password --query="SELECT * FROM system.backups"

# Check backup disk space
docker exec clickhouse-server clickhouse-client --user=admin --password=password --query="SELECT name, path, free_space, total_space FROM system.disks"
```

### Emergency Recovery Procedures

If your main database is corrupted:

1. **Stop the container:**
   ```bash
   docker stop clickhouse-server
   ```

2. **Backup current data (if possible):**
   ```bash
   cp -r ./clickhouse-data ./clickhouse-data-backup-$(date +%Y%m%d_%H%M%S)
   ```

3. **Clear data volume:**
   ```bash
   docker volume rm clickhouse-data
   docker volume create --name=clickhouse-data
   ```

4. **Restart and restore:**
   ```bash
   docker start clickhouse-server
   sleep 30  # Wait for startup
   ./restore.sh your_backup_name
   ```

## Summary

Your current setup is well-configured for automated backups. The key points:

- ✅ **Native ClickHouse BACKUP/RESTORE** commands work well with your volume setup
- ✅ **Local backups** are stored in `./clickhouse-backups` 
- ✅ **Authentication** is configured with admin/password
- ✅ **Health checks** ensure container reliability
- ✅ **External volumes** provide data persistence

**Next Steps:**
1. Create the configuration files (`backups.xml`, optionally `s3.xml`)
2. Set up the backup scripts with appropriate paths
3. Test full backup and restore procedures
4. Configure cron jobs for automation
5. Set up monitoring and alerting

This setup provides enterprise-grade backup automation tailored specifically to your Docker ClickHouse configuration.