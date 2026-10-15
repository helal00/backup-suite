# Backup Suite GUI — Specification

Status: **approved for implementation** (revision 3, 2026-10-14).
This document is the acceptance reference: every requirement has an ID
(`G-…`), section 14 records the review decisions, and section 15 lists the
checks that verify each requirement.

History:
- Revision 1: first draft.
- Revision 2: owner answers R1–R7 and the first Tunnel Manager review.
- **Revision 3** follows the owner's final recommendation
  (`/home/user/php-projects-lv/agentw-commercial/.ai-metadata/handoffs/2026-10-14-backup-suite-gui-recommendation-3.md`).
  It supersedes the account decisions of revision 2. The GUI is an admin app
  set up exactly like agentw-gui: a user unit of the admin login, a socket in
  `$XDG_RUNTIME_DIR`, the owner's normal Tunnel Manager profile, and
  `remote_service` `systemd-user`. One GUI covers both Backup Suite install
  modes through two backends (G-ARC-3). The `backup-gui` account, its sshd
  block, the key handoff and any capabilities endpoint are dropped. Kept from
  the reviews: the editable `backend_id`, no `cursor_store`, no hard-coded
  socket path, linger, and Host/Origin checks that accept any local port.

## 1. Goal

A professional browser GUI for Backup Suite, reached only through an SSH
tunnel managed by Tunnel Manager (`tunnelm`). It shows what the backups are
doing and how much of the server they use, and it gives the same controls as
the command-line tools (`backup-profile.sh`, `systemctl`, `notify-test.sh`)
without a shell. It looks and behaves like `agentw-gui`.

Out of scope for v1 (section 13): editing backup sources (v1.1), restoring
files from Google Drive, editing database backup definitions, managing other
servers, and multi-user accounts inside one GUI.

## 2. What this follows from agentw-gui and Tunnel Manager

Read-only review of `/home/user/php-projects-lv/agentw-gui` (v0.1.3) and
`/home/user/php-projects-lv/agentw-commercial/tunnel-manager` (v0.1.38),
2026-10-14.

| agentw-gui behavior | Backup GUI requirement |
|---|---|
| Node server, no web framework, vanilla JS front end, one `public/` directory | Same stack. The server uses only Node's standard library (no `npm install`) and runs on Node ≥ 18 (`/usr/bin/node` is v18.19.1 on this host; the installer records the absolute path of the `node` it was started with). |
| Runs as the admin login's **systemd user service** `agentw-gui-4317.service`, with linger, resource drop-ins and its own watchdog unit | `backup-suite-gui-4337.service` user unit of the admin login, linger, the same drop-in and watchdog pattern (G-ARC-1). |
| `listen-config.js`: a **private Unix socket** by default (`$XDG_RUNTIME_DIR/agentw-gui/gui-<port>.sock`, 0600 in a 0700 dir); `tcp` (127.0.0.1) and `both` opt-in with a warning | Identical modes, defaults and checks: `$XDG_RUNTIME_DIR/backup-suite-gui/gui-4337.sock` (G-ARC-5). |
| `GET /api/health` returns `app: "agentw-gui"`, build, listen report | `GET /api/health` returns `app` and `app_id` = `backup-suite-gui`; Tunnel Manager checks it with `expect_app_id`. |
| Tunnel Manager bundle (`format = "tunnel-manager-tunnel"`, `version = 1`) generated from current settings in the **Ways to connect** dialog, with Windows `.cmd`, macOS/Linux `.sh`, Android `.txt` launchers and the manual `ssh -N -L` line | Same dialog, launchers and generator, with this app's names and ports, plus a command-line generator for the first import (G-CON-4). |
| Bundle sections `[tunnel.local]`, `[tunnel.health]`, `[tunnel.launch.browser] mode = "webview"`, `[tunnel.events]`, `[tunnel.notifications]`, `[tunnel.remote_service] provider = "systemd-user"`, `policy = "start-if-stopped"` | Same sections and values; `[tunnel.file_bridge]` is left out (this GUI edits no local copies), and there is no `cursor_store` (G-CON-2). |
| App events: `POST /api/events` with `action: "consume" \| "ack"` and `delivery_mode: "per-consumer-v1"`; first consume `baseline: true`; 180 s TTL from `created_at`; `GET /api/events` non-consuming | Same contract and rules (G-EVT-*). |
| Notifications settings: Tunnel Manager delivery, browser delivery, "Prefer Tunnel Manager notifications when active", per-category switches, "Enable browser notifications" → "Test browser notification" | Same controls with backup categories (G-NOT-*). |
| Top bar: reload, ⚙ Settings, Admin, ⇩ Ways to connect, Reset Panels, runtime label, brand + version; overflow `>>` on narrow screens | Same bar with this app's buttons; the runtime label shows the install mode (G-UI-2). |
| Panels with a titlebar, `?` help button with a floating help panel, maximize; responsive panel switcher on phones | Same (G-UI-3, G-UI-6). |
| Settings dialog with tabs, `fieldset` + `legend`, inline checkboxes, bounded number fields, help text, Cancel / **Save Settings** | Same (G-SET-*). |
| Confirm dialog (`Please confirm`); bell with an Activity tab | Same (G-UI-5, G-ACT-1). |
| Look: warm paper palette (`--bg #f4efe5`, `--panel #fffaf0`, `--accent #1a6b5b`, `--danger #9f3b2f`, radius 8 px, Segoe UI / system-ui, Cascadia Code / Consolas) | Same tokens plus a complete dark set (G-UI-1). |
| PWA manifest, icons, small service worker | Same (G-UI-8). |

