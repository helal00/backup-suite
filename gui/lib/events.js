"use strict";

// App events for Tunnel Manager (per-consumer-v1), the browser and the bell.
//
// Source: Backup Suite's events file, read through the control script (events.stat
// is cheap; events.since only runs when the file changed). Tunnel Manager consumers
// are keyed by their installation ID; each gets a silent baseline on first contact,
// claims only events newer than that, and acknowledges them. Events are deliverable
// for 180 s after their created_at; older ones are acknowledged silently. Consumer
// state is persisted, so a GUI restart replays nothing.

const fs = require("fs");
const path = require("path");

const DELIVERY_MODE = "per-consumer-v1";
const TTL_MS = 180 * 1000;
const KEEP_EVENTS = 1000;
const KEEP_ACKS = 2000;
const MAX_CONSUMERS = 64;
const CONSUMER_RE = /^[A-Za-z0-9._:-]{1,128}$/;

class EventStore {
  constructor({ client, stateDir, getSettings, now = () => Date.now(), log = () => {} }) {
    this.client = client;
    this.stateFile = path.join(stateDir, "event-consumers.json");
    this.getSettings = getSettings;
    this.now = now;
    this.log = log;
    this.events = [];
    this.latestSeq = 0;
    this.stat = null;
    this.loaded = false;
    this.refreshing = null;
    this.lastRefreshAt = 0;
    this.tunnelManagerSeenAt = 0;
    this.listeners = new Set();
    this.consumers = this.readState();
  }

  readState() {
    try {
      const data = JSON.parse(fs.readFileSync(this.stateFile, "utf8"));
      return data && typeof data.consumers === "object" ? data.consumers : {};
    } catch {
      return {};
    }
  }

  writeState() {
    fs.mkdirSync(path.dirname(this.stateFile), { recursive: true, mode: 0o700 });
    const temp = `${this.stateFile}.${process.pid}.tmp`;
    fs.writeFileSync(temp, `${JSON.stringify({ version: 1, consumers: this.consumers })}\n`, { mode: 0o600 });
    fs.renameSync(temp, this.stateFile);
  }

