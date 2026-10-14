"use strict";

// Where the GUI listens; the same model as agentw-gui's listen-config.js.
//
// - socket: a Unix socket (mode 0600 in a 0700 directory). Only this account can open
//   it; an SSH tunnel forwards a local port to it (`ssh -L PORT:/path/to.sock`), and the
//   server end of that connection is opened as the SSH login user.
// - tcp:    127.0.0.1:PORT. Every local account on the server can reach it.
// - both:   the socket and the TCP port.
//
// Mode: BACKUP_SUITE_GUI_LISTEN, else the saved setting, else socket.
// Socket: BACKUP_SUITE_GUI_SOCKET, else ${XDG_RUNTIME_DIR:-~/.local/state}/backup-suite-gui/gui-<instance>.sock.

const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const LISTEN_MODES = ["socket", "tcp", "both"];
const INSTANCE = 4337;
const TCP_LISTEN_HOST = "127.0.0.1";
const TCP_WARNING = "This GUI is reachable by every local account on the server.";

function normalizeListenMode(value) {
  const mode = String(value || "").trim().toLowerCase();
  return LISTEN_MODES.includes(mode) ? mode : "";
}

function defaultSocketPath(env = process.env) {
  if (String(env.BACKUP_SUITE_GUI_SOCKET || "").trim()) return path.resolve(String(env.BACKUP_SUITE_GUI_SOCKET).trim());
  const base = String(env.XDG_RUNTIME_DIR || "").trim()
    || path.join(String(env.HOME || "").trim() || os.homedir(), ".local", "state");
  return path.join(base, "backup-suite-gui", `gui-${INSTANCE}.sock`);
}

// Tunnel Manager and OpenSSH need an absolute path without spaces or colons.
function socketPathForwardable(socketPath) {
  return path.isAbsolute(String(socketPath || "")) && !/[\s:]/.test(String(socketPath));
}

function resolveListen({ env = process.env, settings } = {}) {
  const envMode = normalizeListenMode(env.BACKUP_SUITE_GUI_LISTEN);
  const storedMode = normalizeListenMode(settings?.tunnel?.listenMode);
  const mode = envMode || storedMode || "socket";
  const envPort = Number(env.BACKUP_SUITE_GUI_PORT || 0);
  const port = envPort > 0 ? envPort : Number(settings?.tunnel?.tcpPort || INSTANCE);
  const socketPath = defaultSocketPath(env);
  return {
    mode,
    source: envMode ? "env" : (storedMode ? "settings" : "default"),
    instance: INSTANCE,
    port,
    host: TCP_LISTEN_HOST,
    socketPath,
    socketDir: path.dirname(socketPath),
    socket: mode !== "tcp",
    tcp: mode !== "socket",
    forwardable: socketPathForwardable(socketPath),
    warning: mode === "socket" ? "" : TCP_WARNING
  };
}

function modeString(stat) {
  return (stat.mode & 0o777).toString(8).padStart(3, "0");
}

// The socket's directory: 0700 and ours. A directory we own that is wider is
// tightened to 0700; anything owned by someone else stops the start.
function prepareSocketDirectory(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  let stat = fs.lstatSync(dir);
  if (!stat.isDirectory()) throw new Error(`Refusing to listen: ${dir} is not a directory.`);
  const uid = typeof process.getuid === "function" ? process.getuid() : null;
  if (uid !== null && stat.uid !== uid) {
    throw new Error(`Refusing to listen: ${dir} belongs to another account (uid ${stat.uid}).`);
  }
  let tightenedFrom = "";
  if ((stat.mode & 0o077) !== 0) {
    tightenedFrom = modeString(stat);
    fs.chmodSync(dir, 0o700);
    stat = fs.lstatSync(dir);
    if ((stat.mode & 0o077) !== 0) {
      throw new Error(`Refusing to listen: ${dir} is accessible to group or others (mode ${modeString(stat)}).`);
    }
  }
  return { dir, mode: modeString(stat), tightenedFrom };
}

function socketAnswers(socketPath, timeoutMs = 1500) {
  return new Promise((resolve) => {
    const socket = net.connect({ path: socketPath });
    const done = (value) => {
      socket.removeAllListeners();
      socket.destroy();
      resolve(value);
    };
    socket.setTimeout(timeoutMs, () => done(true));
    socket.once("connect", () => done(true));
    socket.once("error", () => done(false));
  });
}

// A leftover socket file is removed only when nothing listens on it.
async function clearStaleSocket(socketPath) {
  let stat;
  try {
    stat = fs.lstatSync(socketPath);
  } catch (error) {
    if (error.code === "ENOENT") return "free";
    throw error;
  }
  if (!stat.isSocket()) throw new Error(`Refusing to listen: ${socketPath} exists and is not a socket.`);
  if (await socketAnswers(socketPath)) return "in-use";
  fs.unlinkSync(socketPath);
  return "removed-stale";
}

function confirmSocketPrivate(socketPath) {
  fs.chmodSync(socketPath, 0o600);
  const stat = fs.lstatSync(socketPath);
  const uid = typeof process.getuid === "function" ? process.getuid() : null;
  if (!stat.isSocket() || (stat.mode & 0o177) !== 0 || (uid !== null && stat.uid !== uid)) {
    throw new Error(`The GUI socket ${socketPath} is not private (mode ${modeString(stat)}).`);
  }
  return modeString(stat);
}

module.exports = {
  INSTANCE,
  LISTEN_MODES,
  TCP_LISTEN_HOST,
  TCP_WARNING,
  clearStaleSocket,
  confirmSocketPrivate,
  defaultSocketPath,
  normalizeListenMode,
  prepareSocketDirectory,
  resolveListen,
  socketAnswers,
  socketPathForwardable
};