Input and output options are the same kinds as agentw-gui's (owner, R1): for
input, tabbed settings, fieldsets, checkboxes, bounded number fields, and a
confirmation before every server change; for output, live panels, Tunnel
Manager native notices, browser notices, the bell's Activity list,
downloadable files, and copy buttons.

## 3. Architecture

```
 Your PC                         Server
 ┌──────────────────┐  SSH -L    ┌──────────────────────────────────────────────────────┐
 │ Tunnel Manager   │  (owner's  │ backup-suite-gui-4337.service  (user unit of admin)  │
 │  normal profile  │═══profile)▶│  Node server, $XDG_RUNTIME_DIR/backup-suite-gui/     │
 │  WebView window  │  socket    │  gui-4337.sock (0600 in 0700 dir)                    │
 │  native notices  │            │        │ one JSON request, one JSON reply            │
 └──────────────────┘            │        ├── user mode:  spawn bin/backup-control.sh   │
                                 │        │              as the user (systemctl --user)  │
                                 │        └── system mode: /run/backup-suite/control.sock│
                                 │             root:backup-suite-gui 0660 → socket-     │
                                 │             activated backup-suite-control@.service  │
                                 │             runs bin/backup-control.sh as root        │
                                 └──────────────────────────────────────────────────────┘
```

- **G-ARC-1** The GUI runs as the login user who administers Backup Suite:
  a systemd **user** unit `backup-suite-gui-4337.service` with
  `Restart=on-failure`, `WorkingDirectory` = the GUI directory, the resource
  drop-in of G-RES-1, and linger enabled for that user so it runs with nobody
  logged in. It never runs as root and never needs sudo.
- **G-ARC-2** The GUI never reads Backup Suite's config or state files
  itself and never runs `rclone` or `systemctl`. Every read and every change
  goes through **`bin/backup-control.sh`**, which holds the verb
  implementations once (section 5). It reads one JSON request on stdin and
  writes one JSON reply on stdout. Paths and `systemctl` scope come from the
  Backup Suite library (`resolve_effective_config`), so the script itself is
  the same in both modes.
- **G-ARC-3** Two backends, chosen by the install mode:
  - **direct (user mode)**: Backup Suite was installed by the user without
    sudo (`~/.config/backup-suite`, `~/.local/state/backup-suite`,
    `systemctl --user` units). The GUI starts
    `<user install dir>/bin/backup-control.sh` as a child process as
    itself. No root, no socket, no group. It can do nothing the user cannot
    already do in a terminal.
  - **broker (system mode)**: Backup Suite was installed with sudo
    (`/etc/backup-suite`, `/var/lib/backup-suite`, system units). The GUI
    connects to `/run/backup-suite/control.sock`; systemd starts one
    `backup-suite-control@.service` instance per connection, which runs
    `/opt/backup-suite/bin/backup-control.sh` as root with the request on
    stdin.
- **G-ARC-4** Mode detection: setting `backend` = `auto` (default),
  `user` or `system`. In `auto`, the GUI picks **user** when
  `${XDG_CONFIG_HOME:-~/.config}/backup-suite/global.conf` exists, else
  **system** when `/run/backup-suite/control.sock` exists, else shows a
  "Backup Suite not found" page with both install commands. When both exist,
  `auto` picks system and Settings offers the switch. The top bar shows the
  mode: "system mode · black" or "user mode · user@black".
- **G-ARC-5** Listener, exactly agentw-gui's `listen-config.js`: mode
  `socket` (default) at `${XDG_RUNTIME_DIR:-~/.local/state}/backup-suite-gui/gui-4337.sock`
  (0600 in a 0700 directory owned by the user; a wider directory owned by
  the user is tightened to 0700, any other owner stops the start); `tcp`
  (127.0.0.1:4337) and `both` are opt-in with the warning "This GUI is
  reachable by every local account on the server." The socket path may be
  overridden by `BACKUP_SUITE_GUI_SOCKET`. No public listener ever exists.
