// Help texts for the `?` buttons. Plain data; app.js renders it as text (never HTML).
// Sources: docs/RESOURCES.md, docs/OPERATIONS.md and docs/GUI-SPECIFICATION.md.
window.BACKUP_SUITE_HELP = {
  navigation: {
    title: "Backup jobs",
    sections: [
      ["Home", "The whole system at a glance: is everything in order, what runs now, server and backup resources, every job's state, database backups and the latest ntfy notifications."],
      ["Jobs", "One card per backup job (one line of file-sources.conf): a source folder and where it is backed up. The card shows whether it is enabled, its state, its source, its mapping (destination mode, stop file, projects) and when it last ran. Click a card for everything about that job."],
      ["New job", "Adds a job. The form is checked on the server as you type: the folder must exist and lie under the allowed folders (FILE_JOB_SOURCE_ROOTS, set on the server), and its destination must not overlap another job's."],
      ["Filter", "All jobs, only enabled ones, or only those needing attention (failed, config problem, paused by a stop file, or files that never settle)."],
      ["Admin", "Everything that is not about one job: start and stop, schedule, profiles, watchdog, ntfy, every global setting, all runs, logs and the audit log."]
    ]
  },
  home: {
    title: "Home",
    sections: [
      ["Verdict", "Green when the schedule is on, the server has memory to spare and every enabled job was backed up in its last run. Amber or red lists what needs a look."],
      ["Gauges", "Backup memory against its throttle (MemoryHigh) and hard limit (MemoryMax), memory that cannot be reclaimed, swap, CPU against its quota, tasks, and the server's free RAM and memory pressure. The thin marks are the watchdog's thresholds."],
      ["Jobs table", "Each job's state, last run, when it was last backed up, how many files changed last run, and how many files are being skipped because they keep changing. Click a row to open the job."]
    ]
  },
  entry: {
    title: "A backup job",
    sections: [
      ["Buttons", "Back up now runs this job alone (with the watchdog, as usual). Edit changes any of its options and its own exclude and volatile patterns. Disable keeps it but skips it in scheduled runs. Remove deletes its line; nothing on the remote is deleted."],
      ["Overview", "What is backed up and where, previous versions and how long they are kept, when the job last ran and was last backed up, when the next run reaches it, and projects that need a look."],
      ["Projects", "With isolation children each child directory is its own project: a failure in one never stops the others. Click a project for its paths, history and the files that changed in its last run."],
      ["Changed files", "The files each project uploaded in its last run: new, updated (the previous version moved to the archive) and removed (moved to the archive)."],
      ["Changing files", "Files modified moments before their project synced are skipped and tried again next run; their previous remote version stays. A file skipped many runs in a row never settles: exclude it or stop its writer briefly."],
      ["Excludes & stop files", "The stop file (.nosync by default) pauses the job or one project. .backup-excludes patterns are never uploaded; .backup-volatile patterns may change during a sync without failing it."],
      ["Runs, Log, Source & destination", "This job's runs with each project's result, its part of the run log, and on request the size of the source and of the destination."]
    ]
  },
  admin: {
    title: "Admin",
    sections: [
      ["What is here", "Backup Suite's settings and actions for the whole server, not for one job: start and stop, the schedule, resource profiles, the watchdog, ntfy, every global setting, every run, the sources file, logs and the audit log."],
      ["Changes", "Every change asks for confirmation, is validated by the control script, and is recorded in the audit log."]
    ]
  },
  actions: {
    title: "Actions & schedule",
    sections: [
      ["File backup", "Start runs every enabled job in file-sources.conf order. Stopping is safe for the remote copies: finished projects stay backed up and the interrupted project is redone next run."],
      ["Schedule", "If file-backup.timer is off, scheduled backups do not run; Home then shows a warning."]
    ]
  },
  settings: {
    title: "All settings",
    sections: [
      ["global.conf", "Every key of Backup Suite's global.conf, grouped. Each save is checked by the server, confirmed, backed up and audited, and applies from the next run."],
      ["Schedule", "When file and database backups run (systemd calendar expressions). Saved changes are applied to the timers at once."],
      ["Remote", "Changing the remote root, the hostname folder or the default destination moves every job's destination: the next run uploads everything again there; nothing is moved or deleted."],
      ["Read-only", "Programs and paths that run as root (rclone binary, extra rclone flags, config and state paths), the folders jobs may back up, and install options are shown but changed in global.conf on the server only: from the GUI they could make root run anything."]
    ]
  },
  logs: {
    title: "Logs",
    sections: [
      ["Journals", "The systemd journal of the file and database backups, the watchdog, and the GUI's control requests. A job's own part of the run log is on its Log tab."]
    ]
  },
  runs: {
    title: "Runs & failures",
    sections: [
      ["History", "One row per file backup run, from the watchdog's history (newest 500 runs). Peak RAM includes cache; non-reclaimable RAM is what could force an OOM kill."],
      ["Events", "contained: the watchdog reclaimed cache and halved CPU; server-pressure: it paused the backup; step-down/step-up: adaptive profile changes; memory-limit, server-critical, pause-timeout: it stopped the backup."],
      ["Run log", "The run's own part of the durable log, with search, download and copy. Failure records are the files sent as ntfy attachments."]
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
    title: "Sources file",
    sections: [
      ["Read-only", "Sources decide what gets backed up, so this version only shows them. Edit file-sources.conf on the server; editing in the GUI arrives in a later version."],
      ["Columns", "enabled | label | source path | destination mode (same-name, fixed, default-root) | destination value | stop file | isolation (single, or children: each child folder is backed up on its own)."],
      ["Exclude files", "Each project can have .backup-excludes files with rclone filter patterns; they are shown below the table."]
    ]
  },
  activity: {
    title: "Activity & audit",
    sections: [
      ["Activity", "Every Backup Suite event: run finished, watchdog actions, profile steps, changing files, schedule changes, GUI actions and tests. Each ntfy notification shows what happened to its push. The bell lists the ntfy notifications on their own."],
      ["Audit", "Every change made through the GUI (or the control broker): when, by which login, what, and the result. Secrets appear only as [set]."]
    ]
  },
  details: {
    title: "Details",
    sections: [
      ["Details panel", "Shows the project, run, log, record or preview you opened. Maximize it for long logs; close it to give the main panel more room."]
    ]
  },
  settings: {
    title: "Settings",
    sections: [
      ["GUI settings", "General, Notifications, Tunnel Manager and GUI resource limits are this GUI's own settings, stored for your login. Backup Suite's own settings are under Admin."]
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
