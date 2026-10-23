// Exports every deck in app-store-screenshots.json through the editor's own
// "Export bundle" button, headless, and unpacks the bundles into
// out/<platform>/<device>/<WxH>/<locale>/NN-<layout>.png.
//
// Starts `next dev` on a spare port unless EDITOR_URL points at a running
// editor. app-store-screenshots.json is restored byte-for-byte afterwards
// (the export switches its active device, and the editor autosaves).
//
// Usage: node scripts/export.mjs [deck ...]   (default: every deck below)
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import path from "node:path";
import JSZip from "jszip";
import { chromium } from "playwright";

const ROOT = path.resolve(import.meta.dirname, "..");
const PROJECT = path.join(ROOT, "app-store-screenshots.json");
const OUT = path.join(ROOT, "out");

// device id → orientation the deck is laid out in.
const DECKS = {
  iphone: "portrait",
  android: "portrait",
  mac: "landscape",
  "android-10": "landscape",
  "android-7": "landscape",
  "feature-graphic": "portrait",
};
const decks = process.argv.length > 2 ? process.argv.slice(2) : Object.keys(DECKS);
for (const d of decks) if (!(d in DECKS)) throw new Error(`Unknown deck "${d}" (known: ${Object.keys(DECKS).join(", ")})`);

const original = await fs.readFile(PROJECT, "utf8");
let server;
let url = process.env.EDITOR_URL;
try {
  if (!url) {
    const port = 3100 + Math.floor(Math.random() * 800);
    url = `http://localhost:${port}`;
    server = spawn("npx", ["next", "dev", "-p", String(port)], { cwd: ROOT, stdio: "ignore", detached: true });
    for (let i = 0; ; i++) {
      if (i > 120) throw new Error("next dev did not come up");
      try {
        if ((await fetch(`${url}/api/project`)).ok) break;
      } catch {}
      await new Promise((r) => setTimeout(r, 1000));
    }
  }

  await fs.rm(OUT, { recursive: true, force: true });
  const browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL ?? "chrome" });
  try {
    for (const device of decks) {
      const project = JSON.parse(original);
      project.device = device;
      project.orientation = DECKS[device];
      await fs.writeFile(PROJECT, JSON.stringify(project, null, 2));

      const ctx = await browser.newContext({ acceptDownloads: true, viewport: { width: 1800, height: 1100 } });
      const page = await ctx.newPage();
      await page.goto(url, { waitUntil: "networkidle", timeout: 120_000 });
      await page.waitForTimeout(3000);
      const [download] = await Promise.all([
        page.waitForEvent("download", { timeout: 300_000 }),
        page.getByRole("button", { name: "Export bundle", exact: true }).click(),
      ]);
      const zip = await JSZip.loadAsync(await fs.readFile(await download.path()));
      let files = 0;
      for (const [name, entry] of Object.entries(zip.files)) {
        if (entry.dir || !name.endsWith(".png")) continue;
        const dest = path.join(OUT, name);
        await fs.mkdir(path.dirname(dest), { recursive: true });
        await fs.writeFile(dest, await entry.async("nodebuffer"));
        files++;
      }
      console.log(`${device}: ${files} PNGs`);
      await ctx.close();
    }
  } finally {
    await browser.close();
  }
} finally {
  await fs.writeFile(PROJECT, original);
  if (server) process.kill(-server.pid);
}
console.log(`Exported to ${path.relative(process.cwd(), OUT) || "."}/`);
