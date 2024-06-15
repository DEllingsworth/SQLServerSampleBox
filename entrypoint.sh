#!/bin/bash

# Log file for custom messages
LOG_FILE="/var/opt/mssql/backup/custom_restore.log"

# Clear previous log file
> $LOG_FILE

echo "=== Starting entrypoint.sh script ===" | tee -a $LOG_FILE

# Run the download and restore script
/usr/src/app/download_and_restore.sh | tee -a $LOG_FILE
