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
- the notifier matches the newest run's log against known causes (files changing during upload, Google Drive rate limit or full storage, expired rclone login, network/DNS failure, local disk full, permissions, missing source, OOM kill, runtime limit, watchdog stop)
- it sends a short, plain-language message: what happened, the likely cause with a fix, what was protected, the failed projects, and the key error lines
- the full journal and durable-log excerpt is attached as a `.log` file

ntfy turns any message body over 4096 bytes into a file attachment, which is why older alerts arrived as an attachment only. Messages are now kept under `NOTIFY_NTFY_MESSAGE_MAX_BYTES` (default 3500) and the details travel as a separate attachment. If the server rejects attachments, the message is resent on its own.

The resource watchdog and the changing-file tracker send their own explained alerts; see [RESOURCES.md](RESOURCES.md). To see the format, send a test: `sudo /opt/backup-suite/bin/notify-test.sh`.

Optional settings: `NOTIFY_NTFY_TOKEN` (access token for protected topics) and `NOTIFY_NTFY_ATTACH_DETAILS="0"` (message only, no attachment).

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
