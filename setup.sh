#!/bin/bash

set -euo pipefail

SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SOURCE_CONFIG_DIR="$SOURCE_DIR/config"
DRY_RUN=0
REFRESH_SCRIPTS=0
REFRESH_CONFIG=0
REFRESH_UNITS=0
AUTO_YES=0
CONFIRMED_SCRIPTS=0
CONFIRMED_CONFIG=0
CONFIRMED_UNITS=0
CONFIRMED_SOURCE_TREE=0

# shellcheck source=/dev/null
. "$SOURCE_DIR/bin/common.sh"

run_cmd() {
    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

usage() {
    cat <<'EOF'
Usage: setup.sh [--dry-run] [--refresh-scripts] [--refresh-config] [--refresh-units] [--yes]

This script installs Backup Suite in user mode or system mode, depending on how it is run.
It deploys the runtime scripts, symlinks runtime config back to the canonical source tree,
and installs matching systemd units.

Edit the real config files in the source tree before running this script.
EOF
}

write_file() {
    local target_file="$1"
    local file_content="$2"

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] write %s\n' "$target_file"
    else
        printf '%s' "$file_content" > "$target_file"
    fi
}

replace_line_in_file() {
    local target_file="$1"
    local match_prefix="$2"
    local replacement_line="$3"

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] update %s -> %s\n' "$target_file" "$replacement_line"
    else
        sed -i "s|^${match_prefix}=.*|${replacement_line}|" "$target_file"
    fi
}

trim() {
    local value="$1"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    printf '%s' "$value"
}

is_enabled_value_local() {
    case "$1" in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        *) return 1 ;;
    esac
}

confirm_category() {
    local category="$1"
    local prompt="$2"
    local current_flag_name="$3"
    local current_flag_value

    current_flag_value=$(eval "printf '%s' \"\${$current_flag_name}\"")
    if [ "$current_flag_value" -eq 1 ]; then
        return 0
    fi

    if [ "$AUTO_YES" -eq 1 ]; then
        eval "$current_flag_name=1"
        return 0
    fi

    printf '%s\n' "$prompt"
    read -r -p "Proceed? [yes/NO] " answer
    if [ "$answer" = "yes" ]; then
        eval "$current_flag_name=1"
        return 0
    fi

    echo "Skipping overwrite for category: $category"
    return 1
}

choose_install_mode() {
    local requested_mode="$1"

    if [ "$requested_mode" = "user" ] && [ "$(id -u)" -eq 0 ]; then
        echo "User mode must be installed by the target user without sudo and not while logged in directly as root." >&2
        echo "Re-run this setup script as that user without sudo to install into their home directory." >&2
        exit 1
    fi

    if [ "$requested_mode" != "auto" ]; then
        return 0
    fi

    if [ "$(id -u)" -ne 0 ]; then
        INSTALL_MODE="user"
        return 0
    fi

    if [ "$AUTO_YES" -eq 1 ]; then
        INSTALL_MODE="system"
        return 0
    fi

    cat <<'EOF'
Root privileges were detected, so Backup Suite can be installed system-wide.

This applies whether you ran the script with sudo or you are logged in directly as root.

Choose installation action:
  1. system  -> install under system paths such as /opt, /etc, /var and use system systemd units
  2. cancel  -> stop now and re-run this script without sudo as the target user for a user-mode install
EOF

    while true; do
        read -r -p "Install action [system/cancel]: " install_mode_answer
        case "$install_mode_answer" in
            system)
                INSTALL_MODE="system"
                return 0
                ;;
            cancel)
                echo "Cancelled. Re-run this setup script without sudo as the target user to install in user mode."
                exit 0
                ;;
            *)
                echo "Please answer 'system' or 'cancel'."
                ;;
        esac
    done
}

