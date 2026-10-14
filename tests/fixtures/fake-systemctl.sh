#!/bin/bash

set -euo pipefail

: "${FAKE_SYSTEMCTL_LOG:?FAKE_SYSTEMCTL_LOG is required}"
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"

arguments=("$@")
[ "${arguments[0]:-}" = "--user" ] && arguments=("${arguments[@]:1}")

new_invocation() {
    # Simulates systemd starting the next run: a new invocation ID and a new
    # cgroup (new cgroup.events inode) that ends after FAKE_SYSTEMCTL_NEW_RUN_SECONDS.
    local cgroup_dir="$WATCHDOG_CGROUP_DIR"
    [ -n "${FAKE_SYSTEMCTL_INVOCATION_FILE:-}" ] && printf 'inv-%s\n' "$RANDOM" > "$FAKE_SYSTEMCTL_INVOCATION_FILE"
    rm -f "$cgroup_dir/cgroup.events"
    printf 'populated 1\nfrozen 0\n' > "$cgroup_dir/cgroup.events"
    printf '0\n' > "$cgroup_dir/cgroup.freeze"
    ( sleep "${FAKE_SYSTEMCTL_NEW_RUN_SECONDS:-2}"; printf 'populated 0\nfrozen 0\n' > "$cgroup_dir/cgroup.events" ) > /dev/null 2>&1 &
}

case "${arguments[0]:-}" in
    stop)
        if [ -n "${FAKE_SYSTEMCTL_FREEZE_AT_STOP_LOG:-}" ] && [ -n "${WATCHDOG_CGROUP_DIR:-}" ]; then
            printf 'freeze=%s\n' "$(cat "$WATCHDOG_CGROUP_DIR/cgroup.freeze")" >> "$FAKE_SYSTEMCTL_FREEZE_AT_STOP_LOG"
        fi
        if [ "${FAKE_SYSTEMCTL_STOP_RESTARTS:-0}" = "1" ] && [ -n "${WATCHDOG_CGROUP_DIR:-}" ] \
            && { [ -z "${FAKE_SYSTEMCTL_RESTART_ONCE_FILE:-}" ] || [ ! -e "$FAKE_SYSTEMCTL_RESTART_ONCE_FILE" ]; }; then
            [ -n "${FAKE_SYSTEMCTL_RESTART_ONCE_FILE:-}" ] && : > "$FAKE_SYSTEMCTL_RESTART_ONCE_FILE"
            new_invocation
        elif [ "${FAKE_SYSTEMCTL_STOP_UNPOPULATES:-1}" = "1" ] && [ -n "${WATCHDOG_CGROUP_DIR:-}" ]; then
            printf 'populated 0\nfrozen 0\n' > "$WATCHDOG_CGROUP_DIR/cgroup.events"
        fi
        ;;
    start)
        if [ "${FAKE_SYSTEMCTL_START_REPOPULATES:-0}" = "1" ] && [ -n "${WATCHDOG_CGROUP_DIR:-}" ]; then
            new_invocation
        fi
        ;;
    is-active)
        exit "${FAKE_SYSTEMCTL_IS_ACTIVE_STATUS:-3}"
        ;;
    show)
        units=()
        properties=""
        index=1
        while [ "$index" -lt "${#arguments[@]}" ]; do
            case "${arguments[$index]}" in
                -p) index=$((index + 1)); properties="${arguments[$index]}" ;;
                -*) ;;
                *) units+=("${arguments[$index]}") ;;
            esac
            index=$((index + 1))
        done
        if [[ ",$properties," == *",Id,"* ]]; then
            # Property blocks, one per unit, as `systemctl show A B -p Id,...` prints them.
            for unit in "${units[@]}"; do
                state="inactive"
                [ "$unit" = "${FAKE_SYSTEMCTL_ACTIVE_UNIT:-}" ] && state="active"
                printf 'Id=%s\nLoadState=loaded\nActiveState=%s\nSubState=dead\nResult=success\nUnitFileState=static\n\n' "$unit" "$state"
            done
        else
            case "$properties" in
                InvocationID)
                    if [ -n "${FAKE_SYSTEMCTL_INVOCATION_FILE:-}" ] && [ -f "$FAKE_SYSTEMCTL_INVOCATION_FILE" ]; then
                        cat "$FAKE_SYSTEMCTL_INVOCATION_FILE"
                    else
                        echo "inv-1"
                    fi
                    ;;
                ActiveState) echo "${FAKE_SYSTEMCTL_ACTIVE_STATE:-inactive}" ;;
                Result) echo "${FAKE_SYSTEMCTL_RESULT:-success}" ;;
                *) printf '%s\n' "${FAKE_SYSTEMCTL_CONTROL_GROUP:-}" ;;
            esac
        fi
        ;;
    is-enabled)
        echo "enabled"
        ;;
esac
exit 0
