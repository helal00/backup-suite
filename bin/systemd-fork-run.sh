#!/bin/bash

set -euo pipefail

pid_file="${1:-}"
shift || true

[ -n "$pid_file" ] || {
    echo "Usage: systemd-fork-run.sh <pid-file> <command> [args...]" >&2
    exit 1
}

[ "$#" -gt 0 ] || {
    echo "No command provided to systemd-fork-run.sh" >&2
    exit 1
}

mkdir -p "$(dirname "$pid_file")"
rm -f "$pid_file"

"$@" &
child_pid=$!

printf '%s\n' "$child_pid" > "$pid_file"

exit 0