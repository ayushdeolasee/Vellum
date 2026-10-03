const JSON_HEADERS = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
};
const ANALYTICS_DAILY_LIMIT = 5000;
const ANALYTICS_RATE_KEY = "public-analytics";
const MAC_DOWNLOAD_URL = "https://github.com/ayushdeolasee/Vellum/releases/latest/download/Vellum.dmg";
const MAC_APPCAST_URL = "https://github.com/ayushdeolasee/Vellum/releases/latest/download/appcast.xml";

export default {
  async scheduled(_controller, env) {
    const results = await env.DB.batch([
      env.DB.prepare("DELETE FROM analytics_events WHERE created_at < datetime('now', '-3 months')"),
      env.DB.prepare("DELETE FROM testflight_signups WHERE created_at < datetime('now', '-12 months')"),
      env.DB.prepare("DELETE FROM analytics_daily_budget WHERE day < date('now', '-3 months')"),
    ]);
    // Only aggregate counts: no names, email addresses, IPs, or request bodies.
    console.log("Retention completed", {
      analyticsDeleted: results[0].meta.changes,
      signupsDeleted: results[1].meta.changes,
    });
  },
  async fetch(request, env, context) {
    const url = new URL(request.url);

    if (url.pathname === "/download/mac") {
      if (request.method !== "GET") {
        return new Response(null, { status: 405, headers: { Allow: "GET" } });
      }
      recordEvent(context, env, "download_click", normalizeDownloadSource(url.searchParams.get("source")));
      return new Response(null, {
        status: 302,
        headers: {
          "Cache-Control": "no-store",
          Location: MAC_DOWNLOAD_URL,
        },
      });
    }

    if (url.pathname === "/updates/appcast.xml") {
      if (request.method !== "GET" && request.method !== "HEAD") {
        return new Response(null, { status: 405, headers: { Allow: "GET, HEAD" } });
      }
      if (request.method === "GET") {
        recordEvent(context, env, "update_check", "sparkle");
      }
      return fetch(MAC_APPCAST_URL, {
        method: request.method,
        headers: { Accept: "application/xml, text/xml;q=0.9, */*;q=0.8" },
        redirect: "follow",
      });
    }

    if (url.pathname === "/api/analytics") {
      if (request.method !== "POST") {
        return json({ error: "Method not allowed." }, 405, { Allow: "POST" });
      }
      return createAnalyticsEvent(request, env);
    }

    if (url.pathname === "/api/testflight-signups") {
      if (request.method !== "POST") {
        return json({ error: "Method not allowed." }, 405, { Allow: "POST" });
      }
      return createSignup(request, env);
    }

    if (url.pathname === "/api/testflight-signups.csv") {
      if (request.method !== "GET") {
        return json({ error: "Method not allowed." }, 405, { Allow: "GET" });
      }
      return exportSignups(request, env);
    }

    if (url.pathname === "/api/analytics-health") {
      if (request.method !== "GET") {
        return json({ error: "Method not allowed." }, 405, { Allow: "GET" });
      }
      return analyticsHealth(request, env);
    }

    if (url.pathname.startsWith("/api/")) {
      return json({ error: "Not found." }, 404);
    }

    return env.ASSETS.fetch(request);
  },
};

async function createAnalyticsEvent(request, env) {
  if (request.headers.get("Content-Type")?.split(";", 1)[0].trim() !== "application/json") {
    return json({ error: "Content type must be application/json." }, 415);
  }

  const parsed = await readJSON(request, 1024, "Invalid event.");
  if (parsed.response) return parsed.response;
  const body = parsed.body;
  if (!isObject(body) || Object.keys(body).some((key) => !["event", "version", "build"].includes(key))) {
    return json({ error: "Invalid event." }, 400);
  }

  const version = normalizeReleaseValue(body.version);
  const build = normalizeReleaseValue(body.build);
  if (body.event !== "first_launch" || !version || !build) {
    return json({ error: "Invalid event." }, 400);
  }

  try {
    if (!(await writeEvent(env, "first_launch", "mac_app", version, build))) {
      return json({ error: "Analytics budget reached." }, 429, { "Retry-After": "60" });
    }
    return new Response(null, {
      status: 204,
      headers: { "Cache-Control": "no-store" },
    });
  } catch {
    return json({ error: "Analytics are temporarily unavailable." }, 503);
  }
}

