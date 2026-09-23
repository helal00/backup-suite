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
- project-level volatile filename for files that may be preserved and retried after observed changes
- file-backup concurrency, stability retry, bounded reporting, and runtime limits
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
enabled|label|source_path|destination_mode|destination_value|sync_stop_file|isolation_mode
```

`destination_mode` values:

- `same-name`
- `fixed`
- `default-root`

Examples:

```text
1|workspace-projects|/home/user/php-projects-lv|fixed|projects/php-projects-lv|.nosync|children
1|web10-native|/var/www/clients/client0/web10/web|fixed|sites/web10|.nosync|single
```

Whole-source stop behavior:

- if `sync_stop_file` exists at the source root, that source is skipped entirely

Isolation behavior:

- `single` protects the configured source as one backup unit
- `children` treats every immediate child directory as an independent project and appends its directory name to the remote destination
- a failed child cannot prevent other children from being attempted
- archive-retention deletion is skipped for the whole run if any child fails

Project-level exclude behavior:

- `FILE_PROJECT_EXCLUDE_FILENAME` defaults to `.backup-excludes`
- `FILE_GLOBAL_EXCLUDE_PATTERNS` is an explicit `|`-separated set of root-relative patterns applied to every isolated project
- the file backup job searches recursively under each source for files with that name
- each matching file contributes exclude patterns relative to its own directory
- this is useful for Laravel or PHP runtime-generated content inside a project tree

The default global policy excludes only rebuildable AgentW observation/ready caches and prompt-run artifacts under `.ai-metadata`. It intentionally retains canonical continuity Markdown such as `project-context-summary.md`, active instructions, status, issues, and handoff files. Do not replace it with a broad `.ai-metadata/**` exclusion.

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

Do not place credentials, key backups, recovery archives, or unique configuration in `.backup-excludes` merely because they live below a runtime directory. Exclude only reproducible caches, downloads, logs, browser profiles, and service/database trees that have a separate snapshot or restore procedure.

### Changing-file classification

`FILE_VOLATILE_FILENAME` defaults to `.backup-volatile`. Its syntax and recursive scoping match `.backup-excludes`, but its meaning is different:

- volatile paths are attempted normally first
- after a failed attempt, Backup Suite waits `FILE_STABILITY_INTERVAL_SECONDS` and retries the complete project
- only paths observed changing during that interval and matching `.backup-volatile` may be preserved remotely and skipped for the final attempt
- the run reports `completed-with-skips`, a `skipped_changed` count, and at most `FILE_CHANGED_DETAIL_LIMIT` path details
- skipped paths are retried automatically on the next run
- an unclassified changing file continues to fail its project; it is never silently skipped

Live database files and wallet stores should still have an application-consistent snapshot/export policy. Volatile classification is a bounded availability fallback, not a database backup format.

### Symlinks and migration

Backup Suite uses rclone `--links`. It does not follow link targets. Relative, absolute, dangling, and directory symlinks are represented remotely as `.rclonelink` records and are recreated when restored with `rclone --links`.

For a populated destination that was previously created with `--copy-links`, the first run is gated. Generate and review reports while the timer remains disabled:

```bash
/opt/backup-suite/bin/file-backup.sh --verbose --link-migration-report
```

The reports are stored below the configured state directory in `migration-reports/`. No remote changes occur in report mode. After reviewing destination-only candidates, apply the migration explicitly:

```bash
/opt/backup-suite/bin/file-backup.sh --verbose --confirm-link-migration
```

Confirmation is accepted only when a prior report exists. Changed and destination-only objects are retained below `deleted_files/<timestamp>/...` through rclone `--backup-dir`.

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

In system mode, the runtime config path is normally:

- `/etc/backup-suite/rclone.conf`

In user mode, the equivalent runtime symlink is under `~/.config/backup-suite/rclone.conf`.

This runtime file is a symlink back to the canonical `rclone.conf` in the suite source tree.

Backup Suite always invokes rclone with:

```bash
--config "$RCLONE_CONFIG_PATH"
```

So operational tests and reconnects must use that same config path. For a system-mode Google Drive remote named `gdrive`, use:

```bash
sudo rclone --config /etc/backup-suite/rclone.conf lsd "gdrive,root_folder_id=YOUR_FOLDER_ID:"
sudo rclone --config /etc/backup-suite/rclone.conf config reconnect gdrive:
```

Plain `sudo rclone ...` may use `/root/.config/rclone/rclone.conf` instead and can give a false pass while the service still fails.

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
