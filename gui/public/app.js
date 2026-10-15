// Backup Suite GUI front end. Vanilla JS, no build step. Every server change goes
// through a confirmation dialog; every value from the server is inserted as text.
(() => {
  "use strict";

  const PROFILE_ORDER = ["slow", "moderate", "fast"];
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
    view: { kind: "home" },
    adminTab: "actions",
    entriesData: null,
    entriesError: null,
    entriesLoadedAt: 0,
    entryCache: {},
    logSource: "file-backup",
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
    // Inside the Admin dialog, details open in its own side panel.
    if ($("#admin-dialog").open) {
      $("#admin-details-title").textContent = title;
      append(clear($("#admin-details-body")), [nodes]);
      $("#admin-details").hidden = false;
      return;
    }
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

  // An installed Backup Suite older than this GUI answers "Unknown verb" to what it
  // does not have yet: say what to do instead.
  function isOutdatedBackendError(error) {
    return error?.code === "invalid_request" && /Unknown verb/i.test(error.message || "");
  }

  const OUTDATED_TEXT = "Backup Suite on the server is older than this GUI, so this page is not available yet. Deploy the latest version (sudo ./production-deploy.sh … from the repository), then reload. Everything else keeps working.";

  function errorNode(error) {
    if (isOutdatedBackendError(error)) return h("div", { class: "notice info", role: "status" }, OUTDATED_TEXT);
    return h("div", { class: "notice bad", role: "alert" }, errorText(error));
  }

  // The control verbs this GUI uses. A server whose status lists fewer (or none:
  // older than this check) gets the deploy notice in the top bar.
  const REQUIRED_VERBS = ["jobs", "job", "job.save", "job.run", "remotes", "remote.create", "fs.browse", "remote.browse"];

  function updateBackendNotice(status) {
    const verbs = status?.verbs;
    const missing = Array.isArray(verbs) ? REQUIRED_VERBS.filter((verb) => !verbs.includes(verb)) : REQUIRED_VERBS;
    const banner = $("#backend-banner");
    banner.hidden = missing.length === 0;
    if (missing.length) banner.textContent = `Backup Suite on the server is older than this GUI: backup jobs, destinations or folder pickers may not work yet. Deploy the latest version (sudo ./production-deploy.sh …), then reload.`;
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

  // Admin: actions and schedule -----------------------------------------------

  renderers.actions = (body) => {
    const status = state.status;
    if (!status) {
      body.append(state.statusError ? errorNode(state.statusError) : loadingNode());
      if (state.statusError?.code === "not_installed" || state.statusError?.code === "forbidden") body.append(installHelp());
      return;
    }
    const backupState = fileBackupState(status);
    const running = backupState.key === "running" || backupState.key === "paused";
    const progress = status.progress || {};
    const cards = h("div", { class: "cards" });
    cards.append(h("section", { class: "card" }, h("h3", {}, "File backup"), kv([
      ["State", pill(backupState.label, backupState.key === "running" ? "info" : backupState.key === "failed" ? "bad" : backupState.key === "paused" ? "warn" : "ok")],
      running && progress.current_entry ? ["Job", progress.current_entry] : null,
      running && progress.current_project ? ["Project", h("code", {}, progress.current_project)] : null,
      status.watchdog_last_action?.reason ? ["Last watchdog stop", h("span", {}, status.watchdog_last_action.reason, " ", timeNode(status.watchdog_last_action.at || status.watchdog_last_action.time))] : null
    ].filter(Boolean)),
    h("div", { class: "toolbar-row tight" },
      h("button", { type: "button", class: "primary-button", dataset: { key: "start-files" }, disabled: running, onclick: () => runAction("start-files") }, "Start file backup now"),
      h("button", { type: "button", class: "danger-button", dataset: { key: "stop-files" }, disabled: !running, onclick: () => runAction("stop-files") }, "Stop file backup")),
    h("p", { class: "muted" }, "A scheduled file backup covers every enabled job, in file-sources.conf order. To back up one job, use Back up now on its page.")));
    const dbRows = ["database-backup.service", "database-size-check.service"].map((unit) => {
      const info = status.services?.[unit] || {};
      const ok = !info.Result || info.Result === "success";
      return [unit.replace(".service", ""), h("span", {}, pill(info.ActiveState === "active" ? "running" : ok ? "ok" : info.Result, info.ActiveState === "active" ? "info" : ok ? "ok" : "bad"), " last ", timeNode(info.ExecMainExitTimestamp || info.InactiveEnterTimestamp))];
    });
    cards.append(h("section", { class: "card" }, h("h3", {}, "Database backups"), kv(dbRows),
      h("div", { class: "toolbar-row tight" }, h("button", { type: "button", dataset: { key: "start-databases" }, onclick: () => runAction("start-databases") }, "Start database backup now"))));
    cards.append(h("section", { class: "card" }, h("h3", {}, "Notifications"),
      h("p", { class: "muted" }, "Sends one ntfy message in the real alert format, with an attached detail file."),
      h("div", { class: "toolbar-row tight" }, h("button", { type: "button", dataset: { key: "notify-test" }, onclick: () => runAction("notify-test") }, "Send test notification"))));
    const timerEnabled = status.timers_enabled?.["file-backup.timer"];
    const timer = status.timers?.["file-backup.timer"] || {};
    const scheduleOff = timerEnabled !== "enabled" || timer.ActiveState !== "active";
    const scheduleCard = h("section", { class: `card wide ${scheduleOff ? "alert-warn" : ""}` }, h("h3", {}, "Schedule"));
    if (scheduleOff) scheduleCard.append(h("p", { class: "notice", role: "alert" }, "Scheduled file backups are OFF. Turn file-backup.timer on to resume them."));
    scheduleCard.append(timersTable(status));
    cards.append(scheduleCard);
    body.append(cards);
  };

  // Admin: logs -------------------------------------------------------------------

  const LOG_SOURCES = [
    ["file-backup", "File backup (journal)"], ["watchdog", "Watchdog"], ["database-backup", "Database backup"],
    ["database-size-check", "Database size check"], ["control", "GUI control requests"]
  ];

  renderers.logs = (body) => {
    const select = h("select", { "aria-label": "Log" }, LOG_SOURCES.map(([key, label]) => h("option", { value: key, selected: key === state.logSource }, label)));
    const lines = h("select", { "aria-label": "Lines" }, [200, 500, 2000].map((count) => h("option", { value: String(count) }, `last ${count} lines`)));
    const host = h("div", {});
    const load = async () => {
      state.logSource = select.value;
      clear(host).append(loadingNode());
      try {
        const journal = await control("journal", { source: select.value, lines: Number(lines.value) });
        clear(host).append(journal.truncated ? h("p", { class: "notice info" }, "Shortened to the last 1 MiB.") : null, textBlock(journal.lines, { fileName: `${select.value}.log` }));
      } catch (error) {
        clear(host).append(errorNode(error));
      }
    };
    select.addEventListener("change", load);
    lines.addEventListener("change", load);
    body.append(h("div", { class: "filters" }, h("label", {}, "Log", select), h("label", {}, "Show", lines),
      h("button", { type: "button", onclick: load }, "Reload"),
      h("button", { type: "button", onclick: () => openRun({ started: "latest" }) }, "Latest run's full log")), host);
    load();
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
    } else if (entry.kind === "patterns") {
      input = h("textarea", { id, name: entry.key, rows: "4", spellcheck: "false", dataset: { join: "|" } });
      input.value = (entry.value || "").split("|").filter(Boolean).join("\n");
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
    for (const input of container.querySelectorAll("input[name], select[name], textarea[name]")) {
      if (input.name.endsWith("__clear")) {
        if (input.checked) changes[input.name.replace("__clear", "")] = "";
        continue;
      }
      if (input.type === "password" || (input.type === "url" && !input.value)) {
        if (input.value) changes[input.name] = input.value.trim();
        continue;
      }
      if (input.value === input.dataset.original) continue;
      changes[input.name] = input.dataset.join ? input.value.split("\n").map((line) => line.trim()).filter(Boolean).join(input.dataset.join) : input.value.trim();
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

  // Admin: notification channels -------------------------------------------------
  //
  // Each channel has its switch, its settings, a test and its delivery log. ntfy is
  // the only channel so far; the others are listed as planned.

  const PLANNED_CHANNELS = [
    ["Telegram", "A bot posts each notification to a chat or group."],
    ["WhatsApp", "Through the WhatsApp Business API or a gateway."],
    ["Email", "Through an SMTP server you choose."],
    ["SMS", "Through an SMS gateway, for errors only."]
  ];

  renderers.notifications = async (body) => {
    body.append(loadingNode());
    let config;
    try {
      [config] = await Promise.all([control("config.get"), api("/api/events?limit=500").then((list) => { state.events = list.events; })]);
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    clear(body);
    const byKey = Object.fromEntries(config.settings.map((entry) => [entry.key, entry]));
    const enabled = (byKey.NOTIFY_FAILURES_ENABLED.value || byKey.NOTIFY_FAILURES_ENABLED.default) === "1";
    const configured = byKey.NOTIFY_NTFY_TOPIC_URL.is_set;
    body.append(h("p", { class: "muted" }, "Backup Suite writes one message per event and sends it through every enabled channel. The bell lists them all with each channel's result."));

    const log = state.events.filter((event) => eventDelivery(event).channels.ntfy).slice().reverse();
    const counts = log.reduce((sum, event) => { sum[eventDelivery(event).channels.ntfy] = (sum[eventDelivery(event).channels.ntfy] || 0) + 1; return sum; }, {});
    const form = h("div", {});
    form.append(h("div", { class: "threshold-grid" }, NTFY_KEYS.filter((key) => byKey[key] && key !== "NOTIFY_FAILURES_ENABLED").map((key) => settingField(byKey[key]))));
    const ntfyCard = h("section", { class: `card wide channel-card ${enabled ? "" : "is-disabled"}` },
      h("div", { class: "channel-head" }, h("h3", {}, "ntfy"), pill(enabled ? (configured ? "enabled" : "enabled, no topic") : "disabled", enabled && configured ? "ok" : "warn")),
      kv([
        ["Topic", configured ? h("code", {}, byKey.NOTIFY_NTFY_TOPIC_URL.value) : "not set"],
        ["Token", byKey.NOTIFY_NTFY_TOKEN.is_set ? "set (never shown)" : "not set"],
        ["Last 500 events", `${counts.sent || 0} sent, ${counts.failed || 0} failed, ${counts.off || 0} while off`]
      ]),
      h("div", { class: "toolbar-row tight" },
        h("button", { type: "button", class: enabled ? "danger-button" : "primary-button", onclick: async () => {
          if (await saveConfig({ NOTIFY_FAILURES_ENABLED: enabled ? "0" : "1" }, config, { title: enabled ? "Disable the ntfy channel?" : "Enable the ntfy channel?", note: enabled ? "Notifications are still recorded and shown in the bell." : "From the next notification on." })) renderAdmin();
        } }, enabled ? "Disable channel…" : "Enable channel…"),
        h("button", { type: "button", onclick: () => runAction("notify-test") }, "Send test notification…")),
      h("details", { open: !configured }, h("summary", {}, "Settings"), form,
        h("p", { class: "muted" }, "The topic is shown shortened; leave it empty to keep it, or type a full https:// URL to replace it. The token can be replaced or cleared, never read."),
        h("div", { class: "toolbar-row end" }, h("button", { type: "button", class: "primary-button", onclick: async () => {
          if (await saveConfig(collectChanges(form), config, { title: "Save ntfy settings?", note: "They apply to the next notification." })) renderAdmin();
        } }, "Save ntfy settings…"))),
      h("h4", {}, "Delivery log"),
      log.length ? h("div", { class: "table-wrap" }, h("table", {},
        h("thead", {}, h("tr", {}, ["Time", "Result", "Notification", "Why it failed"].map((label) => h("th", {}, label)))),
        h("tbody", {}, log.slice(0, 200).map((event) => {
          const result = eventDelivery(event).channels.ntfy;
          const [word, kind] = DELIVERY_LABELS[result] || [result, ""];
          return h("tr", {}, h("td", {}, timeNode(event.created_at)), h("td", {}, pill(word, kind)), h("td", {}, event.title),
            h("td", { class: "muted" }, result === "failed" ? (event.delivery_note || "—").replace(/^ntfy: /, "") : ""));
        })))) : h("p", { class: "muted" }, "Nothing sent through ntfy yet."));
    body.append(h("div", { class: "cards" }, ntfyCard,
      PLANNED_CHANNELS.map(([name, note]) => h("section", { class: "card channel-card is-disabled" },
        h("div", { class: "channel-head" }, h("h3", {}, name), pill("planned", "")), h("p", { class: "muted" }, note)))));
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
    body.append(h("h3", {}, "Jobs (lines)"), sources.rows.length ? h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, ["Line", "Enabled", "Label", "Source", "Destination", "Stop file", "Isolation"].map((label) => h("th", {}, label)))),
      h("tbody", {}, sources.rows.map((row) => h("tr", {},
        h("td", { class: "num" }, row.line),
        h("td", {}, pill(row.enabled === "1" ? "yes" : "no", row.enabled === "1" ? "ok" : "")),
        h("td", {}, row.label),
        h("td", {}, h("code", {}, row.source), row.source_exists ? "" : h("span", {}, " ", pill("missing", "bad"))),
        h("td", {}, `${row.destination_mode}${row.destination_value ? `: ${row.destination_value}` : ""}`),
        h("td", {}, row.stop_file || "default"),
        h("td", {}, row.isolation)))))) : h("p", { class: "empty" }, "No jobs."));
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

  // ------------------------------------------------------------------ entries
  //
  // An entry is one line of file-sources.conf: a source directory backed up to one
  // destination, as one project (isolation single) or one project per child
  // directory (isolation children). The sidebar lists them as cards; each has its
  // own page. Everything that is not about one entry is under Admin.

  const RESULT_LABELS = {
    synced: ["synced", "ok"],
    "synced-retry": ["synced on retry", "ok"],
    "synced-with-skips": ["synced, changing files kept", "warn"],
    failed: ["failed", "bad"],
    "migration-required": ["needs link-migration confirmation", "bad"],
    "migration-report": ["migration report only", "info"],
    "skipped-stop-file": ["paused by stop file", "warn"],
    "skipped-filter": ["outside migration filter", ""],
    "skipped-migrated": ["already migrated", ""],
    "missing-source": ["source missing", "bad"],
    "unreadable-source": ["source unreadable", "bad"],
    "invalid-config": ["config error", "bad"],
    "no-child-projects": ["no child projects", "bad"],
    running: ["running", "info"],
    attention: ["needs attention", "warn"],
    skipped: ["skipped", "warn"],
    unknown: ["no record yet", ""]
  };

  function resultPill(result) {
    const [label, kind] = RESULT_LABELS[result] || [result || "—", ""];
    return pill(label, kind);
  }

  function entryHash(name, tab) {
    return `#job/${encodeURIComponent(name)}${tab && tab !== "overview" ? `/${tab}` : ""}`;
  }

  // The state an entry is in now, for its card and its page.
  function entryCondition(entry) {
    if (!entry.enabled) return { key: "disabled", label: "disabled", kind: "" };
    if (entry.running) return { key: "running", label: "backing up now", kind: "info" };
    if (entry.problem) return { key: "problem", label: "config problem", kind: "bad" };
    if (entry.stop_file_present) return { key: "paused", label: `paused (${entry.stop_file})`, kind: "warn" };
    const last = entry.last_run;
    if (!last) return { key: "none", label: "no run recorded", kind: "" };
    if (last.outcome === "failed") return { key: "failed", label: "last run failed", kind: "bad" };
    if (entry.never_settles) return { key: "settle", label: `${entry.never_settles} file(s) never settle`, kind: "warn" };
    if (last.outcome === "synced-with-skips") return { key: "skips", label: "synced, files kept for next run", kind: "warn" };
    if (last.outcome === "synced") return { key: "ok", label: "backed up", kind: "ok" };
    return { key: last.outcome, label: (RESULT_LABELS[last.outcome] || [last.outcome])[0], kind: "warn" };
  }

  function entryNeedsAttention(entry) {
    return entry.enabled && ["problem", "failed", "settle", "paused"].includes(entryCondition(entry).key);
  }

  function nextRunDate() {
    return parseTime(state.entriesData?.run?.next_run || state.status?.timers?.["file-backup.timer"]?.NextElapseUSecRealtime);
  }

  async function loadEntries({ quiet = false } = {}) {
    try {
      state.entriesData = await control("jobs");
      state.entriesError = null;
    } catch (error) {
      state.entriesError = error;
      if (!quiet && error?.code !== "invalid_request") toast(`Backup jobs: ${errorText(error)}`, "error");
    }
    state.entriesLoadedAt = Date.now();
    renderEntryList();
    if (state.view.kind === "home") renderMain();
  }

  // The entry verbs arrived with the per-entry pages; an older installed Backup Suite
  // answers "Unknown verb" until it is deployed again.
  function entriesErrorNode(error) {
    if (isOutdatedBackendError(error)) {
      return h("div", { class: "notice info" }, "The installed Backup Suite is older than this GUI: backup jobs need the latest version. Deploy it (sudo ./production-deploy.sh …), then reload. Home and Admin work meanwhile.");
    }
    return errorNode(error);
  }

  function renderEntryList() {
    const host = $("#entry-list");
    const data = state.entriesData;
    if (!data) {
      clear(host).append(state.entriesError ? entriesErrorNode(state.entriesError) : loadingNode("Loading backup jobs…"));
      return;
    }
    const filter = $("#entry-filter").value;
    const entries = data.jobs.filter((entry) => filter === "all" || (filter === "enabled" ? entry.enabled : entryNeedsAttention(entry)));
    const home = $("#home-button");
    if (state.view.kind === "home") home.setAttribute("aria-current", "page");
    else home.removeAttribute("aria-current");
    const attention = data.jobs.filter(entryNeedsAttention).length;
    $("#home-card-note").textContent = attention ? `${attention} job${attention === 1 ? " needs" : "s need"} attention` : "System condition";
    const cards = entries.map((entry) => {
      const condition = entryCondition(entry);
      const selected = state.view.kind === "entry" && state.view.name === entry.name;
      const last = entry.last_run;
      return h("button", {
        type: "button", class: `entry-card ${entry.enabled ? "" : "is-disabled"} condition-${condition.key}`,
        "aria-current": selected ? "page" : null, dataset: { entry: entry.name },
        onclick: () => openEntry(entry.name)
      },
      h("span", { class: "entry-card-head" }, h("strong", {}, entry.name), pill(entry.enabled ? "yes" : "no", entry.enabled ? "ok" : "")),
      h("span", { class: "entry-card-status" }, pill(condition.label, condition.kind),
        entry.running && entry.current_project ? h("span", { class: "muted" }, ` ${entry.current_project.split("/").pop()}`) : null),
      h("code", { class: "entry-card-path" }, entry.source),
      h("span", { class: "entry-card-meta" }, `${entry.destination_mode}${entry.destination_value ? `: ${entry.destination_value}` : ""} · ${entry.stop_file} · ${entry.isolation}${entry.children !== null && entry.children !== undefined ? ` (${entry.children})` : ""}`),
      entry.enabled ? h("span", { class: "entry-card-meta" },
        last ? h("span", {}, "last ", h("span", {}, relative(parseTime(last.ended || last.run)) || "—")) : "never run",
        last && last.changes_known ? ` · ${last.new + last.updated + last.removed} changed` : "",
        entry.changing_files ? ` · ${entry.changing_files} changing` : "") : null);
    });
    append(clear(host), [cards.length ? cards : h("p", { class: "empty" }, filter === "attention" ? "No job needs attention." : "No backup jobs yet. Add one with + New job.")]);
    if (data.legacy) host.append(h("p", { class: "muted small-note" }, "Per-job history starts with the next backup run; until then the latest run's log is used."));
  }

  function openEntry(name, tab = "overview") {
    const hash = entryHash(name, tab);
    if (location.hash !== hash) history.pushState(null, "", hash);
    route();
  }

  function goHome() {
    if (location.hash !== "#home") history.pushState(null, "", "#home");
    route();
  }

  // ------------------------------------------------------------------ home

  function systemVerdict(status, entriesData) {
    const problems = [];
    const notes = [];
    if (!status) return { level: "unknown", problems, notes };
    const backup = fileBackupState(status);
    const timerEnabled = status.timers_enabled?.["file-backup.timer"];
    if (timerEnabled && timerEnabled !== "enabled") problems.push("Scheduled file backups are OFF (file-backup.timer).");
    if (backup.key === "paused") problems.push("The watchdog has paused the backup: the server is short of memory.");
    if (backup.key === "failed") problems.push("The last file backup failed.");
    if (backup.contained) notes.push("The watchdog is containing a memory surge in the backup.");
    const watchdog = status.watchdog || {};
    const available = numberOrNull(status.server?.available_percent);
    const pausePercent = numberOrNull(watchdog.threshold_server_pause_percent) ?? 10;
    if (available !== null && available < pausePercent) problems.push(`Server RAM available is ${available}% (the watchdog pauses below ${pausePercent}%).`);
    if (watchdog.server_pressure === "host-stall" && watchdog.server_pressure_note) notes.push(`Memory stall caused outside the backup: ${watchdog.server_pressure_note}.`);
    for (const unit of ["database-backup.service", "database-size-check.service"]) {
      const info = status.services?.[unit];
      if (info && info.Result && info.Result !== "success") problems.push(`${unit.replace(".service", "")}: last result ${info.Result}.`);
    }
    if (entriesData) {
      for (const entry of entriesData.jobs.filter(entryNeedsAttention)) {
        const condition = entryCondition(entry);
        (condition.kind === "bad" ? problems : notes).push(`${entry.name}: ${condition.label}.`);
      }
    }
    return { level: problems.length ? "bad" : notes.length ? "warn" : "ok", problems, notes };
  }

  function renderHome(body) {
    const status = state.status;
    if (!status) {
      body.append(state.statusError ? errorNode(state.statusError) : loadingNode());
      if (state.statusError?.code === "not_installed" || state.statusError?.code === "forbidden") body.append(installHelp());
      return;
    }
    const verdict = systemVerdict(status, state.entriesData);
    const backupState = fileBackupState(status);
    const progress = status.progress || {};
    const running = backupState.key === "running" || backupState.key === "paused";
    const cards = h("div", { class: "cards" });

    const verdictCard = h("section", { class: `card wide verdict verdict-${verdict.level}` },
      h("h3", {}, verdict.level === "ok" ? "Everything is in order" : verdict.level === "warn" ? "Working, with notes" : verdict.level === "bad" ? "Needs attention" : "Checking…"));
    if (verdict.problems.length) verdictCard.append(h("ul", {}, verdict.problems.map((line) => h("li", {}, line))));
    if (verdict.notes.length) verdictCard.append(h("ul", { class: "muted" }, verdict.notes.map((line) => h("li", {}, line))));
    if (!verdict.problems.length && !verdict.notes.length) verdictCard.append(h("p", { class: "muted" }, "The schedule is on, the server has memory to spare, and every enabled job's last run was backed up."));
    cards.append(verdictCard);

    const next = nextRunDate();
    const nowRows = [["File backup", pill(backupState.label, backupState.key === "running" ? "info" : backupState.key === "failed" ? "bad" : backupState.key === "paused" ? "warn" : "ok")]];
    if (running) {
      const started = parseTime(progress.started_at);
      nowRows.push(["Started", h("span", {}, timeNode(progress.started_at), started ? ` (${relative(started)})` : "")]);
      if (progress.current_entry) nowRows.push(["Job", h("button", { type: "button", class: "link-button", onclick: () => openEntry(progress.current_entry) }, progress.current_entry)]);
      if (progress.current_project) nowRows.push(["Project", h("code", {}, progress.current_project)]);
      if (progress.projects_total) nowRows.push(["Progress", `project ${progress.project_index || 0} of ${progress.projects_total}`]);
      nowRows.push(["So far", `synced ${progress.synced || 0}, skipped ${progress.skipped || 0}, kept while changing ${(Number(progress.skipped_changed) || 0) + (Number(progress.deferred_active) || 0)}, failed ${progress.failed || 0}`]);
    } else {
      nowRows.push(["Last finished", timeNode(status.services?.["file-backup.service"]?.ExecMainExitTimestamp || progress.updated_at)]);
      if (progress.outcome) nowRows.push(["Last outcome", progress.outcome]);
    }
    nowRows.push(["Next run", next ? h("span", {}, timeNode(next.toISOString()), ` (${relative(next)})`) : "not scheduled"]);
    cards.append(h("section", { class: "card" }, h("h3", {}, "Now"), kv(nowRows),
      h("div", { class: "toolbar-row tight" }, h("button", { type: "button", onclick: () => openAdmin("actions") }, "Start, stop, schedule…"))));

    const profile = state.profiles;
    cards.append(h("section", { class: "card" }, h("h3", {}, "Resource profile"), profile ? kv([
      ["Setup", profile.mode === "adaptive" ? `Adaptive ${profile.ladder.join(" ↔ ")}` : `Fixed: ${profile.ladder[0]}`],
      ["Now", profile.mode === "adaptive" ? `${status.adaptive_level || profile.current_level}${progress.profile && running ? ` (this run: ${progress.profile})` : ""}` : profile.ladder[0]],
      ["Limits", profile.limits_mode]
    ]) : loadingNode(), h("div", { class: "toolbar-row tight" }, h("button", { type: "button", onclick: () => openAdmin("profiles") }, "Profiles & limits…"))));

    cards.append(h("section", { class: "card wide" }, h("h3", {}, "Server and backup resources (live)"), resourceGauges(status)));
    cards.append(h("section", { class: "card wide" }, h("h3", {}, `Last ${state.settings?.general?.chartMinutes || 30} minutes`),
      chartNode(state.chart),
      h("div", { class: "legend" }, h("span", { class: "memory" }, "Backup memory (% of hard limit)"), h("span", { class: "cpu" }, "Backup CPU %"), h("span", { class: "available" }, "Server RAM available %"))));

    const data = state.entriesData;
    const entriesCard = h("section", { class: "card wide" }, h("h3", {}, "Backup jobs"));
    if (data) {
      entriesCard.append(h("div", { class: "table-wrap" }, h("table", {},
        h("thead", {}, h("tr", {}, ["Job", "State", "Last run", "Last backed up", "Changed last run", "Changing files"].map((label) => h("th", {}, label)))),
        h("tbody", {}, data.jobs.map((entry) => {
          const condition = entryCondition(entry);
          const last = entry.last_run;
          return h("tr", { class: `clickable ${entry.enabled ? "" : "is-disabled"}`, tabindex: "0", onclick: () => openEntry(entry.name), onkeydown: (event) => { if (event.key === "Enter") openEntry(entry.name); } },
            h("td", {}, h("strong", {}, entry.name)), h("td", {}, pill(condition.label, condition.kind)),
            h("td", {}, last ? timeNode(last.run) : "—"), h("td", {}, entry.last_success ? timeNode(entry.last_success) : "—"),
            h("td", { class: "num" }, last && last.changes_known ? String(last.new + last.updated + last.removed) : "—"),
            h("td", { class: "num" }, entry.changing_files ? h("span", {}, String(entry.changing_files), entry.never_settles ? h("span", {}, " ", pill(`${entry.never_settles} never settle`, "warn")) : "") : "0"));
        })))));
      entriesCard.append(h("p", { class: "muted" }, `Destination root ${data.remote_base || "—"}; replaced and deleted files are kept under ${data.archive_folder} for ${data.retention}.`));
    } else {
      entriesCard.append(state.entriesError ? entriesErrorNode(state.entriesError) : loadingNode());
    }
    cards.append(entriesCard);

    const lastRun = state.history?.rows?.[0];
    cards.append(h("section", { class: "card" }, h("h3", {}, "Last recorded run"), lastRun ? [kv([
      ["Started", timeNode(lastRun.started)],
      ["Outcome", pill(lastRun.outcome, lastRun.outcome === "completed" ? "ok" : "bad")],
      ["Duration", duration(lastRun.duration_s)],
      ["Peak RAM", `${bytes(lastRun.peak_mem)} (${bytes(lastRun.peak_anon)} not reclaimable)`],
      ["Watchdog events", lastRun.events.length ? lastRun.events.join(", ") : "none"]
    ]), h("div", { class: "toolbar-row tight" }, h("button", { type: "button", onclick: () => openAdmin("runs") }, "All runs…"))] : h("p", { class: "muted" }, state.history ? "No run recorded by the watchdog yet." : "Loading…")));

    const dbRows = ["database-backup.service", "database-size-check.service"].map((unit) => {
      const info = status.services?.[unit] || {};
      const ok = !info.Result || info.Result === "success";
      return [unit.replace(".service", ""), h("span", {}, pill(info.ActiveState === "active" ? "running" : ok ? "ok" : info.Result, info.ActiveState === "active" ? "info" : ok ? "ok" : "bad"), " last ", timeNode(info.ExecMainExitTimestamp || info.InactiveEnterTimestamp))];
    });
    cards.append(h("section", { class: "card" }, h("h3", {}, "Database backups"), kv(dbRows)));

    const pushed = sentEvents().slice(-5).reverse();
    cards.append(h("section", { class: "card" }, h("h3", {}, "Latest notifications"),
      pushed.length ? h("ul", { class: "event-list compact" }, pushed.map((event) => eventItem(event, false))) : h("p", { class: "muted" }, "None yet."),
      h("div", { class: "toolbar-row tight" }, h("button", { type: "button", onclick: openBell }, "Open notifications"))));
    body.append(cards);
  }

  // ------------------------------------------------------------------ exclude a changing file

  let openContextMenu = null;

  function closeContextMenu() {
    if (!openContextMenu) return;
    const { menu, restoreFocus } = openContextMenu;
    openContextMenu = null;
    menu.remove();
    document.removeEventListener("pointerdown", contextMenuOutside, true);
    document.removeEventListener("keydown", contextMenuKey, true);
    window.removeEventListener("scroll", contextMenuScroll, true);
    window.removeEventListener("resize", closeContextMenu);
    if (restoreFocus && document.contains(restoreFocus)) restoreFocus.focus();
  }

  function contextMenuOutside(event) {
    if (openContextMenu && !openContextMenu.menu.contains(event.target)) closeContextMenu();
  }

  function contextMenuScroll(event) {
    if (openContextMenu && !(event.target instanceof Node && openContextMenu.menu.contains(event.target))) closeContextMenu();
  }

  function contextMenuKey(event) {
    if (!openContextMenu) return;
    const items = [...openContextMenu.menu.querySelectorAll("button")];
    const index = items.indexOf(document.activeElement);
    if (event.key === "Escape") {
      event.preventDefault();
      closeContextMenu();
    } else if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      items[(index + step + items.length) % items.length]?.focus({ preventScroll: false });
    }
  }

  // showContextMenu(x, y, [{heading} | {label, detail, action}], focus element to restore)
  function showContextMenu(x, y, items, restoreFocus) {
    closeContextMenu();
    const menu = h("div", { class: "popover-menu context-menu", role: "menu" }, items.map((item) => item.heading
      ? h("div", { class: "context-menu-heading", role: "presentation" }, item.heading)
      : h("button", { type: "button", role: "menuitem", onclick: () => { closeContextMenu(); item.action(); } },
        h("span", {}, item.label), item.detail ? h("small", { class: "muted" }, item.detail) : null)));
    document.body.append(menu);
    const width = menu.offsetWidth;
    const height = menu.offsetHeight;
    menu.style.left = `${Math.max(8, Math.min(x, window.innerWidth - width - 8))}px`;
    menu.style.top = `${Math.max(8, Math.min(y, window.innerHeight - height - 8))}px`;
    openContextMenu = { menu, restoreFocus };
    document.addEventListener("pointerdown", contextMenuOutside, true);
    document.addEventListener("keydown", contextMenuKey, true);
    menu.querySelector("button")?.focus({ preventScroll: true });
    // Listen for scrolling only after the menu has settled.
    window.setTimeout(() => {
      if (openContextMenu?.menu !== menu) return;
      window.addEventListener("scroll", contextMenuScroll, true);
      window.addEventListener("resize", closeContextMenu);
    }, 0);
  }

  // The file itself, then each parent folder up to the project's own folder.
  function excludeTargets(path) {
    const parts = String(path || "").split("/").filter(Boolean);
    const targets = [];
    if (!parts.length) return targets;
    targets.push({ path: parts.join("/"), folder: false, shown: parts.join("/") });
    for (let depth = parts.length - 1; depth >= 1; depth -= 1) {
      const folder = parts.slice(0, depth).join("/");
      targets.push({ path: folder, folder: true, shown: `${folder}/` });
    }
    return targets;
  }

  function changingRowMenu(event, data, row) {
    event.preventDefault();
    const entry = data.entry;
    const child = entry.isolation === "children" ? String(row.project || "").split("/").pop() : "";
    const targets = excludeTargets(row.path);
    const items = [];
    if (child) {
      items.push({ heading: `Exclude in ${child} only` });
      for (const target of targets) items.push({ label: target.shown, detail: target.folder ? "this folder and everything in it" : "this file", action: () => excludeChanging(data, target, "project", child) });
    }
    items.push({ heading: child ? `Exclude in every project of ${entry.name} (each folder in ${entry.source})` : `Exclude in ${entry.name}` });
    for (const target of targets) items.push({ label: target.shown, detail: target.folder ? "this folder and everything in it" : "this file", action: () => excludeChanging(data, target, "job", "") });
    const anchor = event.currentTarget instanceof Element ? event.currentTarget : null;
    let x = event.clientX;
    let y = event.clientY;
    if (!x && !y && anchor) {
      const box = anchor.getBoundingClientRect();
      x = box.left;
      y = box.bottom;
    }
    showContextMenu(x, y, items, anchor);
  }

  async function excludeChanging(data, target, scope, child) {
    const entry = data.entry;
    const where = scope === "project" ? `project ${child} only` : (entry.isolation === "children" ? `every project of ${entry.name} (each folder in ${entry.source}, also ones added later)` : `job ${entry.name}`);
    if (!(await confirmAction({
      title: `Exclude ${target.shown}?`,
      lines: [
        `${target.folder ? "This folder and everything in it" : "This file"} will no longer be backed up in ${where}, from the next run on.`,
        ["The copy already on the remote stays as it is; nothing is deleted there.",
          "The pattern is kept in Backup Suite's config for this job, not in the project's folder. Remove it again under Excludes & stop files.",
          "The change is audited and listed in Activity."]
      ],
      okLabel: "Exclude"
    }))) return;
    try {
      const result = await control("job.exclude", { name: entry.name, path: target.path, folder: target.folder, scope, project: scope === "project" ? child : undefined });
      toast(result.added ? `Excluded ${target.shown} (${scope === "project" ? child : "every project"}).` : `${target.shown} was already excluded there.`);
      delete state.entryCache[entry.name];
      await loadEntries({ quiet: true });
      renderMain();
    } catch (error) {
      toast(`Failed: ${errorText(error)}`, "error", 10000);
    }
  }

  async function removeJobExclude(entry, scope, child, pattern) {
    if (!(await confirmAction({
      title: `Back up ${pattern} again?`,
      lines: [`${pattern} is backed up again in ${scope === "project" ? `project ${child}` : `every project of ${entry.name}`} from the next run (unless another pattern excludes it).`],
      okLabel: "Remove exclude"
    }))) return;
    try {
      await control("job.exclude", { name: entry.name, scope, project: scope === "project" ? child : undefined, remove: true, pattern });
      toast(`${pattern} is no longer excluded.`);
      delete state.entryCache[entry.name];
      renderMain();
    } catch (error) {
      toast(`Failed: ${errorText(error)}`, "error", 10000);
    }
  }

  // ------------------------------------------------------------------ entry page

  const ENTRY_TABS = [
    ["overview", "Overview"], ["projects", "Projects"], ["changes", "Changed files"], ["changing", "Changing files"],
    ["excludes", "Excludes & stop files"], ["runs", "Runs"], ["log", "Log"], ["storage", "Source & destination"]
  ];

  async function renderEntry(body, name, tab) {
    let data = state.entryCache[name];
    if (!data) body.append(loadingNode());
    try {
      data = await control("job", { name });
      state.entryCache[name] = data;
    } catch (error) {
      if (!data) {
        clear(body).append(entriesErrorNode(error), h("div", { class: "toolbar-row tight" }, h("button", { type: "button", onclick: goHome }, "Back to Home")));
        return;
      }
      toast(`Showing the last loaded view: ${errorText(error)}`, "warn");
    }
    clear(body);
    const entry = data.entry;
    const condition = entryCondition(entry);
    $("#section-title").textContent = entry.name;
    body.append(h("div", { class: "entry-headline" },
      pill(entry.enabled ? "enabled" : "disabled", entry.enabled ? "ok" : ""), " ", pill(condition.label, condition.kind),
      h("span", { class: "muted" }, ` line ${entry.line} of file-sources.conf · ${entry.isolation === "children" ? `one project per child directory (${data.projects.length})` : "one project"}`)));
    body.append(jobActionBar(data));
    if (data.legacy) body.append(h("p", { class: "notice info" }, "Per-job history is recorded from the next backup run on. Until then this page shows what the latest run's log says."));
    const tabBar = h("div", { class: "settings-tabs entry-tabs", role: "tablist", "aria-label": `${entry.name} sections` },
      ENTRY_TABS.map(([key, label]) => h("button", { type: "button", role: "tab", "aria-selected": String(key === tab), onclick: () => openEntry(name, key) }, label)));
    const panel = h("div", { class: "entry-panel", role: "tabpanel" });
    body.append(tabBar, panel);
    const builder = ENTRY_RENDERERS[tab] || ENTRY_RENDERERS.overview;
    await builder(panel, data);
  }

  function projectRowNodes(project, data) {
    const last = project.last;
    const changes = project.changes;
    return h("tr", { class: `clickable ${project.exists ? "" : "is-disabled"}`, tabindex: "0", onclick: () => openProject(data, project), onkeydown: (event) => { if (event.key === "Enter") openProject(data, project); } },
      h("td", {}, h("strong", {}, project.name), project.exists ? "" : h("span", {}, " ", pill("gone from source", "warn")), project.running ? h("span", {}, " ", pill("now", "info")) : ""),
      h("td", {}, project.stop_file_present ? pill(`paused (${data.entry.stop_file})`, "warn") : last ? resultPill(last.result) : resultPill("unknown")),
      h("td", {}, last ? timeNode(last.ended || last.run) : "—"),
      h("td", {}, project.last_success ? timeNode(project.last_success) : "—"),
      h("td", { class: "num" }, changes ? `${changes.new} / ${changes.updated} / ${changes.removed}` : "—"),
      h("td", { class: "num" }, project.changing_files ? h("span", {}, String(project.changing_files), project.never_settles ? h("span", {}, " ", pill("never settles", "warn")) : "") : "0"));
  }

  function projectsTable(data, projects) {
    return h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, ["Project", "Last result", "Last run", "Last backed up", "New / updated / removed", "Changing files"].map((label) => h("th", {}, label)))),
      h("tbody", {}, projects.map((project) => projectRowNodes(project, data)))));
  }

  async function openProject(data, project) {
    const title = `Project ${project.name}`;
    const head = kv([
      ["Source", h("code", {}, project.source)],
      ["Destination", h("code", {}, project.destination || "—")],
      ["Last result", project.last ? resultPill(project.last.result) : "no record yet"],
      ["Last run", project.last ? timeNode(project.last.ended || project.last.run) : "—"],
      ["Last backed up", project.last_success ? timeNode(project.last_success) : "—"],
      ["Runs recorded", String(project.runs)],
      ["Stop file", project.stop_file_present ? `${data.entry.stop_file} is present: this project is skipped` : "not present"]
    ]);
    showDetails(title, [head, loadingNode("Loading this project's changed files…")]);
    try {
      const changes = await control("job.changes", { name: data.entry.name, project: project.project });
      showDetails(title, [head, changesView(changes)]);
    } catch (error) {
      showDetails(title, [head, h("h3", {}, "Changed files"), h("p", { class: "muted" }, error.code === "not_found" ? "No changes recorded for this project yet." : errorText(error))]);
    }
  }

  function changesView(changes) {
    const header = changes.header;
    const nodes = [h("h3", {}, "Changed files in its last run")];
    if (!header) {
      nodes.push(h("p", { class: "muted" }, "No change list recorded yet (it starts with the next run)."));
      return nodes;
    }
    nodes.push(h("p", {}, `Run ${header.run}: ${header.new} new, ${header.updated} updated, ${header.removed} removed (moved to the archive).`));
    if (changes.note) nodes.push(h("p", { class: "notice info" }, `Only part of the list is kept: ${changes.note}.`));
    if (!changes.files.length) {
      nodes.push(h("p", { class: "muted" }, "Nothing changed: the remote copy was already up to date."));
      return nodes;
    }
    nodes.push(textBlock(changes.files.map((file) => `${file.kind.padEnd(8)} ${file.path}`), { fileName: `changes-${changes.project.replace(/[^A-Za-z0-9._-]+/g, "_")}.txt` }));
    return nodes;
  }

  const ENTRY_RENDERERS = {
    overview: (panel, data) => {
      const entry = data.entry;
      const last = entry.last_run;
      const next = nextRunDate();
      const cards = h("div", { class: "cards" });
      if (entry.problem) cards.append(h("section", { class: "card wide alert-bad" }, h("h3", {}, "Problem"), h("p", {}, entry.problem)));
      if (entry.stop_file_present) cards.append(h("section", { class: "card wide alert-warn" }, h("h3", {}, "Paused"), h("p", {}, `${entry.stop_file} exists in ${entry.source}: the whole job is skipped until it is removed.`)));
      cards.append(h("section", { class: "card wide" }, h("h3", {}, "What is backed up, and where"), kv([
        ["Source", h("code", {}, entry.source)],
        ["Destination", h("code", {}, entry.destination || "—")],
        ["Mapping", `${entry.destination_mode}${entry.destination_value ? `: ${entry.destination_value}` : ""}`],
        ["Projects", entry.isolation === "children" ? `each child directory is its own project (${data.projects.length}); a failure in one never stops the others` : "the whole source is one project"],
        ["Stop file", `${entry.stop_file}: in the source pauses the job${entry.isolation === "children" ? ", in a child pauses that project" : ""}`],
        ["Previous versions", h("span", {}, "replaced and deleted files move to ", h("code", {}, entry.archive), ` and are kept ${entry.retention}`)]
      ])));
      const runRows = [
        ["State now", entry.running ? h("span", {}, pill("backing up now", "info"), entry.current_project ? ` ${entry.current_project}` : "") : pill(entryCondition(entry).label, entryCondition(entry).kind)],
        ["Last run", last ? h("span", {}, timeNode(last.run), " ", resultPill(last.outcome)) : "never"],
        ["Last backed up", entry.last_success ? timeNode(entry.last_success) : "—"],
        ["Last change uploaded", entry.last_change ? timeNode(entry.last_change) : "—"],
        ["Next run", next ? h("span", {}, timeNode(next.toISOString()), ` (${relative(next)})`) : "not scheduled"]
      ];
      if (data.position && next) {
        const reach = new Date(next.getTime() + data.position.offset_s * 1000);
        runRows.push(["Reaches this job", h("span", {}, "about ", timeNode(reach.toISOString()), ` and takes about ${duration(data.position.duration_s)} (as in the last run)`)]);
      }
      cards.append(h("section", { class: "card" }, h("h3", {}, "When"), kv(runRows)));
      cards.append(h("section", { class: "card" }, h("h3", {}, "Last run of this job"), last ? kv([
        ["Projects", `${last.projects}: ${last.synced} synced, ${last.skipped} skipped, ${last.failed} failed${last.other ? `, ${last.other} other` : ""}`],
        ["Files", last.changes_known ? `${last.new} new, ${last.updated} updated, ${last.removed} removed` : "not recorded (before per-job history)"],
        ["Kept while changing", String(last.deferred)],
        ["Took", last.started && last.ended ? duration((parseTime(last.ended) - parseTime(last.started)) / 1000) : "—"]
      ]) : h("p", { class: "muted" }, "No run recorded yet.")));
      cards.append(h("section", { class: "card" }, h("h3", {}, "Changing files"), kv([
        ["Being skipped now", String(entry.changing_files)],
        ["Never settle", entry.never_settles ? pill(String(entry.never_settles), "warn") : "0"],
        ["Rule", `files modified in the last ${data.active_window_s}s are skipped and tried again next run`]
      ]), h("div", { class: "toolbar-row tight" }, h("button", { type: "button", onclick: () => openEntry(entry.name, "changing") }, "Open changing files"))));
      const attention = data.projects.filter((project) => project.last && !["synced", "synced-retry", "synced-with-skips"].includes(project.last.result) || project.stop_file_present || project.never_settles);
      if (attention.length) {
        cards.append(h("section", { class: "card wide" }, h("h3", {}, "Projects needing a look"), projectsTable(data, attention.slice(0, 20))));
      }
      panel.append(cards);
    },

    projects: (panel, data) => {
      if (!data.projects.length) {
        panel.append(h("p", { class: "empty" }, data.entry.problem || "No projects."));
        return;
      }
      const search = h("input", { type: "search", placeholder: "Filter projects", "aria-label": "Filter projects" });
      const host = h("div", {});
      const draw = () => {
        const term = search.value.trim().toLowerCase();
        append(clear(host), [projectsTable(data, data.projects.filter((project) => !term || project.name.toLowerCase().includes(term)))]);
      };
      search.addEventListener("input", draw);
      panel.append(h("p", { class: "muted" }, "Click a project for its paths, history and the files that changed in its last run."), h("div", { class: "search-row" }, search), host);
      if (data.children_truncated) panel.append(h("p", { class: "notice info" }, "Only the first 2000 child directories are listed."));
      draw();
    },

    changes: async (panel, data) => {
      const changed = data.projects.filter((project) => project.changes && project.changes.new + project.changes.updated + project.changes.removed > 0);
      const totals = data.projects.reduce((sum, project) => {
        if (project.changes) for (const key of ["new", "updated", "removed"]) sum[key] += project.changes[key];
        return sum;
      }, { new: 0, updated: 0, removed: 0 });
      panel.append(h("p", {}, `In each project's last run: ${totals.new} new, ${totals.updated} updated and ${totals.removed} removed file(s), in ${changed.length} project(s). Removed and replaced versions are kept under the archive for ${data.entry.retention}.`));
      if (!changed.length) {
        panel.append(h("p", { class: "empty" }, data.legacy ? "Changed files are recorded from the next run on." : "No files changed in the last run."));
        return;
      }
      const host = h("div", {});
      panel.append(host);
      for (const project of changed.slice(0, 30)) {
        const section = h("details", { class: "changes-block" }, h("summary", {}, h("strong", {}, project.name), ` · ${project.changes.new} new, ${project.changes.updated} updated, ${project.changes.removed} removed · run ${project.changes.run}`));
        let loaded = false;
        section.addEventListener("toggle", async () => {
          if (!section.open || loaded) return;
          loaded = true;
          const target = h("div", {}, loadingNode());
          section.append(target);
          try {
            const changes = await control("job.changes", { name: data.entry.name, project: project.project });
            append(clear(target), changesView(changes).slice(1));
          } catch (error) {
            clear(target).append(errorNode(error));
          }
        });
        host.append(section);
      }
      if (changed.length > 30) panel.append(h("p", { class: "muted" }, `${changed.length - 30} more project(s) changed; open them from the Projects tab.`));
    },

    changing: (panel, data) => {
      panel.append(h("p", { class: "muted" }, `A file modified in the last ${data.active_window_s}s before its project syncs, or seen changing during the upload, is skipped: its previous remote version stays in place and it is tried again next run. A file skipped ${data.max_deferrals} runs in a row never settles, and you are notified (the number of runs is FILE_ACTIVE_MAX_DEFERRALS in Admin → Settings).`));
      const stale = data.changing.filter((row) => row.count >= data.max_deferrals).length;
      if (stale) panel.append(h("p", { class: "notice" }, `${stale} file(s) never settle. Decide for each: exclude it (or its folder) in this project or in every project of the job with Exclude… or a right-click on the row, or leave it and stop its writer briefly so it can be backed up.`));
      panel.append(data.changing.length ? h("div", { class: "table-wrap" }, h("table", { class: "changing-table" },
        h("thead", {}, h("tr", {}, h("th", {}, "Project"), h("th", {}, "Path"), h("th", { class: "num" }, "Runs skipped in a row"), h("th", {}, "Last seen"), h("th", {}, h("span", { class: "sr-only" }, "Actions")))),
        h("tbody", {}, data.changing.map((row) => h("tr", { class: row.count >= data.max_deferrals ? "highlight" : "", oncontextmenu: (event) => changingRowMenu(event, data, row) },
          h("td", {}, row.project.split("/").pop()), h("td", {}, h("code", {}, row.path)),
          h("td", { class: "num" }, row.count >= data.max_deferrals ? h("span", {}, String(row.count), " ", pill("never settles", "warn")) : String(row.count)),
          h("td", {}, timeNode(row.updated)),
          h("td", {}, h("button", { type: "button", class: "small-button", "aria-haspopup": "menu", title: "Exclude this file or a parent folder", onclick: (event) => changingRowMenu(event, data, row) }, "Exclude…"))))))) : h("p", { class: "empty" }, "No file of this job is being skipped."));
    },

    excludes: (panel, data) => {
      const entry = data.entry;
      const stopped = data.projects.filter((project) => project.stop_file_present);
      append(panel, [h("h3", {}, "Stop file"), h("p", {}, `${entry.stop_file} in ${entry.isolation === "children" ? "the source skips the whole job; in a child directory it skips that project" : "the source skips this job"}.`),
        entry.stop_file_present ? h("p", { class: "notice" }, `Present in the source: the job is paused.`) : null,
        stopped.length ? h("ul", {}, stopped.map((project) => h("li", {}, h("code", {}, project.source), " is paused"))) : h("p", { class: "muted" }, "No project is paused by a stop file.")]);
      const patternSection = (title, block, explanation) => {
        panel.append(h("h3", {}, title), h("p", { class: "muted" }, explanation));
        if (block.global.length) panel.append(h("details", {}, h("summary", {}, `Global patterns for every project (${block.global.length})`), h("pre", {}, block.global.join("\n"))));
        if (block.truncated) panel.append(h("p", { class: "notice info" }, "The search stopped early; not every file is listed."));
        if (!block.files.length) panel.append(h("p", { class: "muted" }, `No ${block.filename} file in this job's source.`));
        for (const file of block.files) panel.append(h("details", {}, h("summary", {}, h("code", {}, file.relative), ` (${file.lines.length} line(s))`), h("pre", {}, file.lines.join("\n") || "(empty)")));
      };
      const jobExcludes = data.patterns?.excludes || [];
      const projectExcludes = Object.entries(data.project_patterns || {});
      panel.append(h("h3", {}, "Excluded by this job"), h("p", { class: "muted" }, "Kept in Backup Suite's config, not in the projects' folders, and relative to each project's folder. Added from Changing files (Exclude…, or right-click) or in the job editor."));
      const patternList = (patterns, scope, child) => h("ul", { class: "pattern-list" }, patterns.map((pattern) => h("li", {}, h("code", {}, pattern), " ",
        h("button", { type: "button", class: "small-button", onclick: () => removeJobExclude(entry, scope, child, pattern) }, "Remove"))));
      if (jobExcludes.length) panel.append(h("div", {}, h("p", {}, entry.isolation === "children" ? "In every project:" : "In this job:"), patternList(jobExcludes, "job", "")));
      for (const [child, patterns] of projectExcludes) panel.append(h("div", {}, h("p", {}, `In ${child} only:`), patternList(patterns, "project", child)));
      if (!jobExcludes.length && !projectExcludes.length) panel.append(h("p", { class: "muted" }, "None."));
      patternSection("Excluded files", data.excludes, `Patterns in ${data.excludes.filename} files are never uploaded (relative to the folder that holds the file).`);
      patternSection("Volatile files", data.volatile, `Patterns in ${data.volatile.filename} files are allowed to change during a sync: if they change, they are left for the next run instead of failing the project.`);
    },

    runs: (panel, data) => {
      if (!data.runs.length) {
        panel.append(h("p", { class: "empty" }, "No run of this job recorded yet."));
        return;
      }
      panel.append(h("p", { class: "muted" }, "Each backup run of this job, newest first. Click a run for each project's result and the job's part of the log."));
      panel.append(h("div", { class: "table-wrap" }, h("table", {},
        h("thead", {}, h("tr", {}, ["Run", "Result", "Projects", "New / updated / removed", "Kept while changing", "Took"].map((label) => h("th", {}, label)))),
        h("tbody", {}, data.runs.map((run) => h("tr", { class: "clickable", tabindex: "0", onclick: () => openEntryRun(data, run), onkeydown: (event) => { if (event.key === "Enter") openEntryRun(data, run); } },
          h("td", {}, timeNode(run.run)), h("td", {}, resultPill(run.outcome)),
          h("td", {}, `${run.synced} synced${run.skipped ? `, ${run.skipped} skipped` : ""}${run.failed ? `, ${run.failed} failed` : ""}`),
          h("td", { class: "num" }, run.changes_known ? `${run.new} / ${run.updated} / ${run.removed}` : "—"),
          h("td", { class: "num" }, String(run.deferred)),
          h("td", {}, run.started && run.ended ? duration((parseTime(run.ended) - parseTime(run.started)) / 1000) : "—")))))));
    },

    log: async (panel, data) => {
      panel.append(loadingNode());
      try {
        const log = await control("job.log", { name: data.entry.name });
        clear(panel).append(h("p", { class: "muted" }, log.run ? `This job's lines of the run started ${log.run}.` : "No run in the durable log yet."),
          log.truncated ? h("p", { class: "notice info" }, "Only the last 2000 lines are shown.") : null,
          textBlock(log.lines, { fileName: `${data.entry.name.replace(/[^A-Za-z0-9._-]+/g, "_")}-log.txt` }));
      } catch (error) {
        clear(panel).append(errorNode(error));
      }
    },

    storage: (panel, data) => {
      const entry = data.entry;
      const resultHost = { source: h("div", {}), destination: h("div", {}) };
      const measure = async (what) => {
        const host = resultHost[what];
        clear(host).append(loadingNode(what === "source" ? "Counting files in the source (up to 90 s)…" : "Asking the remote for the destination's size (up to 90 s)…"));
        try {
          const result = await control("job.measure", { name: entry.name, what });
          const r = result.result;
          clear(host).append(kv([
            ["Measured", timeNode(result.at)],
            ["Files", r.files === null || r.files === undefined ? "—" : String(r.files)],
            ["Size", bytes(r.bytes)],
            r.directories !== undefined ? ["Folders", String(r.directories)] : null
          ].filter(Boolean)), r.complete ? null : h("p", { class: "notice info" }, "Stopped at the time limit: the numbers are partial."), h("p", { class: "muted" }, r.note));
          if (result.listing?.length) {
            host.append(h("h4", {}, "Top level of the destination"), h("div", { class: "table-wrap" }, h("table", {},
              h("thead", {}, h("tr", {}, h("th", {}, "Name"), h("th", { class: "num" }, "Size"), h("th", {}, "Modified"))),
              h("tbody", {}, result.listing.map((item) => h("tr", {}, h("td", {}, item.dir ? `${item.name}/` : item.name), h("td", { class: "num" }, item.dir ? "—" : bytes(item.size)), h("td", {}, item.modified ? timeNode(item.modified) : "—")))))));
          }
        } catch (error) {
          clear(host).append(errorNode(error));
        }
      };
      panel.append(h("div", { class: "cards" },
        h("section", { class: "card" }, h("h3", {}, "Source on this server"), kv([["Path", h("code", {}, entry.source)], ["Exists", entry.source_exists ? "yes" : pill("no", "bad")]]),
          h("div", { class: "toolbar-row tight" }, h("button", { type: "button", disabled: !entry.source_exists, onclick: () => measure("source") }, "Measure source")), resultHost.source),
        h("section", { class: "card" }, h("h3", {}, "Destination"), kv([["Path", h("code", {}, entry.destination || "—")], ["Previous versions", h("code", {}, entry.archive || "—")], ["Kept for", entry.retention]]),
          h("div", { class: "toolbar-row tight" }, h("button", { type: "button", disabled: !entry.destination, onclick: () => measure("destination") }, "Measure destination")), resultHost.destination)),
        h("p", { class: "muted" }, "Measuring reads the whole tree (the destination through rclone), so it runs only when you press the button."));
    }
  };

  async function openEntryRun(data, run) {
    const title = `${data.entry.name} · run ${run.run}`;
    const table = h("div", { class: "table-wrap" }, h("table", {},
      h("thead", {}, h("tr", {}, ["Project", "Result", "New / updated / removed", "Kept while changing"].map((label) => h("th", {}, label)))),
      h("tbody", {}, run.results.map((item) => h("tr", {}, h("td", {}, item.project.split("/").pop()), h("td", {}, resultPill(item.result)),
        h("td", { class: "num" }, item.new === null || item.new === undefined ? "—" : `${item.new} / ${item.updated} / ${item.removed}`), h("td", { class: "num" }, String(item.deferred)))))));
    showDetails(title, [table, loadingNode("Loading the log…")]);
    try {
      const log = await control("job.log", { name: data.entry.name, run: run.run });
      showDetails(title, [table, h("h3", {}, "This job's lines of the run log"), textBlock(log.lines, { fileName: `${data.entry.name.replace(/[^A-Za-z0-9._-]+/g, "_")}-${run.run.replace(/[^0-9]/g, "")}.log` })]);
    } catch (error) {
      showDetails(title, [table, h("p", { class: "muted" }, `Log: ${errorText(error)}`)]);
    }
  }

  // ------------------------------------------------------------------ folder picker
  //
  // Like agentw-gui's folder picker in New Project: browse folders on this server
  // (fs.browse: only under FILE_JOB_SOURCE_ROOTS) or on a destination
  // (remote.browse), and use one. On a destination a new sub-folder name can be
  // added; the first backup creates it.

  const picker = { kind: "fs", remote: "", path: "", parent: null, resolve: null, data: null };

  function closePicker(value) {
    const dialog = $("#picker-dialog");
    if (dialog.open) dialog.close();
    const resolve = picker.resolve;
    picker.resolve = null;
    if (resolve) resolve(value);
  }

  async function pickerLoad(path, { fallback = false } = {}) {
    const list = clear($("#picker-list"));
    list.append(h("li", { class: "muted" }, "Loading…"));
    try {
      picker.data = picker.kind === "fs"
        ? await control("fs.browse", path ? { path } : {})
        : await control("remote.browse", { remote: picker.remote, path: path || "" });
    } catch (error) {
      // A starting folder that cannot be opened (typed by hand, outside the allowed
      // folders): start at the top instead, and say why.
      if (fallback && path) {
        await pickerLoad("");
        $("#picker-list").prepend(h("li", { class: "muted" }, `${path}: ${errorText(error)}`));
        return;
      }
      clear(list).append(h("li", {}, errorNode(error)));
      return;
    }
    if (picker.data.denied) {
      const denied = `${path}: ${picker.data.denied}`;
      await pickerLoad("");
      $("#picker-list").prepend(h("li", { class: "muted" }, denied));
      return;
    }
    const data = picker.data;
    picker.path = data.path || "";
    $("#picker-current").textContent = picker.kind === "fs" ? (picker.path || "Allowed folders") : `${data.base}${picker.path ? `${data.base.endsWith(":") ? "" : "/"}${picker.path}` : ""}`;
    $("#picker-up").disabled = picker.kind === "fs" ? !picker.path : !picker.path;
    $("#picker-select").disabled = picker.kind === "fs" && !picker.path;
    const showHidden = $("#picker-hidden").checked;
    const folders = picker.kind === "fs"
      ? data.folders.filter((folder) => showHidden || !folder.hidden)
      : data.folders.map((name) => ({ name, path: picker.path ? `${picker.path}/${name}` : name, allowed: true, hidden: name.startsWith(".") })).filter((folder) => showHidden || !folder.hidden);
    clear(list);
    if (picker.kind === "remote" && !data.exists) list.append(h("li", { class: "muted" }, "This folder does not exist yet; the first backup creates it."));
    if (!folders.length && data.exists !== false) list.append(h("li", { class: "muted" }, "No sub-folders."));
    for (const folder of folders) {
      list.append(h("li", {}, h("button", {
        type: "button", class: "picker-item", disabled: !folder.allowed,
        title: folder.allowed ? `Open ${folder.name}` : "Holds system or Backup Suite files: cannot be backed up",
        onclick: () => pickerLoad(folder.path)
      }, "📁 ", folder.name, folder.allowed ? "" : " (not allowed)")));
    }
  }

  function openPicker({ kind, remote = "", start = "", title, eyebrow }) {
    picker.kind = kind;
    picker.remote = remote;
    $("#picker-title").textContent = title || "Choose a folder";
    $("#picker-eyebrow").textContent = eyebrow || (kind === "fs" ? "Folder on this server" : "Folder on the destination");
    $("#picker-new").hidden = kind !== "remote";
    $("#picker-new-name").value = "";
    $("#picker-dialog").showModal();
    pickerLoad(start, { fallback: true });
    return new Promise((resolve) => { picker.resolve = resolve; });
  }

  function bindPicker() {
    $("#picker-close").addEventListener("click", () => closePicker(null));
    $("#picker-cancel").addEventListener("click", () => closePicker(null));
    $("#picker-dialog").addEventListener("cancel", () => closePicker(null));
    $("#picker-hidden").addEventListener("change", () => pickerLoad(picker.path));
    $("#picker-up").addEventListener("click", () => {
      if (picker.kind === "fs") pickerLoad(picker.data?.parent || "");
      else pickerLoad(picker.path.split("/").slice(0, -1).join("/"));
    });
    $("#picker-select").addEventListener("click", () => {
      let value = picker.path;
      const extra = $("#picker-new-name").value.trim().replace(/^\/+|\/+$/g, "");
      if (picker.kind === "remote" && extra) value = value ? `${value}/${extra}` : extra;
      closePicker(value);
    });
  }

  // ------------------------------------------------------------------ destinations

  async function loadRemotes(providers = false) {
    const data = await control("remotes", providers ? { providers: true } : {});
    state.remotes = data;
    return data;
  }

  function remoteChoiceOptions(selected) {
    const data = state.remotes;
    const select = clear($("#job-remote-choice"));
    select.append(h("option", { value: "" }, `Default destination (${data?.default_root || "RCLONE_REMOTE_ROOT"})`));
    for (const remote of (data?.remotes || []).filter((item) => item.allowed)) {
      select.append(h("option", { value: remote.name }, `${remote.name} (${remote.type_label})`));
    }
    select.value = selected || "";
    if (select.value !== (selected || "")) select.value = "";
  }

  function updateDestinationFields() {
    const form = $("#job-form");
    const remote = form.elements.remote_choice.value;
    $("#job-mode-label").hidden = Boolean(remote);
    form.elements.destination_value.disabled = !remote && form.elements.destination_mode.value === "same-name";
    form.elements.destination_value.placeholder = remote ? "e.g. backups/web10" : "e.g. sites/web10";
  }

  renderers.destinations = async (body) => {
    body.append(loadingNode());
    let data;
    try {
      data = await loadRemotes(true);
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    clear(body);
    body.append(h("p", { class: "muted" }, "Where backups can go: Google Drive, Dropbox, OneDrive, S3 and others, kept as rclone remotes. Set one up here, then choose it in a job's Destination. Tokens and passwords are stored by rclone on the server and are never shown."),
      h("div", { class: "toolbar-row tight" }, h("button", { type: "button", class: "primary-button", onclick: () => openRemoteWizard(data.providers) }, "+ New destination")));
    const cards = h("div", { class: "cards" });
    for (const remote of data.remotes) {
      const result = h("div", {});
      const settings = Object.entries(remote.settings).slice(0, 12);
      cards.append(h("section", { class: `card ${remote.allowed ? "" : "is-disabled"}` },
        h("div", { class: "channel-head" }, h("h3", {}, remote.name), pill(remote.type_label || remote.type, remote.allowed ? "info" : "")),
        kv([
          ["Used by", remote.used_by.length ? remote.used_by.join(", ") : "nothing yet"],
          ...settings.map(([key, value]) => [key, h("code", {}, value)])
        ]),
        remote.allowed ? null : h("p", { class: "muted" }, "Set up on the server with a type the GUI does not manage; jobs cannot choose it here."),
        h("div", { class: "toolbar-row tight" },
          h("button", { type: "button", onclick: async () => {
            clear(result).append(loadingNode("Testing (up to 45 s)…"));
            try {
              const test = await control("remote.test", { name: remote.name });
              clear(result).append(test.ok
                ? h("p", { class: "notice ok" }, `Reachable (${test.seconds}s).`, test.about?.free !== undefined ? ` Free: ${bytes(test.about.free)}${test.about.total ? ` of ${bytes(test.about.total)}` : ""}.` : "")
                : h("p", { class: "notice bad" }, test.error));
            } catch (error) {
              clear(result).append(errorNode(error));
            }
          } }, "Test"),
          remote.allowed ? h("button", { type: "button", onclick: () => openPicker({ kind: "remote", remote: remote.name, title: `Folders on ${remote.name}` }) }, "Browse…") : null,
          h("button", { type: "button", class: "danger-button", disabled: remote.used_by.length > 0, title: remote.used_by.length ? `Used by ${remote.used_by.join(", ")}` : "", onclick: async () => {
            if (!(await confirmAction({ title: `Remove destination ${remote.name}?`, lines: ["Removes it from rclone.conf (a backup copy is kept and the change is audited).", "Nothing stored on it is deleted."], okLabel: "Remove", danger: true }))) return;
            try {
              await control("remote.delete", { name: remote.name });
              toast(`Destination ${remote.name} removed.`, "warn");
              renderAdmin();
            } catch (error) {
              toast(errorText(error), "error", 10000);
            }
          } }, "Remove…")),
        result));
    }
    if (!data.remotes.length) cards.append(h("p", { class: "empty" }, "No destinations yet."));
    body.append(cards);
  };

  // The setup wizard: the type and its main options, then rclone's own questions
  // one at a time (for Google Drive, Dropbox, OneDrive and Box: one sign-in on a
  // computer with a browser).

  const wizard = { name: "", state: "", providers: null, onDone: null };

  // s3 has sub-providers (AWS, Wasabi, MinIO, …); some options apply to some only.
  function providerMatches(option, provider) {
    if (!option.provider) return true;
    const negated = option.provider.startsWith("!");
    const names = option.provider.replace(/^!/, "").split(",").map((item) => item.trim());
    if (!provider) return negated;
    return negated ? !names.includes(provider) : names.includes(provider);
  }

  function optionInput(option, providerValue) {
    const examples = option.examples.filter((example) => !example.provider || providerMatches({ provider: example.provider }, providerValue));
    if (option.type === "bool") {
      return h("select", { name: option.name }, ["", "true", "false"].map((value) => h("option", { value, selected: value === "" }, value === "" ? `default (${option.default || "false"})` : value === "true" ? "Yes" : "No")));
    }
    if (examples.length && option.exclusive) {
      return h("select", { name: option.name }, h("option", { value: "" }, option.required ? "Choose…" : `default${option.default ? ` (${option.default})` : ""}`),
        examples.map((example) => h("option", { value: example.value }, `${example.value}${example.help ? ` — ${example.help.split("\n")[0]}` : ""}`)));
    }
    const input = h("input", { name: option.name, type: option.password ? "password" : "text", autocomplete: option.password ? "new-password" : "off", spellcheck: "false", placeholder: option.default || "" });
    if (examples.length) {
      const listId = `opt-${option.name}-list`;
      input.setAttribute("list", listId);
      return h("span", {}, input, h("datalist", { id: listId }, examples.map((example) => h("option", { value: example.value }, example.help.split("\n")[0]))));
    }
    return input;
  }

  function renderWizardStart(error) {
    const body = clear($("#remote-body"));
    const providers = wizard.providers || {};
    const types = Object.entries(providers).sort((a, b) => a[1].label.localeCompare(b[1].label));
    const nameInput = h("input", { type: "text", name: "name", spellcheck: "false", autocomplete: "off", placeholder: "e.g. gdrive or dropbox", maxlength: "32" });
    const typeSelect = h("select", { name: "type" }, h("option", { value: "" }, "Choose a service…"), types.map(([type, info]) => h("option", { value: type }, info.label)));
    const optionsHost = h("div", { class: "threshold-grid" });
    const drawOptions = (chosen = "") => {
      clear(optionsHost);
      const info = providers[typeSelect.value];
      if (!info) return;
      for (const option of info.options.filter((item) => item.name === "provider" || providerMatches(item, chosen))) {
        const help = option.help.split("\n");
        optionsHost.append(h("div", { class: "setting-row" },
          h("label", {}, h("code", {}, option.name), option.required ? " (required)" : ""),
          optionInput(option, chosen),
          h("div", { class: "meta" }, help[0]),
          help.length > 1 ? h("details", { class: "meta" }, h("summary", {}, "More"), h("pre", {}, help.slice(1).join("\n"))) : null));
      }
      const providerSelect = optionsHost.querySelector('[name="provider"]');
      if (providerSelect) {
        providerSelect.value = chosen;
        providerSelect.addEventListener("change", () => drawOptions(providerSelect.value));
      }
    };
    typeSelect.addEventListener("change", () => drawOptions(""));
    body.append(
      error ? h("div", { class: "notice bad", role: "alert" }, error) : null,
      h("div", { class: "threshold-grid" },
        h("label", {}, "Name (used in jobs, e.g. gdrive)", nameInput),
        h("label", {}, "Service", typeSelect)),
      h("p", { class: "muted" }, "Only what the service needs is asked. Leave a field empty to use rclone's default. Google Drive, Dropbox, OneDrive and Box then ask you to sign in once."),
      optionsHost,
      h("div", { class: "toolbar-row end" },
        h("button", { type: "button", onclick: () => $("#remote-dialog").close() }, "Cancel"),
        h("button", { type: "button", class: "primary-button", onclick: async (event) => {
          const options = {};
          for (const input of optionsHost.querySelectorAll("[name]")) if (input.value.trim()) options[input.name] = input.value.trim();
          event.target.disabled = true;
          try {
            wizard.name = nameInput.value.trim();
            handleWizardReply(await control("remote.create", { name: wizard.name, type: typeSelect.value, options }));
          } catch (error) {
            renderWizardStart(errorText(error));
          }
        } }, "Continue")));
  }

  function handleWizardReply(reply) {
    if (reply.done) {
      $("#remote-dialog").close();
      toast(reply.error ? `Destination ${reply.name} saved, with a warning: ${reply.error}` : `Destination ${reply.name} is ready.`, reply.error ? "warn" : "info", 10000);
      if (adminOpen() && state.adminTab === "destinations") renderAdmin();
      if (wizard.onDone) wizard.onDone(reply.name);
      return;
    }
    wizard.state = reply.state;
    renderWizardQuestion(reply.question, reply.error);
  }

  function renderWizardQuestion(question, error) {
    const body = clear($("#remote-body"));
    const authorize = (question.help.match(/rclone authorize "[^"]+"(?: "[^"]+")?/) || [])[0];
    let input;
    if (authorize) {
      input = h("textarea", { rows: "5", spellcheck: "false", placeholder: "Paste the result here ({\"access_token\": …})" });
    } else if (question.type === "bool") {
      input = h("select", {}, h("option", { value: "true", selected: question.default === "true" }, "Yes"), h("option", { value: "false", selected: question.default !== "true" }, "No"));
    } else if (question.examples.length && question.exclusive) {
      input = h("select", {}, question.examples.map((example) => h("option", { value: example.value, selected: example.value === question.default }, `${example.value}${example.help ? ` — ${example.help.split("\n")[0]}` : ""}`)));
    } else {
      input = h("input", { type: question.password ? "password" : "text", value: question.default || "", spellcheck: "false", autocomplete: "off" });
    }
    // Headless sign-in: "Use auto config?" is always answered No (the server has no browser).
    if (question.name === "config_is_local") {
      submitWizard("false");
      return;
    }
    body.append(error ? h("div", { class: "notice bad", role: "alert" }, error) : null,
      h("p", { class: "eyebrow" }, `Setting up ${wizard.name}`));
    if (authorize) {
      body.append(h("h3", {}, "Sign in"),
        h("ol", { class: "connect-steps" },
          h("li", {}, "On your own computer (it has a browser), install rclone if it is not there: ", h("a", { href: "https://rclone.org/downloads/", target: "_blank", rel: "noopener noreferrer" }, "rclone.org/downloads"), ". Windows: unzip it, no installer needed."),
          h("li", {}, "In a terminal there, run this command. A browser opens; sign in and allow access:", h("div", { class: "copy-row" }, h("code", {}, authorize), h("button", { type: "button", onclick: () => copyText(authorize) }, "Copy"))),
          h("li", {}, "rclone prints a result between two lines of dashes. Copy all of it and paste it below.")),
        input);
    } else {
      body.append(h("h3", {}, question.name.replace(/^config_/, "").replace(/_/g, " ")), h("pre", { class: "wizard-help" }, question.help.trim()), input);
    }
    body.append(h("div", { class: "toolbar-row end" },
      h("button", { type: "button", onclick: () => $("#remote-dialog").close() }, "Stop here"),
      h("button", { type: "button", class: "primary-button", onclick: () => submitWizard(input.value.trim()) }, "Continue")));
    input.focus();
  }

  async function submitWizard(result) {
    clear($("#remote-body")).append(loadingNode("Asking rclone…"));
    try {
      handleWizardReply(await control("remote.continue", { name: wizard.name, state: wizard.state, result }));
    } catch (error) {
      clear($("#remote-body")).append(errorNode(error), h("div", { class: "toolbar-row end" }, h("button", { type: "button", onclick: () => $("#remote-dialog").close() }, "Close")));
    }
  }

  async function openRemoteWizard(providers, onDone = null) {
    wizard.onDone = onDone;
    wizard.name = "";
    wizard.state = "";
    if (!providers) {
      try {
        providers = (await loadRemotes(true)).providers;
      } catch (error) {
        toast(errorText(error), "error");
        return;
      }
    }
    wizard.providers = providers;
    $("#remote-title").textContent = "New destination";
    renderWizardStart();
    $("#remote-dialog").showModal();
  }

  // ------------------------------------------------------------------ job changes
  //
  // New job, Edit, Enable/Disable, Remove and Back up now. Every change is checked
  // by the server (job.check as you type, again on save), confirmed, and refused if
  // file-sources.conf changed since the page read it.

  const jobEditor = { name: null, sha: "", timer: null, check: null, token: 0 };

  function patternsText(list) {
    return (list || []).join("\n");
  }

  function readJobForm() {
    const form = $("#job-form");
    const lines = (name) => form.elements[name].value.split("\n").map((line) => line.trim()).filter(Boolean);
    return {
      enabled: form.elements.enabled.checked,
      label: form.elements.label.value.trim(),
      source: form.elements.source.value.trim(),
      destination_mode: form.elements.remote_choice.value ? "remote" : form.elements.destination_mode.value,
      destination_value: form.elements.remote_choice.value
        ? `${form.elements.remote_choice.value}:${form.elements.destination_value.value.trim().replace(/^\/+|\/+$/g, "")}`
        : form.elements.destination_value.value.trim(),
      stop_file: form.elements.stop_file.value.trim(),
      isolation: form.querySelector('input[name="isolation"]:checked')?.value || "single",
      excludes: lines("excludes"),
      volatile: lines("volatile")
    };
  }

  function renderJobCheck(result) {
    const host = clear($("#job-check"));
    const info = result.info || {};
    host.append(h("h3", {}, "Check"),
      kv([
        ["Destination", info.destination ? h("code", {}, info.destination) : "—"],
        ["Projects", info.projects === null || info.projects === undefined ? "—" : String(info.projects)],
        ["Line written", h("code", {}, info.line || "—")]
      ]));
    if (result.problems.length) host.append(h("div", { class: "notice bad", role: "alert" }, h("strong", {}, "Cannot be saved yet"), h("ul", {}, result.problems.map((line) => h("li", {}, line)))));
    if (result.warnings.length) host.append(h("div", { class: "notice" }, h("strong", {}, "Note"), h("ul", {}, result.warnings.map((line) => h("li", {}, line)))));
    if (!result.problems.length && !result.warnings.length) host.append(h("p", { class: "notice ok" }, "Looks good."));
    $("#job-save-button").disabled = result.problems.length > 0;
    $("#job-roots-note").textContent = info.roots?.length ? `Allowed under: ${info.roots.join(", ")} (FILE_JOB_SOURCE_ROOTS, set on the server). System folders and Backup Suite's own folders are never allowed.` : "";
  }

  function scheduleJobCheck() {
    clearTimeout(jobEditor.timer);
    jobEditor.timer = setTimeout(async () => {
      const token = ++jobEditor.token;
      const job = readJobForm();
      updateDestinationFields();
      try {
        const args = { job };
        if (jobEditor.name) args.name = jobEditor.name;
        const result = await control("job.check", args);
        if (token !== jobEditor.token) return;
        jobEditor.check = result;
        renderJobCheck(result);
      } catch (error) {
        if (token !== jobEditor.token) return;
        clear($("#job-check")).append(entriesErrorNode(error));
      }
    }, 350);
  }

  async function openJobEditor(name = null) {
    const form = $("#job-form");
    form.reset();
    jobEditor.name = name;
    jobEditor.check = null;
    $("#job-dialog-title").textContent = name ? `Edit job ${name}` : "New backup job";
    clear($("#job-check")).append(loadingNode("Checking…"));
    try {
      await loadRemotes();
    } catch {
      state.remotes = null;
    }
    let job = { enabled: true, label: "", source: "", destination_mode: "fixed", destination_value: "", stop_file: "", isolation: "single", excludes: [], volatile: [] };
    try {
      if (name) {
        const data = await control("job", { name });
        state.entryCache[name] = data;
        const entry = data.entry;
        jobEditor.sha = data.sha256;
        job = { enabled: entry.enabled, label: entry.label || entry.name, source: entry.source, destination_mode: entry.destination_mode,
          destination_value: entry.destination_value, stop_file: entry.stop_file_configured ?? "",
          isolation: entry.isolation, excludes: data.patterns?.excludes || [], volatile: data.patterns?.volatile || [] };
      } else {
        const jobs = await control("jobs");
        state.entriesData = jobs;
        jobEditor.sha = jobs.sha256;
      }
    } catch (error) {
      toast(errorText(error), "error");
      return;
    }
    form.elements.label.value = job.label;
    form.elements.enabled.checked = job.enabled;
    form.elements.source.value = job.source;
    if (job.destination_mode === "remote") {
      const [remoteName, ...folder] = job.destination_value.split(":");
      remoteChoiceOptions(remoteName);
      form.elements.destination_mode.value = "fixed";
      form.elements.destination_value.value = folder.join(":").replace(/^\/+/, "");
    } else {
      remoteChoiceOptions("");
      form.elements.destination_mode.value = job.destination_mode;
      form.elements.destination_value.value = job.destination_value;
    }
    updateDestinationFields();
    form.elements.stop_file.value = job.stop_file;
    for (const radio of form.querySelectorAll('input[name="isolation"]')) radio.checked = radio.value === job.isolation;
    form.elements.excludes.value = patternsText(job.excludes);
    form.elements.volatile.value = patternsText(job.volatile);
    $("#job-dialog").showModal();
    form.elements.label.focus();
    scheduleJobCheck();
  }

  async function saveJobFromEditor() {
    const job = readJobForm();
    let check;
    try {
      check = await control("job.check", jobEditor.name ? { name: jobEditor.name, job } : { job });
    } catch (error) {
      toast(errorText(error), "error");
      return;
    }
    renderJobCheck(check);
    if (check.problems.length) return;
    const before = jobEditor.name ? state.entryCache[jobEditor.name]?.entry : null;
    const lines = [jobEditor.name ? `Changes job ${jobEditor.name} in file-sources.conf (a backup copy is kept and the change is audited):` : "Adds this line to file-sources.conf (a backup copy is kept and the change is audited):",
      h("pre", {}, check.info.line),
      `Destination: ${check.info.destination || "—"}`];
    if (before && before.destination && before.destination !== check.info.destination) {
      lines.push(h("p", { class: "notice" }, `The destination changes from ${before.destination}: the next run uploads everything again to the new place. The old copy stays where it is.`));
    }
    if (before && before.name !== job.label) lines.push(`Renamed from ${before.name}; its history stays under the old name.`);
    if (check.warnings.length) lines.push(check.warnings);
    $("#job-dialog").close();
    if (!(await confirmAction({ title: jobEditor.name ? "Save the job?" : "Add the job?", lines, okLabel: jobEditor.name ? "Save job" : "Add job" }))) {
      $("#job-dialog").showModal();
      return;
    }
    try {
      const args = { job, expect_sha: jobEditor.sha };
      if (jobEditor.name) args.name = jobEditor.name;
      const result = await control("job.save", args);
      toast(`Job ${result.name} ${result.action}. It is backed up from the next run on.`);
      if (jobEditor.name) delete state.entryCache[jobEditor.name];
      await loadEntries({ quiet: true });
      openEntry(result.name);
    } catch (error) {
      if (error.code === "config_conflict") toast("file-sources.conf changed on the server since the form opened. Open the editor again.", "warn", 10000);
      else toast(`Not saved: ${errorText(error)}`, "error", 12000);
    }
  }

  async function jobRunNow(entry) {
    if (!(await confirmAction({
      title: `Back up ${entry.name} now?`,
      lines: ["Starts a file backup of this job only, with the current resource profile and the watchdog.",
        ["Other jobs are not touched; the next scheduled run backs up every job as usual.", "A scheduled run that comes due meanwhile is skipped (one backup at a time).", "You do not have to keep the GUI open."]],
      okLabel: "Back up now"
    }))) return;
    try {
      await control("job.run", { name: entry.name });
      toast(`Backing up ${entry.name}…`);
    } catch (error) {
      toast(`Not started: ${errorText(error)}`, "error", 10000);
    }
  }

  async function jobSetEnabled(entry, sha, enabled) {
    if (!(await confirmAction({
      title: enabled ? `Enable ${entry.name}?` : `Disable ${entry.name}?`,
      lines: enabled ? ["Scheduled runs back this job up again from the next run."] : ["Scheduled runs skip this job until it is enabled again.", "Nothing is deleted: its remote copy and history stay."],
      okLabel: enabled ? "Enable" : "Disable", danger: !enabled
    }))) return;
    try {
      await control("job.enable", { name: entry.name, enabled, expect_sha: sha });
      toast(`${entry.name} ${enabled ? "enabled" : "disabled"}.`);
      delete state.entryCache[entry.name];
      await loadEntries({ quiet: true });
      renderMain();
    } catch (error) {
      toast(error.code === "config_conflict" ? "file-sources.conf changed on the server; reload and try again." : `Failed: ${errorText(error)}`, "error", 10000);
    }
  }

  async function jobRemove(entry, sha) {
    if (!(await confirmAction({
      title: `Remove job ${entry.name}?`,
      lines: ["Removes its line from file-sources.conf and its own patterns (backup copies are kept and the change is audited).",
        ["Nothing on the remote is deleted: the last copy stays at " + (entry.destination || "its destination") + ", and previous versions stay in the archive until they expire.", "Its history stays in the GUI under the same name.", "To pause it instead, use Disable."]],
      okLabel: "Remove job", danger: true
    }))) return;
    try {
      await control("job.remove", { name: entry.name, expect_sha: sha });
      toast(`Job ${entry.name} removed.`, "warn");
      delete state.entryCache[entry.name];
      await loadEntries({ quiet: true });
      goHome();
    } catch (error) {
      toast(error.code === "config_conflict" ? "file-sources.conf changed on the server; reload and try again." : `Failed: ${errorText(error)}`, "error", 10000);
    }
  }

  function jobActionBar(data) {
    const entry = data.entry;
    const running = ["running", "paused"].includes(fileBackupState(state.status).key);
    return h("div", { class: "toolbar-row tight job-actions" },
      h("button", { type: "button", class: "primary-button", dataset: { key: "job-run" }, disabled: !entry.enabled || Boolean(entry.problem) || running,
        title: running ? "A backup is running; try again when it has finished." : !entry.enabled ? "Enable the job first." : "", onclick: () => jobRunNow(entry) }, "Back up now"),
      h("button", { type: "button", dataset: { key: "job-edit" }, onclick: () => openJobEditor(entry.name) }, "Edit…"),
      h("button", { type: "button", dataset: { key: "job-toggle" }, onclick: () => jobSetEnabled(entry, data.sha256, !entry.enabled) }, entry.enabled ? "Disable…" : "Enable…"),
      h("button", { type: "button", class: "danger-button", dataset: { key: "job-remove" }, onclick: () => jobRemove(entry, data.sha256) }, "Remove…"));
  }

  // Admin: every global setting ---------------------------------------------------

  renderers.settings = async (body) => {
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
    const form = h("div", { class: "form-host" });
    const filter = h("input", { type: "search", placeholder: "Find a setting (name or text)", "aria-label": "Find a setting" });
    for (const group of config.groups) {
      const fields = group.keys.map((key) => byKey[key]).filter(Boolean).map((entry) => entry.editable ? settingField(entry) : readonlySetting(entry));
      if (!fields.length) continue;
      const fieldset = h("fieldset", { class: "settings-option-group", dataset: { group: group.id } }, h("legend", {}, group.label));
      if (group.id === "schedule") fieldset.append(h("p", { class: "settings-help" }, "Applied to the timers as soon as you save. Calendar examples: *:0/30 (every 30 minutes), hourly, daily, *-*-* 02:00, Mon..Fri 22:00."));
      if (group.id === "remote") fieldset.append(h("p", { class: "notice" }, "Changing the remote root, the hostname folder or the default destination moves where every job is backed up: the next run uploads everything again there. Nothing is moved or deleted."));
      if (group.id === "profile") fieldset.append(h("div", { class: "toolbar-row tight" }, h("button", { type: "button", onclick: () => openAdmin("profiles") }, "Open Profiles & limits")));
      fieldset.append(h("div", { class: "threshold-grid" }, fields));
      form.append(fieldset);
    }
    filter.addEventListener("input", () => {
      const term = filter.value.trim().toLowerCase();
      for (const row of form.querySelectorAll(".setting-row")) row.hidden = Boolean(term) && !row.textContent.toLowerCase().includes(term);
      for (const fieldset of form.querySelectorAll("fieldset")) fieldset.hidden = ![...fieldset.querySelectorAll(".setting-row")].some((row) => !row.hidden);
    });
    const errors = h("div", { class: "field-error", role: "alert" });
    body.append(h("p", { class: "muted" }, "Every key of Backup Suite's global.conf. Each save is checked by the server, confirmed, backed up and audited. Programs and paths that run as root, and install options, are shown but changed on the server only."),
      h("div", { class: "search-row" }, filter), form, errors,
      h("div", { class: "toolbar-row end sticky-save" }, h("button", { type: "button", class: "primary-button", onclick: async () => {
        const changes = collectChanges(form);
        const problems = validateWatchdog(changes, config);
        errors.textContent = problems.join(" ");
        if (problems.length) return;
        const relocating = Object.keys(changes).filter((key) => byKey[key]?.relocates);
        const schedule = Object.keys(changes).filter((key) => byKey[key]?.schedule);
        const note = [schedule.length ? "The schedule is applied to the timers at once." : "", relocating.length ? `${relocating.join(", ")} moves every job's destination: the next run uploads everything again there.` : "", "Everything else applies from the next backup run."].filter(Boolean).join(" ");
        if (await saveConfig(changes, config, { title: relocating.length ? "Save, and move every job's destination?" : "Save these settings?", note })) renderAdmin();
      } }, "Save settings…")));
  };

  function readonlySetting(entry) {
    const value = entry.kind === "secret" ? (entry.is_set ? "set (never shown)" : "not set") : entry.value || `(not set; default ${entry.default || "empty"})`;
    return h("div", { class: "setting-row readonly" },
      h("span", { class: "setting-key" }, h("code", {}, entry.key), " ", pill("read-only", "")),
      h("code", { class: "readonly-value" }, value),
      entry.explanation ? h("div", { class: "meta" }, entry.explanation) : null,
      h("div", { class: "meta" }, entry.readonly_reason));
  }

  // ------------------------------------------------------------------ main view

  let mainToken = 0;
  async function renderMain() {
    const token = ++mainToken;
    const body = $("#section-body");
    const fresh = h("div", {});
    if (state.view.kind === "entry") {
      $("#section-title").textContent = state.view.name;
      $("#section-help").dataset.help = "entry";
      clear(body).append(fresh);
      await renderEntry(fresh, state.view.name, state.view.tab);
      return;
    }
    $("#section-title").textContent = "Home";
    $("#section-help").dataset.help = "home";
    const focusedKey = document.activeElement?.dataset?.key;
    renderHome(fresh);
    if (token !== mainToken) return;
    clear(body).append(fresh);
    if (focusedKey) body.querySelector(`[data-key="${CSS.escape(focusedKey)}"]`)?.focus();
  }

  // ------------------------------------------------------------------ admin

  const ADMIN_TABS = {
    actions: "Actions & schedule",
    destinations: "Destinations",
    runs: "Runs & failures",
    profiles: "Profiles & limits",
    watchdog: "Watchdog",
    notifications: "Notifications",
    settings: "All settings",
    sources: "Sources file",
    logs: "Logs",
    activity: "Activity & audit"
  };

  function adminOpen() {
    return $("#admin-dialog").open;
  }

  function openAdmin(tab = state.adminTab || "actions") {
    state.adminTab = ADMIN_TABS[tab] ? tab : "actions";
    const dialog = $("#admin-dialog");
    const tabs = clear($("#admin-tabs"));
    for (const [key, label] of Object.entries(ADMIN_TABS)) {
      tabs.append(h("button", { type: "button", role: "tab", "aria-selected": String(key === state.adminTab), onclick: () => openAdmin(key) }, label));
    }
    $("#admin-help").dataset.help = state.adminTab;
    if (!dialog.open) dialog.showModal();
    const hash = `#admin/${state.adminTab}`;
    if (location.hash !== hash) history.replaceState(null, "", hash);
    renderAdmin();
  }

  function closeAdmin() {
    const dialog = $("#admin-dialog");
    if (dialog.open) dialog.close();
  }

  let adminToken = 0;
  async function renderAdmin() {
    const token = ++adminToken;
    const body = $("#admin-body");
    const fresh = h("div", {});
    const result = renderers[state.adminTab](fresh);
    if (result && typeof result.then === "function") {
      clear(body).append(fresh);
      await result;
      return;
    }
    if (token !== adminToken) return;
    clear(body).append(fresh);
  }

  // Re-renders whatever shows server data after a change.
  function renderSection() {
    if (adminOpen()) renderAdmin();
    renderMain();
  }

  // ------------------------------------------------------------------ resource warning
  //
  // Like agentw-gui's resource warning: a small card that pops up when the server or
  // the backup runs short, once per condition until it clears.

  const shownWarnings = new Set();
  function checkResourceWarning(status) {
    if (!status) return;
    const watchdog = status.watchdog || {};
    const server = status.server || {};
    const available = numberOrNull(server.available_percent);
    const pausePercent = numberOrNull(watchdog.threshold_server_pause_percent) ?? 10;
    const backup = fileBackupState(status);
    const warnings = [];
    if (backup.key === "paused") warnings.push({ key: "paused", severity: "critical", text: "The watchdog paused the backup because the server is short of memory.", meta: `Server RAM available ${available ?? "?"}%` });
    if (available !== null && available < pausePercent + 5) warnings.push({ key: "low-ram", severity: available < pausePercent ? "critical" : "warning", text: `Server RAM available is ${available}% (${bytes(server.available_bytes)}).`, meta: `The watchdog pauses the backup below ${pausePercent}%.` });
    if (backup.contained) warnings.push({ key: "contained", severity: "warning", text: "The backup is near its memory limit; the watchdog is containing it.", meta: `${bytes(watchdog.memory_bytes)} of ${bytes(watchdog.memory_max_bytes)}` });
    if (watchdog.server_pressure === "host-stall" && watchdog.server_pressure_note) warnings.push({ key: "host-stall", severity: "warning", text: `Memory stall from ${watchdog.server_pressure_note}.`, meta: "Not caused by the backup; the backup keeps running." });
    const active = new Set(warnings.map((warning) => warning.key));
    for (const key of [...shownWarnings]) if (!active.has(key)) shownWarnings.delete(key);
    const fresh = warnings.find((warning) => !shownWarnings.has(warning.key));
    if (!fresh) return;
    shownWarnings.add(fresh.key);
    const card = $("#resource-warning");
    card.className = `resource-warning severity-${fresh.severity}`;
    $("#resource-warning-title").textContent = fresh.severity === "critical" ? "Resource warning: critical" : "Resource warning";
    $("#resource-warning-text").textContent = fresh.text;
    $("#resource-warning-meta").textContent = fresh.meta || "";
    card.hidden = false;
    clearTimeout(checkResourceWarning.timer);
    checkResourceWarning.timer = setTimeout(() => { card.hidden = true; }, 18000);
  }

  // ------------------------------------------------------------------ bell
  //
  // Notifications are generic: one message per event, delivered through every
  // enabled channel (ntfy now; Telegram, WhatsApp, email and SMS later). The bell
  // lists them all, each with what every channel did; channels are set up in
  // Admin → Notifications.

  const CHANNEL_LABELS = { ntfy: "ntfy", telegram: "Telegram", whatsapp: "WhatsApp", email: "Email", sms: "SMS" };
  const DELIVERY_LABELS = { sent: ["sent", "ok"], failed: ["failed", "bad"], off: ["channel off", "warn"] };

  // Events written before channels existed carry "ntfy": "<result>".
  function eventDelivery(event) {
    if (event.delivery && typeof event.delivery === "object") return { channels: event.delivery, held: Boolean(event.held) };
    if (event.ntfy === "held") return { channels: {}, held: true };
    if (event.ntfy) return { channels: { ntfy: event.ntfy }, held: false };
    return { channels: {}, held: false };
  }

  function sentEvents() {
    return state.events.filter((event) => Object.keys(eventDelivery(event).channels).length || eventDelivery(event).held);
  }

  function deliveryPills(event) {
    const delivery = eventDelivery(event);
    if (delivery.held) return [pill("not sent again: already reported", "")];
    const pills = Object.entries(delivery.channels).map(([channel, result]) => {
      const [word, kind] = DELIVERY_LABELS[result] || [result, ""];
      return pill(`${CHANNEL_LABELS[channel] || channel}: ${word}`, kind);
    });
    return pills.length ? pills : [pill("GUI only", "")];
  }

  function eventItem(event, isNew) {
    const date = parseTime(event.created_at);
    return h("li", { class: `event-item severity-${event.severity} ${isNew ? "is-new" : ""}` },
      h("header", {}, h("span", { class: "event-pills" }, pill(event.severity, event.severity === "error" ? "bad" : event.severity === "warning" ? "warn" : "info"), " ", event.category, " ", deliveryPills(event)),
        timeNode(date ? date.toISOString() : event.created_at)),
      h("strong", {}, event.title),
      event.message || event.delivery_note ? h("details", {}, h("summary", {}, "Details"),
        event.message ? h("p", { class: "event-message" }, event.message) : null,
        event.delivery_note ? h("p", { class: "muted" }, `Delivery: ${event.delivery_note}`) : null) : null);
  }

  async function openBell() {
    const panel = $("#bell-panel");
    const body = clear($("#bell-body"));
    panel.hidden = false;
    $("#bell-button").setAttribute("aria-expanded", "true");
    body.append(loadingNode());
    try {
      const list = await api("/api/events?limit=500");
      state.events = list.events;
    } catch (error) {
      clear(body).append(errorNode(error));
      return;
    }
    const previousSeen = state.seenSeq;
    const events = state.events;
    append(clear(body), [
      h("p", { class: "muted" }, "Every notification, newest first. Each shows what every channel did with it; routine events such as a normal run finishing are shown here only."),
      events.length ? h("ul", { class: "event-list" }, events.slice().reverse().slice(0, 200).map((event) => eventItem(event, event.seq > previousSeen))) : h("p", { class: "empty" }, "Nothing yet."),
      h("div", { class: "toolbar-row tight" },
        h("button", { type: "button", onclick: () => { closeBell(); openAdmin("notifications"); } }, "Channels…"),
        h("button", { type: "button", onclick: () => { closeBell(); openAdmin("activity"); } }, "Activity & audit…"))
    ]);
    markEventsSeen();
    $("#bell-close").focus();
  }

  function closeBell() {
    $("#bell-panel").hidden = true;
    $("#bell-button").setAttribute("aria-expanded", "false");
  }

  function markEventsSeen() {
    const latest = state.events.reduce((max, event) => Math.max(max, event.seq), state.seenSeq);
    state.seenSeq = latest;
    storageSet(SEEN_KEY, String(latest));
    updateChrome();
  }

  // ------------------------------------------------------------------ routing
  //
  // #home, #entry/<name>[/<tab>], #admin/<tab>, #bell. Older links (#overview,
  // #runs, #activity, ...) open the matching Admin tab.

  function route() {
    const hash = decodeURIComponent(location.hash.slice(1));
    const [kind, ...rest] = hash.split("/");
    if ((kind === "job" || kind === "entry") && rest.length) {
      let tab = "overview";
      const last = rest[rest.length - 1];
      if (rest.length > 1 && ENTRY_TABS.some(([key]) => key === last)) {
        tab = last;
        rest.pop();
      }
      const name = rest.join("/");
      if (state.view.kind !== "entry" || state.view.name !== name) $("#layout").classList.add("details-closed");
      state.view = { kind: "entry", name, tab };
    } else {
      state.view = { kind: "home" };
      if (kind === "admin") openAdmin(rest[0] === "server" ? "settings" : rest[0]);
      else if (ADMIN_TABS[kind]) openAdmin(kind);
      else if (kind === "bell") openBell();
    }
    if (window.matchMedia("(max-width: 960px)").matches) showPanel("main");
    renderEntryList();
    renderMain();
  }

  // Called on every live status: re-render what shows it, and refresh the entries
  // when the run moved to another project or ended.
  function onStatusChanged(previous) {
    checkResourceWarning(state.status);
    if (state.status) updateBackendNotice(state.status);
    const before = previous?.progress || {};
    const now = state.status?.progress || {};
    const moved = before.current_project !== now.current_project || before.state !== now.state;
    if (moved || Date.now() - (state.entriesLoadedAt || 0) > 60000) loadEntries({ quiet: true });
    if (state.view.kind === "home") renderMain();
    if (adminOpen() && state.adminTab === "actions") renderAdmin();
  }

  // ------------------------------------------------------------------ live stream

  // An EventSource that reconnects is not a lost connection: Tunnel Manager's app
  // window ends the stream after every message and the page reconnects at once (the
  // server replays what it missed). The banner shows only after the stream has stayed
  // down for STREAM_LOST_AFTER_MS.
  const STREAM_LOST_AFTER_MS = 30000;
  let stream = null;
  let streamLostTimer = null;
  function connectStream() {
    if (stream) stream.close();
    stream = new EventSource("/api/stream");
    stream.addEventListener("open", () => {
      clearTimeout(streamLostTimer);
      streamLostTimer = null;
      state.connected = true;
      $("#connection-banner").hidden = true;
    });
    stream.addEventListener("error", () => {
      if (streamLostTimer) return;
      streamLostTimer = setTimeout(() => {
        streamLostTimer = null;
        if (stream && stream.readyState === EventSource.OPEN) return;
        state.connected = false;
        $("#connection-banner").hidden = false;
        // A stream the browser gave up on (CLOSED) is opened again; the browser
        // retries a CONNECTING one itself.
        if (stream && stream.readyState === EventSource.CLOSED) connectStream();
      }, STREAM_LOST_AFTER_MS);
    });
    stream.addEventListener("hello", (message) => {
      const data = JSON.parse(message.data);
      markUpdateAvailable(data.build);
      state.chart = data.chart || [];
      if (data.status) state.status = data.status;
      state.statusError = data.error;
      updateChrome();
      onStatusChanged(null);
    });
    stream.addEventListener("status", (message) => {
      const data = JSON.parse(message.data);
      const previous = state.status;
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
      onStatusChanged(previous);
    });
    stream.addEventListener("status-error", (message) => {
      state.statusError = JSON.parse(message.data);
      updateChrome();
      if (state.view.kind === "home" && !state.status) renderMain();
    });
    stream.addEventListener("events", (message) => {
      const data = JSON.parse(message.data);
      state.tunnelManagerActive = Boolean(data.tunnel_manager_active);
      for (const event of data.events || []) {
        if (!state.events.some((known) => known.seq === event.seq)) state.events.push(event);
        browserNotify(event);
      }
      updateChrome();
      if (adminOpen() && state.adminTab === "activity") renderAdmin();
      if (!$("#bell-panel").hidden) openBell();
    });
  }

  // Like agentw-gui: when the server serves a newer GUI than this page loaded (it was
  // reinstalled), the reload button turns red; one page reload gets the new one.
  function markUpdateAvailable(build) {
    if (!build || !state.session?.build || build === state.session.build) return;
    const button = $("#reload-button");
    if (button.classList.contains("update-available")) return;
    button.classList.add("update-available");
    button.title = "A new version of this GUI is installed: reload the page to use it";
    button.setAttribute("aria-label", button.title);
    toast("A new version of the GUI is installed. Press the red reload button.", "warn", 12000);
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
        openBell();
      });
    } catch {
      // Notifications can be blocked by the browser; the bell still lists the event.
    }
  }

  async function refreshHistory() {
    try {
      state.history = await control("history", { limit: 500 });
      if (state.view.kind === "home") renderMain();
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

  // "Ways to connect", as in agentw-gui: four tabs made from /api/connect on every
  // opening, so the profile, the scripts and the steps match the current settings.
  // Each tab can be copied as plain text to share.
  const CONNECT_TABS = [["tunnel-manager", "Tunnel Manager"], ["scripts", "Launcher scripts"], ["mobile", "Phone or tablet"], ["manual", "Manual"]];
  let connectTab = "tunnel-manager";

  function connectCopyRow(label, value) {
    return h("div", { class: "copy-row" }, label ? h("span", { class: "copy-label" }, label) : null, h("code", {}, value),
      h("button", { type: "button", onclick: () => copyText(value) }, "Copy"));
  }

  function connectSignIn(info) {
    return `Sign in as ${info.ssh_target} with your usual SSH key or password.`;
  }

  const CONNECT_BUILDERS = {
    "tunnel-manager": (info) => {
      const tm = info.tunnel_manager;
      const backendInput = h("input", { type: "text", value: info.backend_id, spellcheck: "false", "aria-describedby": "backend-hint", autocomplete: "off", "aria-label": "Tunnel Manager backend (user@host)" });
      const steps = [
        `Install Tunnel Manager (Windows, macOS, Linux): ${tm.download_url}`,
        `Download the profile ${tm.file_name} and, in your Tunnel Manager profile for ${info.backend_id}, choose Import.`,
        "Select the imported tunnel backup-suite-gui, then Start. Tunnel Manager starts the GUI on the server if it is stopped, checks it, and opens the app window.",
        connectSignIn(info)
      ];
      const view = [
        h("ol", { class: "connect-steps" },
          h("li", {}, "Install Tunnel Manager (Windows, macOS, Linux): ", h("a", { href: tm.download_url, target: "_blank", rel: "noopener noreferrer" }, "releases page"), "."),
          h("li", {}, "Download the profile and choose Import in Tunnel Manager.",
            h("div", { class: "toolbar-row tight" },
              h("a", { href: tm.url, download: tm.file_name, class: "button-link primary-button" }, `Download ${tm.file_name}`),
              h("button", { type: "button", onclick: () => copyText(tm.toml) }, "Copy profile"))),
          h("li", {}, steps[2]),
          h("li", {}, steps[3])),
        h("label", {}, "Tunnel Manager backend (user@host)", h("div", { class: "copy-row" }, backendInput,
          h("button", { type: "button", onclick: async () => {
            try {
              renderConnect(await api("/api/connect/backend", { method: "POST", body: { backend_id: backendInput.value.trim() } }));
              toast("Backend saved; the profile and every launcher use it.");
            } catch (error) {
              toast(errorText(error), "error");
            }
          } }, "Save"))),
        h("p", { class: "settings-help", id: "backend-hint" }, info.backend_hint_text),
        h("details", {}, h("summary", {}, `What the profile contains (${tm.file_name})`), h("pre", {}, tm.toml)),
        h("p", { class: "muted" }, `On the server the same profile is printed by: ${info.cli.bundle}`)
      ];
      const text = ["Connect with Tunnel Manager", ...steps.map((step, index) => `${index + 1}. ${step}`), "", `--- ${tm.file_name} ---`, tm.toml.trimEnd()].join("\n");
      return { view, text };
    },
    scripts: (info) => {
      const view = [
        h("p", {}, "One small script per computer: it opens the SSH tunnel (no shell), waits until the GUI answers, opens it in your browser and reconnects if the connection drops."),
        h("ul", { class: "connect-scripts" }, info.scripts.map((script) => h("li", {},
          h("a", { href: script.url, download: script.file_name, class: "button-link" }, `Download for ${script.label}`),
          h("span", { class: "muted" }, ` ${script.file_name}: ${script.how_to}`)))),
        h("p", { class: "muted" }, connectSignIn(info)),
        connectCopyRow("Then open", info.address),
        h("p", { class: "muted" }, `On the server, ${info.cli.status} lists the same scripts, saved in ${info.cli.launcher_dir}.`)
      ];
      const text = ["Connect with a launcher script", "Run the script for your computer. It forwards the GUI over SSH and opens it in your browser.",
        ...info.scripts.map((script) => `- ${script.label}: ${script.file_name}. ${script.how_to}`), connectSignIn(info), `The GUI opens at ${info.address}`].join("\n");
      return { view, text };
    },
    mobile: (info) => {
      const m = info.mobile;
      const view = [
        h("h3", {}, m.android.title),
        h("ol", { class: "connect-steps" }, h("li", {}, "Open Termux and run:", connectCopyRow("", "pkg install openssh")), h("li", {}, "Run:", connectCopyRow("", info.manual.ssh)),
          m.android.after.map((line) => h("li", {}, line))),
        h("h3", {}, m.ios.title),
        h("ol", { class: "connect-steps" }, h("li", {}, "In Blink, run:", connectCopyRow("", info.manual.ssh)), m.ios.after.map((line) => h("li", {}, line))),
        h("p", { class: "muted" }, m.ios.note),
        h("h3", {}, "On any phone"),
        h("ul", {}, m.general.map((line) => h("li", {}, line)))
      ];
      const text = ["Connect from a phone or tablet", "", m.android.title, "1. Open Termux and run: pkg install openssh", `2. Run: ${info.manual.ssh}`,
        ...m.android.after.map((line, index) => `${index + 3}. ${line}`), "", m.ios.title, `1. In Blink, run: ${info.manual.ssh}`,
        ...m.ios.after.map((line, index) => `${index + 2}. ${line}`), m.ios.note, "", "On any phone:", ...m.general.map((line) => `- ${line}`)].join("\n");
      return { view, text };
    },
    manual: (info) => {
      const view = [
        h("ol", { class: "connect-steps" },
          h("li", {}, "In a terminal (Windows PowerShell, macOS or Linux), run:", connectCopyRow("", info.manual.ssh),
            h("span", { class: "muted" }, "It stays open with no prompt while connected; keep it open while you work.")),
          h("li", {}, "Open this address in your browser:", connectCopyRow("", info.manual.address))),
        h("p", { class: "muted" }, connectSignIn(info)),
        h("p", { class: "muted" }, `Another local port works too: change ${info.local_port} in both places. The tunnel forwards to ${info.socket ? "the GUI's private socket" : "127.0.0.1 (tcp mode)"} ${info.remote}.`),
        info.socket ? h("p", { class: "muted" }, info.tcp_note) : null
      ];
      const text = ["Connect by hand (any computer with OpenSSH: Windows 10/11, macOS, Linux)", "1. In a terminal, run:", `   ${info.manual.ssh}`,
        "   It stays open with no prompt while connected; keep it open while you work.", "2. Open this address in your browser:", `   ${info.manual.address}`,
        connectSignIn(info), `Another local port works too: change ${info.local_port} in both places.`].join("\n");
      return { view, text };
    }
  };

  function renderConnect(info) {
    const body = clear($("#connect-body"));
    const tabBar = h("div", { class: "settings-tabs", role: "tablist", "aria-label": "Ways to connect" });
    const panel = h("div", { class: "connect-panel", role: "tabpanel" });
    const show = (name) => {
      connectTab = CONNECT_BUILDERS[name] ? name : "tunnel-manager";
      for (const button of tabBar.children) button.setAttribute("aria-selected", String(button.dataset.tab === connectTab));
      const built = CONNECT_BUILDERS[connectTab](info);
      clear(panel).append(...built.view.filter(Boolean),
        h("div", { class: "toolbar-row tight" }, h("button", { type: "button", title: "Copy these instructions as text, to share them", onclick: () => copyText(CONNECT_BUILDERS[connectTab](info).text) }, "Copy this tab")));
    };
    for (const [name, label] of CONNECT_TABS) tabBar.append(h("button", { type: "button", role: "tab", dataset: { tab: name }, onclick: () => show(name) }, label));
    body.append(h("p", { class: "muted" }, `For ${info.ssh_target}: the GUI on the server (${info.remote}) opens at ${info.address} on your device.`), tabBar, panel);
    show(connectTab);
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
    $("#admin-button").addEventListener("click", () => openAdmin());
    $("#admin-close").addEventListener("click", closeAdmin);
    $("#admin-details-close").addEventListener("click", () => { $("#admin-details").hidden = true; });
    $("#admin-dialog").addEventListener("close", () => {
      $("#admin-details").hidden = true;
      if (location.hash.startsWith("#admin")) history.replaceState(null, "", state.view.kind === "entry" ? entryHash(state.view.name, state.view.tab) : "#home");
    });
    $("#home-button").addEventListener("click", goHome);
    $("#new-job-button").addEventListener("click", () => openJobEditor(null));
    bindPicker();
    $("#remote-close").addEventListener("click", () => $("#remote-dialog").close());
    $("#job-browse-source").addEventListener("click", async () => {
      const form = $("#job-form");
      const chosen = await openPicker({ kind: "fs", start: form.elements.source.value.trim(), title: "Source folder" });
      if (chosen) {
        form.elements.source.value = chosen;
        if (!form.elements.label.value.trim()) form.elements.label.value = chosen.split("/").filter(Boolean).pop().replace(/[^A-Za-z0-9._-]+/g, "-").slice(0, 64);
        scheduleJobCheck();
      }
    });
    $("#job-browse-destination").addEventListener("click", async () => {
      const form = $("#job-form");
      const remote = form.elements.remote_choice.value;
      const chosen = await openPicker({ kind: "remote", remote, start: form.elements.destination_value.value.trim().replace(/^\/+|\/+$/g, ""), title: remote ? `Folder on ${remote}` : "Folder on the default destination" });
      if (chosen !== null) {
        form.elements.destination_value.value = chosen;
        if (!remote) form.elements.destination_mode.value = "fixed";
        scheduleJobCheck();
      }
    });
    $("#job-manage-destinations").addEventListener("click", () => {
      openRemoteWizard(null, async (name) => {
        await loadRemotes();
        remoteChoiceOptions(name);
        updateDestinationFields();
        scheduleJobCheck();
      });
    });
    $("#job-form").addEventListener("input", scheduleJobCheck);
    $("#job-form").addEventListener("change", scheduleJobCheck);
    $("#job-form").addEventListener("submit", (event) => {
      if (event.submitter?.value !== "save") return;
      event.preventDefault();
      saveJobFromEditor();
    });
    $("#entry-filter").addEventListener("change", () => {
      storageSet("backup-suite-gui-entry-filter", $("#entry-filter").value);
      renderEntryList();
    });
    $("#resource-warning-close").addEventListener("click", () => { $("#resource-warning").hidden = true; });
    $("#resource-warning-open").addEventListener("click", () => {
      $("#resource-warning").hidden = true;
      openAdmin("watchdog");
    });
    document.addEventListener("keydown", (event) => {
      if (event.key !== "Escape") return;
      if (!$("#help-panel").hidden) $("#help-panel").hidden = true;
      if (!$("#bell-panel").hidden) closeBell();
    });
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
    window.addEventListener("hashchange", route);
    window.addEventListener("popstate", route);
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
    const savedFilter = storageGet("backup-suite-gui-entry-filter");
    if (savedFilter) $("#entry-filter").value = savedFilter;
    route();
    connectStream();
    loadEntries({ quiet: true });
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
      if (state.view.kind === "home") renderMain();
    } catch {
      // Each section loads what it needs on its own.
    }
    if ("serviceWorker" in navigator) navigator.serviceWorker.register("/sw.js").catch(() => {});
  }

  init();
})();
