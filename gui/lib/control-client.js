"use strict";

// The GUI's only way to Backup Suite: bin/backup-control.sh, reached two ways.
//
// - direct (user mode): Backup Suite is installed for this user. The control script
//   runs as a child process, as this user.
// - broker (system mode): Backup Suite runs as root. The GUI connects to
//   /run/backup-suite/control.sock; systemd runs the same control script as root for
//   each connection.
//
// Both take one JSON line and answer one JSON line. Identical concurrent reads are
// coalesced into one call.

const { spawn } = require("child_process");
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const READ_TIMEOUT_MS = 15000;
const CHANGE_TIMEOUT_MS = 75000;
const MAX_REPLY_BYTES = 16 * 1024 * 1024;

const VERBS = {
  status: false, history: false, runlog: false, journal: false, "failures.list": false, "failures.read": false,
  deferrals: false, "sources.get": false, "excludes.list": false, "profile.show": false, "profile.preview": false,
  "profile.set": true, "profile.limits": true, "profile.override": true, "config.get": false, "config.set": true,
  "backup.start": true, "backup.stop": true, "timer.set": true, "notify.test": true, "events.since": false,
  "events.stat": false, audit: false
};

function homeDir(env) {
  return String(env.HOME || "").trim() || os.homedir();
}

function userConfigFile(env = process.env) {
  const base = String(env.XDG_CONFIG_HOME || "").trim() || path.join(homeDir(env), ".config");
  return path.join(base, "backup-suite", "global.conf");
}

function brokerSocket(env = process.env) {
  return String(env.BACKUP_SUITE_CONTROL_SOCKET || "").trim() || "/run/backup-suite/control.sock";
}

function userControlScript(env = process.env) {
  if (String(env.BACKUP_SUITE_CONTROL_SCRIPT || "").trim()) return path.resolve(env.BACKUP_SUITE_CONTROL_SCRIPT);
  return path.join(homeDir(env), ".local", "share", "backup-suite", "bin", "backup-control.sh");
}

function exists(file) {
  try {
    fs.statSync(file);
    return true;
  } catch {
    return false;
  }
}

// Which backend to use. `preference` is the backend setting: auto, user or system.
function detectMode(preference = "auto", env = process.env) {
  const userInstalled = exists(userConfigFile(env));
  const systemInstalled = exists(brokerSocket(env));
  const both = userInstalled && systemInstalled;
  let mode = "none";
  let reason = "";
  if (preference === "user") {
    mode = userInstalled ? "user" : "none";
    reason = userInstalled ? "chosen in Settings" : `No user installation (${userConfigFile(env)} is missing).`;
  } else if (preference === "system") {
    mode = systemInstalled ? "system" : "none";
    reason = systemInstalled ? "chosen in Settings" : `No system broker (${brokerSocket(env)} is missing).`;
  } else if (systemInstalled) {
    mode = "system";
    reason = both ? "both installations found; system mode chosen (switch in Settings)" : "system broker found";
  } else if (userInstalled) {
    mode = "user";
    reason = "user installation found";
  } else {
    reason = "Backup Suite was not found for this user, and the system broker socket does not exist.";
  }
  return { mode, reason, both, userInstalled, systemInstalled, userConfig: userConfigFile(env), socket: brokerSocket(env), script: userControlScript(env) };
}

class ControlError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

function parseReply(text) {
  const line = String(text).split("\n").find((part) => part.trim());
  if (!line) throw new ControlError("no_reply", "The control script gave no reply.");
  try {
    return JSON.parse(line);
  } catch {
    throw new ControlError("bad_reply", "The control script gave an unreadable reply.");
  }
}

