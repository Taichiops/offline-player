// Keeps the player's own files on the device so it opens without internet.
// Songs are not cached here; the page keeps them in IndexedDB.
const CACHE = "offline-player-v1";
const SHELL = ["./", "index.html", "manifest.webmanifest", "icons/icon-192.png", "icons/icon-512.png", "icons/apple-touch-icon.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

// Answer from the cache straight away and refresh it in the background, so an update shows on the next launch.
self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  const sameOrigin = url.origin === self.location.origin;
  const isFont = url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com";
  if (!sameOrigin && !isFont) return;

  event.respondWith(
    caches.open(CACHE).then(async (cache) => {
      const cached = await cache.match(request, { ignoreSearch: sameOrigin });
      const fresh = fetch(request)
        .then((response) => {
          if (response.ok || response.type === "opaque") cache.put(request, response.clone());
          return response;
        })
        .catch(() => cached);
      return cached || fresh;
    })
  );
});
