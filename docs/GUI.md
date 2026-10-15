# Backup Suite GUI

A browser GUI for Backup Suite, reached through an SSH tunnel managed by Tunnel
Manager. It shows what the backups are doing and how much of the server they use,
and offers the same controls as the command-line tools. The full requirements and
the acceptance checks are in [GUI-SPECIFICATION.md](GUI-SPECIFICATION.md).

## What it shows

- **Left panel: backup jobs.** **+ New job**, a Home card, then one card per job
  (one line of `file-sources.conf`): enabled, state, source, mapping, last run,
  changed and changing files. A filter shows all jobs, enabled ones, or those needing
  attention. **Home** shows the whole system: a verdict, what runs now, live server and
  backup resources, every job's state, database backups and the latest ntfy
  notifications.
- **A job's page:** **Back up now** (this job only), **Edit…**, **Enable/Disable…**,
  **Remove…**, and eight tabs: Overview, Projects (one per child folder with
  `children`), Changed files, Changing files, Excludes & stop files, Runs, Log, and
  Source & destination (sizes measured on request).
- **Job editor:** name, enabled, source folder, projects (single or children),
  destination mode and folder, stop file, and the job's own exclude and volatile
  patterns (`<config>/jobs/<name>.excludes` and `.volatile`, applied to every project
  of the job). The server checks the draft as you type.
- **Admin** (modal): actions and schedule, runs and failures, profiles and limits,
  watchdog, ntfy, **All settings** (every `global.conf` key, grouped; schedule changes
  are applied to the timers at once through `bin/apply-schedule.sh`), the sources
  file, logs, activity and audit.
- **Destinations** (Admin): Google Drive, Dropbox, OneDrive, S3 and other rclone
  remotes, set up with a wizard that walks through rclone's own questions (one
  `rclone authorize …` sign-in on your computer for OAuth services), tested, browsed
  and removed. A job sends its backup to the default destination or to one of these
  (destination mode `remote`, value `name:folder`). Only cloud and network types, no
  option that reads a file or runs a program; secrets are never shown.
- **Folder pickers:** the job's source folder (only under `FILE_JOB_SOURCE_ROOTS`)
  and its folder on the destination are chosen by browsing.
- **Notifications** are generic: one message per event goes to every enabled channel
  (ntfy now; Telegram, WhatsApp, email and SMS later). The bell lists them all with
  each channel's result; Admin → Notifications has each channel's switch, settings,
  test and delivery log.
- **Updates:** asset URLs carry the GUI build and are revalidated on every load, so
  a page reload always gets the installed version; when the GUI is reinstalled the
  reload button turns red.
- **Resource warning:** a popup when the server or the backup runs short, once per
  condition until it clears.
- ⚙ holds this GUI's own settings only.

Per-job data comes from `file-backup.sh`: one row per project and run in
`<state>/projects/history.tsv` (bounded to 20000 lines) and each project's changed
files from its last run in `<state>/projects/changes/<key>.tsv` (from rclone's
per-file lines, kept out of the logs). Until the first run after a deploy, job pages
use the latest run's log.

### What the GUI may change

- A job may only back up a folder under `FILE_JOB_SOURCE_ROOTS` (default
  `/home /var/www /srv /opt`), never a system folder (`/etc`, `/root`, `/usr`,
  `/var/lib`, …) nor one holding Backup Suite's own install, config or state. Only the
  server's administrator sets `FILE_JOB_SOURCE_ROOTS`, in `global.conf`.
- Programs and paths the backup runs or reads as root (rclone binary, extra rclone
  flags, config, state and unit paths) and install options are shown but read-only:
  from the GUI they could make root run anything.
- Every change is confirmed, refused if the file changed since it was read, backed up
  under `<state>/gui/config-backups/`, and audited. Removing a job deletes nothing on
  the remote.

## How it runs

- The GUI is a Node.js server (standard library only, Node 18 or newer) that runs as
  a **systemd user unit of the login that administers Backup Suite**:
  `backup-suite-gui-4337.service`, like agentw-gui. It never runs as root.
