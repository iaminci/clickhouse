##
### local backup
```
docker exec -it clickhouse-server clickhouse-client --query="BACKUP DATABASE your_database_name TO Disk('backups', 'your_database_name_backup_local_$(date +%Y%m%d%H%M).zip')"
```
##
### s3 backup
```
docker exec -it clickhouse-server clickhouse-client --query="BACKUP DATABASE your_database_name TO Disk('s3_backup_disk', 'your_database_name_backup_s3_$(date +%Y%m%d%H%M).zip')"
```
##
### local restore
```
docker exec -it clickhouse-server clickhouse-client --query="RESTORE DATABASE your_database_name FROM Disk('backups', 'your_database_name_backup_local_YYYYMMDDHHMM.zip') SETTINGS allow_non_empty_tables = true"
```
##
### s3 restore
```
docker exec -it clickhouse-server clickhouse-client --query="RESTORE DATABASE your_database_name FROM Disk('s3_backup_disk', 'your_database_name_backup_s3_YYYYMMDDHHMM.zip') SETTINGS allow_non_empty_tables = true"
```