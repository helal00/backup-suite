#!/bin/bash
# Backup Suite control script: one JSON request on stdin, one JSON reply on
# stdout. The GUI uses it in both install modes:
#   user mode:   the GUI starts it directly, as the user;
#   system mode: backup-suite-control@.service starts it as root for each
#                connection to /run/backup-suite/control.sock, with --peer %i.
# The verbs are implemented once in backup-control.py; this wrapper resolves
# Backup Suite's configuration and checks who is calling.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
. "$SCRIPT_DIR/common.sh"

reply_error() {
    printf '{"ok":false,"error":{"code":"%s","message":"%s"}}\n' "$1" "$(json_escape "$2")"
    exit 0
}

# Library failures become JSON errors instead of a bare exit.
fail() {
    reply_error config_error "$*"
}

usage() {
    cat <<'EOF'
Usage: backup-control.sh [--peer <systemd-instance>]

Reads one JSON request on stdin and writes one JSON reply on stdout, for
example:
  echo '{"verb":"status"}' | backup-control.sh

--peer is set by backup-suite-control@.service: the instance name of an
accepted Unix socket connection is <n>-<peer pid>-<peer uid>. Only root and
members of the GUI admin group (BACKUP_SUITE_GUI_GROUP, default
backup-suite-gui) may use the broker.
EOF
}

peer_instance=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --peer)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            peer_instance="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
done

caller_uid=$(id -u)
caller_login=$(id -un)
gui_group="${BACKUP_SUITE_GUI_GROUP:-backup-suite-gui}"
if [ -n "$peer_instance" ]; then
    caller_uid="${peer_instance##*-}"
    [[ "$caller_uid" =~ ^[0-9]+$ ]] || reply_error forbidden "Unknown caller."
    caller_login=$(getent passwd "$caller_uid" | cut -d: -f1 || true)
    if [ "$caller_uid" != "0" ]; then
        if [ -z "$caller_login" ] || ! id -nG "$caller_login" 2>/dev/null | tr ' ' '\n' | grep -Fxq -- "$gui_group"; then
            logger -t backup-suite-control "refused connection from uid $caller_uid (${caller_login:-unknown}): not in group $gui_group" 2>/dev/null || true
            reply_error forbidden "uid $caller_uid is not a member of $gui_group."
        fi
    fi
fi

load_global_config

command -v python3 >/dev/null 2>&1 || reply_error unavailable "python3 is required for the Backup Suite control script."

export BSC_MODE="$EFFECTIVE_INSTALL_MODE"
export BSC_SYSTEMD_SCOPE="$SYSTEMD_SCOPE"
export BSC_BIN_DIR="$SCRIPT_DIR"
export BSC_CONFIG_DIR="$CONFIG_DIR"
export BSC_GLOBAL_CONFIG_FILE="$GLOBAL_CONFIG_FILE"
export BSC_STATE_DIR="$STATE_DIR"
export BSC_SOURCES_FILE="$FILE_SOURCE_CONFIG_PATH"
export BSC_SYSTEMD_UNIT_DIR="$SYSTEMD_UNIT_DIR"
export BSC_EXCLUDE_FILENAME="${FILE_PROJECT_EXCLUDE_FILENAME:-.backup-excludes}"
export BSC_ACTIVE_MAX_DEFERRALS="${FILE_ACTIVE_MAX_DEFERRALS:-12}"
export BSC_CALLER_UID="$caller_uid"
export BSC_CALLER_LOGIN="${caller_login:-uid-$caller_uid}"
export BSC_HOSTNAME="${REMOTE_HOSTNAME:-$(hostname)}"
export BACKUP_SUITE_CONFIG_DIR

exec python3 -I "$SCRIPT_DIR/backup-control.py"
