"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const net = require("net");
const os = require("os");
const path = require("path");

const guard = require("../lib/http-guard");
const bundle = require("../lib/bundle");
const settingsStore = require("../lib/settings");
const listenConfig = require("../lib/listen-config");
const { ControlClient, detectMode } = require("../lib/control-client");
const { EventStore } = require("../lib/events");
const { makeFixture } = require("./fixture");

// V22 -----------------------------------------------------------------------
test("Host and Origin checks accept any local port and refuse everything else", () => {
  const token = "t".repeat(43);
  const request = (method, host, origin, csrf) => ({ method, headers: { host, origin, "x-csrf-token": csrf } });
  assert.strictEqual(guard.check(request("GET", "evil.example"), "/api/health", token).code, "bad_host");
  assert.strictEqual(guard.check(request("GET", "127.0.0.1.evil.example:14337"), "/", token).code, "bad_host");
  for (const host of ["127.0.0.1:14399", "localhost:5", "[::1]:14337", "127.0.0.1", "LOCALHOST:9"]) {
    assert.strictEqual(guard.check(request("GET", host), "/api/session", token), null, host);
  }
  assert.strictEqual(guard.check(request("POST", "127.0.0.1:14400", "http://127.0.0.1:14400", token), "/api/control", token), null);
  assert.strictEqual(guard.check(request("POST", "127.0.0.1:14400", "http://127.0.0.1:14401", token), "/api/control", token).code, "bad_origin");
  assert.strictEqual(guard.check(request("POST", "127.0.0.1:14400", "https://evil.example", token), "/api/control", token).code, "bad_origin");
  assert.strictEqual(guard.check(request("POST", "127.0.0.1:14400", undefined, token), "/api/control", token).code, "bad_origin");
  assert.strictEqual(guard.check(request("POST", "127.0.0.1:14400", "http://127.0.0.1:14400", "wrong"), "/api/control", token).code, "bad_csrf");
  assert.strictEqual(guard.check(request("POST", "127.0.0.1:14400", "http://127.0.0.1:14400", undefined), "/api/settings", token).code, "bad_csrf");
  // Tunnel Manager's app window (Wails): the page is at wails.localhost and the proxy
  // forwards with Host 127.0.0.1:<port>; the CSRF token is still required.
  for (const origin of ["http://wails.localhost", "https://wails.localhost", "http://wails.localhost:34115", "wails://wails"]) {
    assert.strictEqual(guard.check(request("POST", "127.0.0.1:14337", origin, token), "/api/control", token), null, origin);
  }
  assert.strictEqual(guard.check(request("POST", "127.0.0.1:14337", "http://wails.localhost", "wrong"), "/api/control", token).code, "bad_csrf");
  for (const origin of ["http://wails.localhost.evil.example", "http://evilwails.localhost", "null"]) {
    assert.strictEqual(guard.check(request("POST", "127.0.0.1:14337", origin, token), "/api/control", token).code, "bad_origin", origin);
  }
  // Tunnel Manager's event endpoint: no CSRF token, no Origin; Host still checked.
  assert.strictEqual(guard.check(request("POST", "127.0.0.1:14337"), "/api/events", token), null);
  assert.strictEqual(guard.check(request("POST", "evil.example"), "/api/events", token).code, "bad_host");
  assert.strictEqual(guard.check(request("POST", "127.0.0.1:14337", "https://evil.example"), "/api/events", token).code, "bad_origin");
});

// V23 -----------------------------------------------------------------------
test("the Tunnel Manager bundle uses the real socket, unit and saved backend", () => {
  const settings = settingsStore.normalize({ tunnel: { backendId: "user@137.74.7.68" } });
  const listen = listenConfig.resolveListen({ env: { XDG_RUNTIME_DIR: "/run/user/1234" }, settings });
  const toml = bundle.tunnelManagerToml(bundle.profile(settings, listen, "backup-suite-gui-4337.service"));
  assert.match(toml, /^backend_id = "user@137\.74\.7\.68"$/m);
  assert.match(toml, /^remote_socket = "\/run\/user\/1234\/backup-suite-gui\/gui-4337\.sock"$/m);
  assert.match(toml, /^expect_app_id = "backup-suite-gui"$/m);
  assert.match(toml, /^minimum_severity = "warning"$/m);
  assert.match(toml, /^provider = "systemd-user"$/m);
  assert.match(toml, /^unit = "backup-suite-gui-4337\.service"$/m);
  assert.match(toml, /^policy = "start-if-stopped"$/m);
  assert.match(toml, /^preferred_port = 14337$/m);
  assert.match(toml, /^port_max = 14437$/m);
  assert.doesNotMatch(toml, /cursor_store/);
  assert.doesNotMatch(toml, /file_bridge|ssh_options|password|token/i);
  assert.doesNotMatch(toml, /remote_port/);

  const tcpSettings = settingsStore.normalize({ tunnel: { listenMode: "tcp", tcpPort: 4400 } });
  const tcpListen = listenConfig.resolveListen({ env: { XDG_RUNTIME_DIR: "/run/user/1234" }, settings: tcpSettings });
  const tcpToml = bundle.tunnelManagerToml(bundle.profile(tcpSettings, tcpListen, "backup-suite-gui-4337.service"));
  assert.match(tcpToml, /^remote_host = "127\.0\.0\.1"$/m);
  assert.match(tcpToml, /^remote_port = 4400$/m);
  assert.doesNotMatch(tcpToml, /remote_socket/);
  assert.match(tcpToml, new RegExp(`^backend_id = "${os.userInfo().username}@`, "m"));
});

