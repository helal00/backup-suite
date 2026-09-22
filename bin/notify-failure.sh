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
durable_log_lines="${NOTIFY_DURABLE_LOG_LINES:-120}"
failure_log_keep_files="${NOTIFY_FAILURE_LOG_KEEP_FILES:-100}"
title_prefix=$(trim "${NOTIFY_NTFY_TITLE_PREFIX:-Backup Suite}")
priority=$(trim "${NOTIFY_NTFY_PRIORITY:-high}")

[[ "$journal_lines" =~ ^[0-9]+$ ]] || fail "NOTIFY_JOURNAL_LINES must be a non-negative integer"
[[ "$durable_log_lines" =~ ^[0-9]+$ ]] || fail "NOTIFY_DURABLE_LOG_LINES must be a non-negative integer"
[[ "$failure_log_keep_files" =~ ^[0-9]+$ ]] || fail "NOTIFY_FAILURE_LOG_KEEP_FILES must be a positive integer"
[ "$failure_log_keep_files" -gt 0 ] || fail "NOTIFY_FAILURE_LOG_KEEP_FILES must be greater than zero"

if [ "$SYSTEMD_SCOPE" = "user" ]; then
    journal_output=$(journalctl --user -u "$unit_name" -n "$journal_lines" --no-pager 2>&1 || true)
else
    journal_output=$(journalctl -u "$unit_name" -n "$journal_lines" --no-pager 2>&1 || true)
fi

case "$unit_name" in
    file-backup.service)
        durable_identifier="backup-file"
        ;;
    database-backup.service)
        durable_identifier="backup-db"
        ;;
    database-size-check.service)
        durable_identifier="backup-db-monitor"
        ;;
    *)
        durable_identifier=""
        ;;
esac

durable_log_path=""
durable_output="No mapped durable log for this unit."
if [ -n "$durable_identifier" ]; then
    durable_log_path=$(join_path "$STATE_DIR" "logs" "${durable_identifier}.log")
    if [ -f "$durable_log_path" ]; then
        durable_output=$(tail -n "$durable_log_lines" "$durable_log_path" 2>&1 || true)
    else
        durable_output="Durable log not found yet: $durable_log_path"
    fi
fi

failure_log_dir=$(join_path "$STATE_DIR" "failures")
failure_unit_name="${unit_name//[^[:alnum:]._-]/_}"
failure_log_path=$(join_path "$failure_log_dir" "$(date -u '+%Y%m%dT%H%M%SZ')-${failure_unit_name}.log")
mkdir -p "$failure_log_dir"
chmod 750 "$failure_log_dir"

message=$(cat <<EOF
$title_prefix failure on $host_name

Failed unit: $unit_name
When: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
Durable run log: ${durable_log_path:-not mapped}
Failure record: $failure_log_path

Recent logs:
$journal_output

Recent durable run log:
$durable_output
EOF
)

printf '%s\n' "$message" > "$failure_log_path"
chmod 640 "$failure_log_path"

mapfile -t stale_failure_logs < <(
    find "$failure_log_dir" -maxdepth 1 -type f -name '*.log' -printf '%T@\t%p\n' \
        | sort -nr \
        | tail -n "+$((failure_log_keep_files + 1))" \
        | cut -f 2-
)
if [ ${#stale_failure_logs[@]} -gt 0 ]; then
    rm -f "${stale_failure_logs[@]}"
fi

curl \
    -fsS \
    -H "Title: $title_prefix failure on $host_name" \
    -H "Priority: $priority" \
    -H "Tags: warning,backup" \
    -d "$message" \
    "$topic_url"

echo "Failure notification sent for unit: $unit_name"
echo "Failure record retained at: $failure_log_path"