async function createSignup(request, env) {
  const origin = request.headers.get("Origin");
  if (origin && origin !== new URL(request.url).origin) {
    return json({ error: "This form must be submitted from vellum.work." }, 403);
  }

  const parsed = await readJSON(request, 4096, "Enter your name and email, then try again.");
  if (parsed.response) return parsed.response;
  const body = parsed.body;
  if (!isObject(body)) {
    return json({ error: "Enter your name and email, then try again." }, 400);
  }

  if (body.website) {
    return json({ outcome: "created" }, 201);
  }

  const firstName = normalizeName(body.firstName);
  const lastName = normalizeName(body.lastName);
  const email = normalizeEmail(body.email);
  const turnstileToken = typeof body.turnstileToken === "string" ? body.turnstileToken : "";

  if (!firstName || !lastName) {
    return json({ error: "Enter your first and last name." }, 400);
  }
  if (!email) {
    return json({ error: "Enter a valid email address." }, 400);
  }

  const turnstile = await verifyTurnstile(turnstileToken, request, env);
  if (!turnstile.success) {
    return json({ error: "Complete the security check and try again." }, 400);
  }

  try {
    const result = await env.DB.prepare(
      `INSERT INTO testflight_signups (id, first_name, last_name, email)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(email) DO NOTHING`,
    ).bind(crypto.randomUUID(), firstName, lastName, email).run();

    const outcome = result.meta.changes === 0 ? "already_registered" : "created";
    return json({ outcome }, outcome === "created" ? 201 : 200);
  } catch (error) {
    console.error("Unable to save TestFlight signup", error);
    return json({ error: "We could not save your signup. Try again in a moment." }, 500);
  }
}

async function verifyTurnstile(token, request, env) {
  if (!token || !env.TURNSTILE_SECRET_KEY) {
    return { success: false };
  }

  const payload = new FormData();
  payload.append("secret", env.TURNSTILE_SECRET_KEY);
  payload.append("response", token);

  const remoteAddress = request.headers.get("CF-Connecting-IP");
  if (remoteAddress) {
    payload.append("remoteip", remoteAddress);
  }

  try {
    const response = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      body: payload,
    });
    const result = await response.json();
    const validHostname = !result.hostname || result.hostname === "vellum.work" || result.hostname === "localhost";
    return {
      success: result.success === true && result.action === "testflight-signup" && validHostname,
    };
  } catch {
    return { success: false };
  }
}

async function exportSignups(request, env) {
  if (!(await authorizedExport(request, env))) {
    return json({ error: "Not found." }, 404);
  }

  try {
    const result = await env.DB.prepare(
      `SELECT first_name, last_name, email
       FROM testflight_signups
       WHERE status = 'waiting'
       ORDER BY created_at ASC`,
    ).all();

    const rows = [
      ["First Name", "Last Name", "Email Address"],
      ...result.results.map((signup) => [signup.first_name, signup.last_name, signup.email]),
    ];
    const csv = rows.map((row) => row.map(csvField).join(",")).join("\r\n") + "\r\n";

    return new Response(csv, {
      headers: {
        "Cache-Control": "no-store",
        "Content-Disposition": "attachment; filename=vellum-testflight-signups.csv",
        "Content-Type": "text/csv; charset=utf-8",
      },
    });
  } catch (error) {
    console.error("Unable to export TestFlight signups", error);
    return json({ error: "The export is unavailable." }, 500);
  }
}

function normalizeName(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim().replace(/\s+/g, " ");
  if (!normalized || normalized.length > 80 || /[\u0000-\u001f\u007f]/.test(normalized)) return null;
  return normalized;
}

function normalizeEmail(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toLowerCase();
  if (normalized.length > 254 || /[\u0000-\u001f\u007f-\u009f]/.test(normalized) || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)) return null;
  return normalized;
}

function normalizeDownloadSource(value) {
  return ["hero", "platforms", "footer"].includes(value) ? value : "direct";
}

function normalizeReleaseValue(value) {
  if (typeof value !== "string") return null;
  const normalized = value.trim();
  return /^[0-9A-Za-z.+-]{1,32}$/.test(normalized) ? normalized : null;
}

