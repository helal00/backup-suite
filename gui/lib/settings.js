"use strict";

// GUI-only settings (not Backup Suite's global.conf): where they live, their
// defaults, and the bounds every saved value is clamped to.
//
// Config:  ${BACKUP_SUITE_GUI_CONFIG_DIR:-${XDG_CONFIG_HOME:-~/.config}/backup-suite-gui}/config.json
// State:   ${BACKUP_SUITE_GUI_STATE_DIR:-${XDG_STATE_HOME:-~/.local/state}/backup-suite-gui}/

const fs = require("fs");
const os = require("os");
const path = require("path");

const NOTIFICATION_CATEGORIES = [
  "run-finished", "run-failed", "watchdog-contain", "watchdog-pause", "watchdog-stop",
  "profile-step", "changing-files", "schedule-off", "gui-action", "test", "alert"
];

const CATEGORY_LABELS = {
  "run-finished": "Backup run finished",
  "run-failed": "Backup run failed",
  "watchdog-contain": "Watchdog contained a surge",
  "watchdog-pause": "Watchdog paused the backup",
  "watchdog-stop": "Watchdog stopped the backup",
  "profile-step": "Adaptive profile stepped down or up",
  "changing-files": "Files repeatedly skipped while changing",
  "schedule-off": "Scheduled backups switched off",
  "gui-action": "Changes made through the GUI",
  test: "Test notifications",
  alert: "Other alerts"
};

function homeDir(env = process.env) {
  return String(env.HOME || "").trim() || os.homedir();
}

function configDir(env = process.env) {
  if (String(env.BACKUP_SUITE_GUI_CONFIG_DIR || "").trim()) return path.resolve(env.BACKUP_SUITE_GUI_CONFIG_DIR);
  const base = String(env.XDG_CONFIG_HOME || "").trim() || path.join(homeDir(env), ".config");
  return path.join(base, "backup-suite-gui");
}

function stateDir(env = process.env) {
  if (String(env.BACKUP_SUITE_GUI_STATE_DIR || "").trim()) return path.resolve(env.BACKUP_SUITE_GUI_STATE_DIR);
  const base = String(env.XDG_STATE_HOME || "").trim() || path.join(homeDir(env), ".local", "state");
  return path.join(base, "backup-suite-gui");
}

function defaults() {
  const categories = {};
  for (const category of NOTIFICATION_CATEGORIES) categories[category] = true;
  return {
    general: { refreshSeconds: 5, chartMinutes: 30, timeDisplay: "utc", theme: "system", backend: "auto" },
    notifications: { tunnelManager: true, browser: true, preferTunnelManager: true, categories },
    tunnel: { listenMode: "socket", tcpPort: 4337, sshHost: "", backendId: "", localPort: 14337 },
    limits: { memoryHighMb: 96, memoryMaxMb: 160, tasksMax: 64, watchdogMemoryMb: 140, watchdogTasks: 56 }
  };
}

function clampInt(value, fallback, low, high) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(high, Math.max(low, Math.round(number)));
}

function pick(value, options, fallback) {
  return options.includes(value) ? value : fallback;
}

const HOST_RE = /^[A-Za-z0-9.-]{1,253}$|^\[[0-9A-Fa-f:]+\]$/;
const BACKEND_RE = /^[a-z_][a-z0-9_.-]{0,31}@[A-Za-z0-9.:[\]-]{1,253}$/;

// Returns a complete, valid settings object built from `input` over the defaults.
function normalize(input) {
  const base = defaults();
  const source = input && typeof input === "object" ? input : {};
  const general = source.general || {};
  const notifications = source.notifications || {};
  const tunnel = source.tunnel || {};
  const limits = source.limits || {};
  const categories = {};
  for (const category of NOTIFICATION_CATEGORIES) {
    const value = notifications.categories ? notifications.categories[category] : undefined;
    categories[category] = typeof value === "boolean" ? value : true;
  }
  const memoryHighMb = clampInt(limits.memoryHighMb, base.limits.memoryHighMb, 48, 1024);
  return {
    general: {
      refreshSeconds: clampInt(general.refreshSeconds, base.general.refreshSeconds, 2, 60),
      chartMinutes: clampInt(general.chartMinutes, base.general.chartMinutes, 10, 120),
      timeDisplay: pick(general.timeDisplay, ["utc", "local"], base.general.timeDisplay),
      theme: pick(general.theme, ["system", "light", "dark"], base.general.theme),
      backend: pick(general.backend, ["auto", "user", "system"], base.general.backend)
    },
    notifications: {
      tunnelManager: typeof notifications.tunnelManager === "boolean" ? notifications.tunnelManager : true,
      browser: typeof notifications.browser === "boolean" ? notifications.browser : true,
      preferTunnelManager: typeof notifications.preferTunnelManager === "boolean" ? notifications.preferTunnelManager : true,
      categories
    },
    tunnel: {
      listenMode: pick(tunnel.listenMode, ["socket", "tcp", "both"], base.tunnel.listenMode),
      tcpPort: clampInt(tunnel.tcpPort, base.tunnel.tcpPort, 1024, 65535),
      sshHost: typeof tunnel.sshHost === "string" && (tunnel.sshHost === "" || HOST_RE.test(tunnel.sshHost)) ? tunnel.sshHost : "",
      backendId: typeof tunnel.backendId === "string" && (tunnel.backendId === "" || BACKEND_RE.test(tunnel.backendId)) ? tunnel.backendId : "",
      localPort: clampInt(tunnel.localPort, base.tunnel.localPort, 1024, 65435)
    },
    limits: {
      memoryHighMb,
      memoryMaxMb: Math.max(memoryHighMb + 16, clampInt(limits.memoryMaxMb, base.limits.memoryMaxMb, 64, 2048)),
      tasksMax: clampInt(limits.tasksMax, base.limits.tasksMax, 16, 512),
      watchdogMemoryMb: clampInt(limits.watchdogMemoryMb, base.limits.watchdogMemoryMb, 48, 2048),
      watchdogTasks: clampInt(limits.watchdogTasks, base.limits.watchdogTasks, 8, 512)
    }
  };
}

function settingsPath(env = process.env) {
  return path.join(configDir(env), "config.json");
}

function load(env = process.env) {
  try {
    return normalize(JSON.parse(fs.readFileSync(settingsPath(env), "utf8")));
  } catch {
    return normalize({});
  }
}

// Writes atomically with mode 0600 in a 0700 directory.
function save(settings, env = process.env) {
  const normalized = normalize(settings);
  const dir = configDir(env);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const target = settingsPath(env);
  const temp = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(temp, `${JSON.stringify(normalized, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temp, target);
  return normalized;
}

// Deep-merges a partial update (from the Settings dialog) into the current settings.
function merge(current, update) {
  const result = JSON.parse(JSON.stringify(current));
  if (!update || typeof update !== "object") return result;
  for (const section of Object.keys(result)) {
    const incoming = update[section];
    if (!incoming || typeof incoming !== "object") continue;
    for (const [key, value] of Object.entries(incoming)) {
      if (!(key in result[section])) continue;
      if (key === "categories" && value && typeof value === "object") {
        Object.assign(result[section].categories, value);
      } else {
        result[section][key] = value;
      }
    }
  }
  return normalize(result);
}

module.exports = {
  CATEGORY_LABELS,
  NOTIFICATION_CATEGORIES,
  configDir,
  defaults,
  load,
  merge,
  normalize,
  save,
  settingsPath,
  stateDir
};
