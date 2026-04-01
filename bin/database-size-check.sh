#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

parse_standard_runtime_args "$@"
setup_journal_logging "backup-db-monitor"
load_global_config
acquire_backup_lock "backup-suite" "backup-suite"

require_command mysql
require_file "$DATABASE_BACKUP_CONFIG_PATH"

[ -d "$MYSQL_PROFILE_DIR" ] || fail "MySQL profile directory not found: $MYSQL_PROFILE_DIR"

run_started_at=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
checked_count=0
over_threshold_count=0
missing_count=0
error_count=0
over_threshold_entries=()
threshold_mb="${DB_MONITOR_THRESHOLD_MB:-512}"
threshold_bytes=$((threshold_mb * 1024 * 1024))

echo "Database size monitor started at $run_started_at"
echo "Threshold: ${threshold_mb} MB"

while IFS='|' read -r enabled site_label database_name mysql_profile; do
    enabled=$(trim "$enabled")
    site_label=$(trim "$site_label")
    database_name=$(trim "$database_name")
    mysql_profile=$(trim "$mysql_profile")

    [ -z "$enabled" ] && continue
    [[ "$enabled" == \#* ]] && continue
    is_enabled_value "$enabled" || continue
    [ -n "$database_name" ] || continue

    profile_file=$(resolve_mysql_profile_file "$mysql_profile")
    if [ ! -f "$profile_file" ]; then
        error_count=$((error_count + 1))
        echo "ERROR: MySQL profile file not found for '$database_name': $profile_file"
        continue
    fi
    if [ ! -r "$profile_file" ]; then
        error_count=$((error_count + 1))
        echo "ERROR: MySQL profile file is not readable for '$database_name': $profile_file"
        continue
    fi

    checked_count=$((checked_count + 1))

    size_bytes=$(mysql --defaults-extra-file="$profile_file" --batch --skip-column-names \
        -e "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema = '${database_name//\'/\'\'}';" 2>/tmp/backup-suite-db-monitor.err) || {
        error_count=$((error_count + 1))
        echo "ERROR: failed to query database size for '$database_name'"
        cat /tmp/backup-suite-db-monitor.err
        rm -f /tmp/backup-suite-db-monitor.err
        continue
    }
    rm -f /tmp/backup-suite-db-monitor.err

    if [ "$size_bytes" = "0" ]; then
        exists=$(mysql --defaults-extra-file="$profile_file" --batch --skip-column-names \
            -e "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '${database_name//\'/\'\'}';")
        if [ "$exists" = "0" ]; then
            missing_count=$((missing_count + 1))
            echo "WARNING: database '$database_name' for site '$site_label' was not found."
            continue
        fi
    fi

    size_mb=$(awk -v bytes="$size_bytes" 'BEGIN { printf "%.2f", bytes / 1024 / 1024 }')
    echo "Database '$database_name' for site '$site_label' is ${size_mb} MB"

    if [ "$size_bytes" -ge "$threshold_bytes" ]; then
        over_threshold_count=$((over_threshold_count + 1))
        over_threshold_entries+=("${site_label}:${database_name}:${size_mb}MB")
        echo "ALERT: database '$database_name' for site '$site_label' is at or above ${threshold_mb} MB"
    fi
done < "$DATABASE_BACKUP_CONFIG_PATH"

echo "Database size monitor summary: checked=${checked_count} over_threshold=${over_threshold_count} missing=${missing_count} errors=${error_count}"
if [ ${#over_threshold_entries[@]} -gt 0 ]; then
    echo "Databases over threshold: ${over_threshold_entries[*]}"
fi

if [ "$error_count" -ne 0 ]; then
    exit 1
fi

echo "Database size monitor finished at $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
