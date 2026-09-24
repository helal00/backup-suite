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
CONTROL_ENV_FILE="/run/backup-suite/file-backup.env"
PROJECT_FILTER_FILE=""
VALIDATION_DIR=""
RESOURCE_REPORT=""
MIGRATION_PROJECTS=()

usage() {
    cat <<'EOF'
Usage: sudo ./production-file-backup-migrate.sh [--yes] [--check] [--only-project LABEL]...

Safely deploys the current Backup Suite source, updates only known file-backup
settings, runs the --links migration under resource limits, verifies a bounded
remote restore, and enables file-backup.timer only after every step succeeds.

  --yes    skip the interactive APPLY LINK MIGRATION confirmation
  --check  perform source/preflight checks only; make no production changes
  --only-project LABEL
           report and confirm only the exact isolated project label; repeatable
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

    if [ -n "$VALIDATION_DIR" ]; then
        case "$VALIDATION_DIR" in
            "$STATE_DIR"/validation/*)
                rm -rf "$VALIDATION_DIR/config"
                ;;
            *)
                log "Refusing to clean unexpected validation directory: $VALIDATION_DIR" >&2
                ;;
        esac
    fi
    if [ -n "$PROJECT_FILTER_FILE" ]; then
        case "$PROJECT_FILTER_FILE" in
            "$STATE_DIR"/validation/*-project-filter)
                rm -f "$PROJECT_FILTER_FILE"
                ;;
            *)
                log "Refusing to clean unexpected project filter: $PROJECT_FILTER_FILE" >&2
                ;;
        esac
    fi

    if [ "$CHECK_ONLY" -eq 0 ] && [ "$MIGRATION_SUCCEEDED" -ne 1 ]; then
        rm -f "$CONTROL_ENV_FILE"
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
        --only-project)
            [ "$#" -ge 2 ] || die "--only-project requires an exact project label"
            [[ "$2" != *'|'* && "$2" != *$'\n'* ]] || die "Invalid --only-project label"
            MIGRATION_PROJECTS+=("$2")
            shift
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
    "$SOURCE_DIR/bin/file-backup-service.sh"
    "$SOURCE_DIR/bin/database-backup.sh"
    "$SOURCE_DIR/bin/database-size-check.sh"
    "$SOURCE_DIR/bin/notify-failure.sh"
    "$SOURCE_DIR/bin/systemd-fork-run.sh"
    "$SOURCE_DIR/systemd/file-backup.service.template"
    "$SOURCE_DIR/systemd/file-backup.timer.template"
    "$SOURCE_DIR/examples/project-policies/crypto-wallets-api.backup-excludes"
    "$SOURCE_DIR/examples/project-policies/crypto-wallets-api.backup-volatile"
    "$SOURCE_DIR/tests/run.sh"
)

for source_file in "${required_source_files[@]}"; do
    [ -f "$source_file" ] || die "Required source file is missing: $source_file"
done

for command_name in awk chmod cp cut find flock git grep head install mktemp readlink rclone sed sha256sum sort stat systemctl systemd-analyze systemd-cgls tail tee wc; do
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
install -d -m 755 "$STATE_DIR/locks"
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
set_shell_config_value "$GLOBAL_CONFIG" FILE_GLOBAL_EXCLUDE_PATTERNS '.ai-metadata/observation-cache/**|.ai-metadata/.ready-observation-cache.*|.ai-metadata/ready-observation-cache.json|.ai-metadata/native-ready-cache/**|.ai-metadata/prompt-runs/**'
set_shell_config_value "$GLOBAL_CONFIG" FILE_RCLONE_TRANSFERS 2
set_shell_config_value "$GLOBAL_CONFIG" FILE_RCLONE_CHECKERS 4
set_shell_config_value "$GLOBAL_CONFIG" FILE_RCLONE_BUFFER_SIZE 16M
set_shell_config_value "$GLOBAL_CONFIG" FILE_STABILITY_INTERVAL_SECONDS 10
set_shell_config_value "$GLOBAL_CONFIG" FILE_CHANGED_DETAIL_LIMIT 20
set_shell_config_value "$GLOBAL_CONFIG" FILE_BACKUP_RUNTIME_MAX_SEC 6h
set_shell_config_value "$GLOBAL_CONFIG" FILE_BACKUP_RANDOMIZED_DELAY_SEC 15m
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
    -e "s|__LOCK_FILE__|$STATE_DIR/locks/file-backup.service.lock|g" \
    -e 's|__FILE_BACKUP_RUNTIME_MAX_SEC__|6h|g' \
    "$SOURCE_DIR/systemd/file-backup.service.template" > "$rendered_unit"
if grep -Eq '__[A-Z0-9_]+__' "$rendered_unit"; then
    die "Unresolved placeholder remains in rendered file-backup.service"
fi
install -m 644 -o 0 -g 0 "$rendered_unit" "$FILE_BACKUP_UNIT"
rm -f "$rendered_unit"
systemd-analyze verify "$FILE_BACKUP_UNIT"

rendered_timer=$(mktemp)
configured_file_schedule=$(bash -c '. "$1"; printf "%s" "${FILE_BACKUP_ONCALENDAR:-*:0/30}"' _ "$(readlink -f "$GLOBAL_CONFIG")")
configured_randomized_delay=$(bash -c '. "$1"; printf "%s" "${FILE_BACKUP_RANDOMIZED_DELAY_SEC:-15m}"' _ "$(readlink -f "$GLOBAL_CONFIG")")
sed \
    -e "s|__FILE_BACKUP_ONCALENDAR__|$configured_file_schedule|g" \
    -e "s|__FILE_BACKUP_RANDOMIZED_DELAY_SEC__|$configured_randomized_delay|g" \
    "$SOURCE_DIR/systemd/file-backup.timer.template" > "$rendered_timer"
install -m 644 -o 0 -g 0 "$rendered_timer" "$UNIT_DIR/file-backup.timer"
rm -f "$rendered_timer"
systemd-analyze verify "$UNIT_DIR/file-backup.timer"
systemctl daemon-reload

assert_service_property() {
    local property_name="$1"
    local expected_value="$2"
    local actual_value

    actual_value=$(systemctl show "$SERVICE_UNIT" -p "$property_name" --value)
    [ "$actual_value" = "$expected_value" ] || die "$SERVICE_UNIT property $property_name is '$actual_value'; expected '$expected_value'"
}

assert_service_property Type exec
assert_service_property Restart no
assert_service_property KillMode control-group
assert_service_property CPUAccounting yes
assert_service_property MemoryAccounting yes
assert_service_property IOAccounting yes
assert_service_property CPUWeight 10
assert_service_property IOWeight 10
assert_service_property MemoryHigh 536870912
assert_service_property MemoryMax 1073741824
assert_service_property TasksMax 64
assert_service_property RuntimeMaxUSec 6h
assert_service_property TimeoutStopUSec 2min
service_exec_start=$(systemctl show "$SERVICE_UNIT" -p ExecStart --value)
[[ "$service_exec_start" == *"$INSTALL_DIR/bin/file-backup-service.sh"* ]] || die "$SERVICE_UNIT does not use the foreground cgroup-preserving launcher"
log "The live systemd manager accepted the file-backup cgroup, accounting, timeout, and no-restart properties."

write_service_environment() {
    local mode="$1"
    local config_dir="${2:-$CONFIG_DIR}"
    local use_project_filter="${3:-1}"
    local temp_environment

    install -d -m 755 /run/backup-suite
    temp_environment=$(mktemp /run/backup-suite/file-backup.env.XXXXXX)
    printf 'BACKUP_SUITE_FILE_BACKUP_MODE=%s\nBACKUP_SUITE_CONFIG_DIR=%s\n' "$mode" "$config_dir" > "$temp_environment"
    if [ "$use_project_filter" -eq 1 ] && [ ${#MIGRATION_PROJECTS[@]} -gt 0 ]; then
        printf 'BACKUP_SUITE_PROJECT_FILTER_FILE=%s\n' "$PROJECT_FILTER_FILE" >> "$temp_environment"
    fi
    chmod 600 "$temp_environment"
    mv -f "$temp_environment" "$CONTROL_ENV_FILE"
}

run_file_backup_service() {
    local label="$1"
    local mode="$2"
    local config_dir="${3:-$CONFIG_DIR}"
    local expected_result="${4:-success}"
    local use_project_filter="${5:-1}"
    local active_state
    local tasks_current
    local tasks_peak=0
    local cpu_current=0
    local cpu_previous=0
    local cpu_peak_percent=0
    local sample_time_ns=0
    local previous_sample_time_ns=0
    local elapsed_sample_ns=0
    local io_read_current=0
    local io_read_previous=0
    local io_read_peak_bps=0
    local io_write_current=0
    local io_write_previous=0
    local io_write_peak_bps=0
    local memory_current=0
    local memory_peak=0
    local io_read_total
    local io_write_total
    local result

    write_service_environment "$mode" "$config_dir" "$use_project_filter"
    systemctl reset-failed "$SERVICE_UNIT" >/dev/null 2>&1 || true
    printf '\n[%s] started_at=%s\n' "$label" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$RESOURCE_REPORT"
    systemctl start --no-block "$SERVICE_UNIT"

    while true; do
        active_state=$(systemctl show "$SERVICE_UNIT" -p ActiveState --value)
        tasks_current=$(systemctl show "$SERVICE_UNIT" -p TasksCurrent --value)
        if [[ "$tasks_current" =~ ^[0-9]+$ ]] && [ "$tasks_current" -gt "$tasks_peak" ]; then
            tasks_peak="$tasks_current"
        fi
        cpu_current=$(systemctl show "$SERVICE_UNIT" -p CPUUsageNSec --value)
        memory_current=$(systemctl show "$SERVICE_UNIT" -p MemoryCurrent --value)
        io_read_current=$(systemctl show "$SERVICE_UNIT" -p IOReadBytes --value)
        io_write_current=$(systemctl show "$SERVICE_UNIT" -p IOWriteBytes --value)
        sample_time_ns=$(date +%s%N)
        if [[ "$memory_current" =~ ^[0-9]+$ ]] && [ "$memory_current" -gt "$memory_peak" ]; then
            memory_peak="$memory_current"
        fi
        if [ "$previous_sample_time_ns" -gt 0 ]; then
            elapsed_sample_ns=$((sample_time_ns - previous_sample_time_ns))
            if [ "$elapsed_sample_ns" -gt 0 ]; then
                if [[ "$cpu_current" =~ ^[0-9]+$ ]] && [ "$cpu_previous" -gt 0 ] && [ "$cpu_current" -ge "$cpu_previous" ] && [ $(( (cpu_current - cpu_previous) * 100 / elapsed_sample_ns )) -gt "$cpu_peak_percent" ]; then
                    cpu_peak_percent=$(( (cpu_current - cpu_previous) * 100 / elapsed_sample_ns ))
                fi
                if [[ "$io_read_current" =~ ^[0-9]+$ ]] && [ "$io_read_previous" -gt 0 ] && [ "$io_read_current" -ge "$io_read_previous" ] && [ $(( (io_read_current - io_read_previous) * 1000000000 / elapsed_sample_ns )) -gt "$io_read_peak_bps" ]; then
                    io_read_peak_bps=$(( (io_read_current - io_read_previous) * 1000000000 / elapsed_sample_ns ))
                fi
                if [[ "$io_write_current" =~ ^[0-9]+$ ]] && [ "$io_write_previous" -gt 0 ] && [ "$io_write_current" -ge "$io_write_previous" ] && [ $(( (io_write_current - io_write_previous) * 1000000000 / elapsed_sample_ns )) -gt "$io_write_peak_bps" ]; then
                    io_write_peak_bps=$(( (io_write_current - io_write_previous) * 1000000000 / elapsed_sample_ns ))
                fi
            fi
        fi
        [[ "$cpu_current" =~ ^[0-9]+$ ]] && cpu_previous="$cpu_current"
        [[ "$io_read_current" =~ ^[0-9]+$ ]] && io_read_previous="$io_read_current"
        [[ "$io_write_current" =~ ^[0-9]+$ ]] && io_write_previous="$io_write_current"
        previous_sample_time_ns="$sample_time_ns"
        if [ "$active_state" = "activating" ] || [ "$active_state" = "active" ]; then
            systemd-cgls --unit "$SERVICE_UNIT" --no-pager >> "$RESOURCE_REPORT" 2>&1 || true
            sleep 1
            continue
        fi
        break
    done

    rm -f "$CONTROL_ENV_FILE"
    systemctl show "$SERVICE_UNIT" \
        -p Result -p ExecMainStatus -p CPUUsageNSec -p MemoryPeak \
        -p IOReadBytes -p IOWriteBytes -p TasksCurrent -p NRestarts \
        -p ControlGroup >> "$RESOURCE_REPORT"
    printf 'TasksPeakObserved=%s\nMemoryPeakBytesObserved=%s\n' "$tasks_peak" "$memory_peak" >> "$RESOURCE_REPORT"
    printf 'CPUPeakPercentObserved=%s\nIOReadPeakBytesPerSecObserved=%s\nIOWritePeakBytesPerSecObserved=%s\n' \
        "$cpu_peak_percent" "$io_read_peak_bps" "$io_write_peak_bps" >> "$RESOURCE_REPORT"
    result=$(systemctl show "$SERVICE_UNIT" -p Result --value)
    io_read_total=$(systemctl show "$SERVICE_UNIT" -p IOReadBytes --value)
    io_write_total=$(systemctl show "$SERVICE_UNIT" -p IOWriteBytes --value)
    [[ "$io_read_total" =~ ^[0-9]+$ ]] || io_read_total="$io_read_previous"
    [[ "$io_write_total" =~ ^[0-9]+$ ]] || io_write_total="$io_write_previous"
    log "Resource result [$label]: result=$result cpu_peak=${cpu_peak_percent}% memory_peak=${memory_peak}B io_read_peak=${io_read_peak_bps}B/s io_write_peak=${io_write_peak_bps}B/s io_read_total=${io_read_total}B io_write_total=${io_write_total}B tasks_peak=$tasks_peak; details=$RESOURCE_REPORT"

    if [ "$expected_result" = "success" ]; then
        [ "$result" = "success" ]
    else
        [ "$result" != "success" ]
    fi
}

install -d -m 700 "$STATE_DIR/migration-reports"
install -d -m 700 "$STATE_DIR/validation"
PROJECT_FILTER_FILE="$STATE_DIR/validation/${RUN_ID}-project-filter"
if [ ${#MIGRATION_PROJECTS[@]} -gt 0 ]; then
    printf '%s\n' "${MIGRATION_PROJECTS[@]}" > "$PROJECT_FILTER_FILE"
    chmod 600 "$PROJECT_FILTER_FILE"
    log "Explicit migration retry filter: ${MIGRATION_PROJECTS[*]}"
fi
RESOURCE_REPORT="$STATE_DIR/validation/${RUN_ID}-resource-report.txt"
: > "$RESOURCE_REPORT"
chmod 600 "$RESOURCE_REPORT"
RUN_STARTED_MARKER=$(mktemp "$STATE_DIR/.migration-report-start.XXXXXX")
log "Running the no-change production link-migration report under resource limits."
run_file_backup_service "link-migration-report" link-migration-report

mapfile -t report_files < <(find "$STATE_DIR/migration-reports" -maxdepth 1 -type f -name '*.txt' -newer "$RUN_STARTED_MARKER" -print | sort)
if [ ${#report_files[@]} -eq 0 ]; then
    mapfile -t report_files < <(find "$STATE_DIR/migration-reports" -maxdepth 1 -type f -name '*.txt' -print | sort)
    [ ${#report_files[@]} -gt 0 ] || die "Migration report run produced no reports and no earlier reports are available"
    log "All applicable projects were already confirmed; reusing ${#report_files[@]} retained migration reports for restore selection."
fi

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
run_file_backup_service "confirm-link-migration" confirm-link-migration

select_restore_report() {
    local report_file
    local report_symlinks
    local destination
    local size_json
    local destination_bytes
    local selected_file=""
    local selected_destination=""
    local selected_size=0
    local restore_report_files=()

    mapfile -t restore_report_files < <(find "$STATE_DIR/migration-reports" -maxdepth 1 -type f -name '*.txt' -print | sort)
    for report_file in "${restore_report_files[@]}"; do
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

validate_failed_sync_isolation() {
    local validation_config
    local validation_state
    local notification_marker
    local notification_unit="backup-suite-notify@file-backup.service.service"
    local notification_wait=0
    local notification_count
    local first_invocation
    local second_invocation
    local active_state
    local child_pid

    VALIDATION_DIR=$(mktemp -d "$STATE_DIR/validation/${RUN_ID}-failed-sync.XXXXXX")
    chmod 700 "$VALIDATION_DIR"
    validation_config="$VALIDATION_DIR/config"
    validation_state="$VALIDATION_DIR/state"
    install -d -m 700 "$validation_config" "$validation_state" "$VALIDATION_DIR/source" "$VALIDATION_DIR/fake-state"
    printf 'validation payload\n' > "$VALIDATION_DIR/source/stable.txt"
    : > "$validation_config/rclone.conf"
    : > "$validation_config/database-backups.conf"

    cp -a "$(readlink -f "$GLOBAL_CONFIG")" "$validation_config/global.conf"
    cat >> "$validation_config/global.conf" <<EOF
SYSTEM_CONFIG_DIR="$validation_config"
SYSTEM_STATE_DIR="$validation_state"
SYSTEM_RCLONE_CONFIG_PATH="$validation_config/rclone.conf"
SYSTEM_RCLONE_BIN="$VALIDATION_DIR/fake-rclone.sh"
SYSTEM_FILE_SOURCE_CONFIG_PATH="$validation_config/file-sources.conf"
SYSTEM_DATABASE_BACKUP_CONFIG_PATH="$validation_config/database-backups.conf"
SYSTEM_MYSQL_PROFILE_DIR="$validation_config"
RCLONE_REMOTE_ROOT="validation:"
INCLUDE_HOSTNAME_IN_REMOTE="0"
FILE_PROCESS_CHECK_ENABLED="0"
FILE_STABILITY_INTERVAL_SECONDS="0"
FILE_RCLONE_EXTRA_FLAGS=""
EOF
    printf '1|failed-sync-validation|%s|fixed|validation|.nosync|single\n' "$VALIDATION_DIR/source" > "$validation_config/file-sources.conf"

    cat > "$VALIDATION_DIR/fake-rclone.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
state_dir="$(cd -- "$(dirname -- "$0")" && pwd)/fake-state"
command_name="${1:-}"
shift || true
printf '%s\n' "$(< /proc/self/cgroup)" >> "$state_dir/rclone-cgroups.log"
case "$command_name" in
    lsf)
        if printf '%s\n' "$*" | grep -q -- '--format pst'; then
            printf 'stable.txt|19|2026-01-01T00:00:00Z\n'
        elif [[ "${1:-}" == /* ]]; then
            printf 'stable.txt\n'
        fi
        ;;
    sync)
        bash -c 'exec -a rclone-validation-child sleep 300' &
        child_pid=$!
        printf '%s\n' "$child_pid" >> "$state_dir/child-pids"
        printf '%s\n' "$(< "/proc/$child_pid/cgroup")" >> "$state_dir/child-cgroups.log"
        echo 'intentional failed-sync validation' >&2
        exit 23
        ;;
    delete)
        ;;
    *)
        echo "unexpected validation rclone command: $command_name" >&2
        exit 64
        ;;
esac
EOF
    chmod 700 "$VALIDATION_DIR/fake-rclone.sh"
    notification_marker=$(mktemp "$STATE_DIR/validation/.notification-start.XXXXXX")
    log "Running one intentional failed sync inside $SERVICE_UNIT; the configured OnFailure path should send exactly one notification."
    run_file_backup_service "intentional-failed-sync" normal "$validation_config" failure 0

    while [ "$notification_wait" -lt 120 ]; do
        active_state=$(systemctl show "$notification_unit" -p ActiveState --value 2>/dev/null || true)
        notification_count=$(find "$STATE_DIR/failures" -maxdepth 1 -type f -name '*file-backup.service.log' -newer "$notification_marker" -print 2>/dev/null | wc -l)
        if [ "$notification_count" -ge 1 ] && [ "$active_state" != "activating" ] && [ "$active_state" != "active" ]; then
            break
        fi
        sleep 1
        notification_wait=$((notification_wait + 1))
    done

    notification_count=$(find "$STATE_DIR/failures" -maxdepth 1 -type f -name '*file-backup.service.log' -newer "$notification_marker" -print 2>/dev/null | wc -l)
    [ "$notification_count" -eq 1 ] || die "Expected exactly one failed-sync notification record; found $notification_count"
    [ "$(systemctl show "$notification_unit" -p Result --value)" = "success" ] || die "The single failed-sync notification did not complete successfully"
    grep -Fq '/file-backup.service' "$VALIDATION_DIR/fake-state/rclone-cgroups.log" || die "Validation rclone did not run in the file-backup.service cgroup"
    grep -Fq '/file-backup.service' "$VALIDATION_DIR/fake-state/child-cgroups.log" || die "Validation rclone child escaped the file-backup.service cgroup"

    while IFS= read -r child_pid; do
        if kill -0 "$child_pid" 2>/dev/null; then
            die "Failed-sync validation left rclone child PID $child_pid running"
        fi
    done < "$VALIDATION_DIR/fake-state/child-pids"

    [ "$(systemctl show "$SERVICE_UNIT" -p NRestarts --value)" = "0" ] || die "$SERVICE_UNIT restarted after the failed sync"
    first_invocation=$(systemctl show "$SERVICE_UNIT" -p InvocationID --value)
    sleep 5
    second_invocation=$(systemctl show "$SERVICE_UNIT" -p InvocationID --value)
    active_state=$(systemctl show "$SERVICE_UNIT" -p ActiveState --value)
    [ "$first_invocation" = "$second_invocation" ] || die "A new backup invocation started immediately after the failed sync"
    [ "$active_state" != "active" ] && [ "$active_state" != "activating" ] || die "$SERVICE_UNIT relaunched after the failed sync"

    printf '\n[failed-sync-proof]\nnotification_records=%s\nnotification_result=success\nrclone_children_remaining=0\nservice_restarts=0\nimmediate_relaunch=0\n' \
        "$notification_count" >> "$RESOURCE_REPORT"
    rm -f "$notification_marker"
    rm -rf "$VALIDATION_DIR/config" "$VALIDATION_DIR/source"
    log "Failed-sync proof passed: one notification, no remaining rclone children, no restart, and no immediate relaunch."
}

validate_failed_sync_isolation
systemctl reset-failed "$SERVICE_UNIT"

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
log "Cgroup and peak resource report: $RESOURCE_REPORT"
