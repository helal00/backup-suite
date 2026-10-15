#!/bin/bash

set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PASS_COUNT=0
FAIL_COUNT=0

# Test runs are heavy work: they yield CPU and disk to backups and services.
if [ -z "${BACKUP_SUITE_TESTS_NO_NICE:-}" ]; then
    renice -n 10 -p $$ > /dev/null 2>&1 || true
    ionice -c 3 -p $$ > /dev/null 2>&1 || true
fi

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
FILE_GLOBAL_EXCLUDE_PATTERNS=".ai-metadata/observation-cache/**|.ai-metadata/.ready-observation-cache.*|.ai-metadata/ready-observation-cache.json|.ai-metadata/native-ready-cache/**|.ai-metadata/prompt-runs/**|.ai-metadata/terminal-choice-state.json"
FILE_VOLATILE_FILENAME=".backup-volatile"
FILE_GLOBAL_VOLATILE_PATTERNS=".ai-metadata/chat-store/**|.ai-metadata/prompts/gui-autosave-*.prompt.txt|.ai-metadata/claude/current.json|.ai-metadata/claude/events/**"
FILE_PROCESS_CHECK_ENABLED="0"
FILE_RCLONE_TRANSFERS="2"
FILE_RCLONE_CHECKERS="4"
FILE_RCLONE_BUFFER_SIZE="16M"
FILE_RCLONE_TPSLIMIT="10"
FILE_RCLONE_EXTRA_FLAGS=""
FILE_STABILITY_INTERVAL_SECONDS="0"
FILE_CHANGED_DETAIL_LIMIT="2"
# Fixture files are created moments before each run; tests that exercise the
# recently-modified deferral window enable it explicitly.
FILE_ACTIVE_WINDOW_SECONDS="0"
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
    local resume_output
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

    resume_output="$test_root/resume.log"
    printf 'not part of migration retry\n' > "$test_root/source/after-confirmation.txt"
    run_backup "$test_root" --confirm-link-migration > "$resume_output" 2>&1
    assert_contains "$resume_output" 'Migration already confirmed'
    [ ! -e "$test_root/remote/projects/project/after-confirmation.txt" ] || fail_test 'confirmed project was redundantly synced during migration resume'

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
    write_test_config "$test_root" "$ROOT_DIR/tests/fixtures/fake-rclone.sh" 'fake:'
    printf '\nFILE_GLOBAL_VOLATILE_PATTERNS="volatile.log"\n' >> "$test_root/config/global.conf"
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

test_project_records_and_changes() {
    # Real rclone against a local alias remote: per-project rows in
    # projects/history.tsv, and each project's changed files from the last run.
    local test_root
    local output_file
    local history
    local changes_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    mkdir -p "$test_root/workspace/alpha/sub" "$test_root/workspace/beta" "$test_root/workspace/paused" "$test_root/remote" "$test_root/single"
    printf 'one\n' > "$test_root/workspace/alpha/keep.txt"
    printf 'two\n' > "$test_root/workspace/alpha/sub/change.txt"
    printf 'three\n' > "$test_root/workspace/alpha/remove.txt"
    printf 'beta\n' > "$test_root/workspace/beta/b.txt"
    printf 'x\n' > "$test_root/workspace/paused/p.txt"
    touch "$test_root/workspace/paused/.nosync"
    printf 'solo\n' > "$test_root/single/s.txt"
    write_test_config "$test_root" rclone 'backup:'
    printf '[backup]\ntype = alias\nremote = %s\n' "$test_root/remote" > "$test_root/config/rclone.conf"
    {
        printf '1|workspace|%s|fixed|projects/workspace|.nosync|children\n' "$test_root/workspace"
        printf '1|single-entry|%s|fixed|tools/single|.nosync|single\n' "$test_root/single"
        printf '1|gone|%s|fixed|tools/gone|.nosync|single\n' "$test_root/missing"
    } > "$test_root/config/file-sources.conf"

    run_backup "$test_root" > "$output_file" 2>&1 || true
    history="$test_root/state/projects/history.tsv"
    assert_file "$history"
    awk -F '\t' '$5 == "workspace/alpha" && $4 == "workspace" && $9 == "synced" && $12 == 3 { found = 1 } END { exit !found }' "$history" \
        || fail_test 'alpha first run: expected synced with 3 new files'
    awk -F '\t' '$5 == "workspace/paused" && $9 == "skipped-stop-file" { found = 1 } END { exit !found }' "$history" \
        || fail_test 'a child with .nosync is recorded as skipped-stop-file'
    awk -F '\t' '$5 == "single-entry" && $4 == "single-entry" && $9 == "synced" { found = 1 } END { exit !found }' "$history" \
        || fail_test 'a single entry is recorded'
    awk -F '\t' '$4 == "gone" && $9 == "missing-source" { found = 1 } END { exit !found }' "$history" \
        || fail_test 'a missing source is recorded'
    # Per-file INFO lines go to the change list, not the log.
    assert_not_contains "$output_file" 'Copied (new)'

    sleep 1
    printf 'two, changed\n' > "$test_root/workspace/alpha/sub/change.txt"
    rm "$test_root/workspace/alpha/remove.txt"
    printf 'brand new\n' > "$test_root/workspace/alpha/added.txt"
    run_backup "$test_root" > "$output_file" 2>&1 || true
    changes_file=$(awk -F '\t' '$5 == "workspace/alpha" { key = $8 } END { print key }' "$history")
    changes_file="$test_root/state/projects/changes/$changes_file.tsv"
    assert_file "$changes_file"
    assert_contains "$changes_file" 'new=1 updated=1 removed=1'
    grep -qxF "$(printf 'updated\tsub/change.txt')" "$changes_file" || fail_test 'updated file not listed'
    grep -qxF "$(printf 'new\tadded.txt')" "$changes_file" || fail_test 'new file not listed'
    grep -qxF "$(printf 'removed\tremove.txt')" "$changes_file" || fail_test 'removed file not listed'
    [ "$(awk -F '\t' '$5 == "workspace/beta"' "$history" | wc -l)" -eq 2 ] || fail_test 'beta should have one row per run'
    awk -F '\t' '$5 == "workspace/beta" { last = $12 + $13 + $14 } END { exit last != 0 }' "$history" \
        || fail_test 'beta did not change in the second run'
    grep -q '^current_entry=' "$test_root/state/run/progress.env" || fail_test 'progress.env has no current_entry'

    # The control script's entry verbs read these records.
    local reply
    mkdir -p "$test_root/bin"
    ln -s "$ROOT_DIR/tests/fixtures/fake-systemctl.sh" "$test_root/bin/systemctl"
    reply=$(control_call "$test_root" '{"verb":"jobs"}')
    [ "$(json_field "$reply" 'len(d["data"]["jobs"])')" = "3" ] || fail_test "entries: expected 3, got: $reply"
    [ "$(json_field "$reply" '[e for e in d["data"]["jobs"] if e["name"] == "workspace"][0]["last_run"]["synced"]')" = "2" ] || fail_test "workspace last run should have 2 synced projects: $reply"
    [ "$(json_field "$reply" '[e for e in d["data"]["jobs"] if e["name"] == "workspace"][0]["children"]')" = "3" ] || fail_test 'workspace has 3 children'
    [ "$(json_field "$reply" '[e for e in d["data"]["jobs"] if e["name"] == "workspace"][0]["destination"]')" = "backup:/projects/workspace" ] || fail_test "destination: $reply"
    [ "$(json_field "$reply" '[e for e in d["data"]["jobs"] if e["name"] == "gone"][0]["problem"]')" = "The source directory does not exist." ] || fail_test 'missing source problem'
    reply=$(control_call "$test_root" '{"verb":"job","args":{"name":"workspace"}}')
    [ "$(json_field "$reply" 'sorted(p["name"] for p in d["data"]["projects"])')" = "['alpha', 'beta', 'paused']" ] || fail_test "entry projects: $reply"
    [ "$(json_field "$reply" '[p for p in d["data"]["projects"] if p["name"] == "paused"][0]["stop_file_present"]')" = "True" ] || fail_test 'paused has .nosync'
    [ "$(json_field "$reply" '[p for p in d["data"]["projects"] if p["name"] == "alpha"][0]["changes"]["updated"]')" = "1" ] || fail_test 'alpha changes header'
    [ "$(json_field "$reply" 'len(d["data"]["runs"])')" = "2" ] || fail_test 'two runs of the entry'
    reply=$(control_call "$test_root" '{"verb":"job.changes","args":{"name":"workspace","project":"workspace/alpha"}}')
    [ "$(json_field "$reply" 'sorted(f["kind"] + ":" + f["path"] for f in d["data"]["files"])')" = "['new:added.txt', 'removed:remove.txt', 'updated:sub/change.txt']" ] || fail_test "entry.changes: $reply"
    reply=$(control_call "$test_root" '{"verb":"job.log","args":{"name":"single-entry"}}')
    [ "$(json_field "$reply" 'any("single-entry" in l for l in d["data"]["lines"]) and not any("workspace/alpha" in l for l in d["data"]["lines"])')" = "True" ] || fail_test "entry.log: $reply"
    reply=$(control_call "$test_root" '{"verb":"job.measure","args":{"name":"workspace","what":"source"}}')
    [ "$(json_field "$reply" 'd["data"]["result"]["files"]')" = "6" ] || fail_test "entry.measure source: $reply"
    reply=$(control_call "$test_root" '{"verb":"job.measure","args":{"name":"workspace","what":"destination"}}')
    [ "$(json_field "$reply" 'd["data"]["result"]["files"]')" = "4" ] || fail_test "entry.measure destination: $reply"
    reply=$(control_call "$test_root" '{"verb":"job","args":{"name":"../etc"}}')
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "not_found" ] || fail_test "unknown entry: $reply"
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

