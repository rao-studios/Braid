/*
 * Board 3, the model in detail: the braid at a glance (the overview figure), a Thread node and the
 * commons node tensor by tensor, the two inner entropies from a state to a citation's value and
 * location, one real answer token by token (the chapters' entropy figure, a table recomputed from the
 * Joltvault log, and the notes), one Mamba2 mixer (the chapters' block figure), one token call by call,
 * and the debug map. Every number carries its date.
 */
(function () {
  "use strict";
  var B = window.Braid, h = B.h, s = B.s, fmt = B.fmt, draw = B.draw, panel = B.panel, boards = B.boards;

  /** A node, tensor by tensor, bottom to top. kind: "thread" or "commons". */
  function column(kind) {
    var thread = kind === "thread", W = 560, x = 16, w = 296, sx = 328, sw = 216, seam = boards.seam12();
    var stack = [
      { k: "in", h: 22, cls: "bd-plain", lines: ["tokens in · [B, L] int32"] },
      { k: "emb", h: 40, cls: "bd-emb", lines: ["Token embedding · 50,288 × 768", "the commons', frozen, in and out"] },
      { k: "head", h: 158, frame: true, cls: thread ? "bd-own" : "bd-gold", title: "×12 · blocks 0–11 · the head", sub: thread ? "trained on this corpus · the only weights it owns" : "as imported · frozen" },
      { k: "tail", h: 158, frame: true, cls: "bd-tail", dashed: thread, title: thread ? "×12 · blocks 12–23 · the commons' tail" : "×12 · blocks 12–23 · the tail", sub: thread ? "one object, by reference · seam " + seam : "run by every Thread · seam " + seam },
      { k: "norm", h: 24, cls: "bd-norm", lines: ["norm_f · at the node · RMSNorm, eps 1e-5"] },
      { k: "out", h: 36, wide: true, cls: "bd-state", lines: thread ? ["h · 768 and 16 hits → the braid", "a normed state and its hits: value, row, offset, loss · NodeStep"] : ["h · 768 → the braid", "a normed state and no hits · NodeStep"] }
    ];
    var gap = 18, tapGap = 30, top = 14, total = stack.reduce(function (a, st) { return a + st.h; }, 0) + gap * (stack.length - 2) + tapGap;
    var H = top + total + 46;
    var svg = draw.svg(W, H, thread ? "A Thread node tensor by tensor: the embedding, its head, the key tap into its own index, the commons' tail, the final norm, its state and hits"
                                     : "The commons node tensor by tensor: the pack run whole, no index, the yardstick");
    var g = s("g");
    svg.appendChild(g);
    var y = H - 46, at = {};
    stack.forEach(function (st) { y -= st.h; at[st.k] = y; y -= st.k === "head" ? tapGap : gap; });
    stack.forEach(function (st, i) {
      var yy = at[st.k], bw = st.wide ? sx + sw - x : w;
      if (st.frame) {
        draw.box(g, { id: "b3-" + kind + "-" + st.k, part: st.k, x: x, y: yy, w: w, h: st.h, cls: st.cls, dashed: st.dashed, rx: 8, lines: [] });
        draw.text(g, x + w / 2, yy + 15, st.title, "bd-t", "middle");
        draw.text(g, x + w / 2, yy + 29, st.sub, "bd-sub", "middle");
        var ix = x + 12, iw = w - 24;
        draw.box(g, { x: ix, y: yy + 38, w: iw, h: 20, cls: "bd-norm", rx: 4, lines: ["RMSNorm · [B, L, 768]"], titleCls: "bd-sub" });
        draw.box(g, { x: ix, y: yy + 64, w: iw, h: 64, cls: "bd-mixer", rx: 4, lh: 12, lines: ["Mamba2 mixer", "in_proj 768→3,352 · conv1d, kernel 4", "SSD scan · S [24, 64, 128] per layer", "gated RMSNorm · out_proj 1,536→768"], titleCls: "bd-sub" });
        draw.box(g, { x: ix, y: yy + 134, w: iw, h: 18, cls: "bd-plain", rx: 4, lines: ["+ the residual · [B, L, 768]"], titleCls: "bd-sub" });
      } else {
        draw.box(g, { id: "b3-" + kind + "-" + st.k, part: st.k, x: x, y: yy, w: bw, h: st.h, cls: st.cls, lines: st.lines, lh: 12 });
      }
      if (i > 0) { var below = stack[i - 1]; draw.arrow(g, x + w / 2, at[below.k], x + w / 2, yy + st.h + 1); }
    });
    var cx = sx + sw / 2;
    if (thread) {
      // The key tap: the residual after the head, into the Thread's own index beside the tail.
      var tapY = at.head - tapGap / 2, ky = tapY - 24, iy = at.tail + 12, ih = 72;
      draw.arrow(g, x + w / 2, tapY, sx - 1, tapY, { part: "key" });
      draw.text(g, x + w / 2 + 8, tapY - 5, "key tap", "bd-key-t", "start");
      draw.box(g, { id: "b3-thread-key", part: "key", x: sx, y: ky, w: sw, h: 48, cls: "bd-state", lh: 12, lines: ["Provenance key · 1,536 floats", "[√½·mid/‖mid‖, √½·final/‖final‖]", "ProvenanceKey.make"] });
      draw.box(g, { id: "b3-thread-index", part: "index", x: sx, y: iy, w: sw, h: ih, cls: "bd-own", lh: 12, lines: ["Provenance index · its own corpus", "one entry per position · entry e+1 follows e", "the 16 nearest → the hits", "ProvenanceIndex.query"] });
      draw.arrow(g, cx, ky, cx, iy + ih + 1, { part: "key" });
      draw.arrow(g, cx, iy, cx, at.out + 36 + 1, { part: "index" });
    } else {
      draw.box(g, { id: "b3-commons-noindex", part: "index", x: sx, y: at.tail + 40, w: sw, h: 56, cls: "bd-plain", dashed: true, lh: 12, lines: ["no index", "no key, no hits · H_knn 0", "the yardstick · credited to nobody"] });
    }
    draw.text(g, (x + sx + sw) / 2, H - 28, thread ? "Thread node · ambient · state 19.4 MB · 24 layers" : "Commons node · the pack as imported · state 19.4 MB · 24 layers", "bd-cap", "middle");
    draw.text(g, (x + sx + sw) / 2, H - 12, thread ? "its head and its index are its own; the tail it runs is the commons'" : "its head is the pack's; its blocks 12–23 are every Thread's tail", "bd-sub", "middle");
    return svg;
  }

  /** The two inner entropies: from a state to a citation's value and location. */
  function entropies() {
    var W = 940, H = 470;
    var svg = draw.svg(W, H, "The two inner entropies: the reed's distribution and its entropy on the left, the hits' distribution and its entropy on the right, the mixture and the shares between them, and the citation's value, location and trace below");
    var g = s("g");
    svg.appendChild(g);
    var cw = 210, lx = 20, rx = W - 20 - cw, mx = (W - cw) / 2, bh = 46, rows = [20, 86, 152, 218];
    var left = [["h_t · 768", "normed at the node · NodeStep.state"], ["logits = h · Eᵀ", "the reed, at the cluster · MLXReed.logits"], ["p_lm(y) = softmax(logits)", "over 50,277 tokens · Expert.plm"], ["H_lm = −Σ p ln p · the claim", "how spread its own guess is"]];
    var right = [["16 hits · value, row, offset, loss", "the index's nearest · NodeStep.hits"], ["w_i = softmax(s_i / τ), τ 0.05", "Mixer.weights"], ["p_knn(y) = Σ w_i [v_i = y]", "the evidence · Expert.knn"], ["H_knn ≤ ln 16 · the evidence", "how spread the hits are"]];
    left.forEach(function (l, i) { draw.box(g, { x: lx, y: rows[i], w: cw, h: bh, cls: i === 3 ? "bd-state" : "bd-plain", lines: l }); if (i) draw.arrow(g, lx + cw / 2, rows[i - 1] + bh, lx + cw / 2, rows[i] - 1); });
    right.forEach(function (l, i) { draw.box(g, { x: rx, y: rows[i], w: cw, h: bh, cls: i === 3 ? "bd-state" : "bd-plain", lines: l }); if (i) draw.arrow(g, rx + cw / 2, rows[i - 1] + bh, rx + cw / 2, rows[i] - 1); });
    var mid = [["p_t = ½ · p_knn + ½ · p_lm", "a Thread's blend · λ 0.5, the commons 0"], ["w′_t = m_t / Σ_open m", "the gate's memory, renormalised · Gate.renormalised"], ["p(y) = Σ_t w′_t · p_t(y)", "the braid's one distribution · Mixer.mix"], ["share_t = w′_t · p_t(y) / p(y)", "the citation's value · Mixer.shares"]];
    mid.forEach(function (l, i) { draw.box(g, { x: mx, y: rows[i] + 33, w: cw, h: bh, cls: i === 3 ? "bd-gold" : "bd-plain", lines: l }); if (i) draw.arrow(g, mx + cw / 2, rows[i - 1] + 33 + bh, mx + cw / 2, rows[i] + 33 - 1); });
    draw.arrow(g, lx + cw, rows[2] + bh / 2, mx - 1, rows[0] + 33 + bh / 2);
    draw.arrow(g, rx, rows[2] + bh / 2, mx + cw + 1, rows[0] + 33 + bh / 2);
    var by = 320, bw = 296, bx = [20, (W - bw) / 2, W - 20 - bw];
    draw.box(g, { x: bx[0], y: by, w: bw, h: 70, cls: "bd-violet", lh: 12, lines: ["The citation's location", "the hits whose value is the chosen token, grouped by row;", "the best gives the partition and its offset", "Spans.annotate · the receipt a span re-reads"] });
    draw.box(g, { x: bx[1], y: by, w: bw, h: 70, cls: "bd-violet", lh: 12, lines: ["The trace, on top of the citations", "a chain advances when the written token is the entry's next;", "trace = clamp((L − 24) / 72, 0, 1) · logged, never applied", "TraceTracker.step"] });
    draw.box(g, { x: bx[2], y: by, w: bw, h: 70, cls: "bd-violet", lh: 12, lines: ["What reads the entropies", "H_lm → the module's label at each position:", "collapsed, retrieval, stitched, unknown, commons", "H_knn → its slope over 8 positions · e_t · κ 0"] });
    draw.arrow(g, rx + cw / 2, rows[3] + bh, bx[0] + bw / 2, by - 1, { dashed: true });
    draw.arrow(g, mx + cw / 2, rows[3] + 33 + bh, bx[1] + bw / 2, by - 1, { dashed: true });
    draw.arrow(g, rx + cw / 2 + 60, rows[3] + bh, bx[2] + bw / 2, by - 1, { dashed: true });
    draw.text(g, 20, H - 46, ["H_lm is the claim: how sure the Thread's own guess is. Low with the commons low means it is guessing on ground the commons already knows.",
                             "H_knn is the evidence: how far the 16 hits agree on one token. Low with a high H_lm means a span that is retrieved, not generated.",
                             "Lift over the commons decides the gate, ln p_t(y) − ln p_c(y), at prompt positions only; the two entropies are logged and read, never applied."], "bd-sub", "start", 14);
    return svg;
  }

  /** Panel C's table, recomputed from the Joltvault log: every position with strands, the holder Craft in front. */
  function panelCTable() {
    var se = B.session("joltvault"), c = se.strands.findIndex(function (x) { return x.name === "craft"; }), commons = se.commons;
    var mod = se.module()[c], readings = mod.readings, ann = se.annotate().annotations;
    var steps = se.steps.filter(function (st) { return st.thr && st.src !== "ctx"; });
    var cols = [{ label: "", n: false }].concat(steps.map(function (st) { return { label: fmt.raw(st.txt), n: true }; }));
    function row(label, f) { return { cells: [{ text: label, cls: "bd-lead" }].concat(steps.map(function (st, j) { var v = f(st, j); return v === null || v === undefined ? "–" : typeof v === "number" ? fmt.n(Math.abs(v) < 5e-3 ? 0 : v, 2) : String(v); })) }; }
    var rows = [
      row("source", function (st) { return st.src === "prompt" ? "prompt" : "gen"; }),
      row("H_lm · Craft", function (st) { return st.thr[c].Hlm; }),
      row("H_knn · Craft", function (st) { return st.thr[c].Hknn; }),
      row("lift · Craft", function (st) { return commons === null || st.thr[c].plm === undefined ? null : Math.log(Math.max(st.thr[c].plm, 1e-30)) - Math.log(Math.max(st.thr[commons].plm, 1e-30)); }),
      row("evidence ρ · Craft", function (st) { return st.thr[c].ev === undefined ? null : st.thr[c].ev; }),
      row("memory · Craft", function (st) { return st.thr[c].mem; }),
      row("memory · commons", function (st) { return commons === null ? null : st.thr[commons].mem; }),
      row("share · Craft", function (st) { return st.thr[c].share; }),
      row("trace L · Craft", function (st) { return String(st.thr[c].tr ? st.thr[c].tr.L : 0); }),
      row("module label", function (st, j) { return readings[j] ? readings[j].label : null; }),
      row("e_t logged", function (st) { return st.thr[c].mod; }),
      row("span", function (st) { var k = se.sharedAt(se.steps.indexOf(st)); var a = ann[k]; return a && a.spanIndex !== null ? "span " + (a.spanIndex + 1) : ""; })
    ];
    return { table: panel.table(cols, rows), steps: steps, c: c };
  }

  boards.define("b3-overview", boards.reuse("overview", { step: 0 }, {
    board: 3, title: "Three Threads and the commons, drawn like Figure 1", chapter: "index.html", anchor: "fig-overview",
    caption: "The same braid as the overview, at a first reading's grain; the two columns beside it go tensor by tensor."
  }));
  boards.define("b3-thread-column", {
    board: 3, title: "A Thread node, tensor by tensor", chapter: "04-commons.html",
    caption: "A Thread node, tensor by tensor: its own head and index, the commons' tail by reference, one state of 19.4 MB.",
    render: function (body) { body.appendChild(column("thread")); }
  });
  boards.define("b3-commons-column", {
    board: 3, title: "The commons node, tensor by tensor", chapter: "04-commons.html",
    caption: "The commons node: the pack run whole, no index, λ 0, the yardstick; its blocks 12–23 are the tail every Thread runs.",
    render: function (body) { body.appendChild(column("commons")); }
  });
  boards.define("b3-entropies", {
    board: 3, title: "The two inner entropies", chapter: "06-provenance.html",
    caption: "The two inner entropies: from a state to a citation's value and location, with the trace on top.",
    render: function (body) {
      body.appendChild(entropies());
      body.appendChild(panel.note("Per Thread, per position; logged as Hlm and Hknn and replayed by braid verify. Every box names the code that computes it."));
    }
  });
  boards.define("b3-citation-location", {
    board: 3, title: "The citation's location", chapter: "06-provenance.html",
    caption: "The citation's location: the hits whose value is the chosen token, and the best one's row and offset.",
    render: function (body) {
      body.appendChild(panel.formula({ lead: "The citation's location", lines: ["hits with value = y, grouped by row", "best = the highest score · (row, offset) → the partition and its token"],
        why: "A span is three or more tokens in a row walking one partition in order, each with a matching hit at rank three or better; verify re-reads it from the source. Spans.annotate." }));
    }
  });
  boards.define("b3-reads-hknn", {
    board: 3, title: "What reads H_knn", chapter: "08-trace.html",
    caption: "What reads H_knn: the trajectory module, whose e_t is logged and enters the gate only through κ, which is 0.",
    render: function (body) {
      body.appendChild(panel.formula({ lead: "The trajectory module", lines: ["slope = OLS over the last 8 H_knn", "c = clamp(−slope / s_ref, 0, 1) · d = clamp(slope / s_ref, 0, 1)", "e_t = c − d · s_ref = ln 16 / 8"],
        why: "Logged as mod at prompt and context positions beside the shadow β4; it reaches the gate only as κ · e_t · ln R, and κ is 0. LiveModule.push, TrajectoryModule.read." }));
    }
  });
  boards.define("b3-trace-box", {
    board: 3, title: "The trace", chapter: "08-trace.html",
    caption: "The trace, on top of the citations: a chain through one document, logged and replayed, never applied.",
    render: function (body) {
      body.appendChild(panel.formula({ lead: "The trace", lines: ["a chain advances when the written token is its entry's next token", "trace = clamp((L − 24) / 72, 0, 1) · phrase 24, arc 96, bridge 8, heads 8, seeds 4"],
        why: "RaoLM's tracker, unchanged, run at the cluster from the logged hits; braid verify replays every chain state. TraceTracker.step." }));
    }
  });
  boards.define("b3-panel-c-chart", boards.reuse("entropy", { s: "joltvault", i: 10, whatif: "no", from: 1 }, {
    board: 3, title: "One real answer: H_lm and H_knn", chapter: "00-entropy.html", anchor: "fig-two-entropies",
    caption: "One real answer, the Joltvault port: H_lm and H_knn for the holder Craft, token by token."
  }));
  boards.define("b3-panel-c-table", {
    board: 3, title: "One real answer, token by token", chapter: "10-verify.html",
    caption: "One real answer, every number recomputed from its log: lift, evidence, memory, share, trace and the module, token by token.",
    render: function (body) {
      var t;
      try { t = panelCTable(); } catch (e) { body.appendChild(panel.note("The Joltvault session's data is not loaded on this page.")); return; }
      body.appendChild(t.table);
      body.appendChild(panel.note("The Joltvault session, read from data/sessions/joltvault.js: " + t.steps.length + " positions with strands, Craft the holder. Lift is ln p_lm,craft − ln p_lm,commons; evidence ρ is the clamped ratio the gate observed at prompt positions; e_t is the trajectory module's reading, logged and never applied."));
    },
    selfCheck: function () {
      var se; try { se = B.session("joltvault"); } catch (e) { return [{ name: "the Joltvault session is loaded", ok: false, detail: e.message }]; }
      var worst = 0;
      se.steps.forEach(function (st) { if (!st.thr || st.src === "ctx") return; var sum = st.thr.reduce(function (a, r) { return a + r.share; }, 0); worst = Math.max(worst, Math.abs(sum - 1)); });
      return [{ name: "the shares in the table sum to 1 at every position", ok: worst <= 1e-5, detail: "worst " + fmt.e(worst) }];
    }
  });
  boards.define("b3-panel-c-notes", {
    board: 3, title: "Reading the real answer", chapter: "08-trace.html",
    caption: "Reading the real answer: what moved the gate, and what only logged.",
    render: function (body) {
      body.appendChild(panel.list([
        { lead: "Prompt, positions 1–9:", text: "every strand asked, lift moves the memory. Craft's p beats the commons' by up to 10 : 1, clamped; its memory climbs from 0.033 to 0.919 while the commons falls from 0.900 to 0.003. The entropies are logged here, but they move nothing." },
        { lead: "The answer:", text: "H_lm stays near 0, while H_knn separates the fact from the template. It is low on \"410\" and \"27\", the port, and rises on template words, which are shared across Craft's documents." },
        { lead: "The trajectory:", text: "the trace walks one document; the trace's head is on row 207, walking offset 7 to 12 in order. Craft's lift is highest exactly where its H_knn is lowest." },
        { lead: "The location:", text: "two spans, not one, since the citation's partition is the one with the exact tokens in order; both re-read from the snapshot." },
        { lead: "The module's call:", text: "retrieval at 11 of 21 positions, stitched at 2 of 21, never 8 in a row, so the flag stays off; its e_t is logged and reaches the gate through κ, which is 0." }
      ]));
    }
  });
  boards.define("b3-mixer", boards.reuse("block", { L: 128 }, {
    board: 3, title: "One Mamba2 mixer, tensor by tensor", chapter: "09-ssd.html", anchor: "fig-block",
    caption: "One Mamba2 mixer, tensor by tensor, over a 128-token prompt."
  }));
  boards.define("b3-call-by-call", {
    board: 3, title: "One token, call by call", chapter: "07-inference.html",
    caption: "One token, call by call: where to put a breakpoint, on the node and at the cluster.",
    render: function (body) {
      function code(name, text) { return { lead: text + " ·", text: h("a", { href: B.root() + "code.html#q=" + encodeURIComponent(name), title: "Find it in the code explorer" }, name) }; }
      body.appendChild(h("div", { class: "grid2" }, [
        h("div", { class: "panel" }, [h("h4", null, "On the node, per Thread"), panel.list([
          code("LocalNode.open", "A session opens on eos ‖ prompt: one forward from a zero state"),
          code("LocalNode.advance", "Each token after that: one step"),
          code("LanguageModule.step", "24 × Mamba2Block.step: twelve of its head, twelve of the commons' tail"),
          code("SSD.step", "Per block, the recurrence: S ← e^(dt·A) S + dt · x Bᵀ"),
          code("ProvenanceKey.make", "The key: mid ⊕ final, 1,536 floats, unit length"),
          code("ProvenanceIndex.query", "The 16 nearest entries of its own corpus"),
          code("NodeStep", "What leaves the node: position, state, hits")
        ], { ordered: true })]),
        h("div", { class: "panel" }, [h("h4", null, "At the cluster, per token: Cluster.generate"), panel.list([
          code("MLXReed.logits", "The reed once per strand: h · Eᵀ"),
          code("Expert", "p_lm, p_knn, H_lm, H_knn from the logits and the hits"),
          code("TraceTracker.step", "The chains advance; L and the trace"),
          code("Gate.weights", "The memory as weights; Gate.open the open set; Mixer.mix the braid's p(y)"),
          code("Mixer.choose", "The likeliest token, ties to the oldest cited document"),
          code("Mixer.shares", "The receipt: each strand's exact share"),
          code("LiveModule.push", "The trajectory module reads the entropies; e_t logged"),
          code("SessionWriter.append", "One line into the log")
        ], { ordered: true })])
      ]));
      body.appendChild(panel.note("After the answer: Spans.annotate, Credit.assign, FollowedCredit.apply and Royalties.view derive the views from the log; braid verify replays the arithmetic, the memory recursion, every trace and every span."));
    }
  });
  boards.define("b3-debug-map", {
    board: 3, title: "The debug map", chapter: "10-verify.html",
    caption: "The debug map: a symptom, the first place to look, and the test that covers it.",
    render: function (body) {
      body.appendChild(panel.table(["symptom", "first place to look", "the test that covers it"], [
        ["Import logits differ from the reference", "the conv1d weight's transpose; dt = clip(softplus(dt + dt_bias)); A = −exp(A_log)", "ImportConformanceTests · within 2.8e-4"],
        ["The chunked forward differs from the step", "the chunk boundaries in SSD.scan; the carry between chunks", "SSDTests · the scan equals the step"],
        ["Packed documents leak into each other", "the resets mask over the conv window and the state", "SSDTests · packed with resets equals per-document"],
        ["Gradients are wrong, or eval fails in a graph", "no eval inside SSD.scan; the commons' tail is frozen when it is built, so only the head carries gradients", "SSDTests · gradients equal the unrolled form"],
        ["A Thread refuses to load: trained against seam …", "the version's seam and cut against the commons' tail: another pack or another cut; rebuild the Thread on this pack", "CommonsTailTests · the seam refusal"],
        ["A head file is refused: a block of the tail", "blocks.safetensors holds a block at or past the cut; a head holds blocks 0–11 only", "CommonsTailTests · makeHead"],
        ["A key does not replay", "the checkpoint's hash and its prefix hash; the key scheme and alpha in index.json", "ReplayTests, CheckpointReplayTests · within 1.1e-6"],
        ["The state is the wrong shape", "24 layers of [B, 3, 1,792] and [B, 24, 64, 128]; the pack it belongs to", "StateStack.from · SSDTests"],
        ["H_lm is huge, or NaN", "the padding rows at −∞; the normed state h", "MLXReed.logits · ImportConformanceTests"],
        ["H_knn does not replay", "the 16 logged hits in order; τ", "braid verify · H_knn from the hits"],
        ["The commons' H_knn is always 0", "expected: the commons has no index and returns no hits", "LocalNode.hits"],
        ["Shares do not sum to 1", "the open set and its renormalisation", "MixerTests · sharesAtScale"],
        ["The memory recursion fails in verify", "the clamp ±ln 10; prompt positions only; the module term at κ 0", "GateTests · braid verify"],
        ["Citations land on the wrong Thread after an attach or a detach", "every step read through the strand slots it was recorded with", "SpansAndCreditTests · viewsFollowMembership"],
        ["A span breaks into a phrase", "the matching hit's rank ≤ 3; the break tokens excluded; three tokens in order", "SpansAndCreditTests"],
        ["The trace is 0 everywhere", "a chain advances only when the written token equals its entry's next; the tracker runs over the logged hits", "TraceTests · the port's 226,790 chains"],
        ["mod is nonzero but the gate does not move", "κ, [gate] module_gain, is 0", "GateTests · κ 0 equals the module off"],
        ["Trace mismatches after an attach", "the tracker seeded from the catch-up hits on the attach line", "SessionTests · attachDetach, NodeContinuityTests"]
      ]));
    }
  });
})();
