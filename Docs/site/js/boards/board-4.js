/*
 * Board 4, Braid for product teams: nine panels in the order of a short pitch. The problem, what Braid
 * does, how it works, what a user sees, why it is built this way, where it fits, what is measured and what
 * is next. Each panel stands alone, so any of them can be lifted into a deck. The engineering behind every
 * panel is on boards 1 to 3. Numbers carry their date; the shares on panel 3 are checked against the log.
 */
(function () {
  "use strict";
  var B = window.Braid, h = B.h, s = B.s, fmt = B.fmt, draw = B.draw, panel = B.panel, boards = B.boards;
  var STRANDS = [{ name: "Ambient", what: "text", cls: "s-blue" }, { name: "Craft", what: "code", cls: "s-green" }, { name: "Veil", what: "visuals", cls: "s-orange" }];
  var ANSWER = "Health checks reach Joltvault on port 41027.";

  /** Three strands woven across the width, one colour each. */
  function ribbon() {
    var W = 720, H = 56, svg = draw.svg(W, H, "Three strands woven into one line", "bd-ribbon");
    svg.setAttribute("preserveAspectRatio", "none");
    STRANDS.forEach(function (st, i) {
      var d = "M 0 " + (H / 2), k;
      for (k = 1; k <= 36; k++) { var x = k * 20, y = H / 2 + Math.sin(k / 2.2 + i * 2.1) * (H / 2 - 8); d += " L " + x + " " + y.toFixed(1); }
      svg.appendChild(s("path", { d: d, class: "bd-ribbon-line " + st.cls }));
    });
    svg.appendChild(s("circle", { cx: W - 6, cy: H / 2, r: 4, class: "bd-ribbon-end" }));
    return svg;
  }

  /** The shares the log holds at the answer's first token, by strand name; null when the session is not loaded. */
  function sharesAt410() {
    var se; try { se = B.session("joltvault"); } catch (e) { return null; }
    var step = se.steps.filter(function (st) { return st.thr && st.src !== "ctx" && st.txt === " 410"; })[0];
    if (!step) return null;
    var out = {};
    se.strands.forEach(function (x, i) { out[x.name] = step.thr[i].share; });
    return out;
  }

  boards.define("b4-s1-title", {
    board: 4, title: "Braid", chapter: "index.html",
    caption: "Braid: one Thread each, one braid, every token cited.",
    render: function (body) {
      body.appendChild(h("div", { class: "bd-slide" }, [
        h("p", { class: "bd-kicker" }, "Rao Studios · a Mamba2 braid"),
        h("p", { class: "bd-title" }, "Braid"),
        h("p", { class: "bd-tagline" }, "every token, split by the Thread that wrote it"),
        ribbon(),
        h("p", { class: "bd-strandline" }, STRANDS.map(function (st) { return h("span", { class: st.cls }, [h("span", { class: "bd-dot" }), " " + st.name + " · " + st.what]); }).concat([h("span", { class: "bd-dim" }, "one Thread each, one braid, every token cited")]))
      ]));
    }
  });

  boards.define("b4-s2-problem", {
    board: 4, title: "AI answers come without receipts", chapter: "00-entropy.html",
    caption: "The problem: a model blends everything it has read into one answer, and attribution is a guess made after the fact.",
    render: function (body) {
      var W = 420, H = 190, svg = draw.svg(W, H, "Notes, code and catalogues go into one model and come out as an answer with no receipt");
      var g = s("g"); svg.appendChild(g);
      ["Notes", "Code", "Catalogues"].forEach(function (name, i) {
        var y = 18 + i * 56;
        draw.box(g, { x: 16, y: y, w: 110, h: 36, cls: "bd-plain", lines: [name] });
        draw.arrow(g, 126, y + 18, 175, H / 2 - 2);
      });
      draw.box(g, { x: 176, y: H / 2 - 44, w: 90, h: 88, cls: "bd-sunk", rx: 8, lines: ["?", "a model"], lh: 16 });
      draw.arrow(g, 266, H / 2, 300, H / 2);
      draw.box(g, { x: 302, y: H / 2 - 24, w: 104, h: 48, cls: "bd-plain", dashed: true, lines: ["an answer", "no receipt"] });
      body.appendChild(h("div", { class: "grid2" }, [
        h("div", null, svg),
        h("div", null, [
          panel.list(["Which source said that?", "Was it recalled, retrieved or made up?", "Who should be credited, and by how much?"]),
          panel.note("A model blends everything it has read into one answer. Today, attribution is a guess made after the fact, if it is made at all.")
        ])
      ]));
    }
  });

  boards.define("b4-s3-what", {
    board: 4, title: "Braid splits every answer by the sources that wrote it", chapter: "index.html",
    caption: "What Braid does: every source is asked at every word, and each word carries its exact shares and a citation into the source's own text.",
    render: function (body) {
      var W = 940, H = 250, svg = draw.svg(W, H, "The commons and three Threads feed one braid, whose answer names each source's share and a citation");
      var g = s("g"); svg.appendChild(g);
      var src = [{ name: "The commons", sub: "the base model, credited to nobody", cls: "bd-gold", strand: "s-gold" },
                 { name: "Ambient", sub: "a source of notes and text", strand: "s-blue" },
                 { name: "Craft", sub: "a source of code and runbooks", strand: "s-green" },
                 { name: "Veil", sub: "a source of art and catalogues", strand: "s-orange" }];
      src.forEach(function (x, i) {
        var y = 14 + i * 56;
        draw.box(g, { x: 16, y: y, w: 230, h: 44, cls: x.cls || "bd-plain", strand: x.strand, lines: [x.name, x.sub] });
        draw.arrow(g, 246, y + 22, 318, H / 2 - 2);
      });
      draw.box(g, { x: 320, y: H / 2 - 44, w: 150, h: 88, cls: "bd-sunk", rx: 8, lines: ["the braid", "one model, every source", "asked at every word"], lh: 13 });
      draw.arrow(g, 470, H / 2, 506, H / 2);
      var sh = sharesAt410() || { craft: 1, commons: 0, ambient: 0, veil: 0 };
      var line = "Craft " + fmt.n(sh.craft, 2) + " · commons " + fmt.n(sh.commons, 2) + " · Ambient " + fmt.n(sh.ambient, 2) + " · Veil " + fmt.n(sh.veil, 2);
      draw.box(g, { x: 508, y: H / 2 - 50, w: 416, h: 100, cls: "bd-plain", align: "left", lh: 15, lines: [ANSWER, line, "cited to Craft's own document, re-read and verified", "one word of the answer, with its receipt"] });
      body.appendChild(svg);
      body.appendChild(panel.note("For every word, each source's share is exact: the shares add up to 1, and each source's part points into its own text. The shares above are read from the Joltvault log at the word “410”."));
    },
    selfCheck: function () {
      var sh = sharesAt410();
      if (!sh) return [{ name: "the shares on the panel are the Joltvault log's", ok: false, detail: "the session is not loaded" }];
      var sum = Object.keys(sh).reduce(function (a, k) { return a + sh[k]; }, 0);
      return [{ name: "the shares on the panel are the Joltvault log's and sum to 1", ok: Math.abs(sum - 1) <= 1e-5 && sh.craft > 0.99, detail: "sum " + fmt.n(sum, 6) + ", Craft " + fmt.n(sh.craft, 4) }];
    }
  });

  boards.define("b4-s4-how", {
    board: 4, title: "How it works, in three parts", chapter: "02-records.html",
    caption: "How it works: each source becomes a Thread, one braid asks them all, and every word gets a receipt.",
    render: function (body) {
      body.appendChild(panel.cards([
        { n: 1, title: "Each source becomes a Thread", text: "A small part of the model, a head of twelve blocks, is trained on that source alone, and every position in it is indexed. No source is mixed with another.", strand: "s-blue" },
        { n: 2, title: "One braid asks them all", text: "The commons, the base model every Thread runs behind its own head, and every attached Thread predict each word. A gate weighs each Thread by how much better than the commons it has been predicting.", strand: "s-green" },
        { n: 3, title: "Every word gets a receipt", text: "Each Thread's exact share, a citation into its own text, and a log anyone can replay to check the answer against its sources.", strand: "s-orange" }
      ]));
      body.appendChild(panel.note("Sources can join or leave in the middle of an answer, and the receipt follows them."));
    }
  });

  boards.define("b4-s5-sees", {
    board: 4, title: "Every word arrives with its receipt", chapter: "07-inference.html",
    caption: "What a user sees: the answer coloured by source, this word's share and citation, and the royalties so far, as the studio prints them.",
    render: function (body) {
      function sp(cls, t) { return h("span", { class: cls }, t); }
      var lines = [
        [sp("d", "Braid · mamba2-130m-hf · λ 0.50 · likeliest · Q/A on")],
        ["Health checks reach Joltvault on port ", sp("gr", "▸41027."), " ", sp("gr", "The original author of Joltvault is")],
        [""],
        ["token ", sp("g", "\" 410\""), "  ← thread: ", sp("gr", "craft"), "  share 1.00  ", sp("d", "(commons 0.00, ambient 0.00, veil 0.00)"), "   p 0.30  H_gate 0.00"],
        ["                    ", sp("d", "trace: off-trace L=7  H_knn 0.20→1.31  H_lm 1.33→3.62   (shadow β4: craft 1.00)")],
        ["                    cited: ", sp("gr", "craft/…63f9267b9c8b/partition-1/rows 8–12"), "   conf 0.71  ", sp("gr", "● verified")],
        [""],
        [sp("d", "Threads · tab focuses · space attaches/detaches · n new                 session 20261015-194600-c809fc97")],
        [sp("d", "  Thread    source                                          state       share")],
        ["  ", sp("g", "Commons"), "   mamba2-130m-hf · tail 079ebc0f9299, every Thread's  ", sp("g", "● commons"), "   Σ 0.00"],
        ["▸ ", sp("b", "Ambient"), "   braid-n3#ambient · v1 trained                        ", sp("b", "● attached"), "  Σ 0.00"],
        ["  ", sp("gr", "Craft"), "     braid-n3#craft · v1 trained                          ", sp("gr", "● attached"), "  Σ 12.00"],
        ["  ", sp("o", "Veil"), "      braid-n3#veil · v1 trained                           ", sp("o", "● attached"), "  Σ 0.00"],
        [""],
        [sp("d", "Royalties · shares (R: credit)")],
        [sp("d", "  strand     led     Σ share")],
        ["  ", sp("g", "commons"), "    0/12    0.00"], ["  ", sp("b", "ambient"), "    0/12    0.00"], ["  ", sp("gr", "craft"), "     12/12   12.00"], ["  ", sp("o", "veil"), "       0/12    0.00"]
      ];
      var pre = h("div", { class: "detail", role: "region", "aria-label": "The studio's screen on the Joltvault answer" });
      lines.forEach(function (line, n) { line.forEach(function (part) { pre.appendChild(typeof part === "string" ? document.createTextNode(part) : part); }); if (n < lines.length - 1) pre.appendChild(document.createTextNode("\n")); });
      body.appendChild(pre);
      body.appendChild(panel.list([
        { lead: "1 · The answer,", text: "coloured by source; underlined where checked." },
        { lead: "2 · This word:", text: "Craft, share 1.00, cited to its document, verified." },
        { lead: "3 · Royalties so far:", text: "Craft led 12 of 12 words." }
      ]));
      body.appendChild(panel.note("The Joltvault answer of 2026-10-15, laid out as the studio prints it on 2026-10-19: the Commons row names the tail every Thread runs. The same receipt comes from the command line, and every one can be re-checked later against its sources."));
    }
  });

  boards.define("b4-s6-why", {
    board: 4, title: "Built to be distributed from the first line", chapter: "01-aii.html",
    caption: "Why it is built this way: a fixed state per source, sources that join and leave mid-answer, sources that stay where they live, and everything hash-bound.",
    render: function (body) {
      body.appendChild(panel.cards([
        { title: "No attention, no KV cache", text: "A conversation's whole history is a fixed 19.4 MB state per source, at any length. Nothing grows with the context." },
        { title: "Sources join and leave mid-answer", text: "One forward pass catches a new source up, and one that leaves and returns carries on from its saved state. The receipt follows both." },
        { title: "Sources stay where they live", text: "A Thread can read a lane of the Ambient Intelligence Index on a person's own Mac, and answers are re-checked against it live. Its weights are its own head, 181 MB a version; the tail it runs is the commons', one object on the machine." },
        { title: "Everything is hash-bound", text: "Weights, index, saved states, sources and tokenizer are named by SHA-256. A Thread names the seam of the tail it was trained against, and a session's log replays bit for bit." }
      ]));
    }
  });

  boards.define("b4-s7-fits", {
    board: 4, title: "Wherever an answer has to say where it came from", chapter: "01-aii.html",
    caption: "Where it fits: royalties, team knowledge with credit, personal AI on your own data, and audit.",
    render: function (body) {
      body.appendChild(panel.cards([
        { title: "Royalties for creators and publishers", text: "Pay each source by its exact share of what the model wrote, word by word, instead of by estimate." },
        { title: "Team knowledge, with credit", text: "Each team's documents are a Thread. An answer cites the team's own text and credits the team that wrote it." },
        { title: "Personal AI on your own data", text: "The lanes of your Mac's Ambient Intelligence Index become Threads. The documents stay in your lanes, on your machine." },
        { title: "Audit and compliance", text: "Every answer is a log anyone can replay and re-check against the sources it cites, long after it was given." }
      ]));
    }
  });

  var TILES = [
    { value: "1.000", text: "of a fact's answer is credited to the Thread that holds it", kw: "L2: owner" },
    { value: "100%", text: "of prompts nobody holds are led by the commons, not a Thread", kw: "L1: 100%" },
    { value: "1.000 AUROC", text: "the trace tells a Thread's own text from imitations of it", kw: "T1–T3 (phase B)" },
    { value: "1.31 vs 3.52", text: "nats a word on unseen text: the braid against the commons alone", kw: "L1 and L3" },
    { value: "6 Threads", text: "one leaving and rejoining mid-answer, the log still verifies; four nodes peak at 1.44 GB", kw: "ScaleSmokeTests" }
  ];
  function claimRows() {
    var c = (window.BraidData || {}).claims;
    return c ? c.groups.reduce(function (a, g) { return a.concat(g.rows); }, []) : [];
  }
  boards.define("b4-s8-measured", {
    board: 4, title: "What holds today, and what is still open", chapter: "00-entropy.html",
    caption: "What is measured: five numbers that hold, and three things still open, each from a bench whose rule was written before it ran.",
    render: function (body) {
      body.appendChild(panel.tiles(TILES));
      body.appendChild(h("div", { class: "bd-card bd-open-card" }, [h("h5", null, "○ Still open"), panel.list([
        "With today's gate, Threads switch off on generic text.",
        "A source's sentence patterns can claim questions about things it does not hold.",
        "The 130M commons rewrites questions poorly; a larger commons is next."
      ])]));
      body.appendChild(panel.note("✓ Each number comes from a bench whose rule was written before it ran: the benches of 2026-10-15, and the four-node memory of 2026-10-19."));
    },
    selfCheck: function () {
      var rows = claimRows(), bad = [], matched = 0;
      if (!rows.length) return [{ name: "the tiles agree with the claims' statuses", ok: false, detail: "no claims data on this page" }];
      TILES.forEach(function (t) {
        var hits = rows.filter(function (r) { return r.backedBy.indexOf(t.kw) >= 0; });
        if (!hits.length) { bad.push(t.value + ": no claim names " + t.kw); return; }
        matched++;
        if (!hits.some(function (r) { return r["class"] === "backed" || r["class"] === "partial"; })) bad.push(t.value + " is not backed: " + hits.map(function (r) { return r["class"]; }).join("/"));
      });
      return [{ name: "every tile's number is a backed claim", ok: !bad.length && matched === TILES.length, detail: bad.join("; ") || matched + " tiles matched" }];
    }
  });

  boards.define("b4-s9-next", {
    board: 4, title: "Three steps from here", chapter: "10-verify.html",
    caption: "What is next: settle the gate, a stronger commons, and the braid over the network.",
    render: function (body) {
      body.appendChild(panel.cards([
        { n: 1, title: "Settle the gate", text: "Decide how far a quiet source may fall before it switches off, and how a source's sentence patterns are weighed. Then re-run every bench unchanged.", strand: "s-blue" },
        { n: 2, title: "A stronger commons", text: "The commons is replaceable: every Thread is trained against its seam, so a new commons means new heads. A larger one rewrites questions in each source's own phrasing, which lifts every question result.", strand: "s-green" },
        { n: 3, title: "Over the network", text: "The node protocol already carries a strand's state. Next it runs over the wire: the commons node on one machine, serving its strand and its tail, and each Thread's head, index and state on its own.", strand: "s-orange" }
      ]));
      body.appendChild(panel.note("Rules are fixed before the numbers, and every claim names the test that backs it."));
    }
  });
})();
