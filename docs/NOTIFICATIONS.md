# Notifications

Backup Suite can publish failure notifications to an `ntfy` topic.

Recommended settings in `config/global.conf`:

```bash
NOTIFY_FAILURES_ENABLED="1"
NOTIFY_NTFY_TOPIC_URL="https://ntfy.sh/your-long-random-topic"
NOTIFY_NTFY_TITLE_PREFIX="Backup Suite"
NOTIFY_NTFY_PRIORITY="high"
NOTIFY_JOURNAL_LINES="40"
NOTIFY_DURABLE_LOG_LINES="120"
NOTIFY_FAILURE_LOG_KEEP_FILES="100"
```

How it works:

- a backup service exits with a real failure
- `systemd` triggers `backup-suite-notify@.service`
- the notifier reads recent `journalctl` lines for the failed unit
- every backup/monitor run is also appended to a bounded durable log under the configured state directory (`logs/`)
- the notifier records a timestamped local failure snapshot under the state directory (`failures/`)
- the notifier sends those details to your configured `ntfy` topic

System-mode defaults retain the local history under `/var/lib/backup-suite/logs/` and `/var/lib/backup-suite/failures/`. Logs rotate at `BACKUP_SUITE_LOG_MAX_BYTES`, retain `BACKUP_SUITE_LOG_KEEP_FILES` files per process, and retain the newest `NOTIFY_FAILURE_LOG_KEEP_FILES` failure snapshots. An ntfy message includes both the recent journal and durable-log tail plus the local snapshot path.

How you receive it on mobile or desktop:

- mobile: install the `ntfy` app on Android or iPhone and subscribe to your topic
- desktop: open `https://ntfy.sh/` in a browser and subscribe to the same topic
- desktop can also use the web app as a pinned tab or browser app

The topic itself is the connection point. Your devices do not connect directly to the backup server. They subscribe to the same `ntfy` topic, and the server publishes failure messages to that topic.

Client options:

- mobile: install the `ntfy` app and subscribe to your topic
- desktop: open `https://ntfy.sh/` and subscribe to the same topic

Privacy note:

- use a long random topic name on the public `ntfy` service

After changing notification config, refresh the installed unit files:

```bash
sudo /home/user/tools/backup-suite/setup.sh --refresh-scripts --refresh-units --yes
sudo systemctl daemon-reload
```

Admin stop behavior:

- deliberate `systemctl stop ...` actions are treated as successful stops
- they do not trigger failure notifications