test("launchers and manual line forward to the socket and check the app id", () => {
  const settings = settingsStore.normalize({ tunnel: { backendId: "user@black" } });
  const listen = listenConfig.resolveListen({ env: { XDG_RUNTIME_DIR: "/run/user/1000" }, settings });
  const profile = bundle.profile(settings, listen, "backup-suite-gui-4337.service");
  const info = bundle.connectInstructions(profile, settings);
  assert.strictEqual(info.manual.ssh, "ssh -N -L 127.0.0.1:14337:/run/user/1000/backup-suite-gui/gui-4337.sock user@black");
  for (const kind of ["windows", "mac", "linux", "android"]) {
    const file = bundle.connectFile(kind, profile);
    assert.ok(file.body.includes("/run/user/1000/backup-suite-gui/gui-4337.sock"), kind);
    assert.ok(file.body.includes("user@black"), kind);
    if (kind !== "android") assert.ok(file.body.includes("backup-suite-gui"), kind);
  }
  assert.strictEqual(bundle.connectFile("evil", profile), null);
  // Every way agentw-gui offers: profile, launchers with how-to, phone, manual, CLI.
  assert.strictEqual(info.ssh_target, "user@black");
  assert.deepStrictEqual(info.scripts.map((script) => script.platform), ["windows", "mac", "linux", "android"]);
  for (const script of info.scripts) assert.ok(script.how_to.length > 10, script.platform);
  assert.match(info.scripts.find((script) => script.platform === "mac").how_to, /chmod \+x backup-suite-gui-mac\.sh/);
  assert.match(info.mobile.android.title, /Termux/);
  assert.match(info.mobile.ios.title, /Blink/);
  assert.match(info.mobile.general.join(" "), /real OpenSSH/);
  assert.strictEqual(info.cli.bundle, "gui/scripts/backup-suite-gui-server bundle --backend user@black");
  const text = bundle.connectText(info, { toml: "/x/backup-suite-gui-tunnel-manager.toml" });
  for (const part of ["1. Tunnel Manager", "/x/backup-suite-gui-tunnel-manager.toml", "2. Launcher scripts", "3. Phone or tablet", "4. Manual", info.manual.ssh]) {
    assert.ok(text.includes(part), part);
  }
  // tcp mode: any SSH app with port forwarding works on a phone.
  const tcpSettings = settingsStore.normalize({ tunnel: { backendId: "user@black", listenMode: "tcp" } });
  const tcpProfile = bundle.profile(tcpSettings, listenConfig.resolveListen({ env: {}, settings: tcpSettings }), "u");
  assert.match(bundle.connectInstructions(tcpProfile, tcpSettings).mobile.general.join(" "), /Termius or JuiceSSH\): local 127\.0\.0\.1:14337/);
});

test("settings are clamped and an invalid backend is dropped", () => {
  const settings = settingsStore.normalize({ general: { refreshSeconds: 1, theme: "neon" }, tunnel: { backendId: "user@host; rm -rf /", localPort: 99999 } });
  assert.strictEqual(settings.general.refreshSeconds, 2);
  assert.strictEqual(settings.general.theme, "system");
  assert.strictEqual(settings.tunnel.backendId, "");
  assert.strictEqual(settings.tunnel.localPort, 65435);
  const merged = settingsStore.merge(settings, { notifications: { categories: { "run-finished": false } }, bogus: { x: 1 } });
  assert.strictEqual(merged.notifications.categories["run-finished"], false);
  assert.strictEqual(merged.notifications.categories["run-failed"], true);
  assert.ok(!("bogus" in merged));
});

