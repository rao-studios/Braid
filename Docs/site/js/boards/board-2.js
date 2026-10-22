/*
 * Board 2, the braid: the answer and its log, the mixture and the shadow, the gate, the four strands
 * over their nodes with the commons' tail every Thread runs, the sources, one token in order, attach
 * and detach, asking a question, what verify replays, the measured rules from PAPER.md's own data, and
 * the open decisions from ARCHITECTURE.md's findings. Every number carries its date.
 */
(function () {
  "use strict";
  var B = window.Braid, h = B.h, s = B.s, draw = B.draw, panel = B.panel, boards = B.boards;

  var STRANDS = [
    { key: "commons", name: "Commons", cls: "s-gold" },
    { key: "ambient", name: "Ambient", cls: "s-blue" },
    { key: "craft", name: "Craft", cls: "s-green" },
    { key: "veil", name: "Veil", cls: "s-orange" }
  ];

  /** The strands over their nodes over their sources. `only`: "strands" (the top two rows) or "sources" (the bottom two). */
  function strands(only) {
    var W = 940, m = 14, cols = 4, gapX = 16, cw = (W - 2 * m - (cols - 1) * gapX) / cols;
    var rows = only === "sources" ? ["nodes", "sources"] : only === "strands" ? ["strands", "nodes"] : ["strands", "nodes", "sources"];
    var nodeH = 96, stripH = 22, heights = { strands: 92, nodes: nodeH + 6 + stripH, sources: 60 }, gapY = 44, top = 12;
    var H = top + rows.reduce(function (a, k) { return a + heights[k]; }, 0) + gapY * (rows.length - 1) + 30;
    var svg = draw.svg(W, H, "The commons and three Threads: each strand's distribution over its node, the commons' tail every Thread runs, and the sources the nodes come from");
    var g = s("g");
    svg.appendChild(g);
    var y = top, at = {};
    rows.forEach(function (k) { at[k] = y; y += heights[k] + gapY; });
    var seam = boards.seam12();
    STRANDS.forEach(function (st, i) {
      var x = m + i * (cw + gapX), cx = x + cw / 2, commons = st.key === "commons";
      if (at.strands !== undefined) {
        draw.box(g, { id: "b2-strand-" + st.key, part: "strands", strand: st.cls, x: x, y: at.strands, w: cw, h: heights.strands, cls: "bd-frame-fill",
                      lines: commons ? ["p_c = softmax(reed(h))", "the base model's own guess", "the yardstick every Thread", "is measured against"]
                                     : ["p_t = ½ p_knn + ½ p_lm", "p_lm from the reed, p_knn from its 16 hits", "trace: how far its hits follow", "one of its documents, in order"] });
        if (at.nodes !== undefined) {
          draw.arrow(g, cx, at.nodes - 2, cx, at.strands + heights.strands + 1);
          draw.text(g, cx + 6, at.strands + heights.strands + gapY / 2 + 4, commons ? "h" : "h + 16 hits", "bd-sub", "start");
        }
      }
      if (at.nodes !== undefined) {
        draw.box(g, { id: "b2-node-" + st.key, part: "nodes", strand: st.cls, x: x, y: at.nodes, w: cw, h: nodeH, cls: commons ? "bd-tail-solid" : "bd-frame-fill",
                      lines: commons ? ["Commons node · the pack run whole", "its blocks 12–23, norm_f and the embedding", "are the tail every Thread runs", "no index · λ 0 · credited to nobody"]
                                     : [st.name + " node", "its head: blocks 0–11, trained on its " + (st.key === "veil" ? "corpus" : "lane"), "its own index · λ 0.5", "a 19.4 MB state"] });
        // The strip under each node: the tail it runs. The commons holds it; every Thread's strip is the same object, chained back to it.
        var sy = at.nodes + nodeH + 6;
        draw.box(g, { id: "b2-tail-" + st.key, part: "tail", x: x, y: sy, w: cw, h: stripH, cls: "bd-tail", dashed: !commons, rx: 4,
                      lines: [commons ? "the tail · blocks 12–23, norm_f, the embedding · seam " + seam.slice(0, 6) : "the commons' tail, by reference"], titleCls: "bd-sub" });
        if (!commons) draw.arrow(g, x, sy + stripH / 2, x - gapX + 1, sy + stripH / 2, { dashed: true, cls: "bd-tail-line" });
        if (at.sources !== undefined) draw.arrow(g, cx, at.sources - 2, cx, at.nodes + nodeH + 6 + stripH + 1, { dashed: true });
      }
      if (at.sources !== undefined) {
        var src = commons ? ["The pack · mamba2-130m-hf", "imported once: the commons' whole,", "and every head's start"] : st.key === "veil" ? ["Dataset node", "braid-n3#veil"] : ["AII lane", (st.key === "ambient" ? "demo-a/ambient" : "demo-b/craft")];
        draw.box(g, { id: "b2-src-" + st.key, part: "sources", strand: st.cls, x: x, y: at.sources, w: cw, h: heights.sources, cls: "bd-plain", lines: src });
      }
    });
    draw.text(g, m, H - 10, "NODES · in process today, each behind the node protocol, which is the wire · the strip under each node is the tail it runs, the commons' own", "bd-cap", "start");
    return svg;
  }

  boards.define("b2-answer", boards.reuse("replay", { s: "joltvault", i: 10, panels: ["strip", "detail"] }, {
    board: 2, title: "The answer", chapter: "00-entropy.html", anchor: "fig-receipt",
    caption: "The answer, each token in the colour of the strand that supplied it, with the token block the studio prints."
  }));
  boards.define("b2-session-log", {
    board: 2, title: "The session log", chapter: "10-verify.html",
    caption: "The session log: one line per position, every strand's numbers and hits, replayed by braid verify.",
    render: function (body) {
      var se = null;
      try { se = B.session("joltvault"); } catch (e) { se = null; }
      body.appendChild(panel.list([
        ["One line per position, every strand:", "memory, w′, p_lm, p_knn, share, H_lm, H_knn, the 16 hits and the trace."],
        ["Two entropies stored,", "H_lm and H_knn; lift, credit, spans and royalties are derived when the log is read."],
        se ? ["This site's Joltvault answer:", se.steps.length + " lines for " + se.strands.length + " strands, " + (se.steps.length - se.firstGen) + " of them generated, replayed by the self-test on every visit."] : "The Joltvault session is replayed where its data is loaded.",
        ["braid verify replays it:", "the body hash, every share, the gate's memory, the shadow, every chain, every span re-read from its source."]
      ]));
    }
  });
  boards.define("b2-mixture", {
    board: 2, title: "The mixture and the shares", chapter: "07-inference.html",
    caption: "The mixture is one sum over the open strands, so each strand's share of a token is exact.",
    render: function (body) {
      body.appendChild(panel.formula({ lead: "The mixture", lines: ["p(y) = Σ_t w′_t · p_t(y)", "share_t = w′_t · p_t(y) / p(y)"],
        why: "The token is the likeliest y. The shares sum to 1 at every token, and each Thread's part is cited to the partition its matching hit came from." }));
    }
  });
  boards.define("b2-shadow", {
    board: 2, title: "Shadow β4", chapter: "08-trace.html",
    caption: "Shadow β4: the trace gate RaoLM settled on, logged at every token and never applied.",
    render: function (body) {
      body.appendChild(panel.formula({ lead: "Shadow β4", lines: ["g^sh_t ∝ m_t · e^(4 · (trace_t − mean trace))"],
        why: "Computed beside the live gate and renormalised over the open strands; the share each strand would have had under it is logged as sg and ss, never applied." }));
    }
  });
  boards.define("b2-gate", {
    board: 2, title: "The gate", chapter: "07-inference.html",
    caption: "The gate: a memory of who has been predicting, moved by lift at prompt tokens only.",
    render: function (body) {
      body.appendChild(panel.formula({ lead: "The gate · a memory of who has been predicting",
        lines: ["memory starts at 0.9 on the commons and 0.1 across the Threads", "at every prompt token, a Thread's evidence is its lift over the commons, ln(p_t / p_c), clamped to 10 : 1", "w′ = memory renormalised over the open strands"],
        why: "A Thread under the open floor closes; the commons and the leader never do. Generated tokens never move the memory. One clamp holds for everything, the module included: no token moves the memory past ten to one." }));
    }
  });
  boards.define("b2-strands", {
    board: 2, title: "One braid, four strands", chapter: "04-commons.html",
    caption: "The commons and three Threads: one yardstick, three corpora, and one tail, the commons', that every Thread runs behind its own head.",
    render: function (body) {
      body.appendChild(strands("strands"));
      body.appendChild(panel.note("Flows bottom to top: the commons and three Threads on mamba2-130m-hf, λ 0.5, τ 0.05, k 16. The commons runs the pack whole; each Thread runs its head in front of the commons' blocks 12–23, the dashed line, as the same modules."));
    }
  });
  boards.define("b2-sources", {
    board: 2, title: "Nodes and their sources", chapter: "01-aii.html",
    caption: "Nodes and their sources: two AII lanes, a dataset node, and the pack the commons comes from.",
    render: function (body) { body.appendChild(strands("sources")); }
  });
  boards.define("b2-one-token", {
    board: 2, title: "One token, in order", chapter: "07-inference.html",
    caption: "One token, in order: every node advances, the braid guesses, weighs, picks, and logs.",
    render: function (body) {
      body.appendChild(panel.list([
        "Each node advances one token: its state steps through its head and then the commons' tail, 24 blocks, and it sends its normed state h and its 16 nearest positions.",
        "The braid runs the reed once per strand, giving p_lm. The hits give p_knn. A Thread mixes the two, half and half; the commons uses its guess alone.",
        "The trace tracker follows each Thread's hits through its own documents. The trajectory module reads the slope of H_knn. Both are logged; neither steers.",
        "The gate's memory gives each strand a weight. Strands under the open floor close; the commons and the leader stay open.",
        "The mixture picks the token. Each strand's share of it is exact.",
        "One line goes into the log: every strand's numbers and hits. Spans, credit and royalties are read from it afterwards.",
        "On prompt tokens only, the memory learns from each Thread's lift over the commons. Generated tokens never move it."
      ], { ordered: true }));
    }
  });
  boards.define("b2-attach", {
    board: 2, title: "Attach and detach, mid-answer", chapter: "07-inference.html",
    caption: "Attach and detach, mid-answer: a Thread catches up in one forward pass and joins at the next token.",
    render: function (body) {
      body.appendChild(panel.list([
        "A Thread attaching mid-answer runs one forward pass over the session so far and joins at the next token: 12 tokens caught up in 0.05 s.",
        "It takes its share of the Threads' memory pro rata; a detached Thread's memory returns the same way. Memory always sums to 1.",
        "Its catch-up hits are written on the attach line, so its trace replays exactly.",
        "Every step is read through the strands it was recorded with, so a citation never lands on the wrong Thread after a change.",
        "In the studio, space attaches or detaches the focused Thread. From the CLI: braid cluster spawn --attach craft@4 --detach ambient@8.",
        { lead: "Measured, 2026-10-15:", text: "six Threads and the commons, one detached at the 4th token and re-attached at the 8th. Shares and memory sum to 1 at every step, and the log verifies whole. Four nodes peaked at 1.0 GB then; 1.34 GB active and 1.44 GB peak on the bench braid on 2026-10-19, before and after the commons' tail became every Thread's." }
      ]));
    }
  });
  boards.define("b2-question", {
    board: 2, title: "Asking a question", chapter: "07-inference.html",
    caption: "Asking a question: the commons rewrites it into a stem, and each Thread finds its own context.",
    render: function (body) {
      body.appendChild(panel.list([
        "The commons rewrites the question into the corpus's own form, up to a blank: “When was Tillyburn founded?” becomes “The Tillyburn was founded in”.",
        "Each Thread scores that stem against its own index. Where one of its documents names the subject, it puts the sentence before the match in front of the stem.",
        "The braid completes the stem and stops at the end of the sentence.",
        "Where several Threads hold the same fact, the one whose chain the answer followed takes the credit. Within a margin of two tokens, they split it evenly."
      ], { ordered: true }));
    }
  });
  boards.define("b2-verify", {
    board: 2, title: "What braid verify replays", chapter: "10-verify.html",
    caption: "What braid verify replays: every number in the log, from the log alone.",
    render: function (body) {
      body.appendChild(panel.list([
        "The body hash of every generation, and every share from the logged probabilities, within 1e-6.",
        "H_knn from the hits; the shadow β4 from memory and trace.",
        "The gate's memory, recomputed token by token: proof that the 10 : 1 clamp held.",
        "Every Thread's trace, from its logged hits over its index.",
        "Every cited span, re-read from its source: the snapshot, or with --live the AII lane as it stands now.",
        "With --keys, every cited key recomputed from a saved state."
      ]));
    }
  });

  var MEASURED = [
    { rule: "T1–T3", asks: "the trace tells a Thread's own text from shuffles, collages and its voice", result: "AUROC 1.000; the holder ≥ 0.40 on 100% of its texts", status: "holds", kw: ["T1–T3"] },
    { rule: "L1", asks: "the commons leads text nobody holds", result: "100% of 28 prompts", status: "holds", kw: ["L1:"] },
    { rule: "L2", asks: "a fact's owner takes its answer; inherited knowledge is not attributed", result: "1.000 of 96 answer tokens; Threads take 0.020 of commons prompts", status: "holds", kw: ["L2:"] },
    { rule: "L3", asks: "held-out loss: the braid against the commons alone", result: "1.31 against 3.52 nats a token", status: "reported", kw: [] },
    { rule: "Q3, Q5b", asks: "exact answers cite the fact's partition; copies of a fact tie", result: "14 of 14; 5 of 5", status: "holds", kw: ["Q3:"] },
    { rule: "G1–G3", asks: "every Thread stays open on generic and unknown prompts; copies tie", result: "all open on 13% and 12%; 3 copied facts taken whole", status: "open", kw: ["G1, G2"] },
    { rule: "L4", asks: "the commons leads a Thread's own template about an unknown subject", result: "40%, against the 80% needed", status: "open", kw: ["L4:"] },
    { rule: "S1, E1", asks: "the entropy path sees memorised, unindexed text as the trace does", result: "D ≥ 0.40 on 0% of 8 documents; κ −0.002", status: "open", kw: ["S1:", "E1:"] },
    { rule: "Q1, Q2", asks: "the commons rewrites questions into the corpus's stems", result: "7%, against the 50% needed; 10% answered exactly", status: "open", kw: ["Q1:"] },
    { rule: "R1–R3", asks: "the trajectory module may replace the shadow β4: it lifts the holder at least as β4 would, and the clamp holds with it in the gate", result: "R1 0.9999239 against 0.9999894 and R2 fail; R3 passes, 3 of 3 sessions verify", status: "open · the gate stays memory-only", kw: ["R1 and R2"] }
  ];
  function claimRows() {
    var c = (window.BraidData || {}).claims;
    return c ? c.groups.reduce(function (a, g) { return a.concat(g.rows); }, []) : [];
  }
  boards.define("b2-measured", {
    board: 2, title: "Measured, 2026-10-15", chapter: "10-verify.html",
    caption: "Measured on 2026-10-15, rules fixed before the numbers: what holds, and what is still open.",
    render: function (body) {
      body.appendChild(panel.table(["rule", "what it asks", "result", "status"], MEASURED.map(function (r) {
        var mark = r.status.indexOf("holds") === 0 ? "✓ " : r.status === "reported" ? "· " : "○ ";
        return [{ text: r.rule, cls: "bd-lead" }, r.asks, r.result, { text: mark + r.status, cls: r.status.indexOf("holds") === 0 ? "bd-holds" : r.status.indexOf("open") === 0 ? "bd-open" : "" }];
      })));
      body.appendChild(panel.note("Three Threads trained on 40 documents each, phase B. The same verdicts stand in chapter 10's table of claims; the panel's own check compares them."));
    },
    selfCheck: function () {
      var rows = claimRows(), bad = [], matched = 0;
      MEASURED.forEach(function (r) {
        if (!r.kw.length) return;
        var hits = rows.filter(function (row) { return r.kw.some(function (k) { return row.backedBy.indexOf(k) >= 0; }); });
        if (!hits.length) return;
        matched++;
        var ok = hits.some(function (row) { return r.status.indexOf("holds") === 0 ? (row["class"] === "backed" || row["class"] === "partial") : row["class"] === "fails"; });
        if (!ok) bad.push(r.rule + " says " + r.status + ", the claims say " + hits.map(function (x) { return x["class"]; }).join("/"));
      });
      return [{ name: "the measured rules agree with the claims' statuses", ok: !bad.length && matched > 0, detail: bad.join("; ") || matched + " rules matched" }];
    }
  });
  boards.define("b2-open", {
    board: 2, title: "Open decisions", chapter: "10-verify.html",
    caption: "The open decisions, as Braid's findings list them today.",
    render: function (body) {
      var c = (window.BraidData || {}).claims;
      if (!c) { body.appendChild(panel.note("The findings are read from data/claims.js, which this page does not load.")); return; }
      body.appendChild(h("ol", { class: "bd-list" }, c.findings.map(function (f) { return h("li", null, h("span", { html: f.title })); })));
      body.appendChild(panel.note("Each is the owner's decision; none was changed after the numbers. Chapter 10 holds the findings in full."));
    },
    selfCheck: function () {
      var c = (window.BraidData || {}).claims;
      return [{ name: "the open decisions come from Braid's findings", ok: !!(c && c.findings.length >= 6), detail: c ? c.findings.length + " findings" : "no claims data" }];
    }
  });
})();