test_global_agentw_cache_policy() {
    local test_root
    test_root=$(mktemp -d)
    mkdir -p \
        "$test_root/source/.ai-metadata/observation-cache" \
        "$test_root/source/.ai-metadata/native-ready-cache" \
        "$test_root/source/.ai-metadata/prompt-runs" \
        "$test_root/source/.ai-metadata/chat-store" \
        "$test_root/remote"
    printf 'durable continuity\n' > "$test_root/source/.ai-metadata/project-context-summary.md"
    printf 'durable instructions\n' > "$test_root/source/.ai-metadata/current-instructions.md"
    printf 'cache\n' > "$test_root/source/.ai-metadata/observation-cache/ready.json"
    printf 'cache\n' > "$test_root/source/.ai-metadata/native-ready-cache/codex.json"
    printf 'cache\n' > "$test_root/source/.ai-metadata/prompt-runs/lifecycle.json"
    printf 'cache\n' > "$test_root/source/.ai-metadata/ready-observation-cache.json"
    printf 'transient choice\n' > "$test_root/source/.ai-metadata/terminal-choice-state.json"
    printf 'stable durable chat state\n' > "$test_root/source/.ai-metadata/chat-store/catalog.json"

    write_test_config "$test_root" rclone 'backup:'
    cat > "$test_root/config/rclone.conf" <<EOF
[backup]
type = alias
remote = $test_root/remote
EOF
    printf '1|agentw-cache-policy|%s|fixed|agentw-cache-policy|.nosync|single\n' "$test_root/source" > "$test_root/config/file-sources.conf"

    run_backup "$test_root" >/dev/null 2>&1

    assert_file "$test_root/remote/agentw-cache-policy/.ai-metadata/project-context-summary.md"
    assert_file "$test_root/remote/agentw-cache-policy/.ai-metadata/current-instructions.md"
    assert_file "$test_root/remote/agentw-cache-policy/.ai-metadata/chat-store/catalog.json"
    [ ! -e "$test_root/remote/agentw-cache-policy/.ai-metadata/observation-cache/ready.json" ] || fail_test 'observation cache was backed up'
    [ ! -e "$test_root/remote/agentw-cache-policy/.ai-metadata/native-ready-cache/codex.json" ] || fail_test 'native-ready cache was backed up'
    [ ! -e "$test_root/remote/agentw-cache-policy/.ai-metadata/prompt-runs/lifecycle.json" ] || fail_test 'prompt run cache was backed up'
    [ ! -e "$test_root/remote/agentw-cache-policy/.ai-metadata/ready-observation-cache.json" ] || fail_test 'ready observation cache was backed up'
    [ ! -e "$test_root/remote/agentw-cache-policy/.ai-metadata/terminal-choice-state.json" ] || fail_test 'terminal choice state was backed up'
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

test_explicit_project_filter() {
    local test_root
    local output_file
    local filter_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    filter_file="$test_root/project-filter"
    mkdir -p "$test_root/projects/bad" "$test_root/projects/good" "$test_root/fake"
    printf 'bad\n' > "$test_root/projects/bad/file.txt"
    printf 'good\n' > "$test_root/projects/good/file.txt"
    printf 'projects/good\n' > "$filter_file"
    write_test_config "$test_root" "$ROOT_DIR/tests/fixtures/fake-rclone.sh" 'fake:'
    printf '1|projects|%s|fixed|projects|.nosync|children\n' "$test_root/projects" > "$test_root/config/file-sources.conf"

    BACKUP_SUITE_PROJECT_FILTER_FILE="$filter_file" \
        FAKE_RCLONE_SCENARIO=isolation \
        FAKE_RCLONE_STATE="$test_root/fake" \
        run_backup "$test_root" > "$output_file" 2>&1

    assert_contains "$output_file" "outside the explicit migration project filter"
    assert_contains "$test_root/fake/commands.log" "$test_root/projects/good"
    assert_not_contains "$test_root/fake/commands.log" "$test_root/projects/bad"
    rm -rf "$test_root"
}

test_resource_unit_and_link_flags() {
    local test_root
    local rendered_unit
    local rendered_timer
    test_root=$(mktemp -d)
    rendered_unit="$test_root/file-backup.service"
    rendered_timer="$test_root/file-backup.timer"
    sed \
        -e "s|__INSTALL_DIR__|$ROOT_DIR|g" \
        -e 's|__CONFIG_DIR__|/etc/backup-suite|g' \
        -e 's|__USER_GROUP_DIRECTIVES__||g' \
        -e 's|__LOCK_FILE__|/var/lib/backup-suite/locks/file-backup.service.lock|g' \
        -e 's|__FILE_BACKUP_RUNTIME_MAX_SEC__|6h|g' \
        "$ROOT_DIR/systemd/file-backup.service.template" > "$rendered_unit"

    for directive in 'Type=exec' 'file-backup-service.sh' 'CPUAccounting=true' 'MemoryAccounting=true' 'IOAccounting=true' 'CPUQuota=50%' 'CPUWeight=10' 'IOWeight=10' 'Nice=15' 'IOSchedulingClass=idle' 'MemoryHigh=512M' 'MemoryMax=1G' 'TasksMax=64' 'RuntimeMaxSec=6h' 'TimeoutStopSec=2min' 'KillMode=control-group' 'Restart=no'; do
        assert_contains "$rendered_unit" "$directive"
    done
    assert_not_contains "$rendered_unit" 'Type=forking'
    assert_not_contains "$rendered_unit" 'Type=oneshot'
    assert_not_contains "$rendered_unit" 'systemd-fork-run.sh'
    assert_contains "$ROOT_DIR/systemd/file-backup.timer.template" 'Persistent=true'
    assert_contains "$ROOT_DIR/systemd/file-backup.timer.template" 'RandomizedDelaySec=__FILE_BACKUP_RANDOMIZED_DELAY_SEC__'
    assert_contains "$ROOT_DIR/systemd/backup-suite-notify@.service.template" 'Restart=no'
    assert_contains "$ROOT_DIR/bin/file-backup-service.sh" 'exec /usr/bin/flock'
    assert_contains "$rendered_unit" '/var/lib/backup-suite/locks/file-backup.service.lock'
    [ "$(grep -c '^OnFailure=backup-suite-notify@%n.service$' "$rendered_unit")" -eq 1 ] || fail_test 'file backup must have exactly one OnFailure notification target'
    assert_not_contains "$ROOT_DIR/systemd/backup-suite-notify@.service.template" 'file-backup.service'
    sed \
        -e 's|__FILE_BACKUP_ONCALENDAR__|*:0/30|g' \
        -e 's|__FILE_BACKUP_RANDOMIZED_DELAY_SEC__|15m|g' \
        "$ROOT_DIR/systemd/file-backup.timer.template" > "$rendered_timer"
    systemd-analyze verify "$rendered_unit" "$rendered_timer" >/dev/null
    if grep -Eq 'CPUQuota|MemoryMax|IOWeight' "$ROOT_DIR/systemd/database-backup.service.template" "$ROOT_DIR/systemd/database-size-check.service.template"; then
        fail_test 'file-backup resource controls leaked into unrelated service templates'
    fi
    # Every shipped unit caps swap: MemoryMax counts RAM only (lesson of 2026-10-14).
    for template in database-backup.service database-size-check.service backup-suite-notify@.service \
        backup-suite-watchdog@.service backup-suite-control@.service; do
        assert_contains "$ROOT_DIR/systemd/$template.template" 'MemorySwapMax='
    done
    assert_contains "$ROOT_DIR/systemd/file-backup.service.template" 'MemorySwapMax='
    assert_contains "$ROOT_DIR/gui/systemd/backup-suite-gui.service.template" 'MemorySwapMax='
    assert_contains "$ROOT_DIR/gui/systemd/backup-suite-gui-watchdog.service.template" 'MemorySwapMax='
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

test_production_migration_runner_guards() {
    local runner="$ROOT_DIR/production-file-backup-migrate.sh"
    local report_line
    local confirm_line
    local restore_line
    local validation_line
    local enable_line

    assert_contains "$runner" 'systemctl disable --now "$TIMER_UNIT"'
    assert_contains "$runner" 'trap on_exit EXIT'
    assert_contains "$runner" 'APPLY LINK MIGRATION'
    assert_contains "$runner" 'BACKUP_SUITE_RESTORE_MAX_BYTES'
    assert_contains "$runner" 'systemctl enable --now "$TIMER_UNIT"'
    assert_contains "$runner" 'run_file_backup_service "link-migration-report" link-migration-report'
    assert_contains "$runner" 'run_file_backup_service "confirm-link-migration" confirm-link-migration'
    assert_contains "$runner" 'systemd-cgls --unit "$SERVICE_UNIT"'
    assert_contains "$runner" 'validate_failed_sync_isolation'
    assert_contains "$runner" 'assert_service_property CPUAccounting yes'
    assert_contains "$runner" 'assert_service_property KillMode control-group'
    assert_contains "$runner" 'assert_service_property Restart no'
    assert_contains "$runner" 'FILE_GLOBAL_EXCLUDE_PATTERNS'
    assert_contains "$runner" 'FILE_GLOBAL_VOLATILE_PATTERNS'
    assert_contains "$runner" '.ai-metadata/terminal-choice-state.json'
    assert_contains "$runner" '.ai-metadata/chat-store/**'
    assert_contains "$runner" '.ai-metadata/prompts/gui-autosave-*.prompt.txt'
    assert_contains "$runner" '.ai-metadata/claude/current.json'
    assert_contains "$runner" '.ai-metadata/claude/events/**'
    assert_contains "$runner" '--only-project'
    assert_contains "$runner" 'PROJECT_FILTER_FILE="$STATE_DIR/validation/${RUN_ID}-project-filter"'
    assert_not_contains "$runner" 'PROJECT_FILTER_FILE="/run/backup-suite/file-backup-projects"'
    assert_contains "$runner" '[[ "$service_exec_start" == *"$INSTALL_DIR/bin/file-backup-service.sh"* ]]'
    assert_not_contains "$runner" '[ "$(systemctl show "$SERVICE_UNIT" -p ExecStart --value)" = *"$INSTALL_DIR/bin/file-backup-service.sh"* ]'
    assert_contains "$runner" 'Expected exactly one failed-sync notification record'
    assert_contains "$runner" 'rclone_children_remaining=0'
    assert_contains "$runner" 'service_restarts=0'
    assert_contains "$runner" 'immediate_relaunch=0'
    assert_not_contains "$runner" 'systemd-run'

    report_line=$(grep -n 'run_file_backup_service "link-migration-report" link-migration-report' "$runner" | cut -d: -f1)
    confirm_line=$(grep -n 'run_file_backup_service "confirm-link-migration" confirm-link-migration' "$runner" | cut -d: -f1)
    restore_line=$(grep -n 'Remote restore verification passed' "$runner" | cut -d: -f1)
    validation_line=$(grep -n '^validate_failed_sync_isolation$' "$runner" | tail -1 | cut -d: -f1)
    enable_line=$(grep -n 'systemctl enable --now "$TIMER_UNIT"' "$runner" | tail -1 | cut -d: -f1)

    [ "$report_line" -lt "$confirm_line" ] || fail_test 'migration confirmation occurs before report'
    [ "$confirm_line" -lt "$restore_line" ] || fail_test 'restore verification occurs before confirmed migration'
    [ "$restore_line" -lt "$validation_line" ] || fail_test 'failed-sync containment validation occurs before restore verification'
    [ "$validation_line" -lt "$enable_line" ] || fail_test 'timer enablement occurs before failed-sync containment validation'
    "$runner" --help >/dev/null
    assert_contains "$runner" 'PRODUCTION_CHANGES_STARTED=1'
}

test_help_never_touches_systemd() {
    local test_root
    test_root=$(mktemp -d)
    install_fake_tools "$test_root"
    : > "$test_root/systemctl.log"
    PATH="$test_root/bin:$PATH" FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" "$ROOT_DIR/production-file-backup-migrate.sh" --help >/dev/null
    PATH="$test_root/bin:$PATH" FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" "$ROOT_DIR/production-file-backup-migrate.sh" --bogus >/dev/null 2>&1 || true
    PATH="$test_root/bin:$PATH" FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" "$ROOT_DIR/production-deploy.sh" --help >/dev/null
    PATH="$test_root/bin:$PATH" FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" "$ROOT_DIR/production-deploy.sh" --bogus >/dev/null 2>&1 || true
    [ ! -s "$test_root/systemctl.log" ] || fail_test "help or option errors called systemctl: $(cat "$test_root/systemctl.log")"
    rm -rf "$test_root"
}

write_notify_config() {
    local test_root="$1"
    cat >> "$test_root/config/global.conf" <<'EOF'
NOTIFY_FAILURES_ENABLED="1"
NOTIFY_NTFY_TOPIC_URL="https://ntfy.invalid/test-topic"
NOTIFY_NTFY_TITLE_PREFIX="Backup Suite Test"
NOTIFY_NTFY_PRIORITY="high"
NOTIFY_JOURNAL_LINES="5"
NOTIFY_DURABLE_LOG_LINES="20"
NOTIFY_FAILURE_LOG_KEEP_FILES="3"
EOF
}

install_fake_tools() {
    local test_root="$1"
    mkdir -p "$test_root/bin"
    ln -sf "$ROOT_DIR/tests/fixtures/fake-curl.sh" "$test_root/bin/curl"
    ln -sf "$ROOT_DIR/tests/fixtures/fake-systemctl.sh" "$test_root/bin/systemctl"
}

curl_message_header() {
    # Prints the Message header (or --data-binary body) of the first request.
    awk '
        /^arg: Message: / { sub(/^arg: Message: /, ""); print; exit }
        previous == "arg: --data-binary" { sub(/^arg: /, ""); print; exit }
        { previous = $0 }
    ' "$1"
}

test_profiles_and_dropin() {
    local test_root
    local dropin
    local output_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    write_test_config "$test_root" rclone 'fake:'
    install_fake_tools "$test_root"
    mkdir -p "$test_root/cgroup/system.slice/file-backup.service"
    printf '50000 100000\n' > "$test_root/cgroup/system.slice/file-backup.service/cpu.max"

    run_profile() {
        env -u XDG_CONFIG_HOME -u XDG_STATE_HOME \
            HOME="$test_root/home" \
            PATH="$test_root/bin:$PATH" \
            FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" \
            BACKUP_SUITE_CONFIG_DIR="$test_root/config" \
            BACKUP_SUITE_CGROUP_ROOT="$test_root/cgroup" \
            "$ROOT_DIR/bin/backup-profile.sh" "$@"
    }

    run_profile print-dropin slow > "$test_root/slow.conf"
    for directive in 'CPUQuota=25%' 'MemoryHigh=256M' 'MemoryMax=512M' 'MemorySwapMax=128M' 'TasksMax=32' 'IOSchedulingClass=idle' 'Nice=19'; do
        assert_contains "$test_root/slow.conf" "$directive"
    done
    run_profile print-dropin fast > "$test_root/fast.conf"
    assert_contains "$test_root/fast.conf" 'CPUQuota=100%'
    assert_contains "$test_root/fast.conf" 'MemoryMax=2G'
    [ "$(run_profile current)" = "fixed custom" ] || fail_test 'configs without FILE_BACKUP_PROFILE must keep the custom (pre-profile) behavior'

    run_profile show > "$output_file"
    assert_contains "$output_file" 'slow'
    assert_contains "$output_file" 'moderate'
    assert_contains "$output_file" 'fast'
    assert_contains "$output_file" 'Memory   : throttled above 512M, hard limit 1G'

    run_profile set fast > "$output_file"
    assert_contains "$test_root/config/global.conf" 'FILE_BACKUP_PROFILE="fast"'
    dropin="$test_root/home/.config/systemd/user/file-backup.service.d/50-backup-profile.conf"
    assert_file "$dropin"
    assert_contains "$dropin" 'CPUQuota=100%'
    assert_contains "$test_root/systemctl.log" 'daemon-reload'

    FAKE_SYSTEMCTL_IS_ACTIVE_STATUS=0 FAKE_SYSTEMCTL_CONTROL_GROUP=/system.slice/file-backup.service run_profile set slow > "$output_file"
    assert_contains "$output_file" 'Applied CPU, memory, swap, and task limits to the running backup.'
    [ "$(cat "$test_root/cgroup/system.slice/file-backup.service/cpu.max")" = "25000 100000" ] || fail_test 'live CPU quota was not applied'
    [ "$(cat "$test_root/cgroup/system.slice/file-backup.service/memory.max")" = "536870912" ] || fail_test 'live memory limit was not applied'

    if run_profile set turbo > "$output_file" 2>&1; then
        fail_test 'an unknown profile must be rejected'
    fi
    assert_contains "$test_root/config/global.conf" 'FILE_BACKUP_PROFILE="slow"'
    rm -rf "$test_root"
}

test_profile_drives_rclone_flags() {
    local test_root
    test_root=$(mktemp -d)
    mkdir -p "$test_root/projects/good" "$test_root/fake"
    printf 'good\n' > "$test_root/projects/good/file.txt"
    write_test_config "$test_root" "$ROOT_DIR/tests/fixtures/fake-rclone.sh" 'fake:'
    printf '\nFILE_BACKUP_PROFILE="slow"\n' >> "$test_root/config/global.conf"
    printf '1|good|%s|fixed|good|.nosync|single\n' "$test_root/projects/good" > "$test_root/config/file-sources.conf"

    FAKE_RCLONE_SCENARIO=isolation FAKE_RCLONE_STATE="$test_root/fake" run_backup "$test_root" > "$test_root/output.log" 2>&1

    assert_contains "$test_root/fake/commands.log" '--transfers 1'
    assert_contains "$test_root/fake/commands.log" '--checkers 2'
    assert_contains "$test_root/fake/commands.log" '--buffer-size 8M'
    assert_contains "$test_root/fake/commands.log" '--tpslimit 4'
    assert_contains "$test_root/fake/commands.log" '--bwlimit 4M'
    assert_contains "$test_root/output.log" 'profile=slow'
    rm -rf "$test_root"
}

test_active_file_deferral() {
    local test_root
    local output_file
    local state_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    mkdir -p "$test_root/source/sub" "$test_root/remote"
    printf 'stable\n' > "$test_root/source/stable.txt"
    printf 'settled root copy\n' > "$test_root/source/same.log"
    printf 'being written\n' > "$test_root/source/sub/same.log"
    touch -d '-1 hour' "$test_root/source/stable.txt" "$test_root/source/same.log"

    write_test_config "$test_root" rclone 'backup:'
    write_notify_config "$test_root"
    install_fake_tools "$test_root"
    cat > "$test_root/config/rclone.conf" <<EOF
[backup]
type = alias
remote = $test_root/remote
EOF
    cat >> "$test_root/config/global.conf" <<'EOF'
FILE_ACTIVE_WINDOW_SECONDS="120"
FILE_ACTIVE_MAX_DEFERRALS="2"
EOF
    printf '1|active|%s|fixed|active|.nosync|single\n' "$test_root/source" > "$test_root/config/file-sources.conf"

    run_active_backup() {
        PATH="$test_root/bin:$PATH" FAKE_CURL_LOG="$test_root/curl.log" run_backup "$test_root" > "$output_file" 2>&1
    }

    run_active_backup
    assert_file "$test_root/remote/active/stable.txt"
    assert_file "$test_root/remote/active/same.log"
    [ ! -e "$test_root/remote/active/sub/same.log" ] || fail_test 'a file modified within the active window was copied'
    assert_contains "$output_file" 'Deferred active path: sub/same.log'
    assert_contains "$output_file" 'deferred_active=1'
    assert_contains "$output_file" 'outcome=completed-with-skips'
    state_file=$(find "$test_root/state/active-files" -type f -name '*.tsv' -print -quit)
    assert_file "$state_file"
    [ "$(cat "$state_file")" = $'1\tsub/same.log' ] || fail_test 'deferral count was not recorded'
    [ ! -e "$test_root/curl.log" ] || fail_test 'a single deferral must not notify'

    run_active_backup
    [ "$(cat "$state_file")" = $'2\tsub/same.log' ] || fail_test 'consecutive deferral count did not increase'
    assert_contains "$output_file" 'has changed during 2 consecutive runs'
    assert_file "$test_root/curl.log"
    assert_contains "$test_root/curl.log" 'files repeatedly skipped while changing'

    touch -d '-1 hour' "$test_root/source/sub/same.log"
    run_active_backup
    assert_file "$test_root/remote/active/sub/same.log"
    assert_contains "$output_file" 'outcome=completed-successfully'
    [ ! -e "$state_file" ] || fail_test 'deferral state was not cleared after the file settled'
    rm -rf "$test_root"
}

test_failure_notification_description() {
    local test_root
    local output_file
    local message
    local failure_record
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    mkdir -p "$test_root/state/logs"
    write_test_config "$test_root" rclone 'fake:'
    write_notify_config "$test_root"
    install_fake_tools "$test_root"
    {
        echo 'File backup started at 2026-10-13 10:00:00 UTC'
        echo 'Old run line that mentions no space left on device'
        echo 'File backup started at 2026-10-14 10:00:00 UTC'
        for index in $(seq 1 400); do
            echo "2026/10/14 10:00:00 ERROR : project/file-$index.json: Failed to copy: googleapi: Error 403: Rate Limit Exceeded, rateLimitExceeded"
        done
        echo 'Failed file sources: workspace-projects/example'
        echo 'Run summary: outcome=completed-with-errors profile=moderate synced=3 skipped=0 skipped_changed=0 deferred_active=0 failed=1'
    } > "$test_root/state/logs/backup-file.log"

    HOME="$test_root/home" PATH="$test_root/bin:$PATH" FAKE_CURL_LOG="$test_root/curl.log" FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" \
        BACKUP_SUITE_CONFIG_DIR="$test_root/config" \
        "$ROOT_DIR/bin/notify-failure.sh" file-backup.service > "$output_file" 2>&1

    assert_contains "$test_root/curl.log" 'arg: PUT'
    assert_contains "$test_root/curl.log" 'arg: Filename: '
    assert_contains "$test_root/curl.log" 'arg: Title: Backup Suite Test failure on'
    message=$(curl_message_header "$test_root/curl.log")
    [ -n "$message" ] || fail_test 'no readable message was sent with the attachment'
    [ "${#message}" -lt 4096 ] || fail_test "ntfy message is ${#message} bytes; ntfy would turn it into an attachment"
    [[ "$message" == *"rate limit was exceeded"* ]] || fail_test 'the rate-limit cause was not explained'
    [[ "$message" == *"Failed projects: workspace-projects/example"* ]] || fail_test 'failed projects missing from the message'
    [[ "$message" != *"local disk ran out of space"* ]] || fail_test 'an older run was used to explain this failure'
    failure_record=$(find "$test_root/state/failures" -type f -name '*file-backup.service.log' -print -quit)
    assert_file "$failure_record"
    assert_contains "$failure_record" 'Failed unit: file-backup.service'
    assert_contains "$failure_record" 'Recent durable run log:'

    rm -f "$test_root/curl.log"
    HOME="$test_root/home" PATH="$test_root/bin:$PATH" FAKE_CURL_LOG="$test_root/curl.log" FAKE_CURL_FAIL_PUT=1 FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" \
        BACKUP_SUITE_CONFIG_DIR="$test_root/config" \
        "$ROOT_DIR/bin/notify-failure.sh" file-backup.service > "$output_file" 2>&1
    [ "$(grep -c '^curl invoked' "$test_root/curl.log")" -eq 2 ] || fail_test 'a failed attachment upload must fall back to one plain message'
    assert_contains "$test_root/curl.log" 'arg: --data-binary'
    assert_contains "$output_file" 'resending as a plain message'
    rm -rf "$test_root"
}

make_fake_cgroup() {
    local cgroup_dir="$1"
    mkdir -p "$cgroup_dir"
    printf '1000000000\n' > "$cgroup_dir/memory.max"
    printf '500000000\n' > "$cgroup_dir/memory.high"
    printf '100000000\n' > "$cgroup_dir/memory.current"
    printf 'anon 50000000\nfile 50000000\n' > "$cgroup_dir/memory.stat"
    printf 'low 0\nhigh 0\nmax 0\noom 0\noom_kill 0\n' > "$cgroup_dir/memory.events"
    printf '0\n' > "$cgroup_dir/memory.swap.current"
    printf '268435456\n' > "$cgroup_dir/memory.swap.max"
    printf '0\n' > "$cgroup_dir/memory.peak"
    printf '5\n' > "$cgroup_dir/pids.current"
    printf '64\n' > "$cgroup_dir/pids.max"
    printf 'usage_usec 1000\n' > "$cgroup_dir/cpu.stat"
    printf '50000 100000\n' > "$cgroup_dir/cpu.max"
    : > "$cgroup_dir/io.stat"
    printf 'populated 1\nfrozen 0\n' > "$cgroup_dir/cgroup.events"
    printf '0\n' > "$cgroup_dir/cgroup.freeze"
    : > "$cgroup_dir/cgroup.kill"
    : > "$cgroup_dir/memory.reclaim"
}

write_fake_meminfo() {
    # write_fake_meminfo <proc-dir> <MemAvailable kB> [PSI full avg10] [SwapFree kB]
    # Tests never read the host's real memory state: every sample is injected.
    local proc_dir="$1"
    local available_kb="$2"
    local psi_full="${3:-0.00}"
    local swap_free_kb="${4:-2000000}"
    mkdir -p "$proc_dir/pressure"
    printf 'MemTotal:       10000000 kB\nMemAvailable:   %s kB\nSwapTotal:       2000000 kB\nSwapFree:        %s kB\n' "$available_kb" "$swap_free_kb" > "$proc_dir/meminfo.tmp"
    mv "$proc_dir/meminfo.tmp" "$proc_dir/meminfo"
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=%s avg60=0.00 avg300=0.00 total=0\n' "$psi_full" "$psi_full" > "$proc_dir/pressure/memory.tmp"
    mv "$proc_dir/pressure/memory.tmp" "$proc_dir/pressure/memory"
}

make_fake_staller() {
    # make_fake_staller <cgroup-root> <relative path> <full avg10> <current> <high|max> <swap> <high events>
    local dir="$1/$2"
    mkdir -p "$dir"
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=%s avg60=0.00 avg300=0.00 total=0\n' "$3" "$3" > "$dir/memory.pressure"
    printf '%s\n' "$4" > "$dir/memory.current"
    printf '%s\n' "$5" > "$dir/memory.high"
    printf 'max\n' > "$dir/memory.max"
    printf '%s\n' "$6" > "$dir/memory.swap.current"
    printf 'low 0\nhigh %s\nmax 0\noom 0\noom_kill 0\n' "$7" > "$dir/memory.events"
}

write_incident_host() {
    # The server as sampled at 19:39:41 UTC on 2026-10-14: 57% RAM available,
    # swap full, PSI full avg10 67, caused by agentw-service.service stalling
    # at its own 256M MemoryHigh with 1.6 GB in swap (memory.high events 219).
    local test_root="$1"
    write_fake_meminfo "$test_root/proc" 5700000 67.00 0
    make_fake_staller "$test_root/cgroup-root" "user.slice/user-1000.slice/user@1000.service/app.slice/agentw-service.service" \
        81.00 268000000 268435456 1717986918 219
    make_fake_staller "$test_root/cgroup-root" "system.slice/mysql.service" 2.00 900000000 max 0 0
    # The user manager aggregates its services; it is never blamed itself.
    make_fake_staller "$test_root/cgroup-root" "user.slice/user-1000.slice/user@1000.service" 90.00 2000000000 max 1717986918 0
}

watchdog_fixture() {
    local test_root="$1"
    write_test_config "$test_root" rclone 'fake:'
    write_notify_config "$test_root"
    install_fake_tools "$test_root"
    make_fake_cgroup "$test_root/cgroup"
    mkdir -p "$test_root/cgroup-root"
    write_fake_meminfo "$test_root/proc" 6000000
    : > "$test_root/systemctl.log"
}

run_watchdog() {
    local test_root="$1"
    shift
    env "$@" \
        HOME="$test_root/home" \
        PATH="$test_root/bin:$PATH" \
        FAKE_CURL_LOG="$test_root/curl.log" \
        FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" \
        BACKUP_SUITE_CONFIG_DIR="$test_root/config" \
        WATCHDOG_CGROUP_DIR="$test_root/cgroup" \
        WATCHDOG_PROC_DIR="$test_root/proc" \
        BACKUP_SUITE_CGROUP_ROOT="$test_root/cgroup-root" \
        WATCHDOG_INTERVAL_SECONDS=0.1 \
        timeout 30 "$ROOT_DIR/bin/backup-watchdog.sh" file-backup.service > "$test_root/watchdog.log" 2>&1
}

end_fake_unit_after() {
    local delay="$1"
    local cgroup_dir="$2"
    ( sleep "$delay"; printf 'populated 0\nfrozen 0\n' > "$cgroup_dir/cgroup.events" ) &
}

test_watchdog_contains_memory_surge() {
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    printf '850000000\n' > "$test_root/cgroup/memory.current"
    printf 'anon 200000000\nfile 650000000\n' > "$test_root/cgroup/memory.stat"
    ( sleep 1; printf '100000000\n' > "$test_root/cgroup/memory.current" ) &
    end_fake_unit_after 3 "$test_root/cgroup"

    run_watchdog "$test_root"
    wait

    [ -n "$(cat "$test_root/cgroup/memory.reclaim")" ] || fail_test 'cache reclaim was not requested'
    [ "$(cat "$test_root/cgroup/cpu.max")" = "50000 100000" ] || fail_test 'CPU quota was not restored after containment'
    assert_contains "$test_root/watchdog.log" 'WATCHDOG EVENT [contained]'
    assert_contains "$test_root/watchdog.log" 'containment released and CPU quota restored'
    assert_contains "$test_root/curl.log" 'backup memory surge contained'
    assert_contains "$test_root/curl.log" 'Halved its CPU quota from 50% to 25%'
    assert_contains "$test_root/state/watchdog/history.tsv" 'contained,released'
    assert_not_contains "$test_root/systemctl.log" 'stop'
    rm -rf "$test_root"
}

test_watchdog_stops_before_oom() {
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    printf '960000000\n' > "$test_root/cgroup/memory.current"
    printf 'anon 950000000\nfile 10000000\n' > "$test_root/cgroup/memory.stat"

    run_watchdog "$test_root"

    assert_contains "$test_root/systemctl.log" 'stop --no-block file-backup.service'
    [ -z "$(cat "$test_root/cgroup/cgroup.kill")" ] || fail_test 'graceful stop should not need a force kill'
    assert_contains "$test_root/curl.log" 'backup stopped before OOM'
    assert_contains "$test_root/curl.log" 'Stopped the backup gracefully'
    assert_file "$test_root/state/watchdog/file-backup.service.last-action"
    assert_contains "$test_root/state/watchdog/history.tsv" 'memory-limit'
    rm -rf "$test_root"
}

test_watchdog_force_kills_hung_stop() {
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    printf 'anon 950000000\nfile 10000000\n' > "$test_root/cgroup/memory.stat"

    run_watchdog "$test_root" FAKE_SYSTEMCTL_STOP_UNPOPULATES=0 WATCHDOG_KILL_GRACE_SECONDS=1

    [ "$(cat "$test_root/cgroup/cgroup.kill")" = "1" ] || fail_test 'hung backup was not force-killed'
    assert_contains "$test_root/curl.log" 'force-killed (SIGKILL)'
    assert_contains "$test_root/state/watchdog/file-backup.service.last-action" 'forced_kill=1'
    rm -rf "$test_root"
}

test_watchdog_pauses_for_server_pressure() {
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    printf 'anon 200000000\nfile 50000000\n' > "$test_root/cgroup/memory.stat"
    write_fake_meminfo "$test_root/proc" 500000
    ( sleep 1.5; write_fake_meminfo "$test_root/proc" 6000000 ) &
    end_fake_unit_after 3.5 "$test_root/cgroup"

    run_watchdog "$test_root" WATCHDOG_PRESSURE_SUSTAIN_SECONDS=1
    wait

    assert_contains "$test_root/curl.log" 'backup paused: server short of memory'
    assert_contains "$test_root/watchdog.log" 'resuming the backup'
    [ "$(cat "$test_root/cgroup/cgroup.freeze")" = "0" ] || fail_test 'backup was left frozen'
    assert_contains "$test_root/state/watchdog/history.tsv" 'server-pressure,resumed'
    # One pressure episode: the pause notice, then one "recovered" once the run completes.
    assert_contains "$test_root/curl.log" 'backups recovered'
    [ "$(grep -c '^arg: Title: ' "$test_root/curl.log")" -eq 2 ] || fail_test 'expected exactly two pushes for one episode'
    [ ! -e "$test_root/state/watchdog/file-backup.service.episode" ] || fail_test 'a completed run must close the episode'
    assert_not_contains "$test_root/systemctl.log" 'stop'
    rm -rf "$test_root"
}

test_watchdog_short_pressure_spike_never_pauses() {
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    printf 'anon 200000000\nfile 50000000\n' > "$test_root/cgroup/memory.stat"
    write_fake_meminfo "$test_root/proc" 500000
    ( sleep 0.6; write_fake_meminfo "$test_root/proc" 6000000 ) &
    end_fake_unit_after 1.5 "$test_root/cgroup"

    run_watchdog "$test_root" WATCHDOG_PRESSURE_SUSTAIN_SECONDS=5
    wait

    assert_not_contains "$test_root/watchdog.log" 'WATCHDOG EVENT [server-pressure]'
    [ ! -e "$test_root/curl.log" ] || fail_test 'a short spike must not notify'
    rm -rf "$test_root"
}

write_adaptive_moderate_slow() {
    cat >> "$1/config/global.conf" <<'CONF'
FILE_BACKUP_PROFILE="moderate"
FILE_BACKUP_PROFILE_MODE="adaptive"
FILE_BACKUP_PROFILE_FLOOR="slow"
WATCHDOG_ADAPTIVE_COOLDOWN_SECONDS="0"
CONF
}

test_watchdog_incident_stall_without_shortage() {
    # Replays 2026-10-14 19:39: 57% RAM available, swap full, server PSI full
    # 67 from agentw-service.service at its own MemoryHigh. Even with a large
    # backup and an adaptive ladder, nothing is paused or stepped down; the
    # cause is reported by name, once.
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    write_adaptive_moderate_slow "$test_root"
    printf '531628032\n' > "$test_root/cgroup/memory.current"
    printf 'anon 300000000\nfile 231628032\n' > "$test_root/cgroup/memory.stat"
    write_incident_host "$test_root"
    end_fake_unit_after 2 "$test_root/cgroup"

    run_watchdog "$test_root" WATCHDOG_PRESSURE_SUSTAIN_SECONDS=0
    wait

    [ "$(cat "$test_root/cgroup/cgroup.freeze")" = "0" ] || fail_test 'the backup was frozen for a stall it did not cause'
    assert_not_contains "$test_root/watchdog.log" 'WATCHDOG EVENT [server-pressure]'
    assert_not_contains "$test_root/watchdog.log" 'WATCHDOG EVENT [step-down]'
    assert_contains "$test_root/watchdog.log" 'WATCHDOG EVENT [host-pressure] memory stall from agentw-service.service; backup continues'
    [ "$(grep -c '^arg: Title: ' "$test_root/curl.log")" -eq 2 ] || fail_test 'expected the host notice and one recovered message'
    assert_contains "$test_root/curl.log.attachments" 'Server memory: 5566 MiB available of 9765 MiB (57%), swap used 1953 MiB of 1953 MiB, memory stall (PSI full avg10) 67.'
    assert_contains "$test_root/curl.log.attachments" '1. user.slice/user-1000.slice/user@1000.service/app.slice/agentw-service.service: stall 81, memory 255 MiB of its 256 MiB MemoryHigh, swap 1638 MiB, memory.high events 219 (at its own limit: it stalls itself)'
    assert_contains "$test_root/curl.log.attachments" '2. system.slice/mysql.service: stall 2'
    assert_contains "$test_root/curl.log.attachments" 'The stall comes from agentw-service.service, which is at its own memory limit (its stall 81, server 67).'
    assert_not_contains "$test_root/curl.log.attachments" 'user@1000.service: stall'
    assert_contains "$test_root/state/watchdog/file-backup.service.status" 'top_staller=agentw-service.service'
    assert_contains "$test_root/state/watchdog/history.tsv" $'\tcompleted\tsuccess'
    rm -rf "$test_root"
}

test_watchdog_tiny_backup_not_paused() {
    # A real shortage (8% available, stall 67, nobody at its own limit), but
    # the backup holds 2 MiB, as at 19:39: freezing it would free nothing.
    # It keeps running and steps down to the floor instead.
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    write_adaptive_moderate_slow "$test_root"
    printf '2097152\n' > "$test_root/cgroup/memory.current"
    printf 'anon 2097152\nfile 0\n' > "$test_root/cgroup/memory.stat"
    write_fake_meminfo "$test_root/proc" 800000 67.00 0
    end_fake_unit_after 2 "$test_root/cgroup"

    run_watchdog "$test_root" WATCHDOG_PRESSURE_SUSTAIN_SECONDS=0
    wait

    [ "$(cat "$test_root/cgroup/cgroup.freeze")" = "0" ] || fail_test 'a 2 MiB backup was frozen'
    assert_contains "$test_root/watchdog.log" 'WATCHDOG EVENT [host-pressure] server short of memory; backup continues'
    assert_contains "$test_root/watchdog.log" 'WATCHDOG EVENT [step-down] backup stepped down from moderate to slow'
    assert_contains "$test_root/state/watchdog/adaptive-profile.state" 'level=slow'
    # The step-down is routine: recorded for the GUI, not pushed.
    assert_not_contains "$test_root/curl.log" 'stepped down'
    assert_contains "$test_root/state/events.jsonl" 'backup stepped down from moderate to slow'
    assert_not_contains "$test_root/systemctl.log" 'stop'
    rm -rf "$test_root"
}

test_watchdog_thaws_before_stop_and_retries() {
    # A paused backup that outlasts the pause limit is thawed before systemd
    # stops it (a frozen process cannot handle SIGTERM), then retried once the
    # shortage clears. The retried run completes and closes the episode.
    local test_root
    local dead_pid
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    printf 'anon 200000000\nfile 50000000\n' > "$test_root/cgroup/memory.stat"
    write_fake_meminfo "$test_root/proc" 500000 30.00
    true & dead_pid=$!
    wait "$dead_pid"
    mkdir -p "$test_root/state/run"
    printf 'state=running\noutcome=\npid=%s\nproject_index=3\n' "$dead_pid" > "$test_root/state/run/progress.env"
    ( sleep 2.5; write_fake_meminfo "$test_root/proc" 6000000 ) &

    run_watchdog "$test_root" WATCHDOG_PRESSURE_SUSTAIN_SECONDS=0 WATCHDOG_FREEZE_MAX_SECONDS=1 \
        WATCHDOG_RETRY_WAIT_SECONDS=20 WATCHDOG_RETRY_CLEAR_SECONDS=1 \
        FAKE_SYSTEMCTL_FREEZE_AT_STOP_LOG="$test_root/freeze-at-stop.log" \
        FAKE_SYSTEMCTL_START_REPOPULATES=1 FAKE_SYSTEMCTL_NEW_RUN_SECONDS=1.5 \
        FAKE_SYSTEMCTL_INVOCATION_FILE="$test_root/invocation"
    wait

    [ "$(cat "$test_root/freeze-at-stop.log")" = "freeze=0" ] || fail_test 'the backup was still frozen when systemd stopped it'
    [ -z "$(cat "$test_root/cgroup/cgroup.kill")" ] || fail_test 'a thawed backup must stop without SIGKILL'
    assert_contains "$test_root/curl.log" 'backup paused: server short of memory'
    assert_contains "$test_root/curl.log" 'backup deferred: server short of memory'
    assert_not_contains "$test_root/curl.log" 'Priority: urgent'
    assert_contains "$test_root/systemctl.log" 'start --no-block file-backup.service'
    assert_contains "$test_root/state/events.jsonl" 'backup retried after the memory shortage cleared'
    assert_contains "$test_root/curl.log" 'backups recovered'
    [ "$(grep -c '^arg: Title: ' "$test_root/curl.log")" -eq 3 ] || fail_test 'expected pause, deferred and recovered: three pushes'
    assert_contains "$test_root/state/run/progress.env" 'state=interrupted'
    assert_contains "$test_root/state/run/progress.env" 'outcome=pause-timeout'
    assert_contains "$test_root/state/watchdog/history.tsv" 'pause-timeout'
    [ "$(grep -c $'\tfile-backup.service\t' "$test_root/state/watchdog/history.tsv")" -eq 2 ] || fail_test 'the retried run needs its own history row'

    # notify-failure.sh must not push a second message for a stop the watchdog explained.
    HOME="$test_root/home" PATH="$test_root/bin:$PATH" FAKE_CURL_LOG="$test_root/curl-failure.log" FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" \
        BACKUP_SUITE_CONFIG_DIR="$test_root/config" FAKE_SYSTEMCTL_RESULT=signal \
        "$ROOT_DIR/bin/notify-failure.sh" file-backup.service > "$test_root/notify.log" 2>&1
    assert_contains "$test_root/notify.log" 'Failure recorded without a push'
    [ ! -e "$test_root/curl-failure.log" ] || fail_test 'a duplicate failure push was sent'
    rm -rf "$test_root"
}

test_watchdog_never_kills_the_next_run() {
    # 2026-10-14 19:01:20: systemd stopped the backup in 5 ms, then a queued
    # timer start launched the next run in the same cgroup 23 ms later. The old
    # watchdog took it for a hung stop and SIGKILLed it. Now it sees the new
    # invocation, leaves it alone and watches it.
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    printf 'anon 950000000\nfile 10000000\n' > "$test_root/cgroup/memory.stat"
    ( sleep 1.2; printf 'anon 50000000\nfile 10000000\n' > "$test_root/cgroup/memory.stat" ) &

    run_watchdog "$test_root" FAKE_SYSTEMCTL_STOP_RESTARTS=1 FAKE_SYSTEMCTL_NEW_RUN_SECONDS=2.5 \
        FAKE_SYSTEMCTL_RESTART_ONCE_FILE="$test_root/restart-once" \
        FAKE_SYSTEMCTL_INVOCATION_FILE="$test_root/invocation" WATCHDOG_KILL_GRACE_SECONDS=3
    wait

    [ -z "$(cat "$test_root/cgroup/cgroup.kill")" ] || fail_test 'the next run was force-killed'
    assert_contains "$test_root/curl.log" 'The timer started the next run right afterwards'
    assert_not_contains "$test_root/curl.log" 'force-killed'
    [ "$(grep -c '^Watchdog started for file-backup.service' "$test_root/watchdog.log")" -eq 2 ] || fail_test 'the next run was not watched'
    rm -rf "$test_root"
}

test_watchdog_episode_reports_once() {
    # A second run inside the same episode (19:34 after 19:01) records its
    # pause without pushing it again.
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    mkdir -p "$test_root/state/watchdog"
    printf 'opened_epoch=%s\nopened_at=2026-10-14T18:51:18Z\ncause=server memory shortage\npause=1\nnotified=1\n' "$(date -u +%s)" \
        > "$test_root/state/watchdog/file-backup.service.episode"
    printf 'anon 200000000\nfile 50000000\n' > "$test_root/cgroup/memory.stat"
    write_fake_meminfo "$test_root/proc" 500000
    end_fake_unit_after 1.5 "$test_root/cgroup"

    run_watchdog "$test_root" WATCHDOG_PRESSURE_SUSTAIN_SECONDS=0
    wait

    assert_contains "$test_root/watchdog.log" 'WATCHDOG EVENT [server-pressure]'
    assert_contains "$test_root/state/events.jsonl" 'backup paused: server short of memory'
    assert_not_contains "$test_root/curl.log" 'backup paused'
    rm -rf "$test_root"
}

test_watchdog_stops_for_critical_server_memory() {
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    write_fake_meminfo "$test_root/proc" 300000

    run_watchdog "$test_root"

    assert_contains "$test_root/systemctl.log" 'stop --no-block file-backup.service'
    assert_contains "$test_root/curl.log" 'backup stopped to protect the server'
    rm -rf "$test_root"
}

test_watchdog_unit_and_deploy_guards() {
    local test_root
    local deploy="$ROOT_DIR/production-deploy.sh"
    test_root=$(mktemp -d)
    sed \
        -e "s|__INSTALL_DIR__|$ROOT_DIR|g" \
        -e 's|__CONFIG_DIR__|/etc/backup-suite|g' \
        -e 's|__USER_GROUP_DIRECTIVES__||g' \
        -e 's|__WATCHDOG_PRIVILEGED_DIRECTIVES__|Nice=-5\nOOMScoreAdjust=-900|g' \
        "$ROOT_DIR/systemd/backup-suite-watchdog@.service.template" > "$test_root/backup-suite-watchdog@.service"
    for directive in 'ExecStart='"$ROOT_DIR"'/bin/backup-watchdog.sh %i.service' 'After=%i.service' 'Restart=no' 'OOMScoreAdjust=-900' 'MemoryMax=64M'; do
        assert_contains "$test_root/backup-suite-watchdog@.service" "$directive"
    done
    systemd-analyze verify "$test_root/backup-suite-watchdog@file-backup.service" >/dev/null
    assert_contains "$ROOT_DIR/systemd/file-backup.service.template" 'Wants=backup-suite-watchdog@file-backup.service'
    assert_contains "$ROOT_DIR/systemd/file-backup.service.template" 'OOMPolicy=stop'
    assert_contains "$ROOT_DIR/systemd/file-backup.service.template" 'MemorySwapMax=256M'

    assert_not_contains "$deploy" 'systemctl disable'
    assert_contains "$deploy" 'systemctl stop "$TIMER_UNIT"'
    assert_contains "$deploy" 'restore_previous_installation'
    assert_contains "$deploy" 'systemctl start "$TIMER_UNIT"'
    assert_contains "$deploy" '--stop-running'
    assert_contains "$deploy" 'install_swap_cap_dropin database-backup.service'
    assert_contains "$deploy" 'install_swap_cap_dropin database-size-check.service'
    assert_contains "$deploy" 'install_runtime_preserve_dropin database-backup.service'
    assert_contains "$deploy" 'install_runtime_preserve_dropin database-size-check.service'
    # /run/backup-suite holds the GUI's control socket: no unit may delete it on stop.
    local template
    for template in "$ROOT_DIR"/systemd/*.template; do
        if grep -q '^RuntimeDirectory=backup-suite' "$template"; then
            grep -Fxq 'RuntimeDirectoryPreserve=yes' "$template" || fail_test "$(basename "$template") must keep /run/backup-suite"
        fi
    done
    assert_contains "$deploy" 'bin/apply-schedule.sh" --no-reload'
    assert_contains "$deploy" 'backup-watchdog.sh" "$SERVICE_UNIT" --self-test'
    assert_contains "$deploy" 'backup-profile.sh" set "$REQUESTED_PROFILE"'
    assert_contains "$deploy" 'backup-profile.sh" adaptive "$REQUESTED_PROFILE" "$REQUESTED_FLOOR"'
    assert_contains "$ROOT_DIR/setup.sh" 'backup-suite-watchdog@.service.template'
    assert_contains "$ROOT_DIR/production-file-backup-migrate.sh" 'backup-suite-watchdog@.service.template'
    "$deploy" --help >/dev/null
    rm -rf "$test_root"
}

profile_cli() {
    local test_root="$1"
    shift
    env -u XDG_CONFIG_HOME -u XDG_STATE_HOME \
        HOME="$test_root/home" \
        PATH="$test_root/bin:$PATH" \
        FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" \
        BACKUP_SUITE_CONFIG_DIR="$test_root/config" \
        BACKUP_SUITE_PROC_DIR="$test_root/proc" \
        BACKUP_SUITE_CPU_COUNT=4 \
        "$ROOT_DIR/bin/backup-profile.sh" "$@"
}

test_profile_auto_limits_and_overrides() {
    local test_root
    test_root=$(mktemp -d)
    write_test_config "$test_root" rclone 'fake:'
    install_fake_tools "$test_root"
    mkdir -p "$test_root/proc"
    printf 'MemTotal:        8388608 kB\nMemAvailable:    4000000 kB\n' > "$test_root/proc/meminfo"

    profile_cli "$test_root" limits auto > "$test_root/output.log"
    assert_contains "$test_root/config/global.conf" 'FILE_PROFILE_LIMITS_MODE="auto"'
    profile_cli "$test_root" print-dropin moderate > "$test_root/moderate.conf"
    for directive in 'MemoryMax=819M' 'MemoryHigh=409M' 'MemorySwapMax=204M' 'CPUQuota=24%'; do
        assert_contains "$test_root/moderate.conf" "$directive"
    done

    profile_cli "$test_root" override slow MEMORY_MAX 384M > "$test_root/output.log"
    assert_contains "$test_root/config/global.conf" 'FILE_PROFILE_SLOW_MEMORY_MAX="384M"'
    profile_cli "$test_root" print-dropin slow > "$test_root/slow.conf"
    assert_contains "$test_root/slow.conf" 'MemoryMax=384M'
    assert_contains "$test_root/slow.conf" 'MemoryHigh=204M'
    profile_cli "$test_root" show > "$test_root/show.log"
    assert_contains "$test_root/show.log" 'auto-scaled to this host; your overrides: MEMORY_MAX'

    if profile_cli "$test_root" override slow MEMORY_MAX 'big$x' > "$test_root/output.log" 2>&1; then
        fail_test 'unsafe override values must be rejected'
    fi
    if profile_cli "$test_root" override slow NOT_A_KEY 1 > "$test_root/output.log" 2>&1; then
        fail_test 'unknown override keys must be rejected'
    fi
    if profile_cli "$test_root" override slow MEMORY_MAX lots > "$test_root/output.log" 2>&1; then
        fail_test 'invalid sizes must be rejected'
    fi
    assert_not_contains "$test_root/config/global.conf" 'FILE_PROFILE_SLOW_MEMORY_MAX="lots"'

    profile_cli "$test_root" override slow MEMORY_MAX --unset > "$test_root/output.log"
    assert_not_contains "$test_root/config/global.conf" 'FILE_PROFILE_SLOW_MEMORY_MAX'
    profile_cli "$test_root" limits fixed > "$test_root/output.log"
    profile_cli "$test_root" print-dropin moderate > "$test_root/moderate.conf"
    assert_contains "$test_root/moderate.conf" 'MemoryMax=1G'
    rm -rf "$test_root"
}

test_profile_requires_swap_cap() {
    # MemoryHigh with an unlimited swap allowance lets a throttled backup thrash
    # in swap for hours instead of reaching MemoryMax.
    local output
    if output=$(bash -c '. "$1/bin/common.sh"; FILE_CUSTOM_MEMORY_SWAP_MAX=infinity; resolve_file_backup_profile custom' _ "$ROOT_DIR" 2>&1); then
        fail_test 'a profile with unlimited swap was accepted'
    fi
    [[ "$output" == *"MemorySwapMax must be a size"* ]] || fail_test "unexpected error: $output"
    bash -c '. "$1/bin/common.sh"; for p in slow moderate fast; do resolve_file_backup_profile "$p"; done' _ "$ROOT_DIR" \
        || fail_test 'built-in profiles must carry a swap cap'
}

test_adaptive_profile_cli() {
    local test_root
    local dropin
    test_root=$(mktemp -d)
    write_test_config "$test_root" rclone 'fake:'
    install_fake_tools "$test_root"
    dropin="$test_root/home/.config/systemd/user/file-backup.service.d/50-backup-profile.conf"

    profile_cli "$test_root" adaptive moderate slow > "$test_root/output.log"
    assert_contains "$test_root/config/global.conf" 'FILE_BACKUP_PROFILE="moderate"'
    assert_contains "$test_root/config/global.conf" 'FILE_BACKUP_PROFILE_MODE="adaptive"'
    assert_contains "$test_root/config/global.conf" 'FILE_BACKUP_PROFILE_FLOOR="slow"'
    assert_contains "$dropin" 'CPUQuota=50%'
    [ "$(profile_cli "$test_root" current)" = "adaptive moderate>slow (now: moderate)" ] || fail_test 'adaptive setup was not reported'

    mkdir -p "$test_root/state/watchdog"
    printf 'level=slow\n' > "$test_root/state/watchdog/adaptive-profile.state"
    [ "$(profile_cli "$test_root" current)" = "adaptive moderate>slow (now: slow)" ] || fail_test 'current adaptive level was not read'

    if profile_cli "$test_root" adaptive slow moderate > "$test_root/output.log" 2>&1; then
        fail_test 'a floor faster than the top profile must be rejected'
    fi
    if profile_cli "$test_root" adaptive moderate moderate > "$test_root/output.log" 2>&1; then
        fail_test 'adaptive mode needs at least two levels'
    fi

    printf '5\n' | profile_cli "$test_root" choose > "$test_root/output.log"
    [ "$(profile_cli "$test_root" current)" = "adaptive fast>moderate>slow (now: fast)" ] || fail_test 'three-step adaptive setup was not chosen'
    assert_contains "$dropin" 'CPUQuota=100%'

    profile_cli "$test_root" set moderate > "$test_root/output.log"
    [ "$(profile_cli "$test_root" current)" = "fixed moderate" ] || fail_test 'set must switch back to a fixed profile'
    [ ! -e "$test_root/state/watchdog/adaptive-profile.state" ] || fail_test 'switching to fixed must clear the adaptive level'
    rm -rf "$test_root"
}

test_watchdog_adaptive_steps_down_and_up() {
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    cat >> "$test_root/config/global.conf" <<'EOF'
FILE_BACKUP_PROFILE="moderate"
FILE_BACKUP_PROFILE_MODE="adaptive"
FILE_BACKUP_PROFILE_FLOOR="slow"
WATCHDOG_ADAPTIVE_COOLDOWN_SECONDS="0"
WATCHDOG_ADAPTIVE_STEP_UP_SECONDS="1"
EOF
    printf '850000000\n' > "$test_root/cgroup/memory.current"
    printf 'anon 200000000\nfile 650000000\n' > "$test_root/cgroup/memory.stat"
    ( sleep 1; printf '100000000\n' > "$test_root/cgroup/memory.current" ) &
    end_fake_unit_after 4 "$test_root/cgroup"

    run_watchdog "$test_root"
    wait

    # Routine steps are recorded as events, not pushed (WATCHDOG_NOTIFY_PROFILE_STEPS=0).
    assert_contains "$test_root/state/events.jsonl" 'backup stepped down from moderate to slow'
    assert_contains "$test_root/state/events.jsonl" 'hard limit stays 953 MiB until usage drops below 512 MiB'
    assert_contains "$test_root/watchdog.log" 'applied the slow hard limit of 512 MiB'
    assert_contains "$test_root/state/events.jsonl" 'backup stepped back up from slow to moderate'
    assert_not_contains "$test_root/curl.log" 'stepped down'
    assert_contains "$test_root/state/watchdog/history.tsv" 'step-down'
    assert_contains "$test_root/state/watchdog/history.tsv" 'step-up'
    [ "$(cat "$test_root/cgroup/cpu.max")" = "50000 100000" ] || fail_test 'moderate CPU quota was not restored on step-up'
    [ "$(cat "$test_root/cgroup/memory.max")" = "1073741824" ] || fail_test 'moderate memory limit was not restored on step-up'
    assert_contains "$test_root/state/watchdog/adaptive-profile.state" 'level=moderate'
    assert_not_contains "$test_root/systemctl.log" 'stop'
    rm -rf "$test_root"
}

test_adaptive_level_carries_into_next_run() {
    local test_root
    test_root=$(mktemp -d)
    watchdog_fixture "$test_root"
    cat >> "$test_root/config/global.conf" <<'EOF'
FILE_BACKUP_PROFILE="moderate"
FILE_BACKUP_PROFILE_MODE="adaptive"
FILE_BACKUP_PROFILE_FLOOR="slow"
WATCHDOG_ADAPTIVE_STEP_UP_SECONDS="100"
EOF
    mkdir -p "$test_root/state/watchdog"
    printf 'level=slow\n' > "$test_root/state/watchdog/adaptive-profile.state"
    end_fake_unit_after 1 "$test_root/cgroup"

    run_watchdog "$test_root"
    wait

    assert_contains "$test_root/watchdog.log" "continuing at 'slow' from the previous run"
    [ "$(cat "$test_root/cgroup/cpu.max")" = "25000 100000" ] || fail_test 'the saved slow level was not applied at start'
    [ "$(cat "$test_root/cgroup/memory.max")" = "536870912" ] || fail_test 'the slow memory limit was not applied at start'
    [ ! -e "$test_root/curl.log" ] || fail_test 'continuing at a saved level must not notify'

    mkdir -p "$test_root/projects/good" "$test_root/fake"
    printf 'good\n' > "$test_root/projects/good/file.txt"
    sed -i "s|^USER_RCLONE_BIN=.*|USER_RCLONE_BIN=\"$ROOT_DIR/tests/fixtures/fake-rclone.sh\"|" "$test_root/config/global.conf"
    printf '1|good|%s|fixed|good|.nosync|single\n' "$test_root/projects/good" > "$test_root/config/file-sources.conf"
    FAKE_RCLONE_SCENARIO=isolation FAKE_RCLONE_STATE="$test_root/fake" run_backup "$test_root" > "$test_root/backup.log" 2>&1
    assert_contains "$test_root/fake/commands.log" '--transfers 1'
    assert_contains "$test_root/fake/commands.log" '--bwlimit 4M'
    assert_contains "$test_root/backup.log" 'Resource profile: slow (mode adaptive; levels moderate>slow)'
    rm -rf "$test_root"
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

setup_control_root() {
    # A user-mode installation with fake systemctl/journalctl/curl for the
    # control script. Prints nothing; the caller passes the root around.
    local test_root="$1"
    write_test_config "$test_root" rclone 'fake:'
    write_notify_config "$test_root"
    install_fake_tools "$test_root"
    ln -sf "$ROOT_DIR/tests/fixtures/fake-journalctl.sh" "$test_root/bin/journalctl"
    mkdir -p "$test_root/source/project-a/sub" "$test_root/state/logs" "$test_root/state/watchdog" "$test_root/state/failures" "$test_root/state/active-files"
    printf '1|workspace|%s/source|fixed|projects/workspace|.nosync|children\n' "$test_root" > "$test_root/config/file-sources.conf"
    printf 'cache/**\n*.tmp\n' > "$test_root/source/project-a/sub/.backup-excludes"
    write_fake_meminfo "$test_root/proc" 6000000
    printf 'type = drive\ntoken = {"access_token":"rclone-secret-value"}\n' > "$test_root/config/rclone.conf"
    cat >> "$test_root/config/global.conf" <<'CONF'
NOTIFY_NTFY_TOKEN="tk_secret_token_value"
CONF
}

control_call() {
    # control_call <test_root> <json-request> [extra args...]
    local test_root="$1"
    local request="$2"
    shift 2
    printf '%s\n' "$request" | HOME="$test_root/home" PATH="$test_root/bin:$PATH" \
        FAKE_CURL_LOG="$test_root/curl.log" FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" \
        FAKE_JOURNALCTL_LOG="$test_root/journalctl.log" \
        BACKUP_SUITE_CONFIG_DIR="$test_root/config" \
        BACKUP_SUITE_PROC_DIR="$test_root/proc" \
        "$ROOT_DIR/bin/backup-control.sh" "$@"
}

json_field() {
    # json_field <json> <python expression on d>
    python3 -c 'import json, sys; d = json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

test_control_read_verbs() {
    local test_root
    local reply
    test_root=$(mktemp -d)
    setup_control_root "$test_root"
    {
        echo 'File backup started at 2026-10-13 10:00:00 UTC'
        echo 'old run'
        echo 'File backup started at 2026-10-14 10:00:00 UTC'
        for index in $(seq 1 3000); do echo "line $index"; done
    } > "$test_root/state/logs/backup-file.log"
    printf 'started\tended\tunit\tprofile\tduration_s\tpeak_mem\tpeak_anon\tpeak_swap\tavg_cpu_pct\tpeak_cpu_pct\tpeak_tasks\tio_read\tio_write\tevents\toutcome\n' > "$test_root/state/watchdog/history.tsv"
    printf '2026-10-14T10:00:00Z\t2026-10-14T11:00:00Z\tfile-backup.service\tmoderate\t3600\t104857600\t52428800\t0\t2\t40\t20\t1000\t2000\tstep-down,step-up\tcompleted\n' >> "$test_root/state/watchdog/history.tsv"
    printf 'state=running\nmemory_bytes=1000\n' > "$test_root/state/watchdog/file-backup.service.status"
    printf '3\tproject-a/file.db\n' > "$test_root/state/active-files/workspace_project-a.tsv"
    printf 'failure text\n' > "$test_root/state/failures/20261014T100000Z-file-backup.service.log"

    reply=$(control_call "$test_root" '{"verb":"status"}')
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "status failed: $reply"
    [ "$(json_field "$reply" 'd["data"]["services"]["file-backup.service"]["ActiveState"]')" = "inactive" ] || fail_test "status did not parse unit blocks: $reply"
    [ "$(json_field "$reply" 'd["data"]["watchdog"]["state"]')" = "running" ] || fail_test 'status did not read the watchdog status file'
    [ "$(json_field "$reply" 'd["data"]["mode"]')" = "user" ] || fail_test 'status mode is not user'
    assert_contains "$test_root/systemctl.log" '--user show file-backup.service'

    reply=$(control_call "$test_root" '{"verb":"history","args":{"limit":5}}')
    [ "$(json_field "$reply" 'd["data"]["rows"][0]["events"]')" = "['step-down', 'step-up']" ] || fail_test "history events not parsed: $reply"
    [ "$(json_field "$reply" 'd["data"]["rows"][0]["peak_mem"]')" = "104857600" ] || fail_test 'history numbers not parsed'

    reply=$(control_call "$test_root" '{"verb":"runlog","args":{"run":"latest","lines":100000}}')
    [ "$(json_field "$reply" 'len(d["data"]["lines"])')" = "2000" ] || fail_test 'runlog was not bounded to 2000 lines'
    [ "$(json_field "$reply" 'd["data"]["truncated"]')" = "True" ] || fail_test 'runlog did not report truncation'
    reply=$(control_call "$test_root" '{"verb":"runlog","args":{"run":"2026-10-13T10:01:00Z","lines":10}}')
    [ "$(json_field "$reply" 'd["data"]["lines"][-1]')" = "old run" ] || fail_test "runlog did not pick the run by start time: $reply"

    reply=$(control_call "$test_root" '{"verb":"journal","args":{"source":"watchdog","lines":5}}')
    assert_contains "$test_root/journalctl.log" '--user -t backup-watchdog -n 5'

    reply=$(control_call "$test_root" '{"verb":"failures.list"}')
    [ "$(json_field "$reply" 'd["data"]["failures"][0]["name"]')" = "20261014T100000Z-file-backup.service.log" ] || fail_test 'failure list wrong'
    reply=$(control_call "$test_root" '{"verb":"deferrals"}')
    [ "$(json_field "$reply" 'd["data"]["rows"][0]["count"]')" = "3" ] || fail_test 'deferrals not read'
    reply=$(control_call "$test_root" '{"verb":"sources.get"}')
    [ "$(json_field "$reply" 'd["data"]["rows"][0]["isolation"]')" = "children" ] || fail_test 'sources not parsed'
    [ "$(json_field "$reply" 'd["data"]["editable"]')" = "False" ] || fail_test 'sources must be read-only in v1'
    reply=$(control_call "$test_root" '{"verb":"excludes.list"}')
    [ "$(json_field "$reply" 'd["data"]["files"][0]["lines"]')" = "['cache/**', '*.tmp']" ] || fail_test "excludes not found: $reply"
    reply=$(control_call "$test_root" '{"verb":"profile.show"}')
    [ "$(json_field "$reply" 'd["data"]["profiles"][0]["name"]')" = "slow" ] || fail_test 'profile.show failed'

    for request in '{"verb":"nope"}' '{"verb":"status","extra":1}' '{"verb":"status","args":{"x":1}}' \
        '{"verb":"failures.read","args":{"name":"../../etc/passwd"}}' '{"verb":"history","args":{"limit":"9"}}' \
        '{"verb":"journal","args":{"source":"sshd"}}' 'not json' '{"verb":"backup.start","args":{"what":"everything"}}'; do
        reply=$(control_call "$test_root" "$request")
        [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "not refused: $request -> $reply"
    done
    [ ! -s "$test_root/state/gui/audit.jsonl" ] || fail_test 'a refused request left an audit line'
}

test_control_never_returns_secrets() {
    local test_root
    local verb
    local all_replies
    test_root=$(mktemp -d)
    setup_control_root "$test_root"
    all_replies="$test_root/replies.txt"
    for verb in status history runlog journal failures.list deferrals sources.get excludes.list profile.show config.get events.since audit; do
        control_call "$test_root" "{\"verb\":\"$verb\"}" >> "$all_replies"
    done
    assert_not_contains "$all_replies" 'tk_secret_token_value'
    assert_not_contains "$all_replies" 'rclone-secret-value'
    assert_not_contains "$all_replies" 'https://ntfy.invalid/test-topic'
    assert_contains "$all_replies" '"key":"NOTIFY_NTFY_TOKEN"'
    assert_contains "$all_replies" '"is_set":true'
}

test_control_jobs() {
    # Add, check, edit, enable/disable, remove and run backup jobs through the
    # control script: every refusal, the written lines, per-job patterns, backups,
    # the conflict check, and that a run backs up only the requested job.
    local test_root
    local reply
    local sha
    test_root=$(mktemp -d)
    setup_control_root "$test_root"
    mkdir -p "$test_root/web/site" "$test_root/source/project-b"
    printf 'FILE_JOB_SOURCE_ROOTS="%s"\n' "$test_root" >> "$test_root/config/global.conf"
    sha=$(json_field "$(control_call "$test_root" '{"verb":"jobs"}')" 'd["data"]["sha256"]')

    # Refusals: outside the allowed roots, a system folder, a folder holding Backup
    # Suite's own config, a duplicate name, an overlapping destination, | in a field.
    reply=$(control_call "$test_root" '{"verb":"job.check","args":{"job":{"label":"etc","source":"/etc","destination_mode":"fixed","destination_value":"x","isolation":"single"}}}')
    [ "$(json_field "$reply" 'any("only folders under" in p for p in d["data"]["problems"]) and any("system or Backup Suite" in p for p in d["data"]["problems"])')" = "True" ] || fail_test "/etc must be refused: $reply"
    reply=$(control_call "$test_root" "{\"verb\":\"job.check\",\"args\":{\"job\":{\"label\":\"all\",\"source\":\"$test_root\",\"destination_mode\":\"fixed\",\"destination_value\":\"all\",\"isolation\":\"single\"}}}")
    [ "$(json_field "$reply" 'any("system or Backup Suite" in p for p in d["data"]["problems"])')" = "True" ] || fail_test "a source holding the config must be refused: $reply"
    reply=$(control_call "$test_root" "{\"verb\":\"job.check\",\"args\":{\"job\":{\"label\":\"workspace\",\"source\":\"$test_root/web\",\"destination_mode\":\"fixed\",\"destination_value\":\"projects/workspace/sub\",\"isolation\":\"single\"}}}")
    [ "$(json_field "$reply" 'any("already named" in p for p in d["data"]["problems"]) and any("overlaps job workspace" in p for p in d["data"]["problems"])')" = "True" ] || fail_test "duplicate name and overlapping destination: $reply"
    reply=$(control_call "$test_root" "{\"verb\":\"job.save\",\"args\":{\"expect_sha\":\"$sha\",\"job\":{\"label\":\"bad|name\",\"source\":\"$test_root/web\",\"destination_mode\":\"fixed\",\"destination_value\":\"sites/web\",\"isolation\":\"single\"}}}")
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "a | in the name must be refused: $reply"

    # Add a job with its own patterns.
    reply=$(control_call "$test_root" "{\"verb\":\"job.save\",\"args\":{\"expect_sha\":\"$sha\",\"job\":{\"enabled\":true,\"label\":\"web\",\"source\":\"$test_root/web\",\"destination_mode\":\"fixed\",\"destination_value\":\"sites/web\",\"stop_file\":\".nosync\",\"isolation\":\"children\",\"excludes\":[\"*.log\",\"cache/**\"],\"volatile\":[\"db/*.sqlite\"]}}}")
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "job.save add: $reply"
    assert_contains "$test_root/config/file-sources.conf" "1|web|$test_root/web|fixed|sites/web|.nosync|children"
    assert_contains "$test_root/config/jobs/web.excludes" 'cache/**'
    assert_contains "$test_root/config/jobs/web.volatile" 'db/*.sqlite'
    ls "$test_root/state/gui/config-backups/" | grep -q '^file-sources.conf\.' || fail_test 'no backup copy of file-sources.conf'
    assert_contains "$test_root/state/gui/audit.jsonl" '"verb": "job.save"'

    # A stale checksum is refused.
    reply=$(control_call "$test_root" "{\"verb\":\"job.enable\",\"args\":{\"expect_sha\":\"$sha\",\"name\":\"web\",\"enabled\":false}}")
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "config_conflict" ] || fail_test "stale sha: $reply"

    # Edit (rename) moves the patterns; disable keeps the rest of the line.
    sha=$(json_field "$(control_call "$test_root" '{"verb":"jobs"}')" 'd["data"]["sha256"]')
    reply=$(control_call "$test_root" "{\"verb\":\"job.save\",\"args\":{\"expect_sha\":\"$sha\",\"name\":\"web\",\"job\":{\"enabled\":true,\"label\":\"websites\",\"source\":\"$test_root/web\",\"destination_mode\":\"fixed\",\"destination_value\":\"sites/web\",\"stop_file\":\"\",\"isolation\":\"children\",\"excludes\":[\"*.log\"],\"volatile\":[]}}}")
    [ "$(json_field "$reply" 'd["data"]["renamed_from"]')" = "web" ] || fail_test "rename: $reply"
    [ ! -e "$test_root/config/jobs/web.excludes" ] || fail_test 'old pattern file left behind'
    [ ! -e "$test_root/config/jobs/websites.volatile" ] || fail_test 'an empty pattern list must remove its file'
    assert_contains "$test_root/config/jobs/websites.excludes" '*.log'
    sha=$(json_field "$reply" 'd["data"]["sha256"]')
    reply=$(control_call "$test_root" "{\"verb\":\"job.enable\",\"args\":{\"expect_sha\":\"$sha\",\"name\":\"websites\",\"enabled\":false}}")
    assert_contains "$test_root/config/file-sources.conf" "0|websites|$test_root/web|fixed|sites/web||children"
    sha=$(json_field "$reply" 'd["data"]["sha256"]')

    # A disabled job cannot run; an enabled one runs alone.
    reply=$(control_call "$test_root" '{"verb":"job.run","args":{"name":"websites"}}')
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "disabled job run: $reply"
    reply=$(control_call "$test_root" '{"verb":"job.run","args":{"name":"workspace"}}')
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "job.run: $reply"
    assert_contains "$test_root/state/run/job-request.env" 'jobs=workspace'
    assert_contains "$test_root/systemctl.log" 'start --no-block file-backup.service'

    # Remove: the line and the patterns go; nothing else changes.
    reply=$(control_call "$test_root" "{\"verb\":\"job.remove\",\"args\":{\"expect_sha\":\"$sha\",\"name\":\"websites\"}}")
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "job.remove: $reply"
    assert_not_contains "$test_root/config/file-sources.conf" 'websites'
    assert_contains "$test_root/config/file-sources.conf" '1|workspace|'
    [ ! -e "$test_root/config/jobs/websites.excludes" ] || fail_test 'removed job kept its patterns'
    rm -rf "$test_root"
}

test_job_run_and_job_patterns() {
    # file-backup.sh: a fresh job request backs up only that job and is used
    # once; an old one is ignored; a job's own excludes reach rclone.
    local test_root
    local output_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    mkdir -p "$test_root/one" "$test_root/two" "$test_root/remote" "$test_root/state/run" "$test_root/config/jobs"
    printf 'keep\n' > "$test_root/one/keep.txt"
    printf 'skip\n' > "$test_root/one/skip.log"
    printf 'two\n' > "$test_root/two/t.txt"
    write_test_config "$test_root" rclone 'backup:'
    printf '[backup]\ntype = alias\nremote = %s\n' "$test_root/remote" > "$test_root/config/rclone.conf"
    printf '1|one|%s|fixed|jobs/one|.nosync|single\n1|two|%s|fixed|jobs/two|.nosync|single\n' "$test_root/one" "$test_root/two" > "$test_root/config/file-sources.conf"
    printf '# test\n*.log\n' > "$test_root/config/jobs/one.excludes"
    printf 'jobs=one\nrequested_at=%s\nrequested_by=tester\n' "$(date +%s)" > "$test_root/state/run/job-request.env"
    run_backup "$test_root" > "$output_file" 2>&1 || fail_test "job run failed: $(tail -5 "$output_file")"
    assert_contains "$output_file" 'Backing up only job(s) one, as requested from the GUI by tester.'
    assert_file "$test_root/remote/jobs/one/keep.txt"
    [ ! -e "$test_root/remote/jobs/one/skip.log" ] || fail_test "the job's own exclude was not applied"
    [ ! -e "$test_root/remote/jobs/two" ] || fail_test 'a job that was not requested was backed up'
    [ ! -e "$test_root/state/run/job-request.env" ] || fail_test 'the request must be used once'
    printf 'jobs=one\nrequested_at=%s\n' "$(( $(date +%s) - 3600 ))" > "$test_root/state/run/job-request.env"
    run_backup "$test_root" > "$output_file" 2>&1 || true
    assert_contains "$output_file" 'Ignoring an old job request'
    assert_file "$test_root/remote/jobs/two/t.txt"
    rm -rf "$test_root"
}

test_control_job_exclude() {
    # Changing files: exclude a file or a folder in one child project or in every
    # project of the job; the patterns go to the job's config (escaped), the row
    # leaves the changing list, an exclude can be removed again, and bad input is refused.
    local test_root
    local reply
    local key
    test_root=$(mktemp -d)
    setup_control_root "$test_root"
    mkdir -p "$test_root/source/project-b"
    reply=$(control_call "$test_root" '{"verb":"job","args":{"name":"workspace"}}')
    key=$(json_field "$reply" '[p["key"] for p in d["data"]["projects"] if p["project"] == "workspace/project-a"][0]')
    printf '14\t.ai-metadata/lifecycle/state.json\n3\t.ai-metadata/lifecycle/other.json\n2\tsrc/a[1].txt\n' > "$test_root/state/active-files/$key.tsv"

    reply=$(control_call "$test_root" '{"verb":"job.exclude","args":{"name":"workspace","path":".ai-metadata/lifecycle","folder":true,"scope":"project","project":"project-a"}}')
    [ "$(json_field "$reply" 'd["data"]["pattern"] == ".ai-metadata/lifecycle/**" and d["data"]["cleared"] == 2')" = "True" ] || fail_test "project exclude: $reply"
    assert_contains "$test_root/config/jobs/workspace.projects/project-a.excludes" '.ai-metadata/lifecycle/**'
    [ "$(cat "$test_root/state/active-files/$key.tsv")" = "$(printf '2\tsrc/a[1].txt')" ] || fail_test 'the excluded folder must leave the changing list'
    reply=$(control_call "$test_root" '{"verb":"job.exclude","args":{"name":"workspace","path":"src/a[1].txt","scope":"job"}}')
    [ "$(json_field "$reply" 'd["data"]["pattern"]')" = 'src/a\[1\].txt' ] || fail_test "glob characters must be escaped: $reply"
    [ ! -e "$test_root/state/active-files/$key.tsv" ] || fail_test 'an empty changing list must be removed'
    assert_contains "$test_root/config/jobs/workspace.excludes" 'src/a\[1\].txt'

    reply=$(control_call "$test_root" '{"verb":"job","args":{"name":"workspace"}}')
    [ "$(json_field "$reply" 'd["data"]["project_patterns"] == {"project-a": [".ai-metadata/lifecycle/**"]} and d["data"]["patterns"]["excludes"] == [r"src/a\[1\].txt"]')" = "True" ] || fail_test "job must list the excludes: $reply"

    for bad in '"path":"../etc/passwd","scope":"job"' '"path":"a","scope":"project","project":"nope"' '"path":"a","scope":"project","project":"../x"' '"path":"a|b","scope":"job"'; do
        reply=$(control_call "$test_root" "{\"verb\":\"job.exclude\",\"args\":{\"name\":\"workspace\",$bad}}")
        [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "must be refused ($bad): $reply"
    done
    reply=$(control_call "$test_root" '{"verb":"job.exclude","args":{"name":"workspace","scope":"project","project":"project-a","remove":true,"pattern":".ai-metadata/lifecycle/**"}}')
    [ "$(json_field "$reply" 'd["data"]["removed"]')" = "True" ] || fail_test "remove: $reply"
    [ ! -e "$test_root/config/jobs/workspace.projects/project-a.excludes" ] || fail_test 'an empty project list must be removed'
    grep -q 'Excluded from job workspace' "$test_root/state/events.jsonl" || fail_test 'the exclude must be audited'
    rm -rf "$test_root"
}

test_job_project_excludes_in_backup() {
    # file-backup.sh applies a child project's own excludes to that project only,
    # and the job's excludes to every project.
    local test_root
    local output_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    mkdir -p "$test_root/ws/alpha/.meta/lifecycle" "$test_root/ws/beta/.meta/lifecycle" "$test_root/remote" "$test_root/config/jobs/ws.projects"
    for project in alpha beta; do
        printf 's\n' > "$test_root/ws/$project/.meta/lifecycle/state.json"
        printf 'k\n' > "$test_root/ws/$project/keep.txt"
        printf 'l\n' > "$test_root/ws/$project/debug.log"
    done
    touch -d '10 minutes ago' "$test_root"/ws/*/.meta/lifecycle/state.json "$test_root"/ws/*/keep.txt "$test_root"/ws/*/debug.log
    write_test_config "$test_root" rclone 'backup:'
    printf '[backup]\ntype = alias\nremote = %s\n' "$test_root/remote" > "$test_root/config/rclone.conf"
    printf '1|ws|%s|fixed|ws|.nosync|children\n' "$test_root/ws" > "$test_root/config/file-sources.conf"
    printf '*.log\n' > "$test_root/config/jobs/ws.excludes"
    printf '.meta/lifecycle/**\n' > "$test_root/config/jobs/ws.projects/alpha.excludes"
    run_backup "$test_root" > "$output_file" 2>&1 || fail_test "backup failed: $(tail -5 "$output_file")"
    assert_file "$test_root/remote/ws/alpha/keep.txt"
    [ ! -e "$test_root/remote/ws/alpha/.meta/lifecycle/state.json" ] || fail_test "alpha's own exclude was not applied"
    assert_file "$test_root/remote/ws/beta/.meta/lifecycle/state.json"
    [ ! -e "$test_root/remote/ws/alpha/debug.log" ] && [ ! -e "$test_root/remote/ws/beta/debug.log" ] || fail_test "the job's exclude must apply to every project"
    rm -rf "$test_root"
}

test_control_settings_catalog() {
    # Every global.conf key is shown; programs and paths are read-only; a schedule
    # change is applied to the timers as drop-ins.
    local test_root
    local reply
    local sha
    test_root=$(mktemp -d)
    setup_control_root "$test_root"
    printf 'FILE_RCLONE_EXTRA_FLAGS="--fast-list"\nMY_OWN_KEY="x"\n' >> "$test_root/config/global.conf"
    mkdir -p "$test_root/home/.config/systemd/user"
    printf '[Timer]\nOnCalendar=*:0/30\n' > "$test_root/home/.config/systemd/user/file-backup.timer"
    reply=$(control_call "$test_root" '{"verb":"config.get"}')
    [ "$(json_field "$reply" 'all(k in [s["key"] for s in d["data"]["settings"]] for k in ["FILE_BACKUP_ONCALENDAR","DB_RETENTION_DAYS","USER_RCLONE_BIN","MY_OWN_KEY","FILE_JOB_SOURCE_ROOTS"])')" = "True" ] || fail_test "config.get must list every key: $reply"
    [ "$(json_field "$reply" '[s for s in d["data"]["settings"] if s["key"] == "FILE_RCLONE_EXTRA_FLAGS"][0]["editable"]')" = "False" ] || fail_test 'extra rclone flags must be read-only'
    sha=$(json_field "$reply" 'd["data"]["sha256"]')
    for key in USER_RCLONE_BIN FILE_RCLONE_EXTRA_FLAGS FILE_JOB_SOURCE_ROOTS MY_OWN_KEY FILE_BACKUP_PROFILE; do
        reply=$(control_call "$test_root" "{\"verb\":\"config.set\",\"args\":{\"expect_sha\":\"$sha\",\"changes\":{\"$key\":\"x\"}}}")
        [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "$key must not be settable: $reply"
    done
    reply=$(control_call "$test_root" "{\"verb\":\"config.set\",\"args\":{\"expect_sha\":\"$sha\",\"changes\":{\"FILE_BACKUP_ONCALENDAR\":\"not a time\"}}}")
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "a bad calendar must be refused: $reply"
    reply=$(control_call "$test_root" "{\"verb\":\"config.set\",\"args\":{\"expect_sha\":\"$sha\",\"changes\":{\"FILE_BACKUP_ONCALENDAR\":\"hourly\",\"DB_RETENTION_DAYS\":\"30\"}}}")
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "schedule save: $reply"
    assert_contains "$test_root/config/global.conf" 'FILE_BACKUP_ONCALENDAR="hourly"'
    assert_contains "$test_root/home/.config/systemd/user/file-backup.timer.d/60-schedule.conf" 'OnCalendar=hourly'
    assert_contains "$test_root/systemctl.log" 'daemon-reload'
    rm -rf "$test_root"
}

test_control_destinations() {
    # Destinations (rclone remotes) from the GUI: allowed types only, no option
    # that reads a file or runs a program, secrets never returned, the OAuth
    # questions step by step, delete refused while in use; the folder picker stays
    # inside FILE_JOB_SOURCE_ROOTS; a job can use its own remote.
    local test_root
    local reply
    local state
    test_root=$(mktemp -d)
    setup_control_root "$test_root"
    printf '[backup]\ntype = alias\nremote = %s\n' "$test_root/remote" > "$test_root/config/rclone.conf"
    printf 'RCLONE_REMOTE_ROOT="backup:"\nFILE_JOB_SOURCE_ROOTS="%s"\n' "$test_root" >> "$test_root/config/global.conf"
    mkdir -p "$test_root/remote" "$test_root/web/site"

    reply=$(control_call "$test_root" '{"verb":"remote.create","args":{"name":"disk","type":"local","options":{}}}')
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "a local remote must be refused: $reply"
    reply=$(control_call "$test_root" '{"verb":"remote.create","args":{"name":"box1","type":"sftp","options":{"host":"localhost","key_file":"/root/.ssh/id_rsa"}}}')
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "key_file must be refused: $reply"
    reply=$(control_call "$test_root" '{"verb":"remote.create","args":{"name":"store","type":"sftp","options":{"host":"backup.example.invalid","user":"me","pass":"secret-value-1"}}}')
    [ "$(json_field "$reply" 'd["data"]["done"]')" = "True" ] || fail_test "sftp create: $reply"
    reply=$(control_call "$test_root" '{"verb":"remotes","args":{"providers":true}}')
    [ "$(json_field "$reply" '[r for r in d["data"]["remotes"] if r["name"] == "store"][0]["settings"]["host"]')" = "backup.example.invalid" ] || fail_test "remotes list: $reply"
    case "$reply" in *secret-value-1*) fail_test 'a password was returned' ;; esac
    [ "$(json_field "$reply" '"drive" in d["data"]["providers"] and "local" not in d["data"]["providers"]')" = "True" ] || fail_test 'providers: allowed types only'
    [ "$(json_field "$reply" '[r for r in d["data"]["remotes"] if r["name"] == "backup"][0]["used_by"][0].startswith("the default destination")')" = "True" ] || fail_test 'usage of the default root'

    # Google Drive, headless: rclone's own questions, one step at a time.
    reply=$(control_call "$test_root" '{"verb":"remote.create","args":{"name":"gd","type":"drive","options":{"scope":"drive"}}}')
    [ "$(json_field "$reply" 'd["data"]["question"]["name"]')" = "config_is_local" ] || fail_test "drive first question: $reply"
    state=$(json_field "$reply" 'd["data"]["state"]')
    reply=$(control_call "$test_root" '{"verb":"remote.continue","args":{"name":"gd","state":"stale","result":"false"}}')
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "config_conflict" ] || fail_test "a stale step must be refused: $reply"
    reply=$(control_call "$test_root" "{\"verb\":\"remote.continue\",\"args\":{\"name\":\"gd\",\"state\":\"$state\",\"result\":\"false\"}}")
    [ "$(json_field "$reply" 'd["data"]["question"]["name"] == "config_token" and "rclone authorize" in d["data"]["question"]["help"]')" = "True" ] || fail_test "drive token question: $reply"

    # Delete: refused while in use, allowed otherwise.
    reply=$(control_call "$test_root" '{"verb":"remote.delete","args":{"name":"backup"}}')
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "deleting the default root must be refused: $reply"
    reply=$(control_call "$test_root" '{"verb":"remote.delete","args":{"name":"gd"}}')
    [ "$(json_field "$reply" 'd["data"]["deleted"]')" = "True" ] || fail_test "delete: $reply"

    # The folder picker: any folder can be browsed (folders only), only allowed
    # ones can be chosen, and pseudo file systems are not listed.
    reply=$(control_call "$test_root" '{"verb":"fs.browse","args":{}}')
    [ "$(json_field "$reply" 'd["data"]["path"] == d["data"]["home"]')" = "True" ] || fail_test "the picker must start at the caller's home: $reply"
    reply=$(control_call "$test_root" "{\"verb\":\"fs.browse\",\"args\":{\"path\":\"$test_root/web\"}}")
    [ "$(json_field "$reply" '[f["name"] for f in d["data"]["folders"]] == ["site"] and d["data"]["folders"][0]["selectable"] and d["data"]["selectable"]')" = "True" ] || fail_test "picker listing: $reply"
    reply=$(control_call "$test_root" "{\"verb\":\"fs.browse\",\"args\":{\"path\":\"$test_root\"}}")
    [ "$(json_field "$reply" '[f["selectable"] for f in d["data"]["folders"] if f["name"] == "config"]')" = "[False]" ] || fail_test "the config folder must not be selectable: $reply"
    reply=$(control_call "$test_root" '{"verb":"fs.browse","args":{"path":"/etc"}}')
    [ "$(json_field "$reply" 'd["data"]["selectable"] == False and "system" in d["data"]["reason"] and len(d["data"]["folders"]) > 0')" = "True" ] || fail_test "/etc may be browsed but not chosen: $reply"
    reply=$(control_call "$test_root" '{"verb":"fs.browse","args":{"path":"/"}}')
    [ "$(json_field "$reply" 'd["data"]["parent"] is None and not any(f["name"] in ("proc", "sys", "dev", "run") for f in d["data"]["folders"])')" = "True" ] || fail_test "the root listing: $reply"
    reply=$(control_call "$test_root" '{"verb":"fs.browse","args":{"path":"/proc/1"}}')
    [ "$(json_field "$reply" 'd["data"]["folders"] == [] and "system file system" in d["data"]["denied"]')" = "True" ] || fail_test "/proc must not be listed: $reply"
    reply=$(control_call "$test_root" '{"verb":"fs.browse","args":{"path":"relative"}}')
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "a relative path must be refused: $reply"

    # A job on its own remote; an unknown remote is refused.
    reply=$(control_call "$test_root" "{\"verb\":\"job.check\",\"args\":{\"job\":{\"label\":\"site\",\"source\":\"$test_root/web/site\",\"destination_mode\":\"remote\",\"destination_value\":\"store:backups/site\",\"isolation\":\"single\"}}}")
    [ "$(json_field "$reply" 'd["data"]["problems"] == [] and d["data"]["info"]["destination"] == "store:/backups/site"')" = "True" ] || fail_test "remote job check: $reply"
    reply=$(control_call "$test_root" "{\"verb\":\"job.check\",\"args\":{\"job\":{\"label\":\"site\",\"source\":\"$test_root/web/site\",\"destination_mode\":\"remote\",\"destination_value\":\"nope:x\",\"isolation\":\"single\"}}}")
    [ "$(json_field "$reply" 'any("no destination named nope" in p for p in d["data"]["problems"])')" = "True" ] || fail_test "unknown remote: $reply"
    rm -rf "$test_root"
}

test_job_on_its_own_remote() {
    # file-backup.sh: a job with destination mode remote goes to that remote, and
    # previous versions are kept and cleaned there.
    local test_root
    local output_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    mkdir -p "$test_root/src" "$test_root/main" "$test_root/other"
    printf 'v1\n' > "$test_root/src/a.txt"
    write_test_config "$test_root" rclone 'backup:'
    printf '[backup]\ntype = alias\nremote = %s\n\n[other]\ntype = alias\nremote = %s\n' "$test_root/main" "$test_root/other" > "$test_root/config/rclone.conf"
    printf '1|elsewhere|%s|remote|other:jobs/elsewhere|.nosync|single\n' "$test_root/src" > "$test_root/config/file-sources.conf"
    run_backup "$test_root" > "$output_file" 2>&1 || fail_test "remote job run failed: $(tail -5 "$output_file")"
    assert_file "$test_root/other/jobs/elsewhere/a.txt"
    [ -z "$(ls -A "$test_root/main")" ] || fail_test 'nothing may go to the default remote'
    sleep 1
    printf 'v2\n' > "$test_root/src/a.txt"
    run_backup "$test_root" > "$output_file" 2>&1 || fail_test "second run failed"
    find "$test_root/other/deleted_files" -name a.txt | grep -q . || fail_test 'the previous version must be kept on the same remote'
    assert_contains "$output_file" 'Cleaning archived file versions older than 21d from other:/deleted_files'
    rm -rf "$test_root"
}

test_control_config_set() {
    local test_root
    local reply
    local sha
    local inode_before
    local sources_sha
    test_root=$(mktemp -d)
    setup_control_root "$test_root"
    mv "$test_root/config/global.conf" "$test_root/config/global.conf.real"
    ln -s global.conf.real "$test_root/config/global.conf"
    inode_before=$(stat -c %i "$test_root/config/global.conf.real")
    sources_sha=$(sha256sum "$test_root/config/file-sources.conf" | cut -d' ' -f1)

    reply=$(control_call "$test_root" '{"verb":"config.set","args":{"changes":{"WATCHDOG_KILL_PERCENT":"85"},"expect_sha":"0000000000000000000000000000000000000000000000000000000000000000"}}')
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "config_conflict" ] || fail_test "stale sha accepted: $reply"
    assert_not_contains "$test_root/config/global.conf.real" 'WATCHDOG_KILL_PERCENT="85"'

    sha=$(json_field "$(control_call "$test_root" '{"verb":"config.get"}')" 'd["data"]["sha256"]')
    for changes in '{"RCLONE_BIN":"/bin/sh"}' '{"WATCHDOG_KILL_PERCENT":"50"}' '{"WATCHDOG_KILL_PERCENT":"8$(id)"}' \
        '{"NOTIFY_NTFY_TOPIC_URL":"http://insecure.example/x"}' '{"WATCHDOG_SYSTEM_CRITICAL_AVAILABLE_PERCENT":"15"}'; do
        reply=$(control_call "$test_root" "{\"verb\":\"config.set\",\"args\":{\"changes\":$changes,\"expect_sha\":\"$sha\"}}")
        [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "invalid change accepted: $changes -> $reply"
    done

    reply=$(control_call "$test_root" "{\"verb\":\"config.set\",\"args\":{\"changes\":{\"WATCHDOG_KILL_PERCENT\":\"85\",\"NOTIFY_NTFY_TOKEN\":\"tk_new_token\"},\"expect_sha\":\"$sha\"},\"session\":\"s1\"}")
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "valid change failed: $reply"
    assert_contains "$test_root/config/global.conf.real" 'WATCHDOG_KILL_PERCENT="85"'
    assert_contains "$test_root/config/global.conf.real" 'NOTIFY_NTFY_TOKEN="tk_new_token"'
    [ -L "$test_root/config/global.conf" ] || fail_test 'config symlink was replaced'
    [ "$(stat -c %i "$test_root/config/global.conf.real")" = "$inode_before" ] || fail_test 'config inode changed'
    ls "$test_root/state/gui/config-backups/" | grep -q '^global.conf\.' || fail_test 'no config backup copy'
    assert_contains "$test_root/state/gui/audit.jsonl" '"verb": "config.set"'
    assert_contains "$test_root/state/gui/audit.jsonl" '"NOTIFY_NTFY_TOKEN": "[set]"'
    assert_not_contains "$test_root/state/gui/audit.jsonl" 'tk_new_token'
    assert_not_contains "$test_root/state/events.jsonl" 'tk_new_token'
    assert_contains "$test_root/state/events.jsonl" '"category":"gui-action"'
    [ "$(sha256sum "$test_root/config/file-sources.conf" | cut -d' ' -f1)" = "$sources_sha" ] || fail_test 'file-sources.conf changed'
}

test_control_profile_matches_cli() {
    local gui_root
    local cli_root
    local reply
    gui_root=$(mktemp -d)
    cli_root=$(mktemp -d)
    setup_control_root "$gui_root"
    setup_control_root "$cli_root"

    reply=$(control_call "$gui_root" '{"verb":"profile.set","args":{"mode":"adaptive","top":"moderate","floor":"slow"}}')
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "profile.set failed: $reply"
    [ "$(json_field "$reply" 'd["data"]["profiles"]["ladder"]')" = "['moderate', 'slow']" ] || fail_test 'ladder not returned'
    HOME="$cli_root/home" PATH="$cli_root/bin:$PATH" FAKE_SYSTEMCTL_LOG="$cli_root/systemctl.log" \
        BACKUP_SUITE_CONFIG_DIR="$cli_root/config" "$ROOT_DIR/bin/backup-profile.sh" adaptive moderate slow > /dev/null

    diff <(grep '^FILE_BACKUP_PROFILE' "$gui_root/config/global.conf") <(grep '^FILE_BACKUP_PROFILE' "$cli_root/config/global.conf") \
        || fail_test 'GUI and CLI wrote different profile keys'
    diff "$gui_root/home/.config/systemd/user/file-backup.service.d/50-backup-profile.conf" \
        "$cli_root/home/.config/systemd/user/file-backup.service.d/50-backup-profile.conf" || fail_test 'GUI and CLI wrote different drop-ins'

    for request in '{"verb":"profile.set","args":{"mode":"adaptive","top":"slow","floor":"moderate"}}' \
        '{"verb":"profile.set","args":{"mode":"fixed","profile":"turbo"}}' \
        '{"verb":"profile.override","args":{"profile":"slow","key":"MEMORY_MAX","value":"1G; rm -rf /"}}' \
        '{"verb":"profile.override","args":{"profile":"slow","key":"PATH","value":"1"}}'; do
        reply=$(control_call "$gui_root" "$request")
        [ "$(json_field "$reply" 'd["error"]["code"]')" = "invalid_request" ] || fail_test "not refused: $request -> $reply"
    done
    reply=$(control_call "$gui_root" '{"verb":"profile.override","args":{"profile":"slow","key":"MEMORY_MAX","value":"384M"}}')
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "override failed: $reply"
    assert_contains "$gui_root/config/global.conf" 'FILE_PROFILE_SLOW_MEMORY_MAX="384M"'
    reply=$(control_call "$gui_root" '{"verb":"profile.preview","args":{"mode":"fixed","profile":"slow"}}')
    [[ "$(json_field "$reply" 'd["data"]["dropin"]')" == *"MemoryMax=384M"* ]] || fail_test "preview missing override: $reply"
}

test_control_actions_and_peer_check() {
    local test_root
    local reply
    local own_group
    test_root=$(mktemp -d)
    setup_control_root "$test_root"

    reply=$(control_call "$test_root" '{"verb":"backup.start","args":{"what":"files"}}')
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "backup.start failed: $reply"
    assert_contains "$test_root/systemctl.log" '--user start --no-block file-backup.service'
    control_call "$test_root" '{"verb":"backup.stop"}' > /dev/null
    assert_contains "$test_root/systemctl.log" '--user stop --no-block file-backup.service'
    control_call "$test_root" '{"verb":"timer.set","args":{"timer":"file-backup.timer","enabled":false}}' > /dev/null
    assert_contains "$test_root/systemctl.log" '--user disable --now file-backup.timer'
    assert_contains "$test_root/state/events.jsonl" '"category":"schedule-off"'
    reply=$(control_call "$test_root" '{"verb":"notify.test"}')
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "notify.test failed: $reply"
    assert_contains "$test_root/curl.log" 'arg: Filename: notification-test.txt'
    assert_contains "$test_root/state/events.jsonl" '"category":"test"'
    [ "$(grep -c '"ok": true' "$test_root/state/gui/audit.jsonl")" -eq 4 ] || fail_test 'expected 4 audit lines'

    reply=$(control_call "$test_root" '{"verb":"status"}' --peer "0-1234-65534")
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "forbidden" ] || fail_test "nobody was allowed: $reply"
    reply=$(control_call "$test_root" '{"verb":"status"}' --peer "0-1234-notanumber")
    [ "$(json_field "$reply" 'd["error"]["code"]')" = "forbidden" ] || fail_test "bad peer was allowed: $reply"
    own_group=$(id -gn)
    reply=$(BACKUP_SUITE_GUI_GROUP="$own_group" control_call "$test_root" '{"verb":"status"}' --peer "3-1234-$(id -u)")
    [ "$(json_field "$reply" 'd["ok"]')" = "True" ] || fail_test "group member refused: $reply"
    [ "$(json_field "$reply" 'd["data"]["caller"]["uid"]')" = "$(id -u)" ] || fail_test 'caller uid not taken from the peer'
}