function recordEvent(context, env, event, source, version = "", build = "") {
  context.waitUntil(writeEvent(env, event, source, version, build).catch(() => {
    console.error("Unable to record aggregate analytics event");
  }));
}

async function writeEvent(env, event, source, version = "", build = "") {
  // One shared key avoids introducing an IP, installation, or user identifier.
  // Cloudflare's binding is approximate and per location, not a global quota.
  const { success } = await env.ANALYTICS_RATE_LIMITER.limit({ key: ANALYTICS_RATE_KEY });
  if (!success) return false;
  // The keyed check reads at most one daily counter. Migration 0004's trigger
  // increments it in this same SQLite statement transaction, so concurrent
  // events cannot race the cap and failed inserts do not consume quota.
  const result = await env.DB.prepare(
    `INSERT INTO analytics_events (event, source, version, build, created_at)
     SELECT ?, ?, ?, ?, datetime('now')
     WHERE COALESCE((SELECT event_count FROM analytics_daily_budget
                     WHERE day = date('now')), 0) < ?`,
  ).bind(event, source, version, build, ANALYTICS_DAILY_LIMIT).run();
  return result.meta.changes > 0;
}

async function analyticsHealth(request, env) {
  if (!(await authorizedExport(request, env))) return json({ error: "Not found." }, 404);
  try {
    const counts = await env.DB.prepare(
      `SELECT
       (SELECT COUNT(*) FROM analytics_events WHERE created_at >= date('now') AND created_at < date('now', '+1 day')) AS analyticsToday,
       (SELECT event_count FROM analytics_daily_budget WHERE day = date('now')) AS analyticsBudgetToday,
       (SELECT COUNT(*) FROM analytics_events WHERE created_at < datetime('now', '-3 months')) AS analyticsOverdue,
       (SELECT COUNT(*) FROM testflight_signups WHERE created_at < datetime('now', '-12 months')) AS signupsOverdue`,
    ).first();
    return json({ ...counts, analyticsDailyLimit: ANALYTICS_DAILY_LIMIT }, 200);
  } catch {
    return json({ error: "Health reporting is temporarily unavailable." }, 503);
  }
}

async function authorizedExport(request, env) {
  const expected = env.EXPORT_TOKEN ? `Bearer ${env.EXPORT_TOKEN}` : "";
  return !!expected && secureEqual(request.headers.get("Authorization") || "", expected);
}

function isObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

async function readJSON(request, byteLimit, invalidMessage) {
  if (Number(request.headers.get("Content-Length") || 0) > byteLimit) {
    return { response: json({ error: "That payload is too large." }, 413) };
  }
  const reader = request.body?.getReader();
  if (!reader) return { response: json({ error: invalidMessage }, 400) };
  const chunks = [];
  let bytes = 0;
  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > byteLimit) {
        await reader.cancel();
        return { response: json({ error: "That payload is too large." }, 413) };
      }
      chunks.push(value);
    }
    const data = new Uint8Array(bytes);
    let offset = 0;
    for (const chunk of chunks) {
      data.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return { body: JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(data)) };
  } catch {
    return { response: json({ error: invalidMessage }, 400) };
  } finally {
    reader.releaseLock();
  }
}

function csvField(value) {
  let text = String(value);
  // Inspect past whitespace/controls before deciding whether a spreadsheet
  // could interpret the cell as a formula. Preserve ordinary Unicode/CSV data.
  const leadingValue = text.replace(/^[\s\u0000-\u001f\u007f-\u009f]+/u, "");
  if (/^[=+@-]/.test(leadingValue) || /^[\t\r\n]/.test(text)) {
    text = `'${text}`;
  }
  return `"${text.replaceAll('"', '""')}"`;
}

async function secureEqual(left, right) {
  const encoder = new TextEncoder();
  const [leftHash, rightHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  const leftBytes = new Uint8Array(leftHash);
  const rightBytes = new Uint8Array(rightHash);
  return leftBytes.every((byte, index) => byte === rightBytes[index]);
}

function json(body, status, extraHeaders = {}) {
  return Response.json(body, {
    status,
    headers: { ...JSON_HEADERS, ...extraHeaders },
  });
}
