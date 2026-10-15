"use strict";

// Backup Suite GUI server. Runs as the admin login's systemd user unit
// (backup-suite-gui-4337.service), listens on a private Unix socket by default, and
// reaches Backup Suite only through bin/backup-control.sh (directly in user mode, via
// the root broker socket in system mode). Node standard library only.

const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const settingsStore = require("./lib/settings");
const listenConfig = require("./lib/listen-config");
const { ControlClient } = require("./lib/control-client");
const { EventStore } = require("./lib/events");
const { Live } = require("./lib/live");
const bundle = require("./lib/bundle");
const guard = require("./lib/http-guard");

const ROOT = __dirname;
const PUBLIC_DIR = path.join(ROOT, "public");
const VERSION = JSON.parse(fs.readFileSync(path.join(ROOT, "package.json"), "utf8")).version;
const UNIT_NAME = `backup-suite-gui-${listenConfig.INSTANCE}.service`;
const MAX_BODY_BYTES = 256 * 1024;
const STARTED_AT = new Date().toISOString();
// The build of the page files this server serves: a hash of public/. A page that
// loaded another build is told to reload (its reload button turns red), and asset
// URLs carry it (?v=) so a reload never gets an old app.js from a cache.
const BUILD = (() => {
  const crypto = require("crypto");
  const digest = crypto.createHash("sha256");
  const walk = (dir) => {
    for (const name of fs.readdirSync(dir).sort()) {
      const full = path.join(dir, name);
      if (fs.statSync(full).isDirectory()) walk(full);
      else digest.update(name).update(fs.readFileSync(full));
    }
  };
  walk(path.join(ROOT, "public"));
  return digest.digest("hex").slice(0, 12);
})();

const STATIC_TYPES = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".webmanifest": "application/manifest+json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon"
};

function log(area, message) {
  process.stdout.write(`${new Date().toISOString()} [${area}] ${message}\n`);
}

