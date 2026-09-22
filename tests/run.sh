#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PASS_COUNT=0
FAIL_COUNT=0

fail_test() {
    echo "ASSERTION FAILED: $*" >&2
    return 1
}

assert_file() {
    [ -f "$1" ] || fail_test "expected file: $1"
}

assert_symlink_target() {
    local path="$1"
    local expected="$2"
    [ -L "$path" ] || fail_test "expected symlink: $path"
    [ "$(readlink "$path")" = "$expected" ] || fail_test "unexpected target for $path"
}

assert_contains() {
    local file="$1"
    local expected="$2"
    grep -Fq -- "$expected" "$file" || fail_test "expected '$expected' in $file"
}

assert_not_contains() {
    local file="$1"
    local unexpected="$2"
    if grep -Fq -- "$unexpected" "$file"; then
        fail_test "did not expect '$unexpected' in $file"
    fi
}

write_test_config() {
    local test_root="$1"
    local rclone_bin="$2"
    local remote_root="$3"

    mkdir -p "$test_root/config/mysql-profiles" "$test_root/state" "$test_root/home"
    : > "$test_root/config/rclone.conf"
    : > "$test_root/config/database-backups.conf"
    cat > "$test_root/config/global.conf" <<EOF
INSTALL_MODE="user"
USER_INSTALL_DIR="$ROOT_DIR"
USER_CONFIG_DIR="$test_root/config"
USER_STATE_DIR="$test_root/state"
USER_DB_LOCAL_OUTPUT_DIR="$test_root/db"
USER_RCLONE_CONFIG_PATH="$test_root/config/rclone.conf"
USER_RCLONE_BIN="$rclone_bin"
USER_FILE_SOURCE_CONFIG_PATH="$test_root/config/file-sources.conf"
USER_DATABASE_BACKUP_CONFIG_PATH="$test_root/config/database-backups.conf"
USER_MYSQL_PROFILE_DIR="$test_root/config/mysql-profiles"
RCLONE_REMOTE_ROOT="$remote_root"
INCLUDE_HOSTNAME_IN_REMOTE="0"
REMOTE_HOSTNAME=""
FILE_DEFAULT_DESTINATION_ROOT="files"
FILE_ARCHIVE_FOLDER_NAME="deleted_files"
FILE_RETENTION_DAYS="21d"
FILE_SYNC_STOP_FILE=".nosync"
FILE_PROJECT_EXCLUDE_FILENAME=".backup-excludes"
FILE_VOLATILE_FILENAME=".backup-volatile"
FILE_PROCESS_CHECK_ENABLED="0"
FILE_RCLONE_TRANSFERS="2"
FILE_RCLONE_CHECKERS="4"
FILE_RCLONE_BUFFER_SIZE="16M"
FILE_RCLONE_TPSLIMIT="10"
FILE_RCLONE_EXTRA_FLAGS=""
FILE_STABILITY_INTERVAL_SECONDS="0"
FILE_CHANGED_DETAIL_LIMIT="2"
EOF
}

run_backup() {
    local test_root="$1"
    shift
    HOME="$test_root/home" \
        BACKUP_SUITE_CONFIG_DIR="$test_root/config" \
        BACKUP_SUITE_LOG_MODE=console \
        "$ROOT_DIR/bin/file-backup.sh" "$@"
}

test_symlink_round_trip() {
    local test_root
    test_root=$(mktemp -d)
    mkdir -p "$test_root/source/dir" "$test_root/remote" "$test_root/restore"
    printf 'payload\n' > "$test_root/source/dir/file.txt"
    ln -s dir/file.txt "$test_root/source/relative"
    ln -s /etc/hosts "$test_root/source/absolute"
    ln -s missing-target "$test_root/source/dangling"
    ln -s dir "$test_root/source/directory"

    rclone copy "$test_root/source" "$test_root/remote" --links
    rclone lsf "$test_root/remote" --recursive --files-only --format p --links | sort > "$test_root/link-records.txt"
    rclone copy "$test_root/remote" "$test_root/restore" --links

    assert_contains "$test_root/link-records.txt" 'relative.rclonelink'
    assert_contains "$test_root/link-records.txt" 'absolute.rclonelink'
    assert_contains "$test_root/link-records.txt" 'dangling.rclonelink'
    assert_contains "$test_root/link-records.txt" 'directory.rclonelink'
    assert_symlink_target "$test_root/restore/relative" 'dir/file.txt'
    assert_symlink_target "$test_root/restore/absolute" '/etc/hosts'
    assert_symlink_target "$test_root/restore/dangling" 'missing-target'
    assert_symlink_target "$test_root/restore/directory" 'dir'
    assert_file "$test_root/restore/dir/file.txt"
    rm -rf "$test_root"
}