function callDirect(script, line, timeoutMs, env) {
  return new Promise((resolve, reject) => {
    let output = "";
    let errors = "";
    let finished = false;
    const child = spawn(script, [], { stdio: ["pipe", "pipe", "pipe"], env });
    const timer = setTimeout(() => {
      if (finished) return;
      finished = true;
      child.kill("SIGTERM");
      reject(new ControlError("timeout", `No reply within ${Math.round(timeoutMs / 1000)}s.`));
    }, timeoutMs);
    child.stdout.on("data", (chunk) => {
      output += chunk;
      if (output.length > MAX_REPLY_BYTES) child.kill("SIGTERM");
    });
    child.stderr.on("data", (chunk) => {
      if (errors.length < 4000) errors += chunk;
    });
    child.on("error", (error) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      reject(new ControlError("unavailable", `Could not run ${script}: ${error.message}`));
    });
    child.on("close", () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      try {
        resolve(parseReply(output));
      } catch (error) {
        if (errors.trim()) error.message += ` ${errors.trim().slice(0, 300)}`;
        reject(error);
      }
    });
    child.stdin.on("error", () => {});
    child.stdin.end(line);
  });
}

function callBroker(socketPath, line, timeoutMs) {
  return new Promise((resolve, reject) => {
    let output = "";
    let finished = false;
    const socket = net.connect({ path: socketPath });
    const finish = (error, value) => {
      if (finished) return;
      finished = true;
      socket.destroy();
      if (error) reject(error);
      else resolve(value);
    };
    socket.setTimeout(timeoutMs, () => finish(new ControlError("timeout", `No reply within ${Math.round(timeoutMs / 1000)}s.`)));
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(line));
    socket.on("data", (chunk) => {
      output += chunk;
      if (output.length > MAX_REPLY_BYTES) finish(new ControlError("bad_reply", "Reply too large."));
      if (output.includes("\n")) {
        try {
          finish(null, parseReply(output));
        } catch (error) {
          finish(error);
        }
      }
    });
    socket.on("end", () => {
      try {
        finish(null, parseReply(output));
      } catch (error) {
        finish(error);
      }
    });
    socket.on("error", (error) => {
      const message = error.code === "EACCES"
        ? `Permission denied on ${socketPath}. Ask an administrator to add your login with: sudo ./production-deploy.sh --gui-admin ${os.userInfo().username}`
        : `Cannot reach the Backup Suite broker (${error.code || error.message}).`;
      finish(new ControlError(error.code === "EACCES" ? "forbidden" : "unavailable", message));
    });
  });
}

class ControlClient {
  constructor({ env = process.env, getPreference = () => "auto" } = {}) {
    this.env = env;
    this.getPreference = getPreference;
    this.inflight = new Map();
    this.calls = 0;
    this.callsByVerb = {};
  }

  mode() {
    return detectMode(this.getPreference(), this.env);
  }

  // Returns the reply's data, or throws ControlError with the script's code.
  async call(verb, args = {}, { session = "" } = {}) {
    if (!(verb in VERBS)) throw new ControlError("invalid_request", `Unknown verb: ${verb}`);
    const changes = VERBS[verb];
    const key = changes ? null : `${verb}\u0000${JSON.stringify(args || {})}`;
    if (key && this.inflight.has(key)) return this.inflight.get(key);
    const promise = this.callNow(verb, args, session, changes);
    if (key) {
      this.inflight.set(key, promise);
      promise.finally(() => this.inflight.delete(key)).catch(() => {});
    }
    return promise;
  }

  async callNow(verb, args, session, changes) {
    const detected = this.mode();
    if (detected.mode === "none") throw new ControlError("not_installed", detected.reason);
    const request = { verb, args: args || {} };
    if (session) request.session = String(session).slice(0, 64);
    const line = `${JSON.stringify(request)}\n`;
    const timeoutMs = changes ? CHANGE_TIMEOUT_MS : READ_TIMEOUT_MS;
    this.calls += 1;
    this.callsByVerb[verb] = (this.callsByVerb[verb] || 0) + 1;
    const reply = detected.mode === "system"
      ? await callBroker(detected.socket, line, timeoutMs)
      : await callDirect(detected.script, line, timeoutMs, this.env);
    if (!reply || reply.ok !== true) {
      const error = reply && reply.error ? reply.error : { code: "bad_reply", message: "Unexpected reply." };
      throw new ControlError(error.code || "error", error.message || "The control script reported an error.");
    }
    return reply.data;
  }
}

module.exports = { ControlClient, ControlError, VERBS, brokerSocket, detectMode, userConfigFile, userControlScript };
