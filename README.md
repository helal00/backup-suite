# Backup Suite

Backup Suite is a shell-based Linux backup project built around `rclone`, MySQL or MariaDB dumps, and systemd timers.

It covers three jobs:

- file backup to a remote backend
- selected database dumps
- database size monitoring

## Quick Start

### 1. Copy the example config files

```bash
cp config/global.conf.example config/global.conf
cp config/file-sources.conf.example config/file-sources.conf
cp config/database-backups.conf.example config/database-backups.conf
cp config/rclone.conf.example config/rclone.conf
cp config/mysql-profiles/default.cnf.example config/mysql-profiles/default.cnf
```

### 2. Edit the config for your environment

Review these first:

- `config/global.conf`
- `config/file-sources.conf`
- `config/database-backups.conf`
- `config/rclone.conf`
- `config/mysql-profiles/*.cnf`

### 3. Install

System-wide install:

```bash
sudo ./setup.sh
```

Refresh an existing install:

```bash
sudo ./setup.sh --refresh-scripts --refresh-units --yes
```

### 4. Run and watch

```bash
sudo systemctl start file-backup.service
systemctl status file-backup.service --no-pager
journalctl -t backup-file -f
```

## Features

- config-driven shell scripts with minimal dependencies
- `rclone`-based remote storage support
- archived deletions for file backups
- optional ntfy failure notifications
- systemd services and timers for scheduled operation
- journal heartbeat lines during long file backup phases

## Project Layout

- `bin/` scripts
- `config/` example config files only
- `systemd/` unit templates
- `docs/` operational and configuration guides
- `setup.sh` installer and refresh entry point

## Documentation

- [Configuration](docs/CONFIGURATION.md)
- [Operations](docs/OPERATIONS.md)
- [Notifications](docs/NOTIFICATIONS.md)
- [Google Drive Notes](docs/GOOGLE_DRIVE.md)
- [Contributing](CONTRIBUTING.md)

## Security Note

This repository is intended to contain example configuration only.

- do not commit real credentials or runtime config
- do not commit live `rclone.conf`
- do not commit real database profile files
