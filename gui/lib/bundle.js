"use strict";

// Ways to connect: the Tunnel Manager import bundle, the launcher scripts (adapted
// from agentw-gui's launcher-templates.js) and the manual ssh line. Everything is
// generated per request from the current listener and settings; nothing here holds a
// credential.

const os = require("os");

const APP_ID = "backup-suite-gui";
const APP_NAME = "Backup Suite GUI";
const TUNNEL_NAME = "backup-suite-gui";
const TUNNEL_MANAGER_DOWNLOAD_URL = "https://github.com/itechmate-uk/ssh-tunnel-manager-dists/releases";

function tomlString(value) {
  return JSON.stringify(String(value ?? ""));
}

function primaryIPv4() {
  const interfaces = os.networkInterfaces();
  for (const name of Object.keys(interfaces).sort()) {
    for (const address of interfaces[name] || []) {
      if (address.family === "IPv4" && !address.internal) return address.address;
    }
  }
  return os.hostname();
}

function loginName() {
  try {
    return os.userInfo().username;
  } catch {
    return process.env.USER || "user";
  }
}

// The Tunnel Manager backend ("user@host"). It must match the user's Tunnel Manager
// profile for this server exactly, so it is editable and saved.
function backendId(settings) {
  if (settings.tunnel.backendId) return settings.tunnel.backendId;
  return `${loginName()}@${settings.tunnel.sshHost || primaryIPv4()}`;
}

function profile(settings, listen, unitName) {
  const backend = backendId(settings);
  return {
    backendId: backend,
    sshTarget: backend,
    remoteSocket: listen.socket && listen.forwardable ? listen.socketPath : "",
    remotePort: listen.port,
    localPort: settings.tunnel.localPort,
    unit: unitName
  };
}

function forwardTarget(p) {
  return p.remoteSocket || `127.0.0.1:${p.remotePort}`;
}

function tunnelManagerToml(p) {
  const lines = [
    `# Tunnel Manager profile for ${APP_NAME} (${p.sshTarget}). Import it with Tunnel Manager's Import.`,
    "# Made by the GUI from its current settings; download it again after they change.",
    'format = "tunnel-manager-tunnel"',
    "version = 1",
    `backend_id = ${tomlString(p.backendId)}`,
    "",
    "[tunnel]",
    `name = ${tomlString(TUNNEL_NAME)}`
  ];
  if (p.remoteSocket) {
    lines.push("# The GUI's private Unix socket on the server.", `remote_socket = ${tomlString(p.remoteSocket)}`);
  } else {
    lines.push('remote_host = "127.0.0.1"', `remote_port = ${Number(p.remotePort)}`);
  }
  const port = Number(p.localPort);
  lines.push("",
    "[tunnel.local]", 'bind_host = "127.0.0.1"', 'mode = "preferred"', `preferred_port = ${port}`, `port_min = ${port}`, `port_max = ${port + 100}`,
    'on_conflict = "prompt"', "reuse_if_health_matches = true", "",
    "[tunnel.health]", 'type = "http"', 'url = "http://127.0.0.1:{local_port}/api/health"', `expect_app_id = ${tomlString(APP_ID)}`, 'timeout = "10s"', "",
    "[tunnel.launch]", 'type = "browser"', 'relaunch = "manual"', "",
    "[tunnel.launch.browser]", 'url = "http://127.0.0.1:{local_port}/"', 'mode = "webview"', 'browser = "auto"', "",
    "[tunnel.events]", "enabled = true", 'url = "http://127.0.0.1:{local_port}/api/events"', 'poll_interval = "5s"', "",
    "[tunnel.notifications]", 'mode = "enabled"', 'minimum_severity = "warning"', "suppress_browser_duplicates = true", "include_detailed_app_messages = true", "",
    "[tunnel.remote_service]", "enabled = true", 'provider = "systemd-user"', `unit = ${tomlString(p.unit)}`, 'policy = "start-if-stopped"',
    'monitor_interval = "30s"', 'command_timeout = "15s"', 'start_timeout = "60s"', "restart_limit = 3", 'restart_window = "10m"', "stop_on_tunnel_stop = false");
  return `${lines.join("\n")}\n`;
}

