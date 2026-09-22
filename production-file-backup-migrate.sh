#!/bin/bash

set -euo pipefail

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALL_DIR="/opt/backup-suite"
CANONICAL_DIR="/opt/backup-suite-src"
CONFIG_DIR="/etc/backup-suite"
STATE_DIR="/var/lib/backup-suite"
UNIT_DIR="/etc/systemd/system"
WORKSPACE_SOURCE="/home/user/php-projects-lv"
CRYPTO_PROJECT="$WORKSPACE_SOURCE/crypto-wallets-api"
RCLONE_CONFIG="$CONFIG_DIR/rclone.conf"
GLOBAL_CONFIG="$CONFIG_DIR/global.conf"
FILE_SOURCES_CONFIG="$CONFIG_DIR/file-sources.conf"
FILE_BACKUP_UNIT="$UNIT_DIR/file-backup.service"
TIMER_UNIT="file-backup.timer"
SERVICE_UNIT="file-backup.service"
RESTORE_MAX_BYTES="${BACKUP_SUITE_RESTORE_MAX_BYTES:-268435456}"
AUTO_CONFIRM=0
CHECK_ONLY=0
MIGRATION_SUCCEEDED=0
RESTORE_DIR=""
RUN_ID=$(date -u '+%Y%m%dT%H%M%SZ')
RUN_STARTED_MARKER=""
BACKUP_DIR=""

usage() {
    cat <<'EOF'
Usage: sudo ./production-file-backup-migrate.sh [--yes] [--check]

Safely deploys the current Backup Suite source, updates only known file-backup
settings, runs the --links migration under resource limits, verifies a bounded
remote restore, and enables file-backup.timer only after every step succeeds.

  --yes    skip the interactive APPLY LINK MIGRATION confirmation
  --check  perform source/preflight checks only; make no production changes
EOF
}

log() {
    printf '[backup-suite-migrate] %s\n' "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

on_exit() {
    local status=$?

    if [ "$CHECK_ONLY" -eq 0 ] && [ "$MIGRATION_SUCCEEDED" -ne 1 ]; then
        systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1 || true
        systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true
        log "FAIL-SAFE: $TIMER_UNIT is disabled and $SERVICE_UNIT is stopped."
        if [ -n "$BACKUP_DIR" ]; then
            log "Protected configuration backups: $BACKUP_DIR"
        fi
        if [ -n "$RESTORE_DIR" ] && [ -d "$RESTORE_DIR" ]; then
            log "Failed restore-test files retained for inspection: $RESTORE_DIR"
        fi
    fi

    if [ "$status" -ne 0 ]; then
        log "Migration runner failed with exit code $status."
    fi
}

trap on_exit EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --yes)
            AUTO_CONFIRM=1
            ;;
        --check)
            CHECK_ONLY=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            die "Unknown option: $1"
            ;;
    esac
    shift
done

required_source_files=(
    "$SOURCE_DIR/bin/common.sh"
    "$SOURCE_DIR/bin/file-backup.sh"
    "$SOURCE_DIR/bin/database-backup.sh"
    "$SOURCE_DIR/bin/database-size-check.sh"
    "$SOURCE_DIR/bin/notify-failure.sh"
    "$SOURCE_DIR/bin/systemd-fork-run.sh"
    "$SOURCE_DIR/systemd/file-backup.service.template"
    "$SOURCE_DIR/examples/project-policies/crypto-wallets-api.backup-excludes"
    "$SOURCE_DIR/examples/project-policies/crypto-wallets-api.backup-volatile"
    "$SOURCE_DIR/tests/run.sh"
)

for source_file in "${required_source_files[@]}"; do
    [ -f "$source_file" ] || die "Required source file is missing: $source_file"
done

for command_name in awk chmod cp cut find flock git grep head install mktemp readlink rclone sed sha256sum sort stat systemctl systemd-analyze systemd-run tail tee wc; do
    require_command "$command_name"
done

[[ "$RESTORE_MAX_BYTES" =~ ^[0-9]+$ ]] || die "BACKUP_SUITE_RESTORE_MAX_BYTES must be a positive integer"
[ "$RESTORE_MAX_BYTES" -gt 0 ] || die "BACKUP_SUITE_RESTORE_MAX_BYTES must be greater than zero"

