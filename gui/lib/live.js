"use strict";

// Live status for every open tab: one `status` read per interval, fanned out over
// Server-Sent Events. Nothing is polled while no tab is connected. A bounded
// in-memory chart buffer keeps backup memory, CPU and server RAM for new tabs.

const HEARTBEAT_MS = 15000;

class Live {
  constructor({ client, events, getSettings, log = () => {} }) {
    this.client = client;
    this.events = events;
    this.getSettings = getSettings;
    this.log = log;
    this.clients = new Set();
    this.timer = null;
    this.heartbeat = null;
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

  addClient(res) {
    this.clients.add(res);
    this.send(res, "hello", { chart: this.chart, status: this.lastStatus, error: this.lastError });
    if (!this.heartbeat) {
      this.heartbeat = setInterval(() => {
        for (const client of this.clients) client.write(": keepalive\n\n");
      }, HEARTBEAT_MS);
      this.heartbeat.unref?.();
    }
    if (!this.timer && !this.polling) this.poll();
  }

  removeClient(res) {
    this.clients.delete(res);
    if (this.clients.size === 0) {
      if (this.timer) clearTimeout(this.timer);
      this.timer = null;
      if (this.heartbeat) clearInterval(this.heartbeat);
      this.heartbeat = null;
    }
  }

  send(res, type, data) {
    try {
      res.write(`event: ${type}\ndata: ${JSON.stringify(data)}\n\n`);
    } catch {
      this.removeClient(res);
    }
  }

  broadcast(type, data) {
    for (const client of this.clients) this.send(client, type, data);
  }

  // Requests an immediate refresh (after an action), keeping one poll at a time.
  nudge() {
    if (this.clients.size === 0 || this.polling) return;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.poll();
  }

  async poll() {
    this.timer = null;
    if (this.clients.size === 0) return;
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
      if (this.clients.size > 0) {
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
