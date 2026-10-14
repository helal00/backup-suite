// Help texts for the `?` buttons. Plain data; app.js renders it as text (never HTML).
// Sources: docs/RESOURCES.md, docs/OPERATIONS.md and docs/GUI-SPECIFICATION.md.
window.BACKUP_SUITE_HELP = {
  navigation: {
    title: "Sections",
    sections: [
      ["Overview", "What the backups are doing now, how much of the server they use, the schedule, and the main actions."],
      ["Runs", "Every finished file backup with its duration, peak memory, CPU and watchdog events. Open a run to read its log."],
      ["Projects & changing files", "The result of each project in the latest run, and files skipped because they kept changing."],
      ["Profiles & limits", "How much CPU, memory, disk and network a backup may use: fixed slow, moderate or fast, or adaptive."],
      ["Watchdog", "The guard that contains, pauses or stops a backup before it can harm the server, and its thresholds."],
      ["Notifications (ntfy)", "Off-server alerts by ntfy. GUI notices (bell, Tunnel Manager, browser) are under Settings."],
      ["Sources", "What gets backed up. Read-only in this version."],
      ["Activity & audit", "Every event and every change made through the GUI."]
    ]
  },
  overview: {
    title: "Overview",
    sections: [
      ["Status", "Idle, Running, Paused by the watchdog, Stopping, or Failed (last run). While running you see the current project and \"project N of M\"."],
      ["Gauges", "Backup memory against its throttle (MemoryHigh) and hard limit (MemoryMax), memory that cannot be reclaimed, swap, CPU against its quota, tasks, and the server's free RAM and memory pressure. Green is normal; amber means the watchdog is about to contain the backup (80% by default); red means it may stop it (90%). The thin marks are the watchdog's thresholds."],
      ["Actions", "Every action asks for confirmation first. Stopping a backup is safe for the remote copies: finished projects stay backed up, and the interrupted project is redone next run. Nothing on Google Drive is deleted by a stop."],
      ["Schedule", "If file-backup.timer is disabled or inactive, scheduled backups do not run; an amber warning says so."]
    ]
  },
  runs: {
    title: "Runs",
    sections: [
      ["History", "One row per file backup run, from the watchdog's history (newest 500 runs). Peak RAM includes cache; non-reclaimable RAM is what could force an OOM kill."],
      ["Events", "contained: the watchdog reclaimed cache and halved CPU; server-pressure: it paused the backup; step-down/step-up: adaptive profile changes; memory-limit, server-critical, pause-timeout: it stopped the backup."],
      ["Run log", "The run's own part of the durable log, with search, download and copy. Failure records are the files sent as ntfy attachments."]
    ]
  },
  projects: {
    title: "Projects & changing files",
    sections: [
      ["Projects", "Read from the latest run's log: synced, synced on retry, synced with changing files kept for next run, deferred, failed, or waiting for a link-migration confirmation."],
      ["Changing files", "Before each project, files modified in the last FILE_ACTIVE_WINDOW_SECONDS (120 s by default) are skipped because they are probably still being written. Their previous remote version stays in place and they are tried again next run."],
      ["Highlighted rows", "A file skipped FILE_ACTIVE_MAX_DEFERRALS runs in a row (12 by default) never settles. Exclude it with .backup-excludes in its project, or stop its writer briefly."]
    ]
  },
  profiles: {
    title: "Profiles & limits",
    sections: [
      ["Fixed or adaptive", "Fixed always uses one profile. Adaptive starts at the top profile and the watchdog steps one level down when the backup or the server is short of resources, and back up after 5 minutes of normal conditions."],
      ["What applies when", "CPU, memory, swap and task limits change at once for a running backup. rclone's uploads, checkers and bandwidth follow from the next project. A lower hard memory limit is applied only once usage is comfortably below it, so a change never forces an OOM kill."],
      ["Limits", "Fixed uses the built-in table. Auto scales memory and CPU to this server: slow 5% RAM / 3% CPU, moderate 10% / 6%, fast 20% / 12%. Overrides set one value for one profile on top of either."],
      ["Preview", "Before saving, the Details panel shows the systemd drop-in that will be written."]
    ]
  },
  watchdog: {
    title: "Watchdog",
    sections: [
      ["What it does", "While a backup runs it reads the backup's cgroup counters every few seconds. It contains a memory surge (reclaims cache, halves CPU), pauses the backup when the server is short of RAM, and stops it before the kernel would OOM-kill anything. Every intervention is reported by ntfy."],
      ["Thresholds", "Percentages refer to the backup's MemoryMax unless they name the server. They must stay in order: release < contain < stop; critical server RAM < pause server RAM; adaptive step-up RAM > step-down RAM."],
      ["When changes apply", "The watchdog reads its settings when a backup starts, so changes apply from the next backup run."]
    ]
  },
  notifications: {
    title: "Notifications (ntfy)",
    sections: [
      ["ntfy", "Backup Suite sends failures and watchdog actions to your ntfy topic. Every message starts with a plain description; the full log is attached."],
      ["Token", "An access token for a protected topic can be replaced or cleared here, but it is never shown."],
      ["Test", "Send test notification sends one message in the real format, and it also appears in the bell."]
    ]
  },
  sources: {
    title: "Sources",
    sections: [
      ["Read-only", "Sources decide what gets backed up, so this version only shows them. Edit file-sources.conf on the server; editing in the GUI arrives in a later version."],
      ["Columns", "enabled | label | source path | destination mode (same-name, fixed, default-root) | destination value | stop file | isolation (single, or children: each child folder is backed up on its own)."],
      ["Exclude files", "Each project can have .backup-excludes files with rclone filter patterns; they are shown below the table."]
    ]
  },
  activity: {
    title: "Activity & audit",
    sections: [
      ["Activity", "Every Backup Suite event: run finished, watchdog actions, profile steps, changing files, schedule changes, GUI actions and tests. Tunnel Manager shows warnings and errors as desktop notices; everything is listed here."],
      ["Audit", "Every change made through the GUI (or the control broker): when, by which login, what, and the result. Secrets appear only as [set]."]
    ]
  },
  details: {
    title: "Details",
    sections: [
      ["Details panel", "Shows the log, record or preview you opened. Maximize it for long logs; close it to give the main panel more room."]
    ]
  },
  settings: {
    title: "Settings",
    sections: [
      ["GUI settings", "General, Notifications, Tunnel Manager and GUI resource limits are this GUI's own settings, stored for your login."],
      ["Server settings", "Change Backup Suite's global.conf through the control script. Each change is validated, confirmed, backed up and audited."]
    ]
  },
  connect: {
    title: "Ways to connect",
    sections: [
      ["Tunnel Manager", "Import the bundle into the Tunnel Manager profile for this server and press Start. The backend must be exactly that profile's user@host."],
      ["Launchers", "Without Tunnel Manager, a launcher opens the SSH tunnel and the browser for you."],
      ["Manual", "Run the ssh line, then open the address in a browser."]
    ]
  }
};
