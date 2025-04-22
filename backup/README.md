# ClickHouse Backup Setup

This directory contains the necessary Kubernetes manifests to deploy the Altinity ClickHouse Backup tool for your ClickHouse cluster.

## Components

1. **ch-backup-pv.yaml**: Persistent Volume and Persistent Volume Claim for backup storage
2. **clickhouse-backup-config.yaml**: ConfigMap with the clickhouse-backup configuration
3. **clickhouse-backup-rbac.yaml**: ServiceAccount, Role, and RoleBinding for the clickhouse-backup deployment
4. **modified-clickhouse.yaml**: ClickHouseInstallation custom resource with clickhouse-backup as a sidecar container

## Deployment

To deploy the ClickHouse Backup components, run:

```bash
kubectl apply -f ch-backup-pv.yaml
kubectl apply -f clickhouse-backup-config.yaml
kubectl apply -f clickhouse-backup-rbac.yaml
kubectl apply -f modified-clickhouse.yaml
```

## Configuration

The default configuration uses S3-compatible storage (MinIO). To modify storage settings, edit the `clickhouse-backup-config.yaml` file and update the corresponding storage section (e.g., the `s3:` section for Amazon S3 or MinIO).

## Usage

### Using the API

The clickhouse-backup tool exposes an API that you can use to manage backups. The API is available at port 7171 on the ClickHouse pod.

### Using the CLI

You can use the clickhouse-backup CLI by executing commands in the clickhouse-backup sidecar container:

```bash
# Create a backup
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup create my-backup

# List backups
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup list

# Upload a backup to remote storage (if configured)
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup upload my-backup

# Restore a backup
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup restore my-backup
```

### Scheduled Backups

To set up scheduled backups, you can use the `watch` command:

```bash
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup watch --watch-interval=1h --full-interval=24h
```

This will create a full backup every 24 hours and incremental backups every hour.

## Documentation

For more information about the clickhouse-backup tool, refer to the official documentation:

- [GitHub Repository](https://github.com/Altinity/clickhouse-backup)
- [Examples](https://github.com/Altinity/clickhouse-backup/blob/master/Examples.md)

---

# ClickHouse Backup and Restore Guide

=====================================

This guide provides instructions on how to restore ClickHouse backups using the `clickhouse-backup` tool. It covers restoring from both remote and local backups, along with additional options for customization.

## Introduction

---

`clickhouse-backup` is a versatile tool designed for backing up and restoring ClickHouse databases. It supports various storage types, including cloud services like AWS, GCS, and Azure, as well as local file systems.

## Prerequisites

---

- Ensure you have the ClickHouse cluster with the backup sidecar container properly deployed.
- Verify that the backup system has proper access to both local and remote storage.

## Restore Options

---

### Restore from a Remote Backup

1. **Download the Backup**:
   First, download the backup from your remote storage (e.g., MinIO) using:

```
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup download backup-name
```

2. **Restore the Backup**:
   Once downloaded, restore the backup with:

```
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup restore backup-name
```

### Restore from a Local Backup

If your backup is already available locally, you can skip the download step and directly restore it using the same command as above:

```
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup restore backup-name
```

### Restore with Additional Options

#### Restore to Different Tables/Databases

You can restore specific tables to different databases or tables using:

```
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup restore backup-name --tables 'source_database.source_table:new_database.new_table'
```

#### Restore Schema Only

To restore only the schema:

```
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup restore backup-name --schema
```

#### Restore Data Only

To restore only the data:

```
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup restore backup-name --data
```

#### Restore Specific Tables Only

Restore specific tables by specifying them:

```
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup restore backup-name --tables 'database.table'
```

#### Restore with Different Database Mapping

Map databases during restoration:

```
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup restore backup-name --database-mapping 'source_database:new_database'
```

## Important Considerations

---

- **Overwriting Existing Data**: By default, `clickhouse-backup` will not overwrite existing tables. Use the `--force` flag to override this behavior.
- **Cluster Configuration**: If working with a ClickHouse cluster, you may need to set the `--cluster` option accordingly.
- **Check Existing Tables**: Before restoration, check existing tables to avoid conflicts:

```
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup tables
```

- **Verify Backups**: Verify the backup content before restoration:

```
kubectl exec -it pod/chi-monitoring-demo-replcluster-0-0-0 -n clickhouse -c clickhouse-backup -- clickhouse-backup describe backup-name
```

## Conclusion

---

Restoring ClickHouse backups with `clickhouse-backup` is straightforward and offers flexibility with various options for customization. With the sidecar container approach, you can back up both schema and data, ensuring comprehensive protection for your ClickHouse deployment.
