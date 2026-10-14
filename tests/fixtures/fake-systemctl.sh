#!/bin/bash

set -euo pipefail

: "${FAKE_SYSTEMCTL_LOG:?FAKE_SYSTEMCTL_LOG is required}"
printf '%s\n' "$*" >> "$FAKE_SYSTEMCTL_LOG"

arguments=("$@")
[ "${arguments[0]:-}" = "--user" ] && arguments=("${arguments[@]:1}")

case "${arguments[0]:-}" in
    stop)
        if [ "${FAKE_SYSTEMCTL_STOP_UNPOPULATES:-1}" = "1" ] && [ -n "${WATCHDOG_CGROUP_DIR:-}" ]; then
            printf 'populated 0\nfrozen 0\n' > "$WATCHDOG_CGROUP_DIR/cgroup.events"
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
            printf '%s\n' "${FAKE_SYSTEMCTL_CONTROL_GROUP:-}"
        fi
        ;;
    is-enabled)
        echo "enabled"
        ;;
esac
exit 0
