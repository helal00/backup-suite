#!/bin/bash
#
# Routine production deployment for an already migrated Backup Suite host.
#
# Unlike production-file-backup-migrate.sh (a one-time --links migration), this
# script never disables file-backup.timer. It pauses the timer only while files
# are replaced, and on any failure it restores the previous scripts, units, and
# config, then restarts the timer. An interrupted run therefore cannot leave
# backups switched off.

set -euo pipefail

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
INSTALL_DIR="/opt/backup-suite"
CANONICAL_DIR="/opt/backup-suite-src"
CONFIG_DIR="/etc/backup-suite"
STATE_DIR="/var/lib/backup-suite"
UNIT_DIR="/etc/systemd/system"
GLOBAL_CONFIG="$CONFIG_DIR/global.conf"
TIMER_UNIT="file-backup.timer"
SERVICE_UNIT="file-backup.service"
WATCHDOG_TEMPLATE_UNIT="backup-suite-watchdog@.service"
WATCHDOG_INSTANCE_UNIT="backup-suite-watchdog@file-backup.service"
PROFILE_DROPIN_DIR="$UNIT_DIR/$SERVICE_UNIT.d"
RUN_ID=$(date -u '+%Y%m%dT%H%M%SZ')
BACKUP_DIR=""
CHECK_ONLY=0
REQUESTED_PROFILE=""
REQUESTED_FLOOR=""
REQUESTED_LIMITS=""
RUNNING_BACKUP_POLICY="wait"
WAIT_LIMIT_SECONDS="${BACKUP_SUITE_DEPLOY_WAIT_LIMIT_SECONDS:-14400}"
SEND_TEST_NOTIFICATION=0
TIMER_WAS_ENABLED=0
TIMER_WAS_ACTIVE=0
TIMER_PAUSED=0
DEPLOY_STARTED=0
DEPLOY_SUCCEEDED=0

usage() {
    cat <<'EOF'
Usage: sudo ./production-deploy.sh [options]

Deploys the current Backup Suite source to this host: scripts, the resource
watchdog, the file-backup resource profile, and the ntfy notification format.
file-backup.timer is never disabled. On failure the previous installation is
restored and the timer restarted.

Options:
  --profile slow|moderate|fast|custom
                   resource profile to apply (asked interactively when omitted
                   in a terminal; otherwise the configured profile, or moderate)
  --floor slow|moderate
                   adaptive mode: start at --profile and let the watchdog step
                   down to this floor when resources are tight, and back up when
                   they are normal (for example --profile moderate --floor slow)
  --fixed          keep a single profile (the default unless --floor is given)
  --limits fixed|auto
                   built-in limits, or limits scaled to this host's RAM and CPU
  --wait           wait for a running backup to finish before deploying (default)
  --stop-running   stop a running backup instead of waiting (its projects are
                   retried by the next run; remote versions stay protected)
  --test-notification
                   send one ntfy test message in the new format after deploying
  --check          run source checks and tests only; change nothing
  -h, --help       show this help
EOF
}

log() {
    printf '[backup-suite-deploy] %s\n' "$*"
}

die() {
    log "ERROR: $*" >&2
    exit 1
}

restore_previous_installation() {
    local backup_file

    [ -n "$BACKUP_DIR" ] && [ -d "$BACKUP_DIR" ] || return 0
    log "Restoring the previous installation from $BACKUP_DIR"
    if [ -d "$BACKUP_DIR/install-bin" ]; then
        rm -rf "$INSTALL_DIR/bin.deploy-restore"
        cp -a "$BACKUP_DIR/install-bin" "$INSTALL_DIR/bin.deploy-restore"
        rm -rf "$INSTALL_DIR/bin"
        mv "$INSTALL_DIR/bin.deploy-restore" "$INSTALL_DIR/bin"
    fi
    for backup_file in file-backup.service backup-suite-notify@.service "$WATCHDOG_TEMPLATE_UNIT"; do
        if [ -f "$BACKUP_DIR/units/$backup_file" ]; then
            cp -a "$BACKUP_DIR/units/$backup_file" "$UNIT_DIR/$backup_file"
        elif [ -f "$BACKUP_DIR/units/.absent-$backup_file" ]; then
            rm -f "$UNIT_DIR/$backup_file"
        fi
    done
    rm -rf "$PROFILE_DROPIN_DIR"
    if [ -d "$BACKUP_DIR/units/$SERVICE_UNIT.d" ]; then
        cp -a "$BACKUP_DIR/units/$SERVICE_UNIT.d" "$PROFILE_DROPIN_DIR"
    fi
    if [ -f "$BACKUP_DIR/global.conf" ]; then
        cat "$BACKUP_DIR/global.conf" > "$(readlink -f "$GLOBAL_CONFIG")"
    fi
    systemctl daemon-reload || true
}