- It listens on a private Unix socket,
  `$XDG_RUNTIME_DIR/backup-suite-gui/gui-4337.sock` (0600 in a 0700 directory).
  TCP on 127.0.0.1 is opt-in (Settings → Tunnel Manager) and reachable by every local
  account.
- It reaches Backup Suite only through `bin/backup-control.sh`:
  - **user mode** (Backup Suite installed without sudo): the GUI runs the script
    directly, as the user;
  - **system mode** (installed with sudo): the GUI connects to
    `/run/backup-suite/control.sock`; systemd runs the same script as root for each
    connection. Only root and members of group `backup-suite-gui` may use it; each
    member gets an ACL entry on the socket.
- Every change made through the GUI is confirmed in the browser, validated by the
  control script, and recorded in `<state dir>/gui/audit.jsonl` and the journal
  (`journalctl -t backup-suite-control`).

Trade-off in system mode: any process running as a GUI admin login can use the
control verbs, exactly as it can use the GUI. On this server that login also runs
the AI agent sessions. The verbs are a fixed list; none returns secrets, a job may
only back up folders under `FILE_JOB_SOURCE_ROOTS` (set on the server, never from
the GUI), root-run programs and paths are read-only, and every change is audited.

## Install

System mode (this server):

```bash
cd /home/user/php-projects-lv/backup-suite
sudo ./production-deploy.sh --profile moderate --floor slow --gui-admin user   # installs the broker
gui/scripts/backup-suite-gui-server install                                    # as user, no sudo
```

`install` copies the GUI to `~/.local/share/backup-suite-gui/app`, writes the user
units with the absolute Node path, starts them, and reports the socket and whether
linger is on. Run it again to update the GUI. If linger is off, run once:
`loginctl enable-linger <login>` (then the GUI runs with nobody logged in).

User mode: install Backup Suite with `./setup.sh` as the user, then run
`gui/scripts/backup-suite-gui-server install`.

## Connect

Every way to connect is in the GUI's ⇩ **Ways to connect** dialog (also under
Actions) and in `gui/scripts/backup-suite-gui-server status`, made by the same code:

- **Tunnel Manager** (recommended): download `backup-suite-gui-tunnel-manager.toml`
  and Import it in your Tunnel Manager profile for this server, then Start. Tunnel
  Manager starts the GUI unit if it is stopped, checks `/api/health` for
  `backup-suite-gui`, and opens the app window.
- **Launcher scripts** for Windows, macOS and Linux: open the tunnel, wait for the
  GUI, open the browser and reconnect on drops.
- **Phone or tablet**: Termux on Android, Blink Shell on iPhone/iPad.
- **Manual**: one `ssh -N -L 127.0.0.1:14337:<socket> user@host` line.

The backend `user@host` must be the one your Tunnel Manager profile shows. Save it
once in the dialog or with `gui/scripts/backup-suite-gui-server backend user@host`.
`status` also saves the profile and the launchers in
`~/.local/share/backup-suite-gui/client-launchers`.

Tunnel Manager's app window is a webview at `wails.localhost` whose local proxy
forwards requests with Host `127.0.0.1:<port>`; the GUI accepts that Origin (the CSRF
token is still required). The proxy also ends the live stream after each message:
every message has an id, a reconnecting window gets only what it missed, and the
"connection lost" banner shows only after 30 s without a stream.

Tunnel Manager shows warnings and errors from Backup Suite as desktop notices.
Every event, including "run finished", is in the bell's Activity list.

## Operate

```bash
gui/scripts/backup-suite-gui-server status      # unit, the GUI watchdog's last stop, every way to connect
gui/scripts/backup-suite-gui-server restart
journalctl --user -u backup-suite-gui-4337.service -n 50 --no-pager
```

The GUI's own limits (Settings → GUI resource limits) default to 96 MB soft,
160 MB hard, 64 tasks, 50% of one core. Its watchdog stops it above 140 MB for 15 s
or 56 tasks; it never touches the backup.

## Test

```bash
tests/run.sh                                   # includes the GUI's node tests
(cd gui && node --test test/*.test.js)         # GUI tests only
node gui/test/browser/validate-ui.cjs          # browser check (Playwright + Chromium)
```
