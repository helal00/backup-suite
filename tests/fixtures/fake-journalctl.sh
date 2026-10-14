#!/bin/bash

set -euo pipefail

printf '%s\n' "$*" >> "${FAKE_JOURNALCTL_LOG:-/dev/null}"
echo "2026-10-14T10:00:00+0000 black backup-watchdog[1]: fake journal line for: $*"
