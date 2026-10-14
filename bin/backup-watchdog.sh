#!/bin/bash
#
# Backup Suite resource watchdog.
#
# Runs only while a backup unit runs (file-backup.service pulls it in with
# Wants=) and reads the unit's cgroup v2 counters with shell builtins, so a
# sample costs no extra processes. It enforces three layers on top of the
# kernel limits set by the backup profile:
#
#   contain  memory above WATCHDOG_CONTAIN_PERCENT of MemoryMax: reclaim cache
#            and halve the CPU quota until usage drops again
#   pause    the server itself is short of memory: freeze the backup until the
#            pressure passes, and stop it if the pause lasts too long
#   stop     memory that cannot be reclaimed nears MemoryMax, or the server is
#            about to run out: stop the backup before the kernel OOM-kills
#            anything, then force-kill the cgroup if a graceful stop hangs
#
# Every action is reported through ntfy with an explanation. A per-run resource
# summary is appended to STATE_DIR/watchdog/history.tsv.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/notify-lib.sh"

usage() {
    cat <<'EOF'
Usage: backup-watchdog.sh <unit-name> [--self-test]

Monitors the resources of a running backup unit and contains, pauses, or stops
it before it can push the server into an out-of-memory condition.

  --self-test   check that the cgroup counters can be read, then exit
EOF
}

monitored_unit=""
self_test=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --self-test) self_test=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) usage >&2; fail "Unknown option: $1" ;;
        *) monitored_unit="$1" ;;
    esac
    shift
done
[ -n "$monitored_unit" ] || { usage >&2; exit 64; }
[[ "$monitored_unit" =~ ^[A-Za-z0-9@._-]+$ ]] || fail "Invalid unit name: $monitored_unit"
BACKUP_EVENT_UNIT="$monitored_unit"

load_global_config
resolve_profile_ladder
adaptive_enabled=0
if [ "$PROFILE_MODE" = "adaptive" ] && [ "${#PROFILE_LADDER[@]}" -ge 2 ]; then
    adaptive_enabled=1
fi
level_index=0
starting_level=$(current_adaptive_profile)
for ladder_index in "${!PROFILE_LADDER[@]}"; do
    [ "${PROFILE_LADDER[$ladder_index]}" = "$starting_level" ] && level_index="$ladder_index"
done
resolve_file_backup_profile "${PROFILE_LADDER[$level_index]}"

# From here on the loop must survive transient read errors on cgroup files.
set +e

interval_seconds="${WATCHDOG_INTERVAL_SECONDS:-5}"
contain_percent="${WATCHDOG_CONTAIN_PERCENT:-80}"
contain_release_percent="${WATCHDOG_CONTAIN_RELEASE_PERCENT:-60}"
kill_percent="${WATCHDOG_KILL_PERCENT:-90}"
kill_samples="${WATCHDOG_KILL_SAMPLES:-2}"
swap_contain_percent="${WATCHDOG_SWAP_CONTAIN_PERCENT:-80}"
swap_kill_percent="${WATCHDOG_SWAP_KILL_PERCENT:-95}"
system_min_available_percent="${WATCHDOG_SYSTEM_MIN_AVAILABLE_PERCENT:-10}"
system_critical_available_percent="${WATCHDOG_SYSTEM_CRITICAL_AVAILABLE_PERCENT:-4}"
system_psi_full_limit="${WATCHDOG_SYSTEM_PSI_FULL_LIMIT:-20}"
freeze_max_seconds="${WATCHDOG_FREEZE_MAX_SECONDS:-600}"
kill_grace_seconds="${WATCHDOG_KILL_GRACE_SECONDS:-30}"
tasks_warn_percent="${WATCHDOG_TASKS_WARN_PERCENT:-90}"
report_interval_seconds="${WATCHDOG_REPORT_INTERVAL_SECONDS:-300}"
status_interval_seconds="${WATCHDOG_STATUS_INTERVAL_SECONDS:-15}"
history_keep_lines="${WATCHDOG_HISTORY_KEEP_LINES:-500}"
start_wait_seconds="${WATCHDOG_START_WAIT_SECONDS:-30}"
proc_dir="${WATCHDOG_PROC_DIR:-/proc}"
step_down_available_percent="${WATCHDOG_ADAPTIVE_STEP_DOWN_AVAILABLE_PERCENT:-20}"
step_down_psi_full="${WATCHDOG_ADAPTIVE_STEP_DOWN_PSI_FULL:-10}"
step_up_available_percent="${WATCHDOG_ADAPTIVE_STEP_UP_AVAILABLE_PERCENT:-30}"
step_up_seconds="${WATCHDOG_ADAPTIVE_STEP_UP_SECONDS:-300}"
step_cooldown_seconds="${WATCHDOG_ADAPTIVE_COOLDOWN_SECONDS:-120}"

for numeric_setting in contain_percent contain_release_percent kill_percent kill_samples swap_contain_percent \
    swap_kill_percent system_min_available_percent system_critical_available_percent system_psi_full_limit \
    freeze_max_seconds kill_grace_seconds tasks_warn_percent report_interval_seconds status_interval_seconds \
    history_keep_lines start_wait_seconds step_down_available_percent step_down_psi_full step_up_available_percent \
    step_up_seconds step_cooldown_seconds; do
    [[ "${!numeric_setting}" =~ ^[0-9]+$ ]] || fail "Watchdog setting $numeric_setting must be a non-negative integer"
done
[[ "$interval_seconds" =~ ^[0-9]+(\.[0-9]+)?$ ]] || fail "WATCHDOG_INTERVAL_SECONDS must be a positive number"

