#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

SERVICE_UNIT="file-backup.service"

usage() {
    cat <<'EOF'
Usage: backup-profile.sh [command]

Choose how much of the server the file backup may use.

Commands:
  show                       list the profiles, their limits, and the active setup
  choose                     interactive menu (default when run in a terminal)
  set <profile>              fixed mode: always use slow, moderate, fast, or custom
  adaptive <top> <floor>     adaptive mode: start at <top>; the watchdog steps
                             down toward <floor> when resources are tight and back
                             up when they are normal. Examples:
                               adaptive moderate slow     (2 steps)
                               adaptive fast slow         (3 steps)
  limits fixed|auto          built-in limits, or limits scaled to this host's RAM/CPU
  override <profile> <KEY> <value>
                             set one limit for one profile, for example
                               override slow MEMORY_MAX 384M
  override <profile> <KEY> --unset
                             remove that override
  apply                      re-apply the configured setup (systemd drop-in)
  current                    print the active setup
  print-dropin [profile]     print the systemd drop-in for a profile

Override keys: CPU_QUOTA CPU_WEIGHT IO_WEIGHT NICE IO_SCHEDULING_CLASS
MEMORY_HIGH MEMORY_MAX MEMORY_SWAP_MAX TASKS_MAX RCLONE_TRANSFERS
RCLONE_CHECKERS RCLONE_BUFFER_SIZE RCLONE_TPSLIMIT RCLONE_BWLIMIT

Changes apply to the next backup run. When a backup is running, its CPU,
memory, swap, and task limits are also changed immediately.
EOF
}

last_observed_for_profile() {
    # Prints the newest watchdog-recorded resource use for this profile.
    local profile_name="$1"
    local history_file

    history_file=$(join_path "$STATE_DIR" "watchdog" "history.tsv")
    [ -r "$history_file" ] || return 0
    awk -F '\t' -v wanted="$profile_name" '
        $4 == wanted { line = $0 }
        END {
            if (line == "") { exit }
            split(line, f, "\t")
            printf "last run: peak %d MiB RAM, avg %s%% CPU, %d min", f[6] / 1048576, f[9], f[5] / 60
        }
    ' "$history_file"
}

print_profile_row() {
    local profile_name="$1"
    local marker="${2:-}"
    local cpu_count
    local quota_number
    local bandwidth
    local observed

    resolve_file_backup_profile "$profile_name"
    cpu_count=$(host_cpu_cores)
    quota_number="${PROFILE_CPU_QUOTA%\%}"
    bandwidth="${PROFILE_RCLONE_BWLIMIT:-unlimited}"
    [ "$bandwidth" = "unlimited" ] || bandwidth="${bandwidth}B/s"

    printf '  %s%s\n' "$PROFILE_NAME" "$marker"
    printf '    %s\n' "$PROFILE_SUMMARY"
    printf '    CPU      : at most %s of one core (%s cores on this host = %s%% of total), nice %s\n' \
        "$PROFILE_CPU_QUOTA" "$cpu_count" "$((quota_number / cpu_count))" "$PROFILE_NICE"
    printf '    Memory   : throttled above %s, hard limit %s, swap limit %s\n' \
        "$PROFILE_MEMORY_HIGH" "$PROFILE_MEMORY_MAX" "$PROFILE_MEMORY_SWAP_MAX"
    printf '    Processes: at most %s tasks\n' "$PROFILE_TASKS_MAX"
    printf '    Disk I/O : scheduling class %s, weight %s\n' "$PROFILE_IO_SCHEDULING_CLASS" "$PROFILE_IO_WEIGHT"
    printf '    Network  : %s parallel uploads, %s checkers, %s buffer each, %s API calls/s, bandwidth %s\n' \
        "$PROFILE_RCLONE_TRANSFERS" "$PROFILE_RCLONE_CHECKERS" "$PROFILE_RCLONE_BUFFER_SIZE" \
        "$PROFILE_RCLONE_TPSLIMIT" "$bandwidth"
    if [ "$PROFILE_NAME" != "custom" ]; then
        printf '    Limits   : %s' "$PROFILE_LIMITS_SOURCE"
        if [ "${#PROFILE_OVERRIDDEN_KEYS[@]}" -gt 0 ]; then
            printf '; your overrides: %s' "${PROFILE_OVERRIDDEN_KEYS[*]}"
        fi
        printf '\n'
    fi
    observed=$(last_observed_for_profile "$PROFILE_NAME")
    if [ -n "$observed" ]; then
        printf '    Observed : %s\n' "$observed"
    fi
}