function createApp({ env = process.env } = {}) {
  let settings = settingsStore.load(env);
  const stateDir = settingsStore.stateDir(env);
  fs.mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  const csrfToken = guard.newToken();
  const client = new ControlClient({ env, getPreference: () => settings.general.backend });
  const events = new EventStore({ client, stateDir, getSettings: () => settings, log });
  const live = new Live({ client, events, getSettings: () => settings, log, build: BUILD, idleStopMs: Number(env.BACKUP_SUITE_GUI_STREAM_GRACE_MS) || undefined });
  let listen = listenConfig.resolveListen({ env, settings });

  function sendJson(res, status, body) {
    const text = JSON.stringify(body);
    res.writeHead(status, {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff"
    });
    res.end(text);
  }

  function sendError(res, status, code, message) {
    sendJson(res, status, { ok: false, error: { code, message } });
  }

  function readBody(req) {
    return new Promise((resolve, reject) => {
      let size = 0;
      const chunks = [];
      req.on("data", (chunk) => {
        size += chunk.length;
        if (size > MAX_BODY_BYTES) {
          reject(Object.assign(new Error("Request body too large."), { httpStatus: 413 }));
          req.destroy();
          return;
        }
        chunks.push(chunk);
      });
      req.on("end", () => {
        if (!chunks.length) return resolve({});
        try {
          resolve(JSON.parse(Buffer.concat(chunks).toString("utf8")));
        } catch {
          reject(Object.assign(new Error("The request body must be JSON."), { httpStatus: 400 }));
        }
      });
      req.on("error", reject);
    });
  }

  function loginName() {
    try {
      return os.userInfo().username;
    } catch {
      return env.USER || "";
    }
  }

  function modeReport() {
    const detected = client.mode();
    return {
      mode: detected.mode,
      reason: detected.reason,
      both: detected.both,
      user_installed: detected.userInstalled,
      system_installed: detected.systemInstalled,
      user_config: detected.userConfig,
      socket: detected.socket,
      label: detected.mode === "system"
        ? `system mode · ${os.hostname()}`
        : detected.mode === "user" ? `user mode · ${loginName()}@${os.hostname()}` : "Backup Suite not found"
    };
  }

  function listenReport() {
    return {
      mode: listen.mode,
      source: listen.source,
      socket_path: listen.socketPath,
      tcp_port: listen.port,
      warning: listen.warning,
      saved_mode: settings.tunnel.listenMode,
      restart_required: settings.tunnel.listenMode !== listen.mode && listen.source !== "env"
    };
  }

  function connectProfile() {
    return bundle.profile(settings, listen, UNIT_NAME);
  }

  function serveStatic(req, res, pathname) {
    let relative = pathname === "/" ? "/index.html" : pathname;
    try {
      relative = decodeURIComponent(relative);
    } catch {
      return sendError(res, 400, "bad_path", "Bad path.");
    }
    const file = path.normalize(path.join(PUBLIC_DIR, relative));
    if (!file.startsWith(PUBLIC_DIR + path.sep)) return sendError(res, 404, "not_found", "Not found.");
    let data;
    try {
      data = fs.readFileSync(file);
    } catch {
      return sendError(res, 404, "not_found", "Not found.");
    }
    if (file.endsWith(".html")) {
      data = Buffer.from(data.toString("utf8").replace(/(src|href)="\/(app\.js|help\.js|theme-boot\.js|styles\.css)"/g, `$1="/$2?v=${BUILD}"`));
    }
    // Revalidated on every load (ETag), so a page reload always gets the files this
    // server has now.
    const etag = `"${BUILD}-${path.basename(file)}"`;
    if (req.headers["if-none-match"] === etag) {
      res.writeHead(304, { ETag: etag, "Cache-Control": "no-cache" });
      return res.end();
    }
    const type = STATIC_TYPES[path.extname(file)] || "application/octet-stream";
    res.writeHead(200, {
      "Content-Type": type,
      ETag: etag,
      "Cache-Control": "no-cache",
      "X-Content-Type-Options": "nosniff",
      "Referrer-Policy": "no-referrer",
      "Content-Security-Policy": "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; manifest-src 'self'; worker-src 'self'; frame-ancestors 'self'; base-uri 'none'; form-action 'self'"
    });
    res.end(req.method === "HEAD" ? undefined : data);
  }

  async function handleApi(req, res, url) {
    const pathname = url.pathname;
    const session = String(req.headers["x-page-session"] || "").replace(/[^A-Za-z0-9-]/g, "").slice(0, 40);

    if (req.method === "GET" && pathname === "/api/health") {
      return sendJson(res, 200, {
        ok: true, app: bundle.APP_ID, app_id: bundle.APP_ID, name: bundle.APP_NAME, version: VERSION, build: BUILD,
        started_at: STARTED_AT, at: new Date().toISOString(), mode: client.mode().mode, listen: { mode: listen.mode },
        features: { health: true, app_events: true, browser_notifications: true }
      });
    }

    if (req.method === "GET" && pathname === "/api/session") {
      return sendJson(res, 200, {
        ok: true, csrf: csrfToken, app: bundle.APP_ID, name: bundle.APP_NAME, version: VERSION, build: BUILD, login: loginName(),
        host: os.hostname(), unit: UNIT_NAME, backend: modeReport(), listen: listenReport(), settings,
        categories: settingsStore.CATEGORY_LABELS, tunnel_manager_active: events.tunnelManagerActive()
      });
    }

    if (req.method === "GET" && pathname === "/api/stream") {
      res.writeHead(200, {
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Accel-Buffering": "no",
        Connection: "keep-alive"
      });
      res.write("retry: 3000\n\n");
      live.addClient(res, req.headers["last-event-id"]);
      req.on("close", () => live.removeClient(res));
      return undefined;
    }

    if (req.method === "POST" && pathname === "/api/control") {
      const body = await readBody(req);
      const verb = String(body.verb || "");
      try {
        const data = await client.call(verb, body.args || {}, { session: session ? `gui-${session}` : "gui" });
        if (["profile.set", "profile.limits", "profile.override", "config.set", "backup.start", "backup.stop", "timer.set", "notify.test"].includes(verb)) {
          log("action", `${verb} ok`);
          setTimeout(() => live.nudge(), 300).unref?.();
          events.refresh().catch(() => {});
        }
        return sendJson(res, 200, { ok: true, data });
      } catch (error) {
        const status = error.code === "invalid_request" ? 400 : error.code === "forbidden" ? 403 : error.code === "config_conflict" ? 409 : error.code === "not_installed" ? 503 : 502;
        return sendError(res, status, error.code || "error", error.message);
      }
    }

    if (req.method === "GET" && pathname === "/api/settings") {
      return sendJson(res, 200, { ok: true, settings, listen: listenReport(), categories: settingsStore.CATEGORY_LABELS });
    }

    if (req.method === "POST" && pathname === "/api/settings") {
      const body = await readBody(req);
      const before = settings;
      settings = settingsStore.save(settingsStore.merge(settings, body.settings || {}), env);
      const restartRequired = before.tunnel.listenMode !== settings.tunnel.listenMode
        || before.tunnel.tcpPort !== settings.tunnel.tcpPort
        || JSON.stringify(before.limits) !== JSON.stringify(settings.limits);
      if (before.general.backend !== settings.general.backend) live.nudge();
      log("settings", "saved");
      return sendJson(res, 200, { ok: true, settings, restart_required: restartRequired, listen: listenReport() });
    }

    if (req.method === "POST" && pathname === "/api/gui/restart") {
      if (!env.INVOCATION_ID) {
        return sendError(res, 409, "not_systemd", "The GUI is not running under systemd; restart it by hand.");
      }
      sendJson(res, 202, { ok: true, restart_in_ms: 1200 });
      const timer = setTimeout(() => {
        const child = spawn("systemctl", ["--user", "restart", UNIT_NAME], { detached: true, stdio: "ignore" });
        child.on("error", () => {});
        child.unref();
      }, 1200);
      timer.unref?.();
      return undefined;
    }

    if (req.method === "GET" && pathname === "/api/connect") {
      return sendJson(res, 200, { ok: true, ...bundle.connectInstructions(connectProfile(), settings) });
    }

    if (req.method === "POST" && pathname === "/api/connect/backend") {
      const body = await readBody(req);
      const value = String(body.backend_id || "").trim();
      const merged = settingsStore.merge(settings, { tunnel: { backendId: value } });
      if (value && merged.tunnel.backendId !== value) {
        return sendError(res, 400, "invalid_request", "Use the form login@host, for example user@203.0.113.10.");
      }
      settings = settingsStore.save(merged, env);
      return sendJson(res, 200, { ok: true, ...bundle.connectInstructions(connectProfile(), settings) });
    }

    if (req.method === "GET" && pathname === "/api/connect/file") {
      const file = bundle.connectFile(String(url.searchParams.get("kind") || ""), connectProfile());
      if (!file) return sendError(res, 400, "invalid_request", "Unknown connection file.");
      res.writeHead(200, {
        "Content-Type": file.contentType,
        "Content-Disposition": `attachment; filename="${file.fileName}"`,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff"
      });
      return res.end(file.body);
    }

    if (req.method === "GET" && pathname === "/api/events") {
      try {
        await events.refresh();
      } catch (error) {
        log("events", error.message);
      }
      const cursor = Number(url.searchParams.get("cursor") || 0);
      const limit = Number(url.searchParams.get("limit") || 200);
      return sendJson(res, 200, events.list({ cursor, limit }));
    }

    if (req.method === "POST" && pathname === "/api/events") {
      const body = await readBody(req);
      const result = await events.handle(body);
      return sendJson(res, result.status, result.body);
    }

    if (req.method === "GET" && pathname === "/api/chart") {
      return sendJson(res, 200, { ok: true, chart: live.chart });
    }

    if (req.method === "GET" && pathname === "/api/diagnostics") {
      return sendJson(res, 200, {
        ok: true, control_calls: client.calls, control_calls_by_verb: client.callsByVerb, stream_clients: live.clients.size,
        memory_rss: process.memoryUsage().rss, uptime_s: Math.round(process.uptime())
      });
    }

    return sendError(res, 404, "not_found", "Unknown API endpoint.");
  }

  async function handle(req, res) {
    let url;
    try {
      url = new URL(req.url, "http://127.0.0.1");
    } catch {
      return sendError(res, 400, "bad_request", "Bad request.");
    }
    const refusal = guard.check(req, url.pathname, csrfToken);
    if (refusal) return sendError(res, refusal.status, refusal.code, refusal.message);
    try {
      if (url.pathname.startsWith("/api/")) return await handleApi(req, res, url);
      if (req.method !== "GET" && req.method !== "HEAD") return sendError(res, 405, "method", "Method not allowed.");
      return serveStatic(req, res, url.pathname);
    } catch (error) {
      log("error", `${req.method} ${url.pathname}: ${error.message}`);
      if (!res.headersSent) sendError(res, error.httpStatus || 500, "error", error.message);
      else res.end();
      return undefined;
    }
  }

  return { handle, client, events, live, settings: () => settings, listen: () => listen, setListen: (value) => { listen = value; }, csrfToken };
}