watchdog_dir=$(join_path "$STATE_DIR" "watchdog")
mkdir -p "$watchdog_dir"
chmod 750 "$watchdog_dir" 2>/dev/null
unit_tag="${monitored_unit//[^A-Za-z0-9._-]/_}"
status_file=$(join_path "$watchdog_dir" "${unit_tag}.status")
history_file=$(join_path "$watchdog_dir" "history.tsv")
last_action_file=$(join_path "$watchdog_dir" "${unit_tag}.last-action")
host_name=$(trim "${REMOTE_HOSTNAME:-}")
[ -n "$host_name" ] || host_name=$(hostname)
title_prefix=$(trim "${NOTIFY_NTFY_TITLE_PREFIX:-Backup Suite}")

now_usec() {
    local realtime="$EPOCHREALTIME"
    printf -v "$1" '%s' "${realtime/./}"
}

read_value() {
    # read_value <var> <file> [default]: first line of a file without forking.
    local __line=""
    if ! { IFS= read -r __line < "$2"; } 2>/dev/null; then
        __line="${3:-}"
    fi
    printf -v "$1" '%s' "$__line"
}

mib() {
    printf '%d MiB' "$(( ${1:-0} / 1048576 ))"
}

percent_of() {
    # percent_of <value> <limit>: integer percentage, 0 when the limit is unknown.
    local __result
    percent_into __result "$1" "$2"
    printf '%s' "$__result"
}

percent_into() {
    # percent_into <var> <value> <limit>: same as percent_of without a subshell.
    if [ -z "${3:-}" ] || [ "${3:-0}" -le 0 ] 2>/dev/null; then
        printf -v "$1" '%s' 0
    else
        printf -v "$1" '%s' "$(( ${2:-0} * 100 / $3 ))"
    fi
}

resolve_cgroup_dir() {
    local control_group

    if [ -n "${WATCHDOG_CGROUP_DIR:-}" ]; then
        cgroup_dir="$WATCHDOG_CGROUP_DIR"
        return 0
    fi
    control_group=$("${SYSTEMCTL_COMMAND[@]}" show "$monitored_unit" -p ControlGroup --value 2>/dev/null)
    if [ -n "$control_group" ]; then
        cgroup_dir="${BACKUP_SUITE_CGROUP_ROOT:-/sys/fs/cgroup}$control_group"
    else
        cgroup_dir=""
    fi
}

cgroup_populated() {
    local line
    [ -n "$cgroup_dir" ] && [ -d "$cgroup_dir" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            "populated 1") return 0 ;;
            "populated 0") return 1 ;;
        esac
    done < "$cgroup_dir/cgroup.events" 2>/dev/null
    return 1
}

pause_fd=""
if exec {pause_fd}<> <(:) 2>/dev/null; then
    :
else
    pause_fd=""
fi

pause_for() {
    if [ -n "$pause_fd" ]; then
        read -r -t "$1" -u "$pause_fd" _ 2>/dev/null
    else
        sleep "$1"
    fi
}

read_limits() {
    local raw
    local quota
    local period

    read_value raw "$cgroup_dir/memory.max" max
    if [ "$raw" = "max" ] || [ -z "$raw" ]; then
        memory_max_bytes=$(( system_total_bytes * ${WATCHDOG_FALLBACK_MEMORY_PERCENT:-25} / 100 ))
        memory_max_source="no MemoryMax; using ${WATCHDOG_FALLBACK_MEMORY_PERCENT:-25}% of RAM"
    else
        memory_max_bytes="$raw"
        memory_max_source="MemoryMax"
    fi
    read_value raw "$cgroup_dir/memory.high" max
    memory_high_original="$raw"
    read_value raw "$cgroup_dir/memory.swap.max" max
    if [ "$raw" = "max" ] || [ -z "$raw" ]; then
        swap_max_bytes=0
    else
        swap_max_bytes="$raw"
    fi
    read_value raw "$cgroup_dir/pids.max" max
    if [ "$raw" = "max" ] || [ -z "$raw" ]; then
        tasks_max=0
    else
        tasks_max="$raw"
    fi
    read_value raw "$cgroup_dir/cpu.max" "max 100000"
    cpu_max_original="$raw"
    quota="${raw%% *}"
    period="${raw##* }"
    if [ "$quota" = "max" ] || ! [[ "$quota" =~ ^[0-9]+$ ]] || ! [[ "$period" =~ ^[0-9]+$ ]]; then
        cpu_quota_percent=0
        cpu_period=100000
    else
        cpu_quota_percent=$(( quota * 100 / period ))
        cpu_period="$period"
    fi
}

read_system() {
    local key
    local value
    local unit
    local line
    local field

    system_total_bytes=0
    system_available_bytes=0
    system_swap_total_bytes=0
    system_swap_free_bytes=0
    while read -r key value unit; do
        case "$key" in
            MemTotal:) system_total_bytes=$(( value * 1024 )) ;;
            MemAvailable:) system_available_bytes=$(( value * 1024 )) ;;
            SwapTotal:) system_swap_total_bytes=$(( value * 1024 )) ;;
            SwapFree:) system_swap_free_bytes=$(( value * 1024 )) ;;
        esac
    done < "$proc_dir/meminfo" 2>/dev/null

    system_psi_full=0
    while read -r line; do
        case "$line" in
            full\ *)
                for field in $line; do
                    case "$field" in
                        avg10=*)
                            value="${field#avg10=}"
                            system_psi_full="${value%%.*}"
                            ;;
                    esac
                done
                ;;
        esac
    done < "$proc_dir/pressure/memory" 2>/dev/null
    [[ "$system_psi_full" =~ ^[0-9]+$ ]] || system_psi_full=0
    percent_into system_available_percent "$system_available_bytes" "$system_total_bytes"
}