function windowsLauncher({ sshTarget, localPort, remotePort, remoteSocket = "" }) {
  return `@echo off
setlocal EnableDelayedExpansion
rem ${APP_NAME} tunnel. Forwards a local port to the GUI's private Unix socket on the server.
rem Run with --tcp to forward to the GUI's TCP port instead (only when the GUI listens in tcp or both mode).
set "START_PORT=${localPort}"
set "REMOTE_PORT=${remotePort}"
set "REMOTE_SOCKET=${remoteSocket}"
set "SSH_TARGET=${sshTarget}"
set "LOCAL_PORT=%START_PORT%"
if "%~1"=="--tunnel-loop" (
  set "LOCAL_PORT=%~2"
  set "REMOTE_TARGET=%~3"
  set "SSH_TARGET=%~4"
  set "URL=http://127.0.0.1:%LOCAL_PORT%/"
  call :connect_loop
  exit /b 0
)
set "REMOTE_TARGET=%REMOTE_SOCKET%"
if "%~1"=="--tcp" set "REMOTE_TARGET="
if "%REMOTE_TARGET%"=="" set "REMOTE_TARGET=127.0.0.1:%REMOTE_PORT%"
call :port_listening %LOCAL_PORT%
if "%ERRORLEVEL%"=="0" (
  call :health_check %LOCAL_PORT%
  if "!ERRORLEVEL!"=="0" (
    set "URL=http://127.0.0.1:%LOCAL_PORT%/"
    echo Reusing existing ${APP_NAME} tunnel at %URL%
    call :open_browser
    exit /b 0
  )
  echo Port %LOCAL_PORT% is already used by another application.
  choice /C UC /N /M "Use another available port (U) or Cancel (C)? "
  if errorlevel 2 exit /b 1
  call :find_available_port
)
set "URL=http://127.0.0.1:%LOCAL_PORT%/"
echo Starting ${APP_NAME} tunnel to %SSH_TARGET% (%REMOTE_TARGET%)...
echo Local URL will be http://127.0.0.1:%LOCAL_PORT%/
start "${APP_NAME} tunnel %LOCAL_PORT%" cmd /k ""%~f0" --tunnel-loop "%LOCAL_PORT%" "%REMOTE_TARGET%" "%SSH_TARGET%""
call :wait_for_health
if not "%ERRORLEVEL%"=="0" (
  echo Tunnel started, but the health check did not confirm ${APP_NAME} yet.
  echo Try opening %URL% after a moment.
)
call :open_browser
exit /b 0

:port_listening
netstat -ano | findstr /R /C:":%1 .*LISTENING" >nul
exit /b %ERRORLEVEL%

:health_check
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:%1/api/health' -TimeoutSec 2; if ($r.app -eq '${APP_ID}') { exit 0 } exit 2 } catch { exit 1 }" >nul 2>nul
exit /b %ERRORLEVEL%

:find_available_port
set /a LOCAL_PORT+=1
call :port_listening %LOCAL_PORT%
if "%ERRORLEVEL%"=="0" goto find_available_port
exit /b 0

:wait_for_health
for /L %%i in (1,1,30) do (
  call :health_check %LOCAL_PORT%
  if "!ERRORLEVEL!"=="0" exit /b 0
  timeout /t 1 /nobreak >nul
)
exit /b 1

:open_browser
set "BROWSER_EXE="
where chrome.exe >nul 2>nul && set "BROWSER_EXE=chrome.exe"
if not defined BROWSER_EXE where msedge.exe >nul 2>nul && set "BROWSER_EXE=msedge.exe"
if not defined BROWSER_EXE if exist "%ProgramFiles%\\Google\\Chrome\\Application\\chrome.exe" set "BROWSER_EXE=%ProgramFiles%\\Google\\Chrome\\Application\\chrome.exe"
if not defined BROWSER_EXE if exist "%ProgramFiles(x86)%\\Microsoft\\Edge\\Application\\msedge.exe" set "BROWSER_EXE=%ProgramFiles(x86)%\\Microsoft\\Edge\\Application\\msedge.exe"
if defined BROWSER_EXE (
  start "" "%BROWSER_EXE%" --app="%URL%"
) else (
  start "" "%URL%"
)
exit /b 0

:connect_loop
echo.
echo Tunnel active at %URL%
echo Keep this window open while using ${APP_NAME}.
ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -L "127.0.0.1:%LOCAL_PORT%:%REMOTE_TARGET%" %SSH_TARGET%
echo.
echo Tunnel disconnected. Reconnecting in 5 seconds...
timeout /t 5 /nobreak >nul
goto connect_loop
`.replace(/\n/g, "\r\n");
}

