"use strict";

// The server end to end over HTTP, against the real control script (user mode).

const test = require("node:test");
const assert = require("node:assert");
const fs = require("fs");
const http = require("http");
const path = require("path");

const { makeFixture, appendEvent } = require("./fixture");

function request(port, method, pathname, { headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, method, path: pathname, headers: { Host: `127.0.0.1:${port}`, ...headers } }, (res) => {
      let data = "";
      res.setEncoding("utf8");
      res.on("data", (chunk) => { data += chunk; });
      res.on("end", () => {
        let json = null;
        try {
          json = JSON.parse(data);
        } catch {
          json = null;
        }
        resolve({ status: res.statusCode, headers: res.headers, text: data, json });
      });
    });
    req.on("error", reject);
    if (body !== undefined) req.end(JSON.stringify(body));
    else req.end();
  });
}

function openStream(port) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: "127.0.0.1", port, path: "/api/stream", headers: { Host: `127.0.0.1:${port}` } }, (res) => {
      const stream = { res, req, text: "" };
      res.setEncoding("utf8");
      res.on("data", (chunk) => { stream.text += chunk; });
      resolve(stream);
    });
    req.on("error", reject);
    req.end();
  });
}

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

test("HTTP API: health, guard, control, settings, connect, events and one shared status poll", async () => {
  const fixture = makeFixture();
  fs.mkdirSync(fixture.env.BACKUP_SUITE_GUI_CONFIG_DIR, { recursive: true });
  fs.writeFileSync(path.join(fixture.env.BACKUP_SUITE_GUI_CONFIG_DIR, "config.json"), JSON.stringify({ general: { refreshSeconds: 2 }, tunnel: { backendId: "user@137.74.7.68" } }));
  const { createApp } = require("../server");
  const app = createApp({ env: fixture.env });
  const server = http.createServer(app.handle);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;
  const origin = `http://127.0.0.1:${port}`;
  const streams = [];
  try {
    const health = await request(port, "GET", "/api/health");
    assert.strictEqual(health.status, 200);
    assert.strictEqual(health.json.app_id, "backup-suite-gui");
    assert.strictEqual(health.json.mode, "user");

    assert.strictEqual((await request(port, "GET", "/api/health", { headers: { Host: "evil.example" } })).status, 403);

    const page = await request(port, "GET", "/");
    assert.strictEqual(page.status, 200);
    assert.match(page.headers["content-security-policy"], /script-src 'self'/);
    assert.strictEqual((await request(port, "GET", "/../package.json")).status, 404);
    assert.strictEqual((await request(port, "GET", "/%2e%2e/server.js")).status, 404);

    const session = await request(port, "GET", "/api/session");
    const csrf = session.json.csrf;
    assert.ok(csrf.length >= 40);
    assert.strictEqual(session.json.backend.mode, "user");

    const noToken = await request(port, "POST", "/api/control", { headers: { Origin: origin, "Content-Type": "application/json" }, body: { verb: "status" } });
    assert.strictEqual(noToken.status, 403);
    const foreign = await request(port, "POST", "/api/control", { headers: { Origin: "http://evil.example", "X-CSRF-Token": csrf }, body: { verb: "status" } });
    assert.strictEqual(foreign.status, 403);
    const headers = { Origin: origin, "X-CSRF-Token": csrf, "Content-Type": "application/json", "X-Page-Session": "abc-123" };
    const status = await request(port, "POST", "/api/control", { headers, body: { verb: "status" } });
    assert.strictEqual(status.status, 200);
    assert.strictEqual(status.json.data.mode, "user");
    const refused = await request(port, "POST", "/api/control", { headers, body: { verb: "backup.start", args: { what: "all" } } });
    assert.strictEqual(refused.status, 400);
    assert.strictEqual(refused.json.error.code, "invalid_request");

    const start = await request(port, "POST", "/api/control", { headers, body: { verb: "backup.start", args: { what: "files" } } });
    assert.strictEqual(start.status, 200);
    const audit = fs.readFileSync(path.join(fixture.stateDir, "gui", "audit.jsonl"), "utf8");
    assert.match(audit, /"session": "gui-abc-123"/);

    const saved = await request(port, "POST", "/api/settings", { headers, body: { settings: { general: { theme: "dark", refreshSeconds: 2 }, tunnel: { listenMode: "tcp" } } } });
    assert.strictEqual(saved.json.settings.general.theme, "dark");
    assert.strictEqual(saved.json.restart_required, true);
    const stored = JSON.parse(fs.readFileSync(path.join(fixture.env.BACKUP_SUITE_GUI_CONFIG_DIR, "config.json"), "utf8"));
    assert.strictEqual(stored.general.theme, "dark");
    assert.strictEqual(fs.statSync(path.join(fixture.env.BACKUP_SUITE_GUI_CONFIG_DIR, "config.json")).mode & 0o777, 0o600);

    const connect = await request(port, "GET", "/api/connect");
    assert.strictEqual(connect.json.backend_id, "user@137.74.7.68");
    const badBackend = await request(port, "POST", "/api/connect/backend", { headers, body: { backend_id: "not valid" } });
    assert.strictEqual(badBackend.status, 400);
    const toml = await request(port, "GET", "/api/connect/file?kind=toml");
    assert.match(toml.headers["content-disposition"], /backup-suite-gui-tunnel-manager\.toml/);
    assert.match(toml.text, /expect_app_id = "backup-suite-gui"/);

    // Tunnel Manager: no CSRF token, no Origin.
    const baseline = await request(port, "POST", "/api/events", { headers: { "Content-Type": "application/json" }, body: { action: "consume", consumer_id: "tm-install-1", delivery_mode: "per-consumer-v1" } });
    assert.strictEqual(baseline.status, 200);
    assert.strictEqual(baseline.json.baseline, true);
    appendEvent(fixture.stateDir, { seq: 900, id: "evt-900-1", created_at: new Date().toISOString(), severity: "error", category: "watchdog-stop", title: "stopped", message: "m", unit: "file-backup.service" });
    await wait(2100);
    const delivered = await request(port, "POST", "/api/events", { headers: { "Content-Type": "application/json" }, body: { action: "consume", consumer_id: "tm-install-1" } });
    assert.ok(delivered.json.events.some((event) => event.id === "evt-900-1"), JSON.stringify(delivered.json));
    const listed = await request(port, "GET", "/api/events?cursor=0");
    assert.ok(listed.json.events.some((event) => event.id === "evt-900-1"));

    // V8: three tabs share one status read per interval.
    const before = app.client.callsByVerb.status || 0;
    for (let index = 0; index < 3; index += 1) streams.push(await openStream(port));
    await wait(4500);
    const during = (app.client.callsByVerb.status || 0) - before;
    assert.ok(during >= 2 && during <= 4, `expected 2-4 shared status reads in 4.5 s with three tabs, got ${during}`);
    for (const stream of streams) assert.match(stream.text, /event: status/);

    // V7 (automated part): no tab, no polling.
    for (const stream of streams) stream.req.destroy();
    await wait(300);
    const idleStart = app.client.callsByVerb.status || 0;
    await wait(4200);
    assert.strictEqual((app.client.callsByVerb.status || 0) - idleStart, 0, "status was polled with no tab open");

    const diagnostics = await request(port, "GET", "/api/diagnostics");
    assert.ok(diagnostics.json.memory_rss > 0);
  } finally {
    for (const stream of streams) stream.req.destroy();
    server.close();
    fixture.cleanup();
  }
});

test("the GUI never reads Backup Suite files directly (all access goes through the control client)", () => {
  const sources = ["server.js", ...fs.readdirSync(path.join(__dirname, "..", "lib")).map((name) => path.join("lib", name))];
  for (const file of sources) {
    const text = fs.readFileSync(path.join(__dirname, "..", file), "utf8");
    assert.doesNotMatch(text, /\/etc\/backup-suite|\/var\/lib\/backup-suite|rclone\.conf|history\.tsv|events\.jsonl|file-sources\.conf/, file);
  }
  // Mode detection only checks that global.conf exists; it never reads it.
  const client = fs.readFileSync(path.join(__dirname, "..", "lib", "control-client.js"), "utf8");
  assert.doesNotMatch(client, /readFileSync|createReadStream|readFile\(/);
});
