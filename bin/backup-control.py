#!/usr/bin/env python3
"""Backup Suite control verbs: one JSON request on stdin, one JSON reply on stdout.

Started only by backup-control.sh, which resolves Backup Suite's configuration
and passes it in BSC_* environment variables. Uses the Python standard library
only. Every verb is listed in VERBS; anything else is refused without changes.
"""

import datetime
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

MAX_REQUEST_BYTES = 64 * 1024
READ_TIMEOUT = 10
CHANGE_TIMEOUT = 60
MAX_LOG_LINES = 2000
MAX_REPLY_TEXT = 1024 * 1024
MAX_HISTORY_ROWS = 500
AUDIT_KEEP_LINES = 2000
EVENTS_KEEP_LINES = 1000
CONFIG_BACKUPS_KEEP = 50

ENV = os.environ
MODE = ENV.get("BSC_MODE", "user")
SCOPE = ENV.get("BSC_SYSTEMD_SCOPE", "user")
BIN_DIR = ENV.get("BSC_BIN_DIR", os.path.dirname(os.path.abspath(__file__)))
GLOBAL_CONFIG_FILE = ENV.get("BSC_GLOBAL_CONFIG_FILE", "")
STATE_DIR = ENV.get("BSC_STATE_DIR", "")
SOURCES_FILE = ENV.get("BSC_SOURCES_FILE", "")
EXCLUDE_FILENAME = ENV.get("BSC_EXCLUDE_FILENAME", ".backup-excludes")
CALLER_UID = ENV.get("BSC_CALLER_UID", str(os.getuid()))
CALLER_LOGIN = ENV.get("BSC_CALLER_LOGIN", "")
HOSTNAME = ENV.get("BSC_HOSTNAME", "")
SYSTEMCTL = ENV.get("BACKUP_SUITE_SYSTEMCTL", "systemctl")
JOURNALCTL = ENV.get("BACKUP_SUITE_JOURNALCTL", "journalctl")
PROC_DIR = ENV.get("BACKUP_SUITE_PROC_DIR", "/proc")

SERVICES = ["file-backup.service", "database-backup.service", "database-size-check.service",
            "backup-suite-watchdog@file-backup.service"]
TIMERS = ["file-backup.timer", "database-backup.timer", "database-size-check.timer"]
SERVICE_PROPERTIES = ["Id", "LoadState", "ActiveState", "SubState", "Result", "UnitFileState",
                      "ExecMainStartTimestamp", "ExecMainExitTimestamp", "ExecMainStatus",
                      "ActiveEnterTimestamp", "InactiveEnterTimestamp", "MainPID"]
TIMER_PROPERTIES = ["Id", "LoadState", "ActiveState", "SubState", "UnitFileState",
                    "LastTriggerUSec", "NextElapseUSecRealtime", "Unit"]
JOURNAL_SOURCES = {
    "file-backup": ["-u", "file-backup.service"],
    "database-backup": ["-u", "database-backup.service"],
    "database-size-check": ["-u", "database-size-check.service"],
    "watchdog": ["-t", "backup-watchdog"],
    "control": ["-t", "backup-suite-control"],
}
PROFILES = ["slow", "moderate", "fast"]
PROFILE_RANK = {"slow": 0, "moderate": 1, "fast": 2}
OVERRIDE_KEYS = ["CPU_QUOTA", "CPU_WEIGHT", "IO_WEIGHT", "NICE", "IO_SCHEDULING_CLASS",
                 "MEMORY_HIGH", "MEMORY_MAX", "MEMORY_SWAP_MAX", "TASKS_MAX", "RCLONE_TRANSFERS",
                 "RCLONE_CHECKERS", "RCLONE_BUFFER_SIZE", "RCLONE_TPSLIMIT", "RCLONE_BWLIMIT"]

SIZE_RE = r"[0-9]+[KMGT]?"
INT_RE = r"[0-9]+"
OVERRIDE_VALUE_RE = {
    "CPU_QUOTA": r"[0-9]{1,4}%",
    "CPU_WEIGHT": INT_RE,
    "IO_WEIGHT": INT_RE,
    "NICE": r"-?[0-9]{1,2}",
    "IO_SCHEDULING_CLASS": r"idle|best-effort|realtime",
    "MEMORY_HIGH": SIZE_RE,
    "MEMORY_MAX": SIZE_RE,
    "MEMORY_SWAP_MAX": SIZE_RE,
    "TASKS_MAX": INT_RE,
    "RCLONE_TRANSFERS": INT_RE,
    "RCLONE_CHECKERS": INT_RE,
    "RCLONE_BUFFER_SIZE": SIZE_RE,
    "RCLONE_TPSLIMIT": INT_RE,
    "RCLONE_BWLIMIT": r"(|off|[0-9]+(\.[0-9]+)?[KMGT]?)",
}


def int_range(low, high):
    return ("int", low, high)


# global.conf keys the GUI may change: (kind, ...) plus a one-line explanation.
CONFIG_KEYS = {
    "FILE_BACKUP_RUNTIME_MAX_SEC": (("regex", r"[0-9]+(s|min|h|d)?"), "Longest a file backup run may take before systemd stops it (e.g. 6h)."),
    "FILE_RETENTION_DAYS": (("regex", r"[0-9]+(d|h)?"), "How long replaced and deleted file versions stay in the remote archive folder (e.g. 21d)."),
    "FILE_ACTIVE_TRACKING_ENABLED": (("bool",), "Skip files modified moments before the sync and retry them next run."),
    "FILE_ACTIVE_WINDOW_SECONDS": (int_range(0, 3600), "Files modified within this many seconds count as still being written."),
    "FILE_ACTIVE_MAX_DEFERRALS": (int_range(1, 1000), "Warn after a file has been skipped this many runs in a row."),
    "WATCHDOG_INTERVAL_SECONDS": (int_range(1, 60), "How often the watchdog samples the running backup."),
    "WATCHDOG_CONTAIN_PERCENT": (int_range(10, 99), "Backup memory (percent of MemoryMax) at which the watchdog reclaims cache and halves CPU."),
    "WATCHDOG_CONTAIN_RELEASE_PERCENT": (int_range(5, 98), "Containment is released once memory stays below this percent."),
    "WATCHDOG_KILL_PERCENT": (int_range(20, 99), "Non-reclaimable memory (percent of MemoryMax) at which the backup is stopped before an OOM kill."),
    "WATCHDOG_KILL_SAMPLES": (int_range(1, 20), "Consecutive samples above the stop threshold before stopping."),
    "WATCHDOG_SWAP_CONTAIN_PERCENT": (int_range(10, 99), "Backup swap (percent of its limit) at which containment starts."),
    "WATCHDOG_SWAP_KILL_PERCENT": (int_range(20, 100), "Backup swap (percent of its limit) at which the backup is stopped."),
    "WATCHDOG_SYSTEM_MIN_AVAILABLE_PERCENT": (int_range(2, 50), "Pause the backup when server RAM available falls below this percent."),
    "WATCHDOG_SYSTEM_CRITICAL_AVAILABLE_PERCENT": (int_range(1, 40), "Stop the backup when server RAM available falls below this percent."),
    "WATCHDOG_SYSTEM_PSI_FULL_LIMIT": (int_range(1, 100), "Pause the backup when memory pressure (PSI full avg10) reaches this value."),
    "WATCHDOG_FREEZE_MAX_SECONDS": (int_range(30, 7200), "Stop a paused backup after this many seconds (it is retried once the shortage clears)."),
    "WATCHDOG_PSI_PAUSE_AVAILABLE_PERCENT": (int_range(2, 90), "A memory stall pauses the backup only while server RAM available is below this percent (a stall without a shortage never does)."),
    "WATCHDOG_PAUSE_MIN_FOOTPRINT_MB": (int_range(0, 65536), "Never pause a backup holding less than this much non-reclaimable memory plus swap (MiB): pausing it would free nothing."),
    "WATCHDOG_PRESSURE_SUSTAIN_SECONDS": (int_range(0, 3600), "Server pressure must last this long before a pause or step-down (a short spike never counts)."),
    "WATCHDOG_RETRY_WAIT_SECONDS": (int_range(0, 14400), "After stopping a long-paused backup, wait up to this long for the shortage to clear and retry once (0: wait for the next timer run)."),
    "WATCHDOG_RETRY_CLEAR_SECONDS": (int_range(10, 3600), "Server memory must be normal this long before that retry starts."),
    "WATCHDOG_NOTIFY_PROFILE_STEPS": (("bool",), "Push adaptive step-down/step-up notices too (otherwise they only appear in Activity)."),
    "WATCHDOG_KILL_GRACE_SECONDS": (int_range(5, 600), "Seconds a stopping backup gets before every process is force-killed."),
    "WATCHDOG_TASKS_WARN_PERCENT": (int_range(10, 100), "Warn when the backup uses this percent of its task limit."),
    "WATCHDOG_ADAPTIVE_STEP_DOWN_AVAILABLE_PERCENT": (int_range(2, 90), "Adaptive mode: step down when server RAM available falls below this percent."),
    "WATCHDOG_ADAPTIVE_STEP_DOWN_PSI_FULL": (int_range(1, 100), "Adaptive mode: step down when memory pressure reaches this value."),
    "WATCHDOG_ADAPTIVE_STEP_UP_AVAILABLE_PERCENT": (int_range(5, 95), "Adaptive mode: step up only while server RAM available stays at or above this percent."),
    "WATCHDOG_ADAPTIVE_STEP_UP_SECONDS": (int_range(30, 7200), "Adaptive mode: seconds of normal conditions before stepping up."),
    "WATCHDOG_ADAPTIVE_COOLDOWN_SECONDS": (int_range(0, 3600), "Adaptive mode: minimum seconds between two level changes."),
    "NOTIFY_FAILURES_ENABLED": (("bool",), "The ntfy channel's switch: send notifications through ntfy."),
    "NOTIFY_NTFY_TOPIC_URL": (("url",), "The ntfy topic URL that receives the notifications."),
    "NOTIFY_NTFY_TOKEN": (("secret",), "Access token for a protected ntfy topic (write-only)."),
    "NOTIFY_NTFY_PRIORITY": (("choice", ["min", "low", "default", "high", "urgent"]), "ntfy priority of failure notifications."),
    "NOTIFY_NTFY_TITLE_PREFIX": (("text", 60), "Text at the start of every notification title."),
    "NOTIFY_NTFY_ATTACH_DETAILS": (("bool",), "Attach the full log to each notification."),
    "NOTIFY_NTFY_MESSAGE_MAX_BYTES": (int_range(512, 4000), "Longest readable message before it is shortened (ntfy turns bodies over 4096 bytes into attachments)."),
}
SECRET_KEYS = {"NOTIFY_NTFY_TOKEN"}
MASKED_KEYS = {"NOTIFY_NTFY_TOPIC_URL"}
CONFIG_DEFAULTS = {
    "FILE_BACKUP_RUNTIME_MAX_SEC": "6h", "FILE_RETENTION_DAYS": "21d", "FILE_ACTIVE_TRACKING_ENABLED": "1",
    "FILE_ACTIVE_WINDOW_SECONDS": "120", "FILE_ACTIVE_MAX_DEFERRALS": "12", "WATCHDOG_INTERVAL_SECONDS": "5",
    "WATCHDOG_CONTAIN_PERCENT": "80", "WATCHDOG_CONTAIN_RELEASE_PERCENT": "60", "WATCHDOG_KILL_PERCENT": "90",
    "WATCHDOG_KILL_SAMPLES": "2", "WATCHDOG_SWAP_CONTAIN_PERCENT": "80", "WATCHDOG_SWAP_KILL_PERCENT": "95",
    "WATCHDOG_SYSTEM_MIN_AVAILABLE_PERCENT": "10", "WATCHDOG_SYSTEM_CRITICAL_AVAILABLE_PERCENT": "4",
    "WATCHDOG_SYSTEM_PSI_FULL_LIMIT": "20", "WATCHDOG_FREEZE_MAX_SECONDS": "900",
    "WATCHDOG_PSI_PAUSE_AVAILABLE_PERCENT": "20", "WATCHDOG_PAUSE_MIN_FOOTPRINT_MB": "64",
    "WATCHDOG_PRESSURE_SUSTAIN_SECONDS": "30", "WATCHDOG_RETRY_WAIT_SECONDS": "1800", "WATCHDOG_RETRY_CLEAR_SECONDS": "60",
    "WATCHDOG_NOTIFY_PROFILE_STEPS": "0", "WATCHDOG_KILL_GRACE_SECONDS": "30",
    "WATCHDOG_TASKS_WARN_PERCENT": "90", "WATCHDOG_ADAPTIVE_STEP_DOWN_AVAILABLE_PERCENT": "20",
    "WATCHDOG_ADAPTIVE_STEP_DOWN_PSI_FULL": "10", "WATCHDOG_ADAPTIVE_STEP_UP_AVAILABLE_PERCENT": "30",
    "WATCHDOG_ADAPTIVE_STEP_UP_SECONDS": "300", "WATCHDOG_ADAPTIVE_COOLDOWN_SECONDS": "120",
    "NOTIFY_FAILURES_ENABLED": "0", "NOTIFY_NTFY_TOPIC_URL": "", "NOTIFY_NTFY_TOKEN": "",
    "NOTIFY_NTFY_PRIORITY": "high", "NOTIFY_NTFY_TITLE_PREFIX": "Backup Suite", "NOTIFY_NTFY_ATTACH_DETAILS": "1",
    "NOTIFY_NTFY_MESSAGE_MAX_BYTES": "3500",
}