describe_setup() {
    local current_level

    resolve_profile_ladder
    if [ "$PROFILE_MODE" = "adaptive" ]; then
        current_level=$(current_adaptive_profile)
        printf 'adaptive %s (now: %s)\n' "$(IFS='>'; printf '%s' "${PROFILE_LADDER[*]}")" "$current_level"
    else
        printf 'fixed %s\n' "${PROFILE_LADDER[0]}"
    fi
}

show_profiles() {
    local profile_name
    local marker
    local entry
    local memory_bytes

    resolve_profile_ladder
    memory_bytes=$(host_memory_bytes)
    echo "Backup Suite file-backup resource profiles (host: $(host_cpu_cores) CPU cores, $(( ${memory_bytes:-0} / 1048576 )) MiB RAM)"
    echo "Limits mode: ${FILE_PROFILE_LIMITS_MODE:-fixed}. The watchdog contains or stops a backup that goes past its limits and reports it via ntfy."
    echo ""
    for profile_name in "${FILE_BACKUP_PROFILE_NAMES[@]}"; do
        marker=""
        for entry in "${PROFILE_LADDER[@]}"; do
            [ "$entry" = "$profile_name" ] && marker="   <- in use"
        done
        print_profile_row "$profile_name" "$marker"
        echo ""
    done
    if [ "${FILE_BACKUP_PROFILE:-custom}" = "custom" ]; then
        print_profile_row custom "   <- in use"
        echo ""
    fi
    echo "Active setup: $(describe_setup)"
    if [ "$PROFILE_MODE" = "adaptive" ]; then
        echo "The watchdog steps one level down when the backup or the server is short of resources, and one level up after ${WATCHDOG_ADAPTIVE_STEP_UP_SECONDS:-300}s of normal conditions."
    fi
}

set_config_value() {
    # Updates or appends KEY="value" in the global config, keeping the file's
    # inode, owner, and mode (the config is often a symlink to the source tree).
    local config_key="$1"
    local config_value="$2"
    local resolved_config
    local temp_file

    resolved_config=$(readlink -f "$GLOBAL_CONFIG_FILE")
    [ -w "$resolved_config" ] || fail "Cannot write $resolved_config. Run with sudo for a system install."
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
    cat "$temp_file" > "$resolved_config"
    rm -f "$temp_file"
}

remove_config_value() {
    local config_key="$1"
    local resolved_config
    local temp_file

    resolved_config=$(readlink -f "$GLOBAL_CONFIG_FILE")
    [ -w "$resolved_config" ] || fail "Cannot write $resolved_config. Run with sudo for a system install."
    temp_file=$(mktemp)
    awk -v key="$config_key" '$0 !~ "^" key "=" { print }' "$resolved_config" > "$temp_file"
    cat "$temp_file" > "$resolved_config"
    rm -f "$temp_file"
}

