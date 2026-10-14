#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/notify-lib.sh"

BACKUP_SUITE_RUNTIME_SCOPE="file-backup"
parse_standard_runtime_args "$@"
setup_journal_logging "backup-file"
load_global_config
resolve_profile_ladder
resolve_file_backup_profile "$(current_adaptive_profile)"
setup_durable_logging "backup-file"
acquire_backup_lock "file-backup" "Backup Suite file backup"

require_rclone_bin
require_file "$RCLONE_CONFIG_PATH"
require_file "$FILE_SOURCE_CONFIG_PATH"
require_command sha256sum
if [ -n "${BACKUP_SUITE_PROJECT_FILTER_FILE:-}" ]; then
    require_file "$BACKUP_SUITE_PROJECT_FILTER_FILE"
fi

run_started_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
archive_timestamp=$(date -u '+%Y-%m-%d_%H-%M-%S')
remote_base=$(remote_base_root)
run_outcome="success"
synced_count=0
skipped_count=0
skipped_changed_count=0
deferred_active_count=0
stale_deferral_entries=()
failed_count=0
migration_required_count=0
migration_report_count=0
cleanup_failed=0
failed_entries=()
temp_runtime_files=()
file_extra_args=()
file_progress_args=()
file_heartbeat_interval_seconds="${FILE_HEARTBEAT_INTERVAL_SECONDS:-60}"
file_stability_interval_seconds="${FILE_STABILITY_INTERVAL_SECONDS:-10}"
file_changed_detail_limit="${FILE_CHANGED_DETAIL_LIMIT:-20}"
file_active_tracking_enabled="${FILE_ACTIVE_TRACKING_ENABLED:-1}"
file_active_window_seconds="${FILE_ACTIVE_WINDOW_SECONDS:-120}"
file_active_max_deferrals="${FILE_ACTIVE_MAX_DEFERRALS:-12}"
file_rclone_tuning_args=()
active_profile_name=""
run_progress_file=$(join_path "$STATE_DIR" "run" "progress.env")
projects_total=0
project_index=0
current_project_label=""

write_run_progress() {
    # One small key=value file for the GUI: where the run is and its counts.
    local run_state="$1"
    local progress_dir
    local temp_file

    progress_dir=$(dirname "$run_progress_file")
    mkdir -p "$progress_dir" 2>/dev/null || return 0
    temp_file="$run_progress_file.tmp.$$"
    {
        printf 'state=%s\n' "$run_state"
        printf 'outcome=%s\n' "${run_outcome:-}"
        printf 'started_at=%s\n' "$run_started_at"
        printf 'updated_at=%s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        printf 'pid=%s\n' "$$"
        printf 'projects_total=%s\n' "$projects_total"
        printf 'project_index=%s\n' "$project_index"
        printf 'current_project=%s\n' "${current_project_label//$'\n'/ }"
        printf 'profile=%s\n' "${PROFILE_NAME:-}"
        printf 'synced=%s\nskipped=%s\nskipped_changed=%s\ndeferred_active=%s\nfailed=%s\n' \
            "$synced_count" "$skipped_count" "$skipped_changed_count" "$deferred_active_count" "$failed_count"
    } > "$temp_file" 2>/dev/null && mv -f "$temp_file" "$run_progress_file" 2>/dev/null
    rm -f "$temp_file" 2>/dev/null
    return 0
}

