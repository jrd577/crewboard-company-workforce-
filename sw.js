/* Crewboard manager app service worker.
   It only touches manager.html, its icons and the manifest. Every other page on the site
   (including the client and supplier sign-up page) is left completely alone.
   Bump VERSION when you change this file. */
var VERSION = "crewboard-v2";
var SHELL = ["manager.html", "manifest.webmanifest", "icon-192.png", "icon-512.png", "icon-180.png"];

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
  if (url.origin !== location.origin) return;            /* Supabase, fonts and CDN scripts go straight to the network */
  if (req.mode === "navigate") {
    if (!/\/manager\.html$/.test(url.pathname)) return;  /* index.html and any other page: not handled here */
    e.respondWith(
      fetch(req).then(function (res) {
        var copy = res.clone();
        caches.open(VERSION).then(function (c) { c.put(req, copy); });
        return res;
      }).catch(function () { return caches.match(req).then(function (m) { return m || caches.match("manager.html"); }); })
    );
    return;
  }
  if (/\/(manifest\.webmanifest|icon-[a-z0-9-]+\.png)$/.test(url.pathname)) {
    e.respondWith(caches.match(req).then(function (m) { return m || fetch(req); }));
  }
});
