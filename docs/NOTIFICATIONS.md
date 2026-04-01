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