- **G-ARC-6** Several users on one server each install their own Backup
  Suite (user mode) and their own GUI. Their sockets live in their own
  runtime directories and never collide; only tcp mode needs a different
  port per user (Settings → Tunnel Manager → port).
- **G-ARC-7** Browser checks on the HTTP API: `Host` must be
  `127.0.0.1`, `localhost` or `[::1]`, with **any** port (Tunnel Manager
  chooses the local port); otherwise 403. Every changing request (`POST`,
  `PUT`, `DELETE`) must carry an `Origin` whose host and port equal the
  request's own `Host` (or the Origin of Tunnel Manager's app window,
  `wails.localhost` or `wails://wails`, whose proxy rewrites `Host`), and the
  per-page CSRF token from `GET /api/session`. Every live-stream message has
  an id; a reconnect with `Last-Event-ID` gets only what it missed, because
  that proxy ends the stream after each message.
  Tunnel Manager's event endpoint (`POST /api/events`) needs no CSRF token
  (Tunnel Manager sends no `Origin`), but still passes the `Host` check.
- **G-ARC-8** Instance name and ports: remote "port" 4337 (the instance
  name, and the TCP port in tcp mode), preferred local port 14337, range
  14337–14437 (owner, R5). agentw-gui uses 4317/14317.

### 3.1 System mode: the root broker

- **G-BRK-1** Units, installed by `setup.sh` / `production-deploy.sh` in
  system mode only: `backup-suite-control.socket`
  (`ListenStream=/run/backup-suite/control.sock`, `SocketUser=root`,
  `SocketGroup=backup-suite-gui`, `SocketMode=0660`, `Accept=yes`,
  `MaxConnections=8`, `ExecStartPost=… install-gui-broker.sh --refresh-acl`,
  which adds a `user:<login>:rw` ACL entry per group member, section 12) and
  `backup-suite-control@.service`
  (`StandardInput=socket`, `StandardOutput=socket`, `StandardError=journal`,
  `ProtectSystem=strict`, `ReadWritePaths=/etc/backup-suite
  /var/lib/backup-suite /etc/systemd/system`, `PrivateTmp=yes`,
  `ProtectHome=read-only`, `NoNewPrivileges=yes`, `MemoryMax=64M`,
  `TasksMax=32`, `RuntimeMaxSec=120`).
- **G-BRK-2** Who may connect: members of group `backup-suite-gui`. The
  deploy creates the group and adds the admins named with `--gui-admin
  <login>` (repeatable); the default is the user who ran the deploy through
  sudo (`SUDO_USER`). Deploy prints the members. The broker takes the
  connecting process's UID from its systemd instance name (section 11) and
  allows exactly the group's members and root.
- **G-BRK-3** **Trade-off (owner decision, stated):** any process running as
  an admin login can use these verbs, exactly as it can use the GUI. On
  black that login is `user`, which also runs the AI agent sessions. The
  verbs are a fixed list; none returns secrets, none writes the sources
  file, and the audit log (G-AUD-1) records every change with the caller's
  UID. On a server where that login already has passwordless sudo, this
  adds no ability it did not have.

### 3.2 Common to both modes

- **G-AUD-1** Every verb that changes something writes one audit line to
  the journal (`logger -t backup-suite-control`) and appends it to
  `<STATE_DIR>/gui/audit.jsonl` (newest 2000 kept): time, mode, caller UID
  and login, GUI session ID, verb, arguments (secrets replaced by `[set]`),
  result.
- **G-SEC-1** No reply ever contains secrets: `rclone.conf`, MySQL
  profiles, `NOTIFY_NTFY_TOKEN`, passwords. The ntfy topic URL is returned
  masked (`https://ntfy.sh/ab…yz`).
- **G-SEC-2** Two changing verbs never run at once: `flock
  <STATE_DIR>/gui/control.lock` for every changing verb.
- **G-SEC-3** Timeouts: reads 10 s, changes 60 s; a timeout is reported and
  never retried automatically.

## 4. Resource budget (the GUI must not become a load itself)

- **G-RES-1** User unit drop-in: `MemoryHigh=96M`, `MemoryMax=160M`,
  `TasksMax=64`, `CPUQuota=50%`, `Nice=10`. Healthy target: under 60 MB RSS
  while idle.
- **G-RES-2** With no browser connected, the GUI runs no control verbs
  except what Tunnel Manager's event poll needs (`events.since`, at most
  once per 5 s, and only if `events.jsonl` changed: the GUI compares its
  size and mtime through the verb's cheap `stat` mode).
