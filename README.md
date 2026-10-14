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

If Google Drive backup logs show `invalid_grant` or token-revoked errors, reconnect the rclone config used by Backup Suite, not a different user/default rclone config. In system mode that is usually:

```bash
sudo rclone --config /etc/backup-suite/rclone.conf config reconnect gdrive:
```

See [docs/GOOGLE_DRIVE.md](docs/GOOGLE_DRIVE.md) and [docs/OPERATIONS.md](docs/OPERATIONS.md).

For the production `--copy-links` to `--links` migration, use the fail-safe root runner after reviewing the operations guide:

```bash
sudo ./production-file-backup-migrate.sh
```

It keeps `file-backup.timer` disabled unless deployment, dry-run reporting, explicit confirmation, confirmed migration, a bounded remote restore, cgroup/resource-accounting validation, and a one-notification/no-restart failed-sync test all succeed.

## What It Does

### File backup

- uses `rclone sync` for one-way source-to-destination backup
- treats source as authoritative
- archives destination-only deleted files into `deleted_files`
- supports multiple file sources and per-project excludes
- stores symlinks as restorable `.rclonelink` records without following their targets
- isolates immediate child projects when configured, with preserved prior remote versions
- keeps recently modified and actively changing files away from rclone, retries them next run, and warns about files that never settle
- runs under a selectable resource profile (`slow`, `moderate`, `fast`) enforced by systemd and a low-cost resource watchdog that contains, pauses, or stops a backup before it can push the server out of memory
- sends ntfy alerts with a plain-language explanation and the full log attached
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
- [Resource profiles, watchdog, and changing files](docs/RESOURCES.md)
- [Google Drive Notes](docs/GOOGLE_DRIVE.md)
- [Contributing](CONTRIBUTING.md)

## Repository Contents

- `bin/` runtime scripts
- `config/` example config files only
- `systemd/` unit templates
- `docs/` detailed documentation
- `setup.sh` installer and refresh entry point
- `production-deploy.sh` routine deployment for an installed host (never disables the timer; rolls back on failure)

## Security Note

This repository is intended to contain example configuration only.

- do not commit real credentials or runtime config
- do not commit live `rclone.conf`
- do not commit real database profile files