test_link_migration_gate_and_restore() {
    local test_root
    local output_file
    local report_file
    local marker_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    mkdir -p "$test_root/source/dir" "$test_root/remote/projects/project/directory"
    printf 'current\n' > "$test_root/source/dir/file.txt"
    printf 'old-followed-content\n' > "$test_root/remote/projects/project/directory/old.txt"
    ln -s dir "$test_root/source/directory"
    ln -s missing-target "$test_root/source/dangling"

    write_test_config "$test_root" rclone 'backup:'
    cat > "$test_root/config/rclone.conf" <<EOF
[backup]
type = alias
remote = $test_root/remote
EOF
    printf '1|project|%s|fixed|projects/project|.nosync|single\n' "$test_root/source" > "$test_root/config/file-sources.conf"

    run_backup "$test_root" --link-migration-report > "$output_file" 2>&1
    report_file=$(find "$test_root/state/migration-reports" -type f -name '*.txt' -print -quit)
    assert_file "$report_file"
    assert_file "$test_root/remote/projects/project/directory/old.txt"
    assert_contains "$report_file" 'destination_only_candidates=1'
    assert_contains "$report_file" 'dry_run_status=success'

    run_backup "$test_root" --confirm-link-migration >> "$output_file" 2>&1
    marker_file=$(find "$test_root/state/link-migrations" -type f -name '*.confirmed' -print -quit)
    assert_file "$marker_file"
    assert_symlink_target "$test_root/remote/projects/project/directory" 'dir'
    find "$test_root/remote/deleted_files" -type f -name old.txt -print -quit | grep -q . || fail_test 'previous followed-link content was not retained'

    mkdir -p "$test_root/restore"
    rclone copy "$test_root/remote/projects/project" "$test_root/restore" --links
    assert_symlink_target "$test_root/restore/directory" 'dir'
    assert_symlink_target "$test_root/restore/dangling" 'missing-target'
    rm -rf "$test_root"
}

test_changing_file_policy() {
    local test_root
    local output_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    mkdir -p "$test_root/source" "$test_root/fake"
    printf 'changing\n' > "$test_root/source/volatile.log"
    printf 'volatile.log\n' > "$test_root/source/.backup-volatile"
    write_test_config "$test_root" "$ROOT_DIR/tests/fixtures/fake-rclone.sh" 'fake:'
    printf '1|changing|%s|fixed|changing|.nosync|single\n' "$test_root/source" > "$test_root/config/file-sources.conf"

    FAKE_RCLONE_SCENARIO=changing FAKE_RCLONE_STATE="$test_root/fake" run_backup "$test_root" > "$output_file" 2>&1

    assert_contains "$output_file" 'outcome=completed-with-skips'
    assert_contains "$output_file" 'skipped_changed=1'
    assert_contains "$output_file" 'Skipped changed path: volatile.log'
    assert_contains "$test_root/state/logs/backup-file.log" 'outcome=completed-with-skips'
    assert_contains "$test_root/fake/commands.log" '--links'
    assert_contains "$test_root/fake/commands.log" '--transfers 2'
    assert_contains "$test_root/fake/commands.log" '--checkers 4'
    assert_contains "$test_root/fake/commands.log" '--buffer-size 16M'
    assert_not_contains "$test_root/fake/commands.log" ' -L '
    rm -rf "$test_root"
}

