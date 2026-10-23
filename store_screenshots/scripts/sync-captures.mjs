// Copies the editor captures rendered by test/screenshot_test.dart
// (EDITOR_CAPTURES=true → ../screenshots/editor/<locale>/<scene>-<slot>[-dark].png, slot = phone/tablet/desktop)
// into public/screenshots/<slot>/<locale>/<scene>[-dark].png, where
// app-store-screenshots.json expects them.
//
// Phone captures get a band added on top, filled with their own top row, so
// the iPhone frame's Dynamic Island sits above the app bar instead of on the
// screen title.
//
// Usage: node scripts/sync-captures.mjs
import { promises as fs } from "node:fs";
import path from "node:path";
import sharp from "sharp";

const ROOT = path.resolve(import.meta.dirname, "..");
const SRC = path.resolve(ROOT, "../screenshots/editor");
const DEST = path.join(ROOT, "public/screenshots");
const PHONE_TOP_PAD = 150;

const locales = await fs.readdir(SRC).catch(() => {
  throw new Error(`No captures in ${SRC}; run scripts/store_screenshots.sh first.`);
});
await fs.rm(DEST, { recursive: true, force: true });

let count = 0;
for (const locale of locales) {
  const dir = path.join(SRC, locale);
  if (!(await fs.stat(dir)).isDirectory()) continue;
  for (const file of await fs.readdir(dir)) {
    const m = file.match(/^(.+)-(phone|tablet|desktop)(-dark)?\.png$/);
    if (!m) continue;
    const [, scene, slot, dark = ""] = m;
    const out = path.join(DEST, slot, locale, `${scene}${dark}.png`);
    await fs.mkdir(path.dirname(out), { recursive: true });
    const input = path.join(dir, file);
    if (slot === "phone") {
      const { data } = await sharp(input).extract({ left: 0, top: 0, width: 1, height: 1 }).raw().toBuffer({ resolveWithObject: true });
      await sharp(input)
        .extend({ top: PHONE_TOP_PAD, background: { r: data[0], g: data[1], b: data[2], alpha: 1 } })
        .png()
        .toFile(out);
    } else {
      await fs.copyFile(input, out);
    }
    count++;
  }
}
console.log(`Synced ${count} captures (${locales.join(", ")}) into public/screenshots/.`);