// V24 -----------------------------------------------------------------------
test("mode detection: user, system, both and neither", () => {
  const fixture = makeFixture();
  try {
    const env = { ...fixture.env };
    const socketPath = path.join(fixture.root, "broker.sock");
    env.BACKUP_SUITE_CONTROL_SOCKET = socketPath;
    assert.strictEqual(detectMode("auto", env).mode, "user");
    fs.writeFileSync(socketPath, "");
    const both = detectMode("auto", env);
    assert.strictEqual(both.mode, "system");
    assert.strictEqual(both.both, true);
    assert.strictEqual(detectMode("user", env).mode, "user");
    fs.rmSync(path.join(fixture.configDir, "global.conf"));
    assert.strictEqual(detectMode("auto", env).mode, "system");
    assert.strictEqual(detectMode("user", env).mode, "none");
    fs.rmSync(socketPath);
    const none = detectMode("auto", env);
    assert.strictEqual(none.mode, "none");
    assert.match(none.reason, /not found/);
  } finally {
    fixture.cleanup();
  }
});

test("direct backend runs the real control script; identical reads are coalesced", async () => {
  const fixture = makeFixture();
  try {
    const client = new ControlClient({ env: fixture.env });
    const [first, second] = await Promise.all([client.call("status"), client.call("status")]);
    assert.strictEqual(first.mode, "user");
    assert.strictEqual(first, second);
    assert.strictEqual(client.callsByVerb.status, 1);
    const config = await client.call("config.get");
    assert.ok(!JSON.stringify(config).includes("tk_fixture_secret"));
    await assert.rejects(client.call("failures.read", { name: "../x" }), { code: "invalid_request" });
    await assert.rejects(client.call("rm -rf"), { code: "invalid_request" });
  } finally {
    fixture.cleanup();
  }
});

test("broker backend speaks one JSON line over the socket and maps refusals", async () => {
  const fixture = makeFixture();
  const socketPath = path.join(fixture.root, "broker.sock");
  const received = [];
  const server = net.createServer((connection) => {
    let buffer = "";
    connection.on("data", (chunk) => {
      buffer += chunk;
      if (!buffer.includes("\n")) return;
      const request = JSON.parse(buffer);
      received.push(request);
      const reply = request.verb === "backup.stop"
        ? { ok: false, error: { code: "forbidden", message: "uid 1 is not a member of backup-suite-gui." } }
        : { ok: true, data: { echo: request.verb, session: request.session } };
      connection.end(`${JSON.stringify(reply)}\n`);
    });
  });
  await new Promise((resolve) => server.listen(socketPath, resolve));
  try {
    fs.rmSync(path.join(fixture.configDir, "global.conf"));
    const client = new ControlClient({ env: { ...fixture.env, BACKUP_SUITE_CONTROL_SOCKET: socketPath } });
    const data = await client.call("events.stat", {}, { session: "gui-abc" });
    assert.deepStrictEqual(data, { echo: "events.stat", session: "gui-abc" });
    await assert.rejects(client.call("backup.stop"), { code: "forbidden" });
    assert.strictEqual(received.length, 2);
  } finally {
    server.close();
    fixture.cleanup();
  }
});

// V16 -----------------------------------------------------------------------
test("Tunnel Manager events: baseline, delivery once, idempotent ack, TTL, no replay after restart", async () => {
  const stateDir = fs.mkdtempSync(path.join(os.tmpdir(), "bsg-events-"));
  let now = Date.parse("2026-10-14T12:00:00Z");
  let events = [];
  let size = 0;
  const client = {
    call: async (verb, args) => {
      if (verb === "events.stat") return { size, mtime: size };
      if (verb === "events.since") {
        const fresh = events.filter((event) => event.seq > args.seq);
        return { events: fresh, latest_seq: fresh.length ? fresh[fresh.length - 1].seq : args.seq, stat: { size, mtime: size } };
      }
      throw new Error(verb);
    }
  };
  const settings = settingsStore.normalize({});
  const push = (seq, category = "watchdog-stop", ageMs = 0) => {
    events.push({ seq, id: `evt-${seq}`, created_at: new Date(now - ageMs).toISOString(), severity: "error", category, title: `t${seq}`, message: "m", unit: "file-backup.service" });
    size += 100;
  };
  try {
    push(1);
    let store = new EventStore({ client, stateDir, getSettings: () => settings, now: () => now });
    const base = await store.handle({ action: "consume", consumer_id: "pc-1", delivery_mode: "per-consumer-v1" });
    assert.strictEqual(base.body.baseline, true);
    assert.deepStrictEqual(base.body.events, []);
    assert.strictEqual(base.body.delivery_mode, "per-consumer-v1");
    assert.strictEqual(base.body.consumer_id, "pc-1");

    push(2);
    push(3, "run-finished");
    now += 3000;
    const first = await store.handle({ action: "consume", consumer_id: "pc-1" });
    assert.deepStrictEqual(first.body.events.map((event) => event.id), ["evt-2", "evt-3"]);
    assert.strictEqual(first.body.events[0].actions[0].target, "/#bell");
    const again = await store.handle({ action: "consume", consumer_id: "pc-1" });
    assert.strictEqual(again.body.events.length, 2, "claimed but unacknowledged events are offered again");
    const ack = await store.handle({ action: "ack", consumer_id: "pc-1", event_ids: ["evt-2", "evt-3"] });
    assert.strictEqual(ack.body.acknowledged, 2);
    assert.strictEqual(ack.body.delivery_mode, "per-consumer-v1");
    const ackAgain = await store.handle({ action: "ack", consumer_id: "pc-1", event_ids: ["evt-2"] });
    assert.strictEqual(ackAgain.body.acknowledged, 0);
    assert.strictEqual((await store.handle({ action: "consume", consumer_id: "pc-1" })).body.events.length, 0);

    // A second installation gets its own baseline and its own copies.
    assert.strictEqual((await store.handle({ action: "consume", consumer_id: "pc-2" })).body.baseline, true);

    // Older than 180 s from created_at: never delivered.
    push(4, "watchdog-stop", 181000);
    now += 3000;
    assert.strictEqual((await store.handle({ action: "consume", consumer_id: "pc-1" })).body.events.length, 0);

    // A disabled category is not delivered.
    settings.notifications.categories["watchdog-contain"] = false;
    push(5, "watchdog-contain");
    now += 3000;
    assert.strictEqual((await store.handle({ action: "consume", consumer_id: "pc-1" })).body.events.length, 0);

    // A restarted GUI (new store, same state directory) replays nothing.
    store = new EventStore({ client, stateDir, getSettings: () => settings, now: () => now });
    const afterRestart = await store.handle({ action: "consume", consumer_id: "pc-1" });
    assert.notStrictEqual(afterRestart.body.baseline, true);
    assert.strictEqual(afterRestart.body.events.length, 0);

    assert.strictEqual((await store.handle({ consumer_id: "" })).status, 400);
    assert.strictEqual((await store.handle({ consumer_id: "pc-1", delivery_mode: "cursor-v0" })).status, 409);
    assert.strictEqual(store.list({ cursor: 3 }).events.map((event) => event.seq).join(","), "4,5");
  } finally {
    fs.rmSync(stateDir, { recursive: true, force: true });
  }
});