bash -n "$SOURCE_DIR/setup.sh" "$SOURCE_DIR"/bin/*.sh "$SOURCE_DIR/tests/run.sh" "$SOURCE_DIR/tests/fixtures"/*.sh

if [ -d "$SOURCE_DIR/.git" ]; then
    if ! git -C "$SOURCE_DIR" diff --quiet || ! git -C "$SOURCE_DIR" diff --cached --quiet; then
        die "Tracked repository changes are present. Commit or discard them before production migration."
    fi
    log "Source commit: $(git -C "$SOURCE_DIR" rev-parse --short HEAD)"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "Running integration tests in check-only mode."
    "$SOURCE_DIR/tests/run.sh"
    log "Check-only preflight passed. No production changes were made."
    MIGRATION_SUCCEEDED=1
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "Run this script with sudo."

for protected_path in "$GLOBAL_CONFIG" "$FILE_SOURCES_CONFIG" "$RCLONE_CONFIG"; do
    [ -f "$protected_path" ] || die "Required production file is missing: $protected_path"
done

exec {MIGRATION_LOCK_FD}>/run/backup-suite-production-migrate.lock
flock -n "$MIGRATION_LOCK_FD" || die "Another Backup Suite production migration is already running."

log "Disabling the file-backup timer before deployment."
systemctl disable --now "$TIMER_UNIT" >/dev/null 2>&1 || true
systemctl stop "$SERVICE_UNIT" >/dev/null 2>&1 || true

log "Running the repository integration suite before deployment."
"$SOURCE_DIR/tests/run.sh"

BACKUP_DIR="$STATE_DIR/migration-backups/$RUN_ID"
install -d -m 700 "$BACKUP_DIR"
cp -a "$(readlink -f "$GLOBAL_CONFIG")" "$BACKUP_DIR/global.conf"
cp -a "$(readlink -f "$FILE_SOURCES_CONFIG")" "$BACKUP_DIR/file-sources.conf"
if [ -f "$FILE_BACKUP_UNIT" ]; then
    cp -a "$FILE_BACKUP_UNIT" "$BACKUP_DIR/file-backup.service"
fi
if [ -f "$CRYPTO_PROJECT/.backup-excludes" ]; then
    cp -a "$CRYPTO_PROJECT/.backup-excludes" "$BACKUP_DIR/crypto-wallets-api.backup-excludes"
fi
if [ -f "$CRYPTO_PROJECT/.backup-volatile" ]; then
    cp -a "$CRYPTO_PROJECT/.backup-volatile" "$BACKUP_DIR/crypto-wallets-api.backup-volatile"
fi
log "Protected configuration backups written to $BACKUP_DIR"

replace_file_preserving_metadata() {
    local replacement_file="$1"
    local target_file="$2"
    local default_mode="$3"
    local resolved_target
    local target_mode="$default_mode"
    local target_uid=0
    local target_gid=0

    if [ -e "$target_file" ] || [ -L "$target_file" ]; then
        resolved_target=$(readlink -f "$target_file")
        [ -n "$resolved_target" ] || die "Could not resolve target: $target_file"
        target_mode=$(stat -c '%a' "$resolved_target")
        target_uid=$(stat -c '%u' "$resolved_target")
        target_gid=$(stat -c '%g' "$resolved_target")
    else
        resolved_target="$target_file"
        if [ -d "$(dirname "$target_file")" ]; then
            target_uid=$(stat -c '%u' "$(dirname "$target_file")")
            target_gid=$(stat -c '%g' "$(dirname "$target_file")")
        fi
    fi

    install -m "$target_mode" -o "$target_uid" -g "$target_gid" "$replacement_file" "$resolved_target"
}

set_shell_config_value() {
    local config_file="$1"
    local config_key="$2"
    local config_value="$3"
    local resolved_config
    local temp_file

    resolved_config=$(readlink -f "$config_file")
    temp_file=$(mktemp)
    awk -v key="$config_key" -v replacement="${config_key}=\"${config_value}\"" '
        BEGIN { replaced = 0 }
        $0 ~ "^" key "=" {
            if (!replaced) {
                print replacement
                replaced = 1
            }
            next
        }
        { print }
        END {
            if (!replaced) {
                print replacement
            }
        }
    ' "$resolved_config" > "$temp_file"
    replace_file_preserving_metadata "$temp_file" "$config_file" 640
    rm -f "$temp_file"
}

install_policy_file() {
    local source_file="$1"
    local target_file="$2"
    [ -d "$(dirname "$target_file")" ] || die "Policy target directory is missing: $(dirname "$target_file")"
    replace_file_preserving_metadata "$source_file" "$target_file" 644
}

log "Deploying scripts without replacing production config or credentials."
install -d -m 755 "$INSTALL_DIR/bin" "$CANONICAL_DIR/bin" "$CANONICAL_DIR/systemd"
install -m 755 "$SOURCE_DIR"/bin/*.sh "$INSTALL_DIR/bin/"
install -m 755 "$SOURCE_DIR"/bin/*.sh "$CANONICAL_DIR/bin/"
install -m 755 "$SOURCE_DIR/setup.sh" "$CANONICAL_DIR/setup.sh"
install -m 644 "$SOURCE_DIR"/systemd/*.template "$CANONICAL_DIR/systemd/"
install -m 644 "$SOURCE_DIR/README.md" "$INSTALL_DIR/README.md"
install -m 755 "$SOURCE_DIR/production-file-backup-migrate.sh" "$CANONICAL_DIR/production-file-backup-migrate.sh"

install_policy_file "$SOURCE_DIR/examples/project-policies/crypto-wallets-api.backup-excludes" "$CRYPTO_PROJECT/.backup-excludes"
install_policy_file "$SOURCE_DIR/examples/project-policies/crypto-wallets-api.backup-volatile" "$CRYPTO_PROJECT/.backup-volatile"

log "Updating only known file-backup settings in $GLOBAL_CONFIG."
set_shell_config_value "$GLOBAL_CONFIG" FILE_VOLATILE_FILENAME .backup-volatile
set_shell_config_value "$GLOBAL_CONFIG" FILE_RCLONE_TRANSFERS 2
set_shell_config_value "$GLOBAL_CONFIG" FILE_RCLONE_CHECKERS 4
set_shell_config_value "$GLOBAL_CONFIG" FILE_RCLONE_BUFFER_SIZE 16M
set_shell_config_value "$GLOBAL_CONFIG" FILE_STABILITY_INTERVAL_SECONDS 10
set_shell_config_value "$GLOBAL_CONFIG" FILE_CHANGED_DETAIL_LIMIT 20
set_shell_config_value "$GLOBAL_CONFIG" FILE_BACKUP_RUNTIME_MAX_SEC 6h
set_shell_config_value "$GLOBAL_CONFIG" BACKUP_SUITE_LOG_MAX_BYTES 10485760
set_shell_config_value "$GLOBAL_CONFIG" BACKUP_SUITE_LOG_KEEP_FILES 10
set_shell_config_value "$GLOBAL_CONFIG" NOTIFY_DURABLE_LOG_LINES 120
set_shell_config_value "$GLOBAL_CONFIG" NOTIFY_FAILURE_LOG_KEEP_FILES 100

resolved_sources_config=$(readlink -f "$FILE_SOURCES_CONFIG")
workspace_row_count=$(awk -F '|' -v wanted="$WORKSPACE_SOURCE" '
    function trim(value) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return value
    }
    /^[[:space:]]*#/ { next }
    NF >= 3 && trim($3) == wanted { count++ }
    END { print count + 0 }
' "$resolved_sources_config")
[ "$workspace_row_count" -eq 1 ] || die "Expected exactly one file-source row for $WORKSPACE_SOURCE; found $workspace_row_count"

updated_sources_file=$(mktemp)
awk -F '|' -v OFS='|' -v wanted="$WORKSPACE_SOURCE" '
    function trim(value) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return value
    }
    /^[[:space:]]*#/ { print; next }
    NF >= 3 && trim($3) == wanted {
        if (NF > 7) {
            print "Unexpected fields in workspace source row" > "/dev/stderr"
            exit 2
        }
        $7 = "children"
        changed++
    }
    { print }
    END {
        if (changed != 1) {
            exit 3
        }
    }
' "$resolved_sources_config" > "$updated_sources_file" || die "Could not safely update workspace isolation mode"
replace_file_preserving_metadata "$updated_sources_file" "$FILE_SOURCES_CONFIG" 640
rm -f "$updated_sources_file"

configured_isolation=$(awk -F '|' -v wanted="$WORKSPACE_SOURCE" '
    function trim(value) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        return value
    }
    /^[[:space:]]*#/ { next }
    NF >= 7 && trim($3) == wanted { print trim($7) }
' "$resolved_sources_config")
[ "$configured_isolation" = "children" ] || die "Workspace isolation verification failed"

rendered_unit=$(mktemp)
sed \
    -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
    -e "s|__CONFIG_DIR__|$CONFIG_DIR|g" \
    -e 's|__USER_GROUP_DIRECTIVES__||g' \
    -e 's|__LOCK_FILE__|/run/backup-suite/file-backup.lock|g' \
    -e 's|__FILE_BACKUP_RUNTIME_MAX_SEC__|6h|g' \
    "$SOURCE_DIR/systemd/file-backup.service.template" > "$rendered_unit"
if grep -Eq '__[A-Z0-9_]+__' "$rendered_unit"; then
    die "Unresolved placeholder remains in rendered file-backup.service"
fi
install -m 644 -o 0 -g 0 "$rendered_unit" "$FILE_BACKUP_UNIT"
rm -f "$rendered_unit"
systemd-analyze verify "$FILE_BACKUP_UNIT"
systemctl daemon-reload

run_resource_limited_backup() {
    local unit_name="$1"
    local migration_argument="$2"

    systemd-run \
        --quiet \
        --unit="$unit_name" \
        --wait \
        --collect \
        --setenv=BACKUP_SUITE_CONFIG_DIR="$CONFIG_DIR" \
        --property=CPUQuota=50% \
        --property=CPUWeight=10 \
        --property=IOWeight=10 \
        --property=Nice=15 \
        --property=IOSchedulingClass=idle \
        --property=MemoryHigh=512M \
        --property=MemoryMax=1G \
        --property=TasksMax=64 \
        --property=RuntimeMaxSec=6h \
        --property=StandardOutput=journal \
        --property=StandardError=journal \
        "$INSTALL_DIR/bin/file-backup.sh" --journal-only "$migration_argument"
}

install -d -m 700 "$STATE_DIR/migration-reports"
RUN_STARTED_MARKER=$(mktemp "$STATE_DIR/.migration-report-start.XXXXXX")
log "Running the no-change production link-migration report under resource limits."
report_unit="backup-suite-link-report-${RUN_ID,,}"
run_resource_limited_backup "$report_unit" --link-migration-report

mapfile -t report_files < <(find "$STATE_DIR/migration-reports" -maxdepth 1 -type f -name '*.txt' -newer "$RUN_STARTED_MARKER" -print | sort)
[ ${#report_files[@]} -gt 0 ] || die "Migration report run produced no new report files"

log "Migration reports completed: ${#report_files[@]}"
total_symlinks=0
total_destination_only=0
for report_file in "${report_files[@]}"; do
    dry_status=$(awk -F= '$1 == "dry_run_status" { print $2; exit }' "$report_file")
    [ "$dry_status" = "success" ] || die "Dry-run failure recorded in $report_file"
    report_symlinks=$(awk -F= '$1 == "source_symlinks" { print $2; exit }' "$report_file")
    report_destination_only=$(awk -F= '$1 == "destination_only_candidates" { print $2; exit }' "$report_file")
    [[ "$report_symlinks" =~ ^[0-9]+$ ]] || die "Invalid source_symlinks in $report_file"
    [[ "$report_destination_only" =~ ^[0-9]+$ ]] || die "Invalid destination_only_candidates in $report_file"
    total_symlinks=$((total_symlinks + report_symlinks))
    total_destination_only=$((total_destination_only + report_destination_only))
done
log "Dry-run impact: source_symlinks=$total_symlinks destination_only_candidates=$total_destination_only"
log "Reports: $STATE_DIR/migration-reports"

if [ "$AUTO_CONFIRM" -ne 1 ]; then
    printf '\nReview the migration reports before continuing.\n'
    printf 'Type APPLY LINK MIGRATION to preserve the reported candidates and continue: '
    read -r confirmation
    [ "$confirmation" = "APPLY LINK MIGRATION" ] || die "Migration was not confirmed"
fi

log "Applying the confirmed migration under resource limits."
confirm_unit="backup-suite-link-confirm-${RUN_ID,,}"
run_resource_limited_backup "$confirm_unit" --confirm-link-migration

select_restore_report() {
    local report_file
    local report_symlinks
    local destination
    local size_json
    local destination_bytes
    local selected_file=""
    local selected_destination=""
    local selected_size=0

    for report_file in "${report_files[@]}"; do
        report_symlinks=$(awk -F= '$1 == "source_symlinks" { print $2; exit }' "$report_file")
        [ "${report_symlinks:-0}" -gt 0 ] || continue
        destination=$(awk -F= '$1 == "destination" { print substr($0, index($0, "=") + 1); exit }' "$report_file")
        [ -n "$destination" ] || continue
        size_json=$(rclone size "$destination" --config "$RCLONE_CONFIG" --links --json 2>/dev/null || true)
        destination_bytes=$(printf '%s' "$size_json" | sed -n 's/.*"bytes":[[:space:]]*\([0-9][0-9]*\).*/\1/p')
        [[ "$destination_bytes" =~ ^[0-9]+$ ]] || continue
        if [ "$destination_bytes" -le "$RESTORE_MAX_BYTES" ] && { [ -z "$selected_file" ] || [ "$destination_bytes" -lt "$selected_size" ]; }; then
            selected_file="$report_file"
            selected_destination="$destination"
            selected_size="$destination_bytes"
        fi
    done

    [ -n "$selected_file" ] || return 1
    printf '%s\n%s\n%s\n' "$selected_file" "$selected_destination" "$selected_size"
}

