#!/bin/bash

set -euo pipefail

scenario="${FAKE_RCLONE_SCENARIO:?FAKE_RCLONE_SCENARIO is required}"
state_dir="${FAKE_RCLONE_STATE:?FAKE_RCLONE_STATE is required}"
command_log="$state_dir/commands.log"
mkdir -p "$state_dir"

printf '%q ' "$@" >> "$command_log"
printf '\n' >> "$command_log"

command_name="${1:-}"
shift || true

increment_counter() {
    local counter_file="$1"
    local value=0
    if [ -f "$counter_file" ]; then
        value=$(<"$counter_file")
    fi
    value=$((value + 1))
    printf '%s\n' "$value" > "$counter_file"
    printf '%s' "$value"
}

any_exclude_file_contains() {
    local expected="$1"
    shift
    while [ "$#" -gt 0 ]; do
        if [ "$1" = "--exclude-from" ] && [ "$#" -gt 1 ] && grep -Fxq "$expected" "$2"; then
            return 0
        fi
        shift
    done
    return 1
}

case "$command_name" in
    lsf)
        if printf '%s\n' "$*" | grep -q -- '--format pst'; then
            if [ "$scenario" = "changing" ]; then
                snapshot_number=$(increment_counter "$state_dir/snapshot-count")
                if [ "$snapshot_number" -eq 1 ]; then
                    printf 'volatile.log|1|2026-01-01T00:00:00Z\n'
                else
                    printf 'volatile.log|2|2026-01-01T00:00:01Z\n'
                fi
            else
                printf 'stable.txt|1|2026-01-01T00:00:00Z\n'
            fi
        fi
        ;;
    sync)
        sync_number=$(increment_counter "$state_dir/sync-count")
        case "$scenario" in
            changing)
                if [ "$sync_number" -le 2 ]; then
                    echo "simulated changing-file failure" >&2
                    exit 1
                fi
                any_exclude_file_contains 'volatile.log' "$@"
                ;;
            isolation)
                source_path="${1:-}"
                if [ "$(basename "$source_path")" = "bad" ]; then
                    echo "simulated isolated project failure" >&2
                    exit 1
                fi
                ;;
            overlap)
                sleep 2
                ;;
        esac
        ;;
    delete)
        ;;
    *)
        echo "unexpected fake rclone command: $command_name" >&2
        exit 1
        ;;
esac
