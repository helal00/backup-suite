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
            -h|--help)
                cat <<'EOF'
Supported runtime options:
    --verbose       show live console output for manual runs with aggregate rclone progress stats
  --journal-only  force journal-only logging
  -h, --help      show this help
EOF
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