  onNewEvents(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  // Fetches new events when the events file changed. `knownStat` (from a status poll)
  // avoids the extra stat call.
  async refresh(knownStat = null) {
    if (this.refreshing) return this.refreshing;
    this.refreshing = (async () => {
      try {
        const stat = knownStat || await this.client.call("events.stat");
        const changed = !this.stat || stat.size !== this.stat.size || stat.mtime !== this.stat.mtime;
        if (!changed && this.loaded) return;
        const data = await this.client.call("events.since", { seq: this.loaded ? this.latestSeq : 0, limit: 1000 });
        const fresh = [];
        for (const event of data.events || []) {
          if (!event || typeof event.seq !== "number" || event.seq <= this.latestSeq) continue;
          this.events.push(event);
          fresh.push(event);
          this.latestSeq = event.seq;
        }
        if (this.events.length > KEEP_EVENTS) this.events = this.events.slice(-KEEP_EVENTS);
        this.stat = data.stat || stat;
        const firstLoad = !this.loaded;
        this.loaded = true;
        if (!firstLoad && fresh.length) {
          for (const listener of this.listeners) listener(fresh);
        }
      } finally {
        this.lastRefreshAt = this.now();
        this.refreshing = null;
      }
    })();
    return this.refreshing;
  }

  list({ cursor = 0, limit = 200 } = {}) {
    const after = Number(cursor) || 0;
    const events = this.events.filter((event) => event.seq > after).slice(-Math.min(500, Math.max(1, limit)));
    return { events, next_cursor: String(this.latestSeq), generation: "backup-suite-events" };
  }

  deliverable(event) {
    const settings = this.getSettings();
    const created = Date.parse(event.created_at || "");
    if (!Number.isFinite(created)) return false;
    if (this.now() - created > TTL_MS) return false;
    const categories = settings.notifications.categories || {};
    return categories[event.category] !== false;
  }

  tunnelManagerActive() {
    return this.now() - this.tunnelManagerSeenAt < 20000;
  }

  // POST /api/events body from Tunnel Manager.
  async handle(body) {
    const consumerId = String(body?.consumer_id || "").trim();
    if (!CONSUMER_RE.test(consumerId)) {
      return { status: 400, body: { error: "consumer_id is required" } };
    }
    const mode = String(body.delivery_mode || DELIVERY_MODE);
    if (mode !== DELIVERY_MODE) {
      return { status: 409, body: { error: `delivery_mode must be ${DELIVERY_MODE}`, delivery_mode: DELIVERY_MODE, consumer_id: consumerId } };
    }
    this.tunnelManagerSeenAt = this.now();
    const action = String(body.action || "consume");
    if (this.now() - this.lastRefreshAt > 2000 || !this.loaded) {
      try {
        await this.refresh();
      } catch (error) {
        this.log("events", `refresh failed: ${error.message}`);
      }
    }
    let consumer = this.consumers[consumerId];
    if (action === "ack") {
      const ids = new Set(Array.isArray(body.event_ids) ? body.event_ids.map(String) : []);
      let acknowledged = 0;
      if (consumer) {
        const acked = new Set(consumer.acked || []);
        for (const event of this.events) {
          if (!ids.has(event.id) || event.seq <= consumer.baseline || acked.has(event.id)) continue;
          acked.add(event.id);
          acknowledged += 1;
        }
        consumer.acked = [...acked].slice(-KEEP_ACKS);
        consumer.seen_at = new Date(this.now()).toISOString();
        this.writeState();
      }
      return { status: 200, body: { ok: true, acknowledged, consumer_id: consumerId, delivery_mode: DELIVERY_MODE } };
    }
    if (!consumer) {
      this.consumers[consumerId] = { baseline: this.latestSeq, acked: [], created_at: new Date(this.now()).toISOString() };
      const ids = Object.keys(this.consumers);
      if (ids.length > MAX_CONSUMERS) {
        ids.sort((a, b) => String(this.consumers[a].seen_at || this.consumers[a].created_at).localeCompare(String(this.consumers[b].seen_at || this.consumers[b].created_at)));
        for (const id of ids.slice(0, ids.length - MAX_CONSUMERS)) delete this.consumers[id];
      }
      this.writeState();
      return {
        status: 200,
        body: { events: [], next_cursor: String(this.latestSeq), generation: "backup-suite-events", delivery_mode: DELIVERY_MODE, consumer_id: consumerId, baseline: true }
      };
    }
    const settings = this.getSettings();
    const limit = Math.max(1, Math.min(500, Number(body.limit) || 100));
    const acked = new Set(consumer.acked || []);
    const claimed = [];
    let expired = false;
    for (const event of this.events) {
      if (event.seq <= consumer.baseline || acked.has(event.id)) continue;
      if (!settings.notifications.tunnelManager || !this.deliverable(event)) {
        acked.add(event.id);
        expired = true;
        continue;
      }
      claimed.push(toTunnelManagerEvent(event));
      if (claimed.length >= limit) break;
    }
    consumer.seen_at = new Date(this.now()).toISOString();
    if (expired) consumer.acked = [...acked].slice(-KEEP_ACKS);
    this.writeState();
    return {
      status: 200,
      body: { events: claimed, next_cursor: String(this.latestSeq), generation: "backup-suite-events", delivery_mode: DELIVERY_MODE, consumer_id: consumerId }
    };
  }
}

function toTunnelManagerEvent(event) {
  return {
    id: event.id,
    type: event.category,
    severity: event.severity,
    title: event.title,
    message: event.message,
    resource_id: event.unit || "",
    url: "/#bell",
    actions: [{ id: "open", label: "Open", kind: "url", target: "/#bell" }],
    created_at: event.created_at
  };
}

module.exports = { DELIVERY_MODE, EventStore, TTL_MS, toTunnelManagerEvent };
