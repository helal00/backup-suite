#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/notify-lib.sh"

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
    unit_result=$(systemctl --user show "$unit_name" -p Result --value 2>/dev/null || true)
    unit_exit_status=$(systemctl --user show "$unit_name" -p ExecMainStatus --value 2>/dev/null || true)
else
    journal_output=$(journalctl -u "$unit_name" -n "$journal_lines" --no-pager 2>&1 || true)
    unit_result=$(systemctl show "$unit_name" -p Result --value 2>/dev/null || true)
    unit_exit_status=$(systemctl show "$unit_name" -p ExecMainStatus --value 2>/dev/null || true)
fi
unit_result="${unit_result:-unknown}"
unit_exit_status="${unit_exit_status:-unknown}"

case "$unit_name" in
    file-backup.service)
        durable_identifier="backup-file"
        run_start_marker="File backup started at"
        ;;
    database-backup.service)
        durable_identifier="backup-db"
        run_start_marker=""
        ;;
    database-size-check.service)
        durable_identifier="backup-db-monitor"
        run_start_marker=""
        ;;
    backup-suite-watchdog@*)
        durable_identifier=""
        run_start_marker=""
        ;;
    *)
        durable_identifier=""
        run_start_marker=""
        ;;
esac

durable_log_path=""
durable_output="No mapped durable log for this unit."
latest_run_output=""
if [ -n "$durable_identifier" ]; then
    durable_log_path=$(join_path "$STATE_DIR" "logs" "${durable_identifier}.log")
    if [ -f "$durable_log_path" ]; then
        durable_output=$(tail -n "$durable_log_lines" "$durable_log_path" 2>&1 || true)
        if [ -n "$run_start_marker" ]; then
            # Only the newest run matters for the explanation.
            latest_run_output=$(tail -n 5000 "$durable_log_path" 2>/dev/null | awk -v marker="$run_start_marker" '
                index($0, marker) { buffer = "" }
                { buffer = buffer $0 "\n" }
                END { printf "%s", buffer }
            ')
        else
            latest_run_output="$durable_output"
        fi
    else
        durable_output="Durable log not found yet: $durable_log_path"
    fi
fi
analysis_text="$latest_run_output"$'\n'"$journal_output"

causes=()
actions=()

add_explanation() {
    causes+=("$1")
    actions+=("$2")
}

log_matches() {
    grep -Eiq -- "$1" <<< "$analysis_text"
}

case "$unit_result" in
    oom-kill)
        add_explanation \
            "The kernel killed the backup because it reached its memory limit (MemoryMax)." \
            "Choose a lower profile with 'backup-profile.sh set slow', or exclude very large trees. The watchdog normally stops the backup before this happens; check its earlier ntfy messages."
        ;;
    timeout)
        add_explanation \
            "The run exceeded its maximum runtime (FILE_BACKUP_RUNTIME_MAX_SEC) and systemd stopped it." \
            "Large or slow projects may need a faster profile or a longer runtime limit. Finished projects are already backed up; the rest continue next run."
        ;;
    signal|core-dump)
        add_explanation \
            "A backup process was killed by a signal (result: $unit_result)." \
            "Check whether an administrator, the watchdog, or a server shutdown stopped it."
        ;;
esac

watchdog_action_file=$(join_path "$STATE_DIR" "watchdog" "${unit_name//[^A-Za-z0-9._-]/_}.last-action")
watchdog_already_notified=0
if [ -f "$watchdog_action_file" ] && [ -n "$(find "$watchdog_action_file" -mmin -15 -print 2>/dev/null)" ]; then
    grep -qx 'notified=1' "$watchdog_action_file" && watchdog_already_notified=1
    add_explanation \
        "The resource watchdog stopped this backup: $(sed -n 's/^reason=//p' "$watchdog_action_file" | head -n 1)" \
        "See the watchdog's ntfy message for the measured values. Consider 'backup-profile.sh set slow' if this repeats."
fi

if log_matches 'source file is being updated|changed size|changed modification time|skipped changed path|deferred active path'; then
    add_explanation \
        "Files were being written while they were copied, so rclone refused to upload an inconsistent copy." \
        "Usually nothing to do: those files keep their previous remote version and are retried next run. If the same file appears every time, add it to .backup-volatile or .backup-excludes."
fi
if log_matches 'ratelimitexceeded|userratelimitexceeded|rate limit exceeded|error 429|too many requests'; then
    add_explanation \
        "Google Drive's API rate limit was exceeded." \
        "Usually temporary. If it repeats, use a lower profile (fewer API calls per second)."
fi
if log_matches 'storagequotaexceeded|quota.*exceeded|insufficient storage'; then
    add_explanation \
        "The Google Drive account is out of storage space." \
        "Free space in Google Drive, or lower FILE_RETENTION_DAYS so old archived versions are removed sooner."
