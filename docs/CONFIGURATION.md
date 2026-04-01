# Configuration

This project ships only example configuration files.

Copy these examples and rename them before first use:

- `config/global.conf.example` -> `config/global.conf`
- `config/file-sources.conf.example` -> `config/file-sources.conf`
- `config/database-backups.conf.example` -> `config/database-backups.conf`
- `config/rclone.conf.example` -> `config/rclone.conf`
- `config/mysql-profiles/default.cnf.example` -> `config/mysql-profiles/default.cnf`

## Global Config

`config/global.conf` controls:

- install mode and install paths
- `rclone` binary and remote root
- file backup retention, schedules, and process pause patterns
- database backup retention, upload behavior, and schedules
- ntfy failure notifications
- database size monitor threshold and schedule

Important settings:

- `RCLONE_REMOTE_ROOT`
- `FILE_BACKUP_ONCALENDAR`
- `DB_BACKUP_ONCALENDAR`
- `DB_MONITOR_ONCALENDAR`
- `NOTIFY_FAILURES_ENABLED`
- `NOTIFY_NTFY_TOPIC_URL`

## File Sources

`config/file-sources.conf` format:

```text
enabled|label|source_path|destination_mode|destination_value|sync_stop_file
```

`destination_mode` values:

- `same-name`
- `fixed`
- `default-root`

Example:

```text
1|workspace|/srv/projects|fixed|projects/workspace|.nosync
1|site-webroot|/var/www/example.com|fixed|sites/example.com|.nosync
```

Project-level excludes:

- `FILE_PROJECT_EXCLUDE_FILENAME` defaults to `.backup-excludes`
- any matching file found inside a source tree contributes exclude rules relative to its own directory

Example `.backup-excludes`:

```text
storage/framework/cache/**
storage/framework/sessions/**
storage/framework/testing/**
storage/framework/views/**
storage/logs/**
bootstrap/cache/*.php
node_modules/**
```

## Database Backups

`config/database-backups.conf` format:

```text
enabled|site_label|database_name|mysql_profile
```

Example:

```text
1|app-main|db_app_main|default
1|shop-prod|db_shop_prod|shop
```

## MySQL Profiles

Store one client credential file per profile in `config/mysql-profiles/`.

Example:

```ini
[client]
host=127.0.0.1
port=3306
user=CHANGE_ME
password=CHANGE_ME
```

## Rclone

`config/rclone.conf` is a normal `rclone` config file.

The suite is backend-agnostic. Examples:

```bash
RCLONE_REMOTE_ROOT="gdrive:server-backups"
RCLONE_REMOTE_ROOT="s3remote:bucket/backups"
RCLONE_REMOTE_ROOT="my-sftp:/backups"
```
