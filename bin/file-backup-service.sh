#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
lock_file="${1:-}"
mode="${BACKUP_SUITE_FILE_BACKUP_MODE:-normal}"

[ -n "$lock_file" ] || {
    echo "Usage: file-backup-service.sh <lock-file>" >&2
    exit 64
}

mkdir -p "$(dirname -- "$lock_file")"

case "$mode" in
    normal)
        mode_args=(--journal-only)
        ;;
    link-migration-report)
        mode_args=(--journal-only --link-migration-report)
        ;;
    confirm-link-migration)
        mode_args=(--journal-only --confirm-link-migration)
        ;;
    *)
        echo "Invalid BACKUP_SUITE_FILE_BACKUP_MODE: $mode" >&2
        exit 64
        ;;
esac

# Keep flock in the foreground so systemd owns the complete process tree. Every
# file-backup.sh and rclone descendant therefore remains in file-backup.service.
exec /usr/bin/flock -n -E 75 "$lock_file" "$SCRIPT_DIR/file-backup.sh" "${mode_args[@]}"
