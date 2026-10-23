// Drivetrain geometry, lifted verbatim from the design system's DrivetrainView.jsx.
// The chain is a real belt solution — external tangents between chainring, active cog
// and the two derailleur pulleys — so moving the chain to another cog re-routes the
// whole loop the way it does on a bike. Pure functions; the DOM lives in drivetrain.js.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.BKGeometry = factory();
})(typeof self !== "undefined" ? self : this, function () {
  const TAU = Math.PI * 2;
  const F = { x: 74, y: 78 };   // chainring centre
  const R = { x: 216, y: 62 };  // cassette centre
  const PR = 7.5;               // pulley radius
  const REAR_MAX = 28;          // largest cog (gear 1)
  const REAR_MIN = 10;          // smallest cog (top gear)
  const TOOTH_PX = 0.78;        // radius per tooth — keeps 34T/50T in true proportion
  const SINGLE_RING = 36;       // one-ring drivetrain (front shifting off)
  const DASH = 8;               // chain link pitch
  const VIEWBOX = "26 28 252 110";

  const r2 = (n) => Math.round(n * 100) / 100;

  // The cage hangs off the active cog and swings down as the chain climbs the stack.
  const guide = (rR) => ({ x: R.x - 2, y: R.y + rR + 12 });
  const tension = (rR) => ({ x: R.x + 12, y: R.y + rR + 32 });

  function rearRadius(gear, gearCount) {
    const g = Math.min(Math.max(1, gear), gearCount);
    const t = gearCount > 1 ? (g - 1) / (gearCount - 1) : 0;
    return REAR_MAX - t * (REAR_MAX - REAR_MIN);
  }

  function cogRadii(gearCount) {
    const out = [];
    for (let i = 1; i <= gearCount; i++) out.push(rearRadius(i, gearCount));
    return out;
  }

  // Chain direction at contact angle t on a circle wound w (+1 with the loop, -1 against).
  const dirAt = (t, w) => (w === 1 ? { x: -Math.sin(t), y: Math.cos(t) } : { x: Math.sin(t), y: -Math.cos(t) });

  // Tangent between two circles honouring each circle's winding.
  function tangent(a, ra, wa, b, rb, wb) {
    const dx = b.x - a.x, dy = b.y - a.y;
    const d = Math.hypot(dx, dy) || 1, th = Math.atan2(dy, dx);
    const ras = ra * wa, rbs = rb * wb;
    const A = Math.acos(Math.max(-1, Math.min(1, (ras - rbs) / d)));
    let best = null;
    for (const phi of [th + A, th - A]) {
      const p1 = { x: a.x + ras * Math.cos(phi), y: a.y + ras * Math.sin(phi) };
      const p2 = { x: b.x + rbs * Math.cos(phi), y: b.y + rbs * Math.sin(phi) };
      const L = Math.hypot(p2.x - p1.x, p2.y - p1.y) || 1;
      const u = { x: (p2.x - p1.x) / L, y: (p2.y - p1.y) / L };
      const da = dirAt(Math.atan2(p1.y - a.y, p1.x - a.x), wa);
      const db = dirAt(Math.atan2(p2.y - b.y, p2.x - b.x), wb);
      const score = u.x * da.x + u.y * da.y + (u.x * db.x + u.y * db.y);
      if (!best || score > best.score) best = { score, p1, p2 };
    }
    return best;
  }

  // Closed chain loop over chainring → cog → guide pulley (counter-wound) → tension.
  function chainPath(rF, rR) {
    const cs = [
      { c: F, r: rF, w: 1 }, { c: R, r: rR, w: 1 },
      { c: guide(rR), r: PR, w: -1 }, { c: tension(rR), r: PR, w: 1 },
    ];
    const segs = cs.map((a, i) => {
      const b = cs[(i + 1) % cs.length];
      return tangent(a.c, a.r, a.w, b.c, b.r, b.w);
    });
    let d = `M ${r2(segs[0].p1.x)} ${r2(segs[0].p1.y)}`;
    for (let i = 0; i < cs.length; i++) {
      const j = (i + 1) % cs.length;
      const k = cs[j];
      const tIn = Math.atan2(segs[i].p2.y - k.c.y, segs[i].p2.x - k.c.x);
      const tOut = Math.atan2(segs[j].p1.y - k.c.y, segs[j].p1.x - k.c.x);
      let delta = (k.w === 1 ? tOut - tIn : tIn - tOut) % TAU;
      if (delta < 0) delta += TAU;
      d += ` L ${r2(segs[i].p2.x)} ${r2(segs[i].p2.y)}`;
      d += ` A ${r2(k.r)} ${r2(k.r)} 0 ${delta > Math.PI ? 1 : 0} ${k.w === 1 ? 1 : 0} ${r2(segs[j].p1.x)} ${r2(segs[j].p1.y)}`;
    }
    return d + " Z";
  }

  // A tooth crown as one dashed circle rather than N ticks.
  function teethDash(r, teeth) {
    const step = (TAU * r) / Math.max(6, teeth);
    return `${r2(step * 0.42)} ${r2(step * 0.58)}`;
  }

  // A linear value v running from `from` down to `to` maps to an integer count that
  // ticks down immediately (v = from → from − 1) and holds `to` at the end.
  function countdownAt(v, from, to) { return Math.max(to, Math.min(from - 1, Math.ceil(v) - 1)); }

  // The same position on the cassette expressed in a different gear count (1-based, clamped).
  function proportionalGear(gear, fromCount, toCount) { return Math.min(toCount, Math.max(1, Math.round(gear * toCount / fromCount))); }

  return { TAU, F, R, PR, REAR_MAX, REAR_MIN, TOOTH_PX, SINGLE_RING, DASH, VIEWBOX,
           r2, guide, tension, rearRadius, cogRadii, tangent, chainPath, teethDash,
           countdownAt, proportionalGear };
});
