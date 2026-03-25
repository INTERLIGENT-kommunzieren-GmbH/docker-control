# Migration Guide: Old Docker Control to New Docker Plugin

This guide explains how to migrate an existing project based on the old `docker-control` (with `control.cmd`) to the new Docker Plugin.

## Automated Migration

The new Docker Plugin includes a `migrate` command that automates most of the process.

### Prerequisites

- The project must contain a `control.cmd` file in the root.
- You must have `rsync` installed on your system.
- You must have `sudo` privileges (required to preserve file permissions during backup and data restoration).

### Steps

1.  Navigate to your project directory.
2.  Run the migration command:
    ```bash
    docker-control migrate
    ```

## What the Migration Command Does

1.  **Stops the Project**: Runs `control.cmd stop` to ensure all containers are stopped.
2.  **Creates a Backup**: Moves the entire project into a `backup_<timestamp>` subfolder using `rsync` with `sudo` to preserve permissions, and then empties the project directory (preserving only the backup folder).
3.  **Applies New Template**: Copies the new project template into the project directory.
4.  **Restores `htdocs`**: Copies the `htdocs` folder back from the backup.
5.  **Migrates Capistrano**: 
    - Extracts the `capistrano` service definition from `backup/docker-compose/docker-compose.development.yml`.
    - Creates a `compose.override.yml` with the migrated service.
    - Updates volumes from `./container/capistrano/...` to `./volumes/capistrano`.
    - Updates build context from `docker-compose/build/capistrano` to `build/capistrano`.
    - Copies capistrano build context and configuration files.
6.  **Migrates Database**: Copies MariaDB/MySQL data from `backup/container/mariadb` to `volumes/db`.
7.  **Restores Environment**: Copies `.env-dist` to `.env` and populates it with values from the backup `.env`.
    - `DB_HOST_PORT` is set from `MARIADB_PORT` or `MYSQL_PORT`.
8.  **Creates Helper Scripts**: Adds `cap.sh` for running Capistrano commands.

## Manual Steps After Migration

- Review `.env` for any missing or incorrect values.
- Check `compose.override.yml` to ensure the `capistrano` service is correctly configured.
- Run `docker-control start` to start the migrated project.