read_cgroup() {
    local key
    local value
    local line
    local field

    read_value memory_current "$cgroup_dir/memory.current" 0
    read_value swap_current "$cgroup_dir/memory.swap.current" 0
    read_value tasks_current "$cgroup_dir/pids.current" 0
    read_value memory_peak_kernel "$cgroup_dir/memory.peak" 0
    [[ "$memory_current" =~ ^[0-9]+$ ]] || memory_current=0
    [[ "$swap_current" =~ ^[0-9]+$ ]] || swap_current=0
    [[ "$tasks_current" =~ ^[0-9]+$ ]] || tasks_current=0
    [[ "$memory_peak_kernel" =~ ^[0-9]+$ ]] || memory_peak_kernel=0

    memory_anon=0
    memory_file=0
    while read -r key value; do
        case "$key" in
            anon) memory_anon="$value" ;;
            file) memory_file="$value" ;;
        esac
    done < "$cgroup_dir/memory.stat" 2>/dev/null

    oom_kill_count=0
    while read -r key value; do
        case "$key" in
            oom_kill) oom_kill_count="$value" ;;
        esac
    done < "$cgroup_dir/memory.events" 2>/dev/null

    cpu_usage_usec=0
    while read -r key value; do
        case "$key" in
            usage_usec) cpu_usage_usec="$value" ;;
        esac
    done < "$cgroup_dir/cpu.stat" 2>/dev/null

    io_read_bytes=0
    io_write_bytes=0
    while read -r line; do
        for field in $line; do
            case "$field" in
                rbytes=*) io_read_bytes=$(( io_read_bytes + ${field#rbytes=} )) ;;
                wbytes=*) io_write_bytes=$(( io_write_bytes + ${field#wbytes=} )) ;;
            esac
        done
    done < "$cgroup_dir/io.stat" 2>/dev/null
}

write_cgroup_value() {
    local file_name="$1"
    local value="$2"
    { printf '%s\n' "$value" > "$cgroup_dir/$file_name"; } 2>/dev/null
}

record_sample_line() {
    local line
    local clock
    TZ=UTC printf -v clock '%(%H:%M:%S)T' -1
    printf -v line '%s mem=%dMiB anon=%dMiB swap=%dMiB cpu=%s%% tasks=%s/%s server_available=%s%% server_psi_full=%s state=%s' \
        "$clock" "$(( memory_current / 1048576 ))" "$(( memory_anon / 1048576 ))" "$(( swap_current / 1048576 ))" \
        "$cpu_percent" "$tasks_current" "${tasks_max:-max}" "$system_available_percent" "$system_psi_full" "$watchdog_state"
    recent_samples+=("$line")
    if [ "${#recent_samples[@]}" -gt 24 ]; then
        recent_samples=("${recent_samples[@]:1}")
    fi
}

profile_label() {
    if [ "$adaptive_enabled" -eq 1 ]; then
        printf '%s (adaptive %s)' "$PROFILE_NAME" "$(IFS='>'; printf '%s' "${PROFILE_LADDER[*]}")"
    else
        printf '%s' "$PROFILE_NAME"
    fi
}

write_adaptive_state() {
    local state_file
    state_file=$(adaptive_state_file)
    {
        printf 'level=%s\n' "$PROFILE_NAME"
        printf 'changed_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'reason=%s\n' "$1"
    } > "$state_file.tmp" 2>/dev/null && mv -f "$state_file.tmp" "$state_file" 2>/dev/null
}

apply_level() {
    # apply_level <ladder-index> <reason>: switch the running backup to another
    # profile level. Raising limits is always safe; a lower hard memory limit is
    # only written once usage is comfortably below it, so the kernel never has
    # to OOM-kill because of a step-down.
    local quota_percent
    local value
    local target_max

    level_index="$1"
    resolve_file_backup_profile "${PROFILE_LADDER[$level_index]}"
    quota_percent="${PROFILE_CPU_QUOTA%\%}"
    write_cgroup_value cpu.max "$(( quota_percent * cpu_period / 100 )) $cpu_period"
    write_cgroup_value cpu.weight "$PROFILE_CPU_WEIGHT"
    write_cgroup_value pids.max "$PROFILE_TASKS_MAX"
    value=$(size_to_bytes "$PROFILE_MEMORY_HIGH")
    write_cgroup_value memory.high "${value:-max}"
    value=$(size_to_bytes "$PROFILE_MEMORY_SWAP_MAX")
    write_cgroup_value memory.swap.max "${value:-max}"
    target_max=$(size_to_bytes "$PROFILE_MEMORY_MAX")
    pending_memory_max=0
    if [ -z "$target_max" ] || [ "$target_max" -gt $(( memory_current + 67108864 )) ]; then
        write_cgroup_value memory.max "${target_max:-max}"
    else
        pending_memory_max="$target_max"
    fi
    cpu_throttled=0
    contained=0
    release_streak=0
    read_limits
    now_usec last_level_change_usec
    write_adaptive_state "$2"
}

limits_text() {
    local cpu_text="unlimited"
    local high_text="none"
    local swap_text="unlimited"

    [ "$cpu_quota_percent" -gt 0 ] && cpu_text="${cpu_quota_percent}%"
    [[ "$memory_high_original" =~ ^[0-9]+$ ]] && high_text=$(mib "$memory_high_original")
    [ "$swap_max_bytes" -gt 0 ] && swap_text=$(mib "$swap_max_bytes")
    printf 'Profile %s, live limits: CPU %s, MemoryHigh %s, MemoryMax %s (%s), swap %s, tasks %s.' \
        "$(profile_label)" "$cpu_text" "$high_text" "$(mib "$memory_max_bytes")" "$memory_max_source" \
        "$swap_text" "${tasks_max:-max}"
}

usage_text() {
    printf 'Backup now uses %s RAM (%s%% of limit; %s not reclaimable), %s swap, %s%% CPU, %s tasks. Server has %s%% RAM available; memory pressure (PSI full avg10) %s.' \
        "$(mib "$memory_current")" "$(percent_of "$memory_current" "$memory_max_bytes")" "$(mib "$memory_anon")" \
        "$(mib "$swap_current")" "$cpu_percent" "$tasks_current" "$system_available_percent" "$system_psi_full"
}

send_event() {
    # send_event <event-key> <priority> <tags> <headline> <what-happened> <action> <next-step>
    local event_key="$1"
    local priority="$2"
    local tags="$3"
    local headline="$4"
    local what_happened="$5"
    local action_taken="$6"
    local next_step="$7"
    local detail_file
    local message
    local event_category

    events_seen+=("$event_key")
    echo "WATCHDOG EVENT [$event_key] $headline - $action_taken"

    message=$(cat <<MSG
$headline

What happened: $what_happened

What the watchdog did: $action_taken

Remote backups: previous versions on the remote stay in place. rclone only deletes or replaces remote files as each one finishes, so an interrupted run never removes good copies.

What to do: $next_step

Host: $host_name | Unit: $monitored_unit | $(date -u '+%Y-%m-%d %H:%M:%S UTC')
$(limits_text)
$(usage_text)
MSG
)

    detail_file=$(mktemp)
    {
        printf '%s\n\n' "$message"
        echo "Recent watchdog samples (every ${interval_seconds}s, newest last):"
        printf '%s\n' "${recent_samples[@]}"
        echo ""
        echo "Durable run log: $(join_path "$STATE_DIR" "logs" "backup-file.log")"
        echo "Watchdog history: $history_file"
    } > "$detail_file"
    case "$event_key" in
        contained|released|tasks-limit) event_category="watchdog-contain" ;;
        server-pressure|resumed) event_category="watchdog-pause" ;;
        step-down|step-up) event_category="profile-step" ;;
        *) event_category="watchdog-stop" ;;
    esac
    ntfy_publish "$title_prefix: $headline on $host_name" "$priority" "$tags" "$message" \
        "$detail_file" "watchdog-${event_key}-$(date -u '+%Y%m%dT%H%M%SZ').txt" "$event_category" || true
    rm -f "$detail_file"
}

