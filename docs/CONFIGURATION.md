# Configuration

This project ships only example configuration files.

Copy these examples and rename them before first use:

- `config/global.conf.example` -> `config/global.conf`
- `config/file-sources.conf.example` -> `config/file-sources.conf`
- `config/database-backups.conf.example` -> `config/database-backups.conf`
- `config/rclone.conf.example` -> `config/rclone.conf`
- `config/mysql-profiles/default.cnf.example` -> `config/mysql-profiles/default.cnf`

## Global Config

File:

- `config/global.conf`

Controls:

- install mode and install paths
- canonical source paths
- `rclone` binary location
- `rclone` remote settings
- optional remote hostname override for stable remote paths
- optional backend-specific extra `rclone` flags
- file backup retention and schedule
- project-level exclude filename for runtime-generated files you do not want backed up
- configurable process patterns that can pause file backup when matched
- file backup heartbeat interval for long journal-visible phases
- database backup retention and schedule
- whether unchanged database dumps should be skipped
- whether local database dumps should be kept after successful upload
- failure notification delivery through ntfy
- database monitor threshold and schedule

### File source config

File:

- `config/file-sources.conf`

In user mode, the equivalent runtime symlink is under `~/.config/backup-suite/file-sources.conf`.

Format:

```text
enabled|label|source_path|destination_mode|destination_value|sync_stop_file
```

`destination_mode` values:

- `same-name`
- `fixed`
- `default-root`

Examples:

```text
1|workspace-projects|/home/user/php-projects-lv|fixed|projects/php-projects-lv|.nosync
1|web10-native|/var/www/clients/client0/web10/web|fixed|sites/web10|.nosync
```

Whole-source stop behavior:

- if `sync_stop_file` exists at the source root, that source is skipped entirely

Project-level exclude behavior:

- `FILE_PROJECT_EXCLUDE_FILENAME` defaults to `.backup-excludes`
- the file backup job searches recursively under each source for files with that name
- each matching file contributes exclude patterns relative to its own directory
- this is useful for Laravel or PHP runtime-generated content inside a project tree

`default-root` means the remote destination is built from:

```text
FILE_DEFAULT_DESTINATION_ROOT/destination_value
```

So for:

```text
1|workspace-projects|/home/user/php-projects-lv|default-root|projects|.nosync
```

the source `/home/user/php-projects-lv` is stored under a remote path ending in `files/projects`, not automatically under `php-projects-lv`.

Example project-level exclude file for a Laravel app:

```text
storage/framework/cache/**
storage/framework/sessions/**
storage/framework/testing/**
storage/framework/views/**
storage/logs/**
bootstrap/cache/*.php
node_modules/**
```

With that file in place, the suite can still back up the larger source tree while excluding runtime-generated or rebuildable content only for that project.

### Database backup config

File:

- `config/database-backups.conf`

In user mode, the equivalent runtime symlink is under `~/.config/backup-suite/database-backups.conf`.

Format:

```text
enabled|site_label|database_name|mysql_profile
```

Example:

```text
1|example-app|dbexample_app|default
1|shop-prod|dbshop_prod|shop
```

### MySQL credential profiles

Directory:

- `config/mysql-profiles`

In user mode, the equivalent runtime symlink is under `~/.config/backup-suite/mysql-profiles`.

Each profile is a separate MySQL client config file such as:

- `default.cnf`
- `shop.cnf`
- `blog.cnf`

Each database row in `database-backups.conf` selects the profile it should use.

Example `default.cnf`:

```ini
[client]
host=127.0.0.1
port=3306
user=CHANGE_ME
password=CHANGE_ME
```

### Rclone config

File:

- `config/rclone.conf`

In user mode, the equivalent runtime symlink is under `~/.config/backup-suite/rclone.conf`.

This runtime file is a symlink back to the canonical `rclone.conf` in the suite source tree.

The suite is backend-agnostic. `RCLONE_REMOTE_ROOT` can point to any valid `rclone` remote path, for example:

```bash
RCLONE_REMOTE_ROOT="gdrive:server-backups"
```

```bash
RCLONE_REMOTE_ROOT="my-sftp:/backups"
```

```bash
RCLONE_REMOTE_ROOT="s3remote:bucket-name/backups"
```

If `INCLUDE_HOSTNAME_IN_REMOTE="1"`, the suite normally uses the current system hostname under the remote root.

To keep a stable remote hostname even if the machine hostname changes later, set for example:

```bash
REMOTE_HOSTNAME="black"
```

If `REMOTE_HOSTNAME` is empty, the suite falls back to the current system hostname at runtime.

During setup, if `REMOTE_HOSTNAME` is blank, the setup script pins the currently discovered hostname into the canonical `global.conf` automatically. This keeps future hostname changes from silently changing the remote path. You can still edit `REMOTE_HOSTNAME` later if you intentionally want a new hostname reflected.

### Backend-specific rclone flags

The suite does not hardcode Google Drive-only transfer flags.

Instead, use these config values when you need backend-specific tuning:

```bash
FILE_RCLONE_EXTRA_FLAGS="--drive-chunk-size 64M --drive-upload-cutoff 64M"
DB_RCLONE_EXTRA_FLAGS=""
```

Examples:

Google Drive tuning:

```bash
FILE_RCLONE_EXTRA_FLAGS="--drive-chunk-size 64M --drive-upload-cutoff 64M"
```

SFTP or generic remote with no special flags:

```bash
FILE_RCLONE_EXTRA_FLAGS=""
DB_RCLONE_EXTRA_FLAGS=""
```
