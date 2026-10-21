/*
 * The trace and the trajectory: a chain walking one document (TraceTracker, replayed in the
 * browser over the logged hits), the module's slope of H_knn and its logged e_t, and the β4
 * shadow gate beside the live one.
 */
(function () {
  "use strict";
  var B = window.Braid, M = B.model, h = B.h, s = B.s, fmt = B.fmt, f32 = Math.fround;

  function threadIndex(se, name) {
    if (name) { var i = se.strands.findIndex(function (x) { return x.name === name; }); if (i >= 0) return i; }
    var lines = se.royalties().strands.filter(function (l) { return !l.commons; }).sort(function (a, b) { return b.share - a.share; });
    return se.strands.findIndex(function (x) { return x.name === lines[0].name; });
  }
  function sessionSelect(se, ctx, keys) {
    return B.select("Session", keys.map(function (k) { var x = B.session(k); return { value: x.slug, label: x.label }; }), se.slug, function (v) { ctx.set({ s: v, i: null, strand: null }); });
  }

  B.define("chain", {
    title: "A chain walks one document",
    params: { s: { default: "harbour" }, strand: { default: null }, i: { type: "int", default: null } },
    render: function (body, state, ctx) {
      var se = B.session(state.s), t = threadIndex(se, state.strand), strand = se.strands[t], th = se.threads[strand.name];
      var replay = se.traces()[strand.name], steps = se.shared, walk = [];
      steps.forEach(function (st, k) { if (st.thr && replay.states[se.steps.indexOf(st)]) walk.push(k); });
      var lastLive = walk.filter(function (j) { var x = replay.states[se.steps.indexOf(steps[j])]; return x && x.e !== undefined; }).pop();
      var k = state.i === null ? (lastLive === undefined ? walk[walk.length - 1] : lastLive) : walk.find(function (j) { return steps[j].i === state.i; });
      if (k === undefined) k = walk[walk.length - 1];
      var at = walk.indexOf(k), stp = steps[k], live = replay.states[se.steps.indexOf(stp)], logged = stp.thr[t].tr || {};
      body.appendChild(h("div", { class: "fig-controls" }, [sessionSelect(se, ctx, ["harbour", "joltvault", "tillyburn", "window-in-autumn"]),
        B.slider("Position", at, 0, walk.length - 1, 1, function (v) { ctx.set({ i: steps[walk[v]].i }); }, function (v) { return steps[walk[v]].i + " " + fmt.tok(steps[walk[v]].txt); })]));
      var Ls = walk.map(function (j) { var x = replay.states[se.steps.indexOf(steps[j])]; return x ? x.L : 0; });
      var max = Math.max(30, Math.max.apply(null, Ls) + 4);
      var labels = walk.map(function (j) { return fmt.raw(steps[j].txt).trim().slice(0, 6); });
      var promptEnd = walk.findIndex(function (j) { return steps[j].src === "gen"; });
      body.appendChild(B.chart.lines({ width: 680, height: 190, n: walk.length, labels: labels, rotate: walk.length > 16, bottom: 40, yMin: 0, yMax: max, yTicks: [0, 24, max > 60 ? 48 : null, max].filter(function (v) { return v !== null; }),
        series: [{ label: "L", cls: se.strandClass(t), values: Ls, step: true }], step: true, refs: [{ y: 24, label: "24: a phrase counts nothing" }], cursor: at, onPick: function (j) { ctx.set({ i: steps[walk[j]].i }); },
        shade: promptEnd > 0 ? [{ from: 0, to: promptEnd - 1, label: "prompt" }] : [], title: "The longest live chain, L",
        tip: function (j) { return "L " + Ls[j] + " · trace " + M.traceRule(se.header.trace).trace(Ls[j]).toFixed(3); } }));
      var text = h("p", { class: "readout", style: "white-space: pre-wrap; line-height: 1.8; margin-top: .5rem" });
      var shown = live, ended = false;
      if (live.e === undefined && live.L > 0) {
        for (var b2 = at - 1; b2 >= 0; b2--) { var prev = replay.states[se.steps.indexOf(steps[walk[b2]])]; if (prev && prev.e !== undefined) { shown = { e: prev.e, row: prev.row, off: prev.off + 1, L: live.L }; ended = true; break; } }
      }
      if (shown.e !== undefined) {
        var p = th.partitions[shown.row], first = Math.max(0, shown.off - shown.L + 1);
        live = Object.assign({}, live, { row: shown.row, off: shown.off });
        for (var o = 0; o < p.tokens.length; o++) {
          var piece = p.text.slice(p.offsets[o], p.offsets[o + 1]);
          var walked = o >= first && o <= live.off, next = !ended && o === live.off + 1;
          text.appendChild(walked ? h("span", { style: "background: color-mix(in srgb, var(--violet) 22%, transparent); border-radius: 2px" }, piece)
            : next ? h("span", { style: "outline: 2px solid var(--violet); border-radius: 2px" }, piece) : document.createTextNode(piece));
        }
        body.appendChild(h("div", { class: "panel" }, [h("h4", null, [h("span", { class: "chip " + se.strandClass(t) }, strand.label), " · " + th.documents[p.doc].name + ", partition " + p.index, ended ? " · the chain reached the record's end" : ""]), text]));
      } else body.appendChild(h("p", { class: "note" }, "No live chain here: none of the last tokens followed a seeded entry."));
      var rule = M.traceRule(se.header.trace);
      var orig = replay.states[se.steps.indexOf(stp)];
      body.appendChild(h("p", { class: "readout" }, ["Replayed in your browser: L ", h("b", null, String(orig.L)), ", expecting ", orig.nx !== undefined ? h("b", null, fmt.tok(th.text(th.layoutIndex().valueRow[orig.e], th.layoutIndex().valueOffset[orig.e]))) : ended ? "nothing: the record has ended" : "nothing",
        " · trace ", h("b", null, rule.trace(orig.L).toFixed(3)), " · the log says L ", String(logged.L), logged.L === orig.L && (logged.nx === undefined ? orig.nx === undefined : logged.nx === orig.nx) ? " · identical" : " · differs",
        " · " + orig.heads.length + " live heads, " + orig.seeds.length + " fresh seeds"]));
      body.appendChild(h("p", { class: "note" }, "Shaded: the tokens this chain has followed, in order, through the Thread's own text. Outlined: the token it expects next. A chain advances only when that token arrives."));
    },
    selfCheck: function (state) {
      var se = B.session(state.s), out = [];
      Object.keys(se.traces()).forEach(function (n) { var r = se.traces()[n]; out.push({ name: n + ": every chain state replays from the logged hits", ok: r.mismatches === 0, detail: (r.positions - r.mismatches) + " of " + r.positions }); });
      return out;
    }
  });

  B.define("slope", {
    title: "The slope of the evidence",
    params: { s: { default: "joltvault" }, strand: { default: null }, i: { type: "int", default: null } },
    render: function (body, state, ctx) {
      var se = B.session(state.s), t = threadIndex(se, state.strand), strand = se.strands[t];
      var mod = se.module()[t], ser = mod.series, reads = mod.readings, n = ser.hknn.length;
      var logged = M.loggedModule(ser, se.header.module);
      var best = 0; reads.forEach(function (x, q) { if (Math.abs(x.evidence) > Math.abs(reads[best].evidence)) best = q; });
      var j = state.i === null ? best : Math.max(0, ser.steps.indexOf(state.i));
      if (j < 0) j = 0;
      var r = reads[j], kappa = se.header.gate.moduleGain;
      body.appendChild(h("div", { class: "fig-controls" }, [sessionSelect(se, ctx, ["joltvault", "harbour", "tillyburn", "window-in-autumn"]),
        B.slider("Position", j, 0, n - 1, 1, function (v) { ctx.set({ i: ser.steps[v] }); }, function (v) { var st = se.steps.find(function (x) { return x.i === ser.steps[v]; }); return ser.steps[v] + " " + fmt.tok(st.txt); })]));
      var labels = ser.steps.map(function (i) { return fmt.raw(se.steps.find(function (x) { return x.i === i; }).txt).trim().slice(0, 6); });
      var ln16 = Math.log(16);
      var chart = B.chart.lines({ width: 680, height: 170, n: n, labels: labels, rotate: n > 16, bottom: 40, yMin: 0, yMax: 3, yTicks: [0, 1, 2, 3],
        series: [{ label: "H_knn", cls: se.strandClass(t), values: ser.hknn }], refs: [{ y: ln16, label: "ln 16" }, { y: Math.log(2), label: "ln 2: coherent" }], cursor: j, onPick: function (x) { ctx.set({ i: ser.steps[x] }); },
        shade: [{ from: r.window[0], to: r.window[1], cls: "shade", label: "the 8 positions the slope is fitted on" }], title: "H_knn and the window" });
      body.appendChild(chart);
      var emod = B.chart.lines({ width: 680, height: 130, n: n, labels: labels, rotate: n > 16, bottom: 40, yMin: -1, yMax: 1, yTicks: [-1, 0, 1],
        series: [{ label: "e_t logged", cls: se.strandClass(t), values: ser.steps.map(function (i) { var st = se.steps.find(function (x) { return x.i === i; }); return f32(st.thr[t].mod || 0); }) },
                 { label: "e_t recomputed", cls: "", dash: "3 3", values: logged, width: 1.4 }], cursor: j, onPick: function (x) { ctx.set({ i: ser.steps[x] }); }, title: "e_t, logged" });
      body.appendChild(B.legend([{ cls: se.strandClass(t), line: true, label: "e_t as logged" }, { line: true, dash: true, label: "e_t recomputed here" }]));
      body.appendChild(emod);
      body.appendChild(h("p", { class: "readout" }, ["At ", h("b", null, fmt.tok(se.steps.find(function (x) { return x.i === ser.steps[j]; }).txt)), ": slope ", r.slope === null ? "–" : fmt.n(r.slope, 3), " · forecast ", r.forecast === null ? "–" : fmt.n(r.forecast, 2),
        " · collapse ", fmt.n(r.collapse, 2), " · divergence ", fmt.n(r.divergence, 2), " · e_t ", h("b", null, fmt.n(r.evidence, 3)), " · label ", h("b", null, r.label)]));
      var would = r.evidence * 0.5 * Math.log(10);
      body.appendChild(h("p", { class: "note" }, "κ is " + kappa + ". At κ 0.5 this reading would have added " + fmt.n(would, 3) + " to a Thread's log-evidence at the next prompt token, before the one clamp. No session on this site used it. It lifted the holder less than the trace gate did, so the gate stays memory-only."));
    },
    selfCheck: function (state) {
      var se = B.session(state.s), worst = 0;
      se.module().forEach(function (m, t) {
        var logged = M.loggedModule(m.series, se.header.module);
        m.series.steps.forEach(function (i, j) { var st = se.steps.find(function (x) { return x.i === i; }); worst = Math.max(worst, Math.abs(logged[j] - f32(st.thr[t].mod || 0))); });
      });
      return [{ name: "every logged e_t recomputes from the H_knn series", ok: worst <= 1e-6, detail: "worst " + fmt.e(worst) }];
    }
  });

  B.define("shadow", {
    title: "The live gate and the β4 shadow",
    params: { s: { default: "harbour" } },
    render: function (body, state, ctx) {
      var se = B.session(state.s), t = threadIndex(se, null), strand = se.strands[t];
      var steps = se.shared.filter(function (x) { return x.thr; });
      body.appendChild(h("div", { class: "fig-controls" }, [sessionSelect(se, ctx, ["harbour", "joltvault", "tillyburn", "window-in-autumn"])]));
      var labels = steps.map(function (x) { return fmt.raw(x.txt).trim().slice(0, 6); });
      var gates = B.chart.lines({ width: 680, height: 170, n: steps.length, labels: labels, rotate: steps.length > 16, bottom: 40, yMin: 0, yMax: 1, yTicks: [0, 0.5, 1],
        series: [{ label: "w′, live", cls: se.strandClass(t), values: steps.map(function (x) { return f32(x.thr[t].w); }) }, { label: "shadow β4", cls: "s-gold", dash: "4 3", values: steps.map(function (x) { return f32(x.thr[t].sg); }), width: 1.6 }],
        title: "The live weight and the shadow gate for " + strand.label });
      var traces = B.chart.lines({ width: 680, height: 110, n: steps.length, labels: labels, rotate: steps.length > 16, bottom: 40, yMin: 0, yMax: 1, yTicks: [0, 1],
        series: [{ label: "trace", cls: "", values: steps.map(function (x) { return x.thr[t].tr ? f32(x.thr[t].tr.tr) : 0; }) }], title: "The trace" });
      body.appendChild(B.legend([{ cls: se.strandClass(t), line: true, label: "w′, the live gate" }, { cls: "s-gold", line: true, dash: true, label: "the β4 shadow, never applied" }]));
      body.appendChild(gates);
      body.appendChild(h("div", { class: "panel" }, [h("h4", null, "Trace, 0 to 1"), traces]));
      var maxTrace = Math.max.apply(null, steps.map(function (x) { return x.thr[t].tr ? f32(x.thr[t].tr.tr) : 0; }));
      var gap = Math.max.apply(null, steps.map(function (x) { return Math.abs(f32(x.thr[t].w) - f32(x.thr[t].sg)); }));
      body.appendChild(h("p", { class: "readout" }, ["Largest trace: ", h("b", null, maxTrace.toFixed(3)), " · largest gap between the live gate and the shadow: ", h("b", null, fmt.e(gap))]));
    }
  });
})();
