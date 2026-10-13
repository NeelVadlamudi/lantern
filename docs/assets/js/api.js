// MBTA V3 API access with a client-side request budget shared by every caller.
// Anonymous limit is 20 requests/minute/IP; we cap ourselves at CONFIG.API_BUDGET_PER_MIN.
import { CONFIG } from "./config.js";

const stamps = [];
const WINDOW_MS = 60000;

async function acquireSlot() {
  for (;;) {
    const now = Date.now();
    while (stamps.length && now - stamps[0] > WINDOW_MS) stamps.shift();
    if (stamps.length < CONFIG.API_BUDGET_PER_MIN) {
      stamps.push(now);
      return;
    }
    await new Promise((r) => setTimeout(r, WINDOW_MS - (now - stamps[0]) + 50));
  }
}

export class ApiError extends Error {
  constructor(status, retryAfterMs) {
    super(`MBTA API ${status}`);
    this.status = status;
    this.retryAfterMs = retryAfterMs;
  }
}

function retryAfter(res) {
  const ra = res.headers.get("retry-after");
  if (ra && !Number.isNaN(Number(ra))) return Number(ra) * 1000;
  const reset = res.headers.get("x-ratelimit-reset"); // epoch seconds, if CORS exposes it
  if (reset && !Number.isNaN(Number(reset))) return Math.max(0, Number(reset) * 1000 - Date.now());
  return null;
}

// path like "/vehicles", params as a plain object; brackets are encoded properly.
export async function mbta(path, params = {}, { signal } = {}) {
  await acquireSlot();
  const url = new URL(CONFIG.API_BASE + path);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  const res = await fetch(url.href, { signal, headers: { Accept: "application/vnd.api+json" } });
  if (!res.ok) throw new ApiError(res.status, retryAfter(res));
  return res.json();
}

export function indexIncluded(doc) {
  const idx = new Map();
  for (const item of doc.included || []) idx.set(`${item.type}:${item.id}`, item);
  return idx;
}
