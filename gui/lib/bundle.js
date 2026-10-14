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

function connectInstructions(p, settings) {
  return {
    backend_id: p.backendId,
    backend_saved: Boolean(settings.tunnel.backendId),
    backend_hint: "must be the user@host of your Tunnel Manager profile for this server",
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
    scripts: Object.entries(PLATFORMS).map(([platform, entry]) => ({ platform, label: entry.label, file_name: entry.fileName, url: `/api/connect/file?kind=${platform}` })),
    manual: { ssh: `ssh -N -L 127.0.0.1:${p.localPort}:${forwardTarget(p)} ${p.sshTarget}`, address: `http://127.0.0.1:${p.localPort}/` }
  };
}

module.exports = { APP_ID, APP_NAME, backendId, connectFile, connectInstructions, primaryIPv4, profile, tunnelManagerToml };