test_events_and_progress_files() {
    local test_root
    local output_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    setup_control_root "$test_root"
    sed -i 's/^NOTIFY_FAILURES_ENABLED="1"/NOTIFY_FAILURES_ENABLED="0"/' "$test_root/config/global.conf"
    printf '1|workspace|%s/source|fixed|projects/workspace|.nosync|children\n' "$test_root" > "$test_root/config/file-sources.conf"
    mkdir -p "$test_root/source/project-b" "$test_root/remote"
    printf 'a\n' > "$test_root/source/project-a/a.txt"
    printf 'b\n' > "$test_root/source/project-b/b.txt"
    sed -i "s|^RCLONE_REMOTE_ROOT=.*|RCLONE_REMOTE_ROOT=\"$test_root/remote\"|" "$test_root/config/global.conf"

    PATH="$test_root/bin:$PATH" FAKE_CURL_LOG="$test_root/curl.log" FAKE_SYSTEMCTL_LOG="$test_root/systemctl.log" \
        run_backup "$test_root" > "$output_file" 2>&1 || { cat "$output_file" >&2; fail_test 'backup failed'; }
    assert_contains "$test_root/state/run/progress.env" 'state=finished'
    assert_contains "$test_root/state/run/progress.env" 'projects_total=2'
    assert_contains "$test_root/state/run/progress.env" 'project_index=2'
    assert_contains "$test_root/state/events.jsonl" '"category":"run-finished"'

    # ntfy_publish records an event even when ntfy is off, as valid JSON.
    HOME="$test_root/home" PATH="$test_root/bin:$PATH" FAKE_CURL_LOG="$test_root/curl.log" BACKUP_SUITE_CONFIG_DIR="$test_root/config" \
        bash -c '. "$1/bin/common.sh"; . "$1/bin/notify-lib.sh"; load_global_config
            for i in $(seq 1 3); do ntfy_publish "title \"$i\"" high "x" "line one
line two	tab \\ backslash" "" "" watchdog-stop > /dev/null; done' _ "$ROOT_DIR"
    python3 -c '
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
seqs = [event["seq"] for event in events]
assert seqs == sorted(seqs) and len(set(seqs)) == len(seqs), seqs
last = events[-1]
assert last["severity"] == "error" and last["category"] == "watchdog-stop", last
assert last["title"] == "title \"3\"" and "\\ backslash" in last["message"], last
' "$test_root/state/events.jsonl" || fail_test 'events.jsonl is not valid or ordered'
    [ ! -s "$test_root/curl.log" ] || fail_test 'ntfy was called although disabled'
    reply=$(control_call "$test_root" '{"verb":"events.since","args":{"seq":1}}')
    [ "$(json_field "$reply" 'd["data"]["events"][0]["seq"]')" = "2" ] || fail_test "events.since wrong: $reply"
}