on_exit() {
    local status=$?

    if [ "$CHECK_ONLY" -eq 0 ] && [ "$DEPLOY_STARTED" -eq 1 ] && [ "$DEPLOY_SUCCEEDED" -ne 1 ]; then
        log "Deployment did not complete; rolling back so backups keep running on the previous version."
        restore_previous_installation || log "Rollback reported an error; inspect $BACKUP_DIR" >&2
    fi
    if [ "$TIMER_PAUSED" -eq 1 ]; then
        if [ "$TIMER_WAS_ENABLED" -eq 1 ]; then
            systemctl enable "$TIMER_UNIT" >/dev/null 2>&1 || true
        fi
        if [ "$TIMER_WAS_ACTIVE" -eq 1 ]; then
            systemctl start "$TIMER_UNIT" || log "Could not restart $TIMER_UNIT; run: sudo systemctl start $TIMER_UNIT" >&2
        fi
        log "$TIMER_UNIT state restored: enabled=$(systemctl is-enabled "$TIMER_UNIT" 2>/dev/null || true) active=$(systemctl is-active "$TIMER_UNIT" 2>/dev/null || true)"
    fi
    if [ "$status" -ne 0 ]; then
        log "Deployment failed with exit code $status."
    fi
}

trap on_exit EXIT

while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile)
            [ "$#" -ge 2 ] || die "--profile requires a value"
            REQUESTED_PROFILE="${2,,}"
            case "$REQUESTED_PROFILE" in
                slow|moderate|fast|custom) ;;
                *) die "Unknown profile: $2" ;;
            esac
            shift
            ;;
        --floor)
            [ "$#" -ge 2 ] || die "--floor requires a value"
            REQUESTED_FLOOR="${2,,}"
            case "$REQUESTED_FLOOR" in
                slow|moderate) ;;
                *) die "Unknown floor: $2 (use slow or moderate)" ;;
            esac
            shift
            ;;
        --fixed)
            REQUESTED_FLOOR=""
            ;;
        --limits)
            [ "$#" -ge 2 ] || die "--limits requires fixed or auto"
            REQUESTED_LIMITS="${2,,}"
            case "$REQUESTED_LIMITS" in
                fixed|auto) ;;
                *) die "Unknown limits mode: $2" ;;
            esac
            shift
            ;;
        --wait)
            RUNNING_BACKUP_POLICY="wait"
            ;;
        --stop-running)
            RUNNING_BACKUP_POLICY="stop"
            ;;
        --test-notification)
            SEND_TEST_NOTIFICATION=1
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
    "$SOURCE_DIR/bin/file-backup-service.sh"
    "$SOURCE_DIR/bin/notify-failure.sh"
    "$SOURCE_DIR/bin/notify-lib.sh"
    "$SOURCE_DIR/bin/notify-test.sh"
    "$SOURCE_DIR/bin/backup-watchdog.sh"
    "$SOURCE_DIR/bin/backup-profile.sh"
    "$SOURCE_DIR/systemd/file-backup.service.template"
    "$SOURCE_DIR/systemd/backup-suite-notify@.service.template"
    "$SOURCE_DIR/systemd/backup-suite-watchdog@.service.template"
    "$SOURCE_DIR/tests/run.sh"
)
for source_file in "${required_source_files[@]}"; do
    [ -f "$source_file" ] || die "Required source file is missing: $source_file"
done
for command_name in awk cp find flock git grep install mktemp readlink sed systemctl systemd-analyze; do
    command -v "$command_name" >/dev/null 2>&1 || die "Required command not found: $command_name"
done
[[ "$WAIT_LIMIT_SECONDS" =~ ^[0-9]+$ ]] || die "BACKUP_SUITE_DEPLOY_WAIT_LIMIT_SECONDS must be an integer"

