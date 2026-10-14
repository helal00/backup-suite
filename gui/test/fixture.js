"use strict";

// A throwaway user-mode Backup Suite installation for the GUI tests: the real control
// script from this repository, a config under a temporary XDG_CONFIG_HOME, and the
// shell test suite's fake systemctl/journalctl/curl on PATH.

const fs = require("fs");
const os = require("os");
const path = require("path");

const REPO = path.resolve(__dirname, "..", "..");

function makeFixture() {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "backup-suite-gui-test-"));
  const xdgConfig = path.join(root, "xdg-config");
  const configDir = path.join(xdgConfig, "backup-suite");
  const stateDir = path.join(root, "state");
  const binDir = path.join(root, "bin");
  const sourceDir = path.join(root, "source");
  for (const dir of [configDir, stateDir, binDir, path.join(sourceDir, "project-a"), path.join(stateDir, "logs"), path.join(stateDir, "watchdog")]) {
    fs.mkdirSync(dir, { recursive: true });
  }
  fs.writeFileSync(path.join(configDir, "global.conf"), [
    'INSTALL_MODE="user"',
    `USER_INSTALL_DIR="${REPO}"`,
    `USER_CONFIG_DIR="${configDir}"`,
    `USER_STATE_DIR="${stateDir}"`,
    `USER_RCLONE_CONFIG_PATH="${configDir}/rclone.conf"`,
    'USER_RCLONE_BIN="rclone"',
    `USER_FILE_SOURCE_CONFIG_PATH="${configDir}/file-sources.conf"`,
    'RCLONE_REMOTE_ROOT="fake:"',
    'FILE_BACKUP_PROFILE="moderate"',
    'FILE_BACKUP_PROFILE_MODE="adaptive"',
    'FILE_BACKUP_PROFILE_FLOOR="slow"',
    'NOTIFY_FAILURES_ENABLED="0"',
    'NOTIFY_NTFY_TOKEN="tk_fixture_secret"',
    ""
  ].join("\n"));
  fs.writeFileSync(path.join(configDir, "file-sources.conf"), `1|workspace|${sourceDir}|fixed|projects/workspace|.nosync|children\n`);
  fs.writeFileSync(path.join(configDir, "rclone.conf"), "token = rclone-fixture-secret\n");
  for (const [name, target] of [["systemctl", "fake-systemctl.sh"], ["journalctl", "fake-journalctl.sh"], ["curl", "fake-curl.sh"]]) {
    fs.symlinkSync(path.join(REPO, "tests", "fixtures", target), path.join(binDir, name));
  }
  const env = {
    ...process.env,
    HOME: path.join(root, "home"),
    XDG_CONFIG_HOME: xdgConfig,
    XDG_STATE_HOME: path.join(root, "xdg-state"),
    XDG_RUNTIME_DIR: path.join(root, "runtime"),
    PATH: `${binDir}:${process.env.PATH}`,
    FAKE_SYSTEMCTL_LOG: path.join(root, "systemctl.log"),
    FAKE_JOURNALCTL_LOG: path.join(root, "journalctl.log"),
    FAKE_CURL_LOG: path.join(root, "curl.log"),
    BACKUP_SUITE_CONTROL_SCRIPT: path.join(REPO, "bin", "backup-control.sh"),
    BACKUP_SUITE_CONTROL_SOCKET: path.join(root, "no-broker.sock"),
    BACKUP_SUITE_GUI_CONFIG_DIR: path.join(root, "gui-config"),
    BACKUP_SUITE_GUI_STATE_DIR: path.join(root, "gui-state")
  };
  fs.mkdirSync(env.HOME, { recursive: true });
  delete env.BACKUP_SUITE_CONFIG_DIR;
  delete env.INVOCATION_ID;
  return { root, env, configDir, stateDir, cleanup: () => fs.rmSync(root, { recursive: true, force: true }) };
}

function appendEvent(stateDir, event) {
  fs.appendFileSync(path.join(stateDir, "events.jsonl"), `${JSON.stringify(event)}\n`);
}

module.exports = { REPO, appendEvent, makeFixture };
