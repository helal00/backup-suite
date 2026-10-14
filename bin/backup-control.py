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
    "NOTIFY_FAILURES_ENABLED": (("bool",), "Send ntfy notifications for failures and watchdog actions."),
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


def verb_config_get(request):
    get_args(request, [])
    path = os.path.realpath(GLOBAL_CONFIG_FILE)
    values = parse_global_config(path)
    settings = []
    for key, (kind, explanation) in CONFIG_KEYS.items():
        present = key in values
        value = values.get(key, "")
        entry = {"key": key, "kind": kind[0], "explanation": explanation, "default": CONFIG_DEFAULTS.get(key, ""),
                 "present": present}
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
        settings.append(entry)
    return {"path": GLOBAL_CONFIG_FILE, "sha256": file_sha256(path), "settings": settings}


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
        if key not in CONFIG_KEYS:
            invalid("%s cannot be changed from the GUI." % key)
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
    return {"sha256": file_sha256(path), "backup": backup_path, "changed": sorted(changes),
            "note": "Watchdog and notification settings apply from the next backup run."}


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
