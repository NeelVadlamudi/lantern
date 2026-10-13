// dbt output loader. Reads board_data.json and, when mart Parquet files exist, runs SQL on them
// in the browser with DuckDB-WASM. Never fabricates values: missing files mean empty states.
import { CONFIG } from "./config.js";
import { TABLES, PARQUET_FILES, BOARD_KEYS, SQL, MAP_FALLBACK_FILES, LAZY_FILES } from "./queries.js";

const DUCKDB_VERSION = "1.32.0";
// Self-hosted (assets/vendor/duckdb, built from @duckdb/duckdb-wasm@${DUCKDB_VERSION} + apache-arrow with esbuild):
// no third-party script, so nothing unhashed runs. Only the exception-handling build ships (every current browser).
const DUCKDB_DIR = new URL("../vendor/duckdb/", import.meta.url).href;
const DUCKDB_ESM = `${DUCKDB_DIR}duckdb-browser.bundle.mjs`;

const dataUrl = (file) => new URL(CONFIG.DATA_PATH + file, location.href).href;

// Any other dbt JSON next to board_data.json (null when absent).
export async function loadJson(file) {
  try {
    const res = await fetch(dataUrl(file), { cache: "no-cache" });
    return res.ok ? await res.json() : null;
  } catch {
    return null;
  }
}

export async function loadBoardData() {
  try {
    const res = await fetch(dataUrl(CONFIG.BOARD_FILE), { cache: "no-cache" });
    if (!res.ok) return null;
    return await res.json();
  } catch {
    return null;
  }
}

function fileListFromBoard(board) {
  const raw = board && board[BOARD_KEYS.files];
  if (!raw) return null;
  if (Array.isArray(raw)) {
    const names = raw.map((f) => (typeof f === "string" ? f : f && f.file)).filter(Boolean);
    const out = {};
    for (const [key, name] of Object.entries(PARQUET_FILES)) {
      const hit = names.find((f) => f.split("/").pop() === name);
      if (hit) out[key] = hit.split("/").pop(); // files sit directly under DATA_PATH
    }
    return Object.keys(out).length ? out : null;
  }
  return { ...raw };
}

async function exists(file) {
  try {
    const res = await fetch(dataUrl(file), { method: "HEAD", cache: "no-cache" });
    return res.ok;
  } catch {
    return false;
  }
}

// Arrow values -> plain JS: BigInt -> Number, list vectors -> arrays.
const toPlain = (v) => {
  if (typeof v === "bigint") return Number(v);
  if (v && typeof v === "object" && typeof v.toArray === "function") return Array.from(v.toArray(), toPlain);
  return v;
};

// Split files (clean + planned-work rows): line_periods, station_periods, station_time_lost, the line and
// station hour heatmaps. The line-day tables (line_daily, line_day_metrics, station_daily) are NOT here:
// their flag marks a whole line-day and is read for the Planned work label; KPI queries filter it there.
const CLEAN_KEYS = ["period", "station", "stationTimeLost", "lineHourHeatmap", "chartHourly"];
const CLEAN_FILE = /^(station_hour_heatmap_[a-z]+|line_hour_heatmap|station_periods|station_time_lost|line_periods)\.parquet$/;

export class MartStore {
  constructor() {
    this.ready = false;
    this.tables = new Set();
    this.conn = null;
    this.error = null;
  }

  // Cheap same-origin HEAD checks; decides whether DuckDB-WASM is worth downloading at all.
  probe(board) {
    if (!this.probePromise) this.probePromise = this._probe(board);
    return this.probePromise;
  }

  async _probe(board) {
    const candidates = { ...(fileListFromBoard(board) || PARQUET_FILES) }; // board_data files list wins (no 404 probes)
    // The map Parquet is only a fallback for a board_data.json without a map block.
    const map = board && board[BOARD_KEYS.map];
    if (map && Array.isArray(map[BOARD_KEYS.mapStations]) && map[BOARD_KEYS.mapStations].length && Array.isArray(map[BOARD_KEYS.mapLines]) && map[BOARD_KEYS.mapLines].length) {
      for (const k of MAP_FALLBACK_FILES) delete candidates[k];
    }
    const present = {};
    await Promise.all(
      Object.entries(candidates).map(async ([key, file]) => {
        if (file && TABLES[key] && (await exists(file))) present[key] = file;
      })
    );
    this.present = present;
    return present;
  }

  // Returns true when at least one mart file is queryable.
  async init(board) {
    if (this.initPromise) return this.initPromise;
    this.initPromise = this._init(board);
    return this.initPromise;
  }

  // View over one Parquet buffer. clean = a file that carries a clean row and a planned-work row per cell
  // (dbt: is_planned_change): the view keeps only clean rows, so no query counts a cell twice. Files
  // without the column load unchanged.
  async makeView(view, file, clean) {
    await this.conn.query(`create or replace view ${view} as select * from read_parquet('${file}')`);
    if (!clean) return;
    const cols = await this.conn.query(`select column_name from (describe ${view})`);
    const has = cols.toArray().some((r) => r.toJSON().column_name === "is_planned_change");
    if (has) { await this.conn.query(`create or replace view ${view} as select * from read_parquet('${file}') where coalesce(is_planned_change, false) = false`); (this.cleaned = this.cleaned || new Set()).add(view); }
  }

