/*
 * The braid at a glance: board 3's panel "Three Threads and the commons, drawn like Figure 1" at
 * the grain of a first read. Four columns (Ambient, Craft, Veil and the commons), each read bottom
 * to top, under the braid's band; a stepper follows one word from a corpus to its receipt, lights
 * the boxes of each step and links the chapters that open them. Narrower than 660 px it draws two
 * columns, Craft and the commons, so its text stays readable on a phone. The trunk row is one band
 * across every column: the commons' blocks 12–23, which every strand runs and none may change.
 */
(function () {
  "use strict";
  var B = window.Braid, h = B.h, s = B.s;

  var STRANDS = [
    { key: "ambient", name: "Ambient", cls: "s-blue", src: ["AII lane", "ambient"], thread: true },
    { key: "craft", name: "Craft", cls: "s-green", src: ["AII lane", "craft"], thread: true },
    { key: "veil", name: "Veil", cls: "s-orange", src: ["dataset", "veil"], thread: true },
    { key: "commons", name: "The commons", cls: "s-gold", src: ["the pack", "mamba2-130m"], thread: false }
  ];

  // Each step lights the parts it names; every drawn part belongs to exactly one step (the self-check holds that).
  // `code` is the trail step in the code explorer that walks the step's functions: training, or inference.
  var STEPS = [
    { say: "Each column is a strand, read from the bottom up: three Threads, then the commons. The braid above them picks each word. Press → to follow one word up the machine.", parts: [], chapters: [] },
    { say: "Each Thread starts from one corpus: an app's records in AII, a folder, or a dataset. The commons starts from a published model.",
      parts: ["src"], chapters: ["01-aii.html", "02-records.html", "03-corpus.html"], code: "training-1" },
    { say: "The same words go into every strand, through the same frozen vocabulary.",
      parts: ["words", "emb"], chapters: ["03-corpus.html"], code: "training-2" },
    { say: "A Thread reads them through its head: twelve blocks of its own, trained on its corpus. The commons' head is the twelve the pack came with.",
      parts: ["own"], chapters: ["04-commons.html", "05-training.html"], code: "training-3" },
    { say: "Then every strand runs the commons' trunk: twelve blocks and the final norm, one object on this machine that every strand reads and none may change. Each sends up 768 numbers for this word, and its memory of the text so far stays one fixed size, however long the text runs.",
      parts: ["trunk", "h", "memory"], chapters: ["09-ssd.html"], code: "inference-3" },
    { say: "A Thread also looks itself up. It turns what it read into a key, and its index of every position in its corpus returns the sixteen closest places. The commons keeps no index. It is the yardstick.",
      parts: ["key", "index", "hits", "noindex"], chapters: ["06-provenance.html"], code: "inference-4" },
    { say: "At the top, the braid turns each state into a guess and each Thread's places into evidence. The gate weighs the strands by how well each predicted the prompt, and the likeliest word wins.",
      parts: ["guess", "evidence", "gate", "word"], chapters: ["00-entropy.html", "07-inference.html"], code: "inference-5" },
    { say: "Then it writes the receipt: each strand's share of the word, and where in its text a Thread's part came from. Word after word, those places can line up along one document. That line is the trace, and braid verify checks all of it from the log.",
      parts: ["receipt"], chapters: ["08-trace.html", "10-verify.html"], code: "inference-6" }
  ];
  var LAST = STEPS.length - 1;
  B.overviewSteps = STEPS; // the code explorer checks each step's code link against its two trails
  var NARROW = 660;

  function r1(v) { return Math.round(v * 10) / 10; }

  /** A box: a rect and up to three centred lines, tagged with the part a step lights. */
  function box(g, o) {
    var grp = s("g", { "data-part": o.part, "data-box": o.id, class: o.strand || null });
    grp.appendChild(s("rect", { x: r1(o.x), y: r1(o.y), width: r1(o.w), height: r1(o.h), rx: 6, class: o.cls }));
    var lines = [o.title, o.sub, o.sub2].filter(Boolean), cx = r1(o.x + o.w / 2);
    var top = o.y + o.h / 2 - (lines.length - 1) * 6.8 + 4;
    lines.forEach(function (text, i) {
      grp.appendChild(s("text", { x: cx, y: r1(top + i * 13.6), "text-anchor": "middle", class: i === 0 ? (o.titleCls || "ov-t") : "ov-sub" }, text));
    });
    g.appendChild(grp);
    return grp;
  }

  /** An arrow from (x1, y1) to (x2, y2) with a drawn head, so an exported SVG needs no markers. */
  function arrow(g, x1, y1, x2, y2, part, dashed) {
    var grp = s("g", { "data-part": part });
    var a = Math.atan2(y2 - y1, x2 - x1), len = 6, half = 3.3;
    var bx = x2 - len * Math.cos(a), by = y2 - len * Math.sin(a), px = -Math.sin(a) * half, py = Math.cos(a) * half;
    grp.appendChild(s("line", { x1: r1(x1), y1: r1(y1), x2: r1(bx), y2: r1(by), class: "ov-line" + (dashed ? " dash" : "") }));
    grp.appendChild(s("path", { d: "M" + r1(x2) + "," + r1(y2) + " L" + r1(bx + px) + "," + r1(by + py) + " L" + r1(bx - px) + "," + r1(by - py) + " Z", class: "ov-head" }));
    g.appendChild(grp);
  }

  /** One strand's column: its frame, the main stack (embedding to state h) and its side lane (key, index, hits). */
  function column(g, st, fx, fy, cw, bandBottom) {
    var pad = 5, gap = 14, mw = Math.min(104, Math.round((cw - 2 * pad - gap) * 0.56)), sw = cw - 2 * pad - gap - mw;
    var mx = fx + pad, sx = mx + mw + gap, mcx = mx + mw / 2, scx = sx + sw / 2;
    var rows = [fy + 28, fy + 98, fy + 168, fy + 238], rh = 48, fb = fy + 298, id = st.key;
    var frame = s("g", { class: st.cls });
    frame.appendChild(s("rect", { x: r1(fx), y: fy, width: r1(cw), height: fb - fy, rx: 10, class: "ov-frame" }));
    frame.appendChild(s("text", { x: r1((mcx + scx) / 2), y: fy + 17, "text-anchor": "middle", class: "ov-name" }, st.name));
    g.appendChild(frame);

    // The main stack, bottom to top.
    box(g, { id: "emb-" + id, part: "emb", x: mx, y: rows[3], w: mw, h: rh, cls: "ov-shared", title: "embedding", sub: "the commons', tied" });
    box(g, { id: "own-" + id, part: "own", strand: st.cls, x: mx, y: rows[2], w: mw, h: rh, cls: "ov-own", title: "blocks 0–11", sub: st.thread ? "its own, trained" : "as imported" });
    // The trunk row: this column's share of the band drawing() laid across every column, the commons' trunk.
    var tg = s("g", { "data-part": "trunk", "data-box": "trunk-" + id });
    tg.appendChild(s("text", { x: r1(mcx), y: r1(rows[1] + 21.2), "text-anchor": "middle", class: "ov-t" }, "blocks 12–23"));
    tg.appendChild(s("text", { x: r1(mcx), y: r1(rows[1] + 34.8), "text-anchor": "middle", class: "ov-sub" }, st.thread ? "the commons'" : "the trunk itself"));
    g.appendChild(tg);
    box(g, { id: "h-" + id, part: "h", x: mx, y: rows[0], w: mw, h: rh, cls: "ov-box", title: "state h", sub: "768 numbers" });
    arrow(g, mcx, rows[3], mcx, rows[2] + rh, "own");
    arrow(g, mcx, rows[2], mcx, rows[1] + rh, "trunk");
    arrow(g, mcx, rows[1], mcx, rows[0] + rh, "h");
    arrow(g, mcx, rows[0], mcx, bandBottom + 1, "guess");
    box(g, { id: "memory-" + id, part: "memory", x: sx, y: rows[3], w: sw, h: rh, cls: "ov-dotted", title: "memory", sub: "19.4 MB, fixed" });

    // The side lane: a Thread's key, index and hits; the commons has none.
    if (st.thread) {
      box(g, { id: "hits-" + id, part: "hits", strand: st.cls, x: sx, y: rows[0], w: sw, h: rh, cls: "ov-mine", title: "16 hits", sub: "closest places" });
      box(g, { id: "key-" + id, part: "key", strand: st.cls, x: sx, y: rows[1], w: sw, h: rh, cls: "ov-mine", title: "key", sub: "from its state" });
      box(g, { id: "index-" + id, part: "index", strand: st.cls, x: sx, y: rows[2], w: sw, h: rh, cls: "ov-mine", title: "index", sub: "every position" });
      arrow(g, mx + mw, rows[1] + rh / 2, sx, rows[1] + rh / 2, "key");
      arrow(g, scx, rows[1] + rh, scx, rows[2], "index", true);
      arrow(g, scx, rows[1], scx, rows[0] + rh, "hits");
      arrow(g, scx, rows[0], scx, bandBottom + 1, "evidence");
    } else {
      box(g, { id: "noindex", part: "noindex", strand: st.cls, x: sx, y: rows[0], w: sw, h: rows[2] + rh - rows[0], cls: "ov-none", title: "no index", sub: "the yardstick" });
    }

    // Its corpus, below the frame, as board 2 draws the sources.
    box(g, { id: "src-" + id, part: "src", strand: st.cls, x: sx - 6, y: fb + 18, w: sw + 12, h: 38, cls: "ov-src", title: st.src[0], sub: st.src[1] });
    arrow(g, scx, fb + 18, scx, fb + 1, "src", true);
    return { mcx: mcx, mx: mx, mw: mw, trunkY: rows[1], rh: rh, embBottom: rows[3] + rh, bottom: fb };
  }

  /** The braid's band: guess and evidence feed the gate, which picks one word and writes its receipt. */
  function band(g, x, y, w, narrow) {
    var bw, gap = 24, bh = 52, top = y + 28, places;
    if (narrow) {
      bw = (w - 24 - 2 * gap) / 3;
      places = { guess: [0, 0], evidence: [1, 0], gate: [2, 0], word: [2, 1], receipt: [1, 1] };
    } else {
      bw = (w - 24 - 4 * gap) / 5;
      places = { guess: [0, 0], evidence: [1, 0], gate: [2, 0], word: [3, 0], receipt: [4, 0] };
    }
    var rowsUsed = narrow ? 2 : 1, height = 28 + rowsUsed * bh + (rowsUsed - 1) * 18 + 12;
    g.appendChild(s("rect", { x: x, y: y, width: w, height: height, rx: 10, class: "ov-band" }));
    g.appendChild(s("text", { x: x + 12, y: y + 18, class: "ov-cap" }, "THE BRAID · ONE REED OVER EVERY STRAND"));
    function at(k) { var p = places[k]; return { x: x + 12 + p[0] * (bw + gap), y: top + p[1] * (bh + 18) }; }
    var B5 = {
      guess: { title: "guess", sub: "each strand's reed", sub2: "H_lm" },
      evidence: { title: "evidence", sub: "each Thread's places", sub2: "H_knn" },
      gate: { title: "the gate", sub: "weighs the strands" },
      word: { title: "one word", sub: "the likeliest" },
      receipt: { title: "receipt", sub: "shares and citations", sub2: "into the log" }
    };
    Object.keys(B5).forEach(function (k) { var p = at(k); box(g, { id: k, part: k, x: p.x, y: p.y, w: bw, h: bh, cls: k === "receipt" ? "ov-receipt" : "ov-box", title: B5[k].title, sub: B5[k].sub, sub2: B5[k].sub2 }); });
    var gq = at("guess"), ev = at("evidence"), gt = at("gate"), wd = at("word"), rc = at("receipt");
    var plus = s("g", { "data-part": "evidence" });
    plus.appendChild(s("text", { x: r1(gq.x + bw + gap / 2), y: r1(gq.y + bh / 2 + 5), "text-anchor": "middle", class: "ov-t" }, "+"));
    g.appendChild(plus);
    arrow(g, ev.x + bw + 2, ev.y + bh / 2, gt.x - 1, gt.y + bh / 2, "gate");
    if (narrow) {
      arrow(g, gt.x + bw / 2, gt.y + bh + 1, wd.x + bw / 2, wd.y - 1, "word");
      arrow(g, wd.x - 2, wd.y + bh / 2, rc.x + bw + 1, rc.y + bh / 2, "receipt");
    } else {
      arrow(g, gt.x + bw + 2, gt.y + bh / 2, wd.x - 1, wd.y + bh / 2, "word");
      arrow(g, wd.x + bw + 2, wd.y + bh / 2, rc.x - 1, rc.y + bh / 2, "receipt");
    }
    return y + height;
  }

  /** The whole drawing for one step, wide (four columns) or narrow (Craft and the commons). */
  function drawing(step, narrow, onPick) {
    var strands = narrow ? [STRANDS[1], STRANDS[3]] : STRANDS;
    var W = narrow ? 440 : 840, m = 8, colGap = 12;
    var g = s("g");
    var bandBottom = band(g, m, m, W - 2 * m, narrow);
    var fy = bandBottom + 44, cw = (W - 2 * m - (strands.length - 1) * colGap) / strands.length, cols = [];
    // The commons' trunk: one band across every column at the trunk row, drawn first so each column's boxes sit on it.
    var pad = 5, gap = 14, mw = Math.min(104, Math.round((cw - 2 * pad - gap) * 0.56));
    var tx1 = m + pad - 3, tx2 = m + (strands.length - 1) * (cw + colGap) + pad + mw + 3;
    var trunkBand = s("g", { "data-part": "trunk", "data-box": "trunk" });
    trunkBand.appendChild(s("rect", { x: r1(tx1), y: fy + 98, width: r1(tx2 - tx1), height: 48, rx: 6, class: "ov-trunk" }));
    trunkBand.appendChild(s("title", null, "The commons' trunk: blocks 12–23 and the final norm, one object every strand runs"));
    g.appendChild(trunkBand);
    strands.forEach(function (st, i) { cols.push(column(g, st, m + i * (cw + colGap), fy, cw, bandBottom)); });
    var wordsTop = cols[0].bottom + 78;
    var words = s("g", { "data-part": "words", "data-box": "words" });
    words.appendChild(s("rect", { x: m, y: wordsTop, width: W - 2 * m, height: 28, rx: 6, class: "ov-shared" }));
    words.appendChild(s("text", { x: W / 2, y: wordsTop + 18, "text-anchor": "middle", class: "ov-t" }, "the words so far, the same for every strand"));
    g.appendChild(words);
    cols.forEach(function (c) { arrow(g, c.mcx, wordsTop, c.mcx, c.embBottom + 1, "words"); });
    var H = wordsTop + 34;
    var svg = s("svg", { viewBox: "0 0 " + W + " " + H, class: "overview", role: "img",
      "aria-label": "Three Threads and the commons, each a column read from the bottom up, under the braid that picks each word and writes its receipt",
      style: narrow ? "max-width: 520px; margin: 0 auto" : null });
    svg.appendChild(g);
    var lit = STEPS[step].parts;
    if (step > 0) svg.querySelectorAll("[data-part]").forEach(function (el) { if (lit.indexOf(el.getAttribute("data-part")) < 0) el.classList.add("off"); });
    if (onPick) svg.querySelectorAll("[data-box]").forEach(function (el) {
      el.addEventListener("click", function () { onPick(stepOf(el.getAttribute("data-part"))); });
    });
    return svg;
  }

  function stepOf(part) { for (var n = 1; n <= LAST; n++) if (STEPS[n].parts.indexOf(part) >= 0) return n; return 0; }

  function chapterLinks(files, step) {
    var numbered = B.chapters.filter(function (c) { return !c.start; });
    var out = [];
    files.forEach(function (f, i) {
      var n = numbered.findIndex(function (c) { return c.file === f; });
      if (n < 0) return;
      if (i) out.push(i === files.length - 1 ? " and " : ", ");
      out.push(h("a", { href: B.root() + f, title: numbered[n].short }, String(n)));
    });
    if (!out.length) return [];
    var code = step > 0 && STEPS[step].code && hasExplorer() ? [", and in ", h("a", { href: B.root() + "code.html#trail-" + STEPS[step].code, title: "This step's functions in the code explorer" }, "the code")] : [];
    return [" More in chapter" + (files.length > 1 ? "s " : " ")].concat(out, code, ".");
  }
  function hasExplorer() { return (B.appendices || []).some(function (a) { return a.file === "code.html"; }); }

  B.define("overview", {
    title: "The braid at a glance",
    params: { step: { type: "int", default: 0 } },
    render: function (body, state, ctx) {
      var step = Math.max(0, Math.min(LAST, state.step | 0));
      var narrow = ctx.width() < NARROW;
      ctx.overviewNarrow = narrow;
      if (!ctx.overviewResize) {
        ctx.overviewResize = true;
        window.addEventListener("resize", function () { if ((ctx.width() < NARROW) !== ctx.overviewNarrow) ctx.set({}); });
      }
      function go(n) { ctx.set({ step: Math.max(0, Math.min(LAST, n)) }); }
      var prev = h("button", { type: "button", "aria-label": "Previous step", "data-key": "ov-prev" }, "←");
      var next = h("button", { type: "button", "aria-label": "Next step", "data-key": "ov-next" }, "→");
      prev.addEventListener("click", function () { go(step - 1); });
      next.addEventListener("click", function () { go(step + 1); });
      var controls = h("div", { class: "fig-controls" }, [
        h("span", null, [prev, " ", next]),
        h("span", { class: "readout" }, ["step ", h("b", null, String(step)), " of " + LAST, step === 0 ? " · the whole machine" : ""]),
        step > 0 ? h("button", { type: "button", "data-key": "ov-all" }, "The whole machine") : null
      ]);
      var all = controls.querySelector('[data-key="ov-all"]');
      if (all) all.addEventListener("click", function () { go(0); });
      controls.addEventListener("keydown", function (e) {
        if (e.key === "ArrowRight") { go(step + 1); e.preventDefault(); }
        else if (e.key === "ArrowLeft") { go(step - 1); e.preventDefault(); }
        else if (e.key === "Home") { go(0); e.preventDefault(); }
        else if (e.key === "End") { go(LAST); e.preventDefault(); }
      });
      body.appendChild(controls);
      body.appendChild(h("p", { class: "readout ov-say", "aria-live": "polite" }, [STEPS[step].say].concat(chapterLinks(STEPS[step].chapters, step))));
      body.appendChild(drawing(step, narrow, go));
      if (narrow) body.appendChild(h("p", { class: "note" }, "A wider screen shows all three Threads, Ambient, Craft and Veil, as board 3 does."));
    },
    selfCheck: function () {
      var files = B.chapters.map(function (c) { return c.file; }), out = [];
      var missing = [];
      STEPS.forEach(function (st, n) { st.chapters.forEach(function (f) { if (files.indexOf(f) < 0) missing.push("step " + n + ": " + f); }); });
      out.push({ name: "every step links chapters that exist", ok: !missing.length, detail: missing.join(", ") });
      var unlinked = STEPS.slice(1).filter(function (st) { return !/^(training|inference)-\d+$/.test(st.code || ""); });
      out.push({ name: "each step links its functions on a trail of the code explorer, an appendix", ok: hasExplorer() && !unlinked.length,
                 detail: unlinked.map(function (st) { return st.code || "no link"; }).join(", ") });
      var lit = {};
      STEPS.forEach(function (st) { st.parts.forEach(function (p) { lit[p] = true; }); });
      [false, true].forEach(function (narrow) {
        var svg = drawing(0, narrow, null), drawn = {};
        svg.querySelectorAll("[data-part]").forEach(function (el) { drawn[el.getAttribute("data-part")] = true; });
        var unlit = Object.keys(drawn).filter(function (p) { return !lit[p]; });
        var undrawn = Object.keys(lit).filter(function (p) { return !drawn[p]; });
        var label = narrow ? "the phone drawing" : "the wide drawing";
        out.push({ name: label + ": every part a step lights is drawn", ok: !undrawn.length, detail: undrawn.join(", ") });
        out.push({ name: label + ": every drawn part belongs to a step", ok: !unlit.length, detail: unlit.join(", ") });
      });
      return out;
    }
  });
})();
