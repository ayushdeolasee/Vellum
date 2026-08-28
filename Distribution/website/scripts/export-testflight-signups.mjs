import { execFileSync } from "node:child_process";

const token = execFileSync(
  "/usr/bin/security",
  ["find-generic-password", "-s", "vellum.work.testflight-export", "-w"],
  { encoding: "utf8" },
).trim();

const response = await fetch("https://vellum.work/api/testflight-signups.csv", {
  headers: { Authorization: `Bearer ${token}` },
});

if (!response.ok) {
  throw new Error(`TestFlight export failed with HTTP ${response.status}.`);
}

process.stdout.write(await response.text());
