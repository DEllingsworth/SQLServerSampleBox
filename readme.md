# MS SQL Server with Pre-loaded Sample Databases

This project sets up a Microsoft SQL Server instance with pre-loaded sample databases using Docker. It is ideal for developers who require a clean installation of MS SQL Server with the Microsoft sample databases, such as WideWorldImporters and AdventureWorks, ready for use.

## Prerequisites

- Docker
- Docker Compose
- Git (for cloning the repository)

## Quick Start

1. **Clone the repository:**
```bash
git clone [repository-url]
cd [repository-directory]
```

2. **Build and run the container:**

```bash
docker-compose up --build
```

This command builds the SQL Server Docker image, sets up the environment, and runs the `download_and_restore.sh` script which handles the downloading and restoring of the sample databases.

3. **Access the SQL Server:**
   - **Host:** `localhost`
   - **Port:** `1433`
   - **Username:** `SA`
   - **Password:** `YourStrong@Passw0rd` (as set in the Dockerfile and docker-compose.yml)

## Configuration

- **Databases Configured:**
  - WideWorldImporters
  - AdventureWorks

  These databases are defined in the `databases.json` file, and you can modify this file to add or change the databases.

- **Scripts and Files:**
  - `download_and_restore.sh`: Main script that sets up the environment, downloads, and restores databases.
  - `databases.json`: JSON file containing the database names and their download URLs.

## Logs

Logs for the operations are stored in `/var/opt/mssql/backup/logs/custom_restore.log` within the Docker container. These logs can help debug issues with database downloading or restoration.

## Stopping the Server

To stop the SQL Server Docker container, use the following Docker Compose command:

```bash
docker-compose down
```

## Customization

You can customize the SQL Server setup by modifying the Dockerfile or the docker-compose.yml file. For example, changing the SA password or configuring additional environment variables.

## Note

Ensure that the `.gitignore` file includes the backup directory to avoid uploading backup files to your version control system.
