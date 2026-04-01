# Contributing

Contributions are welcome.

## Before Opening a Change

- keep changes focused and minimal
- preserve the shell-first, config-driven design
- avoid committing live server config, credentials, tokens, or private paths
- update example files and docs when behavior changes

## Development Notes

- edit source files in the repository, not installed copies under `/opt`
- validate shell scripts before committing:

```bash
bash -n setup.sh
bash -n bin/*.sh
```

- when changing systemd templates, refresh units in a test environment and verify with `systemctl status` and `journalctl`

## Config and Secrets

- keep only `*.example` config files in git
- do not commit real `rclone.conf`, database credentials, or host-specific runtime files

## Pull Requests

- describe the problem being solved
- note any operational impact
- include the commands used for validation when relevant