function posixLauncher({ sshTarget, localPort, remotePort, remoteSocket = "" }) {
  return `#!/usr/bin/env sh
# ${APP_NAME} tunnel. Forwards a local port to the GUI's private Unix socket on the server.
# Run with --tcp to forward to the GUI's TCP port instead (only when the GUI listens in
# tcp or both mode; every local account on the server can reach that port).
set -eu
START_PORT="${localPort}"
REMOTE_PORT="${remotePort}"
REMOTE_SOCKET="${remoteSocket}"
SSH_TARGET="${sshTarget}"
LOCAL_PORT="$START_PORT"
REMOTE_TARGET="$REMOTE_SOCKET"
if [ "\${1:-}" = "--tcp" ] || [ -z "$REMOTE_TARGET" ]; then
  REMOTE_TARGET="127.0.0.1:$REMOTE_PORT"
fi

port_listening() {
  if command -v nc >/dev/null 2>&1; then
    nc -z 127.0.0.1 "$1" >/dev/null 2>&1
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

health_check() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 2 "http://127.0.0.1:$1/api/health" 2>/dev/null | grep -q '"app"[[:space:]]*:[[:space:]]*"${APP_ID}"'
  elif command -v wget >/dev/null 2>&1; then
    wget -q -T 2 -O - "http://127.0.0.1:$1/api/health" 2>/dev/null | grep -q '"app"[[:space:]]*:[[:space:]]*"${APP_ID}"'
  else
    return 1
  fi
}

find_available_port() {
  while port_listening "$LOCAL_PORT"; do
    LOCAL_PORT=$((LOCAL_PORT + 1))
  done
}

open_browser() {
  if command -v google-chrome >/dev/null 2>&1; then
    google-chrome --app="$URL" >/dev/null 2>&1 &
  elif command -v chromium >/dev/null 2>&1; then
    chromium --app="$URL" >/dev/null 2>&1 &
  elif command -v microsoft-edge >/dev/null 2>&1; then
    microsoft-edge --app="$URL" >/dev/null 2>&1 &
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$URL" >/dev/null 2>&1 || true
  elif command -v open >/dev/null 2>&1; then
    open -na "Google Chrome" --args --app="$URL" >/dev/null 2>&1 || open "$URL" >/dev/null 2>&1 || true
  fi
}

if port_listening "$LOCAL_PORT"; then
  if health_check "$LOCAL_PORT"; then
    URL="http://127.0.0.1:$LOCAL_PORT/"
    echo "Reusing existing ${APP_NAME} tunnel at $URL"
    open_browser
    exit 0
  fi
  printf 'Port %s is already used by another application. Use another available port? [y/N] ' "$LOCAL_PORT"
  read answer
  case "$answer" in
    y|Y|yes|YES) find_available_port ;;
    *) echo "Cancelled."; exit 1 ;;
  esac
fi

URL="http://127.0.0.1:$LOCAL_PORT/"
echo "Starting ${APP_NAME} tunnel to $SSH_TARGET ($REMOTE_TARGET)..."
echo "Local URL will be $URL"
OPENED_BROWSER=0
while true; do
  echo
  echo "Tunnel active at $URL"
  echo "Keep this terminal open while using ${APP_NAME}."
  ssh -N -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -L "127.0.0.1:$LOCAL_PORT:$REMOTE_TARGET" "$SSH_TARGET" &
  TUNNEL_PID="$!"
  i=0
  while [ "$i" -lt 30 ]; do
    i=$((i + 1))
    if health_check "$LOCAL_PORT"; then
      if [ "$OPENED_BROWSER" != "1" ]; then
        open_browser
        OPENED_BROWSER=1
      fi
      break
    fi
    if ! kill -0 "$TUNNEL_PID" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if [ "$OPENED_BROWSER" != "1" ]; then
    echo "Tunnel started, but the health check did not confirm ${APP_NAME} yet."
    echo "Open $URL after a moment."
    open_browser
    OPENED_BROWSER=1
  fi
  wait "$TUNNEL_PID" || true
  echo "Tunnel disconnected. Reconnecting in 5 seconds..."
  sleep 5
done
`;
}

