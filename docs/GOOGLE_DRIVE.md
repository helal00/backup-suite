# Google Drive Notes

If the backup host is remote and `rclone` asks for a localhost callback URL, you can complete the login from your own machine by forwarding that port over SSH.

Typical system-mode reconnect command:

```bash
sudo rclone --config /etc/backup-suite/rclone.conf config reconnect gdrive:
```

Do not omit `--config /etc/backup-suite/rclone.conf` for system-mode installs. The systemd services run `rclone` with the configured `RCLONE_CONFIG_PATH`, not necessarily root's default `/root/.config/rclone/rclone.conf`. Testing or reconnecting plain `sudo rclone ...` can therefore fix the wrong config while Backup Suite continues to fail.

Confirm the exact configured path first:

```bash
sudo grep -E 'INSTALL_MODE|RCLONE_CONFIG_PATH|RCLONE_REMOTE_ROOT' /etc/backup-suite/global.conf
```

Then test the same config Backup Suite uses:

```bash
sudo rclone --config /etc/backup-suite/rclone.conf lsd "gdrive,root_folder_id=YOUR_FOLDER_ID:"
```

If `rclone` listens on a local callback such as `127.0.0.1:53682`, create a tunnel from your workstation first:

```bash
ssh -L 53682:127.0.0.1:53682 user@your-server
```

Then open the Google authorization URL in your workstation browser.

Notes:

- if `rclone` uses a different localhost port, tunnel that port instead
- keep the SSH session open until the reconnect completes
- the same method works for first-time Google Drive authorization and later token refresh or reconnect events

Alternative headless method:

- run `rclone authorize "drive"` on a machine with a browser
- copy the resulting token JSON back into the server config

- this avoids the SSH tunnel, but the tunnel workflow is often simpler when you already have shell access to the server

Token lifetime notes:

- Google access tokens are short-lived by design
- `rclone` refreshes them automatically when the refresh token remains valid
- `invalid_grant` usually means the refresh token is no longer usable and the remote must be reconnected
- in system mode, reconnect the Backup Suite config path, for example `sudo rclone --config /etc/backup-suite/rclone.conf config reconnect gdrive:`

- reconnecting updates the stored token in `rclone.conf`; there is no supported setting in Backup Suite or `rclone` to make Google keep the same access token valid for a longer time