- **G-RES-3** With clients connected, live status is read **once** per
  interval (default 5 s, settable 2–60 s) and fanned out to every tab over
  one Server-Sent Events stream (`GET /api/stream`). Tabs never poll on
  their own.
- **G-RES-4** Large reads are bounded: log slices ≤ 2000 lines and ≤ 1 MiB,
  history ≤ 500 rows, failure records ≤ 1 MiB; replies say `truncated: true`.
- **G-RES-5** A small watchdog (same pattern as `agentw-gui-watchdog`) stops
  the GUI unit if it stays above 140 MB for 15 s or above 56 tasks, and
  records why. It never touches the backup.

## 5. Control verbs (`bin/backup-control.sh`)

Request: one JSON line ≤ 64 KiB on stdin, for example
`{"verb":"profile.set","args":{"mode":"adaptive","top":"moderate","floor":"slow"},"session":"…"}`.
Reply: one JSON object on stdout, `{"ok":true,"data":…}` or
`{"ok":false,"error":{"code":"…","message":"…"}}`. Unknown verbs or
arguments outside the listed values fail with `invalid_request` and change
nothing. Unit names below are the Backup Suite units in the current mode's
scope (`systemctl` or `systemctl --user`).

| Verb | Work | Changes |
|---|---|---|
| `status` | fixed `systemctl show` properties for `file-backup.service/.timer`, `database-backup.service/.timer`, `database-size-check.service/.timer`, `backup-suite-watchdog@file-backup.service`; the watchdog status file, adaptive state, run progress (G-RUN-3), server memory | no |
| `history {limit}` | `watchdog/history.tsv` (15 columns) | no |
| `runlog {run: "latest"\|started_utc, lines}` | the run's slice of `logs/backup-file.log` | no |
| `journal {source, lines}` | `journalctl` for one allowed unit or `-t backup-watchdog`, bounded | no |
| `failures.list` / `failures.read {name}` | `failures/*.log` (name must match `^[0-9TZ]+-[A-Za-z0-9._-]+\.log$`) | no |
| `deferrals` | `active-files/*.tsv` | no |
| `sources.get` | `file-sources.conf` rows, raw text and SHA-256 | no |
| `excludes.list` | the `.backup-excludes` files of enabled sources (path, size, first 200 lines; ≤ 200 files) | no |
| `profile.show` | `backup-profile.sh show --json` | no |
| `profile.preview {…as set}` | `backup-profile.sh print-dropin` for the proposed setup | no |
| `profile.set {mode: fixed, profile}` / `{mode: adaptive, top, floor}` | `backup-profile.sh set` / `adaptive` | yes |
| `profile.limits {mode: fixed\|auto}` | `backup-profile.sh limits` | yes |
| `profile.override {profile, key, value \| unset: true}` | `backup-profile.sh override` | yes |
| `config.get` | allowlisted `global.conf` keys (G-SET-2), secrets masked, plus the file's SHA-256 | no |
| `config.set {changes, expect_sha}` | allowlisted keys only; timestamped copy in `gui/config-backups/` first; keeps symlink and inode; `config_conflict` when the SHA-256 differs | yes |
| `backup.start {what: files\|databases}` | `start --no-block` of the service | yes |
| `backup.stop` | `stop --no-block file-backup.service` | yes |
| `timer.set {timer, enabled}` | `enable --now` / `disable --now` of one of the three timers | yes |
| `notify.test` | `notify-test.sh` | sends |
| `events.since {seq}` / `events.stat` | `events.jsonl` after `seq` / its size and mtime | no |
| `audit {limit}` | `gui/audit.jsonl` | no |

There is **no verb that writes `file-sources.conf` in v1** (owner, R3).

## 6. Screens

Layout: top bar; a left navigation column; a main panel; and a right
**Details** panel for logs and explanations that can be maximized or closed.
On phones a panel switcher replaces the columns, as in agentw-gui.

### 6.1 Overview (default)

- **G-OV-1** File backup status: Idle / Running / Paused by watchdog /
  Stopping / Failed (last run). When running: started at, elapsed, current
  project and "project N of M" (G-RUN-3), counts so far.
- **G-OV-2** Live gauges from the watchdog status: backup memory against
  MemoryHigh and MemoryMax, non-reclaimable memory, swap, CPU against the
  quota, tasks, disk read/write this run; server RAM available and memory
  pressure, with the watchdog thresholds drawn on the bars. Green below
  contain (80 %), amber to kill (90 %), red above; each gauge also shows the
  number and a word.
- **G-OV-3** Profile card: "Fixed: moderate" or "Adaptive moderate ↔ slow —
  now slow", with a "Change…" button (6.4).
- **G-OV-4** Schedule card: each timer's state, last and next run; an amber
  warning when `file-backup.timer` is disabled or inactive.
