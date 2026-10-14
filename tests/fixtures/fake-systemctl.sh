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
        printf '%s\n' "${FAKE_SYSTEMCTL_CONTROL_GROUP:-}"
        ;;
esac
exit 0
