# Dockerfile
FROM mcr.microsoft.com/mssql/server:2019-latest

# Set environment variables
ENV ACCEPT_EULA=Y
ENV SA_PASSWORD=YourStrong@Passw0rd

# Install dependencies
USER root
RUN apt-get update && apt-get install -y curl jq ca-certificates

# Copy the scripts and configuration
COPY download_and_restore.sh /usr/src/app/download_and_restore.sh
COPY databases.json /usr/src/app/databases.json

# Default command to run the combined script
CMD ["/bin/bash", "/usr/src/app/download_and_restore.sh"]
