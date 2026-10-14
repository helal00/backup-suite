#!/bin/bash
# Installs the system-mode control broker for the Backup Suite GUI: the admin
# group, its members, and the socket-activated units. Run as root by setup.sh
# (system mode) and production-deploy.sh.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: install-gui-broker.sh --templates DIR --install-dir DIR --config-dir DIR
                             --state-dir DIR [--unit-dir DIR] [--group NAME]
                             [--admin LOGIN]... [--no-start] [--check]
       install-gui-broker.sh --refresh-acl [--group NAME]

Creates group backup-suite-gui (or --group), adds each --admin (default: the
user who ran sudo, SUDO_USER), renders backup-suite-control.socket and
backup-suite-control@.service, and enables the socket.

Members of the group can use the GUI's control verbs as root. Name only the
logins that administer Backup Suite.

--check only verifies an existing installation and prints the members.

--refresh-acl grants each group member read/write on the socket through a
POSIX ACL (run by the socket unit on start). An ACL works at once; a new
group membership would only reach a running GUI after its user manager
restarts, which would also stop that user's other services.
EOF
}

die() {
    printf 'install-gui-broker: %s\n' "$*" >&2
    exit 1
}

template_dir=""
install_dir=""
config_dir=""
state_dir=""
unit_dir="/etc/systemd/system"
group_name="backup-suite-gui"
admins=()
start_socket=1
check_only=0
refresh_acl=0
socket_path="/run/backup-suite/control.sock"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --templates) template_dir="${2:?}"; shift ;;
        --install-dir) install_dir="${2:?}"; shift ;;
        --config-dir) config_dir="${2:?}"; shift ;;
        --state-dir) state_dir="${2:?}"; shift ;;
        --unit-dir) unit_dir="${2:?}"; shift ;;
        --group) group_name="${2:?}"; shift ;;
        --admin) admins+=("${2:?}"); shift ;;
        --no-start) start_socket=0 ;;
        --check) check_only=1 ;;
        --refresh-acl) refresh_acl=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "Run as root."
[[ "$group_name" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid group name: $group_name"

print_members() {
    local members

    members=$(getent group "$group_name" | cut -d: -f4)
    printf 'GUI admins (group %s): %s\n' "$group_name" "${members:-none}"
}

group_members() {
    getent group "$group_name" | cut -d: -f4 | tr ',' '\n' | sed '/^$/d'
}

apply_socket_acl() {
    local member

    [ -S "$socket_path" ] || return 0
    command -v setfacl >/dev/null 2>&1 || die "setfacl is required (package acl)."
    setfacl -b "$socket_path"
    while IFS= read -r member; do
        [[ "$member" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || continue
        setfacl -m "u:${member}:rw" "$socket_path"
    done < <(group_members)
}

if [ "$refresh_acl" -eq 1 ]; then
    apply_socket_acl
    exit 0
fi

if [ "$check_only" -eq 1 ]; then
    getent group "$group_name" >/dev/null || die "Group $group_name does not exist."
    systemctl is-active --quiet backup-suite-control.socket || die "backup-suite-control.socket is not active."
    [ -S /run/backup-suite/control.sock ] || die "/run/backup-suite/control.sock is missing."
    socket_owner=$(stat -c '%U:%G %a' /run/backup-suite/control.sock)
    [ "$socket_owner" = "root:$group_name 660" ] || die "control.sock is $socket_owner; expected root:$group_name 660."
    while IFS= read -r member; do
        getfacl -p "$socket_path" 2>/dev/null | grep -Fxq "user:${member}:rw-" || die "$member is in $group_name but has no ACL entry on $socket_path; run: systemctl restart backup-suite-control.socket"
    done < <(group_members)
    print_members
    exit 0
fi

[ -d "$template_dir" ] || die "--templates must be the directory holding the .template files."
[ -n "$install_dir" ] && [ -n "$config_dir" ] && [ -n "$state_dir" ] || die "--install-dir, --config-dir and --state-dir are required."
[ -x "$install_dir/bin/backup-control.sh" ] || die "$install_dir/bin/backup-control.sh is not installed."

if [ "${#admins[@]}" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    admins=("$SUDO_USER")
fi
for admin_login in "${admins[@]}"; do
    [[ "$admin_login" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "Invalid login: $admin_login"
    getent passwd "$admin_login" >/dev/null || die "No such user: $admin_login"
done

if ! getent group "$group_name" >/dev/null; then
    groupadd --system "$group_name"
    printf 'Created group %s\n' "$group_name"
fi
for admin_login in "${admins[@]}"; do
    if id -nG "$admin_login" | tr ' ' '\n' | grep -Fxq -- "$group_name"; then
        printf '%s is already a GUI admin.\n' "$admin_login"
    else
        usermod -a -G "$group_name" "$admin_login"
        printf 'Added %s to %s.\n' "$admin_login" "$group_name"
    fi
done

canonical_config_dir=$(dirname "$(readlink -f "$config_dir/global.conf")")
render() {
    local template_file="$1"
    local output_file="$2"
    local rendered_file

    rendered_file=$(mktemp)
    sed \
        -e "s|__INSTALL_DIR__|$install_dir|g" \
        -e "s|__CONFIG_DIR__|$config_dir|g" \
        -e "s|__STATE_DIR__|$state_dir|g" \
        -e "s|__CANONICAL_CONFIG_DIR__|$canonical_config_dir|g" \
        -e "s|__GUI_GROUP__|$group_name|g" \
        "$template_file" > "$rendered_file"
    if grep -Eq '__[A-Z0-9_]+__' "$rendered_file"; then
        rm -f "$rendered_file"
        die "Unresolved placeholder in $(basename "$output_file")"
    fi
    install -m 644 -o 0 -g 0 "$rendered_file" "$output_file"
    rm -f "$rendered_file"
}

render "$template_dir/backup-suite-control.socket.template" "$unit_dir/backup-suite-control.socket"
render "$template_dir/backup-suite-control@.service.template" "$unit_dir/backup-suite-control@.service"
systemctl daemon-reload
if [ "$start_socket" -eq 1 ]; then
    systemctl enable backup-suite-control.socket >/dev/null
    # The socket unit's ExecStartPost grants each member an ACL entry.
    systemctl restart backup-suite-control.socket
    printf 'backup-suite-control.socket is %s on /run/backup-suite/control.sock\n' "$(systemctl is-active backup-suite-control.socket)"
fi
print_members
