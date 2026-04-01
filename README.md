# Backup Suite

Backup Suite is a config-driven Linux backup solution for:

- one-way file backup with archived deletions
- selected MySQL or MariaDB database dumps as restore points
- database size monitoring

The suite is designed to be:

- standalone first
- ISPConfig-compatible second
- ISPConfig-aware optionally

It uses `rclone`, so it can work with any `rclone` backend the user configures, not only Google Drive.

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

Start with:

- `config/global.conf`
- `config/file-sources.conf`
- `config/database-backups.conf`
- `config/rclone.conf`
- `config/mysql-profiles/*.cnf`

### 3. Make the scripts executable

If the executable bits were not preserved when the project was downloaded or extracted:

```bash
chmod 755 setup.sh bin/*.sh
```

### 4. Install

System-wide install:

```bash
sudo ./setup.sh
```

User-mode install:

```bash
./setup.sh
```

### 5. Start a job and watch it

```bash
sudo systemctl start file-backup.service
systemctl status file-backup.service --no-pager
journalctl -t backup-file -f
```

## What It Does

### File backup

- uses `rclone sync` for one-way source-to-destination backup
- treats source as authoritative
- archives destination-only deleted files into `deleted_files`
- supports multiple file sources and per-project excludes
- emits periodic journal heartbeat lines during long listing and sync phases

### Database backup

- creates timestamped compressed database dump restore points
- supports multiple MySQL credential profiles
- can skip unchanged dumps and optionally delete local staging dumps after upload

### Database monitor

- checks selected database sizes
- reports databases at or above the configured threshold

## Install Modes

Backup Suite supports both:

- system-wide mode
- per-user mode

System mode defaults:

- scripts: `/opt/backup-suite`
- canonical source: `/opt/backup-suite-src`
- config: `/etc/backup-suite`

User mode defaults:

- scripts: `~/.local/share/backup-suite`
- config: `~/.config/backup-suite`
- state: `~/.local/state/backup-suite`

## Documentation

- [Installation](docs/INSTALLATION.md)
- [Configuration](docs/CONFIGURATION.md)
- [Operations](docs/OPERATIONS.md)
- [Notifications](docs/NOTIFICATIONS.md)
- [Google Drive Notes](docs/GOOGLE_DRIVE.md)
- [Contributing](CONTRIBUTING.md)

## Repository Contents

- `bin/` runtime scripts
- `config/` example config files only
- `systemd/` unit templates
- `docs/` detailed documentation
- `setup.sh` installer and refresh entry point

## Security Note

This repository is intended to contain example configuration only.

- do not commit real credentials or runtime config
- do not commit live `rclone.conf`
- do not commit real database profile files
