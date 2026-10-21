/*
 * From records to a Thread: the token stream and its addresses, the training windows, the index
 * entries, the real training curve, where the key is taken, what a node sends, and the commons
 * beside a Thread. Every token is the GPT-NeoX tokenizer's own, precomputed by src/data.py.
 */
(function () {
  "use strict";
  var B = window.Braid, M = B.model, h = B.h, s = B.s, fmt = B.fmt, f32 = Math.fround;

  /** BatchSampler.plan for the harbour stream, as Swift itself computed it (a compiled copy of DeltaTrainer.swift, 2026-10-18). */
  var SWIFT_PLANS = [[0, 21, [[21, 149, 277, 405, 21, 149, 277, 405]]], [1, 40, [[40, 168, 424, 296, 40, 168, 424, 296]]], [2, 16, [[272, 400, 16, 144, 272, 400, 16, 144]]], [3, 102, [[230, 358, 102, 486, 230, 358, 102, 486]]], [4, 73, [[73, 201, 329, 457, 73, 201, 329, 457]]], [5, 71, [[199, 327, 71, 455, 199, 327, 71, 455]]]];

  function harbour() { var x = (window.BraidData || {}).harbour; if (!x) throw new Error("missing data/harbour.js"); return x; }
  function docIndex(th, id) { return th.documents.findIndex(function (d) { return d.id.split("/").pop() === id || d.id === id; }); }

  /** The training stream exactly as BatchSampler builds it: eos, then each document's tokens and its closing eos. */
  function stream(th) {
    var out = [{ tok: th.eos, eos: true, doc: -1 }];
    th.documents.forEach(function (d, di) {
      d.rows.forEach(function (row, n) {
        var p = th.partitions[row];
        p.tokens.forEach(function (t, i) { out.push({ tok: t, doc: di, row: row, off: i, text: p.text.slice(p.offsets[i], p.offsets[i + 1]) }); });
        if (n < d.rows.length - 1) th["break"].forEach(function (t, j) { out.push({ tok: t, doc: di, row: row, off: p.tokens.length + j, brk: true, text: "¶" }); });
      });
      out.push({ tok: th.eos, eos: true, doc: di });
    });
    return out;
  }
  B.trainingStream = stream;

  function counts(th) {
    var content = 0, entries = th.layout.entries;
    th.partitions.forEach(function (p) { content += p.tokens.length; });
    var str = stream(th).length;
    var tokenCount = th.documents.reduce(function (a, d) { return a + d.rows.reduce(function (b, r) { return b + th.partitions[r].tokens.length; }, 0) + (d.rows.length - 1) * th["break"].length + 2; }, 0);
    return { content: content, stream: str, tokenCount: tokenCount, entries: entries, documents: th.documents.length };
  }

  // MARK: The stream, three ways

  B.define("stream", {
    title: "The stream the model reads",
    params: { mode: { default: "addresses" }, doc: { default: "harlow-light" }, at: { type: "int", default: 19 }, seq: { type: "int", default: 128 }, epoch: { type: "int", default: 0 } },
    render: function (body, state, ctx) {
      var th = B.thread("harbour"), c = counts(th);
      if (state.mode === "windows") return windows(body, state, ctx, th, c);
      var di = docIndex(th, state.doc), d = th.documents[di], row = d.rows[0], p = th.partitions[row];
      var names = th.documents.map(function (x) { return { value: x.id.split("/").pop(), label: x.name }; });
      body.appendChild(h("div", { class: "fig-controls" }, [B.select("Record", names, state.doc, function (v) { ctx.set({ doc: v, at: 0 }); }),
        B.slider("Token", Math.min(state.at, p.tokens.length - 1), 0, p.tokens.length - 1, 1, function (v) { ctx.set({ at: v }); }, function (v) { return fmt.tok(p.text.slice(p.offsets[v], p.offsets[v + 1])); })]));
      var lay = th.layoutIndex(), base = th.layout.entryBase[di], at = Math.min(state.at, p.tokens.length - 1);
      var ribbon = h("div", { class: "ribbon", "aria-label": "The record's tokens, with their offsets" });
      ribbon.appendChild(h("span", { class: "t eos", title: "eos: the state resets here" }, "eos"));
      p.tokens.forEach(function (t, i) {
        var cls = "t" + (i === at ? " lit" : "") + (state.mode === "entries" && i === at + 1 ? " lit" : "");
        var chip = h("span", { class: cls, title: "offset " + i + " · token " + t }, [h("span", { style: "display: block; font-size: .62rem; color: var(--faint)" }, String(i)), p.text.slice(p.offsets[i], p.offsets[i + 1]).replace(/ /g, "·")]);
        chip.addEventListener("click", function () { ctx.set({ at: i }); });
        ribbon.appendChild(chip);
      });
      ribbon.appendChild(h("span", { class: "t eos" }, "eos"));
      body.appendChild(ribbon);
      var tokText = function (i) { return fmt.tok(p.text.slice(p.offsets[i], p.offsets[i + 1])); };
      if (state.mode === "entries") {
        var isEntry = at < p.tokens.length - 1, e = base + at;
        body.appendChild(h("p", { class: "readout", style: "margin-top: .6rem" }, isEntry ? ["Entry ", h("b", null, String(e)), ": key at (row " + row + ", offset " + at + ") ", tokText(at), " → value ", tokText(at + 1), " at (row " + row + ", offset " + (at + 1) + "). Logged as a hit, it reads [", e, ", score, ", p.tokens[at + 1], ", ", row, ", ", at + 1, ", loss]."]
          : ["The last token has nothing after it but eos, so it is a key for no entry and only a value: this record makes ", h("b", null, String(p.tokens.length - 1)), " entries from " + p.tokens.length + " tokens."]));
        if (isEntry && (lay.values[e] !== p.tokens[at + 1] || lay.valueOffset[e] !== at + 1)) throw new Error("layout mismatch at entry " + e);
      } else {
        body.appendChild(h("p", { class: "readout", style: "margin-top: .6rem" }, ["Address of ", tokText(at), ": ", h("b", null, "(row " + row + ", offset " + at + ")"), " · " + d.name + ", partition " + p.index + ". ",
          d.id.endsWith("harlow-light") && at === 19 ? "This is where the harbour answer's first word, “ In”, is cited: p0@19." : ""]));
      }
      body.appendChild(h("table", { style: "margin-top: .4rem" }, h("tbody", null, [
        h("tr", null, [h("th", null, "Content tokens, every partition"), h("td", { class: "n" }, fmt.int(c.content)), h("td", { class: "note" }, "Σ tokens")]),
        h("tr", null, [h("th", null, "The training stream"), h("td", { class: "n" }, fmt.int(c.stream)), h("td", { class: "note" }, "1 + Σ (tokens + 1): one eos between documents")]),
        h("tr", null, [h("th", null, "Read for the index"), h("td", { class: "n" }, fmt.int(c.tokenCount)), h("td", { class: "note" }, "Σ (tokens + 2): each document between its own two eos")]),
        h("tr", null, [h("th", null, "Index entries"), h("td", { class: "n" }, fmt.int(c.entries)), h("td", { class: "note" }, "Σ (tokens − 1): a position whose input or value is eos is not an entry")])
      ])));
    },
    selfCheck: function () {
      var th = B.thread("harbour"), c = counts(th), hb = harbour();
      return [
        { name: "the stream is " + c.stream + " tokens, as the run printed", ok: c.stream === 645 && hb.counts.stream === c.stream },
        { name: "the index holds " + c.entries + " entries, as index.json says", ok: c.entries === hb.index.count },
        { name: "the content tokens recount from the tokenizer's output", ok: c.content === hb.counts.contentTokens },
        { name: "harlow-light offset 19 is “ In”, the answer's first cited word", ok: (function () { var di = docIndex(th, "harlow-light"), p = th.partitions[th.documents[di].rows[0]]; return p.text.slice(p.offsets[19], p.offsets[20]) === " In"; })() },
        { name: "the window plan equals Swift's BatchSampler, epochs 0–5", ok: SWIFT_PLANS.every(function (x) { var p = M.windowPlan(645, 128, 8, 42, x[0]); return p.offset === x[1] && JSON.stringify(p.batches) === JSON.stringify(x[2]); }), detail: "recorded from Swift on 2026-10-18" }
      ];
    }
  });

  function windows(body, state, ctx, th, c) {
    var st = stream(th), seq = state.seq, n = st.length;
    var ok = n > seq + 1;
    body.appendChild(h("div", { class: "fig-controls" }, [
      B.select("Window", [64, 128, 256, 512].map(function (v) { return { value: String(v), label: v + " tokens" + (v === 128 ? " · the playground" : v === 512 ? " · thread sync" : "") }; }), String(seq), function (v) { ctx.set({ seq: parseInt(v, 10), epoch: 0 }); }),
      B.slider("Epoch", state.epoch, 0, 9, 1, function (v) { ctx.set({ epoch: v }); }, function (v) { return String(v); })
    ]));
    if (!ok) { body.appendChild(h("p", { class: "fig-error" }, "The stream is " + n + " tokens; training needs more than one window of " + seq + ".")); return; }
    var plan = M.windowPlan(n, seq, 8, 42, state.epoch);
    var cols = 43, cell = 15.4, rows = Math.ceil(n / cols), W = cols * cell + 8, H = rows * cell + 10;
    var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "The " + n + "-token training stream and this epoch's windows" });
    var owner = new Array(n).fill(-1);
    plan.starts.forEach(function (start, w) { for (var t = start; t < start + seq + 1 && t < n; t++) if (owner[t] < 0) owner[t] = w; });
    st.forEach(function (tok, i) {
      var x = 4 + (i % cols) * cell, y = 4 + Math.floor(i / cols) * cell, w = owner[i];
      var fill = tok.eos ? "var(--red)" : w >= 0 ? (w % 2 ? "var(--blue)" : "var(--green)") : "var(--faint)";
      var op = tok.eos ? 0.9 : w >= 0 ? 0.55 : 0.22;
      var r = s("rect", { x: x, y: y, width: cell - 2, height: cell - 2, rx: 2, style: "fill: " + fill + "; opacity: " + op });
      r.appendChild(s("title", null, "position " + i + (tok.eos ? " · eos: the state resets, and the loss is masked where it is the input" : " · " + JSON.stringify(tok.text)) + (w >= 0 ? " · window " + (w + 1) : " · not read this epoch")));
      svg.appendChild(r);
    });
    body.appendChild(svg);
    var reads = plan.batches[0].length;
    body.appendChild(B.legend([{ color: "var(--green)", label: "a window" }, { color: "var(--blue)", label: "the next window" }, { color: "var(--red)", label: "eos: reset, loss masked" }, { color: "var(--faint)", label: "not read this epoch" }]));
    body.appendChild(h("p", { class: "readout" }, ["Epoch " + state.epoch + ": the grid starts at offset ", h("b", null, String(plan.offset)), " and gives ", h("b", null, plan.starts.length + " windows"), " of " + seq + " + 1 tokens. ",
      plan.batches.length === 1 ? "One step per epoch, a batch of 8: " + (plan.starts.length < 8 ? "the " + plan.starts.length + " windows, repeated to fill it." : "the windows.") : plan.batches.length + " steps, batches of 8.", " Each step reads " + fmt.int(reads * seq) + " tokens."]));
    body.appendChild(h("p", { class: "note" }, "The offset and the order come from Braid's own seeded generator, seed 42 plus the epoch, ported to your browser and checked against Swift's. The stream has " + n + " tokens, of which " + st.filter(function (t) { return t.eos; }).length + " are eos."));
  }

  // MARK: The real training run

  B.define("training-curve", {
    title: "The real 80 steps",
    params: { step: { type: "int", default: 80 } },
    render: function (body, state, ctx) {
      var hb = harbour(), steps = hb.steps, evals = hb.evals, n = steps.length;
      var pick = function (j) { ctx.set({ step: j + 1 }); };
      var labels = steps.map(function (r) { return r.step % 10 === 0 ? String(r.step) : null; });
      var cursor = Math.min(Math.max(state.step, 1), n) - 1;
      var loss = B.chart.lines({ width: 640, height: 170, n: n, labels: labels, yMin: 0, yMax: 5, yTicks: [0, 1, 2, 3, 4, 5], series: [{ label: "loss", cls: "s-gold", values: steps.map(function (r) { return r.loss; }), points: false }],
        markers: evals.map(function (e) { return { x: e.step - 1, y: e.meanLoss, cls: e.learned ? "s-green" : "s-orange" }; }), cursor: cursor, onPick: pick, title: "Training loss, nats",
        tip: function (j) { var r = steps[j]; return "step " + r.step + " · loss " + r.loss.toFixed(3) + " · lr " + r.lr.toExponential(2) + " · |g| " + r.gradNorm.toFixed(2) + " · " + r.seconds.toFixed(1) + " s"; } });
      var lr = B.chart.lines({ width: 640, height: 110, n: n, labels: labels, yMin: 0, yMax: 5e-4, yTicks: [0, 2.5e-4, 5e-4], yFormat: function (v) { return v === 0 ? "0" : v.toExponential(1); }, left: 52,
        series: [{ label: "learning rate", cls: "s-blue", values: steps.map(function (r) { return r.lr; }), points: false }], cursor: cursor, onPick: pick, title: "Learning rate" });
      body.appendChild(h("div", { class: "panel" }, [h("h4", null, "Loss, nats per token; dots are the two evaluations"), loss]));
      body.appendChild(h("div", { class: "panel" }, [h("h4", null, "Learning rate: warmup over the first 15 steps, then a cosine planned over 300"), lr]));
      var r = steps[cursor];
      body.appendChild(h("p", { class: "readout" }, ["Step ", h("b", null, String(r.step)), " · loss " + r.loss.toFixed(4) + " · learning rate " + r.lr.toExponential(2) + " · gradient norm " + r.gradNorm.toFixed(2) + " · " + r.seconds.toFixed(1) + " s into the run"]));
      body.appendChild(h("table", null, [h("thead", null, h("tr", null, ["evaluation", "step", "mean loss", "memorised", "learned"].map(function (x, i) { return h("th", { class: i ? "n" : "" }, x); }))),
        h("tbody", null, evals.map(function (e, i) { return h("tr", null, [h("td", null, String(i + 1)), h("td", { class: "n" }, String(e.step)), h("td", { class: "n" }, e.meanLoss.toFixed(4)), h("td", { class: "n" }, (e.memorised * 100).toFixed(1) + "%"), h("td", { class: "n" }, e.learned ? "yes · stop" : "no")]); }))]));
      body.appendChild(h("p", { class: "note" }, "The harbour Thread, trained on " + hb.version.createdAt.slice(0, 10) + ". Memorised means a position's loss is under 0.1 nat, so the right next token gets at least 90.5% of the probability."));
    },
    selfCheck: function () {
      var hb = harbour(), worst = 0;
      hb.steps.forEach(function (r) { worst = Math.max(worst, Math.abs(M.learningRate(r.step - 1, 300) - r.lr) / r.lr); });
      return [{ name: "the logged learning rate is the schedule, warmup then cosine over 300 planned steps", ok: worst < 1e-5, detail: "worst relative " + fmt.e(worst) },
        { name: "training stopped at the first evaluation at or above 97%", ok: hb.evals[hb.evals.length - 1].learned && hb.evals.slice(0, -1).every(function (e) { return e.memorised < 0.97; }) }];
    }
  });

  // MARK: Where the key is taken

  var SWEEP = [
    ["residual:6", 0.208, 0.628], ["residual:8", 0.204, 0.637], ["residual:12", 0.193, 0.690], ["residual:16", 0.194, 0.690],
    ["pooled-state:8", 0.155, 0.602], ["pooled-state:12", 0.157, 0.566], ["pooled-state:16", 0.285, 0.566],
    ["state-delta:8", 0.176, 0.646], ["state-delta:12", 0.176, 0.628], ["state-delta:16", 0.186, 0.558]
  ];
  B.SWEEP = SWEEP; // board 1's sweep table reads the same rows

  B.define("key-and-index", {
    title: "The key is taken here",
    params: { scheme: { default: "residual:12" } },
    render: function (body, state, ctx) {
      var tap = parseInt(state.scheme.split(":")[1], 10), kind = state.scheme.split(":")[0];
      body.appendChild(h("div", { class: "fig-controls" }, [B.select("Key scheme", SWEEP.map(function (r) { return { value: r[0], label: r[0] + (r[0] === "residual:12" ? " · the default" : "") }; }), state.scheme, function (v) { ctx.set({ scheme: v }); })]));
      var W = 680, H = 380, colX = 30, colW = 230;
      var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "One node, its 24 blocks, and where the key is taken" });
      svg.appendChild(s("text", { x: colX, y: 16, class: "t-strong" }, "One node, bottom to top"));
      for (var b = 0; b < 24; b++) {
        var y = 350 - (b + 1) * 13, own = b < 12;
        var g = s("g", { class: own ? "s-green" : "" });
        g.appendChild(s("rect", { x: colX, y: y, width: colW, height: 11, rx: 2, style: own ? "fill: color-mix(in srgb, var(--s) 28%, var(--bg-raised)); stroke: var(--s)" : "fill: color-mix(in srgb, var(--orange) 14%, var(--bg-raised)); stroke: color-mix(in srgb, var(--orange) 60%, var(--border))" }));
        g.appendChild(s("text", { x: colX + 6, y: y + 9, class: "t-small", style: "font-size: 8.5px" }, "block " + b + (b === 0 ? " · the head, 0–11" : b === 12 ? " · the commons' trunk, 12–23" : "")));
        svg.appendChild(g);
      }
      svg.appendChild(s("rect", { x: colX, y: 352, width: colW, height: 14, rx: 2, class: "box" }));
      svg.appendChild(s("text", { x: colX + 6, y: 362, class: "t-small" }, "tokens → the commons' embedding, tied"));
      svg.appendChild(s("rect", { x: colX, y: 22, width: colW, height: 14, rx: 2, class: "box" }));
      svg.appendChild(s("text", { x: colX + 6, y: 32, class: "t-small" }, "norm_f → the normed state h, 768 floats"));
      var tapY = kind === "residual" ? 350 - tap * 13 : 350 - (tap + 1) * 13 + 5;
      svg.appendChild(s("path", { d: "M" + (colX + colW) + "," + tapY + " L" + (colX + colW + 60) + "," + tapY + " L" + (colX + colW + 60) + ",120", style: "fill: none; stroke: var(--blue); stroke-width: 2" }));
      svg.appendChild(s("path", { d: "M" + (colX + colW) + ",29 L" + (colX + colW + 90) + ",29 L" + (colX + colW + 90) + ",110", style: "fill: none; stroke: var(--blue); stroke-width: 2" }));
      svg.appendChild(s("text", { x: colX + colW + 66, y: tapY - 4, class: "t-small", style: "fill: var(--blue-ink)" }, kind === "residual" ? "mid: the residual after block " + tap : kind === "pooled-state" ? "mid: layer " + tap + "'s state, pooled" : "mid: layer " + tap + "'s state change"));
      var kx = 340, ky = 112;
      svg.appendChild(s("rect", { x: kx, y: ky, width: 320, height: 56, rx: 8, class: "box" }));
      svg.appendChild(s("text", { x: kx + 12, y: ky + 22, class: "t-strong t-mono", style: "font-size: 11.5px" }, "key = [ √½ · mid/‖mid‖ , √½ · final/‖final‖ ]"));
      svg.appendChild(s("text", { x: kx + 12, y: ky + 42, class: "t-small" }, (kind === "residual" ? "768 + 768 = 1,536" : "1,536 + 768 = 2,304") + " floats, unit length, stored as f16"));
      svg.appendChild(s("rect", { x: kx, y: ky + 80, width: 320, height: 118, rx: 8, class: "box-sunk" }));
      svg.appendChild(s("text", { x: kx + 12, y: ky + 102, class: "t-strong" }, "One index entry per position"));
      ["the key", "value: the next token", "where the key's token sits: (row, offset)", "where the value sits: (row, offset), the citation", "the transition's loss"].forEach(function (t, i) {
        svg.appendChild(s("text", { x: kx + 18, y: ky + 124 + i * 15, class: "t-small" }, "· " + t));
      });
      svg.appendChild(s("path", { d: "M" + (kx + 160) + "," + (ky + 56) + " L" + (kx + 160) + "," + (ky + 80), style: "stroke: var(--border-strong); stroke-width: 1.5" }));
      body.appendChild(svg);
      var row = SWEEP.find(function (r) { return r[0] === state.scheme; });
      body.appendChild(h("p", { class: "readout" }, [h("b", null, state.scheme), ": a fact prompt's top hit lands on the fact's own partition ", h("b", null, (row[2] * 100).toFixed(1) + "%"), " of the time; an entry's nearest other entry is in its own document " + (row[1] * 100).toFixed(1) + "% of the time, against 2.5% by chance."]));
      body.appendChild(h("p", { class: "note" }, "bench sweep-key, 2026-10-15: one Thread, 40 documents, 8,479 entries, 113 facts. The rule, fixed first: a scheme ships only if it beats the default by 0.02. None did."));
    }
  });

  // MARK: What a node sends

  B.define("node-emits", {
    title: "What a node sends",
    params: { s: { default: "harbour" }, i: { type: "int", default: 20 } },
    render: function (body, state) {
      var se = B.session(state.s), st = se.steps.find(function (x) { return x.i === state.i; }), t = se.strands.findIndex(function (x) { return !x.commons; });
      var rec = st.thr[t], th = se.threads[se.strands[t].name];
      body.appendChild(h("div", { class: "detail", style: "white-space: pre-wrap" }, [
        h("span", { class: "d" }, "NodeStep {"), "\n  position: " + (st.i - 1) + "\n  state:    768 floats, normed at the node ", h("span", { class: "d" }, "(the reed runs at the cluster; states are not logged)"),
        "\n  hits:     16 × [entry, score, value, row, offset, loss]\n", h("span", { class: "d" }, "}")]));
      body.appendChild(h("div", { class: "scroll" }, h("table", null, [h("thead", null, h("tr", null, ["entry", "score", "value", "row", "offset", "loss", "the value's text"].map(function (c, i) { return h("th", { class: i < 6 ? "n" : "" }, c); }))),
        h("tbody", null, rec.hits.slice(0, 6).map(function (hit) {
          return h("tr", { class: hit[2] === st.tok ? "match" : "" }, [hit[0], f32(hit[1]).toFixed(6), hit[2], hit[3], hit[4], f32(hit[5]).toFixed(5)].map(function (v) { return h("td", { class: "n" }, String(v)); })
            .concat([h("td", { class: "mono" }, fmt.tok(th.text(hit[3], hit[4])) + " · " + th.documents[th.partitions[hit[3]].doc].name)]));
        }))])));
      body.appendChild(h("p", { class: "note" }, "The first 6 of the 16 hits the harbour node sent before the answer's first word, " + fmt.tok(st.txt) + ". The top hit sits at row 5, offset 19 of its corpus: Harlow Light's own “ In”. A node sends no weights: its head stays where the node runs, and the trunk stays with the commons."));
    }
  });

  // MARK: The commons and a Thread

  B.define("commons-and-thread", {
    title: "The commons and a Thread, side by side",
    render: function (body) {
      var hb = harbour(), v = hb.version, seam = v.seamSHA256.slice(0, 12), pack = v.packSHA256.slice(0, 12);
      var W = 680, H = 318;
      var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "The commons node, run whole, and the harbour Thread node: its own head in front of the commons' trunk" });
      svg.appendChild(s("text", { x: W / 2, y: 14, "text-anchor": "middle", class: "t-small" }, "the reed, at the cluster: h · Eᵀ once per strand, over the same vocabulary"));
      function column(x, title, cls, rows, blocks) {
        var g = s("g", { class: cls });
        g.appendChild(s("rect", { x: x, y: 26, width: 300, height: 284, rx: 10, style: "fill: color-mix(in srgb, var(--s) 7%, var(--bg-raised)); stroke: color-mix(in srgb, var(--s) 60%, var(--border)); stroke-dasharray: " + (cls === "s-gold" ? "5 3" : "0") }));
        g.appendChild(s("text", { x: x + 14, y: 48, class: "t-strong" }, title));
        blocks.forEach(function (b, i) {
          g.appendChild(s("rect", { x: x + 14, y: 62 + i * 34, width: 272, height: 28, rx: 5, style: "fill: " + b[1] + "; stroke: " + (b[2] ? "var(--orange-ink); stroke-dasharray: 4 3" : "var(--border-strong)") }));
          g.appendChild(s("text", { x: x + 24, y: 80 + i * 34, class: "t-small" }, b[0]));
        });
        rows.forEach(function (r, i) { g.appendChild(s("text", { x: x + 14, y: 218 + i * 17, class: "t-small" + (i === 0 ? " t-strong" : "") }, r)); });
        svg.appendChild(g);
      }
      var trunk = "color-mix(in srgb, var(--orange) 16%, var(--bg))";
      column(10, "The commons", "s-gold", ["the yardstick, credited to nobody", "no index · λ 0 · every Thread's lift is over it", "its blocks 12–23, norm_f and embedding", "are the trunk every Thread runs", "the pack " + pack + " · seam " + seam],
        [["norm_f · the trunk's", "var(--bg)"], ["blocks 12–23 · the trunk every Thread runs", trunk], ["blocks 0–11 · its head, as imported", trunk], ["the embedding · the trunk's, tied", "var(--bg)"]]);
      column(370, "The harbour Thread", "s-blue", ["one corpus: the playground's 18 records", "index: " + v.entries + " entries · λ 0.5 · τ 0.05", "head " + v.blocksSHA256.slice(0, 12) + " · index " + v.indexSHA256.slice(0, 12), "runs the commons' trunk · seam " + seam, "another pack or seam is refused before it joins"],
        [["norm_f · the commons'", "var(--bg)", true], ["blocks 12–23 · the commons' trunk, by reference", trunk, true], ["blocks 0–11 · its head, trained on its 18 records", "color-mix(in srgb, var(--green) 26%, var(--bg))"], ["the embedding · the commons', tied", "var(--bg)", true]]);
      // The Thread's dashed trunk is the commons' solid one: the same modules, one object.
      var y = 62 + 34 + 14;
      svg.appendChild(s("path", { d: "M384," + y + " L300," + y, style: "fill: none; stroke: var(--orange-ink); stroke-width: 1.5; stroke-dasharray: 4 3" }));
      svg.appendChild(s("path", { d: "M296," + y + " L304," + (y - 4) + " L304," + (y + 4) + " Z", style: "fill: var(--orange-ink)" }));
      svg.appendChild(s("text", { x: 340, y: y - 6, "text-anchor": "middle", class: "t-small", style: "fill: var(--orange-ink)" }, "one object"));
      body.appendChild(svg);
      body.appendChild(h("p", { class: "note" }, "Both run a head and then the same trunk, the commons', each on its own state of 19,390,464 bytes. The Thread's head is 45.2M parameters, 181 MB a version; the commons' trunk is the pack's other 83.8M, loaded once. A Thread built on another pack, or trained against another seam, is refused before it joins."));
    }
  });
})();
