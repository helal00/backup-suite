#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALL_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
if [ -z "${BACKUP_SUITE_CONFIG_DIR:-}" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        BACKUP_SUITE_CONFIG_DIR="/etc/backup-suite"
    else
        BACKUP_SUITE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/backup-suite"
    fi
fi
GLOBAL_CONFIG_FILE="$BACKUP_SUITE_CONFIG_DIR/global.conf"

BACKUP_SUITE_LOG_MODE="${BACKUP_SUITE_LOG_MODE:-journal}"
BACKUP_SUITE_RCLONE_VERBOSE="${BACKUP_SUITE_RCLONE_VERBOSE:-0}"
BACKUP_SUITE_LINK_MIGRATION_REPORT="${BACKUP_SUITE_LINK_MIGRATION_REPORT:-0}"
BACKUP_SUITE_CONFIRM_LINK_MIGRATION="${BACKUP_SUITE_CONFIRM_LINK_MIGRATION:-0}"

if [ -z "${HOME:-}" ]; then
    HOME=$(getent passwd "$(id -u)" | cut -d: -f6)
    export HOME
fi

: "${XDG_CONFIG_HOME:=$HOME/.config}"
: "${XDG_STATE_HOME:=$HOME/.local/state}"
export XDG_CONFIG_HOME XDG_STATE_HOME

trim() {
    local value="$1"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    printf '%s' "$value"
}

strip_slashes() {
    local value="$1"
    value="${value#/}"
    value="${value%/}"
    printf '%s' "$value"
}

fail() {
    echo "$1" >&2
    exit 1
}

require_file() {
    local file_path="$1"
    [ -f "$file_path" ] || fail "Required file not found: $file_path"
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || fail "Required command not found in PATH: $command_name"
}

require_executable_spec() {
    local executable_spec="$1"

    if [[ "$executable_spec" == */* ]]; then
        [ -x "$executable_spec" ] || fail "Required executable is not present or not executable: $executable_spec"
    else
        command -v "$executable_spec" >/dev/null 2>&1 || fail "Required command not found in PATH: $executable_spec"
    fi
}

require_rclone_bin() {
    if [[ "$RCLONE_BIN" == */* ]]; then
        [ -x "$RCLONE_BIN" ] || fail "rclone was not found via RCLONE_BIN='$RCLONE_BIN'. Install rclone first and review the Backup Suite README for user-mode installation instructions."
    else
        command -v "$RCLONE_BIN" >/dev/null 2>&1 || fail "rclone was not found via RCLONE_BIN='$RCLONE_BIN'. Install rclone first and review the Backup Suite README for user-mode installation instructions."
    fi
}

acquire_backup_lock() {
    local lock_name="$1"
    local display_name="${2:-$1}"
    local lock_dir
    local lock_file

    require_command flock

    lock_dir=$(join_path "$STATE_DIR" "locks")
    mkdir -p "$lock_dir"
    lock_file=$(join_path "$lock_dir" "${lock_name}.lock")

    exec {BACKUP_SUITE_LOCK_FD}>"$lock_file"
    if ! flock -n "$BACKUP_SUITE_LOCK_FD"; then
        echo "Another ${display_name} run is already in progress. Exiting."
        exit 0
    fi
}

join_path() {
    local result=""
    local absolute_prefix=""
    local part

    if [ "$#" -gt 0 ] && [[ "$1" == /* ]]; then
        absolute_prefix="/"
    fi

    for part in "$@"; do
        part=$(strip_slashes "$part")
        [ -z "$part" ] && continue
        if [ -z "$result" ]; then
            result="$part"
        else
            result="$result/$part"
        fi
    done

    printf '%s' "$absolute_prefix$result"
}

parse_standard_runtime_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --verbose)
                BACKUP_SUITE_LOG_MODE="tee"
                BACKUP_SUITE_RCLONE_VERBOSE=1
                ;;
            --journal-only)
                BACKUP_SUITE_LOG_MODE="journal"
                BACKUP_SUITE_RCLONE_VERBOSE=0
                ;;
            --link-migration-report)
                if [ "${BACKUP_SUITE_RUNTIME_SCOPE:-}" != "file-backup" ]; then
                    echo "Unknown option: $1" >&2
                    exit 1
                fi
                BACKUP_SUITE_LINK_MIGRATION_REPORT=1
                ;;
            --confirm-link-migration)
                if [ "${BACKUP_SUITE_RUNTIME_SCOPE:-}" != "file-backup" ]; then
                    echo "Unknown option: $1" >&2
                    exit 1
                fi
                BACKUP_SUITE_CONFIRM_LINK_MIGRATION=1
                ;;
            -h|--help)
                cat <<'EOF'
Supported runtime options:
  --verbose       show live console output with aggregate rclone progress stats
  --journal-only  force journal-only logging
  -h, --help      show this help
EOF
                if [ "${BACKUP_SUITE_RUNTIME_SCOPE:-}" = "file-backup" ]; then
                    cat <<'EOF'
  --link-migration-report   write dry-run reports and make no remote changes
  --confirm-link-migration  apply a previously reported --links migration
EOF
                fi
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                exit 1
                ;;
        esac
        shift
    done
}

run_with_heartbeat() {
    local interval_seconds="$1"
    local heartbeat_message="$2"
    shift 2
    local command_pid
    local start_time
    local elapsed_seconds
    local command_status

    "$@" &
    command_pid=$!
    start_time=$(date +%s)

    while kill -0 "$command_pid" >/dev/null 2>&1; do
        sleep "$interval_seconds"
        if kill -0 "$command_pid" >/dev/null 2>&1; then
            elapsed_seconds=$(( $(date +%s) - start_time ))
            echo "$heartbeat_message (elapsed ${elapsed_seconds}s)"
        fi
    done

    wait "$command_pid"
    command_status=$?
    return "$command_status"
}

setup_journal_logging() {
    local identifier="$1"
    case "${BACKUP_SUITE_LOG_MODE:-journal}" in
        journal)
            if command -v systemd-cat >/dev/null 2>&1; then
                exec > >(/usr/bin/systemd-cat --identifier="$identifier") 2>&1
            fi
            ;;
        tee)
            if command -v systemd-cat >/dev/null 2>&1; then
                exec > >(tee >(/usr/bin/systemd-cat --identifier="$identifier")) 2>&1
            fi
            ;;
        console)
            ;;
        *)
            fail "Unsupported BACKUP_SUITE_LOG_MODE: ${BACKUP_SUITE_LOG_MODE}"
            ;;
    esac
}

setup_durable_logging() {
    local identifier="$1"
    local log_dir
    local log_file
    local max_bytes="${BACKUP_SUITE_LOG_MAX_BYTES:-10485760}"
    local keep_files="${BACKUP_SUITE_LOG_KEEP_FILES:-10}"
    local current_bytes=0
    local rotation_count
    local index

    [[ "$max_bytes" =~ ^[0-9]+$ ]] || fail "BACKUP_SUITE_LOG_MAX_BYTES must be a non-negative integer"
    [[ "$keep_files" =~ ^[0-9]+$ ]] || fail "BACKUP_SUITE_LOG_KEEP_FILES must be a positive integer"
    [ "$keep_files" -gt 0 ] || fail "BACKUP_SUITE_LOG_KEEP_FILES must be greater than zero"

    log_dir=$(join_path "$STATE_DIR" "logs")
    log_file=$(join_path "$log_dir" "${identifier}.log")
    mkdir -p "$log_dir"
    chmod 750 "$log_dir"

    if [ -f "$log_file" ]; then
        current_bytes=$(wc -c < "$log_file")
    fi

    if [ "$max_bytes" -gt 0 ] && [ "$current_bytes" -ge "$max_bytes" ]; then
        rotation_count=$((keep_files - 1))
        if [ "$rotation_count" -eq 0 ]; then
            : > "$log_file"
        else
            rm -f "${log_file}.${rotation_count}"
            for ((index=rotation_count - 1; index>=1; index--)); do
                if [ -f "${log_file}.${index}" ]; then
                    mv "${log_file}.${index}" "${log_file}.$((index + 1))"
                fi
            done
            mv "$log_file" "${log_file}.1"
        fi
    fi

    touch "$log_file"
    chmod 640 "$log_file"
    exec > >(tee -a "$log_file") 2>&1
    echo "Durable log: $log_file"
}

load_global_config() {
    require_file "$GLOBAL_CONFIG_FILE"
    # shellcheck source=/dev/null
    . "$GLOBAL_CONFIG_FILE"

    resolve_effective_config

    : "${RCLONE_CONFIG_PATH:?RCLONE_CONFIG_PATH must be set in $GLOBAL_CONFIG_FILE}"
    : "${RCLONE_REMOTE_ROOT:?RCLONE_REMOTE_ROOT must be set in $GLOBAL_CONFIG_FILE}"
    : "${FILE_SOURCE_CONFIG_PATH:?FILE_SOURCE_CONFIG_PATH must be set in $GLOBAL_CONFIG_FILE}"
    : "${DATABASE_BACKUP_CONFIG_PATH:?DATABASE_BACKUP_CONFIG_PATH must be set in $GLOBAL_CONFIG_FILE}"
    : "${MYSQL_PROFILE_DIR:?MYSQL_PROFILE_DIR must be set in $GLOBAL_CONFIG_FILE}"
    : "${RCLONE_BIN:?RCLONE_BIN must be set in $GLOBAL_CONFIG_FILE}"
}

resolve_effective_config() {
    local requested_mode
    requested_mode="${INSTALL_MODE:-auto}"

    case "$requested_mode" in
        auto)
            if [ "$(id -u)" -eq 0 ]; then
                EFFECTIVE_INSTALL_MODE="system"
            else
                EFFECTIVE_INSTALL_MODE="user"
            fi
            ;;
        user|system)
            EFFECTIVE_INSTALL_MODE="$requested_mode"
            ;;
        *)
            fail "Unsupported INSTALL_MODE: $requested_mode"
            ;;
    esac

    if [ "$EFFECTIVE_INSTALL_MODE" = "system" ]; then
        INSTALL_DIR="${SYSTEM_INSTALL_DIR:-${INSTALL_DIR:-/opt/backup-suite}}"
        CONFIG_DIR="${SYSTEM_CONFIG_DIR:-${CONFIG_DIR:-/etc/backup-suite}}"
        STATE_DIR="${SYSTEM_STATE_DIR:-${STATE_DIR:-/var/lib/backup-suite}}"
        DB_LOCAL_OUTPUT_DIR="${SYSTEM_DB_LOCAL_OUTPUT_DIR:-${DB_LOCAL_OUTPUT_DIR:-/var/backups/backup-suite/databases}}"
        RCLONE_CONFIG_PATH="${SYSTEM_RCLONE_CONFIG_PATH:-${RCLONE_CONFIG_PATH:-/etc/backup-suite/rclone.conf}}"
        RCLONE_BIN="${SYSTEM_RCLONE_BIN:-${RCLONE_BIN:-rclone}}"
        FILE_SOURCE_CONFIG_PATH="${SYSTEM_FILE_SOURCE_CONFIG_PATH:-${FILE_SOURCE_CONFIG_PATH:-$CONFIG_DIR/file-sources.conf}}"
        DATABASE_BACKUP_CONFIG_PATH="${SYSTEM_DATABASE_BACKUP_CONFIG_PATH:-${DATABASE_BACKUP_CONFIG_PATH:-$CONFIG_DIR/database-backups.conf}}"
        MYSQL_PROFILE_DIR="${SYSTEM_MYSQL_PROFILE_DIR:-${MYSQL_PROFILE_DIR:-$CONFIG_DIR/mysql-profiles}}"
        SYSTEMD_UNIT_DIR="${SYSTEM_SYSTEMD_UNIT_DIR:-/etc/systemd/system}"
        SYSTEMCTL_COMMAND=(systemctl)
        SYSTEMD_SCOPE="system"
        SYSTEM_CANONICAL_SOURCE_DIR="${SYSTEM_CANONICAL_SOURCE_DIR:-/opt/backup-suite-src}"
    else
        INSTALL_DIR="${USER_INSTALL_DIR:-$HOME/.local/share/backup-suite}"
        CONFIG_DIR="${USER_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/backup-suite}"
        STATE_DIR="${USER_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/backup-suite}"
        DB_LOCAL_OUTPUT_DIR="${USER_DB_LOCAL_OUTPUT_DIR:-$HOME/backups/backup-suite/databases}"
        RCLONE_CONFIG_PATH="${USER_RCLONE_CONFIG_PATH:-${XDG_CONFIG_HOME:-$HOME/.config}/rclone/rclone.conf}"
        RCLONE_BIN="${USER_RCLONE_BIN:-${RCLONE_BIN:-rclone}}"
        FILE_SOURCE_CONFIG_PATH="${USER_FILE_SOURCE_CONFIG_PATH:-$CONFIG_DIR/file-sources.conf}"
        DATABASE_BACKUP_CONFIG_PATH="${USER_DATABASE_BACKUP_CONFIG_PATH:-$CONFIG_DIR/database-backups.conf}"
        MYSQL_PROFILE_DIR="${USER_MYSQL_PROFILE_DIR:-$CONFIG_DIR/mysql-profiles}"
        BACKUP_RUNNER_USER="$(id -un)"
        BACKUP_RUNNER_GROUP="$(id -gn)"
        BACKUP_RUNNER_HOME="$HOME"
        SYSTEMD_UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        SYSTEMCTL_COMMAND=(systemctl --user)
        SYSTEMD_SCOPE="user"
    fi
}

resolve_mysql_profile_file() {
    local profile_name="$1"

    [ -n "$profile_name" ] || profile_name="default"
    printf '%s/%s.cnf' "$MYSQL_PROFILE_DIR" "$profile_name"
}

remote_base_root() {
    local base_root
    local remote_hostname

    base_root=$(strip_slashes "$RCLONE_REMOTE_ROOT")
    remote_hostname=$(trim "${REMOTE_HOSTNAME:-}")

    if [ "${INCLUDE_HOSTNAME_IN_REMOTE:-1}" = "1" ]; then
        if [ -z "$remote_hostname" ]; then
            remote_hostname=$(hostname)
        fi
        printf '%s/%s' "$base_root" "$remote_hostname"
    else
        printf '%s' "$base_root"
    fi
}

is_enabled_value() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

size_to_bytes() {
    # Converts systemd-style sizes (512M, 1G, 2048K, 1073741824) to bytes.
    # Prints nothing for "infinity", "max", or an empty value.
    local value
    local number
    local suffix

    value=$(trim "${1:-}")
    case "$value" in
        ""|infinity|max) return 0 ;;
    esac
    [[ "$value" =~ ^([0-9]+)([KkMmGgTt]?)$ ]] || fail "Unsupported size value: $value"
    number="${BASH_REMATCH[1]}"
    suffix="${BASH_REMATCH[2]}"
    case "$suffix" in
        K|k) number=$((number * 1024)) ;;
        M|m) number=$((number * 1024 * 1024)) ;;
        G|g) number=$((number * 1024 * 1024 * 1024)) ;;
        T|t) number=$((number * 1024 * 1024 * 1024 * 1024)) ;;
    esac
    printf '%s' "$number"
}

FILE_BACKUP_PROFILE_NAMES=(slow moderate fast)

resolve_file_backup_profile() {
    # Resolves the resource profile for file backups into PROFILE_* variables.
    # "custom" keeps the explicit FILE_RCLONE_* and FILE_CUSTOM_* settings, which
    # is also the behavior for configurations written before profiles existed.
    local requested

    requested=$(trim "${1:-${FILE_BACKUP_PROFILE:-custom}}")
    requested="${requested,,}"

    case "$requested" in
        slow)
            PROFILE_SUMMARY="Lowest server impact; a full pass takes about 2-3x longer than moderate."
            PROFILE_CPU_QUOTA="25%"
            PROFILE_CPU_WEIGHT="5"
            PROFILE_IO_WEIGHT="5"
            PROFILE_NICE="19"
            PROFILE_IO_SCHEDULING_CLASS="idle"
            PROFILE_MEMORY_HIGH="256M"
            PROFILE_MEMORY_MAX="512M"
            PROFILE_MEMORY_SWAP_MAX="128M"
            PROFILE_TASKS_MAX="32"
            PROFILE_RCLONE_TRANSFERS="1"
            PROFILE_RCLONE_CHECKERS="2"
            PROFILE_RCLONE_BUFFER_SIZE="8M"
            PROFILE_RCLONE_TPSLIMIT="4"
            PROFILE_RCLONE_BWLIMIT="4M"
            ;;
        moderate)
            PROFILE_SUMMARY="Balanced default; matches the limits validated in production in September 2026."
            PROFILE_CPU_QUOTA="50%"
            PROFILE_CPU_WEIGHT="10"
            PROFILE_IO_WEIGHT="10"
            PROFILE_NICE="15"
            PROFILE_IO_SCHEDULING_CLASS="idle"
            PROFILE_MEMORY_HIGH="512M"
            PROFILE_MEMORY_MAX="1G"
            PROFILE_MEMORY_SWAP_MAX="256M"
            PROFILE_TASKS_MAX="64"
            PROFILE_RCLONE_TRANSFERS="2"
            PROFILE_RCLONE_CHECKERS="4"
            PROFILE_RCLONE_BUFFER_SIZE="16M"
            PROFILE_RCLONE_TPSLIMIT="10"
            PROFILE_RCLONE_BWLIMIT=""
            ;;
        fast)
            PROFILE_SUMMARY="Quickest backups; a full pass takes about 0.5-0.7x the moderate time, with noticeably more load."
            PROFILE_CPU_QUOTA="100%"
            PROFILE_CPU_WEIGHT="50"
            PROFILE_IO_WEIGHT="50"
            PROFILE_NICE="10"
            PROFILE_IO_SCHEDULING_CLASS="best-effort"
            PROFILE_MEMORY_HIGH="1G"
            PROFILE_MEMORY_MAX="2G"
            PROFILE_MEMORY_SWAP_MAX="512M"
            PROFILE_TASKS_MAX="128"
            PROFILE_RCLONE_TRANSFERS="4"
            PROFILE_RCLONE_CHECKERS="8"
            PROFILE_RCLONE_BUFFER_SIZE="32M"
            PROFILE_RCLONE_TPSLIMIT="20"
            PROFILE_RCLONE_BWLIMIT=""
            ;;
        custom)
            PROFILE_SUMMARY="Custom limits from FILE_CUSTOM_* and FILE_RCLONE_* settings."
            PROFILE_CPU_QUOTA="${FILE_CUSTOM_CPU_QUOTA:-50%}"
            PROFILE_CPU_WEIGHT="${FILE_CUSTOM_CPU_WEIGHT:-10}"
            PROFILE_IO_WEIGHT="${FILE_CUSTOM_IO_WEIGHT:-10}"
            PROFILE_NICE="${FILE_CUSTOM_NICE:-15}"
            PROFILE_IO_SCHEDULING_CLASS="${FILE_CUSTOM_IO_SCHEDULING_CLASS:-idle}"
            PROFILE_MEMORY_HIGH="${FILE_CUSTOM_MEMORY_HIGH:-512M}"
            PROFILE_MEMORY_MAX="${FILE_CUSTOM_MEMORY_MAX:-1G}"
            PROFILE_MEMORY_SWAP_MAX="${FILE_CUSTOM_MEMORY_SWAP_MAX:-256M}"
            PROFILE_TASKS_MAX="${FILE_CUSTOM_TASKS_MAX:-64}"
            PROFILE_RCLONE_TRANSFERS="${FILE_RCLONE_TRANSFERS:-2}"
            PROFILE_RCLONE_CHECKERS="${FILE_RCLONE_CHECKERS:-4}"
            PROFILE_RCLONE_BUFFER_SIZE="${FILE_RCLONE_BUFFER_SIZE:-16M}"
            PROFILE_RCLONE_TPSLIMIT="${FILE_RCLONE_TPSLIMIT:-10}"
            PROFILE_RCLONE_BWLIMIT="${FILE_RCLONE_BWLIMIT:-}"
            ;;
        *)
            fail "Unsupported FILE_BACKUP_PROFILE '$requested'. Use slow, moderate, fast, or custom."
            ;;
    esac

    PROFILE_LIMITS_SOURCE="built-in"
    PROFILE_OVERRIDDEN_KEYS=()
    if [ "$requested" != "custom" ]; then
        if [ "${FILE_PROFILE_LIMITS_MODE:-fixed}" = "auto" ]; then
            scale_profile_to_host "$requested"
            PROFILE_LIMITS_SOURCE="auto-scaled to this host"
        elif [ "${FILE_PROFILE_LIMITS_MODE:-fixed}" != "fixed" ]; then
            fail "FILE_PROFILE_LIMITS_MODE must be fixed or auto"
        fi
        apply_profile_overrides "$requested"
    fi

    [[ "$PROFILE_CPU_QUOTA" =~ ^[0-9]+%$ ]] || fail "Profile CPU quota must look like 50%: $PROFILE_CPU_QUOTA"
    [[ "$PROFILE_TASKS_MAX" =~ ^[0-9]+$ ]] || fail "Profile TasksMax must be an integer: $PROFILE_TASKS_MAX"
    [[ "$PROFILE_RCLONE_TRANSFERS" =~ ^[0-9]+$ ]] || fail "Profile rclone transfers must be an integer"
    [[ "$PROFILE_RCLONE_CHECKERS" =~ ^[0-9]+$ ]] || fail "Profile rclone checkers must be an integer"
    size_to_bytes "$PROFILE_MEMORY_HIGH" >/dev/null
    size_to_bytes "$PROFILE_MEMORY_MAX" >/dev/null
    size_to_bytes "$PROFILE_MEMORY_SWAP_MAX" >/dev/null
    PROFILE_NAME="$requested"
}

FILE_PROFILE_OVERRIDE_KEYS=(CPU_QUOTA CPU_WEIGHT IO_WEIGHT NICE IO_SCHEDULING_CLASS MEMORY_HIGH MEMORY_MAX MEMORY_SWAP_MAX TASKS_MAX RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_BUFFER_SIZE RCLONE_TPSLIMIT RCLONE_BWLIMIT)

host_memory_bytes() {
    awk '/^MemTotal:/ { printf "%d", $2 * 1024 }' "${BACKUP_SUITE_PROC_DIR:-/proc}/meminfo" 2>/dev/null || true
}

host_cpu_cores() {
    if [ -n "${BACKUP_SUITE_CPU_COUNT:-}" ]; then
        printf '%s' "$BACKUP_SUITE_CPU_COUNT"
    else
        nproc 2>/dev/null || printf '1'
    fi
}

scale_profile_to_host() {
    # FILE_PROFILE_LIMITS_MODE="auto": derive memory and CPU limits from this
    # host instead of the built-in table. A profile may use a fixed share of RAM
    # (slow 5%, moderate 10%, fast 20%) and of total CPU capacity (slow 3%,
    # moderate 6%, fast 12%).
    local profile_name="$1"
    local memory_percent
    local cpu_percent
    local total_bytes
    local cores
    local memory_max_mib
    local cpu_quota

    case "$profile_name" in
        slow) memory_percent=5; cpu_percent=3 ;;
        moderate) memory_percent=10; cpu_percent=6 ;;
        fast) memory_percent=20; cpu_percent=12 ;;
        *) return 0 ;;
    esac
    total_bytes=$(host_memory_bytes)
    cores=$(host_cpu_cores)
    [[ "$total_bytes" =~ ^[0-9]+$ ]] && [ "$total_bytes" -gt 0 ] || fail "Cannot read host memory for auto-scaled limits"
    [[ "$cores" =~ ^[0-9]+$ ]] && [ "$cores" -gt 0 ] || cores=1

    memory_max_mib=$(( total_bytes * memory_percent / 100 / 1048576 ))
    [ "$memory_max_mib" -ge 256 ] || memory_max_mib=256
    cpu_quota=$(( cores * cpu_percent ))
    [ "$cpu_quota" -ge 10 ] || cpu_quota=10
    [ "$cpu_quota" -le $((cores * 100)) ] || cpu_quota=$((cores * 100))

    PROFILE_MEMORY_MAX="${memory_max_mib}M"
    PROFILE_MEMORY_HIGH="$((memory_max_mib / 2))M"
    PROFILE_MEMORY_SWAP_MAX="$((memory_max_mib / 4))M"
    PROFILE_CPU_QUOTA="${cpu_quota}%"
}

apply_profile_overrides() {
    # Per-profile settings such as FILE_PROFILE_SLOW_MEMORY_MAX="384M" replace
    # the built-in or auto-scaled value. An empty value is honored (for
    # example FILE_PROFILE_SLOW_RCLONE_BWLIMIT="" means unlimited).
    local profile_name="$1"
    local key
    local variable_name

    PROFILE_OVERRIDDEN_KEYS=()
    for key in "${FILE_PROFILE_OVERRIDE_KEYS[@]}"; do
        variable_name="FILE_PROFILE_${profile_name^^}_${key}"
        if [ -n "${!variable_name+x}" ]; then
            printf -v "PROFILE_${key}" '%s' "${!variable_name}"
            PROFILE_OVERRIDDEN_KEYS+=("$key")
        fi
    done
}

file_profile_rank() {
    case "$1" in
        fast) printf '0' ;;
        moderate) printf '1' ;;
        slow) printf '2' ;;
        *) printf '-1' ;;
    esac
}

resolve_profile_ladder() {
    # Sets PROFILE_MODE and PROFILE_LADDER (top profile first). Fixed mode has a
    # single entry; adaptive mode steps from FILE_BACKUP_PROFILE down to
    # FILE_BACKUP_PROFILE_FLOOR and back.
    local top_profile
    local floor_profile
    local top_rank
    local floor_rank
    local rank
    local ordered=(fast moderate slow)

    top_profile=$(trim "${FILE_BACKUP_PROFILE:-custom}")
    top_profile="${top_profile,,}"
    PROFILE_MODE=$(trim "${FILE_BACKUP_PROFILE_MODE:-fixed}")
    PROFILE_MODE="${PROFILE_MODE,,}"
    case "$PROFILE_MODE" in
        fixed)
            PROFILE_LADDER=("$top_profile")
            return 0
            ;;
        adaptive) ;;
        *) fail "FILE_BACKUP_PROFILE_MODE must be fixed or adaptive" ;;
    esac

    floor_profile=$(trim "${FILE_BACKUP_PROFILE_FLOOR:-slow}")
    floor_profile="${floor_profile,,}"
    top_rank=$(file_profile_rank "$top_profile")
    floor_rank=$(file_profile_rank "$floor_profile")
    [ "$top_rank" -ge 0 ] || fail "Adaptive mode needs FILE_BACKUP_PROFILE to be fast, moderate, or slow (not $top_profile)"
    [ "$floor_rank" -ge 0 ] || fail "FILE_BACKUP_PROFILE_FLOOR must be fast, moderate, or slow"
    [ "$floor_rank" -ge "$top_rank" ] || fail "FILE_BACKUP_PROFILE_FLOOR ($floor_profile) must not be faster than FILE_BACKUP_PROFILE ($top_profile)"

    PROFILE_LADDER=()
    for ((rank = top_rank; rank <= floor_rank; rank++)); do
        PROFILE_LADDER+=("${ordered[$rank]}")
    done
}

adaptive_state_file() {
    join_path "$STATE_DIR" "watchdog" "adaptive-profile.state"
}

current_adaptive_profile() {
    # Prints the ladder profile the watchdog last selected, or the top profile.
    local state_file
    local level=""
    local entry

    resolve_profile_ladder
    state_file=$(adaptive_state_file)
    if [ "$PROFILE_MODE" = "adaptive" ] && [ -r "$state_file" ]; then
        level=$(sed -n 's/^level=//p' "$state_file" | head -n 1)
        for entry in "${PROFILE_LADDER[@]}"; do
            if [ "$entry" = "$level" ]; then
                printf '%s' "$level"
                return 0
            fi
        done
    fi
    printf '%s' "${PROFILE_LADDER[0]}"
}

render_file_backup_profile_dropin() {
    # Prints the systemd drop-in that applies the resolved profile limits.
    cat <<DROPIN
# Generated by Backup Suite (backup-profile.sh) for profile: $PROFILE_NAME
# $PROFILE_SUMMARY
# Change it with: backup-profile.sh set slow|moderate|fast
[Service]
CPUQuota=$PROFILE_CPU_QUOTA
CPUWeight=$PROFILE_CPU_WEIGHT
IOWeight=$PROFILE_IO_WEIGHT
Nice=$PROFILE_NICE
IOSchedulingClass=$PROFILE_IO_SCHEDULING_CLASS
MemoryHigh=$PROFILE_MEMORY_HIGH
MemoryMax=$PROFILE_MEMORY_MAX
MemorySwapMax=$PROFILE_MEMORY_SWAP_MAX
TasksMax=$PROFILE_TASKS_MAX
DROPIN
}