function androidLauncherInfo({ sshTarget, localPort, remotePort, remoteSocket = "" }) {
  const socketPart = remoteSocket ? `Remote forwarding target (the GUI's private Unix socket):
  ${remoteSocket}

Your SSH app must support forwarding a local port to a Unix socket on the server.
Termux's OpenSSH does:
  pkg install openssh
  ssh -N -L 127.0.0.1:${localPort}:${remoteSocket} ${sshTarget}

If your SSH app can only forward to a host and port, switch the GUI to tcp mode
(Settings > Tunnel Manager > GUI listener) and forward to 127.0.0.1:${remotePort}.
In tcp mode every local account on the server can reach the GUI.
` : `Remote forwarding target:
  127.0.0.1:${remotePort}

The GUI listens in tcp mode: every local account on the server can reach it.

In Termius, JuiceSSH or a similar app, create a local port forward:
  Local: 127.0.0.1:${localPort}
  Destination: 127.0.0.1:${remotePort}
  SSH host/account: ${sshTarget}
`;
  return `${APP_NAME} Android tunnel setup

SSH target:
  ${sshTarget}

Local port:
  ${localPort}

${socketPart}
Then open this in Android Chrome:
  http://127.0.0.1:${localPort}/

Use local forwarding (-L), not remote forwarding.
`;
}

const PLATFORMS = {
  windows: { label: "Windows", fileName: "backup-suite-gui.cmd", contentType: "application/x-msdownload; charset=utf-8", render: windowsLauncher },
  mac: { label: "macOS", fileName: "backup-suite-gui-mac.sh", contentType: "text/x-shellscript; charset=utf-8", render: posixLauncher },
  linux: { label: "Linux", fileName: "backup-suite-gui-linux.sh", contentType: "text/x-shellscript; charset=utf-8", render: posixLauncher },
  android: { label: "Android", fileName: "backup-suite-gui-android.txt", contentType: "text/plain; charset=utf-8", render: androidLauncherInfo }
};

function connectFile(kind, p) {
  if (kind === "toml") {
    return { contentType: "application/toml; charset=utf-8", fileName: "backup-suite-gui-tunnel-manager.toml", body: tunnelManagerToml(p) };
  }
  const entry = PLATFORMS[kind];
  if (!entry) return null;
  return { contentType: entry.contentType, fileName: entry.fileName, body: entry.render(p) };
}

const LAUNCHER_HOW_TO = {
  windows: "Double-click it. It opens the tunnel in its own window and then the GUI in your browser; keep that window open.",
  mac: "In Terminal: chmod +x FILE, then ./FILE. Keep the window open while you work.",
  linux: "In a terminal: chmod +x FILE, then ./FILE. Keep the window open while you work.",
  android: "Steps for Termux on Android (the Phone or tablet tab has them too)."
};

// Where `backup-suite-gui-server status` saves the launcher scripts on the server.
const LAUNCHER_DIR = "~/.local/share/backup-suite-gui/client-launchers";

function mobileInstructions(p) {
  const address = `http://127.0.0.1:${p.localPort}/`;
  return {
    android: {
      title: "Android: Termux (free, from F-Droid or Google Play)",
      after: [
        "Leave Termux running (allow it to run in the background if Android asks).",
        `Open ${address} in Chrome. Menu, then Add to Home screen, keeps it one tap away.`
      ]
    },
    ios: {
      title: "iPhone or iPad: Blink Shell (App Store)",
      after: [
        "Keep Blink open in the background (Blink's settings can keep the connection alive).",
        `Open ${address} in Safari. Share, then Add to Home Screen, keeps it one tap away.`
      ],
      note: "Blink's forwarding to a socket path has not been checked here; if it does not connect, switch the GUI to tcp mode or use a computer or Android."
    },
    general: [
      "Keep the SSH app connected while you use the GUI; reopen it if the GUI stops answering.",
      p.remoteSocket
        ? "The GUI is reached through a private socket on the server. Use an app that runs real OpenSSH commands; apps that only forward to a host and port (for example Termius or JuiceSSH) cannot reach it unless the GUI is switched to tcp mode."
        : `Any SSH app with local port forwarding works (for example Termius or JuiceSSH): local 127.0.0.1:${p.localPort} to destination 127.0.0.1:${p.remotePort}.`,
      `Sign in as ${p.sshTarget} with your usual SSH key or password.`
    ]
  };
}

