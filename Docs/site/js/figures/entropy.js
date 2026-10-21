/*
 * Two kinds of sure: one Thread's two stored entropies over a real answer, and at the cursor the
 * distribution behind each. H_lm is the claim (its own reed over the vocabulary; the log keeps the
 * entropy and the chosen token's probability). H_knn is the evidence (softmax(score/τ) over its 16
 * hits, grouped by the token each hit says comes next), recomputed here from the logged hits.
 */
(function () {
  "use strict";
  var B = window.Braid, M = B.model, h = B.h, s = B.s, fmt = B.fmt, f32 = Math.fround;

  function strandIndex(se, name) {
    if (name) { var i = se.strands.findIndex(function (x) { return x.name === name; }); if (i >= 0) return i; }
    var roy = se.royalties().strands.filter(function (l) { return !l.commons; }).sort(function (a, b) { return b.share - a.share; });
    return se.strands.findIndex(function (x) { return x.name === roy[0].name; });
  }

  function evidenceBars(se, t, step, tau) {
    var strand = se.strands[t], thread = se.threads[strand.name], rec = step.thr[t];
    var knn = M.Mixer.knn(rec.hits, tau);
    var groups = [];
    knn.mass.forEach(function (mass, value) {
      var first = rec.hits.find(function (hh) { return hh[2] === value; });
      groups.push({ value: value, mass: mass, text: thread.text(first[3], first[4]), count: rec.hits.filter(function (hh) { return hh[2] === value; }).length });
    });
    groups.sort(function (a, b) { return b.mass - a.mass; });
    var shown = groups.slice(0, 8), rest = groups.slice(8).reduce(function (acc, g) { return acc + g.mass; }, 0);
    var W = 420, rowH = 22, L = 112, R = 70, H = (shown.length + (rest > 0 ? 1 : 0)) * rowH + 8;
    var x = B.chart.scale(0, 1, L, W - R);
    var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "Where the 16 hits say the next token comes from" });
    shown.forEach(function (g, i) {
      var y = 4 + i * rowH, chosen = g.value === step.tok;
      svg.appendChild(s("text", { class: "t-mono t-small" + (chosen ? " t-strong" : ""), x: L - 8, y: y + 14, "text-anchor": "end" }, fmt.tok(g.text).slice(0, 16)));
      var gg = s("g", { class: se.strandClass(t) });
      gg.appendChild(s("rect", { x: L, y: y + 3, width: Math.max(1, x(g.mass) - L), height: rowH - 8, rx: 2, style: "fill: var(--s); opacity: " + (chosen ? 1 : 0.45) }));
      svg.appendChild(gg);
      svg.appendChild(s("text", { class: "t-small t-mono", x: Math.max(1, x(g.mass)) + 5, y: y + 14 }, fmt.p(g.mass) + (g.count > 1 ? " · " + g.count + " hits" : "")));
    });
    if (rest > 0) svg.appendChild(s("text", { class: "t-small", x: L - 8, y: 4 + shown.length * rowH + 14, "text-anchor": "end" }, (groups.length - 8) + " more"));
    if (rest > 0) svg.appendChild(s("text", { class: "t-small t-mono", x: L + 5, y: 4 + shown.length * rowH + 14 }, fmt.p(rest)));
    return { svg: svg, entropy: knn.entropy, groups: groups.length };
  }

  function claimBars(se, t, step) {
    var c = se.commons, W = 420, L = 112, R = 70, rowH = 26, max = 8;
    var rows = [{ t: t, label: se.strands[t].label }];
    if (c !== null && c !== t) rows.push({ t: c, label: "the commons" });
    var x = B.chart.scale(0, max, L, W - R), H = rows.length * rowH + 22;
    var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "How sure each reed is of the next token" });
    rows.forEach(function (r, i) {
      var rec = step.thr[r.t], y = 4 + i * rowH, v = rec.Hlm === undefined ? null : f32(rec.Hlm);
      svg.appendChild(s("text", { class: "t-small", x: L - 8, y: y + 15, "text-anchor": "end" }, r.label));
      if (v === null) return;
      var gg = s("g", { class: se.strandClass(r.t) });
      gg.appendChild(s("rect", { x: L, y: y + 4, width: Math.max(1, x(v) - L), height: rowH - 10, rx: 2, style: "fill: var(--s)" }));
      svg.appendChild(gg);
      svg.appendChild(s("text", { class: "t-small t-mono", x: x(v) + 5, y: y + 15 }, fmt.n(v, 2) + " · p " + fmt.p(f32(rec.plm))));
    });
    [0, 2, 4, 6, 8].forEach(function (v) { svg.appendChild(s("text", { class: "t-small", x: x(v), y: H - 4, "text-anchor": "middle", style: "fill: var(--faint)" }, String(v))); });
    return svg;
  }

  B.define("entropy", {
    title: "Two kinds of sure",
    params: { s: { default: "joltvault" }, strand: { default: null }, i: { type: "int", default: 11 }, tau: { type: "number", default: null }, whatif: { default: "no", link: false }, from: { type: "int", default: 1, link: false } },
    render: function (body, state, ctx) {
      var se = B.session(state.s), t = strandIndex(se, state.strand), strand = se.strands[t];
      var steps = se.shared.filter(function (st) { return st.thr && st.i >= state.from; });
      var pos = steps.findIndex(function (st) { return st.i === state.i; });
      if (pos < 0) pos = 0;
      var step = steps[pos], tau = state.tau === null ? f32(strand.tau) : state.tau;
      var controls = [B.slider("Token", pos, 0, steps.length - 1, 1, function (v) { ctx.set({ i: steps[v].i }); }, function (v) { return fmt.tok(steps[v].txt); })];
      if (state.whatif === "tau") controls.push(B.slider("What if τ were", tau, 0.01, 0.5, 0.01, function (v) { ctx.set({ tau: v }); }, function (v) { return v.toFixed(2); }), h("span", { class: "what-if" }, "Braid's τ is " + f32(strand.tau).toFixed(2) + " and is not a control"));
      body.appendChild(h("div", { class: "fig-controls" }, controls));
      var labels = steps.map(function (st) { return B.fmt.raw(st.txt).trim().slice(0, 7); });
      var promptEnd = steps.findIndex(function (st) { return st.src === "gen"; });
      var shade = promptEnd > 0 ? [{ from: 0, to: promptEnd - 1, label: "prompt" }] : [];
      var pick = function (j) { ctx.set({ i: steps[j].i }); };
      var commons = se.commons;
      var claim = B.chart.lines({ width: 640, height: 150, n: steps.length, labels: labels, rotate: steps.length > 14, bottom: steps.length > 14 ? 40 : 30, yMin: 0, yMax: 8, yTicks: [0, 4, 8], shade: shade, cursor: pos, onPick: pick,
        tip: function (j) { return fmt.tok(steps[j].txt) + " H_lm " + fmt.n(f32(steps[j].thr[t].Hlm), 2); }, title: "H_lm, the claim",
        series: [{ label: strand.label, cls: se.strandClass(t), values: steps.map(function (st) { return f32(st.thr[t].Hlm); }) }].concat(commons !== null ? [{ label: "the commons", cls: "s-gold", dash: "5 3", values: steps.map(function (st) { return f32(st.thr[commons].Hlm); }) }] : []) });
      var ln16 = Math.log(16);
      var evidence = B.chart.lines({ width: 640, height: 150, n: steps.length, labels: labels, rotate: steps.length > 14, bottom: steps.length > 14 ? 40 : 30, yMin: 0, yMax: 3, yTicks: [0, 1, 2, 3], shade: shade, cursor: pos, onPick: pick,
        refs: [{ y: ln16, label: "ln 16: the 16 hits spread evenly" }, { y: Math.log(2), label: "ln 2: as torn as two words" }],
        tip: function (j) { return fmt.tok(steps[j].txt) + " H_knn " + fmt.n(f32(steps[j].thr[t].Hknn), 2); }, title: "H_knn, the evidence",
        series: [{ label: strand.label + "'s 16 hits", cls: se.strandClass(t), values: steps.map(function (st) { return state.tau === null ? f32(st.thr[t].Hknn) : M.Mixer.knn(st.thr[t].hits, tau).entropy; }) }] });
      body.appendChild(B.legend([{ cls: se.strandClass(t), line: true, label: strand.label }].concat(commons !== null ? [{ cls: "s-gold", line: true, dash: true, label: "the commons" }] : [])));
      body.appendChild(h("div", { class: "grid2" }, [h("div", { class: "panel" }, [h("h4", null, "H_lm: the claim"), claim]), h("div", { class: "panel" }, [h("h4", null, "H_knn: the evidence"), evidence])]));
      var bars = evidenceBars(se, t, step, tau);
      body.appendChild(h("div", { class: "grid2", style: "margin-top: .6rem" }, [
        h("div", { class: "panel" }, [h("h4", null, ["At ", fmt.tok(step.txt), ": how sure each reed is"]), claimBars(se, t, step),
          h("p", { class: "note" }, "H_lm in nats on a scale of 0 to 8, and the probability each reed gave the token that was written.")]),
        h("div", { class: "panel" }, [h("h4", null, ["At ", fmt.tok(step.txt), ": where the 16 hits point"]), bars.svg,
          h("p", { class: "readout" }, ["H_knn ", h("b", null, fmt.n(bars.entropy, 3)), state.tau === null ? " (logged " + fmt.n(f32(step.thr[t].Hknn), 3) + ")" : " at τ " + tau.toFixed(2) + ", a what-if; logged at " + f32(strand.tau).toFixed(2) + ": " + fmt.n(f32(step.thr[t].Hknn), 3),
            " · " + bars.groups + " distinct next tokens"])])
      ]));
    },
    selfCheck: function (state) {
      var se = B.session(state.s), t = strandIndex(se, state.strand), worst = 0, n = 0;
      se.shared.forEach(function (st) { if (!st.thr) return; n++; worst = Math.max(worst, Math.abs(M.Mixer.knn(st.thr[t].hits, f32(se.strands[t].tau)).entropy - f32(st.thr[t].Hknn))); });
      return [{ name: "H_knn recomputed from the logged hits equals the log", ok: worst <= 1e-5, detail: "worst " + fmt.e(worst) + " over " + n + " positions" }];
    }
  });

  // MARK: Counting the ways

  var MOST = 32;
  /** A belief over n words in play: the first leans `lean` of the way from an even share to all of it, the rest share what is left. */
  function belief(n, lean) {
    if (n <= 1) return [1];
    var top = 1 / n + lean * (1 - 1 / n), rest = (1 - top) / (n - 1), out = [top];
    for (var i = 1; i < n; i++) out.push(rest);
    return out;
  }
  function nats(ps) { var h0 = 0; ps.forEach(function (p) { if (p > 0) h0 -= p * Math.log(p); }); return h0; }
  function pct(p) { return p >= 0.9995 ? "100%" : p >= 0.1 ? Math.round(p * 100) + "%" : p >= 0.001 ? (p * 100).toFixed(1) + "%" : "under 0.1%"; }
  function howMany(x) { var r = Math.round(x); return Math.abs(x - r) < 0.05 ? r + (r === 1 ? " word" : " words") : x.toFixed(1) + " words"; }

  B.define("ways", {
    title: "Counting the ways",
    params: { n: { type: "int", default: 16 }, lean: { type: "number", default: 0 } },
    render: function (body, state, ctx) {
      var n = Math.max(1, Math.min(MOST, state.n | 0)), lean = Math.max(0, Math.min(1, Number(state.lean) || 0));
      var ps = belief(n, lean), H = nats(ps);
      body.appendChild(h("div", { class: "fig-controls" }, [
        B.slider("Words in play", n, 1, MOST, 1, function (v) { ctx.set({ n: v }); }, function (v) { return String(v); }),
        B.slider("Lean toward one", lean, 0, 1, 0.01, function (v) { ctx.set({ lean: v }); },
          function (v) { return n === 1 ? "–" : v === 0 ? "none" : pct(1 / n + v * (1 - 1 / n)) + " on one"; })
      ]));
      var W = 400, L = 16, R = W - 16, top = 24, barH = 64, axisY = 142, most = Math.log(MOST);
      var svg = s("svg", { viewBox: "0 0 " + W + " 194", role: "img", "aria-label": n + " words in play; entropy " + H.toFixed(2) + " nats, as if weighing " + howMany(Math.exp(H)) });
      // The belief, one bar per word; the tallest is drawn full height and the label gives the chances.
      svg.appendChild(s("text", { x: L, y: 12, class: "t-small" }, n === 1 ? "one word, certain" : lean === 0 ? "each word " + pct(ps[0]) : "one word " + pct(ps[0]) + " · the other " + (n - 1) + ", " + pct(ps[1]) + " each"));
      var slot = (R - L) / n, gap = Math.min(3, slot * 0.25);
      ps.forEach(function (p, i) {
        var hgt = Math.max(1, barH * p / ps[0]);
        svg.appendChild(s("rect", { x: (L + i * slot + gap / 2).toFixed(1), y: (top + barH - hgt).toFixed(1), width: Math.max(1, slot - gap).toFixed(1), height: hgt.toFixed(1), rx: 1.5, class: "ways-bar" + (i === 0 && lean > 0 && n > 1 ? " top" : "") }));
      });
      // The ladder: entropy in nats. Each tick is twice the even words of the one before, and the same 0.69 further on.
      var x = function (v) { return L + (R - L) * v / most; };
      svg.appendChild(s("line", { x1: L, y1: axisY, x2: R, y2: axisY, class: "ways-axis" }));
      svg.appendChild(s("line", { x1: L, y1: axisY, x2: x(H).toFixed(1), y2: axisY, class: "ways-climb" }));
      for (var k = 0; (1 << k) <= MOST; k++) {
        var v = Math.log(1 << k), xx = x(v), anchor = k === 0 ? "start" : (1 << k) === MOST ? "end" : "middle";
        svg.appendChild(s("line", { x1: xx.toFixed(1), y1: axisY - 5, x2: xx.toFixed(1), y2: axisY + 5, class: "ways-axis" }));
        svg.appendChild(s("text", { x: xx.toFixed(1), y: axisY - 11, "text-anchor": anchor, class: "t-small" + ((1 << k) === 16 ? " ways-16" : "") }, String(1 << k) + (k === 0 ? " even word" : (1 << k) === 16 ? " · Braid's" : "")));
        svg.appendChild(s("text", { x: xx.toFixed(1), y: axisY + 19, "text-anchor": anchor, class: "t-small t-mono" }, k === 0 ? "0" : v.toFixed(2)));
      }
      svg.appendChild(s("circle", { cx: x(H).toFixed(1), cy: axisY, r: 5, class: "ways-mark" }));
      svg.appendChild(s("text", { x: L, y: axisY + 42, class: "t-small" }, "entropy in nats · each step right doubles the even words and adds ln 2 = 0.69"));
      body.appendChild(svg);
      body.appendChild(h("p", { class: "readout" }, ["entropy ", h("b", null, H.toFixed(2)), " nats · ", h("b", null, (H / Math.LN2).toFixed(2)), " bits · as if weighing ", h("b", null, howMany(Math.exp(H)))]));
      body.appendChild(h("p", { class: "note" }, ["A ", h("b", null, "nat"), " is entropy counted with the natural logarithm, the unit Braid logs. A ", h("b", null, "bit"),
        " counts in base two, one yes-or-no question, so a nat is about 1.44 bits. ", h("b", null, "As if weighing"), " is e to the entropy: the number of equally likely words that would be just as torn."]));
    },
    selfCheck: function () {
      var worst = 0, back = 0, falls = true, prev = Infinity;
      for (var n = 1; n <= MOST; n++) { var e = nats(belief(n, 0)); worst = Math.max(worst, Math.abs(e - Math.log(n))); back = Math.max(back, Math.abs(Math.exp(e) - n)); }
      for (var i = 0; i <= 100; i++) { var hh = nats(belief(16, i / 100)); if (hh > prev + 1e-12) falls = false; prev = hh; }
      var sixteen = nats(belief(16, 0));
      return [
        { name: "an even spread over n words gives ln n, for n from 1 to " + MOST, ok: worst < 1e-12, detail: "worst " + fmt.e(worst) },
        { name: "sixteen even words give 2.77 nats and 4 bits", ok: Math.abs(sixteen - 2.7726) < 1e-4 && Math.abs(sixteen / Math.LN2 - 4) < 1e-12, detail: sixteen.toFixed(4) + " nats" },
        { name: "e to the entropy gives back the number of even words", ok: back < 1e-9, detail: "worst " + fmt.e(back) },
        { name: "leaning toward one word only lowers the entropy, to zero when it has it all", ok: falls && Math.abs(nats(belief(16, 1))) < 1e-12, detail: "at full lean " + nats(belief(16, 1)).toFixed(6) }
      ];
    }
  });

})();