test_durable_failure_history() {
    local test_root
    local output_file
    local failure_record
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    mkdir -p "$test_root/bin" "$test_root/state/logs"
    write_test_config "$test_root" rclone 'fake:'
    cat >> "$test_root/config/global.conf" <<'EOF'
NOTIFY_FAILURES_ENABLED="1"
NOTIFY_NTFY_TOPIC_URL="https://ntfy.invalid/test-topic"
NOTIFY_NTFY_TITLE_PREFIX="Backup Suite Test"
NOTIFY_NTFY_PRIORITY="high"
NOTIFY_JOURNAL_LINES="5"
NOTIFY_DURABLE_LOG_LINES="20"
NOTIFY_FAILURE_LOG_KEEP_FILES="3"
EOF
    printf 'historic backup failure detail\n' > "$test_root/state/logs/backup-file.log"
    ln -s "$ROOT_DIR/tests/fixtures/fake-curl.sh" "$test_root/bin/curl"

    HOME="$test_root/home" \
        PATH="$test_root/bin:$PATH" \
        FAKE_CURL_LOG="$test_root/curl.log" \
        BACKUP_SUITE_CONFIG_DIR="$test_root/config" \
        "$ROOT_DIR/bin/notify-failure.sh" file-backup.service > "$output_file" 2>&1

    failure_record=$(find "$test_root/state/failures" -type f -name '*file-backup.service.log' -print -quit)
    assert_file "$failure_record"
    assert_contains "$failure_record" 'Failed unit: file-backup.service'
    assert_contains "$failure_record" 'historic backup failure detail'
    assert_contains "$output_file" 'Failure record retained at:'
    assert_contains "$test_root/curl.log" 'curl invoked'
    rm -rf "$test_root"
}

test_project_isolation_and_no_delete_on_error() {
    local test_root
    local output_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    mkdir -p "$test_root/projects/bad" "$test_root/projects/good" "$test_root/fake"
    printf 'bad\n' > "$test_root/projects/bad/file.txt"
    printf 'good\n' > "$test_root/projects/good/file.txt"
    write_test_config "$test_root" "$ROOT_DIR/tests/fixtures/fake-rclone.sh" 'fake:'
    printf '1|projects|%s|fixed|projects|.nosync|children\n' "$test_root/projects" > "$test_root/config/file-sources.conf"

    if FAKE_RCLONE_SCENARIO=isolation FAKE_RCLONE_STATE="$test_root/fake" run_backup "$test_root" > "$output_file" 2>&1; then
        fail_test 'isolated failing project should make the run fail'
    fi

    assert_contains "$test_root/fake/commands.log" "$test_root/projects/bad"
    assert_contains "$test_root/fake/commands.log" "$test_root/projects/good"
    assert_contains "$test_root/fake/commands.log" '--backup-dir'
    assert_contains "$output_file" 'Skipping archive retention cleanup because one or more isolated projects failed.'
    if grep -Eq '^(delete|move) ' "$test_root/fake/commands.log"; then
        fail_test 'destructive remote command was issued after a partial project failure'
    fi
    rm -rf "$test_root"
}

test_overlap_prevention() {
    local test_root
    local first_output
    local second_output
    local first_pid
    local wait_count=0
    test_root=$(mktemp -d)
    first_output="$test_root/first.log"
    second_output="$test_root/second.log"
    mkdir -p "$test_root/source" "$test_root/fake"
    printf 'stable\n' > "$test_root/source/file.txt"
    write_test_config "$test_root" "$ROOT_DIR/tests/fixtures/fake-rclone.sh" 'fake:'
    printf '1|overlap|%s|fixed|overlap|.nosync|single\n' "$test_root/source" > "$test_root/config/file-sources.conf"

    FAKE_RCLONE_SCENARIO=overlap FAKE_RCLONE_STATE="$test_root/fake" run_backup "$test_root" > "$first_output" 2>&1 &
    first_pid=$!
    while ! grep -q '^sync ' "$test_root/fake/commands.log" 2>/dev/null; do
        sleep 0.1
        wait_count=$((wait_count + 1))
        [ "$wait_count" -lt 50 ] || fail_test 'first backup did not reach sync'
    done
    FAKE_RCLONE_SCENARIO=overlap FAKE_RCLONE_STATE="$test_root/fake" run_backup "$test_root" > "$second_output" 2>&1
    wait "$first_pid"

    assert_contains "$second_output" 'already in progress'
    [ "$(grep -c '^sync ' "$test_root/fake/commands.log")" -eq 1 ] || fail_test 'more than one overlapping sync ran'
    rm -rf "$test_root"
}

