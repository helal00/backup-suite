# Installation

## Directory Layout

Source suite tree:

- `/home/user/tools/backup-suite`

Installed suite defaults depend on mode.

System mode defaults:

- scripts: `/opt/backup-suite`
- canonical source: `/opt/backup-suite-src`
- config: `/etc/backup-suite`
- state: `/var/lib/backup-suite`
- local DB dumps: `/var/backups/backup-suite/databases`

User mode defaults:

- scripts: `~/.local/share/backup-suite`
- config: `~/.config/backup-suite`
- state: `~/.local/state/backup-suite`
- local DB dumps: `~/backups/backup-suite/databases`

## Config Files

This repository ships only example config files.

When used as a live deployment tree, the canonical config files are:

- `global.conf`
- `file-sources.conf`
- `database-backups.conf`
- `rclone.conf`
- `mysql-profiles/*.cnf`

In user mode, setup deploys runtime config into `~/.config/backup-suite`.

In system mode, setup copies the suite source tree into `/opt/backup-suite-src`, then symlinks `/etc/backup-suite` back to that copied canonical source tree.

Example files remain alongside them for reference.

## Setup Script

Script:

- `/home/user/tools/backup-suite/setup.sh`

If the suite was downloaded or extracted from an archive and executable bits were not preserved, fix them once before running setup:

```bash
chmod 755 /home/user/tools/backup-suite/setup.sh /home/user/tools/backup-suite/bin/*.sh
```

Run it yourself after editing the real config files:

```bash
sudo /home/user/tools/backup-suite/setup.sh --dry-run
sudo /home/user/tools/backup-suite/setup.sh
```

In system-mode dry runs, the script previews deployment into `/opt/backup-suite-src` but reads templates and config from the current source tree during the preview. That avoids false errors when the target canonical source tree does not exist yet.

If you run setup without `sudo`, the suite can install itself in user mode automatically.

User mode example:

```bash
/home/user/tools/backup-suite/setup.sh --dry-run
/home/user/tools/backup-suite/setup.sh
```

If you run setup with `sudo` or while logged in directly as `root`, and `INSTALL_MODE="auto"`, the script first detects that system-wide installation is possible and then asks you to choose:

- `system` to install system-wide
- `cancel` to stop and re-run the script without `sudo` as the target user for a user-mode install

Optional refresh modes:

```bash
sudo /home/user/tools/backup-suite/setup.sh --refresh-scripts
sudo /home/user/tools/backup-suite/setup.sh --refresh-config
sudo /home/user/tools/backup-suite/setup.sh --refresh-units
```

Overwrite behavior:

- existing installed files are kept by default
- refresh flags enable replacement attempts for that category only
- overwrite requires explicit confirmation unless you also pass `--yes`

Install mode behavior:

- `INSTALL_MODE="auto"` offers system-mode installation when run with `sudo` or while logged in directly as `root`
- `INSTALL_MODE="auto"` selects user mode when run without `sudo`
- you can force `INSTALL_MODE="user"` or `INSTALL_MODE="system"` in the config
- when run as root with `INSTALL_MODE="auto"`, the script asks for explicit confirmation before choosing system mode
- `INSTALL_MODE="user"` is not allowed when running with `sudo` or while logged in directly as `root`; for per-user installation, run the setup script as that user without `sudo`

## What the Setup Script Can Do

- install the suite under `/opt/backup-suite`
- in system mode, copy the suite source tree into `/opt/backup-suite-src`
- deploy runtime config symlinks into `/etc/backup-suite` or `~/.config/backup-suite`
- in system mode, add the canonical `/opt/backup-suite-src` source to file backup config as disabled by default if it is not already present
- install systemd service and timer units
- optionally enable the timers

In user mode, the setup script:

- installs into your home directory
- deploys config into your home config directory
- installs user-level units under `~/.config/systemd/user`
- uses `systemctl --user`
- assumes `rclone` is already installed and available in your PATH
- does not attempt to expand your permissions beyond what your user can already access

## Prerequisites

For both system mode and user mode, this suite assumes these commands are already installed and available:

- `rclone`
- `mysql`
- `mysqldump`

Optional but recommended:

- `zstd`

For user mode specifically, `rclone` is not installed by the setup script. It must already be installed for that user environment and available in the user's PATH.

User-level `rclone` install example for a user such as `web10`:

Check architecture:

```bash
uname -m
```

Example for `x86_64`:

```bash
mkdir -p "$HOME/tools/rclone" "$HOME/bin"
cd "$HOME/tools/rclone"
curl -LO https://downloads.rclone.org/rclone-current-linux-amd64.zip
unzip -o rclone-current-linux-amd64.zip
cp rclone-*-linux-amd64/rclone "$HOME/bin/rclone"
chmod 755 "$HOME/bin/rclone"
```

Add it to PATH:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> "$HOME/.bashrc"
. "$HOME/.bashrc"
```

Verify:

```bash
command -v rclone
rclone version
```