# Backup Suite GUI

A browser GUI for Backup Suite, reached through an SSH tunnel managed by Tunnel
Manager. It shows what the backups are doing and how much of the server they use,
and offers the same controls as the command-line tools. The full requirements and
the acceptance checks are in [GUI-SPECIFICATION.md](GUI-SPECIFICATION.md).

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
the AI agent sessions. The verbs are a fixed list; none returns secrets, none writes
`file-sources.conf`, and every change is audited.

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

## Connect with Tunnel Manager

1. Print the bundle with your Tunnel Manager profile's exact `user@host`:
   `gui/scripts/backup-suite-gui-server bundle --backend user@137.74.7.68 > backup-suite-gui.toml`
2. In Tunnel Manager, in your existing profile for this server, Import that file and
   press Start. Tunnel Manager starts the GUI unit if it is stopped, checks
   `/api/health` for `backup-suite-gui`, and opens the app window.
3. Later bundles, launchers for Windows/macOS/Linux/Android and the manual `ssh -L`
   line are in the GUI's ⇩ **Ways to connect** dialog.

Tunnel Manager shows warnings and errors from Backup Suite as desktop notices.
Every event, including "run finished", is in the bell's Activity list.

## Operate

```bash
gui/scripts/backup-suite-gui-server status      # unit status and the GUI watchdog's last stop
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
