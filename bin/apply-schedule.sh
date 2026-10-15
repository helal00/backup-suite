#!/bin/bash
# Applies the schedule settings in global.conf to the installed timers and the
# file backup's run time limit, as systemd drop-ins, then reloads systemd:
#
#   FILE_BACKUP_ONCALENDAR, FILE_BACKUP_RANDOMIZED_DELAY_SEC -> file-backup.timer
#   FILE_BACKUP_RUNTIME_MAX_SEC                              -> file-backup.service
#   DB_BACKUP_ONCALENDAR                                     -> database-backup.timer
#   DB_MONITOR_ONCALENDAR                                    -> database-size-check.timer
#
# The GUI runs it after a schedule change, and production-deploy.sh after every
# deploy, so the timers always follow global.conf. A unit that is not installed is
# skipped. Usage: apply-schedule.sh [--no-reload]

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

reload=1
case "${1:-}" in
    --no-reload) reload=0 ;;
    "") ;;
    -h|--help)
        sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "Usage: apply-schedule.sh [--no-reload]" >&2
        exit 64
        ;;
esac

load_global_config

write_dropin() {
    # write_dropin <unit> <section> <body>
    local unit="$1"
    local section="$2"
    local body="$3"
    local dropin_dir="$SYSTEMD_UNIT_DIR/$unit.d"
    local target="$dropin_dir/60-schedule.conf"

    if [ ! -f "$SYSTEMD_UNIT_DIR/$unit" ]; then
        echo "Skipped $unit: not installed in $SYSTEMD_UNIT_DIR."
        return 0
    fi
    mkdir -p "$dropin_dir"
    printf '# Written by apply-schedule.sh from global.conf; do not edit.\n[%s]\n%s\n' "$section" "$body" > "$target.tmp.$$"
    chmod 644 "$target.tmp.$$"
    mv -f "$target.tmp.$$" "$target"
    echo "Applied to $unit: $(printf '%s' "$body" | grep -v '=$' | tr '\n' ' ')"
}

write_dropin file-backup.timer Timer "OnCalendar=
OnCalendar=${FILE_BACKUP_ONCALENDAR:-*:0/30}
RandomizedDelaySec=${FILE_BACKUP_RANDOMIZED_DELAY_SEC:-15m}"
write_dropin file-backup.service Service "RuntimeMaxSec=${FILE_BACKUP_RUNTIME_MAX_SEC:-6h}"
write_dropin database-backup.timer Timer "OnCalendar=
OnCalendar=${DB_BACKUP_ONCALENDAR:-daily}"
write_dropin database-size-check.timer Timer "OnCalendar=
OnCalendar=${DB_MONITOR_ONCALENDAR:-daily}"

if [ "$reload" -eq 1 ]; then
    "${SYSTEMCTL_COMMAND[@]}" daemon-reload
    echo "systemd reloaded."
fi