// V6 ------------------------------------------------------------------------
test("the socket directory is tightened to 0700, and someone else's directory is refused", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bsg-listen-"));
  try {
    const socketDir = path.join(dir, "backup-suite-gui");
    fs.mkdirSync(socketDir, { mode: 0o755 });
    fs.chmodSync(socketDir, 0o755);
    const prepared = listenConfig.prepareSocketDirectory(socketDir);
    assert.strictEqual(prepared.tightenedFrom, "755");
    assert.strictEqual(prepared.mode, "700");
    if (process.getuid() !== 0) {
      assert.throws(() => listenConfig.prepareSocketDirectory("/tmp"), /belongs to another account/);
    }
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("live stream: a proxy's reconnects get only what they missed and cost no extra status read", async () => {
  const { Live } = require("../lib/live");
  let reads = 0;
  const client = { call: async () => { reads += 1; return { services: {}, server: { available_percent: 50 } }; } };
  const events = { onNewEvents: () => {}, refresh: async () => {}, tunnelManagerActive: () => false };
  const settings = { general: { refreshSeconds: 3600, chartMinutes: 30 } };
  const live = new Live({ client, events, getSettings: () => settings });
  const response = () => ({ text: "", write(chunk) { this.text += chunk; } });
  const idOf = (text) => [...text.matchAll(/^id: (.+)$/gm)].map((match) => match[1]).pop();

  const first = response();
  live.addClient(first);
  await new Promise((resolve) => setImmediate(resolve));
  assert.strictEqual(reads, 1);
  assert.match(first.text, /event: hello/);
  assert.match(first.text, /event: status/);
  const seen = idOf(first.text);

  // The proxy ends the response; the page reconnects with Last-Event-ID at once.
  live.removeClient(first);
  const again = response();
  live.addClient(again, seen);
  await new Promise((resolve) => setImmediate(resolve));
  assert.strictEqual(again.text, "", "nothing new: nothing sent");
  assert.strictEqual(reads, 1, "a reconnect does not read status again");

  // Something happens while the page is between reconnects; it gets exactly that.
  live.removeClient(again);
  live.broadcast("events", { events: [{ seq: 1 }] });
  const third = response();
  live.addClient(third, seen);
  assert.doesNotMatch(third.text, /event: hello/);
  assert.strictEqual((third.text.match(/^event: /gm) || []).length, 1);
  assert.match(third.text, /event: events/);

  // An id from before a restart, or one no longer kept, gets one fresh snapshot.
  const stale = response();
  live.addClient(stale, "zzzz-3");
  assert.match(stale.text, /event: hello/);
  for (const res of [third, stale]) live.removeClient(res);
  clearTimeout(live.timer);
  clearTimeout(live.idleStop);
  clearInterval(live.heartbeat);
});
