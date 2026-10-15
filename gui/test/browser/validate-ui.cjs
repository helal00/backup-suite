"use strict";

// Browser validation (V18, V19 visual part): runs the real server on a fixture
// installation, opens every section at phone and desktop width in light and dark,
// and fails on console errors or horizontal page scroll. Screenshots go to
// $SCREENSHOT_DIR (default: a temporary directory, printed at the end).
//
// Needs Playwright and Chromium, like agentw-gui's browser validations:
//   PLAYWRIGHT_MODULE=~/.cache/ms-playwright-go/1.57.0/package \
//   CHROMIUM_PATH=~/.cache/ms-playwright/chromium_headless_shell-1200/chrome-headless-shell-linux64/chrome-headless-shell \
//   node gui/test/browser/validate-ui.cjs

const fs = require("fs");
const http = require("http");
const os = require("os");
const path = require("path");

const { makeFixture, appendEvent } = require("../fixture");

const playwrightModule = process.env.PLAYWRIGHT_MODULE || path.join(os.homedir(), ".cache/ms-playwright-go/1.57.0/package");
const chromiumPath = process.env.CHROMIUM_PATH || path.join(os.homedir(), ".cache/ms-playwright/chromium_headless_shell-1200/chrome-headless-shell-linux64/chrome-headless-shell");
const { chromium } = require(playwrightModule);

const SECTIONS = ["overview", "runs", "projects", "profiles", "watchdog", "notifications", "sources", "activity"];

function seed(fixture) {
  const { stateDir } = fixture;
  const now = new Date();
  const iso = (offsetSeconds) => new Date(now.getTime() + offsetSeconds * 1000).toISOString().replace(/\.\d+Z$/, "Z");
  const logLines = ["File backup started at 2026-10-14 10:00:00 UTC", "Resource profile: moderate (mode adaptive; levels moderate>slow)"];
  for (const name of ["alpha", "beta", "gamma"]) {
    logLines.push(`Syncing label='workspace/${name}' source='/srv/projects/${name}' destination='fake:projects/workspace/${name}'`);
    if (name === "beta") logLines.push("Deferring 2 path(s) modified within the last 120s in 'workspace/beta'; their previous remote versions stay in place until they settle.");
    logLines.push(name === "gamma" ? "File sync failed for '/srv/projects/gamma'; remote deletions remain protected." : `File sync completed for '/srv/projects/${name}'`);
  }
  logLines.push("2026/10/14 10:30:00 ERROR : gamma/file.json: Failed to copy: googleapi: Error 403: Rate Limit Exceeded");
  logLines.push("Run summary: outcome=completed-with-errors profile=moderate synced=2 skipped=0 skipped_changed=0 deferred_active=2 failed=1");
  fs.writeFileSync(path.join(stateDir, "logs", "backup-file.log"), `${logLines.join("\n")}\n`);
  fs.writeFileSync(path.join(stateDir, "watchdog", "history.tsv"), [
    "started\tended\tunit\tprofile\tduration_s\tpeak_mem\tpeak_anon\tpeak_swap\tavg_cpu_pct\tpeak_cpu_pct\tpeak_tasks\tio_read\tio_write\tevents\toutcome",
    `2026-10-13T10:00:00Z\t2026-10-13T11:40:00Z\tfile-backup.service\tmoderate\t6000\t113246208\t52428800\t0\t2\t48\t22\t1048576000\t20971520\tnone\tcompleted`,
    `2026-10-14T10:00:00Z\t2026-10-14T10:31:00Z\tfile-backup.service\tslow\t1860\t268435456\t201326592\t10485760\t3\t25\t18\t524288000\t10485760\tcontained,step-down\tcompleted`
  ].join("\n") + "\n");
  fs.writeFileSync(path.join(stateDir, "watchdog", "file-backup.service.status"), [
    `updated_at=${iso(0)}`, "unit=file-backup.service", "profile=moderate", "profile_mode=adaptive", "profile_levels=moderate>slow", "state=contained",
    "memory_bytes=880803840", "memory_anon_bytes=402653184", "memory_max_bytes=1073741824", "swap_bytes=20971520", "swap_max_bytes=268435456",
    "cpu_percent=31", "cpu_quota_percent=50", "tasks=21", "tasks_max=64", "io_read_bytes=104857600", "io_write_bytes=5242880",
    "server_available_percent=41", "server_psi_full_avg10=0.5", "peak_memory_bytes=901775360", "peak_anon_bytes=402653184", "peak_swap_bytes=20971520",
    "peak_cpu_percent=49", "peak_tasks=23", "events=contained", "memory_high_bytes=536870912", "threshold_contain_percent=80", "threshold_release_percent=60",
    "threshold_kill_percent=90", "threshold_swap_contain_percent=80", "threshold_swap_kill_percent=95", "threshold_server_pause_percent=10",
    "threshold_server_critical_percent=4", "threshold_psi_full=20"
  ].join("\n") + "\n");
  fs.mkdirSync(path.join(stateDir, "run"), { recursive: true });
  fs.writeFileSync(path.join(stateDir, "run", "progress.env"), [
    "state=running", "outcome=", "started_at=2026-10-14 10:00:00 UTC", `updated_at=${iso(0)}`, "pid=1", "projects_total=12", "project_index=5",
    "current_project=workspace/epsilon", "profile=moderate", "synced=3", "skipped=0", "skipped_changed=0", "deferred_active=2", "failed=1"
  ].join("\n") + "\n");
  fs.mkdirSync(path.join(stateDir, "active-files"), { recursive: true });
  fs.writeFileSync(path.join(stateDir, "active-files", "workspace_beta.tsv"), "14\tdata/cache.db\n2\tlogs/app.log\n");
  fs.mkdirSync(path.join(stateDir, "failures"), { recursive: true });
  fs.writeFileSync(path.join(stateDir, "failures", "20261014T103100Z-file-backup.service.log"), "file-backup.service failed on black\n\nWhat happened (most likely):\n- Google Drive's API rate limit was exceeded.\n");
  let seq = 0;
  for (const [severity, category, title] of [["info", "run-finished", "File backup finished: completed-successfully"], ["warning", "profile-step", "backup stepped down from moderate to slow"], ["error", "watchdog-stop", "backup stopped before OOM"]]) {
    seq += 1;
    appendEvent(stateDir, { seq, id: `evt-${seq}-1`, created_at: iso(-600 + seq * 60), severity, category, title, message: `${title}. Details for the test.`, unit: "file-backup.service" });
  }
}