freeze_backup() {
    write_cgroup_value cgroup.freeze 1
    frozen=1
    now_usec frozen_since_usec
}

thaw_backup() {
    if [ "$frozen" -eq 1 ]; then
        write_cgroup_value cgroup.freeze 0
        frozen=0
    fi
}

restore_cpu_quota() {
    if [ "$cpu_throttled" -eq 1 ]; then
        write_cgroup_value cpu.max "$cpu_max_original"
        cpu_throttled=0
    fi
}

stop_backup() {
    # stop_backup <event-key> <headline> <what-happened> <next-step>
    local event_key="$1"
    local headline="$2"
    local what_happened="$3"
    local next_step="$4"
    local waited=0
    local action_taken

    thaw_backup
    restore_cpu_quota
    printf 'at=%s\nunit=%s\nevent=%s\nreason=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$monitored_unit" "$event_key" "$what_happened" > "$last_action_file"

    "${SYSTEMCTL_COMMAND[@]}" stop --no-block "$monitored_unit" >/dev/null 2>&1
    while cgroup_populated && [ "$waited" -lt "$kill_grace_seconds" ]; do
        pause_for 1
        waited=$((waited + 1))
    done

    if cgroup_populated; then
        write_cgroup_value cgroup.kill 1
        action_taken="Asked systemd to stop the backup; it did not exit within ${kill_grace_seconds}s, so every process in its cgroup was force-killed (SIGKILL)."
        printf 'forced_kill=1\n' >> "$last_action_file"
    else
        action_taken="Stopped the backup gracefully (systemd stop) after ${waited}s, before the kernel had to OOM-kill anything."
        printf 'forced_kill=0\n' >> "$last_action_file"
    fi
    final_action="$event_key"
    watchdog_state="stopped"
    send_event "$event_key" urgent "rotating_light,backup" "$headline" "$what_happened" "$action_taken" "$next_step"
}

write_status() {
    {
        TZ=UTC printf 'updated_at=%(%Y-%m-%dT%H:%M:%SZ)T\n' -1
        printf 'unit=%s\nprofile=%s\nprofile_mode=%s\nprofile_levels=%s\nstate=%s\n' "$monitored_unit" "$PROFILE_NAME" "$PROFILE_MODE" "$(IFS='>'; printf '%s' "${PROFILE_LADDER[*]}")" "$watchdog_state"
        printf 'memory_bytes=%s\nmemory_anon_bytes=%s\nmemory_max_bytes=%s\nswap_bytes=%s\nswap_max_bytes=%s\n' \
            "$memory_current" "$memory_anon" "$memory_max_bytes" "$swap_current" "$swap_max_bytes"
        printf 'cpu_percent=%s\ncpu_quota_percent=%s\ntasks=%s\ntasks_max=%s\n' \
            "$cpu_percent" "$cpu_quota_percent" "$tasks_current" "$tasks_max"
        printf 'io_read_bytes=%s\nio_write_bytes=%s\n' "$(( io_read_bytes - io_read_start ))" "$(( io_write_bytes - io_write_start ))"
        printf 'server_available_percent=%s\nserver_psi_full_avg10=%s\n' "$system_available_percent" "$system_psi_full"
        printf 'peak_memory_bytes=%s\npeak_anon_bytes=%s\npeak_swap_bytes=%s\npeak_cpu_percent=%s\npeak_tasks=%s\n' \
            "$peak_memory" "$peak_anon" "$peak_swap" "$peak_cpu" "$peak_tasks"
        printf 'events=%s\n' "${events_seen[*]:-none}"
    } > "$status_file.tmp" 2>/dev/null && mv -f "$status_file.tmp" "$status_file" 2>/dev/null
}

