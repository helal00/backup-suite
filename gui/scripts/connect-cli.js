"use strict";

// Connection details for backup-suite-gui-server, made by the same code as the GUI's
// "Ways to connect" dialog, so the terminal and the GUI always agree.
//
//   node connect-cli.js <app-dir> bundle [user@host]
//   node connect-cli.js <app-dir> status <launcher-dir> [user@host]
//   node connect-cli.js <app-dir> save-backend <user@host>

const fs = require("fs");
const path = require("path");

const [appDir, command, ...rest] = process.argv.slice(2);
const settingsStore = require(path.join(appDir, "lib", "settings"));
const listenConfig = require(path.join(appDir, "lib", "listen-config"));
const bundle = require(path.join(appDir, "lib", "bundle"));
const UNIT = `backup-suite-gui-${listenConfig.INSTANCE}.service`;

function loadSettings(backend) {
  const settings = settingsStore.load();
  if (!backend) return settings;
  const merged = settingsStore.merge(settings, { tunnel: { backendId: backend } });
  if (merged.tunnel.backendId !== backend) {
    console.error("backup-suite-gui-server: use the form login@host, as your Tunnel Manager profile shows it.");
    process.exit(64);
  }
  return merged;
}

function profileFor(settings) {
  return bundle.profile(settings, listenConfig.resolveListen({ settings }), UNIT);
}

function writeFileAtomic(file, body, mode) {
  const temporary = `${file}.tmp-${process.pid}`;
  fs.writeFileSync(temporary, body, { mode });
  fs.chmodSync(temporary, mode);
  fs.renameSync(temporary, file);
}

if (command === "bundle") {
  process.stdout.write(bundle.tunnelManagerToml(profileFor(loadSettings(rest[0]))));
} else if (command === "status") {
  const [launcherDir, backend] = rest;
  const settings = loadSettings(backend);
  const p = profileFor(settings);
  const saved = {};
  try {
    fs.mkdirSync(launcherDir, { recursive: true, mode: 0o700 });
    for (const kind of ["toml", ...Object.keys(bundle.PLATFORMS)]) {
      const file = bundle.connectFile(kind, p);
      const target = path.join(launcherDir, file.fileName);
      writeFileAtomic(target, file.body, /\.sh$/.test(file.fileName) ? 0o700 : 0o600);
      saved[kind] = target;
    }
  } catch (error) {
    console.error(`Could not save the launchers in ${launcherDir}: ${error.message}`);
  }
  process.stdout.write(bundle.connectText(bundle.connectInstructions(p, settings), saved));
} else if (command === "save-backend") {
  const settings = loadSettings(rest[0]);
  settingsStore.save(settings);
  console.log(`Saved the backend ${settings.tunnel.backendId}. Restart the GUI (backup-suite-gui-server restart) so open pages show it.`);
} else {
  console.error("usage: connect-cli.js <app-dir> bundle|status|save-backend ...");
  process.exit(64);
}