- **G-OV-5** Last run card: outcome, duration, peaks, watchdog events, "Open
  run".
- **G-OV-6** Database backups card: last result and time of
  `database-backup.service` and `database-size-check.service`.
- **G-OV-7** Actions: **Start file backup now**, **Stop file backup**,
  **Start database backup now**, **Send test notification**, each behind a
  confirm dialog that says exactly what happens.
- **G-OV-8** Live mini-chart (inline SVG) of backup memory and CPU for the
  last 30 minutes, kept in server memory (360 × 5 s) and sent to new tabs.

### 6.2 Runs

- **G-RUN-1** `history.tsv` table, newest first, sortable, filter by outcome
  and by "had watchdog events".
- **G-RUN-2** Run detail in the Details panel: the run's log slice with
  search, key errors, the failure record if any, Download and Copy.
- **G-RUN-3** Progress: `file-backup.sh` writes `<STATE_DIR>/run/progress.env`
  at the start and before each project (started, total, index, label,
  counts, profile).
- **G-RUN-4** Failure records list with the same reader.

### 6.3 Projects and changing files

- **G-PRJ-1** Per-project table from the latest run log: label, source,
  destination, last result.
- **G-PRJ-2** Changing files from `active-files/*.tsv`, highlighted at or
  above `FILE_ACTIVE_MAX_DEFERRALS`, with the advice from `docs/RESOURCES.md`.

### 6.4 Profiles and limits

- **G-PRF-1** The five choices of `backup-profile.sh choose` as cards.
- **G-PRF-2** Each profile's resolved limits as `backup-profile.sh show`
  prints them, with the source of each value and the observed usage.
- **G-PRF-3** Limits mode switch (fixed / auto) with the resulting numbers.
- **G-PRF-4** Per-profile override grid with unit-aware inputs and unset.
- **G-PRF-5** Preview of the drop-in before saving; confirm; re-read and show
  the applied state.

### 6.5 Watchdog

- **G-WD-1** Live watchdog state, last action, watchdog journal.
- **G-WD-2** Thresholds grouped as in `docs/RESOURCES.md`, each with its
  default, range and purpose; "applies from the next backup run".
- **G-WD-3** Validation: release < contain < kill ≤ 99; critical < minimum
  available; step-up available > step-down available.

### 6.6 Notifications (ntfy)

- **G-NTF-1** Enabled, masked topic, priority, title prefix, token set yes/no.
- **G-NTF-2** Edit those; the token can be replaced or cleared, never shown.
- **G-NTF-3** Send test notification and show the result.

### 6.7 Sources (read-only in v1)

- **G-SRC-1** Table of `file-sources.conf`, the raw text read-only, Copy,
  Download, path and modified time.
- **G-SRC-2** No editing in v1 (owner, R3); the panel says where to edit
  and that editing arrives in v1.1. No save control, no writing verb.
- **G-SRC-3** Per-project `.backup-excludes` files, read-only.

### 6.8 Activity and audit

- **G-ACT-1** The bell lists all events, newest first, "new since you last
  looked".
- **G-ACT-2** Audit view of `audit.jsonl`.

## 7. Events and notifications

- **G-EVT-1** Append-only `<STATE_DIR>/events.jsonl`, one object per line
  `{seq, id, created_at, severity, category, title, message, unit}`, written
  by `ntfy_publish` in `bin/notify-lib.sh` (every ntfy alert, whether or not
  ntfy is configured or reachable) and by `backup-control.sh` for changes
  made through the GUI. Newest 1000 lines kept.
- **G-EVT-2** Categories: `run-finished`, `run-failed`, `watchdog-contain`,
  `watchdog-pause`, `watchdog-stop`, `profile-step`, `changing-files`,
  `schedule-off`, `gui-action`, `test`. Severity from ntfy priority:
  urgent/high → error, default → warning, low/min → info.
- **G-EVT-3** `POST /api/events`, Tunnel Manager `per-consumer-v1`:
  `consumer_id` required; every reply echoes `delivery_mode` and
  `consumer_id`; first consume returns `baseline: true` and no events;
  `action: "ack"` with `event_ids`, `acknowledged: 0` is success; events
  older than 180 s from `created_at` are never delivered; consumer state is
  persisted in the GUI's data directory so a restart replays nothing.
- **G-EVT-4** `GET /api/events?cursor=` lists without consuming.
- **G-EVT-5** Event `actions` are only relative `{kind: "url", target:
  "/#runs/<id>"}` links; never absolute, never commands.
- **G-NOT-1** Settings → Notifications as agentw-gui: Tunnel Manager
  delivery, browser delivery, prefer Tunnel Manager when active, one switch
  per category, Enable/Test browser notifications.
