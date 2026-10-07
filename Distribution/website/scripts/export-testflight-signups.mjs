import { execFileSync } from "node:child_process";

const token = execFileSync(
  "/usr/bin/security",
  ["find-generic-password", "-s", "vellum.work.testflight-export", "-w"],
  { encoding: "utf8" },
).trim();

const controller = new AbortController();
const timeout = setTimeout(() => controller.abort(), 30_000);
let csv;

try {
  const response = await fetch("https://vellum.work/api/testflight-signups.csv", {
    headers: { Authorization: `Bearer ${token}` },
    signal: controller.signal,
  });

  if (!response.ok) {
    throw new Error(`TestFlight export failed with HTTP ${response.status}.`);
  }

  csv = await response.text();
} catch (error) {
  if (controller.signal.aborted) {
    throw new Error("TestFlight export timed out after 30 seconds.");
  }
  throw error;
} finally {
  clearTimeout(timeout);
}

process.stdout.write(csv);