require_source_configs() {
    [ -f "$SOURCE_CONFIG_DIR/global.conf" ] || fail "Missing source config: $SOURCE_CONFIG_DIR/global.conf"
    [ -f "$SOURCE_CONFIG_DIR/file-sources.conf" ] || fail "Missing source config: $SOURCE_CONFIG_DIR/file-sources.conf"
    [ -f "$SOURCE_CONFIG_DIR/database-backups.conf" ] || fail "Missing source config: $SOURCE_CONFIG_DIR/database-backups.conf"
    [ -f "$SOURCE_CONFIG_DIR/rclone.conf" ] || fail "Missing source config: $SOURCE_CONFIG_DIR/rclone.conf"
    [ -d "$SOURCE_CONFIG_DIR/mysql-profiles" ] || fail "Missing source config directory: $SOURCE_CONFIG_DIR/mysql-profiles"
}

deploy_file() {
    local source_file="$1"
    local target_file="$2"
    local mode="$3"
    local category="$4"
    local confirmation_flag="$5"
    local description="$6"

    if [ -e "$target_file" ] || [ -L "$target_file" ]; then
        case "$category" in
            scripts)
                [ "$REFRESH_SCRIPTS" -eq 1 ] || {
                    echo "Keeping existing $description: $target_file"
                    return 0
                }
                ;;
            units)
                [ "$REFRESH_UNITS" -eq 1 ] || {
                    echo "Keeping existing $description: $target_file"
                    return 0
                }
                ;;
            config)
                [ "$REFRESH_CONFIG" -eq 1 ] || {
                    echo "Keeping existing $description: $target_file"
                    return 0
                }
                ;;
        esac

        confirm_category "$category" "About to overwrite $description: $target_file" "$confirmation_flag" || return 0
    fi

    run_cmd install -m "$mode" "$source_file" "$target_file"
}

deploy_symlink() {
    local source_file="$1"
    local target_file="$2"
    local category="$3"
    local confirmation_flag="$4"
    local description="$5"

    if [ -L "$target_file" ] && [ "$(readlink "$target_file")" = "$source_file" ]; then
        echo "Keeping existing $description symlink: $target_file"
        return 0
    fi

    if [ -e "$target_file" ] || [ -L "$target_file" ]; then
        [ "$REFRESH_CONFIG" -eq 1 ] || {
            echo "Keeping existing $description: $target_file"
            return 0
        }
        confirm_category "$category" "About to overwrite $description: $target_file" "$confirmation_flag" || return 0
        run_cmd rm -rf "$target_file"
    fi

    run_cmd ln -s "$source_file" "$target_file"
}

append_if_missing() {
    local target_file="$1"
    local marker="$2"
    local content="$3"

    if grep -Fq "$marker" "$target_file" 2>/dev/null; then
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        printf '[dry-run] append %s\n' "$target_file"
    else
        printf '%s' "$content" >> "$target_file"
    fi
}

deploy_canonical_source_tree() {
    local target_dir="$1"
    local source_refresh_requested=0

    if [ "$REFRESH_SCRIPTS" -eq 1 ] || [ "$REFRESH_CONFIG" -eq 1 ] || [ "$REFRESH_UNITS" -eq 1 ]; then
        source_refresh_requested=1
    fi

    if [ ! -d "$target_dir" ]; then
        run_cmd install -d -m 755 "$target_dir"
        run_cmd cp -a "$SOURCE_DIR/." "$target_dir/"
        return 0
    fi

    if [ "$source_refresh_requested" -eq 1 ]; then
        confirm_category "scripts" "About to refresh canonical source tree: $target_dir" CONFIRMED_SOURCE_TREE || return 0
        run_cmd rm -rf "$target_dir"
        run_cmd install -d -m 755 "$target_dir"
        run_cmd cp -a "$SOURCE_DIR/." "$target_dir/"
    fi
}

ensure_remote_hostname_pinned() {
    local config_file="$1"
    local discovered_hostname

    if [ -n "$(trim "${REMOTE_HOSTNAME:-}")" ]; then
        return 0
    fi

    discovered_hostname=$(hostname)
    REMOTE_HOSTNAME="$discovered_hostname"
    echo "REMOTE_HOSTNAME is empty. Pinning discovered hostname '$discovered_hostname' into $config_file"
    replace_line_in_file "$config_file" "REMOTE_HOSTNAME" "REMOTE_HOSTNAME=\"$discovered_hostname\""
}

