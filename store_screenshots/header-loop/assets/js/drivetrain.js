// DOM half of the drivetrain: builds the SVG once, then `render()` writes every
// attribute from a plain `state` object. GSAP tweens the state; nothing here
// reads a clock, so the same state always yields the same frame.
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory(require("./drivetrain-geometry.js"));
  else root.BKDrivetrain = factory(root.BKGeometry);
})(typeof self !== "undefined" ? self : this, function (G) {
  const NS = "http://www.w3.org/2000/svg";
  // Colours of the app's dark drivetrain card (BkTheme dark): the card fill
  // shows through the chain's link gaps, the active cog in lifted brand blue.
  const C = {
    fg: "#FFFFFF", muted: "#8A8A93", border: "#4A4A4A", panel: "#1B1F25", brand: "#4DA9E8",
  };

  function el(tag, attrs) {
    const e = document.createElementNS(NS, tag);
    for (const k in attrs) e.setAttribute(k, attrs[k]);
    return e;
  }

  function createDrivetrain(svg, opts) {
    const p = (opts && opts.prefix) || "dt";
    const id = (n) => `${p}-${n}`;
    const state = {
      gear: 12, gearCount: 24, rRear: G.rearRadius(12, 24), rFront: G.SINGLE_RING,
      frontShift: 0, largeRing: 0, smallTeeth: 34, largeTeeth: 50, travel: 0, pulse: 1,
      cogsAlpha: 1,
    };

    svg.setAttribute("viewBox", G.VIEWBOX);
    svg.setAttribute("overflow", "visible");

    const cogs = svg.appendChild(el("g", { id: id("cogs") }));
    const cassette = svg.appendChild(el("g", { id: id("cassette") }));
    cassette.appendChild(el("line", { x1: G.R.x - 7, y1: G.R.y, x2: G.R.x + 7, y2: G.R.y, stroke: C.border, "stroke-width": 1.4 }));
    cassette.appendChild(el("line", { x1: G.R.x, y1: G.R.y - 7, x2: G.R.x, y2: G.R.y + 7, stroke: C.border, "stroke-width": 1.4 }));
    const pulse = svg.appendChild(el("circle", { id: id("pulse"), cx: G.R.x, cy: G.R.y, r: 0, fill: "none", stroke: C.brand, "stroke-width": 2, opacity: 0 }));
    const activeTeeth = svg.appendChild(el("circle", { id: id("active-teeth"), cx: G.R.x, cy: G.R.y, fill: "none", stroke: C.brand, "stroke-width": 2.8 }));
    const activeCog = svg.appendChild(el("circle", { id: id("active-cog"), cx: G.R.x, cy: G.R.y, fill: "none", stroke: C.brand, "stroke-width": 1.6 }));
    svg.appendChild(el("circle", { cx: G.R.x, cy: G.R.y, r: 4.5, fill: C.panel, stroke: C.border, "stroke-width": 1 }));

    const ghostTeeth = svg.appendChild(el("circle", { id: id("ghost-teeth"), cx: G.F.x, cy: G.F.y, fill: "none", stroke: C.border, "stroke-width": 2.4 }));
    const ghostRing = svg.appendChild(el("circle", { id: id("ghost-ring"), cx: G.F.x, cy: G.F.y, fill: "none", stroke: C.border, "stroke-width": 1.2 }));

    const cageA = svg.appendChild(el("line", { id: id("cage-a"), stroke: C.muted, "stroke-width": 2.6, "stroke-linecap": "round" }));
    const cageB = svg.appendChild(el("line", { id: id("cage-b"), stroke: C.muted, "stroke-width": 2.6, "stroke-linecap": "round" }));

    const chain = svg.appendChild(el("path", { id: id("chain"), fill: "none", stroke: C.fg, "stroke-width": 4.2, "stroke-linejoin": "round", opacity: 0.82 }));
    const links = svg.appendChild(el("path", { id: id("chain-links"), fill: "none", stroke: C.panel, "stroke-width": 1.5, "stroke-dasharray": `${G.DASH * 0.3} ${G.DASH * 0.7}`, "stroke-linecap": "round" }));

    const guide = svg.appendChild(el("g", { id: id("guide") }));
    guide.appendChild(el("circle", { r: G.PR - 1.6, fill: C.panel, stroke: C.muted, "stroke-width": 1.3 }));
    guide.appendChild(el("circle", { r: 1.6, fill: C.muted }));
    const tension = svg.appendChild(el("g", { id: id("tension") }));
    tension.appendChild(el("circle", { r: G.PR - 1.6, fill: C.panel, stroke: C.muted, "stroke-width": 1.3 }));
    tension.appendChild(el("circle", { r: 1.6, fill: C.muted }));

    const frontTeeth = svg.appendChild(el("circle", { id: id("front-teeth"), cx: G.F.x, cy: G.F.y, fill: "none", stroke: C.fg, "stroke-width": 2.8, opacity: 0.9 }));
    const frontRing = svg.appendChild(el("circle", { id: id("front-ring"), cx: G.F.x, cy: G.F.y, fill: "none", stroke: C.fg, "stroke-width": 1.6, opacity: 0.9 }));
    const spider = svg.appendChild(el("g", { id: id("spider") }));
    const spokes = [];
    for (let i = 0; i < 5; i++) spokes.push(spider.appendChild(el("line", { x1: G.F.x, y1: G.F.y, stroke: C.border, "stroke-width": 2.4, "stroke-linecap": "round" })));
    svg.appendChild(el("circle", { cx: G.F.x, cy: G.F.y, r: 13, fill: C.panel }));
    const hubDot = svg.appendChild(el("circle", { id: id("hub-dot"), cx: G.F.x, cy: G.F.y, r: 4.5, fill: "none", stroke: C.border, "stroke-width": 1 }));
    const hubText = svg.appendChild(el("text", { id: id("hub-text"), x: G.F.x, y: G.F.y + 4.5, "text-anchor": "middle", "font-family": "Inter, sans-serif", "font-size": 12.5, "font-weight": 700, fill: C.fg }));

    let builtCount = -1;
    function rebuildCogs() {
      const dense = state.gearCount > 14;
      const radii = G.cogRadii(state.gearCount);
      const kids = radii.map((rr, i) => {
        const ridge = dense && i % 4 === 0;
        return el("circle", { cx: G.R.x, cy: G.R.y, r: G.r2(rr), fill: "none", stroke: C.border,
          "stroke-width": dense ? (ridge ? 0.7 : 0.4) : 1.3,
          opacity: dense ? (ridge ? 0.95 : 0.8) : 0.95 });
      });
      cogs.replaceChildren(...kids);
      builtCount = state.gearCount;
    }

    function render() {
      const s = state;
      if (builtCount !== s.gearCount) rebuildCogs();
      cogs.setAttribute("opacity", G.r2(s.cogsAlpha));
      const bigR = s.largeTeeth * G.TOOTH_PX, smallR = s.smallTeeth * G.TOOTH_PX;
      const rearTeeth = Math.max(9, Math.round(s.rRear / G.TOOTH_PX));
      const frontT = s.frontShift > 0.5 ? (s.largeRing > 0.5 ? s.largeTeeth : s.smallTeeth) : Math.round(G.SINGLE_RING / G.TOOTH_PX);

      // rear
      activeTeeth.setAttribute("r", G.r2(s.rRear + 1));
      activeTeeth.setAttribute("stroke-dasharray", G.teethDash(s.rRear + 1, rearTeeth));
      activeCog.setAttribute("r", G.r2(s.rRear));

      // landing ripple
      const vis = s.pulse < 1 && s.pulse >= 0;
      pulse.setAttribute("r", G.r2(s.rRear + 3 + 9 * (vis ? s.pulse : 0)));
      pulse.setAttribute("opacity", vis ? G.r2(0.8 * (1 - s.pulse)) : 0);

      // cage
      const gp = G.guide(s.rRear), tp = G.tension(s.rRear);
      cageA.setAttribute("x1", G.R.x + 20); cageA.setAttribute("y1", G.R.y + 6);
      cageA.setAttribute("x2", G.r2(gp.x)); cageA.setAttribute("y2", G.r2(gp.y));
      cageB.setAttribute("x1", G.r2(gp.x)); cageB.setAttribute("y1", G.r2(gp.y));
      cageB.setAttribute("x2", G.r2(tp.x)); cageB.setAttribute("y2", G.r2(tp.y));
      guide.setAttribute("transform", `translate(${G.r2(gp.x)} ${G.r2(gp.y)})`);
      tension.setAttribute("transform", `translate(${G.r2(tp.x)} ${G.r2(tp.y)})`);

      // chain
      const d = G.chainPath(s.rFront, s.rRear);
      chain.setAttribute("d", d);
      links.setAttribute("d", d);
      // linkTravel (when set) is the travel rounded to whole links, so a loop closes on a link.
      links.setAttribute("stroke-dashoffset", G.r2(-((s.linkTravel ?? s.travel) % G.DASH)));

      // front: active ring + ghost (inactive) ring
      frontTeeth.setAttribute("r", G.r2(s.rFront + 1));
      frontTeeth.setAttribute("stroke-dasharray", G.teethDash(s.rFront + 1, frontT));
      frontRing.setAttribute("r", G.r2(s.rFront));
      const ghostR = s.largeRing > 0.5 ? smallR : bigR;
      const ghostT = s.largeRing > 0.5 ? s.smallTeeth : s.largeTeeth;
      ghostRing.setAttribute("r", G.r2(ghostR));
      ghostTeeth.setAttribute("r", G.r2(ghostR + 1));
      ghostTeeth.setAttribute("stroke-dasharray", G.teethDash(ghostR + 1, ghostT));
      ghostRing.setAttribute("opacity", G.r2(0.75 * s.frontShift));
      ghostTeeth.setAttribute("opacity", G.r2(0.75 * s.frontShift));
      hubText.textContent = s.frontShift > 0.5 ? `${frontT}T` : "";
      hubDot.setAttribute("opacity", s.frontShift > 0.5 ? 0 : 1);

      // rotation from chain travel (px): both rings turn at their true relative speeds
      const degF = (s.travel / (G.TAU * s.rFront)) * 360;
      const degR = (s.travel / (G.TAU * Math.max(4, s.rRear))) * 360;
      spider.setAttribute("transform", `rotate(${G.r2(degF % 360)} ${G.F.x} ${G.F.y})`);
      cassette.setAttribute("transform", `rotate(${G.r2(degR % 360)} ${G.R.x} ${G.R.y})`);
      for (let i = 0; i < 5; i++) {
        const a = (i / 5) * G.TAU - Math.PI / 2;
        spokes[i].setAttribute("x2", G.r2(G.F.x + Math.cos(a) * (s.rFront - 5)));
        spokes[i].setAttribute("y2", G.r2(G.F.y + Math.sin(a) * (s.rFront - 5)));
      }
    }

    render();
    return { state, render };
  }

  return { createDrivetrain };
});
