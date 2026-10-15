#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/notify-lib.sh"

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
Usage: notify-test.sh

Sends one test notification to the configured ntfy topic, in the same format as
real alerts: a readable description as the message and a detail file attached.
EOF
        exit 0
        ;;
esac

load_global_config
resolve_file_backup_profile "${FILE_BACKUP_PROFILE:-custom}"
is_enabled_value "${NOTIFY_FAILURES_ENABLED:-0}" || fail "NOTIFY_FAILURES_ENABLED is off; enable it in $GLOBAL_CONFIG_FILE first."

host_name=$(trim "${REMOTE_HOSTNAME:-}")
[ -n "$host_name" ] || host_name=$(hostname)
detail_file=$(mktemp)
trap 'rm -f "$detail_file"' EXIT

message=$(cat <<EOF
Test notification - no action needed.

What happened: an administrator ran the Backup Suite notification test.

What alerts look like now: every alert starts with a plain-language description (what happened, the likely cause, what Backup Suite did to protect the server and the remote copies, and what to do). The full technical log is attached as a file.

Host: $host_name | Profile: $PROFILE_NAME ($PROFILE_SUMMARY)
Sent: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
EOF
)
{
    printf '%s\n\n' "$message"
    echo "This attachment would contain the full journal and durable-log excerpt of a real alert."
} > "$detail_file"

notify_publish "${NOTIFY_NTFY_TITLE_PREFIX:-Backup Suite}: notification test on $host_name" default "test_tube,backup" \
    "$message" "$detail_file" "notification-test.txt" test