render_unit() {
    local template_file="$1"
    local output_file="$2"
    local lock_file="$3"
    local rendered_unit

    rendered_unit=$(sed \
        -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
        -e "s|__CONFIG_DIR__|$CONFIG_DIR|g" \
        -e "s|__USER_GROUP_DIRECTIVES__||g" \
        -e "s|__LOCK_FILE__|$lock_file|g" \
        -e "s|__FILE_BACKUP_ONCALENDAR__|$FILE_BACKUP_ONCALENDAR|g" \
        -e "s|__DB_BACKUP_ONCALENDAR__|$DB_BACKUP_ONCALENDAR|g" \
        -e "s|__DB_MONITOR_ONCALENDAR__|$DB_MONITOR_ONCALENDAR|g" \
        "$template_file")

    if [ -e "$output_file" ] || [ -L "$output_file" ]; then
        [ "$REFRESH_UNITS" -eq 1 ] || {
            echo "Keeping existing systemd unit: $output_file"
            return 0
        }
        confirm_category "units" "About to overwrite systemd unit: $output_file" CONFIRMED_UNITS || return 0
    fi

    write_file "$output_file" "$rendered_unit"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --refresh-scripts)
            REFRESH_SCRIPTS=1
            ;;
        --refresh-config)
            REFRESH_CONFIG=1
            ;;
        --refresh-units)
            REFRESH_UNITS=1
            ;;
        --yes)
            AUTO_YES=1
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
    shift
done

require_source_configs

# shellcheck source=/dev/null
. "$SOURCE_CONFIG_DIR/global.conf"

choose_install_mode "${INSTALL_MODE:-auto}"
resolve_effective_config

: "${INSTALL_DIR:?INSTALL_DIR must resolve from config/global.conf}"
: "${CONFIG_DIR:?CONFIG_DIR must resolve from config/global.conf}"
: "${STATE_DIR:?STATE_DIR must resolve from config/global.conf}"
: "${RCLONE_CONFIG_PATH:?RCLONE_CONFIG_PATH must resolve from config/global.conf}"
: "${MYSQL_PROFILE_DIR:?MYSQL_PROFILE_DIR must resolve from config/global.conf}"

if [ "$EFFECTIVE_INSTALL_MODE" = "system" ] && [ "$(id -u)" -ne 0 ]; then
    fail "System mode requires sudo or direct root execution."
fi

CANONICAL_SOURCE_DIR="$SOURCE_DIR"
if [ "$EFFECTIVE_INSTALL_MODE" = "system" ]; then
    CANONICAL_SOURCE_DIR="$SYSTEM_CANONICAL_SOURCE_DIR"
fi

echo "Installing Backup Suite into $INSTALL_DIR"
echo "Configuration directory: $CONFIG_DIR"
echo "Effective install mode: $EFFECTIVE_INSTALL_MODE"
echo "Canonical source directory: $CANONICAL_SOURCE_DIR"

if [ "$EFFECTIVE_INSTALL_MODE" = "system" ]; then
    deploy_canonical_source_tree "$CANONICAL_SOURCE_DIR"
    run_cmd chown -R root:root "$CANONICAL_SOURCE_DIR"
fi

READ_SOURCE_DIR="$CANONICAL_SOURCE_DIR"
if [ "$DRY_RUN" -eq 1 ] && [ "$EFFECTIVE_INSTALL_MODE" = "system" ]; then
    READ_SOURCE_DIR="$SOURCE_DIR"
fi
READ_CONFIG_DIR="$READ_SOURCE_DIR/config"
DEPLOYED_CONFIG_SOURCE_DIR="$CANONICAL_SOURCE_DIR/config"

if [ "$EFFECTIVE_INSTALL_MODE" = "system" ]; then
    ensure_remote_hostname_pinned "$DEPLOYED_CONFIG_SOURCE_DIR/global.conf"
else
    ensure_remote_hostname_pinned "$SOURCE_CONFIG_DIR/global.conf"
