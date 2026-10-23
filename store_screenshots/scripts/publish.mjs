// Copies the store sizes of the exported decks (out/, see export.mjs) into the
// committed ../screenshots/store/<locale>/<slot>/, where
// scripts/prepare_store_screenshots.sh picks them up. They are compressed on
// the way, because they are committed: palette PNGs for the App Store, JPEGs
// for Google Play (which takes JPEG or 24-bit PNG, not palette PNGs).
//
// The Microsoft Store listing reuses the androidTablet10 set (2560x1600).
//
// Usage: node scripts/publish.mjs
import { promises as fs } from "node:fs";
import path from "node:path";
import sharp from "sharp";

const ROOT = path.resolve(import.meta.dirname, "..");
const OUT = path.join(ROOT, "out");
const DEST = path.resolve(ROOT, "../screenshots/store");

// slot -> [export dir, format]. iPhone 1284x2778 is a 6.5" size
// (APP_IPHONE_65), iPad 2064x2752 a 13" one (APP_IPAD_PRO_3GEN_129),
// 2880x1800 a Mac App Store one (APP_DESKTOP).
const SLOTS = {
  iphone65: ["ios/iphone/1284x2778", "png"],
  ipad129: ["ios/ipad/2064x2752", "png"],
  desktop: ["macos/mac/2880x1800", "png"],
  android: ["android/android/1080x1920", "jpg"],
  androidTablet10: ["android/android-10/2560x1600", "jpg"],
  androidTablet7: ["android/android-7/1920x1200", "jpg"],
  featureGraphic: ["android/feature-graphic/1024x500", "jpg"],
};

let count = 0;
for (const [slot, [dir, format]] of Object.entries(SLOTS)) {
  const src = path.join(OUT, dir);
  const locales = await fs.readdir(src).catch(() => []);
  for (const locale of locales) {
    const dest = path.join(DEST, locale, slot);
    await fs.rm(dest, { recursive: true, force: true });
    await fs.mkdir(dest, { recursive: true });
    for (const file of (await fs.readdir(path.join(src, locale))).filter((f) => f.endsWith(".png")).sort()) {
      const img = sharp(path.join(src, locale, file)).flatten({ background: "#ffffff" });
      const name = file.replace(/\.png$/, `.${format}`);
      if (format === "png") await img.png({ palette: true, quality: 90, effort: 10 }).toFile(path.join(dest, name));
      else await img.jpeg({ quality: 92, mozjpeg: true }).toFile(path.join(dest, name));
      count++;
    }
  }
}
console.log(`Published ${count} store screenshots into screenshots/store/.`);
