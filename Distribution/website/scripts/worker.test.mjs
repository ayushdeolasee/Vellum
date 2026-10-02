import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import test from "node:test";
import worker from "../worker.js";

// In-memory SQLite and fake bindings only; no account, Keychain, or network access.
function fixture(rateLimit = Infinity) {
  const database = new DatabaseSync(":memory:");
  const migrations = new URL("../migrations/", import.meta.url);
  for (const file of readdirSync(migrations).sort()) database.exec(readFileSync(new URL(file, migrations), "utf8"));
  const keys = [];
  const DB = {
    prepare(sql) {
      let args = [];
      const query = {
        bind(...values) { args = values; return query; },
        async run() { return { meta: { changes: Number(database.prepare(sql).run(...args).changes) } }; },
        async all() { return { results: database.prepare(sql).all(...args) }; },
        async first() { return database.prepare(sql).get(...args); },
      };
      return query;
    },
    async batch(queries) { return Promise.all(queries.map((query) => query.run())); },
  };
  const env = { DB, EXPORT_TOKEN: "fixture-only", ANALYTICS_RATE_LIMITER: {
    async limit({ key }) { keys.push(key); return { success: keys.length <= rateLimit }; },
  } };
  const pending = [];
  const context = { waitUntil(promise) { pending.push(promise); } };
  return { database, env, keys, pending, context };
}
function request(path, body, headers = {}) {
  return new Request(`https://example.test${path}`, body === undefined ? { headers } : {
    method: "POST", headers: { "Content-Type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}
const event = { event: "first_launch", version: "1.2.3", build: "4" };
const auth = { Authorization: "Bearer fixture-only" };

function parseCSV(csv) {
  return Array.from(csv.matchAll(/"((?:[^"]|"")*)"(?:,|\r\n)/g), (match) => match[1].replaceAll('""', '"'));
}

test("export quotes CSV and neutralizes formula prefixes in every identity column", async () => {
  const f = fixture();
  try {
    const dangerous = ["=1+1", "+1+1", "-1+1", "@SUM(1)", " \t=1+1", "\u0000+1+1", "\u0085-1+1", "\uFEFF@SUM(1)", "\tplain"];
    const normal = ['Doe, Jane', 'O"Brien', 'Zoë\n李', '普通', ' a name '];
    // Direct D1 result fixtures also cover NUL, which Node's SQLite text adapter truncates.
    f.env.DB.prepare = () => ({ async all() { return { results: [...dangerous, ...normal].map((value) => ({ first_name: value, last_name: value, email: value })) }; } });
    assert.equal((await worker.fetch(request("/api/testflight-signups.csv"), f.env, f.context)).status, 404);
    const response = await worker.fetch(request("/api/testflight-signups.csv", undefined, auth), f.env, f.context);
    assert.equal(response.status, 200);
    const cells = parseCSV(await response.text()).slice(3);
    [...dangerous, ...normal].forEach((value, index) => {
      const expected = index < dangerous.length ? `'${value}` : value;
      assert.deepEqual(cells.slice(index * 3, index * 3 + 3), [expected, expected, expected]);
    });
  } finally { f.database.close(); }
});

test("analytics schema and streamed UTF-8 byte limits reject invalid inputs without DB writes", async () => {
  const f = fixture();
  try {
    for (const body of [null, [], 4, {}, { ...event, extra: true }, { ...event, event: "download_click" }, { ...event, build: "x".repeat(33) }, "{"]) {
      assert.equal((await worker.fetch(request("/api/analytics", body), f.env, f.context)).status, 400);
    }
    assert.equal((await worker.fetch(request("/api/analytics", event, { "Content-Type": "text/plain" }), f.env, f.context)).status, 415);
    assert.equal((await worker.fetch(request("/api/analytics", " ".repeat(1025)), f.env, f.context)).status, 413);
    const stream = new ReadableStream({ start(c) { c.enqueue(new TextEncoder().encode("é".repeat(513))); c.close(); } });
    const streamed = new Request("https://example.test/api/analytics", { method: "POST", headers: { "Content-Type": "application/json" }, body: stream, duplex: "half" });
    assert.equal((await worker.fetch(streamed, f.env, f.context)).status, 413);
    assert.equal((await worker.fetch(request("/api/testflight-signups", null), f.env, f.context)).status, 400);
    assert.equal(f.database.prepare("SELECT COUNT(*) AS n FROM analytics_events").get().n, 0);
  } finally { f.database.close(); }
});

test("all analytics routes share the rate gate and atomic daily insert budget", async () => {
  const f = fixture(60);
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response("<rss />");
  try {
    for (let i = 0; i < 58; i++) assert.equal((await worker.fetch(request("/api/analytics", event), f.env, f.context)).status, 204);
    assert.equal((await worker.fetch(request("/download/mac?source=hero"), f.env, f.context)).status, 302);
    assert.equal((await worker.fetch(request("/updates/appcast.xml"), f.env, f.context)).status, 200);
    await Promise.all(f.pending);
    assert.equal((await worker.fetch(request("/api/analytics", event), f.env, f.context)).status, 429);
    assert.equal(f.database.prepare("SELECT COUNT(*) AS n FROM analytics_events").get().n, 60);
    assert.equal(new Set(f.keys).size, 1);
    delete f.env.ANALYTICS_RATE_LIMITER;
    assert.equal((await worker.fetch(request("/api/analytics", event), f.env, f.context)).status, 503);
    f.env.ANALYTICS_RATE_LIMITER = { async limit() { return { success: true }; } };
    f.database.exec("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x < 4939) INSERT INTO analytics_events(event,source) SELECT 'first_launch','fixture' FROM n");
    const statuses = await Promise.all(Array.from({ length: 20 }, async () => (await worker.fetch(request("/api/analytics", event), f.env, f.context)).status));
    assert.equal(statuses.filter((status) => status === 204).length, 1);
    assert.equal(statuses.filter((status) => status === 429).length, 19);
    assert.equal(f.database.prepare("SELECT COUNT(*) AS n FROM analytics_events").get().n, 5000);
    assert.equal(f.database.prepare("SELECT event_count FROM analytics_daily_budget WHERE day = date('now')").get().event_count, 5000);
    const plan = f.database.prepare("EXPLAIN QUERY PLAN SELECT event_count FROM analytics_daily_budget WHERE day = date('now')").all();
    assert.ok(plan.some((row) => /SEARCH analytics_daily_budget USING PRIMARY KEY/.test(row.detail)));
    const health = await worker.fetch(request("/api/analytics-health", undefined, auth), f.env, f.context);
    assert.deepEqual(await health.json(), { analyticsToday: 5000, analyticsBudgetToday: 5000, analyticsOverdue: 0, signupsOverdue: 0, analyticsDailyLimit: 5000 });
  } finally { globalThis.fetch = originalFetch; f.database.close(); }
});

test("private health distinguishes today's stored rows from the controlling quota counter", async () => {
  const f = fixture();
  try {
    f.database.exec("INSERT INTO analytics_events(event,source,created_at) VALUES ('first_launch','fixture',datetime('now')), ('first_launch','fixture',datetime('now','+1 day'))");
    f.database.exec("UPDATE analytics_daily_budget SET event_count = 5000 WHERE day = date('now')");
    let response = await worker.fetch(request("/api/analytics-health", undefined, auth), f.env, f.context);
    assert.equal(response.status, 200);
    assert.deepEqual(await response.json(), { analyticsToday: 1, analyticsBudgetToday: 5000, analyticsOverdue: 0, signupsOverdue: 0, analyticsDailyLimit: 5000 });
    assert.equal((await worker.fetch(request("/api/analytics", event), f.env, f.context)).status, 429);
    f.database.exec("DELETE FROM analytics_daily_budget WHERE day = date('now')");
    response = await worker.fetch(request("/api/analytics-health", undefined, auth), f.env, f.context);
    assert.equal((await response.json()).analyticsBudgetToday, null);
    f.database.exec("DROP TABLE analytics_daily_budget");
    assert.equal((await worker.fetch(request("/api/analytics-health", undefined, auth), f.env, f.context)).status, 503);
  } finally { f.database.close(); }
});

test("GET analytics failures log only a fixed message while downloads and appcasts remain available", async () => {
  const f = fixture();
  const originalFetch = globalThis.fetch;
  const originalError = console.error;
  const logs = [];
  globalThis.fetch = async () => new Response("<rss />");
  console.error = (...args) => logs.push(args);
  try {
    f.env.ANALYTICS_RATE_LIMITER.limit = async () => { throw new Error("sensitive fixture detail"); };
    assert.equal((await worker.fetch(request("/download/mac?source=sensitive-fixture"), f.env, f.context)).status, 302);
    await Promise.all(f.pending);
    f.env.ANALYTICS_RATE_LIMITER.limit = async () => ({ success: true });
    f.env.DB.prepare = () => { throw new Error("sensitive database fixture"); };
    assert.equal((await worker.fetch(request("/updates/appcast.xml"), f.env, f.context)).status, 200);
    await Promise.all(f.pending);
    assert.deepEqual(logs, [["Unable to record aggregate analytics event"], ["Unable to record aggregate analytics event"]]);
  } finally { globalThis.fetch = originalFetch; console.error = originalError; f.database.close(); }
});

test("scheduled retention removes expired analytics and waitlist without any incoming event", async () => {
  const f = fixture();
  try {
    f.database.exec("INSERT INTO analytics_events(event,source,created_at) VALUES ('first_launch','fixture',datetime('now','-4 months')), ('first_launch','fixture',datetime('now'))");
    for (const [id, offset, status] of [["old-waiting", "-13 months", "waiting"], ["old-invited", "-13 months", "invited"], ["new", "-1 month", "waiting"]]) {
      f.database.prepare("INSERT INTO testflight_signups(id,first_name,last_name,email,created_at,status) VALUES (?, 'Fixture', 'Only', ?, datetime('now',?), ?)").run(id, `${id}@example.test`, offset, status);
    }
    await worker.scheduled({}, f.env);
    assert.equal(f.database.prepare("SELECT COUNT(*) AS n FROM analytics_events").get().n, 1);
    assert.equal(f.database.prepare("SELECT COUNT(*) AS n FROM testflight_signups").get().n, 1);
    assert.equal(f.database.prepare("SELECT COUNT(*) AS n FROM analytics_daily_budget").get().n, 1);
    assert.equal(f.keys.length, 0);
    assert.equal((await worker.fetch(request("/api/analytics-health"), f.env, f.context)).status, 404);
  } finally { f.database.close(); }
});