fi

run_cmd install -d -m 755 "$INSTALL_DIR"
run_cmd install -d -m 755 "$INSTALL_DIR/bin"
run_cmd install -d -m 755 "$INSTALL_DIR/systemd"
run_cmd install -d -m 750 "$CONFIG_DIR"
run_cmd install -d -m 755 "$STATE_DIR"
run_cmd install -d -m 750 "$DB_LOCAL_OUTPUT_DIR"

deploy_file "$READ_SOURCE_DIR/bin/common.sh" "$INSTALL_DIR/bin/common.sh" 755 scripts CONFIRMED_SCRIPTS "installed script"
deploy_file "$READ_SOURCE_DIR/bin/systemd-fork-run.sh" "$INSTALL_DIR/bin/systemd-fork-run.sh" 755 scripts CONFIRMED_SCRIPTS "installed script"
deploy_file "$READ_SOURCE_DIR/bin/file-backup.sh" "$INSTALL_DIR/bin/file-backup.sh" 755 scripts CONFIRMED_SCRIPTS "installed script"
deploy_file "$READ_SOURCE_DIR/bin/database-backup.sh" "$INSTALL_DIR/bin/database-backup.sh" 755 scripts CONFIRMED_SCRIPTS "installed script"
deploy_file "$READ_SOURCE_DIR/bin/database-size-check.sh" "$INSTALL_DIR/bin/database-size-check.sh" 755 scripts CONFIRMED_SCRIPTS "installed script"
deploy_file "$READ_SOURCE_DIR/bin/notify-failure.sh" "$INSTALL_DIR/bin/notify-failure.sh" 755 scripts CONFIRMED_SCRIPTS "installed script"
deploy_file "$READ_SOURCE_DIR/README.md" "$INSTALL_DIR/README.md" 644 scripts CONFIRMED_SCRIPTS "installed documentation"

deploy_symlink "$DEPLOYED_CONFIG_SOURCE_DIR/global.conf" "$CONFIG_DIR/global.conf" config CONFIRMED_CONFIG "runtime config"
deploy_symlink "$DEPLOYED_CONFIG_SOURCE_DIR/file-sources.conf" "$CONFIG_DIR/file-sources.conf" config CONFIRMED_CONFIG "runtime config"
deploy_symlink "$DEPLOYED_CONFIG_SOURCE_DIR/database-backups.conf" "$CONFIG_DIR/database-backups.conf" config CONFIRMED_CONFIG "runtime config"
deploy_symlink "$DEPLOYED_CONFIG_SOURCE_DIR/rclone.conf" "$CONFIG_DIR/rclone.conf" config CONFIRMED_CONFIG "runtime config"
deploy_symlink "$DEPLOYED_CONFIG_SOURCE_DIR/mysql-profiles" "$CONFIG_DIR/mysql-profiles" config CONFIRMED_CONFIG "runtime config directory"

if [ "$EFFECTIVE_INSTALL_MODE" = "system" ]; then
    append_if_missing "$DEPLOYED_CONFIG_SOURCE_DIR/file-sources.conf" "$SYSTEM_CANONICAL_SOURCE_DIR" "
# System-mode canonical source tree; enable and choose destination when you want to back it up.
0|backup-suite-system-source|$SYSTEM_CANONICAL_SOURCE_DIR|fixed|tools/backup-suite-src|.nosync
"
fi

if [ "$EFFECTIVE_INSTALL_MODE" = "system" ]; then
    run_cmd chmod 640 "$DEPLOYED_CONFIG_SOURCE_DIR/global.conf" "$DEPLOYED_CONFIG_SOURCE_DIR/file-sources.conf" "$DEPLOYED_CONFIG_SOURCE_DIR/database-backups.conf" "$DEPLOYED_CONFIG_SOURCE_DIR/rclone.conf"
    if [ -d "$READ_CONFIG_DIR/mysql-profiles" ] || [ "$DRY_RUN" -eq 1 ]; then
        while IFS= read -r profile_file; do
            run_cmd chmod 640 "$profile_file"
        done < <(find "$DEPLOYED_CONFIG_SOURCE_DIR/mysql-profiles" -type f -name '*.cnf' 2>/dev/null)
    fi