test_gui_broker_installer_guards() {
    local test_root
    local output_file
    test_root=$(mktemp -d)
    output_file="$test_root/output.log"
    "$ROOT_DIR/bin/install-gui-broker.sh" --help > "$output_file"
    assert_contains "$output_file" 'refresh-acl'
    if "$ROOT_DIR/bin/install-gui-broker.sh" --bogus > "$output_file" 2>&1; then
        fail_test 'unknown option accepted'
    fi
    if [ "$(id -u)" -ne 0 ]; then
        if "$ROOT_DIR/bin/install-gui-broker.sh" --templates "$ROOT_DIR/systemd" > "$output_file" 2>&1; then
            fail_test 'non-root install accepted'
        fi
        assert_contains "$output_file" 'Run as root'
    fi
    # Templates render without leftover placeholders.
    for template in backup-suite-control.socket.template backup-suite-control@.service.template; do
        sed -e 's|__INSTALL_DIR__|/opt/x|g' -e 's|__CONFIG_DIR__|/etc/x|g' -e 's|__STATE_DIR__|/var/lib/x|g' \
            -e 's|__CANONICAL_CONFIG_DIR__|/opt/x-src/config|g' -e 's|__GUI_GROUP__|backup-suite-gui|g' \
            "$ROOT_DIR/systemd/$template" > "$test_root/$template"
        if grep -Eq '__[A-Z0-9_]+__' "$test_root/$template"; then
            fail_test "placeholder left in $template"
        fi
    done
    assert_contains "$test_root/backup-suite-control.socket.template" 'SocketMode=0660'
    assert_contains "$test_root/backup-suite-control.socket.template" 'ExecStartPost=/opt/x/bin/install-gui-broker.sh --refresh-acl'
    assert_contains "$test_root/backup-suite-control@.service.template" 'ExecStart=/opt/x/bin/backup-control.sh --peer %i'
}

