# Notifications

Backup Suite can publish failure notifications to an `ntfy` topic.

Recommended settings in `config/global.conf`:

```bash
NOTIFY_FAILURES_ENABLED="1"
NOTIFY_NTFY_TOPIC_URL="https://ntfy.sh/your-long-random-topic"
NOTIFY_NTFY_TITLE_PREFIX="Backup Suite"
NOTIFY_NTFY_PRIORITY="high"
NOTIFY_JOURNAL_LINES="40"
```

How it works:

- a backup service exits with a real failure
- `systemd` triggers `backup-suite-notify@.service`
- the notifier reads recent `journalctl` lines for the failed unit
- the notifier sends those details to your configured `ntfy` topic

Client options:

- mobile: install the `ntfy` app and subscribe to your topic
- desktop: open `https://ntfy.sh/` and subscribe to the same topic

Privacy note:

- use a long random topic name on the public `ntfy` service

Admin stop behavior:

- deliberate `systemctl stop ...` actions are treated as successful stops
- they do not trigger failure notifications