count_planned_projects() {
    # Counts the projects this run will visit, the same way the main loop does.
    local enabled label source_path destination_mode destination_value sync_stop_file isolation_mode unexpected_fields
    local count=0
    local child_count

    [ -r "$FILE_SOURCE_CONFIG_PATH" ] || { printf '0'; return 0; }
    while IFS='|' read -r enabled label source_path destination_mode destination_value sync_stop_file isolation_mode unexpected_fields; do
        enabled=$(trim "$enabled")
        source_path=$(trim "$source_path")
        isolation_mode=$(trim "${isolation_mode:-single}")
        [ -n "$enabled" ] || continue
        [[ "$enabled" == \#* ]] && continue
        is_enabled_value "$enabled" || continue
        [ -d "$source_path" ] || continue
        if [ "$isolation_mode" = "children" ]; then
            child_count=$(find "$source_path" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
            count=$((count + child_count))
        else
            count=$((count + 1))
        fi
    done < "$FILE_SOURCE_CONFIG_PATH"
    printf '%s' "$count"
}

select_project_profile() {
    # In adaptive mode the watchdog may step the profile down or up while the
    # run is in progress; each project starts rclone with the current level.
    local wanted_profile

    wanted_profile=$(current_adaptive_profile)
    [ "$wanted_profile" = "$active_profile_name" ] && return 0
    resolve_file_backup_profile "$wanted_profile"
    file_rclone_tuning_args=(
        --transfers "$PROFILE_RCLONE_TRANSFERS"
        --checkers "$PROFILE_RCLONE_CHECKERS"
        --buffer-size "$PROFILE_RCLONE_BUFFER_SIZE"
        --tpslimit "$PROFILE_RCLONE_TPSLIMIT"
    )
    if [ -n "$PROFILE_RCLONE_BWLIMIT" ]; then
        file_rclone_tuning_args+=(--bwlimit "$PROFILE_RCLONE_BWLIMIT")
    fi
    if [ -n "$active_profile_name" ]; then
        echo "Resource profile changed by the watchdog: ${active_profile_name} -> ${PROFILE_NAME}; rclone uses ${PROFILE_RCLONE_TRANSFERS} transfers from the next project."
    else
        echo "Resource profile: ${PROFILE_NAME} (mode ${PROFILE_MODE}; levels $(IFS='>'; printf '%s' "${PROFILE_LADDER[*]}"))"
    fi
    active_profile_name="$PROFILE_NAME"
}

[[ "$file_active_window_seconds" =~ ^[0-9]+$ ]] || fail "FILE_ACTIVE_WINDOW_SECONDS must be a non-negative integer"
[[ "$file_active_max_deferrals" =~ ^[0-9]+$ ]] && [ "$file_active_max_deferrals" -gt 0 ] || fail "FILE_ACTIVE_MAX_DEFERRALS must be a positive integer"

if [ -n "${FILE_RCLONE_EXTRA_FLAGS:-}" ]; then
    read -r -a file_extra_args <<< "$FILE_RCLONE_EXTRA_FLAGS"
fi

if is_enabled_value "${BACKUP_SUITE_RCLONE_VERBOSE:-0}"; then
    file_progress_args=(--stats 10s --stats-one-line --stats-log-level NOTICE)
elif [ "${BACKUP_SUITE_LOG_MODE:-journal}" = "journal" ]; then
    file_progress_args=(--stats 1m --stats-one-line --stats-log-level NOTICE)
fi

finish() {
    local exit_code=$?
    local run_finished_at

    run_finished_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    echo "Run summary: outcome=${run_outcome} profile=${PROFILE_NAME} synced=${synced_count} skipped=${skipped_count} skipped_changed=${skipped_changed_count} deferred_active=${deferred_active_count} failed=${failed_count} migration_required=${migration_required_count} migration_reports=${migration_report_count} cleanup_failed=${cleanup_failed}"
    if [ ${#failed_entries[@]} -gt 0 ]; then
        echo "Failed file sources: ${failed_entries[*]}"
    fi
    if [ ${#temp_runtime_files[@]} -gt 0 ]; then
        rm -f "${temp_runtime_files[@]}"
    fi
    current_project_label=""
    write_run_progress finished
    if [ "$exit_code" -eq 0 ]; then
        echo "File backup finished at ${run_finished_at} with status: ${run_outcome}"
        record_backup_event info run-finished "File backup finished: ${run_outcome}" \
            "Synced ${synced_count}, skipped ${skipped_count}, deferred while changing $((skipped_changed_count + deferred_active_count)), failed ${failed_count}. Profile ${PROFILE_NAME:-unknown}. Started ${run_started_at}, finished ${run_finished_at}." \
            file-backup.service
    else
        echo "File backup finished at ${run_finished_at} with status: failure (exit code ${exit_code}, outcome ${run_outcome})"
    fi
}

trap finish EXIT

build_project_pattern_file() {
    local source_path="$1"
    local definition_filename="$2"
    local temp_filter_file=""
    local definition_file
    local definition_dir
    local relative_dir
    local pattern
    local normalized_pattern
    local final_pattern
    local global_patterns=""

    [ -n "$definition_filename" ] || return 0

    if [ "$definition_filename" = "${FILE_PROJECT_EXCLUDE_FILENAME:-.backup-excludes}" ]; then
        global_patterns="${FILE_GLOBAL_EXCLUDE_PATTERNS:-}"
    elif [ "$definition_filename" = "${FILE_VOLATILE_FILENAME:-.backup-volatile}" ]; then
        global_patterns="${FILE_GLOBAL_VOLATILE_PATTERNS:-}"
    fi

    if [ -n "$global_patterns" ]; then
        temp_filter_file=$(mktemp)
        temp_runtime_files+=("$temp_filter_file")
        while IFS= read -r pattern || [ -n "$pattern" ]; do
            pattern=$(trim "$pattern")
            [ -n "$pattern" ] || continue
            [[ "$pattern" == \#* ]] && continue
            printf '%s\n' "${pattern#/}" >> "$temp_filter_file"
        done < <(printf '%s\n' "$global_patterns" | tr '|' '\n')
    fi

    while IFS= read -r definition_file; do
        if [ -z "$temp_filter_file" ]; then
            temp_filter_file=$(mktemp)
            temp_runtime_files+=("$temp_filter_file")
        fi

        definition_dir=$(dirname "$definition_file")
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
        done < "$definition_file"
    done < <(find "$source_path" -type f -name "$definition_filename" -print | sort)

    if [ -n "$temp_filter_file" ] && [ -s "$temp_filter_file" ]; then
        printf '%s' "$temp_filter_file"
    elif [ -n "$temp_filter_file" ]; then
        rm -f "$temp_filter_file"
    fi
}

list_rclone_files_sorted() {
    local target_path="$1"
    local output_file="$2"
    shift 2

    "$RCLONE_BIN" lsf "$target_path" \
        --config "$RCLONE_CONFIG_PATH" \
        --recursive \
        --files-only \
        --format p \
        --links \
        "$@" | sort -u > "$output_file"
}

list_destination_files_sorted() {
    local target_path="$1"
    local output_file="$2"
    shift 2
    local error_file

    error_file=$(mktemp)
    temp_runtime_files+=("$error_file")
    if list_rclone_files_sorted "$target_path" "$output_file" "$@" 2> "$error_file"; then
        return 0
    fi

    if grep -Eqi 'directory not found|path not found|object not found' "$error_file"; then
        : > "$output_file"
        return 0
    fi

    cat "$error_file" >&2
    return 1
}

snapshot_source_files() {
    local source_path="$1"
    local output_file="$2"
    shift 2

    "$RCLONE_BIN" lsf "$source_path" \
        --config "$RCLONE_CONFIG_PATH" \
        --recursive \
        --files-only \
        --format pst \
        --separator '|' \
        --links \
        "$@" | sort -u > "$output_file"
}

path_matches_pattern_file() {
    local candidate_path="$1"
    local pattern_file="$2"
    local pattern

    while IFS= read -r pattern || [ -n "$pattern" ]; do
        pattern=$(trim "$pattern")
        [ -n "$pattern" ] || continue
        [[ "$pattern" == \#* ]] && continue
        pattern="${pattern#/}"
        if [[ "$candidate_path" == $pattern ]]; then
            return 0
        fi
    done < "$pattern_file"

    return 1
}

classify_changed_paths() {
    # Writes the source paths that changed between two snapshots. With active
    # tracking enabled every changed path is deferred; otherwise only paths that
    # match an explicit volatile classification are.
    local before_snapshot="$1"
    local after_snapshot="$2"
    local volatile_pattern_file="$3"
    local output_file="$4"
    local changed_lines_file
    local candidates_file
    local candidate_path
    local match_path

    changed_lines_file=$(mktemp)
    candidates_file=$(mktemp)
    temp_runtime_files+=("$changed_lines_file" "$candidates_file")

    comm -3 "$before_snapshot" "$after_snapshot" | sed $'s/^\t//' > "$changed_lines_file"
    cut -d '|' -f 1 "$changed_lines_file" | sort -u > "$candidates_file"

    : > "$output_file"
    if is_enabled_value "$file_active_tracking_enabled"; then
        cat "$candidates_file" > "$output_file"
        return 0
    fi
    [ -n "$volatile_pattern_file" ] || return 0
    while IFS= read -r candidate_path; do
        [ -n "$candidate_path" ] || continue
        match_path="${candidate_path%.rclonelink}"
        if path_matches_pattern_file "$match_path" "$volatile_pattern_file"; then
            printf '%s\n' "$candidate_path" >> "$output_file"
        fi
    done < "$candidates_file"
}

detect_active_files() {
    # Lists files modified within the active window. They are probably still
    # being written, so copying them now could upload a half-written file.
    local source_path="$1"
    local output_file="$2"
    shift 2

    "$RCLONE_BIN" lsf "$source_path" \
        --config "$RCLONE_CONFIG_PATH" \
        --recursive \
        --files-only \
        --format p \
        --links \
        --max-age "${file_active_window_seconds}s" \
        "$@" | LC_ALL=C sort -u > "$output_file"
}

write_path_filter_file() {
    # Converts source-relative paths into exact, root-anchored rclone filters so
    # a deferred path never matches a same-named file elsewhere in the tree.
    local raw_paths_file="$1"
    local filter_file="$2"

    sed -e 's/[][*?{}\\]/\\&/g' -e 's|^|/|' "$raw_paths_file" > "$filter_file"
}

log_bounded_paths() {
    local prefix="$1"
    local paths_file="$2"
    local total
    local shown=0
    local listed_path

    total=$(wc -l < "$paths_file")
    while IFS= read -r listed_path; do
        [ "$shown" -lt "$file_changed_detail_limit" ] || break
        echo "$prefix: $listed_path"
        shown=$((shown + 1))
    done < "$paths_file"
    if [ "$total" -gt "$file_changed_detail_limit" ]; then
        echo "$prefix detail truncated: shown=${file_changed_detail_limit} total=${total}"
    fi
}

record_project_deferrals() {
    # Tracks how many consecutive runs each path has been deferred. A path that
    # never settles would otherwise silently never reach the backup.
    local project_label="$1"
    local state_key="$2"
    local deferred_paths_file="$3"
    local state_dir
    local state_file
    local new_state
    local previous_state="/dev/null"
    local deferral_count
    local deferred_path

    state_dir=$(join_path "$STATE_DIR" "active-files")
    state_file=$(join_path "$state_dir" "${state_key}.tsv")
    mkdir -p "$state_dir"
    chmod 750 "$state_dir" 2>/dev/null || true

    if [ ! -s "$deferred_paths_file" ]; then
        rm -f "$state_file"
        return 0
    fi

    [ -f "$state_file" ] && previous_state="$state_file"
    new_state=$(mktemp)
    temp_runtime_files+=("$new_state")
    awk -F '\t' -v OFS='\t' '
        FILENAME == ARGV[1] { if (NF >= 2) previous[$2] = $1; next }
        $0 != "" { print previous[$0] + 1, $0 }
    ' "$previous_state" "$deferred_paths_file" > "$new_state"

    while IFS=$'\t' read -r deferral_count deferred_path; do
        if [ "$deferral_count" -ge "$file_active_max_deferrals" ] && [ $(( (deferral_count - file_active_max_deferrals) % file_active_max_deferrals )) -eq 0 ]; then
            echo "WARNING: '$deferred_path' in '$project_label' has changed during $deferral_count consecutive runs and has not been backed up in that time."
            stale_deferral_entries+=("$project_label: $deferred_path ($deferral_count runs)")
        fi
    done < "$new_state"

    cp "$new_state" "$state_file"
    chmod 640 "$state_file" 2>/dev/null || true
}

notify_stale_deferrals() {
    local message
    local entry
    local entry_lines=""

    [ "${#stale_deferral_entries[@]}" -gt 0 ] || return 0
    for entry in "${stale_deferral_entries[@]:0:20}"; do
        entry_lines+="- $entry"$'\n'
    done
    if [ "${#stale_deferral_entries[@]}" -gt 20 ]; then
        entry_lines+="- ... and $(( ${#stale_deferral_entries[@]} - 20 )) more (see the durable log)"$'\n'
    fi
    message=$(cat <<MSG
Some files have changed during every backup run for a long time, so the backup keeps skipping them and their remote copy is getting old:

${entry_lines}
Why: Backup Suite does not upload files that are being written (modified within the last ${file_active_window_seconds}s, or seen changing during the upload), because a half-written copy could be worse than the previous one. The previous remote version of each file is kept.

What to do: if a file is a log or cache, add it to .backup-excludes in that project. If it must be backed up, stop or pause its writer briefly, or list it in .backup-volatile so the decision is explicit.

Host: $(hostname) | Profile: $PROFILE_NAME
MSG
)
    ntfy_publish "${NOTIFY_NTFY_TITLE_PREFIX:-Backup Suite}: files repeatedly skipped while changing on $(hostname)" default "hourglass,backup" "$message" "" "" changing-files || true
}

migration_key_for_destination() {
    printf '%s' "$1" | sha256sum | cut -d ' ' -f 1
}

write_link_migration_report() {
    local source_path="$1"
    local destination_path="$2"
    local archive_path="$3"
    local report_file="$4"
    shift 4
    local filter_args=("$@")
    local source_list_file
    local destination_list_file
    local destination_only_file
    local source_link_count
    local destination_only_count
    local report_tmp

    source_list_file=$(mktemp)
    destination_list_file=$(mktemp)
    destination_only_file=$(mktemp)
    report_tmp=$(mktemp)
    temp_runtime_files+=("$source_list_file" "$destination_list_file" "$destination_only_file" "$report_tmp")

    list_rclone_files_sorted "$source_path" "$source_list_file" "${filter_args[@]}"
    list_destination_files_sorted "$destination_path" "$destination_list_file" "${filter_args[@]}"
    comm -13 "$source_list_file" "$destination_list_file" > "$destination_only_file"
    source_link_count=$(grep -Ec '\.rclonelink$' "$source_list_file" || true)
    destination_only_count=$(wc -l < "$destination_only_file")

    mkdir -p "$(dirname "$report_file")"
    {
        echo "Backup Suite --links migration report"
        echo "generated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "source=$source_path"
        echo "destination=$destination_path"
        echo "source_symlinks=$source_link_count"
        echo "destination_only_candidates=$destination_only_count"
        echo ""
        echo "Destination-only paths that rclone may archive during migration (bounded to 200):"
        sed -n '1,200p' "$destination_only_file"
        echo ""
        echo "rclone dry-run output:"
    } > "$report_tmp"

    if ! "$RCLONE_BIN" sync "$source_path" "$destination_path" \
        --config "$RCLONE_CONFIG_PATH" \
        --create-empty-src-dirs \
        --links \
        --dry-run \
        --backup-dir "$archive_path/migration-dry-run" \
        "${file_rclone_tuning_args[@]}" \
        "${filter_args[@]}" \
        "${file_extra_args[@]}" \
        "${file_progress_args[@]}" >> "$report_tmp" 2>&1; then
        echo "dry_run_status=failed" >> "$report_tmp"
        mv "$report_tmp" "$report_file"
        chmod 600 "$report_file"
        return 1
    fi

    echo "dry_run_status=success" >> "$report_tmp"
    mv "$report_tmp" "$report_file"
    chmod 600 "$report_file"
    migration_report_count=$((migration_report_count + 1))
    echo "Link migration dry-run report: $report_file"
}

preserve_confirmed_migration_candidates() {
    local source_path="$1"
    local destination_path="$2"
    local archive_path="$3"
    shift 3
    local filter_args=("$@")
    local source_list_file
    local destination_list_file
    local destination_only_file

    source_list_file=$(mktemp)
    destination_list_file=$(mktemp)
    destination_only_file=$(mktemp)
    temp_runtime_files+=("$source_list_file" "$destination_list_file" "$destination_only_file")

    list_rclone_files_sorted "$source_path" "$source_list_file" "${filter_args[@]}"
    list_destination_files_sorted "$destination_path" "$destination_list_file" "${filter_args[@]}"
    comm -13 "$source_list_file" "$destination_list_file" > "$destination_only_file"

    if [ ! -s "$destination_only_file" ]; then
        return 0
    fi

    echo "Preserving confirmed migration candidates under '$archive_path/migration-preserved'."
    if ! "$RCLONE_BIN" move "$destination_path" "$archive_path/migration-preserved" \
        --config "$RCLONE_CONFIG_PATH" \
        --files-from "$destination_only_file" \
        "${file_progress_args[@]}" \
        "${file_extra_args[@]}"; then
        return 1
    fi

    "$RCLONE_BIN" rmdirs "$destination_path" \
        --config "$RCLONE_CONFIG_PATH" \
        --leave-root \
        --quiet \
        "${file_extra_args[@]}"
}

run_sync_attempt() {
    local source_path="$1"
    local destination_path="$2"
    local attempt_archive_path="$3"
    local log_file="$4"
    local changed_skip_file="$5"
    shift 5
    local sync_args=("$@")

    if [ -n "$changed_skip_file" ] && [ -s "$changed_skip_file" ]; then
        sync_args+=(--exclude-from "$changed_skip_file")
    fi

    "$RCLONE_BIN" sync "$source_path" "$destination_path" \
        --config "$RCLONE_CONFIG_PATH" \
        --create-empty-src-dirs \
        --links \
        --backup-dir "$attempt_archive_path" \
        "${file_rclone_tuning_args[@]}" \
        --retries 1 \
        "${sync_args[@]}" 2>&1 | tee "$log_file"
}

mark_migration_complete() {
    local marker_file="$1"
    local source_path="$2"
    local destination_path="$3"

    mkdir -p "$(dirname "$marker_file")"
    {
        echo "confirmed_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "source=$source_path"
        echo "destination=$destination_path"
    } > "$marker_file"
    chmod 600 "$marker_file"
}

process_project() {
    local project_label="$1"
    local source_path="$2"
    local destination_relative="$3"

    project_index=$((project_index + 1))
    current_project_label="$project_label"
    write_run_progress running
    process_project_sync "$project_label" "$source_path" "$destination_relative"
}

process_project_sync() {
    local project_label="$1"
    local source_path="$2"
    local destination_relative="$3"
    local destination_path
    local archive_path
    local exclude_filter_file
    local volatile_pattern_file
    local migration_key
    local migration_report_file
    local migration_marker_file
    local destination_list_file
    local source_probe_list_file
    local attempt_one_log
    local attempt_two_log
    local attempt_three_log
    local before_snapshot
    local after_snapshot
    local retry_snapshot
    local changed_volatile_file
    local changed_count
    local active_paths_file
    local active_filter_file
    local active_count
    local deferred_paths_file
    local deferred_filter_file
    local migration_applies=0
    local source_filter_args=()
    local source_sync_args=("${file_extra_args[@]}" "${file_progress_args[@]}")

    if [ -n "${BACKUP_SUITE_PROJECT_FILTER_FILE:-}" ] && ! grep -Fxq "$project_label" "$BACKUP_SUITE_PROJECT_FILTER_FILE"; then
        skipped_count=$((skipped_count + 1))
        echo "Skipping '$project_label' because it is outside the explicit migration project filter."
        return 0
    fi

    if [ ! -d "$source_path" ]; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${project_label}:missing-source")
        echo "Source path is missing or not a directory: $source_path"
        return 1
    fi

    if [ ! -r "$source_path" ] || [ ! -x "$source_path" ]; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${project_label}:unreadable-source")
        echo "Source path is not readable by user $(id -un): $source_path"
        return 1
    fi

    select_project_profile
    destination_path=$(join_path "$remote_base" "$destination_relative")
    archive_path=$(join_path "$remote_base" "${FILE_ARCHIVE_FOLDER_NAME:-deleted_files}" "$archive_timestamp" "$destination_relative")
    migration_key=$(migration_key_for_destination "$destination_path")
    migration_report_file=$(join_path "$STATE_DIR" "migration-reports" "${migration_key}.txt")
    migration_marker_file=$(join_path "$STATE_DIR" "link-migrations" "${migration_key}.confirmed")

    if [ -f "$migration_marker_file" ] && { is_enabled_value "$BACKUP_SUITE_LINK_MIGRATION_REPORT" || is_enabled_value "$BACKUP_SUITE_CONFIRM_LINK_MIGRATION"; }; then
        skipped_count=$((skipped_count + 1))
        echo "Migration already confirmed for '$project_label'; skipping it in migration mode. Normal scheduled backups will continue to process it."
        return 0
    fi

    exclude_filter_file=$(build_project_pattern_file "$source_path" "${FILE_PROJECT_EXCLUDE_FILENAME:-.backup-excludes}")
    volatile_pattern_file=$(build_project_pattern_file "$source_path" "${FILE_VOLATILE_FILENAME:-.backup-volatile}")
    if [ -n "$exclude_filter_file" ]; then
        source_filter_args+=(--exclude-from "$exclude_filter_file")
        source_sync_args+=(--exclude-from "$exclude_filter_file")
        echo "Using exclude definitions named '${FILE_PROJECT_EXCLUDE_FILENAME:-.backup-excludes}' under '$source_path'"
    fi
    if [ -n "$volatile_pattern_file" ]; then
        echo "Using volatile classifications named '${FILE_VOLATILE_FILENAME:-.backup-volatile}' under '$source_path'"
    fi

    echo "Syncing label='$project_label' source='$source_path' destination='$destination_path'"

    if is_enabled_value "$BACKUP_SUITE_LINK_MIGRATION_REPORT"; then
        if write_link_migration_report "$source_path" "$destination_path" "$archive_path" "$migration_report_file" "${source_filter_args[@]}"; then
            echo "Dry-run only: no remote changes were made for '$project_label'."
        else
            failed_count=$((failed_count + 1))
            failed_entries+=("${project_label}:migration-report")
        fi
        return 0
    fi

    if [ ! -f "$migration_marker_file" ]; then
        source_probe_list_file=$(mktemp)
        temp_runtime_files+=("$source_probe_list_file")
        if ! list_rclone_files_sorted "$source_path" "$source_probe_list_file" "${source_filter_args[@]}"; then
            failed_count=$((failed_count + 1))
            failed_entries+=("${project_label}:source-list")
            echo "Could not inspect source before link migration: $source_path"
            return 1
        fi
    fi

    if [ ! -f "$migration_marker_file" ] && grep -Eq '\.rclonelink$' "$source_probe_list_file"; then
        destination_list_file=$(mktemp)
        temp_runtime_files+=("$destination_list_file")
        if ! list_destination_files_sorted "$destination_path" "$destination_list_file" "${source_filter_args[@]}"; then
            failed_count=$((failed_count + 1))
            failed_entries+=("${project_label}:destination-list")
            echo "Could not inspect existing destination before link migration: $destination_path"
            return 1
        fi

        if [ -s "$destination_list_file" ]; then
            migration_applies=1
            if is_enabled_value "$BACKUP_SUITE_CONFIRM_LINK_MIGRATION" && [ -s "$migration_report_file" ]; then
                echo "Applying confirmed --links migration using report '$migration_report_file'."
            else
                if ! write_link_migration_report "$source_path" "$destination_path" "$archive_path" "$migration_report_file" "${source_filter_args[@]}"; then
                    failed_count=$((failed_count + 1))
                    failed_entries+=("${project_label}:migration-report")
                    return 1
                fi
                migration_required_count=$((migration_required_count + 1))
                echo "Migration confirmation required. Review the report, then rerun with --confirm-link-migration."
                return 2
            fi
        fi
    fi

    attempt_one_log=$(mktemp)
    attempt_two_log=$(mktemp)
    attempt_three_log=$(mktemp)
    before_snapshot=$(mktemp)
    after_snapshot=$(mktemp)
    retry_snapshot=$(mktemp)
    changed_volatile_file=$(mktemp)
    active_paths_file=$(mktemp)
    active_filter_file=$(mktemp)
    deferred_paths_file=$(mktemp)
    deferred_filter_file=$(mktemp)
    temp_runtime_files+=("$attempt_one_log" "$attempt_two_log" "$attempt_three_log" "$before_snapshot" "$after_snapshot" "$retry_snapshot" "$changed_volatile_file" "$active_paths_file" "$active_filter_file" "$deferred_paths_file" "$deferred_filter_file")

    if [ "$migration_applies" -eq 1 ]; then
        if ! preserve_confirmed_migration_candidates "$source_path" "$destination_path" "$archive_path" "${source_filter_args[@]}"; then
            failed_count=$((failed_count + 1))
            failed_entries+=("${project_label}:migration-preservation")
            echo "Could not preserve confirmed migration candidates for '$source_path'; sync was not started."
            return 1
        fi
    fi

    : > "$active_paths_file"
    if is_enabled_value "$file_active_tracking_enabled" && [ "$file_active_window_seconds" -gt 0 ]; then
        if ! detect_active_files "$source_path" "$active_paths_file" "${source_filter_args[@]}"; then
            echo "Could not scan '$source_path' for recently changed files; continuing without deferrals."
            : > "$active_paths_file"
        fi
    fi
    write_path_filter_file "$active_paths_file" "$active_filter_file"
    if [ -s "$active_paths_file" ]; then
        active_count=$(wc -l < "$active_paths_file")
        deferred_active_count=$((deferred_active_count + active_count))
        echo "Deferring ${active_count} path(s) modified within the last ${file_active_window_seconds}s in '$project_label'; their previous remote versions stay in place until they settle."
        log_bounded_paths "Deferred active path" "$active_paths_file"
    fi

    if run_sync_attempt "$source_path" "$destination_path" "$archive_path/attempt-1" "$attempt_one_log" "$active_filter_file" "${source_sync_args[@]}"; then
        synced_count=$((synced_count + 1))
        if [ "$migration_applies" -eq 1 ]; then
            mark_migration_complete "$migration_marker_file" "$source_path" "$destination_path"
        fi
        record_project_deferrals "$project_label" "$migration_key" "$active_paths_file"
        echo "File sync completed for '$source_path'"
        return 0
    fi

    echo "Initial sync failed for '$source_path'; waiting ${file_stability_interval_seconds}s before one full retry."
    if ! snapshot_source_files "$source_path" "$before_snapshot" "${source_filter_args[@]}"; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${project_label}:stability-snapshot")
        record_project_deferrals "$project_label" "$migration_key" "$active_paths_file"
        return 1
    fi
    sleep "$file_stability_interval_seconds"
    if ! snapshot_source_files "$source_path" "$after_snapshot" "${source_filter_args[@]}"; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${project_label}:stability-snapshot")
        record_project_deferrals "$project_label" "$migration_key" "$active_paths_file"
        return 1
    fi

    if run_sync_attempt "$source_path" "$destination_path" "$archive_path/attempt-2" "$attempt_two_log" "$active_filter_file" "${source_sync_args[@]}"; then
        synced_count=$((synced_count + 1))
        if [ "$migration_applies" -eq 1 ]; then
            mark_migration_complete "$migration_marker_file" "$source_path" "$destination_path"
        fi
        record_project_deferrals "$project_label" "$migration_key" "$active_paths_file"
        echo "File sync completed on stability retry for '$source_path'"
        return 0
    fi

    if ! snapshot_source_files "$source_path" "$retry_snapshot" "${source_filter_args[@]}"; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${project_label}:stability-snapshot")
        record_project_deferrals "$project_label" "$migration_key" "$active_paths_file"
        return 1
    fi

    classify_changed_paths "$before_snapshot" "$retry_snapshot" "$volatile_pattern_file" "$changed_volatile_file"
    LC_ALL=C sort -u "$active_paths_file" "$changed_volatile_file" > "$deferred_paths_file"

    if [ -s "$changed_volatile_file" ]; then
        changed_count=$(wc -l < "$changed_volatile_file")
        echo "Retrying '$source_path' while deferring ${changed_count} path(s) that changed during the previous attempts."
        log_bounded_paths "Skipped changed path" "$changed_volatile_file"
        write_path_filter_file "$deferred_paths_file" "$deferred_filter_file"

        if run_sync_attempt "$source_path" "$destination_path" "$archive_path/attempt-3" "$attempt_three_log" "$deferred_filter_file" "${source_sync_args[@]}"; then
            skipped_changed_count=$((skipped_changed_count + changed_count))
            synced_count=$((synced_count + 1))
            if [ "$migration_applies" -eq 1 ]; then
                mark_migration_complete "$migration_marker_file" "$source_path" "$destination_path"
            fi
            record_project_deferrals "$project_label" "$migration_key" "$deferred_paths_file"
            echo "File sync completed with changing paths preserved remotely for retry on the next run."
            return 0
        fi
    fi

    record_project_deferrals "$project_label" "$migration_key" "$deferred_paths_file"
    failed_count=$((failed_count + 1))
    failed_entries+=("$project_label")
    echo "File sync failed for '$source_path'; remote deletions remain protected and prior versions are retained under '$archive_path'."
    return 1
}

echo "File backup started at ${run_started_at}"
select_project_profile
projects_total=$(count_planned_projects)
write_run_progress running
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

while IFS='|' read -r enabled label source_path destination_mode destination_value sync_stop_file isolation_mode unexpected_fields; do
    enabled=$(trim "$enabled")
    label=$(trim "$label")
    source_path=$(trim "$source_path")
    destination_mode=$(trim "$destination_mode")
    destination_value=$(trim "$destination_value")
    sync_stop_file=$(trim "$sync_stop_file")
    isolation_mode=$(trim "${isolation_mode:-single}")
    unexpected_fields=$(trim "${unexpected_fields:-}")

    [ -z "$enabled" ] && continue
    [[ "$enabled" == \#* ]] && continue
    is_enabled_value "$enabled" || continue

    if [ -n "$unexpected_fields" ]; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${label:-$source_path}:invalid-extra-fields")
        echo "Invalid extra fields in file source configuration for '${label:-$source_path}'."
        continue
    fi

    if [ -z "$source_path" ]; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${label:-unnamed}:empty-source")
        echo "Source path is empty for label '$label'."
        continue
    fi

    if [ ! -d "$source_path" ]; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${label:-$source_path}:missing-source")
        echo "Source path is missing or not a directory: $source_path"
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
            destination_base=$(basename "$source_path")
            ;;
        fixed)
            if [ -z "$destination_value" ]; then
                failed_count=$((failed_count + 1))
                failed_entries+=("${label:-$source_path}:missing-destination")
                echo "destination_value is required for fixed mapping: $source_path"
                continue
            fi
            destination_base=$(strip_slashes "$destination_value")
            ;;
        default-root|"")
            default_key="$destination_value"
            [ -n "$default_key" ] || default_key="${label:-$(basename "$source_path")}"
            destination_base=$(join_path "${FILE_DEFAULT_DESTINATION_ROOT:-files}" "$default_key")
            ;;
        *)
            failed_count=$((failed_count + 1))
            failed_entries+=("${label:-$source_path}:invalid-destination-mode")
            echo "Invalid destination mode '$destination_mode' for source '$source_path'"
            continue
            ;;
    esac

    case "${isolation_mode:-single}" in
        single|"")
            process_project "${label:-$source_path}" "$source_path" "$destination_base" || true
            ;;
        children)
            child_found=0
            while IFS= read -r -d '' child_path; do
                child_found=1
                child_name=$(basename "$child_path")
                if [ -n "$sync_stop_file" ] && [ -f "$child_path/$sync_stop_file" ]; then
                    skipped_count=$((skipped_count + 1))
                    echo "Skipping isolated project '$child_path' because $sync_stop_file is present"
                    continue
                fi
                process_project "${label:-$(basename "$source_path")}/$child_name" "$child_path" "$(join_path "$destination_base" "$child_name")" || true
            done < <(find "$source_path" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
            if [ "$child_found" -eq 0 ]; then
                failed_count=$((failed_count + 1))
                failed_entries+=("${label:-$source_path}:no-child-projects")
                echo "No child project directories found under isolated source '$source_path'."
            fi
            ;;
        *)
            failed_count=$((failed_count + 1))
            failed_entries+=("${label:-$source_path}:invalid-isolation-mode")
            echo "Invalid isolation mode '$isolation_mode' for source '$source_path'."
            ;;
    esac
done < "$FILE_SOURCE_CONFIG_PATH"

if is_enabled_value "$BACKUP_SUITE_LINK_MIGRATION_REPORT"; then
    if [ "$failed_count" -gt 0 ]; then
        run_outcome="migration-report-with-errors"
        exit 1
    fi
    run_outcome="migration-report-completed"
    exit 0
fi

if [ "$migration_required_count" -gt 0 ]; then
    run_outcome="migration-confirmation-required"
    exit 2
fi

if [ "$failed_count" -eq 0 ]; then
    echo "Cleaning archived file versions older than ${FILE_RETENTION_DAYS:-21d} from ${FILE_ARCHIVE_FOLDER_NAME:-deleted_files}"
    archive_listing_file=$(mktemp)
    temp_runtime_files+=("$archive_listing_file")
    if ! list_destination_files_sorted "$(join_path "$remote_base" "${FILE_ARCHIVE_FOLDER_NAME:-deleted_files}")" "$archive_listing_file"; then
        cleanup_failed=1
        echo "Could not inspect archived files for retention cleanup."
    elif [ ! -s "$archive_listing_file" ]; then
        echo "No archived file versions currently require inspection."
    elif "$RCLONE_BIN" delete "$(join_path "$remote_base" "${FILE_ARCHIVE_FOLDER_NAME:-deleted_files}")" \
        --config "$RCLONE_CONFIG_PATH" \
        --min-age "${FILE_RETENTION_DAYS:-21d}" \
        --rmdirs \
        --quiet \
        "${file_extra_args[@]}"; then
        echo "Archived file cleanup completed successfully."
    else
        cleanup_failed=1
        echo "Archived file cleanup failed."
    fi
else
    echo "Skipping archive retention cleanup because one or more isolated projects failed."
fi

notify_stale_deferrals

if [ "$failed_count" -gt 0 ] || [ "$cleanup_failed" -ne 0 ]; then
    run_outcome="completed-with-errors"
    exit 1
fi

if [ "$skipped_changed_count" -gt 0 ] || [ "$deferred_active_count" -gt 0 ]; then
    run_outcome="completed-with-skips"
    echo "File backup completed; changing paths were deferred and keep their previous remote versions until the next run."
else
    run_outcome="completed-successfully"
    echo "File backup completed successfully."
fi
