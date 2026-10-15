"use strict";

// Live status for every open tab: one `status` read per interval, fanned out over
// Server-Sent Events. Nothing is polled while no tab is connected. A bounded
// in-memory chart buffer keeps backup memory, CPU and server RAM for new tabs.
//
// Tunnel Manager's app window cannot stream: its proxy ends an event-stream response
// once it has news and the page reconnects. So every message has an id
// (<epoch>-<seq>), a reconnection that sends Last-Event-ID gets only the messages it
// missed (or one fresh snapshot when they are no longer kept), and polling carries on
// for a short grace period while no window is connected, so a reconnect never triggers
// an extra status read.

const HEARTBEAT_MS = 15000;
const REPLAY_KEEP = 50;
const IDLE_STOP_MS = 15000;
const EPOCH = Date.now().toString(36);

class Live {
  constructor({ client, events, getSettings, log = () => {}, idleStopMs = IDLE_STOP_MS }) {
    this.client = client;
    this.events = events;
    this.getSettings = getSettings;
    this.log = log;
    this.clients = new Set();
    this.timer = null;
    this.heartbeat = null;
    this.idleStop = null;
    this.idleStopMs = idleStopMs;
    this.seq = 0;
    this.recent = [];
    this.lastStatus = null;
    this.lastError = null;
    this.chart = [];
    this.polling = false;
    this.events.onNewEvents((fresh) => this.broadcast("events", { events: fresh, tunnel_manager_active: this.events.tunnelManagerActive() }));
  }

  chartCapacity() {
    const settings = this.getSettings();
    return Math.ceil((settings.general.chartMinutes * 60) / settings.general.refreshSeconds) + 1;
  }

  currentId() {
    return `${EPOCH}-${this.seq}`;
  }

  // The messages after Last-Event-ID, or null when they are not all kept (another
  // epoch, too old or unknown): then the client gets a fresh snapshot.
  missedSince(lastEventId) {
    const match = /^([0-9a-z]+)-([0-9]+)$/.exec(String(lastEventId || ""));
    if (!match || match[1] !== EPOCH) return null;
    const seen = Number(match[2]);
    if (seen > this.seq) return null;
    if (seen === this.seq) return [];
    const missed = this.recent.filter((message) => message.seq > seen);
    if (missed.length === 0 || missed[0].seq !== seen + 1) return null;
    return missed;
  }

  addClient(res, lastEventId = "") {
    this.clients.add(res);
    if (this.idleStop) clearTimeout(this.idleStop);
    this.idleStop = null;
    const missed = this.missedSince(lastEventId);
    if (missed === null) {
      this.send(res, "hello", { chart: this.chart, status: this.lastStatus, error: this.lastError }, this.currentId());
    } else {
      for (const message of missed) this.write(res, message.text);
    }
    if (!this.heartbeat) {
      this.heartbeat = setInterval(() => {
        for (const client of this.clients) this.write(client, ": keepalive\n\n");
      }, HEARTBEAT_MS);
      this.heartbeat.unref?.();
    }
    if (!this.timer && !this.polling) this.poll();
  }

  removeClient(res) {
    this.clients.delete(res);
    if (this.clients.size > 0 || this.idleStop) return;
    this.idleStop = setTimeout(() => {
      this.idleStop = null;
      if (this.clients.size > 0) return;
      if (this.timer) clearTimeout(this.timer);
      this.timer = null;
      if (this.heartbeat) clearInterval(this.heartbeat);
      this.heartbeat = null;
    }, this.idleStopMs);
    this.idleStop.unref?.();
  }

  write(res, text) {
    try {
      res.write(text);
    } catch {
      this.removeClient(res);
    }
  }

  send(res, type, data, id = "") {
    this.write(res, `event: ${type}\n${id ? `id: ${id}\n` : ""}data: ${JSON.stringify(data)}\n\n`);
  }

  broadcast(type, data) {
    this.seq += 1;
    const text = `event: ${type}\nid: ${this.currentId()}\ndata: ${JSON.stringify(data)}\n\n`;
    this.recent.push({ seq: this.seq, text });
    if (this.recent.length > REPLAY_KEEP) this.recent.splice(0, this.recent.length - REPLAY_KEEP);
    for (const client of this.clients) this.write(client, text);
  }

  // Requests an immediate refresh (after an action), keeping one poll at a time.
  nudge() {
    if ((this.clients.size === 0 && !this.idleStop) || this.polling) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.poll();
  }

  async poll() {
    this.timer = null;
    if (this.clients.size === 0 && !this.idleStop) return;
    this.polling = true;
    try {
      const status = await this.client.call("status");
      this.lastStatus = status;
      this.lastError = null;
      this.addChartPoint(status);
      this.broadcast("status", { status, point: this.chart[this.chart.length - 1] || null });
      if (status.events) {
        this.events.refresh(status.events).catch((error) => this.log("events", error.message));
      }
    } catch (error) {
      this.lastError = { code: error.code || "error", message: error.message };
      this.broadcast("status-error", this.lastError);
    } finally {
      this.polling = false;
      if (this.clients.size > 0 || this.idleStop) {
        this.timer = setTimeout(() => this.poll(), this.getSettings().general.refreshSeconds * 1000);
        this.timer.unref?.();
      }
    }
  }

  addChartPoint(status) {
    const service = status.services?.["file-backup.service"] || {};
    const running = service.ActiveState === "active" || service.ActiveState === "activating";
    const watchdog = status.watchdog || {};
    const number = (value) => {
      const parsed = Number(value);
      return Number.isFinite(parsed) ? parsed : null;
    };
    this.chart.push({
      t: Date.now(),
      memory: running ? number(watchdog.memory_bytes) : null,
      memoryMax: running ? number(watchdog.memory_max_bytes) : null,
      cpu: running ? number(watchdog.cpu_percent) : null,
      available: number(status.server?.available_percent)
    });
    const capacity = this.chartCapacity();
    if (this.chart.length > capacity) this.chart.splice(0, this.chart.length - capacity);
  }
}

module.exports = { Live };