# Every other global.conf key the GUI shows. These are editable; their checks are in
# validate_config_value. Schedule keys are applied to the timers at once
# (apply-schedule.sh); the rest apply from the next run.
CONFIG_KEYS.update({
    "FILE_BACKUP_ONCALENDAR": (("calendar",), "When file backups run (systemd OnCalendar, e.g. *:0/30 for every 30 minutes, hourly, daily, Mon..Fri 22:00)."),
    "FILE_BACKUP_RANDOMIZED_DELAY_SEC": (("regex", r"[0-9]+(s|min|m|h)?"), "Random delay added to each scheduled start, so runs do not all begin on the hour (e.g. 15m)."),
    "DB_BACKUP_ONCALENDAR": (("calendar",), "When database backups run (systemd OnCalendar, e.g. daily or *-*-* 03:30)."),
    "DB_MONITOR_ONCALENDAR": (("calendar",), "When the database size check runs (systemd OnCalendar)."),
    "RCLONE_REMOTE_ROOT": (("remote",), "The rclone remote and folder every backup goes under (e.g. gdrive,root_folder_id=...:server-backups). Changing it starts a new copy elsewhere; nothing moves."),
    "INCLUDE_HOSTNAME_IN_REMOTE": (("bool",), "Put this server's name under the remote root, so several servers can share one remote. Changing it starts a new copy elsewhere."),
    "REMOTE_HOSTNAME": (("regex", r"([A-Za-z0-9][A-Za-z0-9.-]{0,62})?"), "Name used for this server in the remote (empty: the real hostname)."),
    "FILE_DEFAULT_DESTINATION_ROOT": (("relpath",), "Folder under the remote root for jobs with destination mode default-root."),
    "FILE_ARCHIVE_FOLDER_NAME": (("filename",), "Folder under the remote root where replaced and deleted file versions are kept."),
    "FILE_ARCHIVE_SUFFIX": (("regex", r"[A-Za-z0-9._-]{0,20}"), "Suffix added to archived versions by older Backup Suite versions."),
    "FILE_SYNC_STOP_FILE": (("filename",), "Default stop file: a job or project folder holding it is skipped (a job can name its own)."),
    "FILE_PROJECT_EXCLUDE_FILENAME": (("filename",), "Name of the per-folder exclude files in a source (rclone filter patterns, one per line)."),
    "FILE_VOLATILE_FILENAME": (("filename",), "Name of the per-folder volatile files: patterns allowed to change during a sync."),
    "FILE_GLOBAL_EXCLUDE_PATTERNS": (("patterns",), "Patterns never uploaded by any job, separated by |."),
    "FILE_GLOBAL_VOLATILE_PATTERNS": (("patterns",), "Patterns that may change during a sync in every job, separated by |."),
    "FILE_PROCESS_CHECK_ENABLED": (("bool",), "Skip a scheduled run while a listed process is running (for example an editor session)."),
    "FILE_PROCESS_CHECK_USER_ONLY": (("bool",), "Only look at processes of the account the backup runs as."),
    "FILE_PROCESS_CHECK_PATTERNS": (("regex", r"[A-Za-z0-9 ._/|,:-]{0,200}"), "Process command-line patterns (pgrep -f) that skip a run, separated by , or |."),
    "FILE_STABILITY_INTERVAL_SECONDS": (int_range(0, 600), "Seconds between the two file snapshots that find files changing during a failed sync."),
    "FILE_CHANGED_DETAIL_LIMIT": (int_range(0, 1000), "How many changing paths each project lists in the log."),
    "FILE_RCLONE_TRANSFERS": (int_range(1, 64), "Parallel uploads (custom profile only; the other profiles set their own)."),
    "FILE_RCLONE_CHECKERS": (int_range(1, 128), "Parallel checks (custom profile only)."),
    "FILE_RCLONE_BUFFER_SIZE": (("regex", r"[0-9]+[KMG]?"), "Buffer per upload (custom profile only), e.g. 16M."),
    "FILE_RCLONE_TPSLIMIT": (int_range(0, 1000), "API calls per second (custom profile only; 0 = no limit)."),
    "FILE_RCLONE_BWLIMIT": (("regex", r"([0-9]+[KMG]?)?"), "Bandwidth limit (custom profile only), e.g. 4M; empty = unlimited."),
    "BACKUP_SUITE_LOG_MAX_BYTES": (int_range(1048576, 1073741824), "Size at which the durable run log is rotated."),
    "BACKUP_SUITE_LOG_KEEP_FILES": (int_range(1, 200), "Rotated run logs kept."),
    "NOTIFY_JOURNAL_LINES": (int_range(10, 2000), "Journal lines included in a failure record."),
    "NOTIFY_DURABLE_LOG_LINES": (int_range(10, 5000), "Run-log lines included in a failure record."),
    "NOTIFY_FAILURE_LOG_KEEP_FILES": (int_range(1, 1000), "Failure records kept."),
    "DB_REMOTE_DESTINATION_ROOT": (("relpath",), "Folder under the remote root for database dumps."),
    "DB_RETENTION_DAYS": (int_range(1, 3650), "Days database dumps are kept on the remote."),
    "DB_RCLONE_TRANSFERS": (int_range(1, 64), "Parallel uploads for database dumps."),
    "DB_RCLONE_CHECKERS": (int_range(1, 128), "Parallel checks for database dumps."),
    "DB_SKIP_UNCHANGED_BACKUPS": (("bool",), "Do not upload a dump identical to the previous one."),
    "DB_KEEP_LOCAL_AFTER_UPLOAD": (("bool",), "Keep the local dump after it was uploaded."),
    "DB_MONITOR_THRESHOLD_MB": (int_range(1, 10485760), "Warn when a database grows past this size (MB)."),
})
CONFIG_DEFAULTS.update({
    "FILE_BACKUP_ONCALENDAR": "*:0/30", "FILE_BACKUP_RANDOMIZED_DELAY_SEC": "15m", "DB_BACKUP_ONCALENDAR": "daily",
    "DB_MONITOR_ONCALENDAR": "daily", "RCLONE_REMOTE_ROOT": "", "INCLUDE_HOSTNAME_IN_REMOTE": "1", "REMOTE_HOSTNAME": "",
    "FILE_DEFAULT_DESTINATION_ROOT": "files", "FILE_ARCHIVE_FOLDER_NAME": "deleted_files", "FILE_ARCHIVE_SUFFIX": "_old",
    "FILE_SYNC_STOP_FILE": ".nosync", "FILE_PROJECT_EXCLUDE_FILENAME": ".backup-excludes", "FILE_VOLATILE_FILENAME": ".backup-volatile",
    "FILE_GLOBAL_EXCLUDE_PATTERNS": "", "FILE_GLOBAL_VOLATILE_PATTERNS": "", "FILE_PROCESS_CHECK_ENABLED": "1",
    "FILE_PROCESS_CHECK_USER_ONLY": "1", "FILE_PROCESS_CHECK_PATTERNS": "vscode-server", "FILE_STABILITY_INTERVAL_SECONDS": "10",
    "FILE_CHANGED_DETAIL_LIMIT": "20", "FILE_RCLONE_TRANSFERS": "2", "FILE_RCLONE_CHECKERS": "4", "FILE_RCLONE_BUFFER_SIZE": "16M",
    "FILE_RCLONE_TPSLIMIT": "10", "FILE_RCLONE_BWLIMIT": "", "BACKUP_SUITE_LOG_MAX_BYTES": "10485760", "BACKUP_SUITE_LOG_KEEP_FILES": "10",
    "NOTIFY_JOURNAL_LINES": "40", "NOTIFY_DURABLE_LOG_LINES": "120", "NOTIFY_FAILURE_LOG_KEEP_FILES": "100",
    "DB_REMOTE_DESTINATION_ROOT": "databases", "DB_RETENTION_DAYS": "14", "DB_RCLONE_TRANSFERS": "4", "DB_RCLONE_CHECKERS": "8",
    "DB_SKIP_UNCHANGED_BACKUPS": "1", "DB_KEEP_LOCAL_AFTER_UPLOAD": "1", "DB_MONITOR_THRESHOLD_MB": "512",
})
SCHEDULE_KEYS = {"FILE_BACKUP_ONCALENDAR", "FILE_BACKUP_RANDOMIZED_DELAY_SEC", "FILE_BACKUP_RUNTIME_MAX_SEC",
                 "DB_BACKUP_ONCALENDAR", "DB_MONITOR_ONCALENDAR"}
# Settings that move every job's destination: the save is marked as such.
RELOCATING_KEYS = {"RCLONE_REMOTE_ROOT", "INCLUDE_HOSTNAME_IN_REMOTE", "REMOTE_HOSTNAME", "FILE_DEFAULT_DESTINATION_ROOT"}

CONFIG_GROUPS = [
    ("schedule", "Schedule", ["FILE_BACKUP_ONCALENDAR", "FILE_BACKUP_RANDOMIZED_DELAY_SEC", "FILE_BACKUP_RUNTIME_MAX_SEC",
                              "DB_BACKUP_ONCALENDAR", "DB_MONITOR_ONCALENDAR"]),
    ("remote", "Remote and previous versions", ["RCLONE_REMOTE_ROOT", "INCLUDE_HOSTNAME_IN_REMOTE", "REMOTE_HOSTNAME",
                                                "FILE_DEFAULT_DESTINATION_ROOT", "FILE_ARCHIVE_FOLDER_NAME", "FILE_RETENTION_DAYS", "FILE_ARCHIVE_SUFFIX"]),
    ("files", "What every file job skips", ["FILE_SYNC_STOP_FILE", "FILE_PROJECT_EXCLUDE_FILENAME", "FILE_VOLATILE_FILENAME",
                                            "FILE_GLOBAL_EXCLUDE_PATTERNS", "FILE_GLOBAL_VOLATILE_PATTERNS"]),
    ("changing", "Changing files", ["FILE_ACTIVE_TRACKING_ENABLED", "FILE_ACTIVE_WINDOW_SECONDS", "FILE_ACTIVE_MAX_DEFERRALS",
                                    "FILE_STABILITY_INTERVAL_SECONDS", "FILE_CHANGED_DETAIL_LIMIT"]),
    ("busy", "Skip runs while busy", ["FILE_PROCESS_CHECK_ENABLED", "FILE_PROCESS_CHECK_USER_ONLY", "FILE_PROCESS_CHECK_PATTERNS"]),
    ("profile", "Resource profile", ["FILE_BACKUP_PROFILE", "FILE_BACKUP_PROFILE_MODE", "FILE_BACKUP_PROFILE_FLOOR", "FILE_PROFILE_LIMITS_MODE"]),
    ("custom", "rclone tuning (custom profile)", ["FILE_RCLONE_TRANSFERS", "FILE_RCLONE_CHECKERS", "FILE_RCLONE_BUFFER_SIZE",
                                                  "FILE_RCLONE_TPSLIMIT", "FILE_RCLONE_BWLIMIT", "FILE_RCLONE_EXTRA_FLAGS"]),
    ("database", "Database backups", ["DB_REMOTE_DESTINATION_ROOT", "DB_RETENTION_DAYS", "DB_RCLONE_TRANSFERS", "DB_RCLONE_CHECKERS",
                                      "DB_SKIP_UNCHANGED_BACKUPS", "DB_KEEP_LOCAL_AFTER_UPLOAD", "DB_MONITOR_THRESHOLD_MB", "DB_RCLONE_EXTRA_FLAGS"]),
    ("watchdog", "Watchdog", [key for key in CONFIG_KEYS if key.startswith("WATCHDOG_")]),
    ("ntfy", "Notifications: ntfy channel", [key for key in CONFIG_KEYS if key.startswith("NOTIFY_NTFY_") or key == "NOTIFY_FAILURES_ENABLED"]),
    ("logs", "Logs and failure records", ["BACKUP_SUITE_LOG_MAX_BYTES", "BACKUP_SUITE_LOG_KEEP_FILES", "NOTIFY_JOURNAL_LINES",
                                          "NOTIFY_DURABLE_LOG_LINES", "NOTIFY_FAILURE_LOG_KEEP_FILES"]),
    ("install", "Installation (read-only)", ["INSTALL_MODE", "FILE_JOB_SOURCE_ROOTS", "INSTALL_SYSTEMD_UNITS", "ENABLE_TIMERS_AFTER_INSTALL"]
     + ["%s_%s" % (prefix, name) for prefix in ("SYSTEM", "USER") for name in
        ("INSTALL_DIR", "CANONICAL_SOURCE_DIR", "CONFIG_DIR", "STATE_DIR", "DB_LOCAL_OUTPUT_DIR", "RCLONE_CONFIG_PATH", "RCLONE_BIN",
         "FILE_SOURCE_CONFIG_PATH", "DATABASE_BACKUP_CONFIG_PATH", "MYSQL_PROFILE_DIR", "SYSTEMD_UNIT_DIR")]),
]
# Shown but never written by the GUI: programs and paths the backup runs or reads as
# root (a change could make root run anything), and what the deploy decides.
READONLY_REASONS = {
    "FILE_RCLONE_EXTRA_FLAGS": "Extra rclone flags run as root (rclone can run commands, e.g. --password-command), so they are changed in global.conf on the server only.",
    "DB_RCLONE_EXTRA_FLAGS": "Extra rclone flags run as root, so they are changed in global.conf on the server only.",
    "FILE_JOB_SOURCE_ROOTS": "The folders a backup job may back up. Only the server's administrator sets this, in global.conf.",
}
INSTALL_REASON = "Installation path, program or install option: changed in global.conf on the server, then re-deployed."
PROFILE_REASON = "Set in Admin → Profiles & limits."
CONFIG_KEY_ORDER = [key for _, _, keys in CONFIG_GROUPS for key in keys]
DEFAULT_JOB_SOURCE_ROOTS = "/home /var/www /srv /opt"


def config_readonly_reason(key):
    if key in READONLY_REASONS:
        return READONLY_REASONS[key]
    if key.startswith(("FILE_BACKUP_PROFILE", "FILE_PROFILE_")):
        return PROFILE_REASON
    if key not in CONFIG_KEYS:
        return INSTALL_REASON
    return ""

FAILURE_NAME_RE = re.compile(r"^[0-9TZ]+-[A-Za-z0-9._-]+\.log$")
RUN_START_RE = re.compile(r"^File backup started at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) UTC")


class ControlError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def invalid(message):
    raise ControlError("invalid_request", message)


# --------------------------------------------------------------------------- helpers

def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def state_path(*parts):
    return os.path.join(STATE_DIR, *parts)


def gui_dir():
    path = state_path("gui")
    os.makedirs(path, mode=0o750, exist_ok=True)
    return path


def read_text(path, limit=MAX_REPLY_TEXT):
    """Reads at most `limit` bytes from the end of a file. Returns (text, truncated)."""
    try:
        size = os.path.getsize(path)
        with open(path, "rb") as handle:
            if size > limit:
                handle.seek(size - limit)
                data = handle.read(limit)
                data = data.split(b"\n", 1)[-1]
                return data.decode("utf-8", "replace"), True
            return handle.read().decode("utf-8", "replace"), False
    except OSError:
        return "", False


def read_key_values(path):
    values = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if "=" in line and not line.startswith("#"):
                    key, value = line.split("=", 1)
                    values[key.strip()] = value
    except OSError:
        return None
    return values


def run(command, timeout, input_text=None):
    try:
        result = subprocess.run(command, input=input_text, capture_output=True, text=True,
                                timeout=timeout, errors="replace")
    except subprocess.TimeoutExpired:
        raise ControlError("timeout", "Timed out after %ss: %s" % (timeout, " ".join(command[:3])))
    except OSError as error:
        raise ControlError("unavailable", "Could not run %s: %s" % (command[0], error))
    return result.returncode, result.stdout, result.stderr


def systemctl(*arguments, timeout=READ_TIMEOUT):
    command = [SYSTEMCTL]
    if SCOPE == "user":
        command.append("--user")
    command.extend(arguments)
    return run(command, timeout)


def bin_script(name):
    return os.path.join(BIN_DIR, name)


def file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_global_config(path):
    values = {}
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = re.match(r'^([A-Z][A-Z0-9_]*)=(.*)$', line.rstrip("\n"))
                if not match:
                    continue
                value = match.group(2).strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                values[match.group(1)] = value
    except OSError:
        pass
    return values


def mask_url(value):
    if not value:
        return ""
    match = re.match(r"^(https?://[^/]+/)(.*)$", value)
    if not match:
        return "[set]"
    topic = match.group(2)
    if len(topic) <= 4:
        return match.group(1) + "…"
    return match.group(1) + topic[:2] + "…" + topic[-2:]


def append_bounded_jsonl(path, record, keep):
    lock_path = path + ".lock"
    with open(lock_path, "a") as lock_handle:
        fcntl.flock(lock_handle, fcntl.LOCK_EX)
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False) + "\n")
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                lines = handle.readlines()
            if len(lines) > keep + 100:
                with open(path, "w", encoding="utf-8") as handle:
                    handle.writelines(lines[-keep:])
        except OSError:
            pass


def record_event(severity, category, title, message, unit=""):
    """Same format and sequence file as record_backup_event in notify-lib.sh."""
    if not STATE_DIR:
        return
    os.makedirs(STATE_DIR, exist_ok=True)
    events_file = state_path("events.jsonl")
    sequence_file = state_path("events.seq")
    with open(state_path("events.lock"), "a") as lock_handle:
        fcntl.flock(lock_handle, fcntl.LOCK_EX)
        try:
            with open(sequence_file, "r") as handle:
                sequence = int(handle.read().strip() or "0")
        except (OSError, ValueError):
            sequence = 0
        sequence += 1
        with open(sequence_file, "w") as handle:
            handle.write("%d\n" % sequence)
        record = {"seq": sequence, "id": "evt-%d-%d" % (sequence, int(time.time())), "created_at": now_iso(),
                  "severity": severity, "category": category, "title": title, "message": message[:4000], "unit": unit}
        with open(events_file, "a", encoding="utf-8") as handle:
            handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
        try:
            with open(events_file, "r", encoding="utf-8", errors="replace") as handle:
                lines = handle.readlines()
            if len(lines) > EVENTS_KEEP_LINES + 100:
                with open(events_file, "w", encoding="utf-8") as handle:
                    handle.writelines(lines[-EVENTS_KEEP_LINES:])
        except OSError:
            pass


def audit(request, verb, args, ok, summary):
    safe_args = {}
    for key, value in (args or {}).items():
        if key == "changes" and isinstance(value, dict):
            safe_args[key] = {k: ("[set]" if k in SECRET_KEYS and v else v) for k, v in value.items()}
        else:
            safe_args[key] = value
    record = {"at": now_iso(), "mode": MODE, "uid": CALLER_UID, "login": CALLER_LOGIN,
              "session": str(request.get("session", ""))[:64], "verb": verb, "args": safe_args,
              "ok": ok, "result": summary[:500]}
    try:
        append_bounded_jsonl(os.path.join(gui_dir(), "audit.jsonl"), record, AUDIT_KEEP_LINES)
    except OSError:
        pass
    try:
        subprocess.run(["logger", "-t", "backup-suite-control",
                        "%s by %s (uid %s): %s %s" % (verb, CALLER_LOGIN, CALLER_UID,
                                                      "ok" if ok else "failed", summary[:200])],
                       timeout=5, capture_output=True)
    except (OSError, subprocess.TimeoutExpired):
        pass