finish_run() {
    local ended_usec
    local duration_seconds
    local average_cpu
    local summary_line

    now_usec ended_usec
    duration_seconds=$(( (ended_usec - started_usec) / 1000000 ))
    if [ "$duration_seconds" -gt 0 ]; then
        average_cpu=$(( (last_cpu_usage_usec - cpu_usage_start) / (duration_seconds * 10000) ))
    else
        average_cpu=0
    fi
    [ "$memory_peak_kernel" -gt "$peak_memory" ] && peak_memory="$memory_peak_kernel"

    printf -v summary_line '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$started_at" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$monitored_unit" "$PROFILE_NAME" "$duration_seconds" \
        "$peak_memory" "$peak_anon" "$peak_swap" "$average_cpu" "$peak_cpu" "$peak_tasks" \
        "$(( io_read_bytes - io_read_start ))" "$(( io_write_bytes - io_write_start ))" \
        "$(IFS=,; printf '%s' "${events_seen[*]:-none}")" "${final_action:-completed}"
    if [ ! -s "$history_file" ]; then
        printf 'started\tended\tunit\tprofile\tduration_s\tpeak_mem\tpeak_anon\tpeak_swap\tavg_cpu_pct\tpeak_cpu_pct\tpeak_tasks\tio_read\tio_write\tevents\toutcome\n' > "$history_file"
    fi
    printf '%s\n' "$summary_line" >> "$history_file"
    if [ "$(wc -l < "$history_file")" -gt $((history_keep_lines + 1)) ]; then
        { head -n 1 "$history_file"; tail -n "$history_keep_lines" "$history_file"; } > "$history_file.tmp" && mv -f "$history_file.tmp" "$history_file"
    fi
    chmod 640 "$history_file" 2>/dev/null

    echo "Watchdog summary for $monitored_unit: profile=$PROFILE_NAME duration=${duration_seconds}s peak_memory=$(mib "$peak_memory") peak_unreclaimable=$(mib "$peak_anon") peak_swap=$(mib "$peak_swap") avg_cpu=${average_cpu}% peak_cpu=${peak_cpu}% peak_tasks=$peak_tasks io_read=$(mib "$(( io_read_bytes - io_read_start ))") io_write=$(mib "$(( io_write_bytes - io_write_start ))") events=${events_seen[*]:-none} outcome=${final_action:-completed}"

    intervention_count=0
    for seen_event in "${events_seen[@]}"; do
        case "$seen_event" in
            step-up|released|resumed) ;;
            *) intervention_count=$((intervention_count + 1)) ;;
        esac
    done
    if [ "$intervention_count" -gt 0 ] && [ -z "$final_action" ]; then
        ntfy_publish "$title_prefix: backup finished after watchdog intervention on $host_name" default "white_check_mark,backup" "$(cat <<MSG
The $monitored_unit run finished after the watchdog had to intervene (${events_seen[*]}).

Run resources: $(( duration_seconds / 60 )) min, peak $(mib "$peak_memory") RAM ($(mib "$peak_anon") not reclaimable), peak swap $(mib "$peak_swap"), average CPU ${average_cpu}%, peak ${peak_cpu}%, peak $peak_tasks tasks.

If this keeps happening, choose a lower profile with: backup-profile.sh set slow
$(limits_text)
MSG
)" "" "" run-finished || true
    fi
    watchdog_state="finished"
    write_status
}

on_signal() {
    thaw_backup
    restore_cpu_quota
    if [ "$monitoring_started" -eq 1 ]; then
        final_action="${final_action:-watchdog-stopped}"
        finish_run
    fi
    exit 0
}

monitoring_started=0
frozen=0
cpu_throttled=0
cpu_max_original=""
trap on_signal TERM INT

# Wait for the backup cgroup to appear; the watchdog starts right after it.
read_system
resolve_cgroup_dir
waited_for_start=0
while ! cgroup_populated; do
    if [ "$self_test" -eq 1 ] || [ "$waited_for_start" -ge "$start_wait_seconds" ]; then
        break
    fi
    pause_for 1
    waited_for_start=$((waited_for_start + 1))
    [ -n "$cgroup_dir" ] || resolve_cgroup_dir
done

if [ "$self_test" -eq 1 ]; then
    echo "Watchdog self-test for $monitored_unit"
    echo "  profile: $PROFILE_NAME ($PROFILE_SUMMARY)"
    echo "  server: $(mib "$system_total_bytes") RAM, $system_available_percent% available, memory PSI full avg10 $system_psi_full"
    if [ -n "$cgroup_dir" ] && [ -d "$cgroup_dir" ]; then
        read_limits
        read_cgroup
        echo "  cgroup: $cgroup_dir"
        echo "  limits: MemoryMax $(mib "$memory_max_bytes"), swap $(mib "$swap_max_bytes"), tasks ${tasks_max}, CPU quota ${cpu_quota_percent}%"
        echo "  usage: $(mib "$memory_current") RAM, $(mib "$memory_anon") not reclaimable, $tasks_current tasks"
    else
        echo "  cgroup: $monitored_unit is not running; counters will be read when it starts."
    fi
    [ -r "$proc_dir/meminfo" ] || fail "Cannot read $proc_dir/meminfo"
    echo "Watchdog self-test passed."
    exit 0
