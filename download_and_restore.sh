#!/bin/bash

# Log file for custom messages
LOG_FILE="/var/opt/mssql/backup/custom_restore.log"

# Clear previous log file
> $LOG_FILE

# Directory where backups should be located
BACKUP_DIR="/var/opt/mssql/backup"

echo "=== Starting download_and_restore.sh script ===" | tee -a $LOG_FILE

# Start SQL Server in the background
/opt/mssql/bin/sqlservr &

# Function to download a file if it doesn't exist
download_if_not_exists() {
    local file_path=$1
    local url=$2
    local max_retries=5
    local retry=0

    if [ ! -f "$file_path" ]; then
        echo "=== File $file_path does not exist. Downloading from $url... ===" | tee -a $LOG_FILE
        while [ $retry -lt $max_retries ]; do
            curl -L -o "$file_path" "$url" 2>&1 | tee -a $LOG_FILE
            if [ $? -eq 0 ]; then
                echo "=== Download of $file_path completed successfully. ===" | tee -a $LOG_FILE
                return 0
            else
                echo "=== Failed to download $file_path from $url. Retry $((retry + 1))/$max_retries ===" | tee -a $LOG_FILE
                retry=$((retry + 1))
                sleep 5
            fi
        done
        echo "=== Download of $file_path from $url failed after $max_retries attempts. ===" | tee -a $LOG_FILE
        return 1
    else
        echo "=== File $file_path already exists. ===" | tee -a $LOG_FILE
        return 0
    fi
}

# Function to check the sanity of the downloaded files
check_file_sanity() {
    local file_path=$1
    local min_size=10000000  # Minimum acceptable file size (10 MB)

    if [ -f "$file_path" ]; then
        local file_size=$(stat -c%s "$file_path")
        if [ $file_size -lt $min_size ]; then
            echo "=== File $file_path is too small (size: $file_size bytes). Sanity check failed. ===" | tee -a $LOG_FILE
            return 1
        else
            echo "=== File $file_path passed sanity check (size: $file_size bytes). ===" | tee -a $LOG_FILE
            return 0
        fi
    else
        echo "=== File $file_path does not exist for sanity check. ===" | tee -a $LOG_FILE
        return 1
    fi
}

# Function to check if SQL Server is up and running
wait_for_sql_server() {
    local retries=30
    local wait=5

    while [ $retries -gt 0 ]; do
        /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P $SA_PASSWORD -Q "SELECT 1" &> /dev/null
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

# Function to restore a database
restore_database() {
    local db_name=$1
    local bak_file=$2

    if [ -f "$bak_file" ]; then
        echo "=== Restoring database $db_name from $bak_file ===" | tee -a $LOG_FILE
        /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P $SA_PASSWORD -Q "
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

# Create the backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"
echo "=== Backup directory created or already exists: $BACKUP_DIR ===" | tee -a $LOG_FILE

# Read the databases.json file and download each backup file
sanity_check_failed=false
for db_info in $(jq -c '.[]' /usr/src/app/databases.json); do
    bak_url=$(echo $db_info | jq -r '.url')
    bak_file="$BACKUP_DIR/$(basename $bak_url)"
    download_if_not_exists $bak_file $bak_url
    if ! check_file_sanity $bak_file; then
        sanity_check_failed=true
    fi
done

# Exit if any sanity check failed
if [ "$sanity_check_failed" = true ]; then
    echo "=== One or more sanity checks failed. Exiting without restoring databases. ===" | tee -a $LOG_FILE
    exit 1
fi

# Wait for SQL Server to start
wait_for_sql_server
if [ $? -ne 0 ]; then
    echo "=== SQL Server failed to start. Exiting. ===" | tee -a $LOG_FILE
    exit 1
fi

# Read the databases.json file and restore each database
for db_info in $(jq -c '.[]' /usr/src/app/databases.json); do
    db_name=$(echo $db_info | jq -r '.name')
    bak_file="$BACKUP_DIR/$(basename $(echo $db_info | jq -r '.url'))"
    restore_database $db_name $bak_file
done

# Keep SQL Server running
wait