def get_args(request, allowed):
    args = request.get("args", {})
    if args is None:
        args = {}
    if not isinstance(args, dict):
        invalid("args must be an object.")
    unknown = set(args) - set(allowed)
    if unknown:
        invalid("Unknown argument(s): %s" % ", ".join(sorted(unknown)))
    return args


def bounded_int(args, key, default, low, high):
    value = args.get(key, default)
    if isinstance(value, bool) or not isinstance(value, int):
        invalid("%s must be an integer." % key)
    if value < low:
        invalid("%s must be at least %d." % (key, low))
    return min(value, high)


def choice(args, key, options, required=True):
    value = args.get(key)
    if value is None and not required:
        return None
    if value not in options:
        invalid("%s must be one of: %s" % (key, ", ".join(options)))
    return value


# --------------------------------------------------------------------------- read verbs

def parse_show_blocks(text):
    blocks = []
    current = {}
    for line in text.splitlines():
        if not line.strip():
            if current:
                blocks.append(current)
                current = {}
            continue
        if "=" in line:
            key, value = line.split("=", 1)
            current[key] = value
    if current:
        blocks.append(current)
    return {block.get("Id", ""): block for block in blocks}


def server_memory():
    info = {}
    try:
        with open(os.path.join(PROC_DIR, "meminfo")) as handle:
            for line in handle:
                parts = line.split()
                if parts and parts[0] in ("MemTotal:", "MemAvailable:", "SwapTotal:", "SwapFree:"):
                    info[parts[0].rstrip(":")] = int(parts[1]) * 1024
    except OSError:
        pass
    psi = None
    try:
        with open(os.path.join(PROC_DIR, "pressure", "memory")) as handle:
            for line in handle:
                if line.startswith("full"):
                    match = re.search(r"avg10=([0-9.]+)", line)
                    if match:
                        psi = float(match.group(1))
    except OSError:
        pass
    total = info.get("MemTotal", 0)
    available = info.get("MemAvailable", 0)
    return {"total_bytes": total, "available_bytes": available,
            "available_percent": round(available * 100 / total, 1) if total else None,
            "swap_total_bytes": info.get("SwapTotal", 0), "swap_free_bytes": info.get("SwapFree", 0),
            "psi_full_avg10": psi}


def verb_status(request):
    get_args(request, [])
    services = {}
    timers = {}
    code, out, err = systemctl("show", *SERVICES, "-p", ",".join(SERVICE_PROPERTIES))
    if code == 0:
        services = parse_show_blocks(out)
    code, out, err = systemctl("show", *TIMERS, "-p", ",".join(TIMER_PROPERTIES))
    if code == 0:
        timers = parse_show_blocks(out)
    enabled = {}
    for timer in TIMERS:
        code, out, err = systemctl("is-enabled", timer)
        enabled[timer] = out.strip() or "unknown"
    adaptive_level = None
    try:
        with open(state_path("watchdog", "adaptive-profile.state")) as handle:
            for line in handle:
                if line.startswith("level="):
                    adaptive_level = line.split("=", 1)[1].strip()
    except OSError:
        pass
    last_action = read_key_values(state_path("watchdog", "file-backup.service.last-action"))
    return {
        "mode": MODE,
        "scope": SCOPE,
        "host": HOSTNAME,
        "caller": {"uid": CALLER_UID, "login": CALLER_LOGIN},
        "services": services,
        "timers": timers,
        "timers_enabled": enabled,
        "watchdog": read_key_values(state_path("watchdog", "file-backup.service.status")),
        "watchdog_last_action": last_action,
        "adaptive_level": adaptive_level,
        "progress": read_key_values(state_path("run", "progress.env")),
        "server": server_memory(),
        "events": events_stat_data(),
        # What this installed control script can do: the GUI compares it with what
        # it needs and says when Backup Suite on the server must be deployed again.
        "verbs": sorted(VERBS),
        "at": now_iso(),
    }


HISTORY_COLUMNS = ["started", "ended", "unit", "profile", "duration_s", "peak_mem", "peak_anon", "peak_swap",
                   "avg_cpu_pct", "peak_cpu_pct", "peak_tasks", "io_read", "io_write", "events", "outcome"]


def verb_history(request):
    args = get_args(request, ["limit"])
    limit = bounded_int(args, "limit", 100, 1, MAX_HISTORY_ROWS)
    rows = []
    text, truncated = read_text(state_path("watchdog", "history.tsv"))
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) < len(HISTORY_COLUMNS) or fields[0] == "started":
            continue
        row = dict(zip(HISTORY_COLUMNS, fields))
        # Column 16 (how systemd says the run ended) exists since the watchdog records it.
        row["result"] = fields[len(HISTORY_COLUMNS)] if len(fields) > len(HISTORY_COLUMNS) else ""
        for key in ("duration_s", "peak_mem", "peak_anon", "peak_swap", "avg_cpu_pct", "peak_cpu_pct",
                    "peak_tasks", "io_read", "io_write"):
            try:
                row[key] = int(row[key])
            except ValueError:
                row[key] = None
        row["events"] = [] if row["events"] in ("", "none") else row["events"].split(",")
        rows.append(row)
    rows.reverse()
    return {"rows": rows[:limit], "total": len(rows), "truncated": truncated or len(rows) > limit}


def log_runs(text):
    """Returns [(start_text, first_line_index)] for each run in the durable log."""
    starts = []
    lines = text.splitlines()
    for index, line in enumerate(lines):
        match = RUN_START_RE.match(line)
        if match:
            starts.append((match.group(1), index))
    return lines, starts


def to_epoch(text):
    for pattern in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return datetime.datetime.strptime(text, pattern).replace(tzinfo=datetime.timezone.utc).timestamp()
        except ValueError:
            continue
    return None


PROJECT_LINE_RE = re.compile(r"^(File backup (started|finished) at|Resource profile|Syncing label=|File sync (completed|failed)|Deferring [0-9]+ path|Retrying '|Initial sync failed|Migration confirmation required|Skipping |No child project|Invalid |Source path is|destination_value is required|Run summary:|Failed file sources:|WARNING: )")
ERROR_LINE_RE = re.compile(r"ERROR|error|failed|Failed|WARNING")


def verb_runlog(request):
    args = get_args(request, ["run", "lines", "list", "filter"])
    line_filter = choice(args, "filter", ["projects", "errors"], required=False)
    lines_wanted = bounded_int(args, "lines", 500, 1, 100000)
    text, truncated_file = read_text(state_path("logs", "backup-file.log"), 8 * 1024 * 1024)
    lines, starts = log_runs(text)
    if args.get("list"):
        return {"runs": [start for start, _ in reversed(starts)][:200]}
    wanted = args.get("run", "latest")
    if not isinstance(wanted, str) or len(wanted) > 40:
        invalid("run must be 'latest' or a start time.")
    if not starts:
        return {"run": None, "lines": [], "truncated": False}
    chosen = len(starts) - 1
    if wanted != "latest":
        wanted_epoch = to_epoch(wanted)
        if wanted_epoch is None:
            invalid("run must be 'latest' or a start time like 2026-10-14T16:05:00Z.")
        best = None
        for index, (start, _) in enumerate(starts):
            start_epoch = to_epoch(start)
            if start_epoch is None:
                continue
            distance = abs(start_epoch - wanted_epoch)
            if distance <= 180 and (best is None or distance < best[0]):
                best = (distance, index)
        if best is None:
            raise ControlError("not_found", "No run in the durable log started near %s." % wanted)
        chosen = best[1]
    first = starts[chosen][1]
    last = starts[chosen + 1][1] if chosen + 1 < len(starts) else len(lines)
    slice_lines = lines[first:last]
    if line_filter == "projects":
        slice_lines = [line for line in slice_lines if PROJECT_LINE_RE.match(line)]
    elif line_filter == "errors":
        slice_lines = [line for line in slice_lines if ERROR_LINE_RE.search(line)]
    limit = min(lines_wanted, MAX_LOG_LINES)
    truncated = len(slice_lines) > limit
    if truncated:
        slice_lines = slice_lines[-limit:]
    return {"run": starts[chosen][0], "lines": slice_lines, "truncated": truncated}


def verb_journal(request):
    args = get_args(request, ["source", "lines"])
    source = choice(args, "source", sorted(JOURNAL_SOURCES))
    lines_wanted = min(bounded_int(args, "lines", 200, 1, 100000), MAX_LOG_LINES)
    command = [JOURNALCTL]
    if SCOPE == "user":
        command.append("--user")
    command += JOURNAL_SOURCES[source] + ["-n", str(lines_wanted), "--no-pager", "-o", "short-iso"]
    code, out, err = run(command, READ_TIMEOUT)
    text = out if code == 0 else (out + err)
    truncated = len(text) > MAX_REPLY_TEXT
    return {"source": source, "lines": text[-MAX_REPLY_TEXT:].splitlines(), "truncated": truncated}