fi

if ! cgroup_populated; then
    echo "$monitored_unit is not running (no populated cgroup after ${start_wait_seconds}s); nothing to watch."
    exit 0
fi

read_limits
read_cgroup
started_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
now_usec started_usec
previous_usec="$started_usec"
cpu_usage_start="$cpu_usage_usec"
previous_cpu_usage="$cpu_usage_usec"
last_cpu_usage_usec="$cpu_usage_usec"
io_read_start="$io_read_bytes"
io_write_start="$io_write_bytes"
oom_kill_baseline="$oom_kill_count"
cpu_percent=0
peak_memory=0
peak_anon=0
peak_swap=0
peak_cpu=0
peak_tasks=0
contained=0
frozen_since_usec=0
release_streak=0
recover_streak=0
kill_streak=0
tasks_warned=0
final_action=""
watchdog_state="watching"
events_seen=()
recent_samples=()
last_report_usec="$started_usec"
last_status_usec=0
last_reclaim_usec=0
pending_memory_max=0
normal_since_usec=0
last_level_change_usec=0
if [ "$adaptive_enabled" -eq 1 ] && [ "$level_index" -gt 0 ]; then
    apply_level "$level_index" "continuing at the level selected during an earlier run"
    echo "Adaptive profile: continuing at '$PROFILE_NAME' from the previous run; stepping up after ${step_up_seconds}s of normal conditions."
fi
monitoring_started=1

echo "Watchdog started for $monitored_unit (cgroup $cgroup_dir). $(limits_text) Thresholds: contain at ${contain_percent}%, stop at ${kill_percent}% not-reclaimable memory, pause when server RAM available < ${system_min_available_percent}% or PSI full >= ${system_psi_full_limit}, stop when < ${system_critical_available_percent}%."

