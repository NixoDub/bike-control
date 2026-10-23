// Renders the store graphics the editor's decks don't cover, per locale, from
// the app captures in ../screenshots/editor/ (see scripts/store_screenshots.sh):
//
//   feature-graphic   Google Play feature graphic, 1024x500
//   appstore-header   App Store product page header, 3840x1646 (21:9)
//   appstore-search   App Store search results asset, 3840x2560 (3:2)
//
// All three sit on the app's brand band (the brand-blue → deep-teal 120°
// gradient with faint terrain contours, lib/widgets/ui/bk_brand_band.dart) and
// show the app's own UI. Store rules they follow:
//   Play: vibrant ground (no white/black/dark grey), focal point toward the
//     centre but clear of the preview video's play button, no device imagery,
//     no ranking/price/"new"/"free" copy, localized.
//   Apple (asset best practices + guideline 2.3.14): copy and focal art inside
//     the art safe area of Apple's templates, one short phrase, no prices,
//     URLs, © or other platforms, localized, no alpha.
//
// Output: out/graphics/<kind>/<locale>.png (opaque).
// Usage: node scripts/graphics.mjs [locale ...]
import { promises as fs } from "node:fs";
import path from "node:path";
import sharp from "sharp";
import { chromium } from "playwright";

const ROOT = path.resolve(import.meta.dirname, "..");
const CAPTURES = path.resolve(ROOT, "../screenshots/editor");
const OUT = path.join(ROOT, "out/graphics");
// Inlined: a page set from a string may not load file:// fonts.
const FONT = `data:font/ttf;base64,${(await fs.readFile(path.join(ROOT, "public/fonts/imported/barlowcondensed800.ttf"))).toString("base64")}`;

import { COPY } from "./creative-copy.mjs";

// Apple's template art safe areas (store_screenshots/src/lib/constants.ts).
const SAFE = {
  header: { x: 1097, y: 493, w: 1646, h: 661 },
  search: { x: 836, y: 765, w: 2168, h: 1030 },
};

// BkContourPainter's nine nested terrain lines, as an SVG path set in a
// 300x220 box.
function contours() {
  const paths = [];
  for (let k = 0; k < 9; k++) {
    const pts = [];
    const radius = 18 + k * 15;
    for (let s = 0; s <= 72; s++) {
      const t = (s / 72) * Math.PI * 2;
      const r = radius * (1 + 0.1 * Math.sin(3 * t + k * 0.45) + 0.06 * Math.sin(5 * t - k * 0.3) + 0.03 * Math.sin(7 * t + k));
      pts.push(`${(190 + Math.cos(t) * r * 1.25).toFixed(2)},${(110 + Math.sin(t) * r * 0.9).toFixed(2)}`);
    }
    paths.push(`<path d="M${pts.join("L")}Z"/>`);
  }
  return paths.join("");
}
const CONTOURS = contours();
const contourSvg = (style, stroke) =>
  `<svg viewBox="0 0 300 220" overflow="visible" style="position:absolute;overflow:visible;${style}" fill="none" stroke="rgba(255,255,255,0.16)" stroke-width="${stroke}" vector-effect="non-scaling-stroke">${CONTOURS}</svg>`;

// The drivetrain card of the dark Virtual shifting capture, found by scanning
// for the card's lighter fill against the page ground.
async function drivetrainCard(locale) {
  const file = path.join(CAPTURES, locale, "virtualshifting-settings-desktop-dark.png");
  const { data, info } = await sharp(file).removeAlpha().raw().toBuffer({ resolveWithObject: true });
  const at = (x, y) => {
    const i = (y * info.width + x) * 3;
    return data[i] + data[i + 1] + data[i + 2];
  };
  const ground = at(50, Math.floor(info.height / 2));
  const lighter = (x, y) => at(x, y) > ground + 10;
  // Rows: first card row below the app bar, then the card's bottom edge.
  const x0 = Math.floor(info.width / 3);
  let top = 220;
  while (!lighter(x0, top)) top++;
  let bottom = top + 40;
  while (bottom < info.height && lighter(x0, bottom)) bottom++;
  const row = top + 300;
  let left = 0;
  while (!lighter(left, row)) left++;
  let right = info.width - 1;
  while (!lighter(right, row)) right--;
  const buf = await sharp(file).extract({ left, top, width: right - left + 1, height: bottom - top }).png().toBuffer();
  return `data:image/png;base64,${buf.toString("base64")}`;
}

async function capture(locale, name) {
  const buf = await fs.readFile(path.join(CAPTURES, locale, `${name}.png`));
  return `data:image/png;base64,${buf.toString("base64")}`;
}

