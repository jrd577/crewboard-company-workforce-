/* Crewboard service worker. Keeps the app shell available and never caches live data.
   Bump VERSION when you change this file. */
var VERSION = "crewboard-v1";
var SHELL = ["./", "manifest.webmanifest", "icons/icon-192.png", "icons/icon-512.png", "icons/icon-180.png"];

self.addEventListener("install", function (e) {
  e.waitUntil(caches.open(VERSION).then(function (c) { return c.addAll(SHELL); }).then(function () { return self.skipWaiting(); }));
});
self.addEventListener("activate", function (e) {
  e.waitUntil(
    caches.keys().then(function (keys) {
      return Promise.all(keys.filter(function (k) { return k !== VERSION; }).map(function (k) { return caches.delete(k); }));
    }).then(function () { return self.clients.claim(); })
  );
});
self.addEventListener("fetch", function (e) {
  var req = e.request;
  if (req.method !== "GET") return;
  var url = new URL(req.url);
  if (url.origin !== location.origin) return;      /* Supabase, fonts and CDN scripts always go straight to the network */
  if (req.mode === "navigate") {
    /* the page itself: network first so updates show at once, cached copy only when offline */
    e.respondWith(
      fetch(req).then(function (res) {
        var copy = res.clone();
        caches.open(VERSION).then(function (c) { c.put(req, copy); });
        return res;
      }).catch(function () { return caches.match(req).then(function (m) { return m || caches.match("./"); }); })
    );
    return;
  }
  /* icons and manifest: cache first */
  e.respondWith(caches.match(req).then(function (m) { return m || fetch(req); }));
});
