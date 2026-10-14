# Resource Profiles, Watchdog, and Changing Files

File backups run under a resource profile, a watchdog that enforces it, and a
changing-file policy that keeps rclone away from files that are being written.
Every intervention is reported through ntfy.

## Choosing a profile

```bash
sudo /opt/backup-suite/bin/backup-profile.sh show          # list profiles and limits
sudo /opt/backup-suite/bin/backup-profile.sh choose        # interactive menu
sudo /opt/backup-suite/bin/backup-profile.sh set slow      # switch directly
```

| Profile | CPU (of one core) | RAM throttle / hard limit | Swap | Tasks | Disk I/O | Uploads / checkers / buffer | API calls/s | Bandwidth | Duration vs moderate |
|---|---|---|---|---|---|---|---|---|---|
| `slow` | 25%, nice 19 | 256M / 512M | 128M | 32 | idle, weight 5 | 1 / 2 / 8M | 4 | 4 MB/s | about 2-3x longer |
| `moderate` | 50%, nice 15 | 512M / 1G | 256M | 64 | idle, weight 10 | 2 / 4 / 16M | 10 | unlimited | baseline |
| `fast` | 100%, nice 10 | 1G / 2G | 512M | 128 | best-effort, weight 50 | 4 / 8 / 32M | 20 | unlimited | about 0.5-0.7x |
| `custom` | `FILE_CUSTOM_*` | `FILE_CUSTOM_*` | `FILE_CUSTOM_*` | `FILE_CUSTOM_*` | `FILE_CUSTOM_*` | `FILE_RCLONE_*` | `FILE_RCLONE_TPSLIMIT` | `FILE_RCLONE_BWLIMIT` | depends |

The limits are maximums. A typical moderate run used about 35 MB of memory and
under one core in production. `backup-profile.sh show` also prints what the last
run of each profile actually used, from the watchdog history.

`set` writes `FILE_BACKUP_PROFILE` to `global.conf`, writes the systemd drop-in
`file-backup.service.d/50-backup-profile.conf`, and reloads systemd. If a
backup is running, its CPU, memory, swap, and task limits are changed
immediately. The rclone settings apply from the next run. A config without
`FILE_BACKUP_PROFILE` behaves as `custom`, so existing hosts keep their
previous behavior until a profile is chosen.

## Fixed or adaptive

| Setup | Command | Behavior |
|---|---|---|
| Fixed | `backup-profile.sh set moderate` | Always uses one profile. |
| Adaptive, 2 steps | `backup-profile.sh adaptive moderate slow` | Starts at moderate. Steps down to slow when resources are tight and back to moderate when they are normal. |
| Adaptive, 3 steps | `backup-profile.sh adaptive fast slow` | fast > moderate > slow and back, one level at a time. |

The watchdog steps **down** one level when any of these is true: backup memory
is at or above 80% of its limit, backup swap is at or above 80%, server RAM
available is below 20%, or memory pressure (PSI full avg10) is at or above 10
while the backup holds at least 64 MiB and the stall is not caused by another
service at its own memory limit (see below). The server conditions must last
`WATCHDOG_PRESSURE_SUSTAIN_SECONDS` (30 s); a short spike never counts.
It steps **up** one level after 300 s in which server RAM available stays at or
above 30%, pressure stays low (or comes only from such another service), and
the backup stays below 60% of its limit.
Level changes are at least 120 s apart. All of these are
`WATCHDOG_ADAPTIVE_*` settings.

A step changes the running backup's CPU, memory throttle, swap, and task limits
at once. rclone's transfers, checkers, and bandwidth follow from the next
project. A lower hard memory limit is only applied once usage is comfortably
below it, so a step-down never forces an OOM kill. The current level is saved
in `/var/lib/backup-suite/watchdog/adaptive-profile.state`. The next run starts
at that level and steps up when conditions allow. Steps are routine: they are
listed in the GUI's Activity and the journal, and pushed through ntfy only with
`WATCHDOG_NOTIFY_PROFILE_STEPS="1"`. Containment, pause, and stop (below) still
apply at the floor level.

## Limits: built-in, auto, or your own

- `backup-profile.sh limits fixed`: the table above (default).
- `backup-profile.sh limits auto`: memory and CPU are scaled to this host. slow uses 5% of RAM and 3% of total CPU, moderate 10% and 6%, fast 20% and 12%. MemoryHigh is half of MemoryMax, swap a quarter, and MemoryMax is at least 256 MB.
- `backup-profile.sh override slow MEMORY_MAX 384M`: set any single limit for a single profile (on top of fixed or auto); `--unset` removes it. Keys: `CPU_QUOTA CPU_WEIGHT IO_WEIGHT NICE IO_SCHEDULING_CLASS MEMORY_HIGH MEMORY_MAX MEMORY_SWAP_MAX TASKS_MAX RCLONE_TRANSFERS RCLONE_CHECKERS RCLONE_BUFFER_SIZE RCLONE_TPSLIMIT RCLONE_BWLIMIT`. They are stored as `FILE_PROFILE_<PROFILE>_<KEY>` in `global.conf`.

## Watchdog

`file-backup.service` pulls in `backup-suite-watchdog@file-backup.service`
through `Wants=`. The watchdog runs only while a backup runs. Every 5 seconds
(`WATCHDOG_INTERVAL_SECONDS`) it reads the backup's cgroup counters with shell
builtins, so it starts no extra processes and uses a few MB of memory. It runs
with `OOMScoreAdjust=-900` and `Nice=-5`, so it stays responsive when the
server is under pressure.

