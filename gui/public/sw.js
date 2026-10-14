// Backup Suite GUI service worker: makes the GUI installable and caches only static
// assets. API replies are never cached; they always go to the server.
const CACHE = "backup-suite-gui-v1";
const ASSETS = ["/", "/index.html", "/styles.css", "/app.js", "/theme-boot.js", "/help.js", "/manifest.webmanifest", "/icons/icon.svg", "/icons/icon-192.png", "/icons/icon-512.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(ASSETS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== self.location.origin || url.pathname.startsWith("/api/")) return;
  // Network first, so a GUI update shows at once; the cache only covers a dropped tunnel.
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        if (response.ok && ASSETS.includes(url.pathname)) {
          const copy = response.clone();
          caches.open(CACHE).then((cache) => cache.put(event.request, copy));
        }
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