fi
if log_matches 'invalid_grant|token expired|oauth2: cannot fetch token|couldn.t fetch token|error 401|unauthorized'; then
    add_explanation \
        "rclone's Google Drive login is no longer valid (expired or revoked token)." \
        "Reconnect the remote: sudo rclone config reconnect <remote>: --config /etc/backup-suite/rclone.conf"
fi
if log_matches 'no such host|dial tcp|connection refused|connection reset|i/o timeout|tls handshake timeout|network is unreachable|context deadline exceeded'; then
    add_explanation \
        "The server could not reach Google Drive (network or DNS problem)." \
        "Check the server's internet connection and DNS. The next scheduled run retries automatically."
fi
if log_matches 'no space left on device|not enough space'; then
    add_explanation \
        "A local disk ran out of space." \
        "Free disk space on the server (df -h), especially /tmp and /var."
fi
if log_matches 'permission denied|not readable by user'; then
    add_explanation \
        "A file or folder could not be read because of its permissions." \
        "Check the paths named in the attached log and their owner/permissions."
fi
if log_matches 'source path is missing|missing-source|no child project directories'; then
    add_explanation \
        "A configured backup source folder no longer exists." \
        "Update file-sources.conf, or restore the missing folder."
fi
if log_matches 'migration confirmation required'; then
    add_explanation \
        "A project needs its one-time symlink (--links) migration confirmed before it can be backed up." \
        "Review the migration report and run the production migration with --only-project for that project."
fi
if log_matches 'cannot allocate memory|resource temporarily unavailable'; then
    add_explanation \
        "The backup hit its memory or process limit." \
        "Choose a different profile ('backup-profile.sh show' lists the limits)."
fi
if [ "${#causes[@]}" -eq 0 ]; then
    add_explanation \
        "No known error pattern matched (unit result: $unit_result, exit status: $unit_exit_status)." \
        "Read the key errors below and the attached log."
fi

failed_projects=$(grep -E '^Failed file sources: ' <<< "$latest_run_output" | tail -n 1 | sed 's/^Failed file sources: //' || true)
run_summary=$(grep -E '^Run summary: ' <<< "$latest_run_output" | tail -n 1 | sed 's/^Run summary: //' || true)
key_errors=$(grep -E 'ERROR|error|failed|Failed' <<< "$analysis_text" \
    | grep -Ev '^Run summary: |^Failed file sources: ' \
    | cut -c 1-300 \
    | tail -n "${NOTIFY_KEY_ERROR_LINES:-8}" || true)

failure_log_dir=$(join_path "$STATE_DIR" "failures")
failure_unit_name="${unit_name//[^[:alnum:]._-]/_}"
failure_timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
failure_log_path=$(join_path "$failure_log_dir" "${failure_timestamp}-${failure_unit_name}.log")
mkdir -p "$failure_log_dir"
chmod 750 "$failure_log_dir"

explanation_text=""
for index in "${!causes[@]}"; do
    explanation_text+="- ${causes[$index]}"$'\n'"  Fix: ${actions[$index]}"$'\n'
done

summary_message=$(cat <<EOF
$unit_name failed on $host_name

What happened (most likely):
${explanation_text}
Safety: previous remote versions are kept. A failed project never deletes remote files, and old-version cleanup is skipped after any failure.

Failed projects: ${failed_projects:-not reported}
Last run summary: ${run_summary:-not available}
Unit result: $unit_result (exit status $unit_exit_status) at $(date -u '+%Y-%m-%d %H:%M:%S UTC')

Key errors:
${key_errors:-none captured}

Full log attached. Local copy: $failure_log_path
EOF
)

{
    printf '%s\n\n' "$summary_message"
    echo "Failed unit: $unit_name"
    echo "When: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "Durable run log: ${durable_log_path:-not mapped}"
    echo "Failure record: $failure_log_path"
    echo ""
    echo "Recent logs:"
    printf '%s\n' "$journal_output"
    echo ""
    echo "Recent durable run log:"
    printf '%s\n' "$durable_output"
} > "$failure_log_path"
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

BACKUP_EVENT_UNIT="$unit_name"
if [ "$watchdog_already_notified" -eq 1 ]; then
    # The watchdog stopped this run and already pushed one message explaining
    # why; a second "failed" push for the same stop would only repeat it.
    record_backup_event error run-failed "$title_prefix failure on $host_name: $unit_name" "$summary_message" "$unit_name" held
    echo "Failure recorded without a push: the resource watchdog already notified about this stop."
    echo "Failure record retained at: $failure_log_path"
    exit 0
fi
ntfy_publish "$title_prefix failure on $host_name: $unit_name" "$priority" "warning,backup" \
    "$summary_message" "$failure_log_path" "${failure_timestamp}-${failure_unit_name}.log" run-failed \
    || fail "Failure notification could not be delivered for unit: $unit_name"

echo "Failure notification sent for unit: $unit_name"
echo "Failure record retained at: $failure_log_path"