apply_live_limits() {
    # A running backup keeps the limits it started with. Write the new limits
    # straight into its cgroup so nothing persists beyond this run.
    local control_group
    local cgroup_dir
    local quota_number
    local value
    local current_memory=0

    "${SYSTEMCTL_COMMAND[@]}" is-active --quiet "$SERVICE_UNIT" 2>/dev/null || return 0
    control_group=$("${SYSTEMCTL_COMMAND[@]}" show "$SERVICE_UNIT" -p ControlGroup --value 2>/dev/null || true)
    [ -n "$control_group" ] || return 0
    cgroup_dir="${BACKUP_SUITE_CGROUP_ROOT:-/sys/fs/cgroup}$control_group"
    [ -d "$cgroup_dir" ] || return 0

    quota_number="${PROFILE_CPU_QUOTA%\%}"
    { printf '%s 100000\n' "$((quota_number * 1000))" > "$cgroup_dir/cpu.max"; } 2>/dev/null || true
    { printf '%s\n' "$PROFILE_CPU_WEIGHT" > "$cgroup_dir/cpu.weight"; } 2>/dev/null || true
    value=$(size_to_bytes "$PROFILE_MEMORY_HIGH")
    { printf '%s\n' "${value:-max}" > "$cgroup_dir/memory.high"; } 2>/dev/null || true
    value=$(size_to_bytes "$PROFILE_MEMORY_MAX")
    if [ -r "$cgroup_dir/memory.current" ]; then
        current_memory=$(cat "$cgroup_dir/memory.current" 2>/dev/null || echo 0)
    fi
    # Never set a hard limit below current use: the kernel would OOM-kill. The
    # watchdog tightens it later once usage has dropped.
    if [ -z "$value" ] || [ "$value" -gt "$((current_memory + 67108864))" ]; then
        { printf '%s\n' "${value:-max}" > "$cgroup_dir/memory.max"; } 2>/dev/null || true
    fi
    value=$(size_to_bytes "$PROFILE_MEMORY_SWAP_MAX")
    { printf '%s\n' "${value:-max}" > "$cgroup_dir/memory.swap.max"; } 2>/dev/null || true
    { printf '%s\n' "$PROFILE_TASKS_MAX" > "$cgroup_dir/pids.max"; } 2>/dev/null || true
    echo "Applied CPU, memory, swap, and task limits to the running backup."
}

apply_profile() {
    local dropin_dir
    local dropin_file
    local temp_file
    local live_profile

    resolve_profile_ladder
    resolve_file_backup_profile "${PROFILE_LADDER[0]}"
    dropin_dir=$(join_path "$SYSTEMD_UNIT_DIR" "${SERVICE_UNIT}.d")
    dropin_file=$(join_path "$dropin_dir" "50-backup-profile.conf")
    mkdir -p "$dropin_dir"
    temp_file=$(mktemp "$dropin_dir/.50-backup-profile.conf.XXXXXX")
    render_file_backup_profile_dropin > "$temp_file"
    chmod 644 "$temp_file"
    mv -f "$temp_file" "$dropin_file"
    echo "Wrote $dropin_file"

    if "${SYSTEMCTL_COMMAND[@]}" daemon-reload; then
        echo "systemd reloaded; setup '$(describe_setup)' applies from the next backup run."
    else
        echo "systemd daemon-reload failed; run it manually before the next backup." >&2
    fi

    # A running backup gets the level it should use now.
    live_profile=$(current_adaptive_profile)
    resolve_file_backup_profile "$live_profile"
    apply_live_limits
}

reset_adaptive_state() {
    rm -f "$(adaptive_state_file)" 2>/dev/null || true
}

set_profile() {
    local requested="${1:-}"

    [ -n "$requested" ] || fail "Usage: backup-profile.sh set slow|moderate|fast|custom"
    requested="${requested,,}"
    resolve_file_backup_profile "$requested"
    set_config_value FILE_BACKUP_PROFILE "$requested"
    set_config_value FILE_BACKUP_PROFILE_MODE fixed
    FILE_BACKUP_PROFILE="$requested"
    FILE_BACKUP_PROFILE_MODE="fixed"
    reset_adaptive_state
    echo "Fixed profile '$requested' saved in $(readlink -f "$GLOBAL_CONFIG_FILE")"
    apply_profile
}

set_adaptive() {
    local top_profile="${1:-}"
    local floor_profile="${2:-}"

    [ -n "$top_profile" ] && [ -n "$floor_profile" ] || fail "Usage: backup-profile.sh adaptive <top> <floor>, for example: adaptive moderate slow"
    FILE_BACKUP_PROFILE="${top_profile,,}"
    FILE_BACKUP_PROFILE_MODE="adaptive"
    FILE_BACKUP_PROFILE_FLOOR="${floor_profile,,}"
    resolve_profile_ladder
    [ "${#PROFILE_LADDER[@]}" -ge 2 ] || fail "Adaptive mode needs a floor slower than the top profile; use 'set ${FILE_BACKUP_PROFILE}' for a single profile."
    set_config_value FILE_BACKUP_PROFILE "$FILE_BACKUP_PROFILE"
    set_config_value FILE_BACKUP_PROFILE_MODE adaptive
    set_config_value FILE_BACKUP_PROFILE_FLOOR "$FILE_BACKUP_PROFILE_FLOOR"
    reset_adaptive_state
    echo "Adaptive setup saved: $(IFS='>'; printf '%s' "${PROFILE_LADDER[*]}") (starts at ${PROFILE_LADDER[0]})"
    apply_profile
}

