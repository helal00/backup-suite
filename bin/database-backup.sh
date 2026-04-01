#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

parse_standard_runtime_args "$@"
setup_journal_logging "backup-db"
load_global_config
acquire_backup_lock "backup-suite" "backup-suite"

require_command mysqldump
require_command mysql
require_command sha256sum
require_rclone_bin
require_file "$DATABASE_BACKUP_CONFIG_PATH"
require_file "$RCLONE_CONFIG_PATH"

[ -d "$MYSQL_PROFILE_DIR" ] || fail "MySQL profile directory not found: $MYSQL_PROFILE_DIR"

run_started_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
run_outcome="success"
backed_up_count=0
skipped_unchanged_count=0
failed_count=0
failed_entries=()
remote_cleanup_failed=0
local_cleanup_failed=0
timestamp=$(date -u '+%Y-%m-%d_%H-%M-%S')
remote_base=$(join_path "$(remote_base_root)" "${DB_REMOTE_DESTINATION_ROOT:-databases}")
db_extra_args=()
pending_hash_files=()
pending_hash_values=()
hash_state_dir=$(join_path "$STATE_DIR" "database-hashes")

if [ -n "${DB_RCLONE_EXTRA_FLAGS:-}" ]; then
    read -r -a db_extra_args <<< "$DB_RCLONE_EXTRA_FLAGS"
fi

db_progress_args=()
if is_enabled_value "${BACKUP_SUITE_RCLONE_VERBOSE:-0}"; then
    db_progress_args=(--stats 10s --stats-one-line --stats-log-level NOTICE)
fi

compute_dump_hash() {
    local dump_file="$1"

    case "$dump_file" in
        *.sql.zst)
            zstd -dc "$dump_file" | sha256sum | awk '{print $1}'
            ;;
        *.sql.gz)
            gzip -dc "$dump_file" | sha256sum | awk '{print $1}'
            ;;
        *)
            sha256sum "$dump_file" | awk '{print $1}'
            ;;
    esac
}

hash_state_file_for_db() {
    local site_label="$1"
    local database_name="$2"

    printf '%s' "$(join_path "$hash_state_dir" "$site_label" "${database_name}.sha256")"
}

has_staged_local_dumps() {
    find "$DB_LOCAL_OUTPUT_DIR" -type f \( -name '*.sql.zst' -o -name '*.sql.gz' \) -print -quit | grep -q .
}

if command -v zstd >/dev/null 2>&1; then
    compressor="zstd"
    extension="sql.zst"
else
    compressor="gzip"
    extension="sql.gz"
fi

