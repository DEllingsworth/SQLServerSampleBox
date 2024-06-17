#!/bin/bash

# Enhanced logging function
log_message() {
    local message=$1
    echo "$message"  # This goes to Docker logs
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message" | tee -a $MY_LOG_FILE  # This goes to our logfile
}

# Step 1: Set up logging directory and log file
LOG_DIR="/var/opt/mssql/backup/logs"
mkdir -p $LOG_DIR
MY_LOG_FILE="$LOG_DIR/custom_restore.log"
log_message "=== Log file location: $MY_LOG_FILE ==="

# Clear previous log file
> $MY_LOG_FILE

# Step 2: Define the backup directory
BACKUP_DIR="/var/opt/mssql/backup"
log_message "=== Starting download_and_restore.sh script ==="

# Step 3: Start SQL Server in the background
/opt/mssql/bin/sqlservr &

# Function to download a file if it doesn't exist
download_if_not_exists() {
    local file_path=$1
    local url=$2
    local max_retries=5
    local retry=0

    if [ ! -f "$file_path" ]; then
        log_message "File $file_path does not exist. Downloading from $url..."
        while [ $retry -lt $max_retries ]; do
            curl -L -o "$file_path" "$url" >> $MY_LOG_FILE 2>&1
            if [ $? -eq 0 ]; then
                log_message "Download of $file_path completed successfully."
                return 0
            else
                log_message "Failed to download $file_path from $url. Retry $((retry + 1))/$max_retries"
                retry=$((retry + 1))
                sleep 5
            fi
        done
        log_message "Download of $file_path from $url failed after $max_retries attempts."
        return 1
    else
        log_message "File $file_path already exists."
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
            log_message "File $file_path is too small (size: $file_size bytes). Sanity check failed."
            return 1
        else
            log_message "File $file_path passed sanity check (size: $file_size bytes)."
            return 0
        fi
    else
        log_message "File $file_path does not exist for sanity check."
        return 1
    fi
}

# Function to check if SQL Server is up and running
wait_for_sql_server() {
    local retries=30
    local wait=5

    while [ $retries -gt 0 ]; do
        /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P $SA_PASSWORD -Q "SELECT name FROM sys.databases WHERE name = 'tempdb'" &> /dev/null
        if [ $? -eq 0 ]; then
            log_message "SQL Server is up and ready to accept connections"
            return 0
        else
            log_message "Waiting for SQL Server to start and be ready..."
            sleep $wait
            retries=$((retries - 1))
        fi
    done

    log_message "SQL Server did not start in time"
    return 1
}