test_resource_unit_and_link_flags() {
    local test_root
    local rendered_unit
    test_root=$(mktemp -d)
    rendered_unit="$test_root/file-backup.service"
    sed \
        -e 's|__INSTALL_DIR__|/opt/backup-suite|g' \
        -e 's|__CONFIG_DIR__|/etc/backup-suite|g' \
        -e 's|__USER_GROUP_DIRECTIVES__||g' \
        -e 's|__LOCK_FILE__|/run/backup-suite/file-backup.lock|g' \
        -e 's|__FILE_BACKUP_RUNTIME_MAX_SEC__|6h|g' \
        "$ROOT_DIR/systemd/file-backup.service.template" > "$rendered_unit"

    for directive in 'CPUQuota=50%' 'CPUWeight=10' 'IOWeight=10' 'Nice=15' 'IOSchedulingClass=idle' 'MemoryHigh=512M' 'MemoryMax=1G' 'TasksMax=64' 'RuntimeMaxSec=6h' 'flock -n -E 75'; do
        assert_contains "$rendered_unit" "$directive"
    done
    systemd-analyze verify "$rendered_unit" >/dev/null
    if grep -Eq 'CPUQuota|MemoryMax|IOWeight' "$ROOT_DIR/systemd/database-backup.service.template" "$ROOT_DIR/systemd/database-size-check.service.template"; then
        fail_test 'file-backup resource controls leaked into unrelated service templates'
    fi
    if grep -Eq -- '(^|[[:space:]])(-L|--copy-links)([[:space:]]|$)' "$ROOT_DIR/bin/file-backup.sh"; then
        fail_test 'file backup still contains copy-link behavior'
    fi
    [ "$(grep -c -- '--links' "$ROOT_DIR/bin/file-backup.sh")" -ge 3 ] || fail_test 'expected --links on listing, report, and sync paths'
    rm -rf "$test_root"
}

test_crypto_wallet_policy() {
    local excludes="$ROOT_DIR/examples/project-policies/crypto-wallets-api.backup-excludes"
    local volatile="$ROOT_DIR/examples/project-policies/crypto-wallets-api.backup-volatile"
    assert_not_contains "$excludes" '.runtime/**'
    assert_contains "$excludes" '.runtime/tron/rootfs/**'
    assert_contains "$excludes" '.runtime/tron/node/output-directory/**'
    assert_contains "$excludes" '.runtime/npm-cache/**'
    assert_not_contains "$excludes" '.runtime/credentials'
    assert_not_contains "$excludes" '.runtime/key-backups'
    assert_not_contains "$excludes" '.runtime/recovery'
    assert_not_contains "$excludes" '.runtime/tron/keys'
    assert_contains "$volatile" '.runtime/node/regtest/wallets/**/*.dat'
}

run_test() {
    local name="$1"
    shift
    echo "==> $name"
    if "$0" --single "$@"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "PASS: $name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "FAIL: $name" >&2
    fi
}

if [ "${1:-}" = "--single" ]; then
    shift
    "$@"
    exit $?
fi

chmod 755 "$ROOT_DIR/tests/fixtures/fake-rclone.sh" "$ROOT_DIR/tests/fixtures/fake-curl.sh"

run_test 'symlink round-trip restore' test_symlink_round_trip
run_test 'safe link migration gate and restore' test_link_migration_gate_and_restore
run_test 'changing-file retry and bounded skip' test_changing_file_policy
run_test 'project isolation and no delete on error' test_project_isolation_and_no_delete_on_error
run_test 'overlap prevention' test_overlap_prevention
run_test 'durable failure history and ntfy correlation' test_durable_failure_history
run_test 'resource unit generation and link flags' test_resource_unit_and_link_flags
run_test 'crypto wallet durable/volatile policy' test_crypto_wallet_policy

echo "Tests: passed=$PASS_COUNT failed=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
