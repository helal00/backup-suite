# Google Drive Notes

If the backup host is remote and `rclone` asks for a localhost callback URL, you can complete the login from your own machine by forwarding that port over SSH.

Typical reconnect command:

```bash
sudo rclone --config /etc/backup-suite/rclone.conf config reconnect gdrive:
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

- reconnecting updates the stored token in `rclone.conf`; there is no supported setting in Backup Suite or `rclone` to make Google keep the same access token valid for a longer time