# Function to get logical file names from the backup
get_logical_file_names() {
    local bak_file=$1

    log_message "Getting logical file names from $bak_file"

    local file_list_output
    file_list_output=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P $SA_PASSWORD -Q "RESTORE FILELISTONLY FROM DISK = N'$bak_file'" -s "," -W -h-1 2>&1)
    log_message "$file_list_output"

    local data_files=()
    local log_files=()
    
    # Properly parse the output
    while IFS=',' read -r LogicalName PhysicalName Type Rest; do
        if [[ "$Type" == "D" || "$Type" == "S" ]]; then
            data_files+=("$LogicalName")
        elif [[ "$Type" == "L" ]]; then
            log_files+=("$LogicalName")
        fi
    done <<< "$file_list_output"

    if [ ${#data_files[@]} -eq 0 ] || [ ${#log_files[@]} -eq 0 ]; then
        log_message "Failed to get logical file names from $bak_file"
        return 1
    fi

    # Export logical file names for use in the restore function
    export DATA_FILES="${data_files[@]}"
    export LOG_FILES="${log_files[@]}"
    log_message "Exported logical file names: Data Files - ${DATA_FILES[*]}, Log Files - ${LOG_FILES[*]}"
    return 0
}


# Function to restore a database
restore_database() {
    local db_name=$1
    local bak_file=$2

    if [ -f "$bak_file" ]; then
        log_message "Restoring database $db_name from $bak_file"

        # Call the function to get logical file names
        get_logical_file_names "$bak_file"
        if [ $? -ne 0 ]; then
            log_message "Failed to get logical file names for $bak_file"
            exit 1
        fi

        # Ensure variables are correctly populated
        log_message "Data Files: $DATA_FILES, Log Files: $LOG_FILES"

        # Build the RESTORE DATABASE command with all file movements
        local restore_command="RESTORE DATABASE [$db_name] FROM DISK = '$bak_file' WITH"
        local count=1
        for file in $DATA_FILES; do
            restore_command+=" MOVE '$file' TO '/var/opt/mssql/data/${db_name}_Data${count}.mdf',"
            count=$((count + 1))
        done

        count=1
        for file in $LOG_FILES; do
            restore_command+=" MOVE '$file' TO '/var/opt/mssql/data/${db_name}_Log${count}.ldf',"
            count=$((count + 1))
        done

        # Remove the trailing comma and add NORECOVERY
        restore_command=${restore_command%,}
        restore_command+=", NORECOVERY"

        log_message "Executing initial restore command: $restore_command"
        /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P $SA_PASSWORD -Q "$restore_command"
        
        if [ $? -ne 0 ]; then
            log_message "Initial restore command failed."
            exit 1
        fi

        # Wait for the database to be in restoring state
        while true; do
            status=$(/opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P $SA_PASSWORD -Q "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name = N'$db_name';" -h-1 -W | tr -d '[:space:]')
            if [[ "$status" == "RESTORING" ]]; then
                log_message "Database $db_name is RESTORING."
                break
            elif [[ "$status" == "RECOVERY_PENDING" || "$status" == "SUSPECT" || "$status" == "EMERGENCY" ]]; then
                log_message "Database $db_name is in an error state: $status"
                exit 1
            else
                log_message "Waiting for database $db_name to be in RESTORING state: $status"
                sleep 5
            fi
        done

        # Complete the restore
        log_message "Executing restore completion command: RESTORE DATABASE [$db_name] WITH RECOVERY"
        /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P $SA_PASSWORD -Q "RESTORE DATABASE [$db_name] WITH RECOVERY"
        
        if [ $? -ne 0 ]; then
            log_message "Restore completion command failed."
            exit 1
        fi

        log_message "Verifying restore of database $db_name"
        /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P $SA_PASSWORD -Q "SELECT name FROM master.sys.databases WHERE name = N'$db_name'" -h-1 -W | grep -qw "$db_name"
        if [ $? -eq 0 ]; then
            log_message "Restored database $db_name successfully."
        else
            log_message "Failed to restore database $db_name"
            exit 1
        fi
    else
        log_message "Backup file $bak_file for database $db_name does not exist"
        exit 1
    fi
}



# Function to verify the database restore
verify_restore() {
    local db_name=$1
    log_message "Verifying restore of database $db_name"
    /opt/mssql-tools/bin/sqlcmd -S localhost -U SA -P $SA_PASSWORD -Q "SELECT name FROM master.sys.databases WHERE name = N'$db_name'" -h-1 -W | grep -qw "$db_name"
    if [ $? -eq 0 ]; then
        return 0
    else
        return 1
    fi
}


# Function to process databases from configuration
process_databases() {
    local sanity_check_failed=false
    for db_info in $(jq -c '.[]' /usr/src/app/databases.json); do
        db_name=$(echo $db_info | jq -r '.name')
        bak_url=$(echo $db_info | jq -r '.url')
        db_backup_dir="$BACKUP_DIR/$db_name"
        mkdir -p "$db_backup_dir"
        bak_file="$db_backup_dir/$(basename $bak_url)"
        download_if_not_exists $bak_file $bak_url
        if ! check_file_sanity $bak_file; then
            sanity_check_failed=true
        fi
    done

    # Exit if any sanity check failed
    if [ "$sanity_check_failed" = true ]; then
        log_message "=== One or more sanity checks failed. Exiting without restoring databases. ==="
        exit 1
    fi

    # Wait for SQL Server to start
    wait_for_sql_server
    if [ $? -ne 0 ]; then
        log_message "=== SQL Server failed to start. Exiting. ==="
        exit 1
    fi

    log_message ""
    log_message ""
    # Restore each database
    for db_info in $(jq -c '.[]' /usr/src/app/databases.json); do
        db_name=$(echo $db_info | jq -r '.name')
        db_backup_dir="$BACKUP_DIR/$db_name"
        bak_file="$db_backup_dir/$(basename $(echo $db_info | jq -r '.url'))"
        log_message "==="
        log_message "=== Restoring database $db_name from $bak_file ==="
        log_message "==="
        restore_database $db_name $bak_file
    done
}

# Step 8: Create the backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"
log_message "=== Backup directory created or already exists: $BACKUP_DIR ==="

# Step 9: Process databases
process_databases
log_message ""
log_message ""
log_message "=== Restore Scipt Complete ==="
# Step 10: Keep SQL Server running
wait