| Situation | Watchdog action | ntfy |
|---|---|---|
| Backup memory at or above 80% of MemoryMax, or swap at or above 80% of its allowance | Reclaims the backup's cache memory and halves its CPU quota. Restores them once usage stays below 60%. | "backup memory surge contained" |
| Non-reclaimable backup memory at or above 90% of MemoryMax for 2 samples | Stops the backup gracefully before the kernel OOM-kills it, then force-kills the cgroup if it has not exited after 30 s. | "backup stopped before OOM" |
| Swap at or above 95% while RAM is at or above 80% | Stops the backup. | "backup stopped: memory and swap exhausted" |
| Server RAM available below 10% for 10 s, or memory PSI full avg10 at or above 20 for 30 s while RAM available is below 20% and the stall is not another service's own (see below); the backup holds at least 64 MiB of non-reclaimable memory and swap | Freezes the backup (no CPU or I/O) and resumes it when the shortage clears. | "backup paused: server short of memory" |
| The same shortage, but the backup holds less than 64 MiB | Keeps it running (pausing would free nothing); in adaptive mode it steps down to the floor. | "server short of memory; backup continues" |
| A memory stall without a shortage, or caused by another cgroup at its own memory limit | Keeps the backup running and names the cgroup that stalls. | "memory stall from &lt;service&gt;; backup continues" |
| Pause longer than 15 minutes (`WATCHDOG_FREEZE_MAX_SECONDS`) | Thaws the backup, stops it gracefully, then retries it once server memory has been normal for 60 s (waiting up to 30 min; `WATCHDOG_RETRY_*`). | "backup deferred: server short of memory" |
| Server RAM available below 4% | Stops the backup immediately to protect production services. | "backup stopped to protect the server" |
| The kernel OOM-killed a backup process anyway | Records it; systemd stops the unit (`OOMPolicy=stop`). | "kernel OOM-killed a backup process" |
| Tasks at or above 90% of TasksMax | Warns once. | "backup near its process limit" |
| A run finishes after any containment | Sends a summary of the run's resource use. | "backup finished after watchdog intervention" |
| The first run that completes after a pressure episode was reported | Closes the episode. | "backups recovered" |

**Pressure episodes.** Pauses, deferrals and host-stall notices belong to one
episode, which lasts until a run completes normally (at most 24 hours). Each
kind of notice is pushed once per episode; repeats, for example when the next
timer run pauses again, are only listed in Activity. If the watchdog stopped a
run and already explained why, the failure notifier records the failure without
pushing a second message.

**Whose stall is it?** The server-wide memory stall (`/proc/pressure/memory`)
also rises when a single service is throttled at its own `MemoryHigh`: that
service stalls itself while the server still has plenty of RAM. On 2026-10-14
`agentw-service.service` did exactly that (its own stall 81, the server's 67,
57% of RAM available), and the old watchdog paused and then stopped two backups
for it. While the server reports a stall, the watchdog now ranks the services
and scopes by their own `memory.pressure` and checks whether the worst one sits
at its `MemoryHigh` (or `MemoryMax`). If it does, the stall is attributed to it
and the backup is neither paused nor stepped down. The attachment of every
notice lists server RAM, swap and the three worst stallers with their memory,
limit, swap and `memory.high` event count.

**Stopping and the next run.** Before stopping a paused backup the watchdog
thaws it, so its processes can handle SIGTERM and exit cleanly. If the timer
starts the next run while the watchdog waits for the stop (as at 19:01:20 on
2026-10-14), the watchdog sees the new invocation, never force-kills it, and
starts watching it. A run that ends some other way is recorded with systemd's
result (`success`, `signal`, `oom-kill`, `timeout`, `exit-code`) in the
history; a killed run's progress file is marked `interrupted`.

Stopping a backup is safe for the remote copy. rclone replaces or archives
each remote file only when that file finishes, and deletions only happen at
the end of a successful project sync. The next scheduled run starts normally.

The thresholds are `WATCHDOG_*` settings in `global.conf` (see
`config/global.conf.example`).

Files:

- `/var/lib/backup-suite/watchdog/file-backup.service.status`: live values, updated every 15 s while a backup runs
- `/var/lib/backup-suite/watchdog/history.tsv`: one line per run with duration, peak RAM, non-reclaimable RAM and swap, average and peak CPU, peak tasks, disk I/O, events, outcome, and systemd's result (the newest 500 runs)
- `/var/lib/backup-suite/watchdog/file-backup.service.last-action`: the most recent stop, which the failure notifier also reports
- `/var/lib/backup-suite/watchdog/file-backup.service.episode`: the open pressure episode and which notices it has pushed

Every unit Backup Suite ships caps swap with `MemorySwapMax`: `MemoryMax`
counts RAM only, and a unit with `MemoryHigh` but unlimited swap is pushed
into swap without bound instead of reaching its limit. The database units have
no RAM limit (a large dump must not be killed) but cap swap too. A file backup
profile without a swap cap is rejected.

Check it with:

```bash
sudo /opt/backup-suite/bin/backup-watchdog.sh file-backup.service --self-test
journalctl -t backup-watchdog -n 50 --no-pager
```

## Changing files

Before each project sync, Backup Suite lists files modified within the last
`FILE_ACTIVE_WINDOW_SECONDS` (default 120). These files are probably still
being written, so they are excluded from that sync with exact, root-anchored
filters. If rclone still sees a file change while uploading it, the existing
stability retry also defers the files that changed.

A deferred file keeps its previous remote version and is tried again on the
next run. Each deferral is counted per file in
`/var/lib/backup-suite/active-files/`. A file deferred for
`FILE_ACTIVE_MAX_DEFERRALS` runs in a row (default 12) triggers an ntfy
warning that names it, so a file that never settles is never silently left
out. Exclude such files with `.backup-excludes`, or stop their writer briefly.
