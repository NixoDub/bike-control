// Replaces the Microsoft Store listing's desktop screenshots through Partner
// Center, driven by Playwright on a logged-in Chrome profile (the Store has no
// listing-image API we can reach without an Azure AD app).
//
//   node scripts/msstore-upload.mjs [--submit] [--dry-run] [file.png ...]
//
// Files default to the 10" landscape deck (out/android/android-10/2560x1600/en,
// PNG; the Store takes PNG only, 1366x768 and up). The listing is English only.
//
// Steps: open the product overview; reuse a draft update or start one; open the
// draft's English listing; replace the desktop screenshots in order (each tile
// has its own file input; extra files go into the add card, extra tiles are
// deleted); Save. With --submit, submit for certification. --dry-run changes
// nothing: it stops before Save, and stops before starting an update when no
// draft exists.
//
// Partner Center quirks this works around:
//   - Its <he-button> web components ignore element clicks, so buttons are
//     clicked by position (page.mouse on the bounding box).
//   - "Submit for certification" first only validates; once the validation
//     poll reports done, a second click sends the submission.
//   - Headless Chrome needs a normal user agent, or Akamai answers "Access
//     Denied".
// The profile is ~/.cache/bikecontrol-partnercenter (override with
// PARTNER_CENTER_PROFILE); log in there once with a headed run if the session
// has expired. Close any other Chrome using that profile first.
import { promises as fs } from "node:fs";
import os from "node:os";
import path from "node:path";
import { chromium } from "playwright";

const PRODUCT = "9NP42GS03Z26";
const OVERVIEW = `https://partner.microsoft.com/en-us/dashboard/products/${PRODUCT}/overview`;
const ROOT = path.resolve(import.meta.dirname, "..");
const DEFAULT_DIR = path.join(ROOT, "out/android/android-10/2560x1600/en");

const args = process.argv.slice(2);
const submit = args.includes("--submit");
const dryRun = args.includes("--dry-run");
let files = args.filter((a) => !a.startsWith("--")).map((f) => path.resolve(f));
if (files.length === 0) {
  files = (await fs.readdir(DEFAULT_DIR).catch(() => [])).filter((f) => f.endsWith(".png")).sort().map((f) => path.join(DEFAULT_DIR, f));
}
if (files.length === 0) throw new Error(`No screenshots: export the decks first (${DEFAULT_DIR}).`);
for (const f of files) if (!f.endsWith(".png")) throw new Error(`Partner Center takes PNG only: ${f}`);

const ctx = await chromium.launchPersistentContext(process.env.PARTNER_CENTER_PROFILE ?? path.join(os.homedir(), ".cache/bikecontrol-partnercenter"), {
  channel: "chrome",
  headless: !process.env.HEADED,
  viewport: { width: 1500, height: 1200 },
  userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36",
  args: ["--disable-blink-features=AutomationControlled"],
});
const page = ctx.pages()[0] ?? (await ctx.newPage());

const button = (label) => page.locator("he-button, button").filter({ hasText: new RegExp(`^\\s*${label}\\s*$`) }).first();
async function press(label) {
  const box = await button(label).boundingBox();
  if (!box) throw new Error(`No "${label}" button on ${page.url()}`);
  await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
}
const status = async () => ((await page.innerText("body")).match(/Product update: ([^\n(]*)/) ?? [])[1]?.trim();
async function overview() {
  await page.goto(OVERVIEW, { waitUntil: "domcontentloaded", timeout: 90_000 });
  await page.waitForTimeout(10_000);
  if (/login|signin/i.test(page.url())) throw new Error("Partner Center session expired: log in once with HEADED=1.");
}

try {
  await overview();
  let state = await status();
  if (state && !/In draft/i.test(state)) throw new Error(`The current update is "${state}"; it can't be edited until it is published.`);
  if (!state && dryRun) {
    console.log("Dry run: no update in progress, and starting one is a change, so stopping here.");
    process.exitCode = 0;
  } else if (!state) {
    console.log("Starting an update");
    await press("Start update");
    await page.waitForTimeout(15_000);
    state = await status();
    if (!/In draft/i.test(state ?? "")) throw new Error(`Starting an update left it as "${state}".`);
  }

  if (!(await status())) throw Object.assign(new Error("stop"), { quiet: true });

  // The draft's English listing.
  await page.getByText("Languages supported in packages", { exact: true }).first().click();
  await page.waitForTimeout(6_000);
  await page.getByText("English (United States)", { exact: true }).first().click();
  await page.waitForTimeout(15_000);
  if (!/\/listings/.test(page.url())) throw new Error(`Did not reach the English listing (${page.url()}).`);
  console.log(`Listing: ${page.url()}`);

  const tiles = page.locator(".screenshot-swap-container");
  const existing = await tiles.count();
  console.log(`Desktop screenshots: ${existing} now, ${files.length} new`);
  for (let i = 0; i < Math.min(existing, files.length); i++) {
    await tiles.nth(i).locator("input[type=file]").setInputFiles(files[i]);
    await page.waitForTimeout(6_000);
  }
  for (let i = existing; i < files.length; i++) {
    // The desktop panel's add card: the first upload input outside a tile.
    await page.locator(".clear-upload-card input[type=file]").first().setInputFiles(files[i]);
    await page.waitForTimeout(6_000);
  }
  for (let i = existing - 1; i >= files.length; i--) {
    const del = tiles.nth(i).locator("he-button").first();
    const box = await del.boundingBox();
    await page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
    await page.waitForTimeout(3_000);
  }
  const now = await tiles.count();
  if (now !== files.length) throw new Error(`Expected ${files.length} screenshots, the listing shows ${now}.`);

  if (dryRun) {
    console.log("Dry run: not saving. The draft keeps its previous screenshots.");
  } else {
    await page.getByRole("button", { name: "Save", exact: true }).last().click();
    await page.waitForTimeout(15_000);
    console.log(`Saved; update is "${await status()}"`);
    if (submit) {
      let validated = false;
      page.on("response", async (r) => {
        if (/\/validate\?token=/.test(r.url())) {
          try {
            if (/"hasResourceLinks":true/.test(await r.text())) validated = true;
          } catch {}
        }
      });
      await overview();
      await press("Submit for certification");
      for (let i = 0; i < 40 && !validated; i++) await page.waitForTimeout(3_000);
      if (!validated) throw new Error("Validation did not finish; nothing was submitted.");
      await press("Submit for certification");
      await page.waitForTimeout(30_000);
      console.log(`Submitted; update is "${await status()}"`);
    }
  }
} catch (e) {
  if (!e.quiet) throw e;
} finally {
  await ctx.close();
}
