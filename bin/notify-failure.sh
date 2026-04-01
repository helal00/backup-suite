#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

load_global_config

unit_name="${1:-}"
[ -n "$unit_name" ] || fail "Usage: notify-failure.sh <failed-unit-name>"

if ! is_enabled_value "${NOTIFY_FAILURES_ENABLED:-0}"; then
    echo "Failure notifications are disabled."
    exit 0
fi

topic_url=$(trim "${NOTIFY_NTFY_TOPIC_URL:-}")
[ -n "$topic_url" ] || fail "NOTIFY_NTFY_TOPIC_URL must be set when NOTIFY_FAILURES_ENABLED=1"

require_command curl

host_name=$(trim "${REMOTE_HOSTNAME:-}")
if [ -z "$host_name" ]; then
    host_name=$(hostname)
fi

journal_lines="${NOTIFY_JOURNAL_LINES:-40}"
title_prefix=$(trim "${NOTIFY_NTFY_TITLE_PREFIX:-Backup Suite}")
priority=$(trim "${NOTIFY_NTFY_PRIORITY:-high}")

if [ "$SYSTEMD_SCOPE" = "user" ]; then
    journal_output=$(journalctl --user -u "$unit_name" -n "$journal_lines" --no-pager 2>&1 || true)
else
    journal_output=$(journalctl -u "$unit_name" -n "$journal_lines" --no-pager 2>&1 || true)
fi

message=$(cat <<EOF
$title_prefix failure on $host_name

Failed unit: $unit_name
When: $(date -u '+%Y-%m-%d %H:%M:%S UTC')

Recent logs:
$journal_output
EOF
)

curl \
    -fsS \
    -H "Title: $title_prefix failure on $host_name" \
    -H "Priority: $priority" \
    -H "Tags: warning,backup" \
    -d "$message" \
    "$topic_url"

echo "Failure notification sent for unit: $unit_name"