while cgroup_populated; do
    read_system
    read_cgroup
    now_usec sample_usec

    elapsed_usec=$(( sample_usec - previous_usec ))
    if [ "$elapsed_usec" -gt 0 ] && [ "$frozen" -eq 0 ]; then
        cpu_percent=$(( (cpu_usage_usec - previous_cpu_usage) * 100 / elapsed_usec ))
    else
        cpu_percent=0
    fi
    previous_usec="$sample_usec"
    previous_cpu_usage="$cpu_usage_usec"
    last_cpu_usage_usec="$cpu_usage_usec"

    [ "$memory_current" -gt "$peak_memory" ] && peak_memory="$memory_current"
    [ "$memory_anon" -gt "$peak_anon" ] && peak_anon="$memory_anon"
    [ "$swap_current" -gt "$peak_swap" ] && peak_swap="$swap_current"
    [ "$cpu_percent" -gt "$peak_cpu" ] && peak_cpu="$cpu_percent"
    [ "$tasks_current" -gt "$peak_tasks" ] && peak_tasks="$tasks_current"

    percent_into usage_percent "$memory_current" "$memory_max_bytes"
    percent_into anon_percent "$memory_anon" "$memory_max_bytes"
    percent_into swap_percent "$swap_current" "$swap_max_bytes"
    percent_into tasks_percent "$tasks_current" "$tasks_max"
    record_sample_line

    # 1. The kernel already OOM-killed something inside the backup.
    if [ "$oom_kill_count" -gt "$oom_kill_baseline" ]; then
        send_event "oom-kill" urgent "rotating_light,backup" "kernel OOM-killed a backup process" \
            "The kernel killed $(( oom_kill_count - oom_kill_baseline )) process(es) inside $monitored_unit because it reached its memory limit before the watchdog could act (memory grew faster than one ${interval_seconds}s sample)." \
            "Recorded the event. systemd stops the whole backup after an OOM kill (OOMPolicy=stop)." \
            "Switch to a lower profile (backup-profile.sh set slow) or lower WATCHDOG_INTERVAL_SECONDS, and check the attached samples for what grew."
        oom_kill_baseline="$oom_kill_count"
    fi

    # 2. Stop conditions.
    if [ "$anon_percent" -ge "$kill_percent" ]; then
        kill_streak=$((kill_streak + 1))
    else
        kill_streak=0
    fi

    if [ "$kill_streak" -ge "$kill_samples" ]; then
        stop_backup "memory-limit" "backup stopped before OOM" \
            "The backup's non-reclaimable memory reached $(mib "$memory_anon") (${anon_percent}% of its $(mib "$memory_max_bytes") limit) for $kill_streak samples in a row. At 100% the kernel would OOM-kill it." \
            "If this repeats, choose a lower profile (backup-profile.sh set slow) or exclude very large or rapidly growing trees. The next scheduled run starts normally."
        break
    fi
    if [ "$swap_max_bytes" -gt 0 ] && [ "$swap_percent" -ge "$swap_kill_percent" ] && [ "$anon_percent" -ge "$contain_percent" ]; then
        stop_backup "swap-limit" "backup stopped: memory and swap exhausted" \
            "The backup filled ${swap_percent}% of its $(mib "$swap_max_bytes") swap allowance while using ${anon_percent}% of its RAM limit, so it could no longer be contained." \
            "Choose a lower profile (backup-profile.sh set slow). The next scheduled run starts normally."
        break
    fi
    if [ "$system_total_bytes" -gt 0 ] && [ "$system_available_percent" -lt "$system_critical_available_percent" ]; then
        stop_backup "server-critical" "backup stopped to protect the server" \
            "The whole server is almost out of memory: only ${system_available_percent}% of RAM is available (critical threshold ${system_critical_available_percent}%). The backup was using $(mib "$memory_current"). Stopping it frees that memory and lowers the risk of the kernel OOM-killing a production service." \
            "Find what is using the server's memory (for example: ps aux --sort=-rss | head). The backup itself may not be the cause. The next scheduled run starts normally."
        break
    fi
    if [ "$frozen" -eq 1 ] && [ $(( (sample_usec - frozen_since_usec) / 1000000 )) -ge "$freeze_max_seconds" ]; then
        stop_backup "pause-timeout" "backup stopped after a long pause" \
            "The backup was paused for $(( (sample_usec - frozen_since_usec) / 1000000 ))s because the server was under memory pressure, and the pressure did not clear within ${freeze_max_seconds}s. Stopping it releases the memory the paused backup still held." \
            "Check what is loading the server. The next scheduled run starts normally."
        break
    fi

    # 3. Server-wide pressure: pause the backup, resume when it clears.
    if [ "$system_total_bytes" -gt 0 ] && { [ "$system_available_percent" -lt "$system_min_available_percent" ] || [ "$system_psi_full" -ge "$system_psi_full_limit" ]; }; then
        recover_streak=0
        if [ "$frozen" -eq 0 ]; then
            freeze_backup
            watchdog_state="paused"
            send_event "server-pressure" high "warning,backup" "backup paused: server memory pressure" \
                "The server is short of memory: ${system_available_percent}% of RAM available (pause threshold ${system_min_available_percent}%), memory pressure PSI full avg10 = ${system_psi_full} (limit ${system_psi_full_limit})." \
                "Froze every backup process (cgroup freeze). It resumes automatically once the pressure clears, or is stopped if the pause lasts longer than ${freeze_max_seconds}s." \
                "No action is needed unless this repeats. If it does, check which service is using the memory."
        fi
    elif [ "$frozen" -eq 1 ]; then
        if [ "$system_available_percent" -ge $((system_min_available_percent + 5)) ] && [ "$system_psi_full" -lt $(( (system_psi_full_limit + 1) / 2 )) ]; then
            recover_streak=$((recover_streak + 1))
        else
            recover_streak=0
        fi
        if [ "$recover_streak" -ge 3 ]; then
            echo "Server memory pressure cleared (${system_available_percent}% available); resuming the backup after $(( (sample_usec - frozen_since_usec) / 1000000 ))s paused."
            thaw_backup
            watchdog_state="watching"
            events_seen+=("resumed")
            recover_streak=0
        fi
    fi

    # 4. Adaptive profile: step down when resources are tight, back up when normal.
    stepped_this_sample=0
    if [ "$pending_memory_max" -gt 0 ] && [ $(( memory_current + 67108864 )) -lt "$pending_memory_max" ]; then
        write_cgroup_value memory.max "$pending_memory_max"
        memory_max_bytes="$pending_memory_max"
        memory_max_source="MemoryMax"
        echo "Backup memory is down to $(mib "$memory_current"); applied the $PROFILE_NAME hard limit of $(mib "$pending_memory_max")."
        pending_memory_max=0
    fi
    if [ "$adaptive_enabled" -eq 1 ] && [ "$frozen" -eq 0 ]; then
        tight_reasons=""
        if [ "$usage_percent" -ge "$contain_percent" ]; then
            tight_reasons+="backup memory at ${usage_percent}% of its $(mib "$memory_max_bytes") limit; "
        fi
        if [ "$swap_max_bytes" -gt 0 ] && [ "$swap_percent" -ge "$swap_contain_percent" ]; then
            tight_reasons+="backup swap at ${swap_percent}% of its allowance; "
        fi
        if [ "$system_total_bytes" -gt 0 ] && [ "$system_available_percent" -lt "$step_down_available_percent" ]; then
            tight_reasons+="server RAM available ${system_available_percent}% (step-down below ${step_down_available_percent}%); "
        fi
        if [ "$system_psi_full" -ge "$step_down_psi_full" ]; then
            tight_reasons+="server memory pressure PSI full ${system_psi_full} (step-down at ${step_down_psi_full}); "
        fi
        since_change_seconds=$(( (sample_usec - last_level_change_usec) / 1000000 ))

        if [ -n "$tight_reasons" ]; then
            normal_since_usec=0
            if [ "$level_index" -lt $(( ${#PROFILE_LADDER[@]} - 1 )) ] && [ "$since_change_seconds" -ge "$step_cooldown_seconds" ]; then
                previous_level="$PROFILE_NAME"
                apply_level $((level_index + 1)) "${tight_reasons%; }"
                stepped_this_sample=1
                watchdog_state="watching"
                memory_max_note="hard limit $(mib "$memory_max_bytes")"
                if [ "$pending_memory_max" -gt 0 ]; then
                    memory_max_note="hard limit stays $(mib "$memory_max_bytes") until usage drops below $(mib "$pending_memory_max") (lowering it now would force an OOM kill)"
                fi
                send_event "step-down" default "arrow_down,backup" "backup stepped down from $previous_level to $PROFILE_NAME" \
                    "Resources got tight: ${tight_reasons%; }." \
                    "Switched the running backup to the $PROFILE_NAME limits: CPU $PROFILE_CPU_QUOTA, memory throttle $PROFILE_MEMORY_HIGH, $memory_max_note, swap $PROFILE_MEMORY_SWAP_MAX, $PROFILE_TASKS_MAX tasks. rclone uses $PROFILE_RCLONE_TRANSFERS upload(s) from the next project. It steps back up after ${step_up_seconds}s of normal conditions." \
                    "No action needed. If backups stay at $PROFILE_NAME most of the time, look at what else loads the server."
            fi
        elif [ "$system_available_percent" -ge "$step_up_available_percent" ] && [ "$system_psi_full" -lt "$step_down_psi_full" ] \
            && [ "$usage_percent" -lt "$contain_release_percent" ] && { [ "$swap_max_bytes" -eq 0 ] || [ "$swap_percent" -lt "$contain_release_percent" ]; }; then
            [ "$normal_since_usec" -gt 0 ] || normal_since_usec="$sample_usec"
            if [ "$level_index" -gt 0 ] && [ $(( (sample_usec - normal_since_usec) / 1000000 )) -ge "$step_up_seconds" ] && [ "$since_change_seconds" -ge "$step_cooldown_seconds" ]; then
                previous_level="$PROFILE_NAME"
                apply_level $((level_index - 1)) "resources normal for ${step_up_seconds}s"
                stepped_this_sample=1
                normal_since_usec=0
                send_event "step-up" low "arrow_up,backup" "backup stepped back up from $previous_level to $PROFILE_NAME" \
                    "Resources have been normal for at least ${step_up_seconds}s: server RAM available ${system_available_percent}%, backup memory ${usage_percent}% of its limit." \
                    "Restored the $PROFILE_NAME limits: CPU $PROFILE_CPU_QUOTA, memory $PROFILE_MEMORY_HIGH / $PROFILE_MEMORY_MAX, $PROFILE_TASKS_MAX tasks; rclone uses $PROFILE_RCLONE_TRANSFERS upload(s) from the next project." \
                    "No action needed."
            fi
        else
            normal_since_usec=0
        fi
    fi

    # 5. Containment: reclaim cache and halve CPU while memory is high.
    if [ "$frozen" -eq 0 ] && [ "$stepped_this_sample" -eq 0 ]; then
        if [ "$usage_percent" -ge "$contain_percent" ] || { [ "$swap_max_bytes" -gt 0 ] && [ "$swap_percent" -ge "$swap_contain_percent" ]; }; then
            release_streak=0
            if [ $(( sample_usec - last_reclaim_usec )) -ge 30000000 ]; then
                reclaim_target=$(( memory_max_bytes * contain_release_percent / 100 ))
                if [ "$memory_current" -gt "$reclaim_target" ]; then
                    write_cgroup_value memory.reclaim "$(( memory_current - reclaim_target ))"
                fi
                last_reclaim_usec="$sample_usec"
            fi
            if [ "$contained" -eq 0 ]; then
                contained=1
                watchdog_state="contained"
                throttle_text="CPU quota left unchanged (no CPU quota is set)."
                if [ "$cpu_quota_percent" -gt 0 ]; then
                    throttled_quota=$(( cpu_period * cpu_quota_percent / 200 ))
                    [ "$throttled_quota" -ge $(( cpu_period / 20 )) ] || throttled_quota=$(( cpu_period / 20 ))
                    write_cgroup_value cpu.max "$throttled_quota $cpu_period"
                    cpu_throttled=1
                    throttle_text="Halved its CPU quota from ${cpu_quota_percent}% to $(( throttled_quota * 100 / cpu_period ))% to slow further growth."
                fi
                send_event "contained" high "warning,backup" "backup memory surge contained" \
                    "Backup memory reached $(mib "$memory_current") (${usage_percent}% of its $(mib "$memory_max_bytes") limit; swap ${swap_percent}% of its allowance). The containment threshold is ${contain_percent}%." \
                    "Asked the kernel to reclaim the backup's cache memory down to ${contain_release_percent}% of the limit. $throttle_text Limits return to normal once usage stays below ${contain_release_percent}%. The backup is stopped if its non-reclaimable memory reaches ${kill_percent}%." \
                    "No action is needed unless this repeats; if it does, choose a lower profile (backup-profile.sh set slow)."
            fi
        elif [ "$contained" -eq 1 ]; then
            if [ "$usage_percent" -lt "$contain_release_percent" ]; then
                release_streak=$((release_streak + 1))
            else
                release_streak=0
            fi
            if [ "$release_streak" -ge 6 ]; then
                restore_cpu_quota
                contained=0
                release_streak=0
                watchdog_state="watching"
                events_seen+=("released")
                echo "Backup memory back to $(mib "$memory_current") (${usage_percent}% of limit); containment released and CPU quota restored."
            fi
        fi
    fi

    # 6. Task count close to TasksMax: forks start failing at the limit.
    if [ "$tasks_max" -gt 0 ] && [ "$tasks_warned" -eq 0 ] && [ "$tasks_percent" -ge "$tasks_warn_percent" ]; then
        tasks_warned=1
        send_event "tasks-limit" default "warning,backup" "backup near its process limit" \
            "The backup is running $tasks_current of at most $tasks_max tasks (threads and processes). At the limit, new threads fail and rclone transfers can error." \
            "Recorded the event; the kernel enforces the limit itself." \
            "If backups fail with 'resource temporarily unavailable', choose a profile with a higher task limit or fewer transfers."
    fi

    if [ $(( sample_usec - last_report_usec )) -ge $(( report_interval_seconds * 1000000 )) ]; then
        echo "Watchdog sample: ${recent_samples[-1]}"
        last_report_usec="$sample_usec"
    fi
    if [ $(( sample_usec - last_status_usec )) -ge $(( status_interval_seconds * 1000000 )) ]; then
        write_status
        last_status_usec="$sample_usec"
    fi

    pause_for "$interval_seconds"
done

restore_cpu_quota
finish_run
exit 0
