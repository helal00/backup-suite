#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

parse_standard_runtime_args "$@"
setup_journal_logging "backup-file"
load_global_config
acquire_backup_lock "backup-suite" "backup-suite"

require_rclone_bin
require_file "$RCLONE_CONFIG_PATH"
require_file "$FILE_SOURCE_CONFIG_PATH"

run_started_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
run_outcome="success"
synced_count=0
skipped_count=0
failed_count=0
failed_entries=()
cleanup_failed=0
archive_timestamp=$(date -u '+%Y-%m-%d_%H-%M-%S')
remote_base=$(remote_base_root)
file_extra_args=()
temp_runtime_files=()
file_heartbeat_interval_seconds="${FILE_HEARTBEAT_INTERVAL_SECONDS:-60}"

if [ -n "${FILE_RCLONE_EXTRA_FLAGS:-}" ]; then
    read -r -a file_extra_args <<< "$FILE_RCLONE_EXTRA_FLAGS"
fi

file_progress_args=()
if is_enabled_value "${BACKUP_SUITE_RCLONE_VERBOSE:-0}"; then
    file_progress_args=(--stats 10s --stats-one-line --stats-log-level NOTICE)
elif [ "${BACKUP_SUITE_LOG_MODE:-journal}" = "journal" ]; then
    file_progress_args=(--stats 1m --stats-one-line --stats-log-level NOTICE)
fi