finish() {
    local exit_code=$?
    local run_finished_at

    run_finished_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
    echo "Run summary: outcome=${run_outcome} backed_up=${backed_up_count} skipped_unchanged=${skipped_unchanged_count} failed=${failed_count} local_cleanup_failed=${local_cleanup_failed} remote_cleanup_failed=${remote_cleanup_failed}"
    if [ ${#failed_entries[@]} -gt 0 ]; then
        echo "Failed database backups: ${failed_entries[*]}"
    fi
    if [ "$exit_code" -eq 0 ]; then
        echo "Database backup finished at ${run_finished_at} with status: success"
    else
        echo "Database backup finished at ${run_finished_at} with status: failure (exit code ${exit_code})"
    fi
}

trap finish EXIT

mkdir -p "$DB_LOCAL_OUTPUT_DIR"
mkdir -p "$hash_state_dir"

echo "Database backup started at $run_started_at"
echo "Using database config: $DATABASE_BACKUP_CONFIG_PATH"
echo "Local output directory: $DB_LOCAL_OUTPUT_DIR"
echo "Remote database root: $remote_base"
echo "Compression: $compressor"

while IFS='|' read -r enabled site_label database_name mysql_profile; do
    enabled=$(trim "$enabled")
    site_label=$(trim "$site_label")
    database_name=$(trim "$database_name")
    mysql_profile=$(trim "$mysql_profile")

    [ -z "$enabled" ] && continue
    [[ "$enabled" == \#* ]] && continue
    is_enabled_value "$enabled" || continue
    [ -n "$site_label" ] || continue
    [ -n "$database_name" ] || continue

    profile_file=$(resolve_mysql_profile_file "$mysql_profile")
    if [ ! -f "$profile_file" ]; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${site_label}:${database_name}:missing-profile:${mysql_profile:-default}")
        echo "MySQL profile file not found for database '$database_name': $profile_file"
        continue
    fi
    if [ ! -r "$profile_file" ]; then
        failed_count=$((failed_count + 1))
        failed_entries+=("${site_label}:${database_name}:unreadable-profile:${mysql_profile:-default}")
        echo "MySQL profile file is not readable for database '$database_name': $profile_file"
        continue
    fi

    target_dir=$(join_path "$DB_LOCAL_OUTPUT_DIR" "$site_label" "$database_name")
    hash_state_file=$(hash_state_file_for_db "$site_label" "$database_name")
    mkdir -p "$target_dir"
    mkdir -p "$(dirname "$hash_state_file")"
    target_file="$target_dir/${timestamp}.${extension}"

    echo "Backing up database '$database_name' for site '$site_label'"

    if [ "$compressor" = "zstd" ]; then
        if mysqldump \
            --defaults-extra-file="$profile_file" \
            --single-transaction \
            --quick \
            --skip-comments \
            --routines \
            --triggers \
            --events \
            --databases "$database_name" | zstd -T0 -q -o "$target_file"; then
            dump_hash=$(compute_dump_hash "$target_file")
            if is_enabled_value "${DB_SKIP_UNCHANGED_BACKUPS:-1}" && [ -f "$hash_state_file" ] && [ "$(tr -d '[:space:]' < "$hash_state_file")" = "$dump_hash" ]; then
                rm -f "$target_file"
                skipped_unchanged_count=$((skipped_unchanged_count + 1))
                echo "Database backup unchanged since last successful upload: $database_name"
            else
                pending_hash_files+=("$hash_state_file")
                pending_hash_values+=("$dump_hash")
                backed_up_count=$((backed_up_count + 1))
                echo "Database backup completed: $database_name -> $target_file"
            fi
        else
            rm -f "$target_file"
            failed_count=$((failed_count + 1))
            failed_entries+=("${site_label}:${database_name}")
            echo "Database backup failed: $database_name"
        fi
    else
        if mysqldump \
            --defaults-extra-file="$profile_file" \
            --single-transaction \
            --quick \
            --skip-comments \
            --routines \
            --triggers \
            --events \
            --databases "$database_name" | gzip -c > "$target_file"; then
            dump_hash=$(compute_dump_hash "$target_file")
            if is_enabled_value "${DB_SKIP_UNCHANGED_BACKUPS:-1}" && [ -f "$hash_state_file" ] && [ "$(tr -d '[:space:]' < "$hash_state_file")" = "$dump_hash" ]; then
                rm -f "$target_file"
                skipped_unchanged_count=$((skipped_unchanged_count + 1))
                echo "Database backup unchanged since last successful upload: $database_name"
            else
                pending_hash_files+=("$hash_state_file")
                pending_hash_values+=("$dump_hash")
                backed_up_count=$((backed_up_count + 1))
                echo "Database backup completed: $database_name -> $target_file"
            fi
        else
            rm -f "$target_file"
            failed_count=$((failed_count + 1))
            failed_entries+=("${site_label}:${database_name}")
            echo "Database backup failed: $database_name"
        fi
    fi
done < "$DATABASE_BACKUP_CONFIG_PATH"

echo "Deleting local database backups older than ${DB_RETENTION_DAYS:-14} days from $DB_LOCAL_OUTPUT_DIR"
if find "$DB_LOCAL_OUTPUT_DIR" -type f \( -name '*.sql.zst' -o -name '*.sql.gz' \) -mtime +"${DB_RETENTION_DAYS:-14}" -delete; then
    echo "Local database retention cleanup completed successfully."
else
    local_cleanup_failed=1
    echo "Local database retention cleanup failed."
fi

if has_staged_local_dumps; then
    echo "Uploading database backups to $remote_base"
    if "$RCLONE_BIN" copy "$DB_LOCAL_OUTPUT_DIR" "$remote_base" \
        --config "$RCLONE_CONFIG_PATH" \
        --transfers "${DB_RCLONE_TRANSFERS:-4}" \
        --checkers "${DB_RCLONE_CHECKERS:-8}" \
        "${db_progress_args[@]}" \
        "${db_extra_args[@]}"; then
        echo "Remote database upload completed successfully."

        if [ ${#pending_hash_files[@]} -gt 0 ]; then
            for index in "${!pending_hash_files[@]}"; do
                printf '%s\n' "${pending_hash_values[$index]}" > "${pending_hash_files[$index]}"
            done
        fi

        if ! is_enabled_value "${DB_KEEP_LOCAL_AFTER_UPLOAD:-1}"; then
            echo "Removing local staged database dumps after successful upload."
            find "$DB_LOCAL_OUTPUT_DIR" -type f \( -name '*.sql.zst' -o -name '*.sql.gz' \) -delete
            find "$DB_LOCAL_OUTPUT_DIR" -depth -type d -empty -delete
        fi
    else
        failed_count=$((failed_count + 1))
        failed_entries+=("remote-upload")
        echo "Remote database upload failed."
    fi
else
    echo "No staged local database dumps require upload."
fi

echo "Deleting remote database backups older than ${DB_RETENTION_DAYS:-14} days from $remote_base"
if "$RCLONE_BIN" delete "$remote_base" \
    --config "$RCLONE_CONFIG_PATH" \
    --min-age "${DB_RETENTION_DAYS:-14}d" \
    --rmdirs \
    --quiet; then
    echo "Remote database retention cleanup completed successfully."
else
    remote_cleanup_failed=1
    echo "Remote database retention cleanup failed."
fi

if [ "$failed_count" -gt 0 ] || [ "$local_cleanup_failed" -ne 0 ] || [ "$remote_cleanup_failed" -ne 0 ]; then
    run_outcome="completed-with-errors"
    exit 1
fi

run_outcome="completed-successfully"
echo "Database backup completed successfully."