function connectInstructions(p, settings) {
  return {
    backend_id: p.backendId,
    ssh_target: p.sshTarget,
    backend_saved: Boolean(settings.tunnel.backendId),
    backend_hint: "must be the user@host of your Tunnel Manager profile for this server",
    backend_hint_text: settings.tunnel.backendId
      ? "Must be the user@host of your Tunnel Manager profile for this server, exactly as Tunnel Manager shows it. Tunnel Manager refuses the import on any difference, for example an alias instead of the address. The launchers and the manual command use it too."
      : "Not saved yet: this is a guess from the server's address. Save the user@host of your Tunnel Manager profile for this server, exactly as Tunnel Manager shows it; the launchers and the manual command use it too.",
    remote: forwardTarget(p),
    socket: Boolean(p.remoteSocket),
    local_port: p.localPort,
    address: `http://127.0.0.1:${p.localPort}/`,
    unit: p.unit,
    tunnel_manager: {
      download_url: TUNNEL_MANAGER_DOWNLOAD_URL,
      file_name: "backup-suite-gui-tunnel-manager.toml",
      url: "/api/connect/file?kind=toml",
      toml: tunnelManagerToml(p)
    },
    scripts: Object.entries(PLATFORMS).map(([platform, entry]) => ({
      platform, label: entry.label, file_name: entry.fileName, url: `/api/connect/file?kind=${platform}`,
      how_to: LAUNCHER_HOW_TO[platform].replace(/FILE/g, entry.fileName)
    })),
    mobile: mobileInstructions(p),
    manual: { ssh: `ssh -N -L 127.0.0.1:${p.localPort}:${forwardTarget(p)} ${p.sshTarget}`, address: `http://127.0.0.1:${p.localPort}/` },
    tcp_note: "If an SSH app can only forward to a host and port, switch the GUI to tcp mode (Settings, Tunnel Manager, GUI listener) and download the profile and launchers again. In tcp mode every local account on the server can reach the GUI.",
    cli: {
      status: "gui/scripts/backup-suite-gui-server status",
      bundle: `gui/scripts/backup-suite-gui-server bundle --backend ${p.backendId}`,
      launcher_dir: LAUNCHER_DIR
    }
  };
}

// Plain-text "ways to connect" for `backup-suite-gui-server status`, like agentw-gui status.
function connectText(info, savedFiles = {}) {
  const lines = [];
  lines.push(info.socket
    ? `${APP_NAME} listens on a private Unix socket on this host:\n  ${info.remote}\nOnly this account can open it; an SSH tunnel to it is opened as your SSH login user.`
    : `${APP_NAME} listens on ${info.remote} (tcp mode): every local account on this host can reach it.`);
  lines.push("", `Backend (user@host): ${info.backend_id}${info.backend_saved ? "" : " (a guess; set yours with: bundle --backend user@host, or in the GUI's Ways to connect)"}`);
  lines.push("", "1. Tunnel Manager (recommended)",
    `   Install: ${info.tunnel_manager.download_url}`,
    `   Profile: ${savedFiles.toml || info.cli.bundle}`,
    "   In your Tunnel Manager profile for this server: Import that file, then Start.");
  lines.push("", "2. Launcher scripts (open the tunnel and the browser, reconnect on drops)");
  for (const script of info.scripts) lines.push(`   ${script.label.padEnd(8)} ${savedFiles[script.platform] || script.file_name}`);
  lines.push(`   Through an open tunnel the GUI serves fresh ones: ${info.address}api/connect/file?kind=windows|mac|linux|android|toml`);
  lines.push("", "3. Phone or tablet",
    `   Android (Termux): pkg install openssh, then: ${info.manual.ssh}`,
    `   iPhone/iPad (Blink Shell): ${info.manual.ssh}`,
    `   Then open ${info.address} in the phone's browser.`,
    `   ${info.mobile.general[1]}`);
  lines.push("", "4. Manual (any computer with OpenSSH 6.7 or later; keep it open)",
    `   ${info.manual.ssh}`,
    `   Then open: ${info.address}`);
  if (info.socket) lines.push("", info.tcp_note);
  lines.push("", `In the GUI: the download button (or Actions, Ways to connect) shows all of these.`);
  return `${lines.join("\n")}\n`;
}

module.exports = { APP_ID, APP_NAME, PLATFORMS, backendId, connectFile, connectInstructions, connectText, primaryIPv4, profile, tunnelManagerToml };
