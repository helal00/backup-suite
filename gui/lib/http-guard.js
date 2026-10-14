"use strict";

// Browser-side protection for the HTTP API.
//
// - Host must be 127.0.0.1, localhost or [::1], with any port (Tunnel Manager picks
//   the local port). This blocks DNS rebinding: a page on evil.example that resolves
//   to 127.0.0.1 still sends Host: evil.example.
// - A changing request (POST, PUT, PATCH, DELETE) must carry an Origin whose host and
//   port equal the request's own Host, and the per-server CSRF token from
//   GET /api/session.
// - Tunnel Manager's event endpoint (POST /api/events) needs no CSRF token, because
//   Tunnel Manager is not a browser and sends no Origin; it still passes the Host check.

const crypto = require("crypto");

const LOCAL_HOST_RE = /^(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?$/i;
const CHANGING = new Set(["POST", "PUT", "PATCH", "DELETE"]);
const CSRF_EXEMPT = new Set(["/api/events"]);

function newToken() {
  return crypto.randomBytes(32).toString("base64url");
}

function hostAllowed(host) {
  return LOCAL_HOST_RE.test(String(host || ""));
}

function originMatchesHost(origin, host) {
  if (!origin) return false;
  try {
    const url = new URL(origin);
    return (url.protocol === "http:" || url.protocol === "https:") && url.host.toLowerCase() === String(host || "").toLowerCase();
  } catch {
    return false;
  }
}

function tokensEqual(a, b) {
  const left = Buffer.from(String(a || ""));
  const right = Buffer.from(String(b || ""));
  return left.length === right.length && left.length > 0 && crypto.timingSafeEqual(left, right);
}

// Returns null when the request may proceed, else { status, code, message }.
function check(req, pathname, token) {
  const host = req.headers.host;
  if (!hostAllowed(host)) {
    return { status: 403, code: "bad_host", message: "Requests must address 127.0.0.1, localhost or [::1]." };
  }
  if (!CHANGING.has(req.method)) return null;
  if (CSRF_EXEMPT.has(pathname)) {
    const origin = req.headers.origin;
    if (origin && !originMatchesHost(origin, host)) {
      return { status: 403, code: "bad_origin", message: "Cross-origin request refused." };
    }
    return null;
  }
  if (!originMatchesHost(req.headers.origin, host)) {
    return { status: 403, code: "bad_origin", message: "Cross-origin request refused." };
  }
  if (!tokensEqual(req.headers["x-csrf-token"], token)) {
    return { status: 403, code: "bad_csrf", message: "Missing or stale page token; reload the page." };
  }
  return null;
}

module.exports = { check, hostAllowed, newToken, originMatchesHost };
