// Lantern service worker: cache-first for the self-hosted vendor files only (DuckDB-WASM, its parquet
// extension, MapLibre). Data, pages and the live feed are never cached here. Bump VERSION with the vendor files.
const VERSION = "vendor-duckdb-1.32.0-ext-1.4.3-maplibre-5.24.0";
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k !== VERSION) await caches.delete(k);
  await self.clients.claim();
})()));
self.addEventListener("fetch", (e) => {
  const u = new URL(e.request.url);
  if (e.request.method !== "GET" || u.origin !== self.location.origin || !u.pathname.includes("/assets/vendor/")) return;
  e.respondWith((async () => {
    const c = await caches.open(VERSION);
    const hit = await c.match(e.request);
    if (hit) return hit;
    const res = await fetch(e.request);
    if (res.ok && res.type === "basic") c.put(e.request, res.clone());
    return res;
  })());
});