const page = (w, h, body) => `<!doctype html><html><head><meta charset="utf-8"><style>
@font-face { font-family: Display; src: url("${FONT}"); font-weight: 800; }
html, body { margin: 0; width: ${w}px; height: ${h}px; overflow: hidden; }
.ground { position: absolute; inset: 0; overflow: hidden; background: linear-gradient(120deg, #0E74B7 0%, #0B7478 100%); }
.headline { font-family: Display; font-weight: 800; text-transform: uppercase; color: #fff; white-space: pre-line; text-wrap: balance; margin: 0; }
.card { position: absolute; border-radius: var(--r); box-shadow: 0 var(--s) calc(var(--s) * 2.5) rgba(4, 18, 28, 0.45); }
.phone { position: absolute; background: #0b0c0e; border-radius: var(--r); padding: var(--b); box-shadow: 0 var(--s) calc(var(--s) * 2.5) rgba(4, 18, 28, 0.45); }
.phone img { display: block; width: 100%; border-radius: calc(var(--r) - var(--b)); }
</style></head><body><div class="ground">${body}</div></body></html>`;

function featureGraphic(locale, card) {
  // 1024x500. Copy left, UI right, the middle left open for the play button.
  return page(1024, 500, `
    ${contourSvg("right:-220px;top:-170px;width:900px;height:660px", 1.4)}
    ${contourSvg("left:-260px;bottom:-300px;width:640px;height:470px", 1.2)}
    <div style="position:absolute;left:60px;top:0;bottom:0;width:420px;display:flex;flex-direction:column;justify-content:center;">
      <p class="headline" data-lines="2" style="font-size:58px;line-height:0.98;">${COPY.feature[locale]}</p>
    </div>
    <img class="card" src="${card}" style="--r:18px;--s:14px;right:48px;top:50%;width:440px;transform:translateY(-50%);">`);
}

function header(locale, card) {
  const s = SAFE.header;
  const gap = 70;
  const textW = 760;
  const cardW = s.w - textW - gap;
  return page(3840, 1646, `
    ${contourSvg("right:-700px;top:-560px;width:2700px;height:1980px", 1.1)}
    ${contourSvg("left:-760px;bottom:-900px;width:2200px;height:1610px", 1.1)}
    <div style="position:absolute;left:${s.x}px;top:${s.y}px;width:${textW}px;height:${s.h}px;display:flex;align-items:center;">
      <p class="headline" data-lines="4" style="font-size:112px;line-height:0.96;">${COPY.header[locale]}</p>
    </div>
    <img class="card" src="${card}" style="--r:34px;--s:34px;left:${s.x + textW + gap}px;top:${s.y + s.h / 2}px;width:${cardW}px;transform:translateY(-50%);">`);
}

function search(locale, ride, shifting) {
  const s = SAFE.search;
  const bezel = 18;
  const phoneH = s.h; // the phones fill the safe area's height
  const phoneW = Math.round((phoneH - 2 * bezel) * (1100 / 2390) + 2 * bezel);
  const gap = 56;
  const textW = s.w - 2 * phoneW - gap - 120;
  const phone = (left, src) =>
    `<div class="phone" style="--r:64px;--b:${bezel}px;--s:34px;left:${left}px;top:${s.y}px;width:${phoneW - 2 * bezel}px;"><img src="${src}"></div>`;
  return page(3840, 2560, `
    ${contourSvg("right:-900px;top:-700px;width:3200px;height:2350px", 1.1)}
    ${contourSvg("left:-900px;bottom:-1000px;width:2600px;height:1900px", 1.1)}
    <div style="position:absolute;left:${s.x}px;top:${s.y}px;width:${textW}px;height:${s.h}px;display:flex;align-items:center;">
      <p class="headline" data-lines="5" style="font-size:150px;line-height:0.95;">${COPY.search[locale]}</p>
    </div>
    ${phone(s.x + s.w - 2 * phoneW - gap, ride)}
    ${phone(s.x + s.w - phoneW, shifting)}`);
}

const locales = process.argv.length > 2 ? process.argv.slice(2) : (await fs.readdir(CAPTURES)).sort();
const browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL ?? "chrome" });
try {
  for (const locale of locales) {
    const card = await drivetrainCard(locale);
    const ride = await capture(locale, "device-phone");
    const shifting = await capture(locale, "virtualshifting-settings-phone-dark");
    const jobs = [
      ["feature-graphic", 1024, 500, featureGraphic(locale, card)],
      ["appstore-header", 3840, 1646, header(locale, card)],
      ["appstore-search", 3840, 2560, search(locale, ride, shifting)],
    ];
    for (const [kind, w, h, html] of jobs) {
      const pg = await browser.newPage({ viewport: { width: w, height: h } });
      await pg.setContent(html, { waitUntil: "load" });
      await pg.evaluate(async () => {
        await document.fonts.ready;
        // Longer languages shrink until the headline fits its line budget.
        for (const el of document.querySelectorAll(".headline[data-lines]")) {
          const lines = Number(el.dataset.lines);
          let size = parseFloat(getComputedStyle(el).fontSize);
          const lh = parseFloat(el.style.lineHeight);
          while (el.getBoundingClientRect().height > size * lh * lines + 2 && size > 10) {
            size *= 0.97;
            el.style.fontSize = `${size}px`;
          }
        }
      });
      const shot = await pg.screenshot({ type: "png" });
      await pg.close();
      const out = path.join(OUT, kind, `${locale}.png`);
      await fs.mkdir(path.dirname(out), { recursive: true });
      await sharp(shot).removeAlpha().png().toFile(out);
    }
    console.log(`graphics: ${locale}`);
  }
} finally {
  await browser.close();
}