async function main() {
  const fixture = makeFixture();
  seed(fixture);
  const screenshotDir = process.env.SCREENSHOT_DIR || fs.mkdtempSync(path.join(os.tmpdir(), "bsg-screens-"));
  fs.mkdirSync(screenshotDir, { recursive: true });
  // A running backup, so the gauges and the running state render.
  fixture.env.FAKE_SYSTEMCTL_ACTIVE_UNIT = "file-backup.service";
  const { createApp } = require("../../server");
  const app = createApp({ env: fixture.env });
  const server = http.createServer(app.handle);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const browser = await chromium.launch({ executablePath: chromiumPath });
  const failures = [];
  try {
    for (const [label, viewport] of [["phone", { width: 390, height: 844 }], ["desktop", { width: 1366, height: 900 }]]) {
      for (const scheme of ["light", "dark"]) {
        const context = await browser.newContext({ viewport, colorScheme: scheme });
        const page = await context.newPage();
        const errors = [];
        page.on("console", (message) => { if (message.type() === "error") errors.push(message.text()); });
        page.on("pageerror", (error) => errors.push(error.message));
        for (const section of SECTIONS) {
          await page.goto(`${base}/#${section}`);
          await page.waitForSelector("#section-body > div");
          await page.waitForTimeout(section === "overview" ? 2500 : 1500);
          if (section === "overview") {
            const chip = await page.textContent("#state-chip");
            if (!/Running 5\/12/.test(chip)) failures.push(`${label}/${scheme}: state chip shows "${chip}"`);
          }
          const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
          if (overflow > 1) failures.push(`${label}/${scheme}/${section}: horizontal page scroll of ${overflow}px`);
          const bodyText = await page.textContent("#section-body");
          if (/\[object Object\]|undefined|NaN/.test(bodyText)) failures.push(`${label}/${scheme}/${section}: suspicious text in section`);
          await page.screenshot({ path: path.join(screenshotDir, `${label}-${scheme}-${section}.png`), fullPage: label === "desktop" });
        }
        // Dialogs.
        await page.goto(`${base}/#overview`);
        await page.waitForTimeout(800);
        await page.click("#settings-button");
        await page.screenshot({ path: path.join(screenshotDir, `${label}-${scheme}-settings.png`) });
        await page.keyboard.press("Escape");
        await page.click("#connect-button");
        await page.waitForSelector('#connect-body [role="tab"][aria-selected="true"]');
        for (const tab of ["scripts", "mobile", "manual", "tunnel-manager"]) {
          await page.click(`#connect-body [data-tab="${tab}"]`);
          await page.waitForSelector(`#connect-body [data-tab="${tab}"][aria-selected="true"]`);
        }
        await page.screenshot({ path: path.join(screenshotDir, `${label}-${scheme}-connect.png`) });
        await page.keyboard.press("Escape");
        await page.click("#bell-button");
        await page.waitForSelector(".event-list");
        await page.screenshot({ path: path.join(screenshotDir, `${label}-${scheme}-bell.png`) });
        if (errors.length) failures.push(`${label}/${scheme}: console errors: ${errors.join(" | ")}`);
        await context.close();
      }
    }
  } finally {
    await browser.close();
    server.close();
    fixture.cleanup();
  }
  console.log(`Screenshots: ${screenshotDir}`);
  if (failures.length) {
    console.log(failures.join("\n"));
    process.exit(1);
  }
  console.log("UI validation passed.");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