- **G-NOT-2** Tunnel Manager native notices: warnings and errors only
  (owner, R4; bundle `minimum_severity = "warning"`). Info events reach the
  bell and Activity list.
- **G-NOT-3** ntfy stays the off-server channel; GUI channels are extra.

## 8. Settings dialog

Tabs: **General** (refresh interval 2–60 s, chart window 10–120 min, time
display UTC/local, theme system/light/dark, backend auto/user/system),
**Notifications** (G-NOT-1), **Tunnel Manager** (listener mode, socket path,
tcp port, Tunnel Manager backend `user@host`, local port preference),
**GUI resource limits** (G-RES-1/5, after restart), **Server settings**
(`config.set`, each change confirmed and audited).

- **G-SET-1** GUI settings live in `${XDG_CONFIG_HOME:-~/.config}/backup-suite-gui/config.json`;
  event consumer state and the chart buffer snapshot in
  `${XDG_STATE_HOME:-~/.local/state}/backup-suite-gui/`.
- **G-SET-2** `config.set` allowlist: `FILE_BACKUP_RUNTIME_MAX_SEC`,
  `FILE_RETENTION_DAYS`, `FILE_ACTIVE_TRACKING_ENABLED`,
  `FILE_ACTIVE_WINDOW_SECONDS`, `FILE_ACTIVE_MAX_DEFERRALS`, all
  `WATCHDOG_*` keys, `NOTIFY_FAILURES_ENABLED`, `NOTIFY_NTFY_TOPIC_URL`,
  `NOTIFY_NTFY_TOKEN` (write-only), `NOTIFY_NTFY_PRIORITY`,
  `NOTIFY_NTFY_TITLE_PREFIX`, `NOTIFY_NTFY_ATTACH_DETAILS`,
  `NOTIFY_NTFY_MESSAGE_MAX_BYTES`. Profile keys only through `profile.*`;
  remote, rclone, source and MySQL settings are not editable.
- **G-SET-3** Each server setting shows its value, its default from
  `config/global.conf.example`, and a one-line explanation.

## 9. Ways to connect (⇩ button)

- **G-CON-1** Dialog as agentw-gui: Tunnel Manager download link, the
  bundle (shown, downloadable as `backup-suite-gui-tunnel-manager.toml`),
  launchers for Windows, macOS, Linux and Android, the manual line
  `ssh -N -L 127.0.0.1:14337:<socket> <login>@<host>`, Copy buttons. An
  editable **Tunnel Manager backend** field holds `backend_id`, hint: "must
  be the user@host of your Tunnel Manager profile for this server" (Tunnel
  Manager compares it textually and refuses the import on any difference).
  Default: the GUI's login and the saved host, else the server's primary
  IPv4 address; the value is saved.
- **G-CON-2** Generated bundle. `remote_socket` is the listener's actual
  path at request time; `unit` is the actual unit name; no `cursor_store`:

```toml
format = "tunnel-manager-tunnel"
version = 1
backend_id = "user@137.74.7.68"

[tunnel]
name = "backup-suite-gui"
remote_socket = "/run/user/1000/backup-suite-gui/gui-4337.sock"

[tunnel.local]
bind_host = "127.0.0.1"
mode = "preferred"
preferred_port = 14337
port_min = 14337
port_max = 14437
on_conflict = "prompt"
reuse_if_health_matches = true

[tunnel.health]
type = "http"
url = "http://127.0.0.1:{local_port}/api/health"
expect_app_id = "backup-suite-gui"
timeout = "10s"

[tunnel.launch]
type = "browser"
relaunch = "manual"

[tunnel.launch.browser]
url = "http://127.0.0.1:{local_port}/"
mode = "webview"
browser = "auto"

[tunnel.events]
enabled = true
url = "http://127.0.0.1:{local_port}/api/events"
poll_interval = "5s"

[tunnel.notifications]
mode = "enabled"
minimum_severity = "warning"
suppress_browser_duplicates = true
include_detailed_app_messages = true

[tunnel.remote_service]
enabled = true
provider = "systemd-user"
unit = "backup-suite-gui-4337.service"
policy = "start-if-stopped"
monitor_interval = "30s"
command_timeout = "15s"
start_timeout = "60s"
restart_limit = 3
restart_window = "10m"
stop_on_tunnel_stop = false
```

  (The path shown is an example from uid 1000; the generator uses the
  running service's real path.) In tcp mode `remote_socket` becomes
  `remote_host = "127.0.0.1"` and `remote_port = <tcp port>`.
- **G-CON-3** Bundle and launchers are generated per request; they contain
  no credentials, `ssh_options`, executable launch or local actions.
- **G-CON-4** First import: `gui/scripts/backup-suite-gui-server bundle
  [--backend user@host]` prints the same bundle on the server.
- **G-CON-5** Tunnel Manager uses the owner's normal profile for the admin
  login (on black: `User_Black`, login `user`).

## 10. Look and feel

- **G-UI-1** agentw-gui's `:root` tokens; theme system / light / dark
  (owner, R6), every token defined for both themes, dark under
  `@media (prefers-color-scheme: dark)` guarded by
  `:root:not([data-theme="light"])` and under `:root[data-theme="dark"]`;
  WCAG AA (4.5:1 text, 3:1 UI parts) in both.
- **G-UI-2** Top bar: ⟳ Reload, ⚙ Settings, **Actions**, ⇩ Ways to connect,
  Reset Panels, the mode label ("system mode · black"), a state chip, and the
  brand "Backup-Suite-Gui" with version; `>>` overflow on narrow screens.
- **G-UI-3** Panel titlebars with `?` help (floating panel) and maximize.
- **G-UI-4** Human units (MiB/GiB, % of limit, minutes); UTC with local time
  on hover (swappable).
- **G-UI-5** "Please confirm" before every change, naming the effect and
  when it applies; errors shown with message and code.
- **G-UI-6** Works from 390 px wide, no horizontal page scroll.
- **G-UI-7** Keyboard reachable, visible focus, `aria-label` on icon
  buttons, state never by color alone.
- **G-UI-8** PWA manifest, icons, service worker caching static assets only.
- **G-UI-9** Connection-loss banner that clears when the stream reconnects.

## 11. Backend changes in Backup Suite

1. `bin/backup-control.sh` (both modes). In system mode the broker unit
   starts it as `backup-control.sh --peer %i`: with `Accept=yes` on a Unix
   socket, systemd names each connection's instance `<n>-<peer pid>-<peer
   uid>` (verified on this host, systemd 255), so the caller's UID comes from
   systemd itself and no helper program is needed.
2. `systemd/backup-suite-control.socket.template` and
   `backup-suite-control@.service.template`; setup/deploy in system mode
   create group `backup-suite-gui`, add the admins (`--gui-admin`, default
   `SUDO_USER`), install and start the socket.
3. `backup-profile.sh show --json`.
4. `file-backup.sh` writes `run/progress.env`.
5. `notify-lib.sh` appends to `events.jsonl`.
6. `production-deploy.sh` checks: socket active, `status` answers as root,
   group members printed.
7. Tests: every verb in a fake system root and in user mode; refused values;
   secrets never in replies; `config_conflict`; audit lines; no verb writes
   `file-sources.conf`; peer-UID refusal.

## 12. GUI install and operation

- `gui/` in this repository: `server.js`, `lib/` (listen config, control
  client, events, bundle, launchers, settings), `public/`, `test/`,
  `scripts/backup-suite-gui-server` (`install|uninstall|start|stop|restart|status|bundle|service-run`),
  `scripts/backup-suite-gui-watchdog`.
- `backup-suite-gui-server install` (as the admin user, no sudo): writes the
  user unit and its drop-in with the absolute Node path, enables and starts
  it, enables the watchdog, prints the socket path, whether linger is on, and
  the `bundle` hint.
- Owner steps (to-do at implementation):
  1. install or update Backup Suite as usual (system mode: `sudo
     ./production-deploy.sh …`, which installs the broker and adds the
     deploying user to `backup-suite-gui`);
  2. `gui/scripts/backup-suite-gui-server install`; `loginctl enable-linger
     <user>` once if linger is off;
  3. in Tunnel Manager's existing profile, import the bundle and press Start.
- Group membership and running GUIs: a user's systemd manager keeps the
  groups it started with, and restarting it would stop that user's other
  services (on black: agentw-gui and the AI sessions). So the socket unit's
  `ExecStartPost` (`install-gui-broker.sh --refresh-acl`) gives every member
  of `backup-suite-gui` a POSIX ACL entry `user:<login>:rw` on
  `/run/backup-suite/control.sock`. A new admin can connect at once; the
  group stays the single list of admins and the broker still checks it
  (G-BRK-2).

## 13. Later phases (not v1)

- **v1.1** Edit `file-sources.conf`: validation identical to
  `file-backup.sh`, diff before saving, backup copy, `expect_sha`, refused
  while a file backup runs, audited.
- Restore browser (owner, R7): Google Drive versions, restore to a staging
  directory, never in place.
- Database backup management; run one project now; dry run; several servers.

## 14. Review decisions

| ID | Decision |
|---|---|
| R1 | Input/output options: the same kinds as agentw-gui. |
| R2 | System mode uses a socket-activated root broker with a fixed verb list, not sudo rules. Revision 3: its group holds the admins named at deploy (default `SUDO_USER`); the trade-off is stated in G-BRK-3. |
| R3 | Sources read-only in v1; editing in v1.1. |
| R4 | Tunnel Manager notices: warnings and errors only. |
| R5 | `backup-suite-gui`, 4337 / 14337 (14337–14437). Revision 3: owned by the admin login. |
| R6 | Dark theme in v1 (system / light / dark, WCAG AA). |
| R7 | Restore from Google Drive later. |
| Rec-3 | Copy agentw-gui's setup: user unit, `$XDG_RUNTIME_DIR` socket, owner's normal Tunnel Manager profile, `remote_service` `systemd-user`; one GUI, two backends (direct / broker). Dropped: `backup-gui` account, sshd block, jail, key handoff, capabilities endpoint. Kept: editable `backend_id`, no `cursor_store`, no hard-coded socket path, linger, Host/Origin with any port. |

## 15. Verification checklist

Automated items run in `tests/run.sh` (bash, control script) and
`gui/test/` (`node --test`, no dependencies).

| # | Check | Proves | How |
|---|---|---|---|
| V1 | The GUI runs as the admin user (not root); no GUI code reads Backup Suite files directly (grep: all access via the control client) | G-ARC-1/2 | automated + manual |
| V2 | Unknown verb, extra argument, out-of-range value, path traversal in `failures.read` → `invalid_request`, nothing changed | G-ARC-2, §5 | automated |
| V3 | System mode: socket `root:backup-suite-gui 0660` with one ACL entry per member (`install-gui-broker.sh --check`); a connection from a UID outside the group is refused and logged | G-BRK-1/2 | automated + manual |
| V4 | No reply of any verb contains the ntfy token, the unmasked topic, or `rclone.conf` content | G-SEC-1 | automated |
| V5 | Each changing verb leaves one journal line and one `audit.jsonl` line with the caller UID | G-AUD-1 | automated |
| V6 | Socket directory owned by someone else → GUI refuses to start; a wider own directory is tightened to 0700 | G-ARC-5 | automated |
| V7 | Idle RSS < 60 MB after 10 min with one tab; with no tab, only `events.stat` calls | G-RES-1/2 | manual |
| V8 | Three tabs → one `status` call per interval | G-RES-3 | automated |
| V9 | `runlog` with `lines=100000` → ≤ 2000 lines, `truncated: true` | G-RES-4 | automated |
| V10 | `config.set` with a stale `expect_sha` → `config_conflict`, file unchanged; success keeps symlink/inode and leaves a backup copy | §5 | automated |
| V11 | `file-sources.conf` SHA-256 unchanged after the whole test run; Sources panel has no save control | G-SRC-2 | automated |
| V12 | During a real run: Running, project N of M, live gauges matching the watchdog status file | G-OV-1/2, G-RUN-3 | manual |
| V13 | GUI "Adaptive moderate ↔ slow" gives the same `global.conf` keys and drop-in as `backup-profile.sh adaptive moderate slow` | G-PRF-1/5 | automated |
| V14 | Watchdog form rejects release ≥ contain and critical ≥ minimum | G-WD-3 | automated |
| V15 | Tunnel Manager: import into the owner's profile; with nobody logged in (linger), Start → `start-if-stopped` starts the unit if needed, health matches, WebView opens; a mismatched `backend_id` is refused | G-CON-1/2/5, G-ARC-1 | manual |
| V16 | Events: baseline, echo of `delivery_mode`/`consumer_id`, once per installation, idempotent ack, 180 s TTL, no replay after restart | G-EVT-3 | automated + manual |
| V17 | Test notification → ntfy with description + attachment; bell entry; a Tunnel Manager notice for a warning event and none for an info event | G-NTF-3, G-NOT-2 | manual |
| V18 | 390 px wide: no horizontal scroll, all actions reachable | G-UI-6 | manual |
| V19 | Themes system/light/dark apply; token contrast check ≥ 4.5:1 / 3:1 | G-UI-1/7 | automated + manual |
| V20 | Tunnel down → banner; back → banner clears, stream resumes | G-UI-9 | manual |
| V21 | Same verb tests pass in user mode (direct backend, `systemctl --user` via a fake) and in system mode (fake root) | G-ARC-3 | automated |
| V22 | `Host: evil.example` → 403; `Host: 127.0.0.1:14399` and `localhost:<any>` and `[::1]:<any>` → allowed; changing request with foreign `Origin` or no CSRF token → 403; `POST /api/events` without CSRF → allowed | G-ARC-7 | automated |
| V23 | Bundle: no `cursor_store`, actual `remote_socket` and unit, saved `backend_id`, `remote_service` `systemd-user` | G-CON-2 | automated |
| V24 | Mode detection: user config only → user; socket only → system; both → system with switch offered; neither → "not found" page | G-ARC-4 | automated |