bash -n "$SOURCE_DIR/setup.sh" "$SOURCE_DIR/production-deploy.sh" "$SOURCE_DIR"/bin/*.sh "$SOURCE_DIR/tests/run.sh" "$SOURCE_DIR/tests/fixtures"/*.sh
if [ -d "$SOURCE_DIR/.git" ]; then
    if ! git -C "$SOURCE_DIR" diff --quiet || ! git -C "$SOURCE_DIR" diff --cached --quiet; then
        die "Tracked repository changes are present. Commit or discard them before deploying."
    fi
    log "Source commit: $(git -C "$SOURCE_DIR" rev-parse --short HEAD)"
fi

log "Running the repository integration suite."
"$SOURCE_DIR/tests/run.sh"

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "Check-only preflight passed. No production changes were made."
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "Run this script with sudo."
[ -f "$GLOBAL_CONFIG" ] || die "Production config is missing: $GLOBAL_CONFIG"
[ -d "$INSTALL_DIR/bin" ] || die "No existing installation at $INSTALL_DIR; use setup.sh for a first install."

exec {DEPLOY_LOCK_FD}>/run/backup-suite-production-deploy.lock
flock -n "$DEPLOY_LOCK_FD" || die "Another Backup Suite deployment is already running."

if [ -z "$REQUESTED_PROFILE" ]; then
    configured_profile=$(bash -c '. "$1"; printf "%s" "${FILE_BACKUP_PROFILE:-}"' _ "$(readlink -f "$GLOBAL_CONFIG")")
    if [ -t 0 ] && [ -t 1 ]; then
        BACKUP_SUITE_CONFIG_DIR="$CONFIG_DIR" "$SOURCE_DIR/bin/backup-profile.sh" show
        echo ""
        read -r -p "Profile to apply [slow/moderate/fast, Enter = ${configured_profile:-moderate}]: " REQUESTED_PROFILE
        REQUESTED_PROFILE="${REQUESTED_PROFILE,,}"
    fi
    REQUESTED_PROFILE="${REQUESTED_PROFILE:-${configured_profile:-moderate}}"
    case "$REQUESTED_PROFILE" in
        slow|moderate|fast|custom) ;;
        *) die "Unknown profile: $REQUESTED_PROFILE" ;;
    esac
    if [ -t 0 ] && [ -t 1 ] && [ -z "$REQUESTED_FLOOR" ] && [ "$REQUESTED_PROFILE" != "slow" ] && [ "$REQUESTED_PROFILE" != "custom" ]; then
        read -r -p "Adaptive floor (watchdog steps down to it when resources are tight) [slow/moderate, Enter = fixed $REQUESTED_PROFILE]: " REQUESTED_FLOOR
        REQUESTED_FLOOR="${REQUESTED_FLOOR,,}"
        case "$REQUESTED_FLOOR" in
            ""|slow|moderate) ;;
            *) die "Unknown floor: $REQUESTED_FLOOR" ;;
        esac
    fi
fi
if [ -n "$REQUESTED_FLOOR" ]; then
    [ "$REQUESTED_PROFILE" != "custom" ] || die "Adaptive mode needs --profile fast, moderate, or slow"
    [ "$REQUESTED_FLOOR" != "$REQUESTED_PROFILE" ] || REQUESTED_FLOOR=""
fi
if [ -n "$REQUESTED_FLOOR" ]; then
    log "Setup to apply: adaptive $REQUESTED_PROFILE -> $REQUESTED_FLOOR"
else
    log "Setup to apply: fixed $REQUESTED_PROFILE"
fi

systemctl is-enabled --quiet "$TIMER_UNIT" 2>/dev/null && TIMER_WAS_ENABLED=1
systemctl is-active --quiet "$TIMER_UNIT" 2>/dev/null && TIMER_WAS_ACTIVE=1
log "$TIMER_UNIT before deployment: enabled=$TIMER_WAS_ENABLED active=$TIMER_WAS_ACTIVE"

# Stop (never disable) the timer so no run starts while files are replaced.
TIMER_PAUSED=1
systemctl stop "$TIMER_UNIT" >/dev/null 2>&1 || true

if systemctl is-active --quiet "$SERVICE_UNIT"; then
    if [ "$RUNNING_BACKUP_POLICY" = "stop" ]; then
        log "Stopping the running backup as requested (--stop-running)."
        systemctl stop "$SERVICE_UNIT"
    else
        log "A backup is running; waiting for it to finish (use --stop-running to stop it instead)."
        waited=0
        while systemctl is-active --quiet "$SERVICE_UNIT"; do
            [ "$waited" -lt "$WAIT_LIMIT_SECONDS" ] || die "The running backup did not finish within ${WAIT_LIMIT_SECONDS}s; nothing was changed."
            sleep 30
            waited=$((waited + 30))
            if [ $((waited % 600)) -eq 0 ]; then
                log "Still waiting for the running backup ($((waited / 60)) min)."
            fi
        done
        log "The running backup finished; continuing."
    fi
fi

BACKUP_DIR="$STATE_DIR/deploy-backups/$RUN_ID"
install -d -m 700 "$BACKUP_DIR" "$BACKUP_DIR/units"
cp -a "$INSTALL_DIR/bin" "$BACKUP_DIR/install-bin"
cp -a "$(readlink -f "$GLOBAL_CONFIG")" "$BACKUP_DIR/global.conf"
for unit_file in file-backup.service backup-suite-notify@.service "$WATCHDOG_TEMPLATE_UNIT"; do
    if [ -f "$UNIT_DIR/$unit_file" ]; then
        cp -a "$UNIT_DIR/$unit_file" "$BACKUP_DIR/units/$unit_file"
    else
        : > "$BACKUP_DIR/units/.absent-$unit_file"
    fi
done
if [ -d "$PROFILE_DROPIN_DIR" ]; then
    cp -a "$PROFILE_DROPIN_DIR" "$BACKUP_DIR/units/$SERVICE_UNIT.d"
fi
log "Previous installation saved to $BACKUP_DIR"
DEPLOY_STARTED=1

log "Installing scripts (production config and credentials are not replaced)."
install -d -m 755 "$INSTALL_DIR/bin" "$CANONICAL_DIR/bin" "$CANONICAL_DIR/systemd"
install -m 755 "$SOURCE_DIR"/bin/*.sh "$INSTALL_DIR/bin/"
install -m 755 "$SOURCE_DIR"/bin/*.sh "$CANONICAL_DIR/bin/"
install -m 644 "$SOURCE_DIR"/systemd/*.template "$CANONICAL_DIR/systemd/"
install -m 755 "$SOURCE_DIR/setup.sh" "$SOURCE_DIR/production-deploy.sh" "$SOURCE_DIR/production-file-backup-migrate.sh" "$CANONICAL_DIR/"
install -m 644 "$SOURCE_DIR/README.md" "$INSTALL_DIR/README.md"

render_unit() {
    local template_file="$1"
    local output_file="$2"
    local rendered_file
    local runtime_max

    runtime_max=$(bash -c '. "$1"; printf "%s" "${FILE_BACKUP_RUNTIME_MAX_SEC:-6h}"' _ "$(readlink -f "$GLOBAL_CONFIG")")
    rendered_file=$(mktemp)
    sed \
        -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
        -e "s|__CONFIG_DIR__|$CONFIG_DIR|g" \
        -e 's|__USER_GROUP_DIRECTIVES__||g' \
        -e "s|__LOCK_FILE__|$STATE_DIR/locks/file-backup.service.lock|g" \
        -e "s|__FILE_BACKUP_RUNTIME_MAX_SEC__|$runtime_max|g" \
        -e 's|__WATCHDOG_PRIVILEGED_DIRECTIVES__|Nice=-5\nOOMScoreAdjust=-900|g' \
        "$template_file" > "$rendered_file"
    if grep -Eq '__[A-Z0-9_]+__' "$rendered_file"; then
        rm -f "$rendered_file"
        die "Unresolved placeholder in rendered $(basename "$output_file")"
    fi
    install -m 644 -o 0 -g 0 "$rendered_file" "$output_file"
    rm -f "$rendered_file"
}

log "Installing systemd units: $SERVICE_UNIT, $WATCHDOG_TEMPLATE_UNIT, backup-suite-notify@.service"
render_unit "$SOURCE_DIR/systemd/file-backup.service.template" "$UNIT_DIR/$SERVICE_UNIT"
render_unit "$SOURCE_DIR/systemd/backup-suite-watchdog@.service.template" "$UNIT_DIR/$WATCHDOG_TEMPLATE_UNIT"
render_unit "$SOURCE_DIR/systemd/backup-suite-notify@.service.template" "$UNIT_DIR/backup-suite-notify@.service"
systemd-analyze verify "$UNIT_DIR/$SERVICE_UNIT" "$UNIT_DIR/$WATCHDOG_INSTANCE_UNIT"
systemctl daemon-reload

if [ -n "$REQUESTED_LIMITS" ]; then
    log "Setting limits mode '$REQUESTED_LIMITS'."
    BACKUP_SUITE_CONFIG_DIR="$CONFIG_DIR" "$INSTALL_DIR/bin/backup-profile.sh" limits "$REQUESTED_LIMITS"
fi
if [ -n "$REQUESTED_FLOOR" ]; then
    log "Applying adaptive profile '$REQUESTED_PROFILE' with floor '$REQUESTED_FLOOR'."
    BACKUP_SUITE_CONFIG_DIR="$CONFIG_DIR" "$INSTALL_DIR/bin/backup-profile.sh" adaptive "$REQUESTED_PROFILE" "$REQUESTED_FLOOR"
else
    log "Applying fixed profile '$REQUESTED_PROFILE'."
    BACKUP_SUITE_CONFIG_DIR="$CONFIG_DIR" "$INSTALL_DIR/bin/backup-profile.sh" set "$REQUESTED_PROFILE"
fi
BACKUP_SUITE_CONFIG_DIR="$CONFIG_DIR" "$INSTALL_DIR/bin/backup-profile.sh" show

# Verify that systemd accepted the top profile (the unit's starting limits)
# and the watchdog wiring, using the saved config including any overrides.
# shellcheck source=/dev/null
. "$INSTALL_DIR/bin/common.sh"
load_global_config
resolve_profile_ladder
resolve_file_backup_profile "${PROFILE_LADDER[0]}"
assert_service_property() {
    local property_name="$1"
    local expected_value="$2"
    local actual_value

    actual_value=$(systemctl show "$SERVICE_UNIT" -p "$property_name" --value)
    [ "$actual_value" = "$expected_value" ] || die "$SERVICE_UNIT property $property_name is '$actual_value'; expected '$expected_value'"
}
assert_service_property MemoryHigh "$(size_to_bytes "$PROFILE_MEMORY_HIGH")"
assert_service_property MemoryMax "$(size_to_bytes "$PROFILE_MEMORY_MAX")"
assert_service_property MemorySwapMax "$(size_to_bytes "$PROFILE_MEMORY_SWAP_MAX")"
assert_service_property TasksMax "$PROFILE_TASKS_MAX"
assert_service_property CPUWeight "$PROFILE_CPU_WEIGHT"
assert_service_property IOWeight "$PROFILE_IO_WEIGHT"
quota_ms=$(( ${PROFILE_CPU_QUOTA%\%} * 10 ))
if [ $((quota_ms % 1000)) -eq 0 ]; then
    assert_service_property CPUQuotaPerSecUSec "$((quota_ms / 1000))s"
else
    assert_service_property CPUQuotaPerSecUSec "${quota_ms}ms"
fi
assert_service_property Restart no
assert_service_property KillMode control-group
assert_service_property OOMPolicy stop
systemctl show "$SERVICE_UNIT" -p Wants --value | grep -Fq "$WATCHDOG_INSTANCE_UNIT" || die "$SERVICE_UNIT does not pull in $WATCHDOG_INSTANCE_UNIT"
log "systemd accepted the profile limits and the watchdog wiring."

BACKUP_SUITE_CONFIG_DIR="$CONFIG_DIR" "$INSTALL_DIR/bin/backup-watchdog.sh" "$SERVICE_UNIT" --self-test

DEPLOY_SUCCEEDED=1
log "Deployment complete. Backup copy of the previous installation: $BACKUP_DIR"

if [ "$SEND_TEST_NOTIFICATION" -eq 1 ]; then
    BACKUP_SUITE_CONFIG_DIR="$CONFIG_DIR" "$INSTALL_DIR/bin/notify-test.sh" || log "The test notification could not be sent; check NOTIFY_* settings." >&2
fi