  async _init(board) {
    const present = await this.probe(board);
    if (!Object.keys(present).length) return false;

    try {
      const duckdb = await import(DUCKDB_ESM);
      const eh = { mainModule: `${DUCKDB_DIR}duckdb-eh.wasm`, mainWorker: `${DUCKDB_DIR}duckdb-browser-eh.worker.js` };
      const bundle = await duckdb.selectBundle({ mvp: eh, eh });
      const worker = new Worker(bundle.mainWorker);
      const db = new duckdb.AsyncDuckDB(new duckdb.ConsoleLogger(duckdb.LogLevel.WARNING), worker);
      await db.instantiate(bundle.mainModule, bundle.pthreadWorker);
      this.conn = await db.connect();
      // Extensions (parquet) load from our own copy, never extensions.duckdb.org.
      try { await this.conn.query(`set custom_extension_repository = '${DUCKDB_DIR}ext'`); } catch { /* older builds */ }

      // Mart files are small; buffer them so any static host works (no HTTP range support needed).
      this.db = db;
      for (const [key, file] of Object.entries(present)) {
        if (LAZY_FILES.includes(key)) continue;
        // One bad file (404, corrupt Parquet) only takes out what reads it, never the whole board.
        try {
          const res = await fetch(dataUrl(file), { cache: "no-cache" });
          if (!res.ok) { console.warn("[data] file unavailable", file, res.status); continue; }
          const buf = new Uint8Array(await res.arrayBuffer());
          const name = `${key}.parquet`;
          await db.registerFileBuffer(name, buf);
          await this.makeView(TABLES[key], name, CLEAN_KEYS.includes(key));
          await this.conn.query(`select 1 from ${TABLES[key]} limit 1`); // reads the footer: corrupt files fail here
          this.tables.add(key);
        } catch (err) { console.warn("[data] file skipped (unreadable)", file, String(err && err.message || err).slice(0, 120)); }
      }
      this.ready = this.tables.size > 0;
    } catch (err) {
      this.error = err;
      console.warn("[data] DuckDB-WASM unavailable", err);
      this.ready = false;
    }
    return this.ready;
  }

  // Load a lazy file (e.g. the station x hour heatmap) on first use. True when queryable.
  async ensure(key) {
    if (this.tables.has(key)) return true;
    if (!this.ready || !this.present || !this.present[key]) return false;
    this._lazy = this._lazy || new Map();
    if (!this._lazy.has(key)) this._lazy.set(key, (async () => {
      try {
        const res = await fetch(dataUrl(this.present[key]), { cache: "no-cache" });
        if (!res.ok) return false;
        await this.db.registerFileBuffer(`${key}.parquet`, new Uint8Array(await res.arrayBuffer()));
        await this.makeView(TABLES[key], `${key}.parquet`, CLEAN_KEYS.includes(key));
        this.tables.add(key);
        return true;
      } catch (err) { console.warn("[data] lazy load failed", key, err); return false; }
    })());
    return this._lazy.get(key);
  }

  // Extra Parquet file named by board_data (e.g. charts.station_heatmap_files_by_line); returns its view name.
  async ensureFile(file) {
    if (!this.ready || typeof file !== "string" || !/^[a-z0-9_]{1,60}\.parquet$/.test(file)) return null;
    const view = `x_${file.replace(/\.parquet$/, "")}`;
    this._extra = this._extra || new Map();
    if (!this._extra.has(file)) this._extra.set(file, (async () => {
      try {
        const res = await fetch(dataUrl(file), { cache: "no-cache" });
        if (!res.ok) return null;
        await this.db.registerFileBuffer(file, new Uint8Array(await res.arrayBuffer()));
        await this.makeView(view, file, CLEAN_FILE.test(file));
        await this.conn.query(`select 1 from ${view} limit 1`);
        return view;
      } catch (err) { console.warn("[data] file skipped (unreadable)", file, String(err && err.message || err).slice(0, 120)); return null; }
    })());
    return this._extra.get(file);
  }

  has(...keys) {
    return this.ready && keys.every((k) => this.tables.has(k));
  }

  // Column names of a loaded table (cached); null when the table isn't loaded.
  async columns(key) {
    if (!this.has(key)) return null;
    this._cols = this._cols || new Map();
    if (!this._cols.has(key)) {
      const rows = await this.query(`select column_name from (describe ${TABLES[key]})`);
      this._cols.set(key, rows ? rows.map((r) => r.column_name) : null);
    }
    return this._cols.get(key);
  }

  // Raw SQL (insight cards build theirs from config; identifiers are validated there).
  async query(sql) {
    if (!this.ready) return null;
    try {
      const table = await this.conn.query(sql);
      return table.toArray().map((row) => {
        const o = row.toJSON();
        for (const k of Object.keys(o)) o[k] = toPlain(o[k]);
        return o;
      });
    } catch (err) {
      console.info("[data] insight query returned nothing (column or table missing?)", String(err && err.message || err).slice(0, 160));
      return null;
    }
  }

  async run(name, filters = {}) {
    if (!this.ready) return null;
    const sql = SQL[name](filters);
    try {
      const table = await this.conn.query(sql);
      return table.toArray().map((row) => {
        const o = row.toJSON();
        for (const k of Object.keys(o)) o[k] = toPlain(o[k]);
        return o;
      });
    } catch (err) {
      console.warn(`[data] query ${name} failed`, err);
      return null;
    }
  }
}
