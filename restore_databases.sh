#!/bin/bash

# Log file for custom messages
LOG_FILE="/var/opt/mssql/backup/custom_restore.log"

echo "=== Starting restore_databases.sh script ===" | tee -a $LOG_FILE

# Function to check if SQL Server is up and running
wait_for_sql_server() {
    local retries=30
    local wait=5

    while [ $retries -gt 0 ]; do
        /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P YourStrong@Passw0rd -Q "SELECT 1" &> /dev/null
        if [ $? -eq 0 ]; then
            echo "=== SQL Server is up and running ===" | tee -a $LOG_FILE
            return 0
        else
            echo "=== Waiting for SQL Server to start... ===" | tee -a $LOG_FILE
            sleep $wait
            retries=$((retries - 1))
        fi
    done

    echo "=== SQL Server did not start in time ===" | tee -a $LOG_FILE
    return 1
}

# Wait for SQL Server to start
wait_for_sql_server
if [ $? -ne 0 ]; then
    echo "=== SQL Server failed to start. Exiting. ===" | tee -a $LOG_FILE
    exit 1
fi

# Function to restore a database
restore_database() {
    local db_name=$1
    local bak_file=$2

    if [ -f "$bak_file" ]; then
        echo "=== Restoring database $db_name from $bak_file ===" | tee -a $LOG_FILE
        /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P YourStrong@Passw0rd -Q "
        RESTORE DATABASE [$db_name] 
        FROM DISK = '$bak_file' 
        WITH MOVE '${db_name}_Data' TO '/var/opt/mssql/data/${db_name}_Data.mdf', 
        MOVE '${db_name}_Log' TO '/var/opt/mssql/data/${db_name}_Log.ldf'"
        if [ $? -eq 0 ]; then
            echo "=== Restored database $db_name successfully. ===" | tee -a $LOG_FILE
        else
            echo "=== Failed to restore database $db_name from $bak_file ===" | tee -a $LOG_FILE
        fi
    else
        echo "=== Backup file $bak_file for database $db_name does not exist ===" | tee -a $LOG_FILE
    fi
}

# Read the databases.json file and restore each database
for db_info in $(jq -c '.[]' /usr/src/app/databases.json); do
    db_name=$(echo $db_info | jq -r '.name')
    bak_file="/var/opt/mssql/backup/$(basename $(echo $db_info | jq -r