mapfile -t restore_selection < <(select_restore_report || true)
[ ${#restore_selection[@]} -eq 3 ] || die "No migrated symlink destination was small enough for the bounded restore test (limit $RESTORE_MAX_BYTES bytes)"
restore_report="${restore_selection[0]}"
restore_remote="${restore_selection[1]}"
restore_size="${restore_selection[2]}"

RESTORE_DIR=$(mktemp -d "/var/tmp/backup-suite-restore-${RUN_ID}.XXXXXX")
log "Restoring the smallest eligible migrated project (${restore_size} bytes) into $RESTORE_DIR"
rclone copy "$restore_remote" "$RESTORE_DIR" \
    --config "$RCLONE_CONFIG" \
    --links \
    --transfers 2 \
    --checkers 4 \
    --buffer-size 16M

expected_link_count=$(rclone lsf "$restore_remote" \
    --config "$RCLONE_CONFIG" \
    --recursive \
    --files-only \
    --format p \
    --links | grep -Ec '\.rclonelink$' || true)
restored_link_count=$(find "$RESTORE_DIR" -type l -print | wc -l)
[ "$expected_link_count" -gt 0 ] || die "Selected restore destination contains no link records after migration"
[ "$restored_link_count" -eq "$expected_link_count" ] || die "Restore link count mismatch: expected $expected_link_count, restored $restored_link_count"

while IFS= read -r restored_link; do
    [ -L "$restored_link" ] || die "Restore verification found a non-link entry: $restored_link"
    readlink "$restored_link" >/dev/null
done < <(find "$RESTORE_DIR" -type l -print)

log "Remote restore verification passed: symlinks=$restored_link_count report=$restore_report"
case "$RESTORE_DIR" in
    /var/tmp/backup-suite-restore-*)
        rm -rf "$RESTORE_DIR"
        RESTORE_DIR=""
        ;;
    *)
        die "Refusing to remove unexpected restore directory: $RESTORE_DIR"
        ;;
esac

rm -f "$RUN_STARTED_MARKER"
RUN_STARTED_MARKER=""

log "Enabling $TIMER_UNIT only after successful migration and restore verification."
systemctl enable --now "$TIMER_UNIT"
systemctl is-enabled --quiet "$TIMER_UNIT"
systemctl is-active --quiet "$TIMER_UNIT"

MIGRATION_SUCCEEDED=1
log "SUCCESS: production file backup migration completed and $TIMER_UNIT is enabled."
log "Durable run logs: $STATE_DIR/logs"
log "Retained failure records: $STATE_DIR/failures"