build_project_exclude_file() {
    local source_path="$1"
    local exclude_filename="$2"
    local temp_filter_file=""
    local exclude_definition_file
    local definition_dir
    local relative_dir
    local pattern
    local normalized_pattern
    local final_pattern

    [ -n "$exclude_filename" ] || return 0

    while IFS= read -r exclude_definition_file; do
        if [ -z "$temp_filter_file" ]; then
            temp_filter_file=$(mktemp)
            temp_runtime_files+=("$temp_filter_file")
        fi

        definition_dir=$(dirname "$exclude_definition_file")
        relative_dir="${definition_dir#$source_path}"
        relative_dir="${relative_dir#/}"

        while IFS= read -r pattern || [ -n "$pattern" ]; do
            pattern=$(trim "$pattern")
            [ -n "$pattern" ] || continue
            [[ "$pattern" == \#* ]] && continue

            normalized_pattern="${pattern#/}"
            if [ -n "$relative_dir" ]; then
                final_pattern=$(join_path "$relative_dir" "$normalized_pattern")
            else
                final_pattern="$normalized_pattern"
            fi

            printf '%s\n' "$final_pattern" >> "$temp_filter_file"
        done < "$exclude_definition_file"
    done < <(find "$source_path" -type f -name "$exclude_filename" | sort)

    if [ -n "$temp_filter_file" ] && [ -s "$temp_filter_file" ]; then
        printf '%s' "$temp_filter_file"
    elif [ -n "$temp_filter_file" ]; then
        rm -f "$temp_filter_file"
    fi
}

list_rclone_files_sorted() {
    local target_path="$1"
    local output_file="$2"
    local follow_links="$3"
    shift 3
    local listing_args=(
        lsf "$target_path"
        --config "$RCLONE_CONFIG_PATH"
        --recursive
        --files-only
        --format p
    )

    if [ "$follow_links" = "1" ]; then
        listing_args+=( -L )
    fi

    listing_args+=("$@")

    "$RCLONE_BIN" "${listing_args[@]}" | sort -u > "$output_file"
}

archive_deleted_remote_files() {
    local source_path="$1"
    local destination_path="$2"
    local archive_path="$3"
    shift 3
    local filter_args=("$@")
    local source_list_file
    local destination_list_file
    local deleted_list_file

    source_list_file=$(mktemp)
    destination_list_file=$(mktemp)
    deleted_list_file=$(mktemp)
    temp_runtime_files+=("$source_list_file" "$destination_list_file" "$deleted_list_file")

    "$RCLONE_BIN" mkdir "$destination_path" \
        --config "$RCLONE_CONFIG_PATH" \
        "${file_extra_args[@]}" >/dev/null

    run_with_heartbeat "$file_heartbeat_interval_seconds" \
        "Still enumerating source files for '$source_path'" \
        list_rclone_files_sorted "$source_path" "$source_list_file" 1 "${filter_args[@]}"

    run_with_heartbeat "$file_heartbeat_interval_seconds" \
        "Still enumerating remote files for '$destination_path'" \
        list_rclone_files_sorted "$destination_path" "$destination_list_file" 0 "${filter_args[@]}"

    comm -13 "$source_list_file" "$destination_list_file" > "$deleted_list_file"

    if [ -s "$deleted_list_file" ]; then
        echo "Archiving destination-only deleted files into '$archive_path'"
        if ! "$RCLONE_BIN" move "$destination_path" "$archive_path" \
            --config "$RCLONE_CONFIG_PATH" \
            --files-from "$deleted_list_file" \
            "${file_progress_args[@]}" \
            "${file_extra_args[@]}"; then
            return 1
        fi

        "$RCLONE_BIN" rmdirs "$destination_path" \
            --config "$RCLONE_CONFIG_PATH" \
            --leave-root \
            --quiet \
            "${file_extra_args[@]}" || true
    fi
}

finish() {
    local exit_code=$?
    local run_finished_at

    run_finished_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    echo "Run summary: outcome=${run_outcome} synced=${synced_count} skipped=${skipped_count} failed=${failed_count} cleanup_failed=${cleanup_failed}"
    if [ ${#failed_entries[@]} -gt 0 ]; then
        echo "Failed file sources: ${failed_entries[*]}"
    fi
    if [ ${#temp_runtime_files[@]} -gt 0 ]; then
        rm -f "${temp_runtime_files[@]}"
    fi
    if [ "$exit_code" -eq 0 ]; then
        echo "File backup finished at ${run_finished_at} with status: success"
    else
        echo "File backup finished at ${run_finished_at} with status: failure (exit code ${exit_code})"
    fi
}

trap finish EXIT

echo "File backup started at ${run_started_at}"
echo "Using source config: $FILE_SOURCE_CONFIG_PATH"
echo "Remote base: $remote_base"

if is_enabled_value "${FILE_PROCESS_CHECK_ENABLED:-1}"; then
    normalized_patterns=$(printf '%s' "${FILE_PROCESS_CHECK_PATTERNS:-vscode-server}" | sed 's/,/|/g')
    IFS='|' read -r -a process_patterns <<< "$normalized_patterns"
    for process_pattern in "${process_patterns[@]}"; do
        process_pattern=$(trim "$process_pattern")
        [ -n "$process_pattern" ] || continue

        if is_enabled_value "${FILE_PROCESS_CHECK_USER_ONLY:-1}"; then
            if pgrep -u "$(id -u)" -f "$process_pattern" > /dev/null; then
                run_outcome="skipped-process-active"
                echo "Configured process pattern '$process_pattern' is active for user $(id -un). Skipping file backup."
                echo "Next attempt will be triggered by the configured timer schedule."
                exit 0
            fi
        elif pgrep -f "$process_pattern" > /dev/null; then
            run_outcome="skipped-process-active"
            echo "Configured process pattern '$process_pattern' is active. Skipping file backup."
            echo "Next attempt will be triggered by the configured timer schedule."
            exit 0
        fi
    done
fi

while IFS='|' read -r enabled label source_path destination_mode destination_value sync_stop_file; do
    enabled=$(trim "$enabled")
    label=$(trim "$label")
    source_path=$(trim "$source_path")
    destination_mode=$(trim "$destination_mode")
    destination_value=$(trim "$destination_value")
    sync_stop_file=$(trim "$sync_stop_file")

    [ -z "$enabled" ] && continue
    [[ "$enabled" == \#* ]] && continue
    is_enabled_value "$enabled" || continue

    [ -n "$source_path" ] || {
        skipped_count=$((skipped_count + 1))
        echo "Skipping source with empty path for label '$label'"
        continue
    }

    [ -d "$source_path" ] || {
        failed_count=$((failed_count + 1))
        failed_entries+=("${label:-$source_path}:missing-source")
        echo "Source path is missing or not a directory: $source_path"
        continue
    }

    if [ ! -r "$source_path" ] || [ ! -x "$source_path" ]; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${label:-$source_path}:unreadable-source")
        echo "Source path is not readable by user $(id -un): $source_path"
        continue
    fi

    if [ -z "$sync_stop_file" ]; then
        sync_stop_file="${FILE_SYNC_STOP_FILE:-.nosync}"
    fi

    if [ -n "$sync_stop_file" ] && [ -f "$source_path/$sync_stop_file" ]; then
        skipped_count=$((skipped_count + 1))
        echo "Skipping source '$source_path' because $sync_stop_file is present"
        continue
    fi

    case "$destination_mode" in
        same-name)
            destination_relative=$(basename "$source_path")
            ;;
        fixed)
            [ -n "$destination_value" ] || fail "destination_value is required for fixed mapping: $source_path"
            destination_relative=$(strip_slashes "$destination_value")
            ;;
        default-root|"")
            default_key="$destination_value"
            [ -n "$default_key" ] || default_key="${label:-$(basename "$source_path")}" 
            destination_relative=$(join_path "${FILE_DEFAULT_DESTINATION_ROOT:-files}" "$default_key")
            ;;
        *)
            failed_count=$((failed_count + 1))
            failed_entries+=("${label:-$source_path}:invalid-destination-mode")
            echo "Invalid destination mode '$destination_mode' for source '$source_path'"
            continue
            ;;
    esac

    destination_path=$(join_path "$remote_base" "$destination_relative")
    archive_path=$(join_path "$remote_base" "${FILE_ARCHIVE_FOLDER_NAME:-deleted_files}" "$archive_timestamp" "$destination_relative")
    source_filter_args=()
    source_sync_args=("${file_extra_args[@]}" "${file_progress_args[@]}")

    exclude_filter_file=$(build_project_exclude_file "$source_path" "${FILE_PROJECT_EXCLUDE_FILENAME:-.backup-excludes}")
    if [ -n "$exclude_filter_file" ]; then
        source_filter_args+=(--exclude-from "$exclude_filter_file")
        source_sync_args+=(--exclude-from "$exclude_filter_file")
        echo "Using project exclude definitions named '${FILE_PROJECT_EXCLUDE_FILENAME:-.backup-excludes}' under '$source_path'"
    fi

    echo "Syncing label='${label:-$source_path}' source='$source_path' destination='$destination_path'"

    if ! archive_deleted_remote_files "$source_path" "$destination_path" "$archive_path" "${source_filter_args[@]}"; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${label:-$source_path}:archive-deleted-files")
        echo "Failed to archive deleted files for '$source_path'"
        continue
    fi

    if "$RCLONE_BIN" sync "$source_path" "$destination_path" \
        --config "$RCLONE_CONFIG_PATH" \
        --create-empty-src-dirs \
        -L \
        --transfers "${FILE_RCLONE_TRANSFERS:-12}" \
        --checkers "${FILE_RCLONE_CHECKERS:-24}" \
        --buffer-size "${FILE_RCLONE_BUFFER_SIZE:-128M}" \
        --tpslimit "${FILE_RCLONE_TPSLIMIT:-10}" \
        "${source_sync_args[@]}"; then
        synced_count=$((synced_count + 1))
        echo "File sync completed for '$source_path'"
    else
        failed_count=$((failed_count + 1))
        failed_entries+=("${label:-$source_path}")
        echo "File sync failed for '$source_path'"
    fi
done < "$FILE_SOURCE_CONFIG_PATH"

echo "Cleaning archived file versions older than ${FILE_RETENTION_DAYS:-21d} from ${FILE_ARCHIVE_FOLDER_NAME:-deleted_files}"
if "$RCLONE_BIN" delete "$(join_path "$remote_base" "${FILE_ARCHIVE_FOLDER_NAME:-deleted_files}")" \
    --config "$RCLONE_CONFIG_PATH" \
    --min-age "${FILE_RETENTION_DAYS:-21d}" \
    --rmdirs \
    --quiet; then
    echo "Archived file cleanup completed successfully."
else
    cleanup_failed=1
    echo "Archived file cleanup failed."
fi

if [ "$failed_count" -gt 0 ] || [ "$cleanup_failed" -ne 0 ]; then
    run_outcome="completed-with-errors"
    exit 1
fi

run_outcome="completed-successfully"
echo "File backup completed successfully."
