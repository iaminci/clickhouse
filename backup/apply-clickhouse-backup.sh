#!/bin/bash

# Apply the PV and PVC for backup storage
kubectl apply -f ch-backup-pv.yaml

# Apply the ConfigMap with the clickhouse-backup configuration
kubectl apply -f clickhouse-backup-config.yaml

# Apply the RBAC resources
kubectl apply -f clickhouse-backup-rbac.yaml

# Apply the Deployment and Service
kubectl apply -f clickhouse-backup-deployment.yaml

echo "ClickHouse Backup components have been applied."
echo "You can access the clickhouse-backup API at http://clickhouse-backup:7171 from within the cluster."
echo "To create a backup, run: kubectl exec -it deployment/clickhouse-backup -- clickhouse-backup create my-backup"
echo "To list backups, run: kubectl exec -it deployment/clickhouse-backup -- clickhouse-backup list"
