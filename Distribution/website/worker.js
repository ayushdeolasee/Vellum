const JSON_HEADERS = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
};

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

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

    if (url.pathname.startsWith("/api/")) {
      return json({ error: "Not found." }, 404);
    }

    return env.ASSETS.fetch(request);
  },
};

async function createSignup(request, env) {
  const origin = request.headers.get("Origin");
  if (origin && origin !== new URL(request.url).origin) {
    return json({ error: "This form must be submitted from vellum.work." }, 403);
  }

  const contentLength = Number(request.headers.get("Content-Length") || 0);
  if (contentLength > 4096) {
    return json({ error: "That submission is too large." }, 413);
  }

  let body;
  try {
    const rawBody = await request.text();
    if (rawBody.length > 4096) {
      return json({ error: "That submission is too large." }, 413);
    }
    body = JSON.parse(rawBody);
  } catch {
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
  const authorization = request.headers.get("Authorization") || "";
  const expected = env.EXPORT_TOKEN ? `Bearer ${env.EXPORT_TOKEN}` : "";

  if (!expected || !(await secureEqual(authorization, expected))) {
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
  if (normalized.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalized)) return null;
  return normalized;
}

function csvField(value) {
  return `"${String(value).replaceAll('"', '""')}"`;
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
