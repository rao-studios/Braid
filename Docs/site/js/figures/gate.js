/*
 * The gate and the shares. #fig-shares splits one logged token among the strands with Mixer's
 * arithmetic (w′ from memory over the open set; p_t = λ·p_knn + (1−λ)·p_lm; share = w′·p_t/p).
 * #fig-gate-memory replays Gate.observe over the prompt from the logged probabilities and shows
 * the one clamp at ten to one.
 */
(function () {
  "use strict";
  var B = window.Braid, M = B.model, h = B.h, s = B.s, fmt = B.fmt, f32 = Math.fround;

  function generated(se) { return se.shared.filter(function (st) { return st.thr && st.src === "gen"; }); }

  function split(se, step, lambda) {
    var strands = se.strands, rows = [];
    var gates = step.thr.map(function (r) { return f32(r.mem); }), open = step.thr.map(function (r) { return r.open; });
    var w = M.Gate.renormalised(gates, open);
    var total = 0;
    step.thr.forEach(function (r, t) {
      var lam = strands[t].commons ? 0 : (lambda === null ? f32(strands[t].lambda) : lambda);
      var pt = r.plm === undefined ? null : lam * f32(r.pknn) + (1 - lam) * f32(r.plm);
      var part = open[t] ? w[t] * (pt || 0) : 0;
      total += part;
      rows.push({ t: t, memory: gates[t], open: open[t], w: w[t], plm: r.plm === undefined ? null : f32(r.plm), pknn: f32(r.pknn), lambda: lam, pt: pt, part: part, logged: f32(r.share) });
    });
    rows.forEach(function (r) { r.share = total > 0 ? r.part / total : r.w; });
    return { rows: rows, p: total };
  }

  B.define("shares", {
    title: "One token, split among the strands",
    params: { s: { default: "tillyburn" }, i: { type: "int", default: 10 }, lambda: { type: "number", default: null } },
    render: function (body, state, ctx) {
      var se = B.session(state.s), gen = generated(se);
      var at = gen.findIndex(function (st) { return st.i === state.i; });
      if (at < 0) at = 0;
      var step = gen[at], what = state.lambda !== null;
      var r = split(se, step, state.lambda);
      body.appendChild(h("div", { class: "fig-controls" }, [
        B.slider("Token", at, 0, gen.length - 1, 1, function (v) { ctx.set({ i: gen[v].i }); }, function (v) { return fmt.tok(gen[v].txt); }),
        B.slider("What if λ were", what ? state.lambda : 0.5, 0, 1, 0.05, function (v) { ctx.set({ lambda: v }); }, function (v) { return v.toFixed(2); }),
        what ? h("button", { type: "button", "data-key": "reset" }, "Back to the log") : null,
        h("span", { class: "what-if" }, "Braid's λ is 0.5 for a Thread and 0 for the commons; λ is not a control")
      ]));
      var reset = body.querySelector('[data-key="reset"]');
      if (reset) reset.addEventListener("click", function () { ctx.set({ lambda: null }); });
      var floor = M.Gate.floor(se.header.gate.openFloor, se.strands.length);
      body.appendChild(h("div", { class: "scroll" }, h("table", null, [
        h("thead", null, h("tr", null, ["strand", "memory", "open?", "w′", "p_lm(y)", "p_knn(y)", "λ", "p_t(y)", "w′ · p_t(y)", "share"].map(function (c, i) { return h("th", { class: i ? "n" : "" }, c); }))),
        h("tbody", null, r.rows.map(function (x) {
          return h("tr", { class: x.open ? "" : "dim" }, [h("td", null, h("span", { class: "chip " + se.strandClass(x.t) }, se.strands[x.t].label)), h("td", { class: "n" }, fmt.p(x.memory)),
            h("td", { class: "n" }, x.open ? "open" : "closed, under " + floor.toFixed(3)), h("td", { class: "n" }, fmt.p(x.w)), h("td", { class: "n" }, x.plm === null ? "–" : fmt.p(x.plm)),
            h("td", { class: "n" }, fmt.p(x.pknn)), h("td", { class: "n" }, x.lambda.toFixed(2)), h("td", { class: "n" }, x.pt === null ? "–" : fmt.p(x.pt)), h("td", { class: "n" }, fmt.p(x.part)),
            h("td", { class: "n" }, h("b", null, fmt.p(x.share)))]);
        })),
        h("tfoot", null, h("tr", null, [h("td", { colspan: 8 }, "p(y) = Σ w′ · p_t(y)" + (what ? " at the what-if λ" : "")), h("td", { class: "n" }, h("b", null, fmt.p(r.p))), h("td", { class: "n" }, "Σ " + fmt.p(r.rows.reduce(function (a, x) { return a + x.share; }, 0)))]))
      ])));
      var W = 640, H = 64, L = 4, R = 4, x = B.chart.scale(0, 1, L, W - R), acc = 0;
      var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "The token's probability, split into each strand's share" });
      r.rows.forEach(function (row) {
        if (row.share <= 0) return;
        var g = s("g", { class: se.strandClass(row.t) });
        g.appendChild(s("rect", { x: x(acc), y: 6, width: Math.max(0.5, x(acc + row.share) - x(acc)), height: 30, style: "fill: var(--s)" }));
        if (row.share > 0.08) g.appendChild(s("text", { x: x(acc) + 6, y: 26, class: "t-strong", style: "fill: #141414; font-size: 12px" }, se.strands[row.t].label + " " + fmt.p(row.share)));
        svg.appendChild(g);
        acc += row.share;
      });
      svg.appendChild(s("text", { class: "t-small", x: L, y: 54 }, "The whole bar is " + fmt.tok(step.txt) + "'s probability p(y) = " + fmt.p(r.p) + "; each strand's part of it is its share."));
      body.appendChild(svg);
      if (step.cand && !what) body.appendChild(h("p", { class: "readout" }, ["The three likeliest tokens, as logged: ", step.cand.map(function (c) { return fmt.tok(c.txt) + " " + fmt.p(f32(c.p)); }).join(" · ")]));
      if (!what) body.appendChild(h("p", { class: "note" }, "Recomputed here from the logged memory, p_lm and p_knn; the logged shares agree within " + fmt.e(Math.max.apply(null, r.rows.map(function (x) { return Math.abs(x.share - x.logged); }))) + "."));
    },
    selfCheck: function (state) {
      var se = B.session(state.s), worst = 0, n = 0;
      generated(se).forEach(function (st) { split(se, st, null).rows.forEach(function (x) { worst = Math.max(worst, Math.abs(x.share - x.logged)); n++; }); });
      return [{ name: "every share recomputes from memory, p_lm, p_knn and λ", ok: worst <= 1e-5, detail: "worst " + fmt.e(worst) + " over " + n + " strand-tokens" }];
    }
  });

  /** The gate replayed over a session's prompt: every intermediate of Gate.observe at every prompt token. */
  function replayGate(se, boost) {
    var settings = se.header.gate, strands = se.strands;
    var state = new M.Gate.GateState(strands.length, se.commons, settings.commonsPrior);
    var out = [];
    se.shared.forEach(function (st, k) {
      if (!st.thr || st.src !== "prompt") return;
      var likelihoods = st.thr.map(function (r, t) { var p = M.Mixer.probability(r, f32(strands[t].lambda)); return p === null ? f32(strands[t].lambda) * f32(r.pknn) : p; });
      if (boost && boost.k === k) likelihoods[boost.t] = likelihoods[se.commons] * boost.ratio;
      var logged = st.thr.map(function (r) { return f32(r.mem); });
      var detail = M.Gate.observe(state, likelihoods, null, settings);
      out.push({ k: k, step: st, likelihoods: likelihoods, logged: logged, detail: detail, ev: st.thr.map(function (r) { return r.ev === undefined ? null : f32(r.ev); }) });
    });
    return out;
  }

  B.define("gate-memory", {
    title: "The gate learns only while the prompt is read",
    params: { s: { default: "joltvault" }, at: { type: "int", default: 4 }, boost: { type: "number", default: null } },
    render: function (body, state, ctx) {
      var se = B.session(state.s), strands = se.strands, c = se.commons;
      var thread = strands.findIndex(function (x, t) { return !x.commons && se.royalties().strands.some(function (l) { return l.name === x.name && l.led > 0; }); });
      if (thread < 0) thread = strands.findIndex(function (x) { return !x.commons; });
      var prompt = replayGate(se, null);
      var at = Math.min(Math.max(0, state.at), prompt.length - 1);
      var boosted = state.boost !== null ? replayGate(se, { k: prompt[at].k, t: thread, ratio: state.boost }) : null;
      var view = boosted || prompt;
      var asLogged = state.boost === null; // only the slider's first readout: a drag reads its own value
      body.appendChild(h("div", { class: "fig-controls" }, [
        B.slider("Prompt token", at, 0, prompt.length - 1, 1, function (v) { ctx.set({ at: v }); }, function (v) { return fmt.tok(prompt[v].step.txt); }),
        B.slider("What if " + strands[thread].label + " beat the commons by", state.boost === null ? 0 : Math.log10(state.boost), -2, 6, 0.5, function (v) { ctx.set({ boost: Math.pow(10, v) }); },
          function (v) { if (asLogged) { asLogged = false; return "as logged"; } var x = Math.pow(10, v); return x >= 1 ? "×" + fmt.int(Math.round(x)) : "×" + x.toFixed(2); }),
        state.boost !== null ? h("button", { type: "button", "data-key": "reset" }, "Back to the log") : null
      ]));
      var reset = body.querySelector('[data-key="reset"]');
      if (reset) reset.addEventListener("click", function () { ctx.set({ boost: null }); });
      var labels = prompt.map(function (p) { return B.fmt.raw(p.step.txt).trim().slice(0, 8); });
      var n = prompt.length;
      var series = strands.map(function (x, t) {
        return { label: x.label, cls: se.strandClass(t), dash: x.commons ? "5 3" : null, values: [view[0].detail.before[t]].concat(view.map(function (p) { return p.detail.after[t]; })) };
      });
      var floor = M.Gate.floor(se.header.gate.openFloor, strands.length);
      var chart = B.chart.lines({ width: 640, height: 210, n: n + 1, labels: ["start"].concat(labels), yMin: 0, yMax: 1, yTicks: [0, 0.25, 0.5, 0.75, 1], series: series, cursor: at + 1,
        refs: [{ y: floor, label: "open floor " + floor.toFixed(3) }], onPick: function (j) { if (j > 0) ctx.set({ at: j - 1 }); }, title: "Memory after each prompt token",
        tip: function (j) { return j === 0 ? "the memory before the prompt" : "after " + fmt.tok(prompt[j - 1].step.txt); } });
      body.appendChild(B.legend(strands.map(function (x, t) { return { cls: se.strandClass(t), line: true, dash: x.commons, label: x.label }; })));
      body.appendChild(chart);
      var p = view[at], d = p.detail, span = Math.log(M.Gate.reach(se.header.gate));
      body.appendChild(h("div", { class: "scroll" }, h("table", null, [
        h("thead", null, h("tr", null, ["strand", "p_t(x)", "p_c(x)", "ratio", "ρ̃, clamped", "gain", "loss", "credibility", "memory before", "memory after"].map(function (cc, i) { return h("th", { class: i ? "n" : "" }, cc); }))),
        h("tbody", null, strands.map(function (x, t) {
          var raw = p.likelihoods[t] / p.likelihoods[c], clamped = Math.abs(Math.log(d.ratios[t])) >= span - 1e-12 && t !== c;
          return h("tr", { class: t === thread ? "match" : "" }, [h("td", null, h("span", { class: "chip " + se.strandClass(t) }, x.label)), h("td", { class: "n" }, fmt.p(p.likelihoods[t])), h("td", { class: "n" }, fmt.p(p.likelihoods[c])),
            h("td", { class: "n" }, t === c ? "1" : raw >= 1000 || raw < 0.001 ? raw.toExponential(1) : raw.toFixed(3)), h("td", { class: "n" }, h("b", null, d.ratios[t].toFixed(3) + (clamped ? " ⟂" : ""))),
            h("td", { class: "n" }, d.gains[t].toFixed(3)), h("td", { class: "n" }, d.losses[t].toFixed(3)), h("td", { class: "n" }, d.credibility[t].toFixed(3)), h("td", { class: "n" }, fmt.p(d.before[t])), h("td", { class: "n" }, fmt.p(d.after[t]))]);
        }))
      ])));
      body.appendChild(h("p", { class: "note" }, [
        "At ", fmt.tok(p.step.txt), " the weight on every ratio is the best Thread credibility, ", h("b", null, d.weight.toFixed(3)), "; ⟂ marks a ratio cut to ten to one. ",
        state.boost !== null ? (state.boost > 10 ? "Past ten, the result stops changing: one clamp holds for everything." : "Below ten, the ratio is taken as it is.") :
          "Recomputed with Gate.observe from the logged probabilities; the logged memory agrees within " + fmt.e(Math.max.apply(null, prompt.slice(0, -1).map(function (q, j) { return Math.max.apply(null, q.detail.after.map(function (v, t) { return Math.abs(v - prompt[j + 1].logged[t]); })); }).concat([0]))) + "."
      ]));
    },
    selfCheck: function (state) {
      var se = B.session(state.s), prompt = replayGate(se, null), worst = 0;
      prompt.forEach(function (p, j) { if (j + 1 < prompt.length) p.detail.after.forEach(function (v, t) { worst = Math.max(worst, Math.abs(v - prompt[j + 1].logged[t])); }); });
      var evWorst = 0;
      prompt.forEach(function (p) { p.detail.ratios.forEach(function (r, t) { if (p.ev[t] !== null) evWorst = Math.max(evWorst, Math.abs(r - p.ev[t]) / Math.max(1, p.ev[t])); }); });
      var a = replayGate(se, { k: prompt[0].k, t: 1, ratio: 10 }), b = replayGate(se, { k: prompt[0].k, t: 1, ratio: 1e6 });
      var same = a.every(function (p, j) { return p.detail.after.every(function (v, t) { return Math.abs(v - b[j].detail.after[t]) < 1e-15; }); });
      return [
        { name: "the memory recursion replays the log", ok: worst <= 1e-6, detail: "worst " + fmt.e(worst) },
        { name: "the bounded evidence ρ̃ equals the logged ev", ok: evWorst <= 1e-5, detail: "worst relative " + fmt.e(evWorst) },
        { name: "a ratio of a million moves memory exactly as a ratio of ten", ok: same, detail: "GateTests.lift, in the browser" }
      ];
    }
  });
})();