def verb_failures_list(request):
    get_args(request, [])
    directory = state_path("failures")
    entries = []
    try:
        for name in os.listdir(directory):
            if FAILURE_NAME_RE.match(name):
                path = os.path.join(directory, name)
                stat = os.stat(path)
                entries.append({"name": name, "size": stat.st_size,
                                "modified": datetime.datetime.fromtimestamp(stat.st_mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
    except OSError:
        pass
    entries.sort(key=lambda entry: entry["name"], reverse=True)
    return {"failures": entries[:200]}


def verb_failures_read(request):
    args = get_args(request, ["name"])
    name = args.get("name")
    if not isinstance(name, str) or not FAILURE_NAME_RE.match(name):
        invalid("name must be a failure record file name.")
    path = state_path("failures", name)
    if not os.path.isfile(path):
        raise ControlError("not_found", "No such failure record.")
    text, truncated = read_text(path)
    return {"name": name, "text": text, "truncated": truncated}


def verb_deferrals(request):
    get_args(request, [])
    directory = state_path("active-files")
    rows = []
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".tsv"):
            continue
        path = os.path.join(directory, name)
        try:
            stat = os.stat(path)
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    parts = line.rstrip("\n").split("\t", 1)
                    if len(parts) == 2 and parts[0].isdigit():
                        rows.append({"project": name[:-4], "count": int(parts[0]), "path": parts[1],
                                     "updated": datetime.datetime.fromtimestamp(stat.st_mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
        except OSError:
            continue
    rows.sort(key=lambda row: -row["count"])
    try:
        max_deferrals = int(ENV.get("BSC_ACTIVE_MAX_DEFERRALS", "12"))
    except ValueError:
        max_deferrals = 12
    return {"rows": rows[:2000], "max_deferrals": max_deferrals, "truncated": len(rows) > 2000}


def parse_sources(text):
    rows = []
    for number, line in enumerate(text.splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = [field.strip() for field in line.split("|")]
        row = {"line": number, "enabled": fields[0] if fields else "", "label": fields[1] if len(fields) > 1 else "",
               "source": fields[2] if len(fields) > 2 else "", "destination_mode": fields[3] if len(fields) > 3 else "",
               "destination_value": fields[4] if len(fields) > 4 else "", "stop_file": fields[5] if len(fields) > 5 else "",
               "isolation": (fields[6] if len(fields) > 6 else "") or "single", "extra_fields": len(fields) > 7}
        row["source_exists"] = os.path.isdir(row["source"]) if row["source"] else False
        rows.append(row)
    return rows


def verb_sources_get(request):
    get_args(request, [])
    if not os.path.isfile(SOURCES_FILE):
        raise ControlError("not_found", "Source config not found: %s" % SOURCES_FILE)
    text, truncated = read_text(SOURCES_FILE)
    stat = os.stat(SOURCES_FILE)
    return {"path": SOURCES_FILE, "text": text, "truncated": truncated, "sha256": file_sha256(SOURCES_FILE),
            "modified": datetime.datetime.fromtimestamp(stat.st_mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "rows": parse_sources(text), "editable": False}


def verb_excludes_list(request):
    get_args(request, [])
    text, _ = read_text(SOURCES_FILE) if os.path.isfile(SOURCES_FILE) else ("", False)
    files = []
    deadline = time.monotonic() + 8
    truncated = False
    for row in parse_sources(text):
        if row["enabled"] not in ("1", "true", "yes", "on") or not row["source_exists"]:
            continue
        for directory, subdirs, names in os.walk(row["source"]):
            subdirs[:] = [name for name in subdirs if name not in (".git", "node_modules", "vendor")]
            if EXCLUDE_FILENAME in names:
                path = os.path.join(directory, EXCLUDE_FILENAME)
                try:
                    with open(path, "r", encoding="utf-8", errors="replace") as handle:
                        content_lines = []
                        for index, line in enumerate(handle):
                            if index >= 200:
                                break
                            content_lines.append(line.rstrip("\n"))
                    files.append({"source_label": row["label"], "path": path, "size": os.path.getsize(path),
                                  "lines": content_lines})
                except OSError:
                    continue
            if len(files) >= 200 or time.monotonic() > deadline:
                truncated = True
                break
        if truncated:
            break
    return {"filename": EXCLUDE_FILENAME, "files": files, "truncated": truncated}


def profile_show(limits_mode=None):
    command = [bin_script("backup-profile.sh"), "show", "--json"]
    if limits_mode:
        command += ["--limits", limits_mode]
    code, out, err = run(command, READ_TIMEOUT)
    if code != 0:
        raise ControlError("profile_error", (err or out).strip()[:500] or "backup-profile.sh show failed.")
    try:
        return json.loads(out)
    except ValueError:
        raise ControlError("profile_error", "backup-profile.sh show --json returned invalid JSON.")


def verb_profile_show(request):
    args = get_args(request, ["limits_mode"])
    limits_mode = choice(args, "limits_mode", ["fixed", "auto"], required=False)
    return profile_show(limits_mode)


def profile_setup_args(args):
    mode = choice(args, "mode", ["fixed", "adaptive"])
    if mode == "fixed":
        profile = choice(args, "profile", PROFILES + ["custom"])
        if "top" in args or "floor" in args:
            invalid("Fixed mode takes only 'profile'.")
        return ["set", profile], profile
    top = choice(args, "top", PROFILES)
    floor = choice(args, "floor", PROFILES)
    if "profile" in args:
        invalid("Adaptive mode takes 'top' and 'floor'.")
    if PROFILE_RANK[floor] >= PROFILE_RANK[top]:
        invalid("The floor must be slower than the top profile.")
    return ["adaptive", top, floor], top


def verb_profile_preview(request):
    args = get_args(request, ["mode", "profile", "top", "floor"])
    command, top = profile_setup_args(args)
    code, out, err = run([bin_script("backup-profile.sh"), "print-dropin", top], READ_TIMEOUT)
    if code != 0:
        raise ControlError("profile_error", (err or out).strip()[:500])
    return {"dropin": out, "profile": top}


def run_profile_change(command):
    code, out, err = run([bin_script("backup-profile.sh")] + command, CHANGE_TIMEOUT)
    output = (out + err).strip()
    if code != 0:
        raise ControlError("profile_error", output[-1000:] or "backup-profile.sh failed.")
    return {"output": output[-4000:], "profiles": profile_show()}


def verb_profile_set(request):
    args = get_args(request, ["mode", "profile", "top", "floor"])
    command, _ = profile_setup_args(args)
    return run_profile_change(command)


def verb_profile_limits(request):
    args = get_args(request, ["mode"])
    return run_profile_change(["limits", choice(args, "mode", ["fixed", "auto"])])


def verb_profile_override(request):
    args = get_args(request, ["profile", "key", "value", "unset"])
    profile = choice(args, "profile", PROFILES)
    key = choice(args, "key", OVERRIDE_KEYS)
    if args.get("unset") is True:
        if "value" in args:
            invalid("Give either value or unset.")
        return run_profile_change(["override", profile, key, "--unset"])
    value = args.get("value")
    if not isinstance(value, str) or not re.fullmatch(OVERRIDE_VALUE_RE[key], value):
        invalid("Invalid value for %s." % key)
    return run_profile_change(["override", profile, key, value])


def config_entry(key, values):
    present = key in values
    value = values.get(key, "")
    reason = config_readonly_reason(key)
    if key in CONFIG_KEYS:
        kind, explanation = CONFIG_KEYS[key]
    else:
        kind, explanation = ("text", 0), ""
    entry = {"key": key, "kind": kind[0], "explanation": explanation, "default": CONFIG_DEFAULTS.get(key, ""),
             "present": present, "editable": not reason, "readonly_reason": reason,
             "schedule": key in SCHEDULE_KEYS, "relocates": key in RELOCATING_KEYS}
    if key == "FILE_JOB_SOURCE_ROOTS":
        entry["default"] = DEFAULT_JOB_SOURCE_ROOTS
    if kind[0] == "int":
        entry["min"], entry["max"] = kind[1], kind[2]
    if kind[0] == "choice":
        entry["options"] = kind[1]
    if key in SECRET_KEYS:
        entry["value"] = None
        entry["is_set"] = bool(value)
    elif key in MASKED_KEYS:
        entry["value"] = mask_url(value)
        entry["is_set"] = bool(value)
        entry["masked"] = True
    else:
        entry["value"] = value
    return entry


def verb_config_get(request):
    get_args(request, [])
    path = os.path.realpath(GLOBAL_CONFIG_FILE)
    values = parse_global_config(path)
    settings = [config_entry(key, values) for key in CONFIG_KEY_ORDER]
    known = set(CONFIG_KEY_ORDER)
    others = sorted(key for key in values if key not in known)
    groups = [{"id": group_id, "label": label, "keys": keys} for group_id, label, keys in CONFIG_GROUPS]
    if others:
        # Keys this GUI does not know (older or newer Backup Suite, or a typo): shown read-only.
        settings += [config_entry(key, values) for key in others]
        groups.append({"id": "other", "label": "Other keys in global.conf (read-only)", "keys": others})
    return {"path": GLOBAL_CONFIG_FILE, "sha256": file_sha256(path), "settings": settings, "groups": groups}


def validate_config_value(key, value):
    kind, _ = CONFIG_KEYS[key]
    if not isinstance(value, str):
        invalid("%s must be a string." % key)
    if any(character in value for character in "\"$`\\\n\r'"):
        invalid("%s cannot contain quotes, $, backticks, backslashes or line breaks." % key)
    name = kind[0]
    if name == "int":
        if not re.fullmatch(r"[0-9]+", value) or not kind[1] <= int(value) <= kind[2]:
            invalid("%s must be a whole number from %d to %d." % (key, kind[1], kind[2]))
    elif name == "bool":
        if value not in ("0", "1"):
            invalid("%s must be 0 or 1." % key)
    elif name == "regex":
        if not re.fullmatch(kind[1], value):
            invalid("Invalid value for %s." % key)
    elif name == "url":
        if value and not re.fullmatch(r"https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/-]+", value):
            invalid("%s must be an https:// URL." % key)
    elif name == "choice":
        if value not in kind[1]:
            invalid("%s must be one of: %s" % (key, ", ".join(kind[1])))
    elif name == "text":
        if len(value) > kind[1] or not re.fullmatch(r"[A-Za-z0-9 ._:()-]*", value):
            invalid("%s may hold up to %d letters, digits, spaces and . _ : ( ) -" % (key, kind[1]))
    elif name == "secret":
        if len(value) > 200 or not re.fullmatch(r"[A-Za-z0-9._-]*", value):
            invalid("%s may hold only letters, digits, . _ and -." % key)
    elif name == "calendar":
        if not value or len(value) > 100 or not re.fullmatch(r"[A-Za-z0-9 *:/.,~+-]+", value):
            invalid("%s must be a systemd calendar expression such as *:0/30, hourly or daily." % key)
        analyze = shutil.which("systemd-analyze")
        if analyze:
            code, _, err = run([analyze, "calendar", value], READ_TIMEOUT)
            if code != 0:
                invalid("%s: systemd does not accept '%s' (%s)." % (key, value, err.strip().splitlines()[-1] if err.strip() else "invalid"))
    elif name == "remote":
        if not re.fullmatch(r"[A-Za-z0-9_-]+(,[A-Za-z0-9_]+=[A-Za-z0-9._-]+)*:[A-Za-z0-9._/ -]*", value):
            invalid("%s must look like remote:folder (optionally remote,option=value:folder)." % key)
    elif name == "relpath":
        if not re.fullmatch(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*", value) or ".." in value.split("/"):
            invalid("%s must be a relative folder like files or sites/web10." % key)
    elif name == "filename":
        if not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", value) or value in (".", ".."):
            invalid("%s must be a single file or folder name." % key)
    elif name == "patterns":
        if len(value) > 4000 or not re.fullmatch(r"[A-Za-z0-9 ._/*?\[\]{},|!+#@%=:~-]*", value):
            invalid("%s may hold rclone patterns separated by | (no quotes, $ or backslashes)." % key)


def merged_config_checks(values):
    def number(key):
        try:
            return int(values.get(key, CONFIG_DEFAULTS[key]))
        except ValueError:
            return int(CONFIG_DEFAULTS[key])
    if not number("WATCHDOG_CONTAIN_RELEASE_PERCENT") < number("WATCHDOG_CONTAIN_PERCENT") < number("WATCHDOG_KILL_PERCENT") <= 99:
        invalid("The watchdog needs release < contain < stop (kill) <= 99 percent.")
    if not number("WATCHDOG_SYSTEM_CRITICAL_AVAILABLE_PERCENT") < number("WATCHDOG_SYSTEM_MIN_AVAILABLE_PERCENT"):
        invalid("The critical server RAM percent must be below the pause percent.")
    if not number("WATCHDOG_ADAPTIVE_STEP_UP_AVAILABLE_PERCENT") > number("WATCHDOG_ADAPTIVE_STEP_DOWN_AVAILABLE_PERCENT"):
        invalid("Adaptive step-up RAM percent must be above the step-down percent.")
    if not number("WATCHDOG_SWAP_CONTAIN_PERCENT") < number("WATCHDOG_SWAP_KILL_PERCENT"):
        invalid("Swap containment percent must be below the swap stop percent.")
    if not number("WATCHDOG_PSI_PAUSE_AVAILABLE_PERCENT") >= number("WATCHDOG_SYSTEM_MIN_AVAILABLE_PERCENT"):
        invalid("The stall pause RAM percent must be at or above the shortage pause percent.")


def verb_config_set(request):
    args = get_args(request, ["changes", "expect_sha"])
    changes = args.get("changes")
    if not isinstance(changes, dict) or not changes:
        invalid("changes must be a non-empty object.")
    for key, value in changes.items():
        if key not in CONFIG_KEYS or config_readonly_reason(key):
            invalid("%s cannot be changed from the GUI. %s" % (key, config_readonly_reason(key)))
        validate_config_value(key, value)
    expect = args.get("expect_sha")
    if not isinstance(expect, str) or not re.fullmatch(r"[0-9a-f]{64}", expect):
        invalid("expect_sha is required.")
    path = os.path.realpath(GLOBAL_CONFIG_FILE)
    current_sha = file_sha256(path)
    if current_sha != expect:
        raise ControlError("config_conflict", "global.conf changed since it was read; reload and try again.")
    current = parse_global_config(path)
    merged = dict(current)
    merged.update(changes)
    merged_config_checks(merged)

    backups = os.path.join(gui_dir(), "config-backups")
    os.makedirs(backups, mode=0o750, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    backup_path = os.path.join(backups, "global.conf.%s" % stamp)
    shutil.copy2(path, backup_path)
    os.chmod(backup_path, 0o600)
    existing = sorted(name for name in os.listdir(backups) if name.startswith("global.conf."))
    for name in existing[:-CONFIG_BACKUPS_KEEP]:
        try:
            os.remove(os.path.join(backups, name))
        except OSError:
            pass

    with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
        lines = handle.read().splitlines()
    pending = dict(changes)
    output = []
    for line in lines:
        match = re.match(r"^([A-Z][A-Z0-9_]*)=", line)
        if match and match.group(1) in changes:
            key = match.group(1)
            if key in pending:
                output.append('%s="%s"' % (key, pending.pop(key)))
            continue
        output.append(line)
    for key, value in pending.items():
        output.append('%s="%s"' % (key, value))
    # Rewrite in place: keeps the inode, owner, mode and any symlink.
    with open(path, "r+", encoding="utf-8", errors="surrogateescape") as handle:
        handle.seek(0)
        handle.write("\n".join(output) + "\n")
        handle.truncate()
    changed = ", ".join("%s=%s" % (k, "[set]" if k in SECRET_KEYS and v else v) for k, v in changes.items())
    record_event("info", "gui-action", "Settings changed: %s" % ", ".join(sorted(changes)), changed, "")
    note = "The changes apply from the next backup run."
    schedule_output = ""
    if SCHEDULE_KEYS & set(changes):
        code, out, err = run([bin_script("apply-schedule.sh")], CHANGE_TIMEOUT)
        schedule_output = (out + err).strip()
        if code != 0:
            raise ControlError("apply_failed", "global.conf was saved, but the timers were not updated: %s" % schedule_output[-500:])
        note = "The schedule was applied to the timers at once; other changes apply from the next backup run."
    return {"sha256": file_sha256(path), "backup": backup_path, "changed": sorted(changes), "note": note,
            "schedule_output": schedule_output}


def verb_backup_start(request):
    args = get_args(request, ["what"])
    what = choice(args, "what", ["files", "databases"])
    unit = "file-backup.service" if what == "files" else "database-backup.service"
    code, out, err = systemctl("start", "--no-block", unit, timeout=CHANGE_TIMEOUT)
    if code != 0:
        raise ControlError("systemctl_failed", (err or out).strip()[:500])
    record_event("info", "gui-action", "Started %s" % unit, "Started from the GUI by %s." % CALLER_LOGIN, unit)
    return {"unit": unit, "started": True}


def verb_backup_stop(request):
    get_args(request, [])
    code, out, err = systemctl("stop", "--no-block", "file-backup.service", timeout=CHANGE_TIMEOUT)
    if code != 0:
        raise ControlError("systemctl_failed", (err or out).strip()[:500])
    record_event("warning", "gui-action", "Stopped file-backup.service",
                 "Stopped from the GUI by %s. Finished projects stay backed up; the current project is redone next run." % CALLER_LOGIN,
                 "file-backup.service")
    return {"unit": "file-backup.service", "stopping": True}


def verb_timer_set(request):
    args = get_args(request, ["timer", "enabled"])
    timer = choice(args, "timer", TIMERS)
    enabled = args.get("enabled")
    if not isinstance(enabled, bool):
        invalid("enabled must be true or false.")
    action = "enable" if enabled else "disable"
    code, out, err = systemctl(action, "--now", timer, timeout=CHANGE_TIMEOUT)
    if code != 0:
        raise ControlError("systemctl_failed", (err or out).strip()[:500])
    severity = "info" if enabled else "warning"
    category = "gui-action" if enabled else "schedule-off"
    record_event(severity, category, "%s %sd" % (timer, action),
                 "%s by %s from the GUI." % ("Enabled" if enabled else "Disabled", CALLER_LOGIN), timer)
    return {"timer": timer, "enabled": enabled}


def verb_notify_test(request):
    get_args(request, [])
    code, out, err = run([bin_script("notify-test.sh")], CHANGE_TIMEOUT)
    output = (out + err).strip()
    if code != 0:
        raise ControlError("notify_failed", output[-1000:] or "notify-test.sh failed.")
    return {"output": output[-2000:]}


def events_stat_data():
    path = state_path("events.jsonl")
    try:
        stat = os.stat(path)
        return {"size": stat.st_size, "mtime": stat.st_mtime}
    except OSError:
        return {"size": 0, "mtime": 0}


def verb_events_stat(request):
    get_args(request, [])
    return events_stat_data()


def verb_events_since(request):
    args = get_args(request, ["seq", "limit"])
    after = bounded_int(args, "seq", 0, 0, 2 ** 62)
    limit = bounded_int(args, "limit", 200, 1, 1000)
    events = []
    text, _ = read_text(state_path("events.jsonl"), 4 * 1024 * 1024)
    for line in text.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and isinstance(event.get("seq"), int) and event["seq"] > after:
            events.append(event)
    latest = events[-1]["seq"] if events else after
    return {"events": events[-limit:], "latest_seq": latest, "truncated": len(events) > limit,
            "stat": events_stat_data()}


def verb_audit(request):
    args = get_args(request, ["limit"])
    limit = bounded_int(args, "limit", 200, 1, AUDIT_KEEP_LINES)
    entries = []
    text, _ = read_text(os.path.join(state_path("gui"), "audit.jsonl"))
    for line in text.splitlines():
        try:
            entries.append(json.loads(line))
        except ValueError:
            continue
    entries.reverse()
    return {"entries": entries[:limit]}


# verb: (function, changes something)
# --------------------------------------------------------------------------- backup jobs
#
# One backup job is one line of file-sources.conf. Its projects are the entry itself
# (isolation single) or each child directory (isolation children). file-backup.sh
# records one row per project and run in projects/history.tsv and the changed files
# of each project's last run in projects/changes/<key>.tsv, where <key> is the
# sha256 of the project's remote destination (the same key as active-files/<key>.tsv).

PROJECT_HISTORY_COLUMNS = ["run", "started", "ended", "entry", "project", "source", "destination", "key", "result",
                           "deferred_active", "skipped_changed", "new", "updated", "removed"]
PROJECT_HISTORY_READ_BYTES = 8 * 1024 * 1024
ENTRY_RUNS_KEEP = 60
CHILDREN_MAX = 2000
CHANGES_LINES_MAX = 1000
SYNCED_RESULTS = ("synced", "synced-retry", "synced-with-skips")
REMOTE_BASE = ENV.get("BSC_REMOTE_BASE", "")
ARCHIVE_FOLDER = ENV.get("BSC_ARCHIVE_FOLDER", "deleted_files")
RETENTION = ENV.get("BSC_RETENTION", "21d")
DEFAULT_STOP_FILE = ENV.get("BSC_STOP_FILE", ".nosync")
DEFAULT_DESTINATION_ROOT = ENV.get("BSC_DEFAULT_DESTINATION_ROOT", "files")
VOLATILE_FILENAME = ENV.get("BSC_VOLATILE_FILENAME", ".backup-volatile")
GLOBAL_EXCLUDES = [part for part in ENV.get("BSC_GLOBAL_EXCLUDES", "").split("|") if part.strip()]
GLOBAL_VOLATILE = [part for part in ENV.get("BSC_GLOBAL_VOLATILE", "").split("|") if part.strip()]
RCLONE_BIN = ENV.get("BSC_RCLONE_BIN", "rclone")
RCLONE_CONFIG = ENV.get("BSC_RCLONE_CONFIG", "")
LABEL_RE = re.compile(r"^[^\x00-\x1f]{1,300}$")


def strip_slashes(value):
    if value.startswith("/"):
        value = value[1:]
    if value.endswith("/"):
        value = value[:-1]
    return value


def join_path(*parts):
    """file-backup.sh's join_path: one slash stripped at each end of every part."""
    prefix = "/" if parts and parts[0].startswith("/") else ""
    kept = [strip_slashes(part) for part in parts]
    return prefix + "/".join(part for part in kept if part)


def destination_key(destination):
    return hashlib.sha256(destination.encode("utf-8")).hexdigest()


def is_enabled_value(value):
    return value.strip().lower() in ("1", "true", "yes", "on")


def entry_destination_relative(row):
    mode = row["destination_mode"] or "default-root"
    if mode == "same-name":
        return os.path.basename(row["source"].rstrip("/"))
    if mode == "fixed":
        return strip_slashes(row["destination_value"]) if row["destination_value"] else ""
    if mode == "default-root":
        key = row["destination_value"] or row["label"] or os.path.basename(row["source"].rstrip("/"))
        return join_path(DEFAULT_DESTINATION_ROOT, key)
    if mode == "remote":
        match = REMOTE_VALUE_RE.match(row["destination_value"] or "")
        return strip_slashes(match.group(2)) if match else ""
    return ""


REMOTE_VALUE_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9_-]{0,31}):/?([A-Za-z0-9._ -]+(/[A-Za-z0-9._ -]+)*)/?$")


def entry_base(row):
    """The remote root a job's destination is under: the default (RCLONE_REMOTE_ROOT
    with this host) or, in mode remote, the job's own remote."""
    if row["destination_mode"] == "remote":
        match = REMOTE_VALUE_RE.match(row["destination_value"] or "")
        return "%s:" % match.group(1) if match else ""
    return REMOTE_BASE


def describe_entry(row):
    """The entry as file-backup.sh treats it."""
    name = row["label"] or row["source"]
    relative = entry_destination_relative(row)
    base = entry_base(row)
    stop_file = row["stop_file"] or DEFAULT_STOP_FILE
    entry = {
        "name": name, "line": row["line"], "label": row["label"], "enabled": is_enabled_value(row["enabled"]),
        "source": row["source"], "source_exists": row["source_exists"], "isolation": row["isolation"],
        "destination_mode": row["destination_mode"] or "default-root", "destination_value": row["destination_value"],
        "destination": join_path(base, relative) if relative and base else "",
        "remote": base[:-1] if row["destination_mode"] == "remote" and base else "",
        "destination_relative": relative, "stop_file": stop_file, "stop_file_configured": row["stop_file"],
        "stop_file_present": bool(row["source_exists"] and stop_file and os.path.isfile(os.path.join(row["source"], stop_file))),
        "archive": join_path(base, ARCHIVE_FOLDER, "<run time>", "attempt-<n>", relative) if relative and base else "",
        "retention": RETENTION, "problem": "",
    }
    if row["extra_fields"]:
        entry["problem"] = "The line has more than 7 fields."
    elif not row["source"]:
        entry["problem"] = "The source path is empty."
    elif not row["source_exists"]:
        entry["problem"] = "The source directory does not exist."
    elif not relative:
        entry["problem"] = {"fixed": "No destination: fixed mode needs a destination value.",
                            "remote": "Destination must be remote:folder, e.g. dropbox:backups/web10."}.get(row["destination_mode"], "Unknown destination mode.")
    elif row["isolation"] not in ("single", "children"):
        entry["problem"] = "Unknown isolation mode %s." % row["isolation"]
    return entry


def entry_projects(entry):
    """The projects this entry has now: [(project label, source path, destination, stop file present)]."""
    if not entry["source_exists"] or entry["problem"]:
        return [], False
    if entry["isolation"] == "single":
        return [(entry["name"], entry["source"], entry["destination"], entry["stop_file_present"])], False
    children = []
    truncated = False
    try:
        names = sorted(name for name in os.listdir(entry["source"])
                       if os.path.isdir(os.path.join(entry["source"], name)) and not os.path.islink(os.path.join(entry["source"], name)))
    except OSError:
        names = []
    if len(names) > CHILDREN_MAX:
        names = names[:CHILDREN_MAX]
        truncated = True
    base_label = entry["label"] or os.path.basename(entry["source"].rstrip("/"))
    for name in names:
        path = os.path.join(entry["source"], name)
        stop = bool(entry["stop_file"]) and os.path.isfile(os.path.join(path, entry["stop_file"]))
        children.append(("%s/%s" % (base_label, name), path, join_path(entry["destination"], name) if entry["destination"] else "", stop))
    return children, truncated


def read_project_history():
    text, truncated = read_text(state_path("projects", "history.tsv"), PROJECT_HISTORY_READ_BYTES)
    rows = []
    for line in text.splitlines():
        fields = line.split("\t")
        if len(fields) < len(PROJECT_HISTORY_COLUMNS):
            continue
        row = dict(zip(PROJECT_HISTORY_COLUMNS, fields))
        for key in ("deferred_active", "skipped_changed", "new", "updated", "removed"):
            try:
                row[key] = int(row[key])
            except ValueError:
                row[key] = 0
        rows.append(row)
    return rows, truncated


def legacy_project_rows():
    """Before projects/history.tsv existed: the latest run's project results from the
    durable log, so an entry page has something to show until the next run."""
    text, _ = read_text(state_path("logs", "backup-file.log"), 8 * 1024 * 1024)
    lines, starts = log_runs(text)
    if not starts:
        return []
    run_text, first = starts[-1]
    epoch = to_epoch(run_text)
    run_iso = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if epoch else run_text
    rows = []
    current = None
    for line in lines[first:]:
        match = re.match(r"^Syncing label='(.*)' source='(.*)' destination='(.*)'$", line)
        if match:
            current = {"run": run_iso, "started": "", "ended": "", "entry": match.group(1).split("/")[0], "project": match.group(1),
                       "source": match.group(2), "destination": match.group(3), "key": destination_key(match.group(3)),
                       "result": "running", "deferred_active": 0, "skipped_changed": 0, "new": None, "updated": None, "removed": None,
                       "legacy": True}
            rows.append(current)
            continue
        if not current:
            continue
        if line.startswith("File sync completed with changing paths"):
            current["result"] = "synced-with-skips"
        elif line.startswith("File sync completed on stability retry"):
            current["result"] = "synced-retry"
        elif line.startswith("File sync completed for"):
            current["result"] = "synced"
        elif line.startswith("File sync failed"):
            current["result"] = "failed"
        elif line.startswith("Migration confirmation required"):
            current["result"] = "migration-required"
        deferred = re.match(r"^Deferring ([0-9]+) path", line)
        if deferred:
            current["deferred_active"] = int(deferred.group(1))
    return rows


def deferral_counts():
    """{key: (paths, never-settling paths)} from active-files/<key>.tsv."""
    try:
        max_deferrals = int(ENV.get("BSC_ACTIVE_MAX_DEFERRALS", "12"))
    except ValueError:
        max_deferrals = 12
    counts = {}
    directory = state_path("active-files")
    try:
        names = os.listdir(directory)
    except OSError:
        names = []
    for name in names:
        if not name.endswith(".tsv"):
            continue
        total = stale = 0
        try:
            with open(os.path.join(directory, name), "r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    parts = line.split("\t", 1)
                    if len(parts) == 2 and parts[0].isdigit():
                        total += 1
                        if int(parts[0]) >= max_deferrals:
                            stale += 1
        except OSError:
            continue
        counts[name[:-4]] = (total, stale)
    return counts, max_deferrals


def run_state():
    progress = read_key_values(state_path("run", "progress.env")) or {}
    code, out, _ = systemctl("show", "file-backup.service", "-p", "Id,ActiveState")
    active = parse_show_blocks(out).get("file-backup.service", {}).get("ActiveState", "") if code == 0 else ""
    running = active in ("active", "activating", "deactivating") and progress.get("state") == "running"
    timer = {}
    code, out, _ = systemctl("show", "file-backup.timer", "-p", "NextElapseUSecRealtime,LastTriggerUSec")
    if code == 0:
        for line in out.splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                timer[key] = value
    return {"running": running, "active_state": active, "current_entry": progress.get("current_entry", "") if running else "",
            "current_project": progress.get("current_project", "") if running else "",
            "run_started": progress.get("started_at", "") if running else "",
            "next_run": timer.get("NextElapseUSecRealtime", ""), "last_trigger": timer.get("LastTriggerUSec", "")}


def summarize_rows(rows):
    """One run of one entry: counts by result and changed files."""
    summary = {"projects": len(rows), "synced": 0, "failed": 0, "skipped": 0, "other": 0, "new": 0, "updated": 0, "removed": 0,
               "deferred": 0, "started": "", "ended": "", "changes_known": True}
    for row in rows:
        result = row["result"]
        if result in SYNCED_RESULTS:
            summary["synced"] += 1
        elif result in ("failed", "missing-source", "unreadable-source", "invalid-config", "no-child-projects"):
            summary["failed"] += 1
        elif result.startswith("skipped"):
            summary["skipped"] += 1
        else:
            summary["other"] += 1
        for key in ("new", "updated", "removed"):
            if row.get(key) is None:
                summary["changes_known"] = False
            else:
                summary[key] += row[key]
        summary["deferred"] += row["deferred_active"] + row["skipped_changed"]
        if row["started"] and (not summary["started"] or row["started"] < summary["started"]):
            summary["started"] = row["started"]
        if row["ended"] and row["ended"] > summary["ended"]:
            summary["ended"] = row["ended"]
    if summary["failed"]:
        summary["outcome"] = "failed"
    elif summary["other"]:
        summary["outcome"] = "attention"
    elif summary["synced"] and summary["deferred"]:
        summary["outcome"] = "synced-with-skips"
    elif summary["synced"]:
        summary["outcome"] = "synced"
    elif summary["skipped"]:
        summary["outcome"] = "skipped"
    else:
        summary["outcome"] = "unknown"
    return summary


def rows_by_entry():
    rows, truncated = read_project_history()
    legacy = False
    if not rows:
        rows = legacy_project_rows()
        legacy = bool(rows)
    grouped = {}
    for row in rows:
        grouped.setdefault(row["entry"], []).append(row)
    return grouped, legacy, truncated


def entry_overview(entry, entry_rows, deferrals, current):
    """The card for one entry: last run, last success, changes, deferrals, running now."""
    runs = {}
    for row in entry_rows:
        runs.setdefault(row["run"], []).append(row)
    run_keys = sorted(runs)
    last = summarize_rows(runs[run_keys[-1]]) if run_keys else None
    if last:
        last["run"] = run_keys[-1]
    last_success = ""
    for key in reversed(run_keys):
        if any(row["result"] in SYNCED_RESULTS for row in runs[key]):
            last_success = max((row["ended"] or key) for row in runs[key] if row["result"] in SYNCED_RESULTS)
            break
    last_change = ""
    for row in reversed(entry_rows):
        if (row.get("new") or 0) + (row.get("updated") or 0) + (row.get("removed") or 0) > 0:
            last_change = row["ended"] or row["run"]
            break
    keys = {row["key"] for row in entry_rows if row["key"]}
    changing = sum(deferrals.get(key, (0, 0))[0] for key in keys)
    never_settles = sum(deferrals.get(key, (0, 0))[1] for key in keys)
    overview = dict(entry)
    overview.update({
        "last_run": last, "last_success": last_success, "last_change": last_change, "runs_recorded": len(run_keys),
        "changing_files": changing, "never_settles": never_settles,
        "running": bool(current["running"] and current["current_entry"] == entry["name"]),
        "current_project": current["current_project"] if current["running"] and current["current_entry"] == entry["name"] else "",
    })
    return overview


def load_entries():
    if not os.path.isfile(SOURCES_FILE):
        raise ControlError("not_found", "Source config not found: %s" % SOURCES_FILE)
    text, _ = read_text(SOURCES_FILE)
    return [describe_entry(row) for row in parse_sources(text)]


def verb_jobs(request):
    get_args(request, [])
    entries = load_entries()
    grouped, legacy, truncated = rows_by_entry()
    deferrals, max_deferrals = deferral_counts()
    current = run_state()
    cards = [entry_overview(entry, grouped.get(entry["name"], []), deferrals, current) for entry in entries]
    for card in cards:
        if card["isolation"] == "children" and card["source_exists"]:
            try:
                card["children"] = sum(1 for name in os.listdir(card["source"]) if os.path.isdir(os.path.join(card["source"], name)))
            except OSError:
                card["children"] = None
        else:
            card["children"] = None
    return {"jobs": cards, "sha256": file_sha256(os.path.realpath(SOURCES_FILE)), "run": current, "legacy": legacy, "history_truncated": truncated,
            "max_deferrals": max_deferrals, "remote_base": REMOTE_BASE, "archive_folder": ARCHIVE_FOLDER, "retention": RETENTION}


def find_entry(args):
    name = args.get("name")
    if not isinstance(name, str) or not LABEL_RE.match(name):
        invalid("name must be a job name (its label, or its source path) from file-sources.conf.")
    for entry in load_entries():
        if entry["name"] == name:
            return entry
    raise ControlError("not_found", "No backup job named %s in file-sources.conf." % name)


def read_changes_header(key):
    path = state_path("projects", "changes", "%s.tsv" % key)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            first = handle.readline().strip()
    except OSError:
        return None
    match = re.match(r"^# run=(\S+) project=.* new=([0-9]+) updated=([0-9]+) removed=([0-9]+)$", first)
    if not match:
        return None
    return {"run": match.group(1), "new": int(match.group(2)), "updated": int(match.group(3)), "removed": int(match.group(4))}


def pattern_files(source, filename, limit=200, seconds=5):
    """The exclude or volatile definition files under an entry's source."""
    files = []
    truncated = False
    deadline = time.monotonic() + seconds
    for directory, subdirs, names in os.walk(source):
        subdirs[:] = [name for name in subdirs if name not in (".git", "node_modules", "vendor")]
        if filename in names:
            path = os.path.join(directory, filename)
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as handle:
                    lines = [line.rstrip("\n") for index, line in enumerate(handle) if index < 200]
                files.append({"path": path, "relative": os.path.relpath(path, source), "lines": lines})
            except OSError:
                continue
        if len(files) >= limit or time.monotonic() > deadline:
            truncated = True
            break
    return files, truncated


def verb_job(request):
    args = get_args(request, ["name"])
    entry = find_entry(args)
    grouped, legacy, truncated = rows_by_entry()
    entry_rows = grouped.get(entry["name"], [])
    deferrals, max_deferrals = deferral_counts()
    current = run_state()
    overview = entry_overview(entry, entry_rows, deferrals, current)

    by_project = {}
    for row in entry_rows:
        by_project.setdefault(row["project"], []).append(row)
    present, children_truncated = entry_projects(entry)
    projects = []
    seen = set()
    for label, path, destination, stop in present:
        seen.add(label)
        history_rows = by_project.get(label, [])
        last = history_rows[-1] if history_rows else None
        # The key the backup recorded (it is what active-files and changes use);
        # the key from the current config only for a project never recorded.
        key = (last["key"] if last and last["key"] else "") or (destination_key(destination) if destination else "")
        last_success = next((row["ended"] or row["run"] for row in reversed(history_rows) if row["result"] in SYNCED_RESULTS), "")
        changing, stale = deferrals.get(key, (0, 0))
        projects.append({"project": label, "name": os.path.basename(path), "source": path, "destination": destination, "key": key,
                         "stop_file_present": stop, "exists": True, "last": last, "last_success": last_success,
                         "runs": len(history_rows), "changing_files": changing, "never_settles": stale,
                         "changes": read_changes_header(key) if key else None,
                         "running": current["running"] and current["current_project"] == label})
    for label, history_rows in by_project.items():
        if label in seen or label == entry["name"]:
            continue
        last = history_rows[-1]
        projects.append({"project": label, "name": label.split("/")[-1], "source": last["source"], "destination": last["destination"],
                         "key": last["key"], "stop_file_present": False, "exists": False, "last": last,
                         "last_success": next((row["ended"] or row["run"] for row in reversed(history_rows) if row["result"] in SYNCED_RESULTS), ""),
                         "runs": len(history_rows), "changing_files": 0, "never_settles": 0,
                         "changes": read_changes_header(last["key"]) if last["key"] else None, "running": False})

    runs = {}
    for row in entry_rows:
        runs.setdefault(row["run"], []).append(row)
    run_list = []
    for key in sorted(runs, reverse=True)[:ENTRY_RUNS_KEEP]:
        summary = summarize_rows(runs[key])
        summary["run"] = key
        summary["results"] = [{"project": row["project"], "result": row["result"], "new": row["new"], "updated": row["updated"],
                               "removed": row["removed"], "deferred": row["deferred_active"] + row["skipped_changed"],
                               "started": row["started"], "ended": row["ended"]} for row in runs[key]]
        run_list.append(summary)

    keys = {project["key"] for project in projects if project["key"]}
    changing_rows = []
    directory = state_path("active-files")
    for key in sorted(keys):
        path = os.path.join(directory, "%s.tsv" % key)
        project = next((item["project"] for item in projects if item["key"] == key), "")
        try:
            stat = os.stat(path)
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                for line in handle:
                    parts = line.rstrip("\n").split("\t", 1)
                    if len(parts) == 2 and parts[0].isdigit():
                        changing_rows.append({"project": project, "path": parts[1], "count": int(parts[0]),
                                              "updated": datetime.datetime.fromtimestamp(stat.st_mtime, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")})
        except OSError:
            continue
    changing_rows.sort(key=lambda row: -row["count"])

    excludes, excludes_truncated = pattern_files(entry["source"], EXCLUDE_FILENAME) if entry["source_exists"] else ([], False)
    volatile, volatile_truncated = pattern_files(entry["source"], VOLATILE_FILENAME) if entry["source_exists"] else ([], False)

    # Where this entry comes in a run: its projects' start offsets in the last run
    # that synced it, for an estimate of when the next run reaches it.
    position = None
    if run_list:
        last_run = run_list[0]
        run_epoch = to_epoch(last_run["run"])
        starts = [to_epoch(item["started"]) for item in last_run["results"] if item["started"]]
        ends = [to_epoch(item["ended"]) for item in last_run["results"] if item["ended"]]
        starts = [value for value in starts if value]
        ends = [value for value in ends if value]
        if run_epoch and starts and ends:
            position = {"offset_s": int(min(starts) - run_epoch), "duration_s": int(max(ends) - min(starts))}

    return {"entry": overview, "sha256": file_sha256(os.path.realpath(SOURCES_FILE)),
            "patterns": verb_job_get_patterns(entry["label"]), "project_patterns": job_project_patterns(entry["label"]), "roots": job_source_roots(), "projects": projects, "children_truncated": children_truncated, "runs": run_list,
            "changing": changing_rows[:2000], "max_deferrals": max_deferrals, "run": current, "legacy": legacy,
            "history_truncated": truncated, "position": position,
            "excludes": {"filename": EXCLUDE_FILENAME, "files": excludes, "truncated": excludes_truncated, "global": GLOBAL_EXCLUDES},
            "volatile": {"filename": VOLATILE_FILENAME, "files": volatile, "truncated": volatile_truncated, "global": GLOBAL_VOLATILE},
            "active_window_s": int(ENV.get("BSC_ACTIVE_WINDOW", "120") or 120)}


def verb_job_changes(request):
    args = get_args(request, ["name", "project"])
    entry = find_entry(args)
    project = args.get("project")
    if not isinstance(project, str) or not LABEL_RE.match(project):
        invalid("project must be a project of this job.")
    rows, _ = read_project_history()
    key = next((row["key"] for row in reversed(rows) if row["entry"] == entry["name"] and row["project"] == project and row["key"]), "")
    if not key:
        present, _ = entry_projects(entry)
        destination = next((dest for label, _, dest, _ in present if label == project), "")
        if not destination:
            raise ControlError("not_found", "No project %s in job %s." % (project, entry["name"]))
        key = destination_key(destination)
    text, truncated = read_text(state_path("projects", "changes", "%s.tsv" % key), 2 * 1024 * 1024)
    header = None
    files = []
    note = ""
    for line in text.splitlines():
        if line.startswith("# run="):
            header = read_changes_header(key)
        elif line.startswith("# truncated"):
            note = line[2:]
        elif "\t" in line and len(files) < CHANGES_LINES_MAX:
            kind, path = line.split("\t", 1)
            files.append({"kind": kind, "path": path})
    return {"project": project, "key": key, "header": header, "files": files, "note": note, "truncated": truncated}


def verb_job_log(request):
    args = get_args(request, ["name", "run"])
    entry = find_entry(args)
    text, _ = read_text(state_path("logs", "backup-file.log"), 8 * 1024 * 1024)
    lines, starts = log_runs(text)
    if not starts:
        return {"run": None, "lines": [], "truncated": False}
    chosen = len(starts) - 1
    wanted = args.get("run", "latest")
    if wanted != "latest":
        if not isinstance(wanted, str) or len(wanted) > 40:
            invalid("run must be 'latest' or a start time.")
        wanted_epoch = to_epoch(wanted)
        if wanted_epoch is None:
            invalid("run must be 'latest' or a start time like 2026-10-14T16:05:00Z.")
        best = None
        for index, (start, _) in enumerate(starts):
            start_epoch = to_epoch(start)
            if start_epoch is not None and abs(start_epoch - wanted_epoch) <= 180 and (best is None or abs(start_epoch - wanted_epoch) < best[0]):
                best = (abs(start_epoch - wanted_epoch), index)
        if best is None:
            raise ControlError("not_found", "No run in the durable log started near %s." % wanted)
        chosen = best[1]
    first = starts[chosen][1]
    last = starts[chosen + 1][1] if chosen + 1 < len(starts) else len(lines)
    prefix = entry["name"]
    own = []
    inside = False
    for line in lines[first:last]:
        match = re.match(r"^Syncing label='(.*)' source=", line)
        if match:
            inside = match.group(1) == prefix or match.group(1).startswith(prefix + "/")
        elif line.startswith(("Skipping source '%s'" % entry["source"], "Skipping isolated project '%s/" % entry["source"].rstrip("/"))):
            own.append(line)
            continue
        elif line.startswith(("Run summary:", "File backup finished", "Cleaning archived")):
            inside = False
        if inside:
            own.append(line)
    truncated = len(own) > MAX_LOG_LINES
    return {"run": starts[chosen][0], "lines": own[-MAX_LOG_LINES:], "truncated": truncated}


MEASURE_SECONDS = 90


def measure_source(path):
    files = directories = size = 0
    deadline = time.monotonic() + MEASURE_SECONDS - 10
    complete = True
    for directory, subdirs, names in os.walk(path):
        directories += 1
        for name in names:
            try:
                size += os.lstat(os.path.join(directory, name)).st_size
                files += 1
            except OSError:
                continue
        if time.monotonic() > deadline:
            complete = False
            break
    return {"files": files, "directories": directories, "bytes": size, "complete": complete}


def verb_job_measure(request):
    args = get_args(request, ["name", "what"])
    entry = find_entry(args)
    what = choice(args, "what", ["source", "destination"])
    if what == "source":
        if not entry["source_exists"]:
            raise ControlError("not_found", "The source directory does not exist.")
        result = measure_source(entry["source"])
        result["note"] = "Everything under the source, before excludes and stop files."
        return {"what": what, "path": entry["source"], "result": result, "at": now_iso()}
    if not entry["destination"]:
        raise ControlError("not_found", "This job has no destination.")
    command = [RCLONE_BIN, "size", "--json", entry["destination"]]
    if RCLONE_CONFIG:
        command += ["--config", RCLONE_CONFIG]
    code, out, err = run(command, MEASURE_SECONDS)
    if code != 0:
        raise ControlError("remote_error", (err or out).strip()[-500:] or "rclone size failed.")
    try:
        measured = json.loads(out)
    except ValueError:
        raise ControlError("remote_error", "rclone size returned no JSON.")
    listing = []
    command = [RCLONE_BIN, "lsjson", "--max-depth", "1", "--no-mimetype", entry["destination"]]
    if RCLONE_CONFIG:
        command += ["--config", RCLONE_CONFIG]
    try:
        code, out, err = run(command, 30)
        if code == 0:
            for item in json.loads(out)[:500]:
                listing.append({"name": item.get("Name", ""), "dir": bool(item.get("IsDir")), "size": item.get("Size"),
                                "modified": item.get("ModTime", "")})
    except (ControlError, ValueError):
        pass
    listing.sort(key=lambda item: (not item["dir"], item["name"].lower()))
    return {"what": what, "path": entry["destination"], "at": now_iso(),
            "result": {"files": measured.get("count"), "bytes": measured.get("bytes"), "complete": True,
                       "note": "Current files only; replaced and deleted versions are kept apart under %s for %s." % (ARCHIVE_FOLDER, RETENTION)},
            "listing": listing}


# --------------------------------------------------------------------------- job changes
#
# Add, edit, enable, disable and remove backup jobs (lines of file-sources.conf),
# each job's own exclude and volatile patterns (CONFIG_DIR/jobs/<name>.excludes and
# .volatile, applied to every project of the job), and "back up this job now".
#
# A job may only back up a folder under FILE_JOB_SOURCE_ROOTS (set in global.conf by
# the server's administrator; the GUI cannot change it), and never a system folder or
# Backup Suite's own config and state: in system mode the backup runs as root, so a
# job could otherwise upload any file on the server.

JOB_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")
JOB_DESTINATION_MODES = ["fixed", "same-name", "default-root", "remote"]
JOB_ISOLATIONS = ["single", "children"]
JOB_PATTERN_RE = re.compile(r"^[^\x00-\x1f|]{1,300}$")
JOB_PATTERNS_MAX = 500
JOB_REQUEST_MAX_AGE = 600
JOBS_CONFIG_DIR = os.path.join(ENV.get("BSC_CONFIG_DIR", ""), "jobs")
SYSTEM_FOLDERS = ["/bin", "/boot", "/dev", "/etc", "/lib", "/lib32", "/lib64", "/libx32", "/proc", "/root", "/run", "/sbin",
                  "/snap", "/sys", "/usr", "/var/cache", "/var/lib", "/var/log", "/lost+found"]


def path_within(path, folder):
    folder = folder.rstrip("/") or "/"
    return path == folder or path.startswith(folder + "/") or folder == "/"


def job_source_roots():
    values = parse_global_config(os.path.realpath(GLOBAL_CONFIG_FILE)) if GLOBAL_CONFIG_FILE else {}
    text = values.get("FILE_JOB_SOURCE_ROOTS", DEFAULT_JOB_SOURCE_ROOTS)
    roots = []
    for part in re.split(r"[\s:|,]+", text):
        if part.startswith("/") and part != "/":
            roots.append(os.path.realpath(part))
    return roots


def protected_folders():
    folders = list(SYSTEM_FOLDERS)
    for path in (STATE_DIR, ENV.get("BSC_CONFIG_DIR", ""), os.path.dirname(BIN_DIR.rstrip("/")),
                 os.path.dirname(os.path.realpath(GLOBAL_CONFIG_FILE)) if GLOBAL_CONFIG_FILE else ""):
        if path and path != "/":
            folders.append(os.path.realpath(path))
    return folders


def job_pattern_path(name, kind):
    return os.path.join(JOBS_CONFIG_DIR, "%s.%s" % (name, kind))


def read_job_patterns(name, kind):
    if not JOB_NAME_RE.match(name or ""):
        return []
    try:
        with open(job_pattern_path(name, kind), "r", encoding="utf-8", errors="replace") as handle:
            return [line.strip() for index, line in enumerate(handle)
                    if index <= JOB_PATTERNS_MAX and line.strip() and not line.lstrip().startswith("#")]
    except OSError:
        return []


def job_draft(args):
    """The job fields from a request, as strings and lists, before any check."""
    draft = args.get("job")
    if not isinstance(draft, dict):
        invalid("job must be an object.")
    unknown = set(draft) - {"enabled", "label", "source", "destination_mode", "destination_value", "stop_file", "isolation",
                            "excludes", "volatile"}
    if unknown:
        invalid("Unknown job field(s): %s" % ", ".join(sorted(unknown)))
    fields = {}
    for key in ("label", "source", "destination_mode", "destination_value", "stop_file", "isolation"):
        value = draft.get(key, "")
        if not isinstance(value, str) or len(value) > 1024:
            invalid("%s must be text." % key)
        fields[key] = value.strip()
    enabled = draft.get("enabled", True)
    if not isinstance(enabled, bool):
        invalid("enabled must be true or false.")
    fields["enabled"] = enabled
    for key in ("excludes", "volatile"):
        value = draft.get(key, [])
        if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
            invalid("%s must be a list of patterns." % key)
        fields[key] = [item.strip() for item in value if item.strip()]
    return fields


def check_job(fields, rows, editing=None):
    """Returns (problems, warnings, info) for a draft job. `editing` is the row being
    edited (it does not conflict with itself)."""
    problems = []
    warnings = []
    others = [row for row in rows if editing is None or row["line"] != editing["line"]]
    name = fields["label"]
    if not JOB_NAME_RE.match(name):
        problems.append("Name: 1 to 64 letters, digits, dots, dashes or underscores, starting with a letter or digit.")
    elif any((row["label"] or row["source"]) == name for row in others):
        problems.append("Another job is already named %s." % name)

    source = fields["source"]
    real_source = ""
    if not source.startswith("/") or "|" in source or any(ord(character) < 32 for character in source):
        problems.append("Source: an absolute folder path (starting with /), without |.")
    else:
        source = os.path.normpath(source)
        fields["source"] = source
        real_source = os.path.realpath(source)
        if not os.path.isdir(real_source):
            problems.append("Source: %s is not an existing folder on this server." % source)
        roots = job_source_roots()
        if not any(path_within(real_source, root) for root in roots):
            problems.append("Source: only folders under %s may be backed up (FILE_JOB_SOURCE_ROOTS in global.conf, set on the server)." % ", ".join(roots or ["(none)"]))
        for folder in protected_folders():
            if path_within(real_source, folder) or (folder.startswith(real_source.rstrip("/") + "/") and real_source != "/"):
                problems.append("Source: %s holds system or Backup Suite files (%s) and cannot be backed up by a job." % (source, folder))
                break
        for row in others:
            other = os.path.realpath(row["source"]) if row["source"] else ""
            if other and (path_within(real_source, other) or path_within(other, real_source)):
                warnings.append("The source overlaps job %s (%s): those files are backed up twice." % (row["label"] or row["source"], row["source"]))

    mode = fields["destination_mode"] or "fixed"
    fields["destination_mode"] = mode
    value = fields["destination_value"]
    if mode not in JOB_DESTINATION_MODES:
        problems.append("Destination mode: fixed, same-name, default-root or remote.")
    elif mode == "remote":
        match = REMOTE_VALUE_RE.match(value)
        if not match:
            problems.append("Destination: pick a destination and a folder on it (remote:folder, e.g. dropbox:backups/web10).")
        else:
            try:
                remote_settings = rclone_dump().get(match.group(1))
            except ControlError as error:
                remote_settings = None
                problems.append("Destination: %s" % error.message)
            if remote_settings is None:
                problems.append("Destination: there is no destination named %s (Admin → Destinations)." % match.group(1))
            elif remote_settings.get("type") not in REMOTE_TYPES:
                problems.append("Destination: %s is a %s remote, which jobs cannot use from the GUI." % (match.group(1), remote_settings.get("type")))
        value = "%s:%s" % (match.group(1), match.group(2).strip("/")) if match else value
        fields["destination_value"] = value
    elif mode == "fixed" and not value:
        problems.append("Destination: fixed mode needs a folder, e.g. projects/%s." % (name or "my-job"))
    if mode == "same-name":
        value = ""
        fields["destination_value"] = ""
    if mode != "remote":
        if value and (not re.fullmatch(r"[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*", value.strip("/")) or ".." in value.split("/")):
            problems.append("Destination: a relative folder of letters, digits, . _ - and /, e.g. sites/web10.")
        fields["destination_value"] = value.strip("/") if value else ""

    stop = fields["stop_file"]
    if stop and (not re.fullmatch(r"[A-Za-z0-9._-]{1,64}", stop) or stop in (".", "..")):
        problems.append("Stop file: a single file name such as .nosync.")
    isolation = fields["isolation"] or "single"
    fields["isolation"] = isolation
    if isolation not in JOB_ISOLATIONS:
        problems.append("Projects: single or children.")
    for key in ("excludes", "volatile"):
        if len(fields[key]) > JOB_PATTERNS_MAX:
            problems.append("At most %d %s patterns." % (JOB_PATTERNS_MAX, key))
        bad = [item for item in fields[key] if not JOB_PATTERN_RE.match(item)]
        if bad:
            problems.append("%s pattern %r: up to 300 characters, without |." % (key.capitalize(), bad[0][:40]))

    row = {"enabled": "1" if fields["enabled"] else "0", "label": name, "source": source, "destination_mode": mode,
           "destination_value": fields["destination_value"], "stop_file": stop, "isolation": isolation, "extra_fields": False,
           "source_exists": bool(real_source) and os.path.isdir(real_source), "line": editing["line"] if editing else 0}
    relative = entry_destination_relative(row) if mode in JOB_DESTINATION_MODES else ""
    base = entry_base(row)
    destination = join_path(base, relative) if relative and base else ""
    if relative:
        for other_row in others:
            other_relative = entry_destination_relative(other_row)
            if entry_base(other_row) != base:
                continue
            if other_relative and (other_relative == relative or other_relative.startswith(relative + "/") or relative.startswith(other_relative + "/")):
                problems.append("Destination %s overlaps job %s (%s): two jobs would overwrite each other's files." % (relative, other_row["label"] or other_row["source"], other_relative))
    projects = None
    if row["source_exists"] and isolation == "children":
        try:
            projects = sum(1 for item in os.listdir(real_source) if os.path.isdir(os.path.join(real_source, item)))
        except OSError:
            projects = None
        if projects == 0:
            warnings.append("The source has no child folders yet: with children, each child folder is one project.")
    elif row["source_exists"]:
        projects = 1
    line = "|".join([row["enabled"], name, source, mode, fields["destination_value"], stop, isolation])
    info = {"line": line, "destination": destination, "destination_relative": relative, "projects": projects,
            "real_source": real_source, "roots": job_source_roots()}
    return problems, warnings, info


def require_sources_sha(args):
    expect = args.get("expect_sha")
    if not isinstance(expect, str) or not re.fullmatch(r"[0-9a-f]{64}", expect):
        invalid("expect_sha is required.")
    path = os.path.realpath(SOURCES_FILE)
    if not os.path.isfile(path):
        raise ControlError("not_found", "Source config not found: %s" % SOURCES_FILE)
    if file_sha256(path) != expect:
        raise ControlError("config_conflict", "file-sources.conf changed since it was read; reload and try again.")
    return path


def backup_file(path, name):
    backups = os.path.join(gui_dir(), "config-backups")
    os.makedirs(backups, mode=0o750, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    target = os.path.join(backups, "%s.%s" % (name, stamp))
    if os.path.isfile(path):
        shutil.copy2(path, target)
        os.chmod(target, 0o600)
    existing = sorted(item for item in os.listdir(backups) if item.startswith(name + "."))
    for item in existing[:-CONFIG_BACKUPS_KEEP]:
        try:
            os.remove(os.path.join(backups, item))
        except OSError:
            pass
    return target


def rewrite_sources(path, replace_line=None, new_line=None):
    """Replaces (or with new_line None removes) line number replace_line, or appends
    new_line. Rewrites in place: keeps the inode, owner, mode and any symlink."""
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
        lines = handle.read().splitlines()
    if replace_line is not None:
        if not 1 <= replace_line <= len(lines):
            raise ControlError("config_conflict", "file-sources.conf changed since it was read; reload and try again.")
        if new_line is None:
            del lines[replace_line - 1]
        else:
            lines[replace_line - 1] = new_line
    else:
        lines.append(new_line)
    with open(path, "r+", encoding="utf-8", errors="surrogateescape") as handle:
        handle.seek(0)
        handle.write("\n".join(lines) + "\n")
        handle.truncate()


def write_job_patterns(name, kind, patterns):
    path = job_pattern_path(name, kind)
    if not patterns:
        try:
            os.remove(path)
        except OSError:
            pass
        return
    os.makedirs(JOBS_CONFIG_DIR, mode=0o750, exist_ok=True)
    temporary = "%s.tmp.%d" % (path, os.getpid())
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write("# Written by the Backup Suite GUI: patterns for every project of job %s.\n" % name)
        handle.write("\n".join(patterns) + "\n")
    os.chmod(temporary, 0o640)
    os.replace(temporary, path)


def sources_rows():
    text, _ = read_text(SOURCES_FILE)
    return parse_sources(text)


def find_row(rows, name):
    if not isinstance(name, str) or not LABEL_RE.match(name):
        invalid("name must be a job name from file-sources.conf.")
    for row in rows:
        if (row["label"] or row["source"]) == name:
            return row
    raise ControlError("not_found", "No backup job named %s in file-sources.conf." % name)


def verb_job_check(request):
    args = get_args(request, ["name", "job"])
    fields = job_draft(args)
    rows = sources_rows()
    editing = find_row(rows, args["name"]) if args.get("name") else None
    problems, warnings, info = check_job(fields, rows, editing)
    return {"problems": problems, "warnings": warnings, "info": info, "job": fields}


def verb_job_get_patterns(name):
    return {"excludes": read_job_patterns(name, "excludes"), "volatile": read_job_patterns(name, "volatile")}


def verb_job_save(request):
    args = get_args(request, ["name", "job", "expect_sha"])
    path = require_sources_sha(args)
    fields = job_draft(args)
    rows = sources_rows()
    editing = find_row(rows, args["name"]) if args.get("name") else None
    problems, warnings, info = check_job(fields, rows, editing)
    if problems:
        invalid(" ".join(problems))
    backup = backup_file(path, "file-sources.conf")
    rewrite_sources(path, editing["line"] if editing else None, info["line"])
    name = fields["label"]
    old_name = (editing["label"] or editing["source"]) if editing else None
    for kind in ("excludes", "volatile"):
        write_job_patterns(name, kind, fields[kind])
        if old_name and old_name != name and JOB_NAME_RE.match(old_name):
            try:
                os.remove(job_pattern_path(old_name, kind))
            except OSError:
                pass
    old_projects = os.path.join(JOBS_CONFIG_DIR, "%s.projects" % old_name) if old_name and JOB_NAME_RE.match(old_name) else ""
    if old_name and old_name != name and old_projects and os.path.isdir(old_projects):
        new_projects = os.path.join(JOBS_CONFIG_DIR, "%s.projects" % name)
        if os.path.isdir(new_projects):
            shutil.rmtree(new_projects)
        os.rename(old_projects, new_projects)
    action = "edited" if editing else "added"
    record_event("info", "gui-action", "Backup job %s %s" % (name, action), info["line"], "")
    return {"sha256": file_sha256(path), "backup": backup, "line": info["line"], "name": name, "warnings": warnings,
            "action": action, "renamed_from": old_name if old_name and old_name != name else None}


def verb_job_enable(request):
    args = get_args(request, ["name", "enabled", "expect_sha"])
    if not isinstance(args.get("enabled"), bool):
        invalid("enabled must be true or false.")
    path = require_sources_sha(args)
    row = find_row(sources_rows(), args.get("name"))
    with open(path, "r", encoding="utf-8", errors="surrogateescape") as handle:
        original = handle.read().splitlines()[row["line"] - 1]
    parts = original.split("|")
    parts[0] = "1" if args["enabled"] else "0"
    backup = backup_file(path, "file-sources.conf")
    rewrite_sources(path, row["line"], "|".join(parts))
    name = row["label"] or row["source"]
    record_event("info", "gui-action", "Backup job %s %s" % (name, "enabled" if args["enabled"] else "disabled"), "", "")
    return {"sha256": file_sha256(path), "backup": backup, "name": name, "enabled": args["enabled"]}


def verb_job_remove(request):
    args = get_args(request, ["name", "expect_sha"])
    path = require_sources_sha(args)
    row = find_row(sources_rows(), args.get("name"))
    name = row["label"] or row["source"]
    backup = backup_file(path, "file-sources.conf")
    rewrite_sources(path, row["line"], None)
    for kind in ("excludes", "volatile"):
        if JOB_NAME_RE.match(name) and os.path.isfile(job_pattern_path(name, kind)):
            backup_file(job_pattern_path(name, kind), "job-%s.%s" % (name, kind))
            os.remove(job_pattern_path(name, kind))
    projects_dir = os.path.join(JOBS_CONFIG_DIR, "%s.projects" % name)
    if JOB_NAME_RE.match(name) and os.path.isdir(projects_dir):
        for child, patterns in job_project_patterns(name).items():
            backup_file(job_project_pattern_path(name, child, "excludes"), "job-%s.project-excludes" % name)
        shutil.rmtree(projects_dir)
    record_event("warning", "gui-action", "Backup job %s removed" % name,
                 "Its line was removed from file-sources.conf. Nothing was deleted on the remote.", "")
    return {"sha256": file_sha256(path), "backup": backup, "name": name}


def verb_job_run(request):
    args = get_args(request, ["name"])
    row = find_row(sources_rows(), args.get("name"))
    name = row["label"] or row["source"]
    if not is_enabled_value(row["enabled"]):
        raise ControlError("invalid_request", "Job %s is disabled; enable it first." % name)
    if describe_entry(row)["problem"]:
        raise ControlError("invalid_request", "Job %s has a problem: %s" % (name, describe_entry(row)["problem"]))
    code, out, _ = systemctl("show", "file-backup.service", "-p", "Id,ActiveState")
    active = parse_show_blocks(out).get("file-backup.service", {}).get("ActiveState", "") if code == 0 else ""
    if active in ("active", "activating", "deactivating", "reloading"):
        raise ControlError("busy", "A file backup is running; this job can run once it has finished.")
    run_dir = state_path("run")
    os.makedirs(run_dir, mode=0o750, exist_ok=True)
    request_path = os.path.join(run_dir, "job-request.env")
    temporary = request_path + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write("jobs=%s\nrequested_at=%d\nrequested_by=%s\n" % (name, int(time.time()), CALLER_LOGIN or CALLER_UID))
    os.chmod(temporary, 0o640)
    os.replace(temporary, request_path)
    code, out, err = systemctl("start", "--no-block", "file-backup.service", timeout=CHANGE_TIMEOUT)
    if code != 0:
        try:
            os.remove(request_path)
        except OSError:
            pass
        raise ControlError("action_failed", (err or out).strip()[-500:] or "systemctl start failed.")
    record_event("info", "gui-action", "Backup of job %s started" % name, "Only this job runs; the watchdog and the resource profile apply as usual.", "file-backup.service")
    return {"name": name, "started": True}


# --------------------------------------------------------------------------- excluding a file or folder
#
# From the Changing files list: exclude one path (a file, or a folder and all it
# holds) for one project of a job, or for every project of the job. The patterns
# live in Backup Suite's config, never in the project's own folder:
#   CONFIG_DIR/jobs/<job>.excludes                          every project of the job
#   CONFIG_DIR/jobs/<job>.projects/<child folder>.excludes  one child project
# file-backup.sh applies both (relative to the project's folder) from the next run.

EXCLUDE_GLOB_CHARS = "\\*?[]{}"


def job_project_pattern_path(name, child, kind):
    return os.path.join(JOBS_CONFIG_DIR, "%s.projects" % name, "%s.%s" % (child, kind))


def read_pattern_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return [line.strip() for index, line in enumerate(handle)
                    if index < JOB_PATTERNS_MAX + 1 and line.strip() and not line.lstrip().startswith("#")]
    except OSError:
        return []


def write_pattern_file(path, header, patterns):
    if not patterns:
        try:
            os.remove(path)
        except OSError:
            pass
        return
    os.makedirs(os.path.dirname(path), mode=0o750, exist_ok=True)
    temporary = "%s.tmp.%d" % (path, os.getpid())
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write("# Written by the Backup Suite GUI: %s.\n" % header)
        handle.write("\n".join(patterns) + "\n")
    os.chmod(temporary, 0o640)
    os.replace(temporary, path)


def job_project_patterns(name):
    """{child folder: [exclude patterns]} for a job's per-project files."""
    result = {}
    if not JOB_NAME_RE.match(name or ""):
        return result
    directory = os.path.join(JOBS_CONFIG_DIR, "%s.projects" % name)
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return result
    for item in names:
        if item.endswith(".excludes"):
            patterns = read_pattern_file(os.path.join(directory, item))
            if patterns:
                result[item[:-len(".excludes")]] = patterns
    return result


def exclude_pattern(path, folder):
    """The rclone filter pattern for one relative path: glob characters escaped,
    and a folder excluded with everything below it."""
    escaped = "".join("\\" + char if char in EXCLUDE_GLOB_CHARS else char for char in path)
    return escaped + "/**" if folder else escaped


def check_exclude_path(value):
    if not isinstance(value, str):
        invalid("path must be text.")
    path = value.strip().strip("/")
    parts = path.split("/")
    if not path or len(path) > 300 or any(part in ("", ".", "..") for part in parts) or re.search(r"[\x00-\x1f|]", path):
        invalid("path must be a path inside the project, such as .ai-metadata/lifecycle/state.json.")
    return path


def entry_project_keys(entry, child=None):
    """The state keys (active-files/<key>.tsv) of a job's projects, or of one child."""
    grouped, _, _ = rows_by_entry()
    last_key = {}
    for row in grouped.get(entry["name"], []):
        if row["key"]:
            last_key[row["project"]] = row["key"]
    present, _ = entry_projects(entry)
    keys = []
    for label, path, destination, _ in present:
        if child is not None and os.path.basename(path) != child:
            continue
        key = last_key.get(label) or (destination_key(destination) if destination else "")
        if key:
            keys.append(key)
    return keys


def prune_changing_paths(keys, path, folder):
    """Drops the excluded path from the changing-files lists now; the next run
    would drop it anyway, as excluded files are no longer scanned."""
    removed = 0
    directory = state_path("active-files")
    for key in keys:
        state_file = os.path.join(directory, "%s.tsv" % key)
        try:
            with open(state_file, "r", encoding="utf-8", errors="surrogateescape") as handle:
                lines = handle.read().splitlines()
        except OSError:
            continue
        kept = []
        for line in lines:
            parts = line.split("\t", 1)
            listed = parts[1] if len(parts) == 2 else ""
            if listed == path or (folder and listed.startswith(path + "/")):
                removed += 1
            else:
                kept.append(line)
        if len(kept) == len(lines):
            continue
        if kept:
            temporary = "%s.tmp.%d" % (state_file, os.getpid())
            with open(temporary, "w", encoding="utf-8", errors="surrogateescape") as handle:
                handle.write("\n".join(kept) + "\n")
            os.chmod(temporary, 0o640)
            os.replace(temporary, state_file)
        else:
            os.remove(state_file)
    return removed


def verb_job_exclude(request):
    args = get_args(request, ["name", "path", "folder", "scope", "project", "remove", "pattern"])
    entry = find_entry(args)
    name = entry["label"]
    if not JOB_NAME_RE.match(name or ""):
        invalid("Give this job a name (label) in its editor first; excludes are kept per job name.")
    scope = args.get("scope", "job")
    if scope not in ("job", "project"):
        invalid("scope must be job or project.")
    child = None
    if scope == "project":
        if entry["isolation"] != "children":
            invalid("This job is one project; exclude for the whole job.")
        child = args.get("project")
        names = [os.path.basename(path) for _, path, _, _ in entry_projects(entry)[0]]
        if not isinstance(child, str) or "/" in child or child not in names:
            invalid("project must be one of this job's child folders.")
        target = job_project_pattern_path(name, child, "excludes")
        header = "excluded paths for project %s of job %s" % (child, name)
        backup_name = "job-%s.project-excludes" % name
    else:
        target = job_pattern_path(name, "excludes")
        header = "patterns for every project of job %s" % name
        backup_name = "job-%s.excludes" % name
    patterns = read_pattern_file(target)

    if args.get("remove"):
        pattern = args.get("pattern")
        if not isinstance(pattern, str) or pattern.strip() not in patterns:
            invalid("That pattern is not in this list.")
        backup_file(target, backup_name)
        patterns.remove(pattern.strip())
        write_pattern_file(target, header, patterns)
        record_event("info", "gui-action", "Exclude removed from job %s" % name,
                     "%s no longer excluded%s." % (pattern.strip(), " in %s" % child if child else " in every project"), "")
        return {"name": name, "scope": scope, "project": child, "pattern": pattern.strip(), "removed": True, "patterns": patterns}

    path = check_exclude_path(args.get("path"))
    folder = args.get("folder", False)
    if not isinstance(folder, bool):
        invalid("folder must be true or false.")
    pattern = exclude_pattern(path, folder)
    if not JOB_PATTERN_RE.match(pattern):
        invalid("This path cannot be written as a pattern.")
    added = pattern not in patterns
    if added:
        if len(patterns) >= JOB_PATTERNS_MAX:
            invalid("This list already has %d patterns." % JOB_PATTERNS_MAX)
        backup_file(target, backup_name)
        patterns.append(pattern)
        write_pattern_file(target, header, patterns)
    cleared = prune_changing_paths(entry_project_keys(entry, child), path, folder)
    where = "project %s" % child if child else "every project of the job"
    record_event("info", "gui-action", "Excluded from job %s" % name,
                 "%s %s is no longer backed up in %s (pattern %s)." % ("Folder" if folder else "File", path, where, pattern), "")
    return {"name": name, "scope": scope, "project": child, "pattern": pattern, "added": added, "cleared": cleared,
            "file": target, "patterns": patterns}


# --------------------------------------------------------------------------- destinations (rclone remotes)
#
# Set up where backups go without the rclone command line: list, create (rclone's
# own question-and-answer protocol: `config create --non-interactive`, then
# `config update --continue --state --result`), test, browse and delete remotes in
# rclone.conf.
#
# rclone runs as root in system mode, so only cloud and network remote types can be
# created (never local, alias, crypt, union and other types that reach local
# folders), and no option that reads a file or runs a command is accepted. Secrets
# (tokens, passwords, keys) are never returned.

REMOTE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")
REMOTE_TYPES = {
    "drive": "Google Drive", "dropbox": "Dropbox", "onedrive": "Microsoft OneDrive", "box": "Box", "pcloud": "pCloud",
    "s3": "Amazon S3 and compatible (Wasabi, MinIO, Cloudflare R2, …)", "b2": "Backblaze B2", "webdav": "WebDAV (Nextcloud, ownCloud, …)",
    "sftp": "SFTP server", "ftp": "FTP server", "mega": "MEGA", "azureblob": "Microsoft Azure Blob Storage",
    "google cloud storage": "Google Cloud Storage", "koofr": "Koofr", "jottacloud": "Jottacloud", "yandex": "Yandex Disk",
    "swift": "OpenStack Swift", "seafile": "Seafile", "hidrive": "HiDrive", "zoho": "Zoho WorkDrive",
}
REMOTE_DENIED_OPTION_RE = re.compile(r"(file$|_file|command|^ssh$|env_auth|key_use_agent|socket|^config_dir)", re.I)
REMOTE_SECRET_RE = re.compile(r"(token|secret|pass|key|credential|auth|cookie|session|sas|account$|^user$|client_id)", re.I)
REMOTE_TIMEOUT = 45


def rclone_command(*arguments):
    command = [RCLONE_BIN] + list(arguments)
    if RCLONE_CONFIG:
        command += ["--config", RCLONE_CONFIG]
    return command


def rclone_dump():
    code, out, err = run(rclone_command("config", "dump"), READ_TIMEOUT)
    if code != 0:
        raise ControlError("remote_error", (err or out).strip()[-300:] or "rclone config dump failed.")
    try:
        data = json.loads(out or "{}")
    except ValueError:
        raise ControlError("remote_error", "rclone config dump returned no JSON.")
    return data if isinstance(data, dict) else {}


def remote_root_name(spec):
    match = re.match(r"^([A-Za-z0-9_-]+)[,:]", spec or "")
    return match.group(1) if match else ""


def remote_usage():
    """{remote name: [what uses it]}: the global destination and jobs with their own remote."""
    usage = {}
    values = parse_global_config(os.path.realpath(GLOBAL_CONFIG_FILE)) if GLOBAL_CONFIG_FILE else {}
    root = remote_root_name(values.get("RCLONE_REMOTE_ROOT", ""))
    if root:
        usage.setdefault(root, []).append("the default destination (RCLONE_REMOTE_ROOT)")
    try:
        rows = sources_rows()
    except ControlError:
        rows = []
    for row in rows:
        if row["destination_mode"] == "remote":
            name = remote_root_name(row["destination_value"])
            if name:
                usage.setdefault(name, []).append("job %s" % (row["label"] or row["source"]))
    return usage


def safe_remote_settings(settings):
    shown = {}
    for key, value in settings.items():
        if key == "type":
            continue
        shown[key] = "[set]" if REMOTE_SECRET_RE.search(key) else str(value)[:200]
    return shown


def provider_options():
    """{type: [options a user fills in when creating it]} for the allowed types."""
    code, out, _ = run(rclone_command("config", "providers"), READ_TIMEOUT)
    if code != 0:
        return {}
    try:
        providers = json.loads(out)
    except ValueError:
        return {}
    options = {}
    for provider in providers:
        name = provider.get("Name")
        if name not in REMOTE_TYPES:
            continue
        fields = []
        for option in provider.get("Options") or []:
            if option.get("Advanced") or option.get("Hide") or REMOTE_DENIED_OPTION_RE.search(option.get("Name", "")):
                continue
            fields.append({"name": option.get("Name"), "help": (option.get("Help") or "")[:1500], "default": option.get("DefaultStr", ""),
                           "required": bool(option.get("Required")), "password": bool(option.get("IsPassword")),
                           "provider": option.get("Provider", ""), "type": option.get("Type", "string"),
                           "exclusive": bool(option.get("Exclusive")),
                           "examples": [{"value": example.get("Value", ""), "help": (example.get("Help") or "")[:200], "provider": example.get("Provider", "")}
                                        for example in (option.get("Examples") or [])[:60]]})
        options[name] = {"label": REMOTE_TYPES[name], "description": provider.get("Description", ""), "options": fields}
    return options


def verb_remotes(request):
    args = get_args(request, ["providers"])
    dump = rclone_dump()
    usage = remote_usage()
    remotes = []
    for name in sorted(dump):
        settings = dump[name] if isinstance(dump[name], dict) else {}
        kind = settings.get("type", "")
        remotes.append({"name": name, "type": kind, "type_label": REMOTE_TYPES.get(kind, kind), "allowed": kind in REMOTE_TYPES,
                        "settings": safe_remote_settings(settings), "used_by": usage.get(name, [])})
    reply = {"remotes": remotes, "config": RCLONE_CONFIG, "default_root": REMOTE_BASE, "default_remote": remote_root_name(REMOTE_BASE)}
    if args.get("providers"):
        reply["providers"] = provider_options()
    return reply


def wizard_path(name):
    directory = os.path.join(gui_dir(), "remote-wizard")
    os.makedirs(directory, mode=0o700, exist_ok=True)
    return os.path.join(directory, "%s.json" % name)


def wizard_reply(name, out, err, code):
    """One step of rclone's protocol: the next question, or done."""
    try:
        data = json.loads(out[out.index("{"):]) if "{" in out else {}
    except ValueError:
        data = {}
    if code != 0 and not data:
        raise ControlError("remote_error", (err or out).strip()[-500:] or "rclone config failed.")
    state_value = data.get("State") or ""
    option = data.get("Option") or {}
    error = data.get("Error") or ""
    if not state_value:
        try:
            os.remove(wizard_path(name))
        except OSError:
            pass
        return {"name": name, "done": True, "error": error}
    option_name = option.get("Name", "")
    with open(wizard_path(name), "w", encoding="utf-8") as handle:
        json.dump({"state": state_value, "option": option_name, "at": int(time.time())}, handle)
    return {"name": name, "done": False, "error": error, "state": state_value,
            "question": {"name": option_name, "help": (option.get("Help") or "")[:3000], "default": option.get("DefaultStr", ""),
                         "type": option.get("Type", "string"), "password": bool(option.get("IsPassword")),
                         "exclusive": bool(option.get("Exclusive")), "required": bool(option.get("Required")),
                         "examples": [{"value": example.get("Value", ""), "help": (example.get("Help") or "")[:200]}
                                      for example in (option.get("Examples") or [])[:100]]}}


def check_remote_value(key, value):
    if not isinstance(value, str) or len(value) > 20000 or "\n" in value.strip() or "\r" in value:
        invalid("%s must be one line of text." % key)
    if REMOTE_DENIED_OPTION_RE.search(key):
        invalid("%s cannot be set from the GUI: it reads a file or runs a program as root." % key)


def verb_remote_create(request):
    args = get_args(request, ["name", "type", "options"])
    name = args.get("name")
    kind = args.get("type")
    options = args.get("options") or {}
    if not isinstance(name, str) or not REMOTE_NAME_RE.match(name):
        invalid("Name: up to 32 letters, digits, - and _, starting with a letter or digit.")
    if kind not in REMOTE_TYPES:
        invalid("This remote type cannot be created from the GUI.")
    if not isinstance(options, dict):
        invalid("options must be an object.")
    if name in rclone_dump():
        invalid("A remote named %s already exists." % name)
    pairs = []
    for key, value in options.items():
        if not isinstance(key, str) or not re.fullmatch(r"[a-z0-9_]{1,64}", key):
            invalid("Unknown option %r." % key)
        check_remote_value(key, value)
        if value != "":
            pairs.append("%s=%s" % (key, value))
    backup_file(RCLONE_CONFIG, "rclone.conf") if RCLONE_CONFIG else None
    code, out, err = run(rclone_command("config", "create", name, kind, *pairs, "--non-interactive", "--obscure"), REMOTE_TIMEOUT)
    reply = wizard_reply(name, out, err, code)
    record_event("info", "gui-action", "Destination %s (%s) created" % (name, REMOTE_TYPES[kind]) if reply["done"] else "Destination %s (%s) being set up" % (name, REMOTE_TYPES[kind]), "", "")
    return reply


def verb_remote_continue(request):
    args = get_args(request, ["name", "state", "result"])
    name = args.get("name")
    if not isinstance(name, str) or not REMOTE_NAME_RE.match(name):
        invalid("Unknown remote.")
    try:
        with open(wizard_path(name), "r", encoding="utf-8") as handle:
            pending = json.load(handle)
    except (OSError, ValueError):
        raise ControlError("not_found", "No setup in progress for %s; start again." % name)
    if args.get("state") != pending.get("state"):
        raise ControlError("config_conflict", "This setup step is out of date; start again.")
    check_remote_value(pending.get("option", ""), args.get("result", ""))
    code, out, err = run(rclone_command("config", "update", name, "--continue", "--state", pending["state"], "--result", args.get("result", ""),
                                        "--non-interactive", "--obscure"), REMOTE_TIMEOUT)
    reply = wizard_reply(name, out, err, code)
    if reply["done"]:
        record_event("info", "gui-action", "Destination %s set up" % name, "", "")
    return reply


def find_remote(name):
    if not isinstance(name, str) or not REMOTE_NAME_RE.match(name):
        invalid("Unknown remote.")
    dump = rclone_dump()
    if name not in dump:
        raise ControlError("not_found", "No remote named %s in rclone.conf." % name)
    return dump[name]


def verb_remote_test(request):
    args = get_args(request, ["name"])
    name = args.get("name")
    find_remote(name)
    started = time.monotonic()
    code, out, err = run(rclone_command("about", "%s:" % name, "--json"), REMOTE_TIMEOUT)
    about = None
    if code == 0:
        try:
            about = json.loads(out)
        except ValueError:
            about = None
    if code != 0:
        code, out, err = run(rclone_command("lsf", "%s:" % name, "--dirs-only", "--max-depth", "1"), REMOTE_TIMEOUT)
        if code != 0:
            return {"name": name, "ok": False, "error": (err or out).strip()[-600:] or "rclone could not reach it."}
    return {"name": name, "ok": True, "about": about, "seconds": round(time.monotonic() - started, 1)}


def verb_remote_delete(request):
    args = get_args(request, ["name"])
    name = args.get("name")
    find_remote(name)
    used = remote_usage().get(name, [])
    if used:
        raise ControlError("invalid_request", "%s is still used by %s." % (name, ", ".join(used)))
    backup_file(RCLONE_CONFIG, "rclone.conf")
    code, out, err = run(rclone_command("config", "delete", name), READ_TIMEOUT)
    if code != 0:
        raise ControlError("remote_error", (err or out).strip()[-300:] or "rclone config delete failed.")
    record_event("warning", "gui-action", "Destination %s removed from rclone.conf" % name, "Nothing stored on it was deleted.", "")
    return {"name": name, "deleted": True}


def verb_remote_browse(request):
    """Folders on a remote, for the destination picker. remote is a configured
    remote name, or empty for the default destination root."""
    args = get_args(request, ["remote", "path"])
    remote = args.get("remote") or ""
    folder = args.get("path") or ""
    if not isinstance(folder, str) or (folder and not re.fullmatch(r"[A-Za-z0-9._ -]+(/[A-Za-z0-9._ -]+)*", folder.strip("/"))) or ".." in folder.split("/"):
        invalid("path must be a relative folder.")
    if remote:
        settings = find_remote(remote)
        if settings.get("type") not in REMOTE_TYPES:
            invalid("This remote type cannot be used from the GUI.")
        base = "%s:" % remote
    else:
        if not REMOTE_BASE:
            raise ControlError("not_found", "No default destination (RCLONE_REMOTE_ROOT) is set.")
        base = REMOTE_BASE
    target = join_path(base, folder.strip("/")) if folder.strip("/") else base
    code, out, err = run(rclone_command("lsf", target, "--dirs-only", "--max-depth", "1"), REMOTE_TIMEOUT)
    if code != 0:
        message = (err or out).strip()
        if "directory not found" in message.lower():
            return {"remote": remote, "path": folder.strip("/"), "base": base, "folders": [], "exists": False}
        raise ControlError("remote_error", message[-500:] or "rclone could not list it.")
    folders = sorted({line.rstrip("/") for line in out.splitlines() if line.strip()}, key=str.lower)[:1000]
    return {"remote": remote, "path": folder.strip("/"), "base": base, "folders": folders, "exists": True}


def verb_fs_browse(request):
    """Folders on this server, for the job source picker: only under
    FILE_JOB_SOURCE_ROOTS, never inside system or Backup Suite folders."""
    args = get_args(request, ["path"])
    path = args.get("path") or ""
    roots = job_source_roots()
    if not path:
        return {"path": "", "parent": None, "roots": roots,
                "folders": [{"name": root, "path": root, "allowed": True} for root in roots if os.path.isdir(root)]}
    if not isinstance(path, str) or not path.startswith("/") or "\x00" in path:
        invalid("path must be an absolute folder.")
    real = os.path.realpath(path)
    protected = protected_folders()
    # Outside the allowed folders is an answer, not an error: the picker starts at
    # the top instead.
    if not any(path_within(real, root) for root in roots):
        return {"path": real, "parent": "", "roots": roots, "folders": [],
                "denied": "Only folders under %s can be backed up." % ", ".join(roots)}
    if any(path_within(real, folder) for folder in protected):
        return {"path": real, "parent": "", "roots": roots, "folders": [], "denied": "This folder holds system or Backup Suite files."}
    try:
        names = sorted(os.listdir(real), key=str.lower)
    except OSError as error:
        raise ControlError("not_found", "Cannot open %s: %s" % (path, error.strerror))
    folders = []
    for name in names:
        full = os.path.join(real, name)
        if not os.path.isdir(full) or os.path.islink(full):
            continue
        allowed = not any(path_within(full, folder) or folder.startswith(full.rstrip("/") + "/") for folder in protected)
        folders.append({"name": name, "path": full, "allowed": allowed, "hidden": name.startswith(".")})
        if len(folders) >= 2000:
            break
    parent = os.path.dirname(real.rstrip("/"))
    if not any(path_within(parent, root) for root in roots):
        parent = ""
    return {"path": real, "parent": parent, "roots": roots, "folders": folders}


VERBS = {
    "status": (verb_status, False),
    "history": (verb_history, False),
    "runlog": (verb_runlog, False),
    "journal": (verb_journal, False),
    "failures.list": (verb_failures_list, False),
    "failures.read": (verb_failures_read, False),
    "deferrals": (verb_deferrals, False),
    "sources.get": (verb_sources_get, False),
    "excludes.list": (verb_excludes_list, False),
    "profile.show": (verb_profile_show, False),
    "profile.preview": (verb_profile_preview, False),
    "profile.set": (verb_profile_set, True),
    "profile.limits": (verb_profile_limits, True),
    "profile.override": (verb_profile_override, True),
    "config.get": (verb_config_get, False),
    "config.set": (verb_config_set, True),
    "backup.start": (verb_backup_start, True),
    "backup.stop": (verb_backup_stop, True),
    "timer.set": (verb_timer_set, True),
    "notify.test": (verb_notify_test, True),
    "events.since": (verb_events_since, False),
    "events.stat": (verb_events_stat, False),
    "audit": (verb_audit, False),
    "jobs": (verb_jobs, False),
    "job": (verb_job, False),
    "job.changes": (verb_job_changes, False),
    "job.log": (verb_job_log, False),
    "job.measure": (verb_job_measure, False),
    "job.check": (verb_job_check, False),
    "job.save": (verb_job_save, True),
    "job.enable": (verb_job_enable, True),
    "job.remove": (verb_job_remove, True),
    "job.run": (verb_job_run, True),
    "job.exclude": (verb_job_exclude, True),
    "remotes": (verb_remotes, False),
    "remote.create": (verb_remote_create, True),
    "remote.continue": (verb_remote_continue, True),
    "remote.test": (verb_remote_test, False),
    "remote.delete": (verb_remote_delete, True),
    "remote.browse": (verb_remote_browse, False),
    "fs.browse": (verb_fs_browse, False),
}


def reply(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    raw = sys.stdin.buffer.readline(MAX_REQUEST_BYTES + 1)
    if len(raw) > MAX_REQUEST_BYTES:
        reply({"ok": False, "error": {"code": "invalid_request", "message": "Request too large."}})
        return
    try:
        request = json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError):
        reply({"ok": False, "error": {"code": "invalid_request", "message": "The request must be one JSON object."}})
        return
    if not isinstance(request, dict):
        reply({"ok": False, "error": {"code": "invalid_request", "message": "The request must be one JSON object."}})
        return
    unknown = set(request) - {"verb", "args", "session", "id"}
    verb = request.get("verb")
    if unknown or verb not in VERBS:
        reply({"ok": False, "error": {"code": "invalid_request", "message": "Unknown verb or field."}})
        return
    handler, changes = VERBS[verb]
    lock_handle = None
    try:
        if changes:
            lock_handle = open(os.path.join(gui_dir(), "control.lock"), "a")
            fcntl.flock(lock_handle, fcntl.LOCK_EX)
        data = handler(request)
        if changes:
            audit(request, verb, request.get("args"), True, "ok")
        reply({"ok": True, "verb": verb, "mode": MODE, "data": data})
    except ControlError as error:
        if changes and error.code != "invalid_request":
            audit(request, verb, request.get("args"), False, "%s: %s" % (error.code, error.message))
        reply({"ok": False, "verb": verb, "error": {"code": error.code, "message": error.message}})
    except Exception as error:  # Unexpected: report it, never leak a traceback with paths of secrets.
        if changes:
            audit(request, verb, request.get("args"), False, "internal: %s" % type(error).__name__)
        reply({"ok": False, "verb": verb, "error": {"code": "internal", "message": "%s: %s" % (type(error).__name__, str(error)[:300])}})
    finally:
        if lock_handle:
            lock_handle.close()


if __name__ == "__main__":
    main()
