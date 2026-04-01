# Operations

## Service Model

The systemd services are intended to be started manually or by timers.

Current behavior:

- `systemctl start ...` returns quickly
- systemd still tracks the real running process
- deliberate `systemctl stop ...` does not trigger ntfy failure alerts
- long file-backup phases emit periodic journal heartbeat lines so slow runs are visible

## Manual Runs

Examples:

```bash
/opt/backup-suite/bin/file-backup.sh --verbose
/opt/backup-suite/bin/database-backup.sh --verbose
/opt/backup-suite/bin/database-size-check.sh --verbose
```

Manual `--verbose` mode shows compact `rclone` stats.

## Monitoring

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

## Timers

Typical schedule intent:

- file backup: every 30 minutes
- database backup: daily
- database size monitor: daily

Check active timer schedule:

```bash
systemctl list-timers file-backup.timer database-backup.timer database-size-check.timer --all --no-pager
```

## Failure Notifications

If enabled, failures are posted to an `ntfy` topic.

Relevant settings:

- `NOTIFY_FAILURES_ENABLED`
- `NOTIFY_NTFY_TOPIC_URL`
- `NOTIFY_NTFY_TITLE_PREFIX`
- `NOTIFY_NTFY_PRIORITY`