test_gui_node_suite() {
    # The GUI's own tests (gui/test/*.test.js): guard, bundle, events, control
    # client, server end to end and colour contrast. They need Node >= 18.
    local node_bin=""
    local candidate
    for candidate in "${BACKUP_SUITE_GUI_NODE:-}" /usr/bin/node /usr/local/bin/node "$(command -v node 2>/dev/null || true)"; do
        [ -n "$candidate" ] && [ -x "$candidate" ] || continue
        if [ "$("$candidate" -e 'process.stdout.write(process.versions.node.split(".")[0])')" -ge 18 ]; then
            node_bin="$candidate"
            break
        fi
    done
    if [ -z "$node_bin" ]; then
        echo "Node.js 18 or newer not found; skipping the GUI tests."
        return 0
    fi
    local log_dir
    log_dir=$(mktemp -d)
    (cd "$ROOT_DIR/gui" && "$node_bin" --test test/*.test.js) > "$log_dir/gui-tests.log" 2>&1 || {
        grep -E -A12 '^not ok' "$log_dir/gui-tests.log" | head -60 >&2
        fail_test 'GUI node tests failed'
    }
    # production-deploy.sh runs this suite under sudo, where the control script
    # would read /etc/backup-suite unless the fixture pins its own config. Run
    # once more as a fake root so that is caught without sudo.
    [ "$(id -u)" -eq 0 ] && return 0
    mkdir -p "$log_dir/fake-root-bin"
    ln -s "$ROOT_DIR/tests/fixtures/fake-id.sh" "$log_dir/fake-root-bin/id"
    (cd "$ROOT_DIR/gui" && PATH="$log_dir/fake-root-bin:$PATH" "$node_bin" --test test/*.test.js) > "$log_dir/gui-tests-root.log" 2>&1 || {
        grep -E -A12 '^not ok' "$log_dir/gui-tests-root.log" | head -60 >&2
        fail_test 'GUI node tests failed when run as root'
    }
}

if [ "${1:-}" = "--single" ]; then
    shift
    "$@"
    exit $?
fi

chmod 755 "$ROOT_DIR/tests/fixtures/fake-rclone.sh" "$ROOT_DIR/tests/fixtures/fake-curl.sh" "$ROOT_DIR/tests/fixtures/fake-systemctl.sh" "$ROOT_DIR/tests/fixtures/fake-id.sh"

run_test 'symlink round-trip restore' test_symlink_round_trip
run_test 'safe link migration gate and restore' test_link_migration_gate_and_restore
run_test 'changing-file retry and bounded skip' test_changing_file_policy
run_test 'per-project records and changed files' test_project_records_and_changes
run_test 'project isolation and no delete on error' test_project_isolation_and_no_delete_on_error
run_test 'overlap prevention' test_overlap_prevention
run_test 'explicit migration project filter' test_explicit_project_filter
run_test 'durable failure history and ntfy correlation' test_durable_failure_history
run_test 'global AgentW cache policy retains canonical metadata' test_global_agentw_cache_policy
run_test 'resource unit generation and link flags' test_resource_unit_and_link_flags
run_test 'crypto wallet durable/volatile policy' test_crypto_wallet_policy
run_test 'production migration runner safety gates' test_production_migration_runner_guards
run_test 'resource profiles and systemd drop-in' test_profiles_and_dropin
run_test 'profile drives rclone tuning flags' test_profile_drives_rclone_flags
run_test 'recently modified files are deferred and tracked' test_active_file_deferral
run_test 'ntfy failure message explains the cause' test_failure_notification_description
run_test 'watchdog contains a memory surge' test_watchdog_contains_memory_surge
run_test 'watchdog stops a backup before OOM' test_watchdog_stops_before_oom
run_test 'watchdog force-kills a hung stop' test_watchdog_force_kills_hung_stop
run_test 'watchdog pauses for server memory pressure' test_watchdog_pauses_for_server_pressure
run_test 'watchdog ignores a short pressure spike' test_watchdog_short_pressure_spike_never_pauses
run_test 'watchdog replays the 19:39 stall without a shortage' test_watchdog_incident_stall_without_shortage
run_test 'watchdog never pauses a tiny backup' test_watchdog_tiny_backup_not_paused
run_test 'watchdog thaws before stop and retries after pressure clears' test_watchdog_thaws_before_stop_and_retries
run_test 'watchdog never kills the next run' test_watchdog_never_kills_the_next_run
run_test 'watchdog pushes each notice once per episode' test_watchdog_episode_reports_once
run_test 'watchdog stops for critical server memory' test_watchdog_stops_for_critical_server_memory
run_test 'watchdog unit and deploy safety guards' test_watchdog_unit_and_deploy_guards
run_test 'help and option errors never touch systemd' test_help_never_touches_systemd
run_test 'auto-scaled limits and per-profile overrides' test_profile_auto_limits_and_overrides
run_test 'adaptive profile commands' test_adaptive_profile_cli
run_test 'profiles always cap swap' test_profile_requires_swap_cap
run_test 'watchdog steps the profile down and back up' test_watchdog_adaptive_steps_down_and_up
run_test 'adaptive level carries into the next run' test_adaptive_level_carries_into_next_run
run_test 'control script read verbs and refusals' test_control_read_verbs
run_test 'control script never returns secrets' test_control_never_returns_secrets
run_test 'control script config.set safety' test_control_config_set
run_test 'backup jobs: add, edit, enable, remove, run' test_control_jobs
run_test 'job run and per-job patterns in file-backup' test_job_run_and_job_patterns
run_test 'exclude a changing file per project or per job' test_control_job_exclude
run_test 'per-project job excludes in file-backup' test_job_project_excludes_in_backup
run_test 'every global setting shown, schedule applied' test_control_settings_catalog
run_test 'destinations, folder picker and remote jobs' test_control_destinations
run_test 'a job on its own remote' test_job_on_its_own_remote
run_test 'control script profile verbs match the CLI' test_control_profile_matches_cli
run_test 'control script actions, audit and peer check' test_control_actions_and_peer_check
run_test 'events file and run progress' test_events_and_progress_files
run_test 'GUI broker installer guards and templates' test_gui_broker_installer_guards
run_test 'GUI server, events, bundle and contrast (node)' test_gui_node_suite

echo "Tests: passed=$PASS_COUNT failed=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