async function start() {
  const app = createApp();
  const listen = app.listen();
  const servers = [];
  if (listen.socket) {
    if (!listen.forwardable) throw new Error(`The socket path ${listen.socketPath} cannot be forwarded (it must be absolute, without spaces or colons).`);
    const prepared = listenConfig.prepareSocketDirectory(listen.socketDir);
    if (prepared.tightenedFrom) log("listen", `tightened ${listen.socketDir} from ${prepared.tightenedFrom} to 700`);
    const stale = await listenConfig.clearStaleSocket(listen.socketPath);
    if (stale === "in-use") throw new Error(`Another process already listens on ${listen.socketPath}.`);
    const server = http.createServer(app.handle);
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      const previous = process.umask(0o177);
      server.listen(listen.socketPath, () => {
        process.umask(previous);
        resolve();
      });
    });
    listenConfig.confirmSocketPrivate(listen.socketPath);
    servers.push(server);
    log("listen", `socket ${listen.socketPath}`);
  }
  if (listen.tcp) {
    const server = http.createServer(app.handle);
    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(listen.port, listenConfig.TCP_LISTEN_HOST, resolve);
    });
    servers.push(server);
    log("listen", `tcp ${listenConfig.TCP_LISTEN_HOST}:${listen.port} (${listenConfig.TCP_WARNING})`);
  }
  const detected = app.client.mode();
  log("start", `${bundle.APP_NAME} ${VERSION}; backend ${detected.mode} (${detected.reason})`);
  const stop = () => {
    for (const server of servers) server.close();
    if (listen.socket) {
      try {
        fs.unlinkSync(listen.socketPath);
      } catch {
        // already gone
      }
    }
    process.exit(0);
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
}

if (require.main === module) {
  start().catch((error) => {
    log("fatal", error.message);
    process.exit(1);
  });
}

module.exports = { createApp, UNIT_NAME, VERSION };
