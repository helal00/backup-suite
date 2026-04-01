# Operations

## Service Model

The systemd services are intended to be started manually or by timers.

Current behavior:

- `systemctl start ...` returns quickly
- systemd still tracks the real running process
- deliberate `systemctl stop ...` does not trigger ntfy failure alerts
- long file-backup phases emit periodic journal heartbeat lines so slow runs are visible

## Runtime Commands

Run file backup manually:

```bash
/opt/backup-suite/bin/file-backup.sh
```

In user mode, use the user install path instead, for example:

```bash
~/.local/share/backup-suite/bin/file-backup.sh
```

For a manual run with live terminal output and compact `rclone` stats:

```bash
/opt/backup-suite/bin/file-backup.sh --verbose
```

Run database backup manually:

```bash
/opt/backup-suite/bin/database-backup.sh
```

For a manual run with live terminal output and compact `rclone` stats:

```bash
/opt/backup-suite/bin/database-backup.sh --verbose
```

Run database monitor manually:

```bash
/opt/backup-suite/bin/database-size-check.sh
```

For a manual run with live terminal output:

```bash
/opt/backup-suite/bin/database-size-check.sh --verbose
```

By default, manual runs log to the journal. `--verbose` mirrors output to the terminal and shows aggregate `rclone` progress stats such as transferred amount, percent, speed, and ETA without the noisier per-file output. The manual stats refresh interval is 10 seconds.

## File Backup Behavior

The file backup uses one-way `rclone sync`.

This means:

- changes in source are copied to destination
- files deleted from source are removed from destination
- destination-only drift is removed on the next run
- destination-only deleted files are first moved into `deleted_files`
- changed files are overwritten in place instead of being archived
- archived files older than the file retention period are deleted permanently

If a configured source path exists but the runtime user cannot read or traverse it, the run logs an explicit error for that source and the overall run is marked failed.

The file backup can also pause itself when configured processes are active.

Manual and timer runs are also serialized by a shared suite lock, so no second backup-suite script starts while any other backup-suite script is already active.

Relevant global config settings:

- `FILE_PROCESS_CHECK_ENABLED="1"`
- `FILE_PROCESS_CHECK_USER_ONLY="1"`
- `FILE_PROCESS_CHECK_PATTERNS="vscode-server"`

`FILE_PROCESS_CHECK_PATTERNS` accepts one or more process-match patterns separated by commas or `|`.

Examples:

```bash
FILE_PROCESS_CHECK_PATTERNS="vscode-server"
```

```bash
FILE_PROCESS_CHECK_PATTERNS="vscode-server,code-server"
```

```bash
FILE_PROCESS_CHECK_PATTERNS="vscode-server|phpstorm|node /srv/watch-task"
```

By default, the suite keeps this check enabled and scoped to the current runtime user only.

This is source-to-destination only. Nothing from the destination is written back into source.

## Database Restore Points

Each timestamped database dump file is a restore point.

The suite keeps local and remote retention separate from file archive retention.

Relevant global config settings:

- `DB_SKIP_UNCHANGED_BACKUPS="1"`
- `DB_KEEP_LOCAL_AFTER_UPLOAD="0"`

How unchanged skipping works:

- the suite still creates a fresh dump attempt on schedule
- it hashes the dump content after creation
- if the content hash matches the last successfully uploaded dump for that database, the new local dump is discarded and no new restore point is retained

How local dump cleanup works:

- dumps are created locally first as staging artifacts
- after successful upload, local dump files can be deleted automatically
- if upload fails, local dump files are kept so they are not lost
- backup scripts share one suite-wide lock, so a direct `file-backup.sh`, `database-backup.sh`, or `database-size-check.sh` invocation exits if another suite script is already running

Defaults:

- database dump retention: 14 days
- file archive retention: 21 days

## Checking Current Databases

List all databases:

```bash
mysql --defaults-extra-file=/etc/backup-suite/mysql-profiles/default.cnf -e "SHOW DATABASES;"
```

List non-system databases only:

```bash
mysql --defaults-extra-file=/etc/backup-suite/mysql-profiles/default.cnf --batch --skip-column-names -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ('information_schema','mysql','performance_schema','sys') ORDER BY schema_name;"
```

Show database sizes in MB:

```bash
mysql --defaults-extra-file=/etc/backup-suite/mysql-profiles/default.cnf --batch --skip-column-names -e "SELECT table_schema, ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS size_mb FROM information_schema.tables GROUP BY table_schema ORDER BY size_mb DESC;"
```

## Systemd Units

Installed system services:

- `file-backup.service`
- `file-backup.timer`
- `database-backup.service`
- `database-backup.timer`
- `database-size-check.service`
- `database-size-check.timer`

Check timers:

```bash
systemctl status file-backup.timer
systemctl status database-backup.timer
systemctl status database-size-check.timer
```

In user mode, use:

```bash
systemctl --user status file-backup.timer
systemctl --user status database-backup.timer
systemctl --user status database-size-check.timer
```

Check active timer schedule:

```bash
systemctl list-timers file-backup.timer database-backup.timer database-size-check.timer --all --no-pager
```

Check logs:

```bash
journalctl -t backup-file -n 200 --no-pager
journalctl -t backup-db -n 200 --no-pager
journalctl -t backup-db-monitor -n 200 --no-pager
```

## Monitoring Running Jobs

Service state:

```bash
systemctl status file-backup.service --no-pager
systemctl status database-backup.service --no-pager
systemctl status database-size-check.service --no-pager
```

Journal output:

```bash
journalctl -t backup-file -f
journalctl -t backup-db -f
journalctl -t backup-db-monitor -f
```

## ISPConfig Notes

This suite does not assume the stock Linux `backup` account has enough permission to read ISPConfig site trees.

Use the natural permission boundary of the mode you choose:

- user mode: back up only what that user can already access
- system mode: use root or `sudo` for machine-wide backup

For databases, create one or more MySQL credential profiles and map each database to the profile that should back it up.