set_limits_mode() {
    local requested="${1:-}"

    case "$requested" in
        fixed|auto) ;;
        *) fail "Usage: backup-profile.sh limits fixed|auto" ;;
    esac
    FILE_PROFILE_LIMITS_MODE="$requested"
    resolve_profile_ladder
    resolve_file_backup_profile "${PROFILE_LADDER[0]}"
    set_config_value FILE_PROFILE_LIMITS_MODE "$requested"
    echo "Limits mode is now '$requested'."
    apply_profile
}

set_override() {
    local profile_name="${1:-}"
    local key="${2:-}"
    local value="${3-}"
    local known_key
    local valid=0
    local variable_name

    profile_name="${profile_name,,}"
    key="${key^^}"
    case "$profile_name" in
        slow|moderate|fast) ;;
        *) fail "Overrides apply to slow, moderate, or fast (custom uses FILE_CUSTOM_* and FILE_RCLONE_*)." ;;
    esac
    for known_key in "${FILE_PROFILE_OVERRIDE_KEYS[@]}"; do
        [ "$known_key" = "$key" ] && valid=1
    done
    [ "$valid" -eq 1 ] || fail "Unknown override key '$key'. Known keys: ${FILE_PROFILE_OVERRIDE_KEYS[*]}"
    [ "$#" -ge 3 ] || fail "Usage: backup-profile.sh override <profile> <KEY> <value>|--unset"
    variable_name="FILE_PROFILE_${profile_name^^}_${key}"

    if [ "$value" = "--unset" ]; then
        unset "$variable_name"
        remove_config_value "$variable_name"
        echo "Removed $variable_name"
    else
        [[ "$value" != *'"'* && "$value" != *'$'* && "$value" != *'`'* && "$value" != *\\* ]] || fail "Override values cannot contain quotes, \$, backticks, or backslashes."
        printf -v "$variable_name" '%s' "$value"
        # Validate before saving.
        resolve_file_backup_profile "$profile_name"
        set_config_value "$variable_name" "$value"
        echo "Saved $variable_name=\"$value\""
    fi
    apply_profile
}

choose_profile() {
    local answer

    show_profiles
    cat <<'EOF'

Choose a setup:
  1) fixed slow
  2) fixed moderate
  3) fixed fast
  4) adaptive moderate <-> slow        (2 steps)
  5) adaptive fast <-> moderate <-> slow (3 steps)
  q) keep the current setup
EOF
    read -r -p "Choice [1-5/q]: " answer
    case "$answer" in
        1) set_profile slow ;;
        2) set_profile moderate ;;
        3) set_profile fast ;;
        4) set_adaptive moderate slow ;;
        5) set_adaptive fast slow ;;
        q|Q|"") echo "Setup unchanged: $(describe_setup)" ;;
        *) fail "Invalid choice: $answer" ;;
    esac
}

load_global_config

command_name="${1:-}"
if [ -z "$command_name" ]; then
    if [ -t 0 ] && [ -t 1 ]; then
        command_name="choose"
    else
        command_name="show"
    fi
fi

case "$command_name" in
    show)
        show_profiles
        ;;
    choose)
        choose_profile
        ;;
    set)
        set_profile "${2:-}"
        ;;
    adaptive)
        set_adaptive "${2:-}" "${3:-}"
        ;;
    limits)
        set_limits_mode "${2:-}"
        ;;
    override)
        shift
        set_override "$@"
        ;;
    apply)
        apply_profile
        ;;
    current)
        describe_setup
        ;;
    print-dropin)
        resolve_file_backup_profile "${2:-${FILE_BACKUP_PROFILE:-custom}}"
        render_file_backup_profile_dropin
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage >&2
        fail "Unknown command: $command_name"
        ;;
esac