else
    run_cmd chmod 600 "$DEPLOYED_CONFIG_SOURCE_DIR/global.conf" "$DEPLOYED_CONFIG_SOURCE_DIR/file-sources.conf" "$DEPLOYED_CONFIG_SOURCE_DIR/database-backups.conf" "$DEPLOYED_CONFIG_SOURCE_DIR/rclone.conf"
    if [ -d "$READ_CONFIG_DIR/mysql-profiles" ] || [ "$DRY_RUN" -eq 1 ]; then
        while IFS= read -r profile_file; do
            run_cmd chmod 600 "$profile_file"
        done < <(find "$DEPLOYED_CONFIG_SOURCE_DIR/mysql-profiles" -type f -name '*.cnf' 2>/dev/null)
    fi
fi

if is_enabled_value_local "${INSTALL_SYSTEMD_UNITS:-1}"; then
    echo "Installing systemd units"
    run_cmd install -d -m 755 "$SYSTEMD_UNIT_DIR"

    file_lock="%t/backup-suite-file-backup.lock"
    db_lock="%t/backup-suite-database-backup.lock"
    monitor_lock="%t/backup-suite-database-monitor.lock"

    if [ "$EFFECTIVE_INSTALL_MODE" = "system" ]; then
        file_lock="/run/backup-suite/file-backup.lock"
        db_lock="/run/backup-suite/database-backup.lock"
        monitor_lock="/run/backup-suite/database-monitor.lock"
    fi

    render_unit "$READ_SOURCE_DIR/systemd/file-backup.service.template" "$SYSTEMD_UNIT_DIR/file-backup.service" "$file_lock"
    render_unit "$READ_SOURCE_DIR/systemd/file-backup.timer.template" "$SYSTEMD_UNIT_DIR/file-backup.timer" "$file_lock"
    render_unit "$READ_SOURCE_DIR/systemd/database-backup.service.template" "$SYSTEMD_UNIT_DIR/database-backup.service" "$db_lock"
    render_unit "$READ_SOURCE_DIR/systemd/database-backup.timer.template" "$SYSTEMD_UNIT_DIR/database-backup.timer" "$db_lock"
    render_unit "$READ_SOURCE_DIR/systemd/database-size-check.service.template" "$SYSTEMD_UNIT_DIR/database-size-check.service" "$monitor_lock"
    render_unit "$READ_SOURCE_DIR/systemd/database-size-check.timer.template" "$SYSTEMD_UNIT_DIR/database-size-check.timer" "$monitor_lock"
    render_unit "$READ_SOURCE_DIR/systemd/backup-suite-notify@.service.template" "$SYSTEMD_UNIT_DIR/backup-suite-notify@.service" ""

    run_cmd chmod 644 "$SYSTEMD_UNIT_DIR/file-backup.service" "$SYSTEMD_UNIT_DIR/file-backup.timer" "$SYSTEMD_UNIT_DIR/database-backup.service" "$SYSTEMD_UNIT_DIR/database-backup.timer" "$SYSTEMD_UNIT_DIR/database-size-check.service" "$SYSTEMD_UNIT_DIR/database-size-check.timer" "$SYSTEMD_UNIT_DIR/backup-suite-notify@.service"
    run_cmd "${SYSTEMCTL_COMMAND[@]}" daemon-reload

    if is_enabled_value_local "${ENABLE_TIMERS_AFTER_INSTALL:-0}"; then
        run_cmd "${SYSTEMCTL_COMMAND[@]}" enable --now file-backup.timer
        run_cmd "${SYSTEMCTL_COMMAND[@]}" enable --now database-backup.timer
        run_cmd "${SYSTEMCTL_COMMAND[@]}" enable --now database-size-check.timer
    fi
fi

echo "Backup Suite setup completed."
echo "Review the canonical source under $CANONICAL_SOURCE_DIR and runtime config links under $CONFIG_DIR before enabling timers on a live system."
