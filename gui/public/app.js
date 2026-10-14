// Backup Suite GUI front end. Vanilla JS, no build step. Every server change goes
// through a confirmation dialog; every value from the server is inserted as text.
(() => {
  "use strict";

  const PROFILE_ORDER = ["slow", "moderate", "fast"];
  const SECTIONS = {
    overview: "Overview",
    runs: "Runs",
    projects: "Projects & changing files",
    profiles: "Profiles & limits",
    watchdog: "Watchdog",
    notifications: "Notifications (ntfy)",
    sources: "Sources",
    activity: "Activity & audit"
  };
  const SETUP_CHOICES = [
    { id: "fixed-slow", label: "Fixed slow", args: { mode: "fixed", profile: "slow" }, note: "Lowest server impact, longest runs." },
    { id: "fixed-moderate", label: "Fixed moderate", args: { mode: "fixed", profile: "moderate" }, note: "Balanced; validated in production." },
    { id: "fixed-fast", label: "Fixed fast", args: { mode: "fixed", profile: "fast" }, note: "Quickest runs, noticeably more load." },
    { id: "adaptive-moderate-slow", label: "Adaptive moderate ↔ slow", args: { mode: "adaptive", top: "moderate", floor: "slow" }, note: "Recommended: moderate, stepping down to slow when resources are tight (2 steps)." },
    { id: "adaptive-fast-slow", label: "Adaptive fast ↔ moderate ↔ slow", args: { mode: "adaptive", top: "fast", floor: "slow" }, note: "Starts fast and steps down one level at a time (3 steps)." }
  ];
  const WATCHDOG_GROUPS = [
    ["Sampling", ["WATCHDOG_INTERVAL_SECONDS"]],
    ["Containment", ["WATCHDOG_CONTAIN_PERCENT", "WATCHDOG_CONTAIN_RELEASE_PERCENT", "WATCHDOG_SWAP_CONTAIN_PERCENT", "WATCHDOG_TASKS_WARN_PERCENT"]],
    ["Stopping the backup", ["WATCHDOG_KILL_PERCENT", "WATCHDOG_KILL_SAMPLES", "WATCHDOG_SWAP_KILL_PERCENT", "WATCHDOG_KILL_GRACE_SECONDS"]],
    ["Server protection", ["WATCHDOG_SYSTEM_MIN_AVAILABLE_PERCENT", "WATCHDOG_SYSTEM_CRITICAL_AVAILABLE_PERCENT", "WATCHDOG_SYSTEM_PSI_FULL_LIMIT", "WATCHDOG_PSI_PAUSE_AVAILABLE_PERCENT", "WATCHDOG_PAUSE_MIN_FOOTPRINT_MB", "WATCHDOG_PRESSURE_SUSTAIN_SECONDS", "WATCHDOG_FREEZE_MAX_SECONDS", "WATCHDOG_RETRY_WAIT_SECONDS", "WATCHDOG_RETRY_CLEAR_SECONDS"]],
    ["Adaptive steps", ["WATCHDOG_ADAPTIVE_STEP_DOWN_AVAILABLE_PERCENT", "WATCHDOG_ADAPTIVE_STEP_DOWN_PSI_FULL", "WATCHDOG_ADAPTIVE_STEP_UP_AVAILABLE_PERCENT", "WATCHDOG_ADAPTIVE_STEP_UP_SECONDS", "WATCHDOG_ADAPTIVE_COOLDOWN_SECONDS", "WATCHDOG_NOTIFY_PROFILE_STEPS"]]
  ];
  const NTFY_KEYS = ["NOTIFY_FAILURES_ENABLED", "NOTIFY_NTFY_TOPIC_URL", "NOTIFY_NTFY_TOKEN", "NOTIFY_NTFY_PRIORITY", "NOTIFY_NTFY_TITLE_PREFIX", "NOTIFY_NTFY_ATTACH_DETAILS", "NOTIFY_NTFY_MESSAGE_MAX_BYTES"];
  const SERVER_KEYS = ["FILE_BACKUP_RUNTIME_MAX_SEC", "FILE_RETENTION_DAYS", "FILE_ACTIVE_TRACKING_ENABLED", "FILE_ACTIVE_WINDOW_SECONDS", "FILE_ACTIVE_MAX_DEFERRALS"];
  const SEEN_KEY = "backup-suite-gui-events-seen";

  const state = {
    session: null,
    csrf: "",
    settings: null,
    status: null,
    statusError: null,
    profiles: null,
    history: null,
    chart: [],
    events: [],
    tunnelManagerActive: false,
    section: "overview",
    connected: false,
    sessionId: (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2)).slice(0, 36),
    seenSeq: Number(storageGet(SEEN_KEY) || 0),
    runsView: { outcome: "", eventsOnly: false, sort: "started", descending: true }
  };

  // ------------------------------------------------------------------ utilities

  function storageGet(key) {
    try {
      return window.localStorage.getItem(key);
    } catch {
      return null;
    }
  }

  function storageSet(key, value) {
    try {
      window.localStorage.setItem(key, value);
    } catch {
      // Storage unavailable (private window): per-viewer conveniences only.
    }
  }

  function $(selector, root = document) {
    return root.querySelector(selector);
  }

  function h(tag, attributes, ...children) {
    const element = document.createElement(tag);
    for (const [key, value] of Object.entries(attributes || {})) {
      if (value === null || value === undefined || value === false) continue;
      if (key === "class") element.className = value;
      // CSSOM, not a style attribute: the page's Content-Security-Policy blocks inline style attributes.
      else if (key === "style" && typeof value === "object") Object.assign(element.style, value);
      else if (key === "dataset") Object.assign(element.dataset, value);
      else if (key.startsWith("on") && typeof value === "function") element.addEventListener(key.slice(2), value);
      else if (value === true) element.setAttribute(key, "");
      else element.setAttribute(key, String(value));
    }
    append(element, children);
    return element;
  }

  function append(parent, children) {
    for (const child of children.flat(Infinity)) {
      if (child === null || child === undefined || child === false) continue;
      parent.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return parent;
  }

  function clear(element) {
    while (element.firstChild) element.removeChild(element.firstChild);
    return element;
  }

  function bytes(value) {
    const number = Number(value);
    if (value === null || value === undefined || value === "" || !Number.isFinite(number)) return "—";
    if (number >= 1024 ** 3) return `${(number / 1024 ** 3).toFixed(2)} GiB`;
    if (number >= 1024 ** 2) return `${(number / 1024 ** 2).toFixed(number >= 100 * 1024 ** 2 ? 0 : 1)} MiB`;
    if (number >= 1024) return `${(number / 1024).toFixed(0)} KiB`;
    return `${number} B`;
  }

  function duration(seconds) {
    const total = Math.max(0, Math.round(Number(seconds) || 0));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    if (hours) return `${hours} h ${minutes} min`;
    if (minutes) return `${minutes} min`;
    return `${total} s`;
  }

  function numberOrNull(value) {
    const number = Number(value);
    return value === null || value === undefined || value === "" || !Number.isFinite(number) ? null : number;
  }

  // systemd prints "Wed 2026-10-14 16:07:28 UTC"; the watchdog writes ISO times; the
  // durable log writes "2026-10-14 16:05:00 UTC".
  function parseTime(text) {
    if (!text || text === "n/a" || text === "0") return null;
    if (text instanceof Date) return text;
    const iso = Date.parse(text);
    if (Number.isFinite(iso) && /T/.test(text)) return new Date(iso);
    const match = String(text).match(/(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:\.\d+)?\s*(UTC|Z)?/);
    if (!match) return null;
    if (match[7] || /UTC/.test(text)) {
      return new Date(Date.UTC(+match[1], +match[2] - 1, +match[3], +match[4], +match[5], +match[6]));
    }
    return new Date(+match[1], +match[2] - 1, +match[3], +match[4], +match[5], +match[6]);
  }

  function formatUtc(date) {
    return `${date.toISOString().slice(0, 19).replace("T", " ")} UTC`;
  }

  function formatLocal(date) {
    return date.toLocaleString(undefined, { year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" });
  }

  function timeNode(value) {
    const date = parseTime(value);
    if (!date) return h("span", { class: "muted" }, value ? String(value) : "—");
    const local = (state.settings?.general?.timeDisplay || "utc") === "local";
    return h("time", { datetime: date.toISOString(), title: local ? formatUtc(date) : `Your time: ${formatLocal(date)}` }, local ? formatLocal(date) : formatUtc(date));
  }

  function relative(date) {
    if (!date) return "";
    const seconds = Math.round((Date.now() - date.getTime()) / 1000);
    if (seconds < 0) return `in ${duration(-seconds)}`;
    return `${duration(seconds)} ago`;
  }

  function pill(text, kind) {
    return h("span", { class: `pill ${kind || ""}` }, text);
  }

  function toast(message, kind = "info", timeoutMs = 6000) {
    const element = h("div", { class: `toast ${kind}` }, message);
    $("#toast-region").append(element);
    setTimeout(() => element.remove(), timeoutMs);
  }

  function errorText(error) {
    if (!error) return "Unknown error.";
    return error.code ? `${error.message} (${error.code})` : error.message || String(error);
  }

  // ------------------------------------------------------------------ server calls

  async function api(path, { method = "GET", body } = {}) {
    const headers = { "X-Page-Session": state.sessionId };
    if (method !== "GET") {
      headers["Content-Type"] = "application/json";
      headers["X-CSRF-Token"] = state.csrf;
    }
    let response;
    try {
      response = await fetch(path, { method, headers, body: body === undefined ? undefined : JSON.stringify(body), credentials: "same-origin" });
    } catch (error) {
      throw { code: "network", message: "The server could not be reached. Check the tunnel." };
    }
    let data = null;
    try {
      data = await response.json();
    } catch {
      data = null;
    }
    if (!response.ok || (data && data.ok === false)) {
      const error = data?.error || { code: `http_${response.status}`, message: response.statusText || "Request failed." };
      if (error.code === "bad_csrf") toast("The page token is stale. Reload the GUI.", "error");
      throw error;
    }
    return data;
  }

  async function control(verb, args = {}) {
    const data = await api("/api/control", { method: "POST", body: { verb, args } });
    return data.data;
  }

  // ------------------------------------------------------------------ dialogs and panels

  function confirmAction({ title = "Please confirm", lines = [], okLabel = "Confirm", danger = false }) {
    const dialog = $("#confirm-dialog");
    $("#confirm-title").textContent = title;
    const body = clear($("#confirm-body"));
    for (const line of lines) {
      if (Array.isArray(line)) body.append(h("ul", {}, line.map((item) => h("li", {}, item))));
      else if (line instanceof Node) body.append(line);
      else body.append(h("p", {}, line));
    }
    const ok = $("#confirm-ok");
    ok.textContent = okLabel;
    ok.className = danger ? "danger-button" : "primary-button";
    dialog.returnValue = "";
    dialog.showModal();
    ok.focus();
    return new Promise((resolve) => {
      dialog.addEventListener("close", () => resolve(dialog.returnValue === "ok"), { once: true });
    });
  }

  function showHelp(topic) {
    const help = window.BACKUP_SUITE_HELP?.[topic];
    if (!help) return;
    $("#help-title").textContent = `Help: ${help.title}`;
    const body = clear($("#help-body"));
    for (const [heading, text] of help.sections) {
      body.append(h("h3", {}, heading), h("p", {}, text));
    }
    $("#help-panel").hidden = false;
    $("#help-close").focus();
  }

  function showDetails(title, nodes) {
    $("#details-title").textContent = title;
    append(clear($("#details-body")), [nodes]);
    $("#layout").classList.remove("details-closed");
    if (window.matchMedia("(max-width: 960px)").matches) showPanel("details");
  }

  function showPanel(name) {
    const layout = $("#layout");
    layout.classList.remove("show-sidebar", "show-details");
    if (name === "sidebar") layout.classList.add("show-sidebar");
    if (name === "details") layout.classList.add("show-details");
    for (const button of document.querySelectorAll("[data-show-panel]")) {
      button.classList.toggle("active", button.dataset.showPanel === name);
    }
  }

  function textBlock(lines, { searchable = true, fileName = "backup-suite.log" } = {}) {
    const text = Array.isArray(lines) ? lines.join("\n") : String(lines || "");
    const pre = h("pre", { class: "log-view", tabindex: "0" }, text || "(empty)");
    const wrapper = h("div", {});
    const tools = h("div", { class: "toolbar-row tight" },
      h("button", { type: "button", onclick: () => copyText(text) }, "Copy"),
      h("button", { type: "button", onclick: () => download(fileName, text) }, "Download"));
    if (searchable) {
      const input = h("input", { type: "search", placeholder: "Search this log", "aria-label": "Search this log" });
      const count = h("span", { class: "muted" });
      input.addEventListener("input", () => {
        const term = input.value.trim().toLowerCase();
        clear(pre);
        if (!term) {
          pre.textContent = text;
          count.textContent = "";
          return;
        }
        let matches = 0;
        for (const line of text.split("\n")) {
          if (line.toLowerCase().includes(term)) {
            matches += 1;
            const index = line.toLowerCase().indexOf(term);
            pre.append(line.slice(0, index), h("mark", {}, line.slice(index, index + term.length)), line.slice(index + term.length), "\n");
          }
        }
        count.textContent = `${matches} matching line${matches === 1 ? "" : "s"}`;
      });
      wrapper.append(h("div", { class: "search-row" }, input, count));
    }
    wrapper.append(pre, tools);
    return wrapper;
  }

  async function copyText(text) {
    try {
      await navigator.clipboard.writeText(text);
      toast("Copied.");
    } catch {
      toast("Copy failed; select the text and copy it by hand.", "warn");
    }
  }

  function download(fileName, text) {
    const url = URL.createObjectURL(new Blob([text], { type: "text/plain;charset=utf-8" }));
    const link = h("a", { href: url, download: fileName });
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  function loadingNode(text = "Loading…") {
    return h("p", { class: "muted" }, text);
  }

  function errorNode(error) {
    return h("div", { class: "notice bad", role: "alert" }, errorText(error));
  }

  // ------------------------------------------------------------------ status model

  function fileBackupState(status) {
    if (!status) return { key: "unknown", label: "Checking…" };
    const service = status.services?.["file-backup.service"] || {};
    const active = service.ActiveState;
    const watchdog = status.watchdog || {};
    const progress = status.progress || {};
    if (active === "deactivating") return { key: "paused", label: "Stopping" };
    if (active === "active" || active === "activating") {
      const index = numberOrNull(progress.project_index);
      const total = numberOrNull(progress.projects_total);
      const where = index && total ? ` ${index}/${total}` : "";
      if (watchdog.state === "paused") return { key: "paused", label: `Paused by watchdog${where}` };
      return { key: "running", label: `Running${where}${progress.profile ? ` · ${progress.profile}` : ""}`, contained: watchdog.state === "contained" };
    }
    if (service.Result && service.Result !== "success") return { key: "failed", label: "Failed (last run)" };
    return { key: "idle", label: "Idle" };
  }

  function watchdogFresh(status) {
    const service = status?.services?.["file-backup.service"] || {};
    return (service.ActiveState === "active" || service.ActiveState === "activating") && status?.watchdog;
  }

  function updateChrome() {
    const backupState = fileBackupState(state.status);
    const chip = $("#state-chip");
    chip.className = `state-chip state-${backupState.key}`;
    chip.textContent = state.statusError && !state.status ? "Status unavailable" : backupState.label;
    const timerEnabled = state.status?.timers_enabled?.["file-backup.timer"];
    if (state.status && timerEnabled && timerEnabled !== "enabled") {
      chip.className = "state-chip state-warn";
      chip.textContent = `${backupState.label} · schedule OFF`;
    }
    const unseen = state.events.filter((event) => event.seq > state.seenSeq).length;
    const badge = $("#bell-badge");
    badge.hidden = unseen === 0;
    badge.textContent = unseen > 99 ? "99+" : String(unseen);
  }

  // ------------------------------------------------------------------ gauges and chart

  function gauge({ label, value, max, text, marks = [], warnAt = 80, badAt = 90, inverse = false, note }) {
    const percent = max ? Math.max(0, Math.min(100, (value / max) * 100)) : 0;
    let level = "ok";
    if (percent >= badAt) level = "bad";
    else if (percent >= warnAt) level = "warn";
    const word = level === "bad" ? (inverse ? "critical" : "high") : level === "warn" ? "elevated" : "normal";
    const track = h("div", { class: "gauge-track", role: "meter", "aria-valuemin": "0", "aria-valuemax": "100", "aria-valuenow": String(Math.round(percent)), "aria-label": `${label}: ${text}, ${word}` },
      h("div", { class: `gauge-fill ${level === "ok" ? "" : level}`, style: { width: `${percent.toFixed(1)}%` } }),
      marks.filter((mark) => mark.at > 0 && mark.at < 100).map((mark) => h("span", { class: "gauge-mark", style: { left: `${mark.at.toFixed(1)}%` }, title: mark.title })));
    return h("div", { class: "gauge" },
      h("div", { class: "gauge-label" }, h("span", {}, label), h("strong", {}, `${text} · ${word}`)),
      track,
      note ? h("div", { class: "gauge-note" }, note) : null);
  }

  function resourceGauges(status) {
    const nodes = [];
    const server = status.server || {};
    const watchdog = status.watchdog || {};
    const pausePercent = numberOrNull(watchdog.threshold_server_pause_percent) ?? 10;
    const criticalPercent = numberOrNull(watchdog.threshold_server_critical_percent) ?? 4;
    if (watchdogFresh(status)) {
      const memory = numberOrNull(watchdog.memory_bytes) || 0;
      const memoryMax = numberOrNull(watchdog.memory_max_bytes);
      const memoryHigh = numberOrNull(watchdog.memory_high_bytes);
      const contain = numberOrNull(watchdog.threshold_contain_percent) ?? 80;
      const kill = numberOrNull(watchdog.threshold_kill_percent) ?? 90;
      if (memoryMax) {
        nodes.push(gauge({
          label: "Backup memory", value: memory, max: memoryMax, warnAt: contain, badAt: kill,
          text: `${bytes(memory)} of ${bytes(memoryMax)}`,
          marks: [
            memoryHigh ? { at: (memoryHigh / memoryMax) * 100, title: `Throttle (MemoryHigh) ${bytes(memoryHigh)}` } : null,
            { at: contain, title: `Watchdog contains at ${contain}%` },
            { at: kill, title: `Watchdog stops at ${kill}% (non-reclaimable)` }
          ].filter(Boolean),
          note: memoryHigh ? `Throttled above ${bytes(memoryHigh)}; hard limit ${bytes(memoryMax)}.` : null
        }));
        const anon = numberOrNull(watchdog.memory_anon_bytes) || 0;
        nodes.push(gauge({ label: "Non-reclaimable memory", value: anon, max: memoryMax, warnAt: contain, badAt: kill, text: `${bytes(anon)} of ${bytes(memoryMax)}`, marks: [{ at: kill, title: `Stop at ${kill}%` }] }));
      }
      const swap = numberOrNull(watchdog.swap_bytes) || 0;
      const swapMax = numberOrNull(watchdog.swap_max_bytes);
      if (swapMax) {
        const swapContain = numberOrNull(watchdog.threshold_swap_contain_percent) ?? 80;
        const swapKill = numberOrNull(watchdog.threshold_swap_kill_percent) ?? 95;
        nodes.push(gauge({ label: "Backup swap", value: swap, max: swapMax, warnAt: swapContain, badAt: swapKill, text: `${bytes(swap)} of ${bytes(swapMax)}`, marks: [{ at: swapContain, title: "Contain" }, { at: swapKill, title: "Stop" }] }));
      }
      const cpu = numberOrNull(watchdog.cpu_percent) || 0;
      const quota = numberOrNull(watchdog.cpu_quota_percent);
      if (quota) {
        nodes.push(gauge({ label: "Backup CPU", value: cpu, max: quota, warnAt: 90, badAt: 101, text: `${cpu}% of ${quota}% quota` }));
      }
      const tasks = numberOrNull(watchdog.tasks) || 0;
      const tasksMax = numberOrNull(watchdog.tasks_max);
      if (tasksMax) nodes.push(gauge({ label: "Backup tasks", value: tasks, max: tasksMax, warnAt: 90, badAt: 98, text: `${tasks} of ${tasksMax}` }));
      nodes.push(h("p", { class: "gauge-note" }, `Disk this run: read ${bytes(watchdog.io_read_bytes)}, written ${bytes(watchdog.io_write_bytes)}. Peaks: ${bytes(watchdog.peak_memory_bytes)} RAM, ${watchdog.peak_cpu_percent ?? "—"}% CPU, ${watchdog.peak_tasks ?? "—"} tasks.`));
    } else {
      nodes.push(h("p", { class: "muted" }, "No backup is running. Backup gauges appear while one runs; the server's memory is shown below."));
    }
    const available = numberOrNull(server.available_percent);
    if (available !== null) {
      const used = 100 - available;
      nodes.push(gauge({
        label: "Server RAM in use", value: used, max: 100, warnAt: 100 - pausePercent, badAt: 100 - criticalPercent, inverse: true,
        text: `${available}% available (${bytes(server.available_bytes)} of ${bytes(server.total_bytes)})`,
        marks: [{ at: 100 - pausePercent, title: `Watchdog pauses the backup below ${pausePercent}% available` }, { at: 100 - criticalPercent, title: `Watchdog stops the backup below ${criticalPercent}% available` }]
      }));
    }
    const psi = numberOrNull(server.psi_full_avg10);
    if (psi !== null) {
      const psiLimit = numberOrNull(watchdog.threshold_psi_full) ?? 20;
      const stallAvailable = numberOrNull(watchdog.threshold_psi_pause_available_percent) ?? 20;
      nodes.push(gauge({ label: "Memory pressure (PSI full avg10)", value: psi, max: Math.max(psiLimit * 1.25, 1), warnAt: 50, badAt: 80, text: `${psi} (pauses at ${psiLimit} only below ${stallAvailable}% RAM available)`, marks: [{ at: 80, title: `Pause at ${psiLimit} while RAM available is below ${stallAvailable}%` }] }));
    }
    if (watchdog.server_pressure === "host-stall" && watchdog.server_pressure_note) {
      nodes.push(h("p", { class: "gauge-note" }, `Memory stall not caused by the backup: ${watchdog.server_pressure_note}. The backup keeps running.`));
    }
    return nodes;
  }

  function chartNode(points) {
    const width = 600;
    const height = 140;
    const left = 34;
    const bottom = 18;
    const usable = points.slice(-Math.max(2, points.length));
    const svgNs = "http://www.w3.org/2000/svg";
    const svg = document.createElementNS(svgNs, "svg");
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    svg.setAttribute("class", "chart");
    svg.setAttribute("role", "img");
    const lastMemory = [...usable].reverse().find((point) => point.memory !== null);
    svg.setAttribute("aria-label", lastMemory ? `Backup memory ${bytes(lastMemory.memory)}, CPU ${lastMemory.cpu ?? "—"}%, over the last ${state.settings?.general?.chartMinutes || 30} minutes` : "No backup ran in the chart window");
    const line = (cls, x1, y1, x2, y2) => {
      const element = document.createElementNS(svgNs, "line");
      element.setAttribute("class", cls);
      element.setAttribute("x1", x1);
      element.setAttribute("y1", y1);
      element.setAttribute("x2", x2);
      element.setAttribute("y2", y2);
      svg.append(element);
    };
    const label = (text, x, y) => {
      const element = document.createElementNS(svgNs, "text");
      element.setAttribute("x", x);
      element.setAttribute("y", y);
      element.textContent = text;
      svg.append(element);
    };
    line("axis", left, height - bottom, width, height - bottom);
    line("axis", left, 4, left, height - bottom);
    label("100%", 0, 12);
    label("0", 20, height - bottom);
    if (usable.length < 2) {
      label("Collecting data…", left + 10, height / 2);
      return svg;
    }
    const start = usable[0].t;
    const end = usable[usable.length - 1].t;
    const span = Math.max(1, end - start);
    const x = (t) => left + ((t - start) / span) * (width - left - 4);
    const y = (percent) => (height - bottom) - (Math.max(0, Math.min(100, percent)) / 100) * (height - bottom - 6);
    const series = (cls, valueOf) => {
      let path = "";
      let drawing = false;
      for (const point of usable) {
        const value = valueOf(point);
        if (value === null || value === undefined) {
          drawing = false;
          continue;
        }
        path += `${drawing ? "L" : "M"}${x(point.t).toFixed(1)},${y(value).toFixed(1)} `;
        drawing = true;
      }
      if (!path) return;
      const element = document.createElementNS(svgNs, "path");
      element.setAttribute("class", cls);
      element.setAttribute("d", path.trim());
      svg.append(element);
    };
    series("line-available", (point) => point.available);
    series("line-memory", (point) => (point.memory !== null && point.memoryMax ? (point.memory / point.memoryMax) * 100 : null));
    series("line-cpu", (point) => point.cpu);
    label(`${Math.round(span / 60000)} min`, width - 44, height - 4);
    return svg;
  }

  // ------------------------------------------------------------------ sections

  const renderers = {};

  renderers.overview = (body) => {
    const status = state.status;
    if (!status) {
      body.append(state.statusError ? errorNode(state.statusError) : loadingNode());
      if (state.statusError?.code === "not_installed" || state.statusError?.code === "forbidden") body.append(installHelp());
      return;
    }
    const backupState = fileBackupState(status);
    const progress = status.progress || {};
    const service = status.services?.["file-backup.service"] || {};
    const running = backupState.key === "running" || backupState.key === "paused";
    const cards = h("div", { class: "cards" });

    const statusRows = [["State", pill(backupState.label, backupState.key === "running" ? "info" : backupState.key === "failed" ? "bad" : backupState.key === "paused" ? "warn" : "ok")]];
    if (running) {
      const started = parseTime(progress.started_at) || parseTime(service.ExecMainStartTimestamp);
      statusRows.push(["Started", h("span", {}, timeNode(progress.started_at || service.ExecMainStartTimestamp), started ? ` (${relative(started)})` : "")]);
      if (progress.projects_total) statusRows.push(["Progress", `project ${progress.project_index || 0} of ${progress.projects_total}`]);
      if (progress.current_project) statusRows.push(["Current project", h("code", {}, progress.current_project)]);
      statusRows.push(["So far", `synced ${progress.synced || 0}, skipped ${progress.skipped || 0}, deferred ${(Number(progress.skipped_changed) || 0) + (Number(progress.deferred_active) || 0)}, failed ${progress.failed || 0}`]);
      if (backupState.contained) statusRows.push(["Watchdog", pill("containing a memory surge", "warn")]);
    } else {
      statusRows.push(["Last finished", timeNode(service.ExecMainExitTimestamp || progress.updated_at)]);
      if (progress.outcome) statusRows.push(["Last outcome", progress.outcome]);
    }
    const lastAction = status.watchdog_last_action;
    if (lastAction?.reason) statusRows.push(["Last watchdog stop", h("span", {}, lastAction.reason, " ", timeNode(lastAction.at || lastAction.time))]);
    cards.append(h("section", { class: "card" }, h("h3", {}, "File backup"), kv(statusRows)));

    const timerEnabled = status.timers_enabled?.["file-backup.timer"];
    const timer = status.timers?.["file-backup.timer"] || {};
    const scheduleOff = timerEnabled !== "enabled" || timer.ActiveState !== "active";
    const scheduleCard = h("section", { class: `card wide ${scheduleOff ? "alert-warn" : ""}` }, h("h3", {}, "Schedule"));
    if (scheduleOff) scheduleCard.append(h("p", { class: "notice", role: "alert" }, "Scheduled file backups are OFF. Enable file-backup.timer to resume them."));
    scheduleCard.append(timersTable(status));
    cards.append(scheduleCard);

    const profileCard = h("section", { class: "card" }, h("h3", {}, "Resource profile"));
    if (state.profiles) {
      const level = status.adaptive_level || state.profiles.current_level;
      profileCard.append(kv([
        ["Setup", state.profiles.mode === "adaptive" ? `Adaptive ${state.profiles.ladder.join(" ↔ ")}` : `Fixed: ${state.profiles.ladder[0]}`],
        ["Now", state.profiles.mode === "adaptive" ? `${level}${progress.profile && running ? ` (this run: ${progress.profile})` : ""}` : state.profiles.ladder[0]],
        ["Limits", state.profiles.limits_mode]
      ]));
    } else {
      profileCard.append(loadingNode());
    }
    profileCard.append(h("div", { class: "toolbar-row tight" }, h("button", { type: "button", dataset: { key: "change-profile" }, onclick: () => navigate("profiles") }, "Change…")));
    cards.append(profileCard);

    const resources = h("section", { class: "card wide" }, h("h3", {}, "Resources (live)"), resourceGauges(status));
    cards.append(resources);

    cards.append(h("section", { class: "card wide" }, h("h3", {}, `Last ${state.settings?.general?.chartMinutes || 30} minutes`),
      chartNode(state.chart),
      h("div", { class: "legend" }, h("span", { class: "memory" }, "Backup memory (% of hard limit)"), h("span", { class: "cpu" }, "Backup CPU %"), h("span", { class: "available" }, "Server RAM available %"))));

    const lastRun = state.history?.rows?.[0];
    const runCard = h("section", { class: "card" }, h("h3", {}, "Last recorded run"));
    if (lastRun) {
      runCard.append(kv([
        ["Started", timeNode(lastRun.started)],
        ["Outcome", pill(lastRun.outcome, lastRun.outcome === "completed" ? "ok" : "bad")],
        ["Duration", duration(lastRun.duration_s)],
        ["Peak RAM", `${bytes(lastRun.peak_mem)} (${bytes(lastRun.peak_anon)} not reclaimable)`],
        ["CPU", `avg ${lastRun.avg_cpu_pct ?? "—"}%, peak ${lastRun.peak_cpu_pct ?? "—"}%`],
        ["Profile", lastRun.profile],
        ["Watchdog events", lastRun.events.length ? lastRun.events.join(", ") : "none"]
      ]), h("div", { class: "toolbar-row tight" }, h("button", { type: "button", dataset: { key: "open-last-run" }, onclick: () => openRun(lastRun) }, "Open run")));
    } else {
      runCard.append(h("p", { class: "muted" }, state.history ? "No run has been recorded by the watchdog yet." : "Loading…"));
    }
    cards.append(runCard);

    const dbRows = ["database-backup.service", "database-size-check.service"].map((unit) => {
      const info = status.services?.[unit] || {};
      const ok = !info.Result || info.Result === "success";
      return [unit.replace(".service", ""), h("span", {}, pill(info.ActiveState === "active" ? "running" : ok ? "ok" : info.Result, info.ActiveState === "active" ? "info" : ok ? "ok" : "bad"), " last ", timeNode(info.ExecMainExitTimestamp || info.InactiveEnterTimestamp))];
    });
    cards.append(h("section", { class: "card" }, h("h3", {}, "Database backups"), kv(dbRows)));

    cards.append(h("section", { class: "card" }, h("h3", {}, "Actions"),
      h("div", { class: "toolbar-row tight" },
        h("button", { type: "button", class: "primary-button", dataset: { key: "start-files" }, disabled: running, onclick: () => runAction("start-files") }, "Start file backup now"),
        h("button", { type: "button", class: "danger-button", dataset: { key: "stop-files" }, disabled: !running, onclick: () => runAction("stop-files") }, "Stop file backup")),
      h("div", { class: "toolbar-row tight" },
        h("button", { type: "button", dataset: { key: "start-databases" }, onclick: () => runAction("start-databases") }, "Start database backup now"),
        h("button", { type: "button", dataset: { key: "notify-test" }, onclick: () => runAction("notify-test") }, "Send test notification"))));

    body.append(cards);
  };

  function kv(rows) {
    const list = h("dl", { class: "kv" });
    for (const [key, value] of rows) list.append(h("dt", {}, key), h("dd", {}, value));
    return list;
  }

  function timersTable(status) {
    const rows = ["file-backup.timer", "database-backup.timer", "database-size-check.timer"].map((timer) => {
      const info = status.timers?.[timer] || {};
      const enabled = status.timers_enabled?.[timer] || "unknown";
      const on = enabled === "enabled" && info.ActiveState === "active";
      return h("tr", {},
        h("td", {}, timer.replace(".timer", "")),
        h("td", {}, pill(on ? "on" : `${enabled}/${info.ActiveState || "?"}`, on ? "ok" : "warn")),
        h("td", {}, timeNode(info.LastTriggerUSec)),
        h("td", {}, timeNode(info.NextElapseUSecRealtime)),
        h("td", {}, h("button", { type: "button", dataset: { key: `timer-${timer}` }, onclick: () => toggleTimer(timer, !on) }, on ? "Turn off…" : "Turn on…")));
    });
    return h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, h("th", {}, "Timer"), h("th", {}, "State"), h("th", {}, "Last run"), h("th", {}, "Next run"), h("th", {}, ""))),
      h("tbody", {}, rows)));
  }

  function installHelp() {
    const mode = state.session?.backend || {};
    return h("div", { class: "notice info" },
      h("p", {}, mode.reason || ""),
      h("p", {}, "User mode: install Backup Suite for this login with ./setup.sh (no sudo). System mode: an administrator runs sudo ./production-deploy.sh --gui-admin ", state.session?.login || "<login>", " so this login may use the broker."));
  }

  async function runAction(action) {
    const running = ["running", "paused"].includes(fileBackupState(state.status).key);
    const plans = {
      "start-files": {
        title: "Start a file backup now?",
        lines: ["Starts file-backup.service now, with the current resource profile and the watchdog.", "It runs for as long as it needs; you do not have to keep the GUI open."],
        okLabel: "Start backup",
        verb: "backup.start", args: { what: "files" }, done: "File backup started."
      },
      "stop-files": {
        title: "Stop the running file backup?",
        lines: ["Stops file-backup.service.", ["Finished projects stay backed up.", "The current project is redone by the next run.", "Nothing on Google Drive is deleted by a stop.", "The schedule (timer) is not changed."]],
        okLabel: "Stop backup", danger: true,
        verb: "backup.stop", args: {}, done: "Stopping the file backup."
      },
      "start-databases": {
        title: "Start a database backup now?",
        lines: ["Starts database-backup.service now."],
        okLabel: "Start database backup",
        verb: "backup.start", args: { what: "databases" }, done: "Database backup started."
      },
      "notify-test": {
        title: "Send a test notification?",
        lines: ["Sends one ntfy message in the real alert format, with a description and an attached detail file.", "It also appears in the bell and, as a warning, in Tunnel Manager."],
        okLabel: "Send",
        verb: "notify.test", args: {}, done: "Test notification sent."
      }
    };
    const plan = plans[action];
    if (!plan) return;
    if (action === "start-files" && running) {
      toast("A file backup is already running.", "warn");
      return;
    }
    if (action === "stop-files" && !running) {
      toast("No file backup is running.", "warn");
      return;
    }
    if (!(await confirmAction(plan))) return;
    try {
      const result = await control(plan.verb, plan.args);
      toast(result?.output ? `${plan.done} ${String(result.output).split("\n").pop()}` : plan.done);
    } catch (error) {
      toast(`Failed: ${errorText(error)}`, "error", 10000);
    }
  }

  async function toggleTimer(timer, enable) {
    const lines = enable
      ? [`Enables and starts ${timer}, so scheduled backups run again.`]
      : [`Disables and stops ${timer}.`, "Scheduled backups of this kind stop until it is turned on again. A running backup is not stopped."];
    if (!(await confirmAction({ title: enable ? "Turn the schedule on?" : "Turn the schedule off?", lines, okLabel: enable ? "Turn on" : "Turn off", danger: !enable }))) return;
    try {
      await control("timer.set", { timer, enabled: enable });
      toast(`${timer} ${enable ? "enabled" : "disabled"}.`, enable ? "info" : "warn");
    } catch (error) {
      toast(`Failed: ${errorText(error)}`, "error", 10000);
    }
  }

  // Runs ---------------------------------------------------------------------

  renderers.runs = async (body) => {
    body.append(loadingNode());
    let history;
    let failures;
    try {
      [history, failures] = await Promise.all([control("history", { limit: 500 }), control("failures.list")]);
      state.history = history;
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    clear(body);
    const view = state.runsView;
    const outcomes = [...new Set(history.rows.map((row) => row.outcome))].sort();
    const outcomeSelect = h("select", { "aria-label": "Outcome" }, h("option", { value: "" }, "All outcomes"), outcomes.map((outcome) => h("option", { value: outcome, selected: outcome === view.outcome }, outcome)));
    const eventsCheck = h("input", { type: "checkbox", checked: view.eventsOnly });
    const tableHost = h("div", {});
    const draw = () => {
      view.outcome = outcomeSelect.value;
      view.eventsOnly = eventsCheck.checked;
      let rows = history.rows.filter((row) => (!view.outcome || row.outcome === view.outcome) && (!view.eventsOnly || row.events.length));
      rows = rows.slice().sort((a, b) => {
        const left = a[view.sort];
        const right = b[view.sort];
        const compared = typeof left === "number" && typeof right === "number" ? left - right : String(left).localeCompare(String(right));
        return view.descending ? -compared : compared;
      });
      const header = (key, label, numeric) => h("th", { class: numeric ? "num" : "", "aria-sort": view.sort === key ? (view.descending ? "descending" : "ascending") : "none" },
        h("button", { type: "button", class: "sort", onclick: () => { view.descending = view.sort === key ? !view.descending : true; view.sort = key; draw(); } }, label, view.sort === key ? (view.descending ? " ▼" : " ▲") : ""));
      append(clear(tableHost), [rows.length ? h("div", { class: "table-wrap" }, h("table", {},
        h("thead", {}, h("tr", {}, header("started", "Started"), header("duration_s", "Duration", true), header("profile", "Profile"), header("outcome", "Outcome"),
          header("peak_mem", "Peak RAM", true), header("peak_anon", "Not reclaimable", true), header("peak_swap", "Swap", true),
          header("avg_cpu_pct", "CPU avg", true), header("peak_cpu_pct", "CPU peak", true), header("peak_tasks", "Tasks", true),
          header("io_read", "Read", true), header("io_write", "Written", true), h("th", {}, "Watchdog events"))),
        h("tbody", {}, rows.map((row) => h("tr", { class: "clickable", tabindex: "0", onclick: () => openRun(row), onkeydown: (event) => { if (event.key === "Enter") openRun(row); } },
          h("td", {}, timeNode(row.started)), h("td", { class: "num" }, duration(row.duration_s)), h("td", {}, row.profile),
          h("td", {}, pill(row.outcome, row.outcome === "completed" ? "ok" : "bad")),
          h("td", { class: "num" }, bytes(row.peak_mem)), h("td", { class: "num" }, bytes(row.peak_anon)), h("td", { class: "num" }, bytes(row.peak_swap)),
          h("td", { class: "num" }, `${row.avg_cpu_pct ?? "—"}%`), h("td", { class: "num" }, `${row.peak_cpu_pct ?? "—"}%`), h("td", { class: "num" }, row.peak_tasks ?? "—"),
          h("td", { class: "num" }, bytes(row.io_read)), h("td", { class: "num" }, bytes(row.io_write)), h("td", {}, row.events.join(", ") || "—")))))) : h("p", { class: "empty" }, "No runs match.")]);
    };
    outcomeSelect.addEventListener("change", draw);
    eventsCheck.addEventListener("change", draw);
    body.append(
      h("div", { class: "filters" },
        h("label", {}, "Outcome", outcomeSelect),
        h("label", { class: "inline-check" }, eventsCheck, h("span", {}, "Only runs with watchdog events")),
        h("button", { type: "button", onclick: () => openRun({ started: "latest" }) }, "Open the latest log")),
      tableHost,
      h("h3", {}, "Failure records"),
      failures.failures.length ? h("div", { class: "table-wrap" }, h("table", {},
        h("thead", {}, h("tr", {}, h("th", {}, "Record"), h("th", {}, "Time"), h("th", { class: "num" }, "Size"))),
        h("tbody", {}, failures.failures.map((entry) => h("tr", { class: "clickable", tabindex: "0", onclick: () => openFailure(entry.name), onkeydown: (event) => { if (event.key === "Enter") openFailure(entry.name); } },
          h("td", {}, h("code", {}, entry.name)), h("td", {}, timeNode(entry.modified)), h("td", { class: "num" }, bytes(entry.size))))))) : h("p", { class: "muted" }, "No failure records."));
    draw();
  };

  async function openRun(row) {
    showDetails("Run log", loadingNode());
    try {
      const [log, errors] = await Promise.all([
        control("runlog", { run: row.started || "latest", lines: 2000 }),
        control("runlog", { run: row.started || "latest", lines: 8, filter: "errors" })
      ]);
      const nodes = [];
      if (row.duration_s !== undefined) {
        nodes.push(kv([["Started", timeNode(row.started)], ["Outcome", row.outcome], ["Duration", duration(row.duration_s)], ["Peak RAM", bytes(row.peak_mem)], ["Watchdog events", row.events.join(", ") || "none"]]));
      }
      nodes.push(h("h3", {}, "Key errors"), errors.lines.length ? h("pre", {}, errors.lines.join("\n")) : h("p", { class: "muted" }, "None found."));
      nodes.push(h("h3", {}, `Log of the run started ${log.run || "?"}`));
      if (log.truncated) nodes.push(h("p", { class: "notice info" }, "Only the last 2000 lines are shown."));
      nodes.push(textBlock(log.lines, { fileName: `backup-run-${String(log.run || "latest").replace(/[^0-9]/g, "")}.log` }));
      showDetails("Run log", nodes);
    } catch (error) {
      showDetails("Run log", errorNode(error));
    }
  }

  async function openFailure(name) {
    showDetails("Failure record", loadingNode());
    try {
      const record = await control("failures.read", { name });
      showDetails("Failure record", [h("p", {}, h("code", {}, record.name)), record.truncated ? h("p", { class: "notice info" }, "Shortened to the last 1 MiB.") : null, textBlock(record.text, { fileName: record.name })]);
    } catch (error) {
      showDetails("Failure record", errorNode(error));
    }
  }

  // Projects -----------------------------------------------------------------

  function parseProjects(lines) {
    const projects = [];
    let current = null;
    let summary = "";
    for (const line of lines) {
      const sync = line.match(/^Syncing label='(.*)' source='(.*)' destination='(.*)'$/);
      if (sync) {
        current = { label: sync[1], source: sync[2], destination: sync[3], result: "running", note: "" };
        projects.push(current);
        continue;
      }
      if (line.startsWith("Run summary:")) summary = line.replace("Run summary: ", "");
      if (!current) continue;
      if (/^File sync completed with changing paths/.test(line)) current.result = "synced, changing files kept for next run";
      else if (/^File sync completed on stability retry/.test(line)) current.result = "synced on retry";
      else if (/^File sync completed for/.test(line)) current.result = current.result === "running" ? "synced" : current.result;
      else if (/^File sync failed/.test(line)) current.result = "failed";
      else if (/^Migration confirmation required/.test(line)) current.result = "migration confirmation required";
      const deferred = line.match(/^Deferring (\d+) path/);
      if (deferred) current.note = `${deferred[1]} recently changed path(s) deferred`;
    }
    return { projects, summary };
  }

  renderers.projects = async (body) => {
    body.append(loadingNode());
    let log;
    let deferrals;
    try {
      [log, deferrals] = await Promise.all([control("runlog", { run: "latest", lines: 2000, filter: "projects" }), control("deferrals")]);
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    clear(body);
    const parsed = parseProjects(log.lines);
    body.append(h("h3", {}, "Latest run"), log.run ? h("p", { class: "muted" }, `Started ${log.run}. ${parsed.summary}`) : h("p", { class: "muted" }, "No run in the durable log yet."));
    if (log.truncated) body.append(h("p", { class: "notice info" }, "The run has more project lines than shown; the oldest are left out."));
    body.append(parsed.projects.length ? h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, h("th", {}, "Project"), h("th", {}, "Source"), h("th", {}, "Destination"), h("th", {}, "Result"), h("th", {}, "Notes"))),
      h("tbody", {}, parsed.projects.map((project) => {
        const kind = project.result === "failed" || project.result.startsWith("migration") ? "bad" : project.result === "running" ? "info" : project.result === "synced" || project.result === "synced on retry" ? "ok" : "warn";
        return h("tr", {}, h("td", {}, project.label), h("td", {}, h("code", {}, project.source)), h("td", {}, h("code", {}, project.destination)), h("td", {}, pill(project.result, kind)), h("td", {}, project.note || "—"));
      })))) : h("p", { class: "empty" }, "No projects in the latest run log."));

    body.append(h("h3", {}, "Changing files"),
      h("p", { class: "muted" }, `Files modified moments before a sync are skipped and tried again next run. Rows at or above ${deferrals.max_deferrals} runs in a row are highlighted: such a file never settles. Exclude it with .backup-excludes in its project, or stop its writer briefly.`));
    body.append(deferrals.rows.length ? h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, h("th", {}, "Project"), h("th", {}, "Path"), h("th", { class: "num" }, "Runs skipped"), h("th", {}, "Last seen"))),
      h("tbody", {}, deferrals.rows.map((row) => h("tr", { class: row.count >= deferrals.max_deferrals ? "highlight" : "" },
        h("td", {}, row.project), h("td", {}, h("code", {}, row.path)),
        h("td", { class: "num" }, row.count >= deferrals.max_deferrals ? h("span", {}, String(row.count), " ", pill("never settles", "warn")) : String(row.count)),
        h("td", {}, timeNode(row.updated))))))) : h("p", { class: "empty" }, "No files are being skipped."));
  };

  // Profiles -----------------------------------------------------------------

  function currentChoiceId(profiles) {
    if (!profiles) return "";
    if (profiles.mode === "adaptive") return `adaptive-${profiles.ladder[0]}-${profiles.ladder[profiles.ladder.length - 1]}`;
    return `fixed-${profiles.ladder[0]}`;
  }

  function profileTable(profiles) {
    const names = profiles.profiles.map((profile) => profile.name);
    const rows = [
      ["CPU (of one core)", (p) => `${p.limits.CPU_QUOTA} (${Math.round(parseInt(p.limits.CPU_QUOTA, 10) / profiles.host.cpu_cores)}% of host), nice ${p.limits.NICE}`],
      ["Memory throttle / hard limit", (p) => `${p.limits.MEMORY_HIGH} / ${p.limits.MEMORY_MAX}`],
      ["Swap", (p) => p.limits.MEMORY_SWAP_MAX],
      ["Tasks", (p) => p.limits.TASKS_MAX],
      ["Disk I/O", (p) => `${p.limits.IO_SCHEDULING_CLASS}, weight ${p.limits.IO_WEIGHT}`],
      ["Uploads / checkers / buffer", (p) => `${p.limits.RCLONE_TRANSFERS} / ${p.limits.RCLONE_CHECKERS} / ${p.limits.RCLONE_BUFFER_SIZE}`],
      ["API calls/s", (p) => p.limits.RCLONE_TPSLIMIT],
      ["Bandwidth", (p) => (p.limits.RCLONE_BWLIMIT ? `${p.limits.RCLONE_BWLIMIT}B/s` : "unlimited")],
      ["Limits from", (p) => `${p.limits_source || "—"}${p.overrides.length ? `; overrides: ${p.overrides.join(", ")}` : ""}`],
      ["Observed (last run)", (p) => (p.observed ? `peak ${bytes(p.observed.peak_memory_bytes)} RAM, avg ${p.observed.avg_cpu_percent}% CPU, ${duration(p.observed.duration_s)}` : "—")]
    ];
    return h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, h("th", {}, ""), profiles.profiles.map((p) => h("th", {}, p.name, p.current ? " (now)" : p.in_ladder ? " (in range)" : "")))),
      h("tbody", {}, rows.map(([label, valueOf]) => h("tr", {}, h("th", { scope: "row" }, label), profiles.profiles.map((p) => h("td", {}, String(valueOf(p))))))),
      h("caption", { class: "muted" }, `This host: ${profiles.host.cpu_cores} CPU cores, ${bytes(profiles.host.memory_bytes)} RAM. Profiles: ${names.join(", ")}.`)));
  }

  renderers.profiles = async (body) => {
    body.append(loadingNode());
    try {
      state.profiles = await control("profile.show");
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    clear(body);
    const profiles = state.profiles;
    const current = currentChoiceId(profiles);
    body.append(h("p", {}, "Active setup: ", h("strong", {}, profiles.setup), ". ",
      profiles.mode === "adaptive" ? `The watchdog steps one level down when resources are tight and back up after ${profiles.step_up_seconds}s of normal conditions.` : ""));

    body.append(h("h3", {}, "Setup"), h("div", { class: "profile-choices" }, SETUP_CHOICES.map((choice) => h("button", {
      type: "button", class: "profile-choice", "aria-pressed": choice.id === current ? "true" : "false",
      onclick: () => chooseSetup(choice)
    }, h("strong", {}, choice.label, choice.id === current ? " — current" : ""), h("small", {}, choice.note)))));

    body.append(h("h3", {}, "Limits per profile"), profileTable(profiles));

    const modeSelect = h("select", { "aria-label": "Limits mode" }, h("option", { value: "fixed", selected: profiles.limits_mode === "fixed" }, "Fixed (built-in table)"), h("option", { value: "auto", selected: profiles.limits_mode === "auto" }, "Auto (scaled to this server)"));
    body.append(h("h3", {}, "Limits mode"), h("div", { class: "filters" }, h("label", {}, "Limits", modeSelect),
      h("button", { type: "button", onclick: () => previewLimitsMode(modeSelect.value) }, "Preview…"),
      h("button", { type: "button", class: "primary-button", onclick: () => saveLimitsMode(modeSelect.value) }, "Save limits mode…")));

    const overrideRows = profiles.override_keys.map((key) => h("tr", {}, h("th", { scope: "row" }, h("code", {}, key)),
      PROFILE_ORDER.map((name) => {
        const profile = profiles.profiles.find((p) => p.name === name);
        if (!profile) return h("td", {}, "—");
        const overridden = profile.overrides.includes(key);
        const input = h("input", { type: "text", value: overridden ? profile.limits[key] : "", placeholder: profile.limits[key] || "(none)", "aria-label": `${name} ${key}`, spellcheck: "false" });
        return h("td", {}, input,
          h("button", { type: "button", class: "icon-button small", title: "Save this override", "aria-label": `Save ${name} ${key}`, onclick: () => saveOverride(name, key, input.value.trim()) }, "✓"),
          overridden ? h("button", { type: "button", class: "icon-button small", title: "Remove this override", "aria-label": `Remove ${name} ${key} override`, onclick: () => removeOverride(name, key) }, "↺") : null);
      })));
    body.append(h("h3", {}, "Per-profile overrides"),
      h("p", { class: "muted" }, "Set one value for one profile on top of the fixed or auto limits. The placeholder shows the value in use. Sizes like 512M or 1G, percentages like 25%, whole numbers otherwise."),
      h("div", { class: "table-wrap override-grid" }, h("table", {}, h("thead", {}, h("tr", {}, h("th", {}, "Key"), PROFILE_ORDER.map((name) => h("th", {}, name)))), h("tbody", {}, overrideRows))));
  };

  async function chooseSetup(choice) {
    showDetails("Profile preview", loadingNode());
    let preview;
    try {
      preview = await control("profile.preview", choice.args);
      showDetails("Profile preview", [h("p", {}, `systemd drop-in that will be written for ${preview.profile}:`), h("pre", {}, preview.dropin)]);
    } catch (error) {
      showDetails("Profile preview", errorNode(error));
      return;
    }
    const lines = [
      `Sets the resource profile to: ${choice.label}.`,
      ["Writes the systemd drop-in shown in the Details panel and reloads systemd.",
        "A running backup gets the new CPU, memory, swap and task limits at once; rclone settings apply from its next project.",
        "A lower hard memory limit waits until usage is comfortably below it, so this never forces an OOM kill.",
        choice.args.mode === "adaptive" ? "The adaptive level starts again at the top profile." : "Adaptive stepping is switched off."]
    ];
    if (!(await confirmAction({ title: "Change the resource profile?", lines, okLabel: "Apply profile" }))) return;
    try {
      const result = await control("profile.set", choice.args);
      state.profiles = result.profiles;
      toast(`Profile set: ${result.profiles.setup}`);
      showDetails("Profile applied", textBlock(result.output, { searchable: false, fileName: "profile-change.txt" }));
      renderSection();
    } catch (error) {
      toast(`Failed: ${errorText(error)}`, "error", 10000);
    }
  }

  async function previewLimitsMode(mode) {
    showDetails("Limits preview", loadingNode());
    try {
      const preview = await control("profile.show", { limits_mode: mode });
      showDetails(`Limits preview: ${mode}`, [h("p", {}, mode === "auto" ? "Scaled to this server (slow 5% RAM / 3% CPU, moderate 10% / 6%, fast 20% / 12%; hard memory limit at least 256M)." : "The built-in table."), profileTable(preview)]);
    } catch (error) {
      showDetails("Limits preview", errorNode(error));
    }
  }

  async function saveLimitsMode(mode) {
    if (state.profiles && state.profiles.limits_mode === mode) {
      toast(`Limits mode is already ${mode}.`);
      return;
    }
    await previewLimitsMode(mode);
    if (!(await confirmAction({ title: "Change the limits mode?", lines: [`Switches every profile to ${mode} limits (shown in the Details panel) and re-applies the current setup.`], okLabel: "Save" }))) return;
    try {
      const result = await control("profile.limits", { mode });
      state.profiles = result.profiles;
      toast(`Limits mode: ${mode}.`);
      renderSection();
    } catch (error) {
      toast(`Failed: ${errorText(error)}`, "error", 10000);
    }
  }

  async function saveOverride(profile, key, value) {
    if (!value) {
      toast("Enter a value first, or use ↺ to remove an override.", "warn");
      return;
    }
    if (!(await confirmAction({ title: "Save this override?", lines: [`Sets ${key} = ${value} for the ${profile} profile, then re-applies the current setup.`], okLabel: "Save override" }))) return;
    try {
      const result = await control("profile.override", { profile, key, value });
      state.profiles = result.profiles;
      toast(`${profile} ${key} = ${value}`);
      renderSection();
    } catch (error) {
      toast(`Failed: ${errorText(error)}`, "error", 10000);
    }
  }

  async function removeOverride(profile, key) {
    if (!(await confirmAction({ title: "Remove this override?", lines: [`${profile} ${key} goes back to its ${state.profiles?.limits_mode || "fixed"} value.`], okLabel: "Remove" }))) return;
    try {
      const result = await control("profile.override", { profile, key, unset: true });
      state.profiles = result.profiles;
      toast(`Removed ${profile} ${key}.`);
      renderSection();
    } catch (error) {
      toast(`Failed: ${errorText(error)}`, "error", 10000);
    }
  }

  // Server settings (watchdog, ntfy, general) --------------------------------

  function settingField(entry) {
    const id = `setting-${entry.key}`;
    let input;
    if (entry.kind === "bool") {
      input = h("select", { id, name: entry.key }, h("option", { value: "1", selected: (entry.value || entry.default) === "1" }, "On"), h("option", { value: "0", selected: (entry.value || entry.default) === "0" }, "Off"));
    } else if (entry.kind === "choice") {
      input = h("select", { id, name: entry.key }, entry.options.map((option) => h("option", { value: option, selected: (entry.value || entry.default) === option }, option)));
    } else if (entry.kind === "secret") {
      input = h("input", { id, name: entry.key, type: "password", autocomplete: "new-password", placeholder: entry.is_set ? "set — type to replace" : "not set", spellcheck: "false" });
    } else if (entry.kind === "url" && entry.masked) {
      input = h("input", { id, name: entry.key, type: "url", placeholder: entry.value || "not set", spellcheck: "false" });
    } else if (entry.kind === "int") {
      input = h("input", { id, name: entry.key, type: "number", min: entry.min, max: entry.max, step: "1", value: entry.value || entry.default });
    } else {
      input = h("input", { id, name: entry.key, type: "text", value: entry.value || entry.default, spellcheck: "false" });
    }
    input.dataset.original = input.value;
    const row = h("div", { class: "setting-row" },
      h("label", { for: id }, h("code", {}, entry.key)),
      input,
      h("div", { class: "meta" }, entry.explanation),
      h("div", { class: "meta" }, `Default: ${entry.kind === "secret" ? "empty" : entry.default || "empty"}${entry.kind === "int" ? ` · range ${entry.min}–${entry.max}` : ""}${entry.present ? "" : " · not set in global.conf (default applies)"}`));
    input.addEventListener("input", () => row.classList.toggle("changed", input.value !== input.dataset.original));
    if (entry.kind === "secret") {
      row.append(h("label", { class: "inline-check" }, h("input", { type: "checkbox", name: `${entry.key}__clear` }), h("span", {}, "Clear the token")));
    }
    return row;
  }

  function collectChanges(container) {
    const changes = {};
    for (const input of container.querySelectorAll("input[name], select[name]")) {
      if (input.name.endsWith("__clear")) {
        if (input.checked) changes[input.name.replace("__clear", "")] = "";
        continue;
      }
      if (input.type === "password" || (input.type === "url" && !input.value)) {
        if (input.value) changes[input.name] = input.value.trim();
        continue;
      }
      if (input.value !== input.dataset.original) changes[input.name] = input.value.trim();
    }
    return changes;
  }

  function validateWatchdog(changes, config) {
    const value = (key) => Number(key in changes ? changes[key] : (config.settings.find((entry) => entry.key === key)?.value || config.settings.find((entry) => entry.key === key)?.default));
    const problems = [];
    if (!(value("WATCHDOG_CONTAIN_RELEASE_PERCENT") < value("WATCHDOG_CONTAIN_PERCENT") && value("WATCHDOG_CONTAIN_PERCENT") < value("WATCHDOG_KILL_PERCENT") && value("WATCHDOG_KILL_PERCENT") <= 99)) problems.push("Keep release < contain < stop (kill) ≤ 99 percent.");
    if (!(value("WATCHDOG_SYSTEM_CRITICAL_AVAILABLE_PERCENT") < value("WATCHDOG_SYSTEM_MIN_AVAILABLE_PERCENT"))) problems.push("The critical server RAM percent must be below the pause percent.");
    if (!(value("WATCHDOG_ADAPTIVE_STEP_UP_AVAILABLE_PERCENT") > value("WATCHDOG_ADAPTIVE_STEP_DOWN_AVAILABLE_PERCENT"))) problems.push("Adaptive step-up RAM percent must be above the step-down percent.");
    if (!(value("WATCHDOG_SWAP_CONTAIN_PERCENT") < value("WATCHDOG_SWAP_KILL_PERCENT"))) problems.push("Swap containment must be below the swap stop percent.");
    if (!(value("WATCHDOG_PSI_PAUSE_AVAILABLE_PERCENT") >= value("WATCHDOG_SYSTEM_MIN_AVAILABLE_PERCENT"))) problems.push("The stall pause RAM percent must be at or above the shortage pause percent.");
    return problems;
  }

  async function saveConfig(changes, config, { title, note }) {
    const keys = Object.keys(changes);
    if (!keys.length) {
      toast("Nothing changed.");
      return false;
    }
    const shown = keys.map((key) => `${key} = ${key === "NOTIFY_NTFY_TOKEN" ? (changes[key] ? "[new token]" : "[cleared]") : changes[key] || "(empty)"}`);
    if (!(await confirmAction({ title, lines: ["Writes these values to Backup Suite's global.conf (a backup copy is kept and the change is audited):", shown, note], okLabel: "Save" }))) return false;
    try {
      const result = await control("config.set", { changes, expect_sha: config.sha256 });
      toast(`Saved ${result.changed.length} setting(s). ${result.note}`);
      return true;
    } catch (error) {
      if (error.code === "config_conflict") toast("global.conf changed on the server since this page loaded. The values were reloaded; check them and save again.", "warn", 10000);
      else toast(`Failed: ${errorText(error)}`, "error", 10000);
      return error.code === "config_conflict";
    }
  }

  renderers.watchdog = async (body) => {
    body.append(loadingNode());
    let config;
    let journal;
    try {
      [config, journal] = await Promise.all([control("config.get"), control("journal", { source: "watchdog", lines: 200 })]);
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    clear(body);
    const status = state.status || {};
    const watchdog = status.watchdog || {};
    const last = status.watchdog_last_action;
    body.append(h("section", { class: "card" }, h("h3", {}, "Now"), kv([
      ["Watchdog", watchdogFresh(status) ? pill(watchdog.state || "watching", watchdog.state === "watching" ? "ok" : "warn") : pill("idle (no backup running)", "")],
      ["Events this run", watchdogFresh(status) ? watchdog.events || "none" : "—"],
      ["Last stop", last?.reason ? last.reason : "none recorded"]
    ]), h("div", { class: "toolbar-row tight" }, h("button", { type: "button", onclick: () => showDetails("Watchdog journal", textBlock(journal.lines, { fileName: "backup-watchdog.log" })) }, "Open watchdog journal"))));

    const form = h("div", { class: "form-host" });
    const byKey = Object.fromEntries(config.settings.map((entry) => [entry.key, entry]));
    for (const [group, keys] of WATCHDOG_GROUPS) {
      form.append(h("fieldset", { class: "settings-option-group" }, h("legend", {}, group), h("div", { class: "threshold-grid" }, keys.filter((key) => byKey[key]).map((key) => settingField(byKey[key])))));
    }
    const errors = h("div", { class: "field-error", role: "alert" });
    body.append(h("h3", {}, "Thresholds"), h("p", { class: "muted" }, "Percentages refer to the backup's MemoryMax unless they name the server. Changes apply from the next backup run."), form, errors,
      h("div", { class: "toolbar-row end" }, h("button", { type: "button", class: "primary-button", onclick: async () => {
        const changes = collectChanges(form);
        const problems = validateWatchdog(changes, config);
        errors.textContent = problems.join(" ");
        if (problems.length) return;
        if (await saveConfig(changes, config, { title: "Save watchdog thresholds?", note: "The watchdog reads them when the next backup starts." })) renderSection();
      } }, "Save thresholds…")));
  };

  renderers.notifications = async (body) => {
    body.append(loadingNode());
    let config;
    try {
      config = await control("config.get");
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    clear(body);
    const byKey = Object.fromEntries(config.settings.map((entry) => [entry.key, entry]));
    const enabled = (byKey.NOTIFY_FAILURES_ENABLED.value || byKey.NOTIFY_FAILURES_ENABLED.default) === "1";
    body.append(h("section", { class: "card" }, h("h3", {}, "ntfy now"), kv([
      ["Alerts", pill(enabled ? "on" : "off", enabled ? "ok" : "warn")],
      ["Topic", byKey.NOTIFY_NTFY_TOPIC_URL.is_set ? h("code", {}, byKey.NOTIFY_NTFY_TOPIC_URL.value) : "not set"],
      ["Token", byKey.NOTIFY_NTFY_TOKEN.is_set ? "set (never shown)" : "not set"],
      ["Priority", byKey.NOTIFY_NTFY_PRIORITY.value || byKey.NOTIFY_NTFY_PRIORITY.default],
      ["Title prefix", byKey.NOTIFY_NTFY_TITLE_PREFIX.value || byKey.NOTIFY_NTFY_TITLE_PREFIX.default]
    ]), h("div", { class: "toolbar-row tight" }, h("button", { type: "button", onclick: () => runAction("notify-test") }, "Send test notification…"))));
    const form = h("div", {});
    form.append(h("fieldset", { class: "settings-option-group" }, h("legend", {}, "ntfy settings"), h("div", { class: "threshold-grid" }, NTFY_KEYS.filter((key) => byKey[key]).map((key) => settingField(byKey[key])))));
    body.append(form, h("p", { class: "muted" }, "The topic is shown shortened; leave the field empty to keep it, or type a full https:// URL to replace it. The token can be replaced or cleared, never read. GUI notices (bell, Tunnel Manager, browser) are in Settings → Notifications."),
      h("div", { class: "toolbar-row end" }, h("button", { type: "button", class: "primary-button", onclick: async () => {
        if (await saveConfig(collectChanges(form), config, { title: "Save ntfy settings?", note: "They apply to the next notification." })) renderSection();
      } }, "Save ntfy settings…")));
  };

  // Sources ------------------------------------------------------------------

  renderers.sources = async (body) => {
    body.append(loadingNode());
    let sources;
    try {
      sources = await control("sources.get");
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    clear(body);
    body.append(h("p", { class: "notice info" }, "Sources are read-only in this version. Edit ", h("code", {}, sources.path), " on the server; editing here arrives in a later version."),
      kv([["File", h("code", {}, sources.path)], ["Modified", timeNode(sources.modified)], ["SHA-256", h("code", {}, sources.sha256.slice(0, 16) + "…")]]));
    body.append(h("h3", {}, "Entries"), sources.rows.length ? h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, ["Line", "Enabled", "Label", "Source", "Destination", "Stop file", "Isolation"].map((label) => h("th", {}, label)))),
      h("tbody", {}, sources.rows.map((row) => h("tr", {},
        h("td", { class: "num" }, row.line),
        h("td", {}, pill(row.enabled === "1" ? "yes" : "no", row.enabled === "1" ? "ok" : "")),
        h("td", {}, row.label),
        h("td", {}, h("code", {}, row.source), row.source_exists ? "" : h("span", {}, " ", pill("missing", "bad"))),
        h("td", {}, `${row.destination_mode}${row.destination_value ? `: ${row.destination_value}` : ""}`),
        h("td", {}, row.stop_file || "default"),
        h("td", {}, row.isolation)))))) : h("p", { class: "empty" }, "No entries."));
    body.append(h("h3", {}, "Raw file"), textBlock(sources.text, { searchable: false, fileName: "file-sources.conf" }));
    const excludesHost = h("div", {}, loadingNode("Looking for .backup-excludes files…"));
    body.append(h("h3", {}, "Per-project exclude files"), excludesHost);
    try {
      const excludes = await control("excludes.list");
      clear(excludesHost);
      if (excludes.truncated) excludesHost.append(h("p", { class: "notice info" }, "The search stopped early (time or file limit); not every file is listed."));
      if (!excludes.files.length) excludesHost.append(h("p", { class: "empty" }, `No ${excludes.filename} files found.`));
      for (const file of excludes.files) {
        excludesHost.append(h("details", {}, h("summary", {}, h("code", {}, file.path), ` (${file.source_label}, ${bytes(file.size)})`), h("pre", {}, file.lines.join("\n") || "(empty)")));
      }
    } catch (error) {
      clear(excludesHost).append(errorNode(error));
    }
  };

  // Activity -----------------------------------------------------------------

  function eventItem(event, isNew) {
    const date = parseTime(event.created_at);
    return h("li", { class: `event-item severity-${event.severity} ${isNew ? "is-new" : ""}` },
      h("header", {}, h("span", {}, pill(event.severity, event.severity === "error" ? "bad" : event.severity === "warning" ? "warn" : "info"), " ", event.category), timeNode(date ? date.toISOString() : event.created_at)),
      h("strong", {}, event.title),
      event.message ? h("details", {}, h("summary", {}, "Details"), h("p", {}, event.message)) : null);
  }

  renderers.activity = async (body) => {
    body.append(loadingNode());
    let audit;
    try {
      const [list, auditData] = await Promise.all([api("/api/events?limit=500"), control("audit", { limit: 300 })]);
      state.events = list.events;
      audit = auditData;
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    clear(body);
    const previousSeen = state.seenSeq;
    markEventsSeen();
    body.append(h("h3", {}, "Events"), state.events.length
      ? h("ul", { class: "event-list" }, state.events.slice().reverse().map((event) => eventItem(event, event.seq > previousSeen)))
      : h("p", { class: "empty" }, "No events yet."));
    body.append(h("h3", {}, "Audit log"), audit.entries.length ? h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, ["Time", "Login", "Change", "Arguments", "Result"].map((label) => h("th", {}, label)))),
      h("tbody", {}, audit.entries.map((entry) => h("tr", {},
        h("td", {}, timeNode(entry.at)), h("td", {}, `${entry.login} (${entry.uid})`), h("td", {}, h("code", {}, entry.verb)),
        h("td", {}, h("code", {}, JSON.stringify(entry.args || {}))), h("td", {}, pill(entry.ok ? "ok" : "failed", entry.ok ? "ok" : "bad"), " ", entry.ok ? "" : entry.result)))))) : h("p", { class: "empty" }, "No changes have been made through the GUI yet."));
  };

  function markEventsSeen() {
    const latest = state.events.reduce((max, event) => Math.max(max, event.seq), state.seenSeq);
    state.seenSeq = latest;
    storageSet(SEEN_KEY, String(latest));
    updateChrome();
  }

  async function openBell() {
    const panel = $("#bell-panel");
    const body = clear($("#bell-body"));
    panel.hidden = false;
    $("#bell-button").setAttribute("aria-expanded", "true");
    body.append(loadingNode());
    try {
      const list = await api("/api/events?limit=100");
      state.events = list.events;
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    const previousSeen = state.seenSeq;
    clear(body);
    body.append(state.events.length ? h("ul", { class: "event-list" }, state.events.slice().reverse().slice(0, 100).map((event) => eventItem(event, event.seq > previousSeen))) : h("p", { class: "empty" }, "No events yet."),
      h("div", { class: "toolbar-row tight" }, h("button", { type: "button", onclick: () => { closeBell(); navigate("activity"); } }, "Open Activity & audit")));
    markEventsSeen();
    $("#bell-close").focus();
  }

  function closeBell() {
    $("#bell-panel").hidden = true;
    $("#bell-button").setAttribute("aria-expanded", "false");
  }

  // ------------------------------------------------------------------ navigation

  function navigate(section) {
    if (!SECTIONS[section]) section = "overview";
    if (location.hash !== `#${section}`) history.replaceState(null, "", `#${section}`);
    state.section = section;
    for (const button of document.querySelectorAll("[data-section]")) {
      if (button.dataset.section === section) button.setAttribute("aria-current", "page");
      else button.removeAttribute("aria-current");
    }
    $("#section-title").textContent = SECTIONS[section];
    $("#section-help").dataset.help = section;
    if (window.matchMedia("(max-width: 960px)").matches) showPanel("main");
    renderSection();
  }

  let renderToken = 0;
  async function renderSection() {
    const token = ++renderToken;
    const body = $("#section-body");
    const focusedKey = document.activeElement?.dataset?.key;
    const fresh = h("div", {});
    const result = renderers[state.section](fresh);
    if (result && typeof result.then === "function") {
      clear(body).append(fresh);
      await result;
      return;
    }
    if (token !== renderToken) return;
    clear(body).append(fresh);
    if (focusedKey) {
      const again = body.querySelector(`[data-key="${CSS.escape(focusedKey)}"]`);
      if (again) again.focus();
    }
  }

  // ------------------------------------------------------------------ live stream

  let stream = null;
  function connectStream() {
    if (stream) stream.close();
    stream = new EventSource("/api/stream");
    stream.addEventListener("open", () => {
      state.connected = true;
      $("#connection-banner").hidden = true;
    });
    stream.addEventListener("error", () => {
      state.connected = false;
      $("#connection-banner").hidden = false;
    });
    stream.addEventListener("hello", (message) => {
      const data = JSON.parse(message.data);
      state.chart = data.chart || [];
      if (data.status) state.status = data.status;
      state.statusError = data.error;
      updateChrome();
      if (state.section === "overview") renderSection();
    });
    stream.addEventListener("status", (message) => {
      const data = JSON.parse(message.data);
      const wasRunning = ["running", "paused"].includes(fileBackupState(state.status).key);
      state.status = data.status;
      state.statusError = null;
      if (data.point) {
        state.chart.push(data.point);
        const capacity = Math.ceil(((state.settings?.general?.chartMinutes || 30) * 60) / (state.settings?.general?.refreshSeconds || 5)) + 1;
        if (state.chart.length > capacity) state.chart.splice(0, state.chart.length - capacity);
      }
      const isRunning = ["running", "paused"].includes(fileBackupState(state.status).key);
      if (wasRunning && !isRunning) refreshHistory();
      updateChrome();
      if (state.section === "overview") renderSection();
    });
    stream.addEventListener("status-error", (message) => {
      state.statusError = JSON.parse(message.data);
      updateChrome();
      if (state.section === "overview" && !state.status) renderSection();
    });
    stream.addEventListener("events", (message) => {
      const data = JSON.parse(message.data);
      state.tunnelManagerActive = Boolean(data.tunnel_manager_active);
      for (const event of data.events || []) {
        if (!state.events.some((known) => known.seq === event.seq)) state.events.push(event);
        browserNotify(event);
      }
      updateChrome();
      if (state.section === "activity") renderSection();
    });
  }

  function browserNotify(event) {
    const settings = state.settings?.notifications;
    if (!settings?.browser || !("Notification" in window) || Notification.permission !== "granted") return;
    if (settings.categories?.[event.category] === false) return;
    if (settings.preferTunnelManager && state.tunnelManagerActive) return;
    try {
      const notification = new Notification(event.title, { body: `${event.message || ""}\nOccurred: ${event.created_at}`.trim(), tag: event.id, icon: "/icons/icon-192.png" });
      notification.addEventListener("click", () => {
        window.focus();
        navigate("activity");
      });
    } catch {
      // Notifications can be blocked by the browser; the bell still lists the event.
    }
  }

  async function refreshHistory() {
    try {
      state.history = await control("history", { limit: 500 });
      if (state.section === "overview") renderSection();
    } catch {
      // Overview shows "Loading…" for the last run until the next try.
    }
  }

  // ------------------------------------------------------------------ settings dialog

  function applyTheme(theme) {
    if (theme === "light" || theme === "dark") document.documentElement.setAttribute("data-theme", theme);
    else document.documentElement.removeAttribute("data-theme");
    storageSet("backup-suite-gui-theme", theme);
  }

  function settingsTab(name) {
    for (const button of document.querySelectorAll("[data-settings-tab-button]")) button.setAttribute("aria-selected", String(button.dataset.settingsTabButton === name));
    for (const panel of document.querySelectorAll("[data-settings-tab]")) panel.hidden = panel.dataset.settingsTab !== name;
    if (name === "server") loadServerSettings();
  }

  function fillSettingsForm() {
    const form = $("#settings-form");
    const settings = state.settings;
    for (const element of form.querySelectorAll("[name*='.']")) {
      const [section, key] = element.name.split(".");
      const value = settings[section]?.[key];
      if (element.type === "checkbox") element.checked = Boolean(value);
      else element.value = value ?? "";
    }
    const categories = clear($("#settings-categories"));
    for (const [category, label] of Object.entries(state.session.categories || {})) {
      categories.append(h("label", { class: "inline-check" }, h("input", { type: "checkbox", name: `category.${category}`, checked: settings.notifications.categories[category] !== false }), h("span", {}, label)));
    }
    const backend = state.session.backend;
    $("#settings-backend-note").textContent = `Now: ${backend.label}. ${backend.reason}`;
    const listen = state.session.listen;
    $("#settings-listen-note").textContent = `Listening now: ${listen.mode}${listen.mode !== "tcp" ? ` on ${listen.socket_path}` : ""}${listen.mode !== "socket" ? ` and 127.0.0.1:${listen.tcp_port}` : ""}. ${listen.warning || ""}${listen.source === "env" ? " (set by BACKUP_SUITE_GUI_LISTEN; the setting below is ignored)" : ""}`;
    updateNotificationButton();
  }

  function readSettingsForm() {
    const form = $("#settings-form");
    const update = { general: {}, notifications: { categories: {} }, tunnel: {}, limits: {} };
    for (const element of form.querySelectorAll("[name]")) {
      if (element.name.startsWith("category.")) {
        update.notifications.categories[element.name.slice(9)] = element.checked;
        continue;
      }
      const [section, key] = element.name.split(".");
      if (!update[section] || !key) continue;
      if (element.type === "checkbox") update[section][key] = element.checked;
      else if (element.type === "number") update[section][key] = Number(element.value);
      else update[section][key] = element.value.trim();
    }
    return update;
  }

  function updateNotificationButton() {
    const button = $("#browser-notification-button");
    const status = $("#browser-notification-status");
    if (!("Notification" in window)) {
      button.disabled = true;
      status.textContent = "This browser does not support notifications.";
      return;
    }
    button.disabled = false;
    button.textContent = Notification.permission === "granted" ? "Test browser notification" : "Enable browser notifications";
    status.textContent = Notification.permission === "denied" ? "Blocked in this browser's site settings." : "";
  }

  async function loadServerSettings() {
    const host = clear($("#server-settings-body"));
    host.append(loadingNode());
    try {
      const config = await control("config.get");
      clear(host);
      const byKey = Object.fromEntries(config.settings.map((entry) => [entry.key, entry]));
      const form = h("div", { class: "threshold-grid" }, SERVER_KEYS.filter((key) => byKey[key]).map((key) => settingField(byKey[key])));
      host.append(form);
      $("#server-settings-save").onclick = async () => {
        if (await saveConfig(collectChanges(form), config, { title: "Save server settings?", note: "They apply from the next backup run." })) loadServerSettings();
      };
    } catch (error) {
      clear(host).append(errorNode(error));
    }
  }

  function openSettings() {
    fillSettingsForm();
    settingsTab("general");
    $("#settings-dialog").showModal();
  }

  async function saveSettings() {
    try {
      const result = await api("/api/settings", { method: "POST", body: { settings: readSettingsForm() } });
      state.settings = result.settings;
      state.session.settings = result.settings;
      state.session.listen = result.listen;
      applyTheme(result.settings.general.theme);
      toast(result.restart_required ? "Settings saved. Restart the GUI to apply the listener or limit changes." : "Settings saved.", result.restart_required ? "warn" : "info");
      const session = await api("/api/session");
      state.session = session;
      $("#mode-label").textContent = session.backend.label;
      renderSection();
    } catch (error) {
      toast(`Settings not saved: ${errorText(error)}`, "error", 10000);
    }
  }

  // ------------------------------------------------------------------ connect dialog

  async function openConnect() {
    const dialog = $("#connect-dialog");
    const body = clear($("#connect-body"));
    body.append(loadingNode());
    dialog.showModal();
    let info;
    try {
      info = await api("/api/connect");
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    renderConnect(info);
  }

  function renderConnect(info) {
    const body = clear($("#connect-body"));
    const backendInput = h("input", { type: "text", value: info.backend_id, spellcheck: "false", "aria-describedby": "backend-hint", autocomplete: "off" });
    body.append(
      h("h3", {}, "1. Tunnel Manager (recommended)"),
      h("p", {}, "Get Tunnel Manager from ", h("a", { href: info.tunnel_manager.download_url, target: "_blank", rel: "noopener noreferrer" }, "its releases page"), ". In the profile for this server, use Import with the file below, then press Start."),
      h("label", {}, "Tunnel Manager backend (user@host)", h("div", { class: "copy-row" }, backendInput,
        h("button", { type: "button", onclick: async () => {
          try {
            renderConnect(await api("/api/connect/backend", { method: "POST", body: { backend_id: backendInput.value.trim() } }));
            toast("Backend saved; the bundle below uses it.");
          } catch (error) {
            toast(errorText(error), "error");
          }
        } }, "Save"))),
      h("p", { class: "settings-help", id: "backend-hint" }, "Must be the user@host of your Tunnel Manager profile for this server, exactly as Tunnel Manager shows it. Tunnel Manager refuses the import on any difference, for example an alias instead of the address."),
      h("div", { class: "toolbar-row tight" },
        h("a", { href: info.tunnel_manager.url, download: info.tunnel_manager.file_name, class: "button-link" }, `Download ${info.tunnel_manager.file_name}`),
        h("button", { type: "button", onclick: () => copyText(info.tunnel_manager.toml) }, "Copy bundle")),
      h("details", {}, h("summary", {}, "Show the bundle"), h("pre", {}, info.tunnel_manager.toml)),
      h("p", { class: "muted" }, `The GUI's remote service is ${info.unit}; Tunnel Manager starts it if it is stopped.`),
      h("h3", {}, "2. Launcher scripts"),
      h("div", { class: "toolbar-row tight" }, info.scripts.map((script) => h("a", { href: script.url, download: script.file_name, class: "button-link" }, script.label))),
      h("h3", {}, "3. Manually"),
      h("div", { class: "copy-row" }, h("code", {}, info.manual.ssh), h("button", { type: "button", onclick: () => copyText(info.manual.ssh) }, "Copy")),
      h("p", {}, "Then open ", h("code", {}, info.manual.address), ". Forwarding to ", info.socket ? "the GUI's private socket" : "127.0.0.1 (tcp mode)", ": ", h("code", {}, info.remote), "."));
  }

  // ------------------------------------------------------------------ start-up

  function bindChrome() {
    $("#reload-button").addEventListener("click", () => location.reload());
    $("#settings-button").addEventListener("click", openSettings);
    $("#connect-button").addEventListener("click", openConnect);
    $("#reset-panels-button").addEventListener("click", () => {
      $("#layout").className = "layout";
      showPanel("main");
    });
    const actionsButton = $("#actions-button");
    const actionsMenu = $("#actions-menu");
    const closeMenu = () => {
      actionsMenu.hidden = true;
      actionsButton.setAttribute("aria-expanded", "false");
    };
    actionsButton.addEventListener("click", () => {
      const open = actionsMenu.hidden;
      actionsMenu.hidden = !open;
      actionsButton.setAttribute("aria-expanded", String(open));
      if (open) actionsMenu.querySelector("button").focus();
    });
    actionsMenu.addEventListener("click", (event) => {
      const action = event.target.closest("[data-action]")?.dataset.action;
      closeMenu();
      if (action) runAction(action);
    });
    document.addEventListener("click", (event) => {
      if (!event.target.closest(".menu-anchor")) closeMenu();
    });
    document.addEventListener("keydown", (event) => {
      if (event.key !== "Escape") return;
      closeMenu();
      if (!$("#help-panel").hidden) $("#help-panel").hidden = true;
      if (!$("#bell-panel").hidden) closeBell();
    });
    for (const button of document.querySelectorAll("[data-section]")) button.addEventListener("click", () => navigate(button.dataset.section));
    document.addEventListener("click", (event) => {
      const helpButton = event.target.closest("[data-help]");
      if (helpButton) showHelp(helpButton.dataset.help);
    });
    $("#help-close").addEventListener("click", () => { $("#help-panel").hidden = true; });
    $("#bell-button").addEventListener("click", () => ($("#bell-panel").hidden ? openBell() : closeBell()));
    $("#bell-close").addEventListener("click", closeBell);
    $("#main-maximize").addEventListener("click", () => $("#layout").classList.toggle("main-maximized"));
    $("#details-maximize").addEventListener("click", () => $("#layout").classList.toggle("details-maximized"));
    $("#details-close").addEventListener("click", () => {
      $("#layout").classList.add("details-closed");
      $("#layout").classList.remove("details-maximized");
      showPanel("main");
    });
    for (const button of document.querySelectorAll("[data-show-panel]")) button.addEventListener("click", () => showPanel(button.dataset.showPanel));
    for (const button of document.querySelectorAll("[data-settings-tab-button]")) button.addEventListener("click", () => settingsTab(button.dataset.settingsTabButton));
    $("#settings-form").addEventListener("submit", (event) => {
      if (event.submitter?.value === "save") {
        event.preventDefault();
        const form = $("#settings-form");
        if (!form.reportValidity()) return;
        $("#settings-dialog").close();
        saveSettings();
      }
    });
    $("#browser-notification-button").addEventListener("click", async () => {
      if (Notification.permission === "granted") {
        new Notification("Backup Suite GUI test", { body: "Browser notifications work in this window.", icon: "/icons/icon-192.png" });
      } else {
        await Notification.requestPermission();
      }
      updateNotificationButton();
    });
    $("#restart-gui-button").addEventListener("click", async () => {
      if (!(await confirmAction({ title: "Restart the GUI?", lines: ["Restarts backup-suite-gui. Open pages reconnect after a few seconds. Backups are not affected.", "If the listener changes, reconnect the tunnel with the new bundle from Ways to connect."], okLabel: "Restart GUI" }))) return;
      try {
        await api("/api/gui/restart", { method: "POST", body: {} });
        toast("Restarting the GUI…", "warn");
      } catch (error) {
        toast(errorText(error), "error");
      }
    });
    window.addEventListener("hashchange", () => navigate(location.hash.slice(1)));
  }

  async function init() {
    bindChrome();
    try {
      const session = await api("/api/session");
      state.session = session;
      state.csrf = session.csrf;
      state.settings = session.settings;
      state.tunnelManagerActive = session.tunnel_manager_active;
      applyTheme(session.settings.general.theme);
      $("#mode-label").textContent = session.backend.label;
      $("#version-label").textContent = `v${session.version} · ${session.login}@${session.host}`;
    } catch (error) {
      $("#section-body").append(errorNode(error));
      $("#connection-banner").hidden = false;
      return;
    }
    navigate(location.hash.slice(1) || "overview");
    connectStream();
    try {
      const [profiles, history, events] = await Promise.all([
        control("profile.show").catch(() => null),
        control("history", { limit: 500 }).catch(() => null),
        api("/api/events?limit=500").catch(() => ({ events: [] }))
      ]);
      state.profiles = profiles;
      state.history = history;
      state.events = events.events || [];
      if (!storageGet(SEEN_KEY)) markEventsSeen();
      updateChrome();
      if (state.section === "overview") renderSection();
    } catch {
      // Each section loads what it needs on its own.
    }
    if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
  }

  init();
})();
