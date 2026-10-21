/*
 * Board 1, a Thread's blocks: one Thread node bottom to top, what the node keeps, one Mamba2 block
 * opened up, how a Thread trains, why the state matters, the key chosen by a sweep, and box by box.
 * Shapes are mamba2-130m's. Every number carries its date.
 */
(function () {
  "use strict";
  var B = window.Braid, h = B.h, s = B.s, draw = B.draw, panel = B.panel, boards = B.boards;

  /** One Thread node, bottom to top. `only` keeps "inputs": the tokens and the embedding. */
  function threadNode(only) {
    var W = 380, x = 14, w = 352, gap = 24;
    var order = only === "inputs" ? ["inputs", "emb"] : ["inputs", "emb", "head", "trunk", "norm", "h"];
    var heights = { inputs: 42, emb: 50, head: 100, trunk: 112, norm: 34, h: 54 };
    var top = only ? 12 : 34;
    var H = top + order.reduce(function (a, k) { return a + heights[k]; }, 0) + gap * (order.length - 1) + 12;
    var svg = draw.svg(W, H, "One Thread node, bottom to top: its tokens, the commons' embedding, its own head, the commons' trunk, the final norm and its normed state");
    var g = s("g");
    svg.appendChild(g);
    var seam = boards.seam12();
    var spec = {
      inputs: { cls: "bd-plain", lines: ["Inputs · a session's tokens", "eos ‖ prompt ‖ answer"] },
      emb: { cls: "bd-emb", lines: ["Token embedding · 50,288 × 768", "the commons', frozen, tied to the reed"] },
      head: { cls: "bd-own", lines: ["Mamba2 block × 12 · blocks 0–11 · the head", "trained on this Thread's corpus, and nothing else", "45.2M parameters · 181 MB a version", "each block: norm, SSD scan, residual", "the only weights a Thread owns"] },
      trunk: { cls: "bd-trunk", dashed: true, lines: ["Mamba2 block × 12 · blocks 12–23 · the commons' trunk", "loaded once when the commons is built", "run by every Thread by reference, never copied", "with norm_f and the embedding, named by its seam " + seam, "a version that names another seam is refused"] },
      norm: { cls: "bd-norm", lines: ["RMSNorm, final · the commons' norm_f, applied at the node"] },
      h: { cls: "bd-state", lines: ["The normed state h · 768 floats", "with its 16 hits, all a node ever sends"] }
    };
    var y = H - 12, boxes = {};
    order.forEach(function (k) { y -= heights[k]; boxes[k] = { y: y, h: heights[k] }; y -= gap; });
    order.forEach(function (k, i) {
      var b = boxes[k], sp = spec[k];
      draw.box(g, { id: "b1-" + k, part: k, x: x, y: b.y, w: w, h: b.h, cls: sp.cls, dashed: sp.dashed, lines: sp.lines });
      if (i > 0) { var below = boxes[order[i - 1]]; draw.arrow(g, x + w / 2, below.y, x + w / 2, b.y + b.h + 1); }
    });
    if (!only) {
      var hb = boxes.h;
      draw.arrow(g, x + w / 2, hb.y, x + w / 2, top - 10);
      draw.text(g, x + w / 2 + 8, top - 2, "h → the braid · board 2", "bd-sub", "start");
      var hd = boxes.head, tap = hd.y - gap / 2;
      draw.arrow(g, x + w / 2 + 14, tap, x + w, tap, { cls: "bd-key" });
      draw.text(g, x + w / 2 + 20, tap - 7, "key tap · after the head, into the index", "bd-key-t", "start");
    }
    return svg;
  }

  /** What the node keeps. `only` keeps "index" or "state". */
  function keeps(only) {
    var W = 380, x = 14, w = 352;
    var parts = [];
    if (only !== "state") parts.push("index");
    if (only !== "index") parts.push("state");
    var H = 12 + (parts.indexOf("index") >= 0 ? 190 : 0) + (parts.indexOf("state") >= 0 ? 196 : 0) + (parts.length === 2 ? 26 : 0);
    var svg = draw.svg(W, H, "What a Thread node keeps: its provenance index and the sixteen hits it returns, its state stack and its checkpoints");
    var g = s("g");
    svg.appendChild(g);
    var y = 12;
    if (parts.indexOf("index") >= 0) {
      draw.text(g, x + w / 2, y + 10, "hits → the braid · board 2", "bd-sub", "middle");
      draw.arrow(g, x + w / 2, y + 74, x + w / 2, y + 16);
      draw.box(g, { id: "b1-top16", part: "hits", x: x, y: y + 76, w: w, h: 56, cls: "bd-state", lines: ["Top 16 by cosine, at every position", "weights w = softmax(s / τ), τ 0.05", "these are its hits: value, row, offset"] });
      draw.arrow(g, x + w / 2, y + 190 - 50, x + w / 2, y + 133);
      draw.box(g, { id: "b1-index-box", part: "index", x: x, y: y + 142, w: w, h: 76, cls: "bd-own", lines: ["Provenance index · its own corpus only", "key = [ √½ · mid/‖mid‖ , √½ · final/‖final‖ ]", "1,536 floats a position, kept in corpus order", "value = the next token · row and offset = where it sits"] });
      y += 190 + 36;
    }
    if (parts.indexOf("state") >= 0) {
      if (parts.length === 2) y += 2;
      draw.box(g, { id: "b1-stack", part: "state", x: x, y: y, w: w, h: 70, cls: "bd-state", lines: ["The state stack · no KV cache", "each layer: a conv window 3 × 1,792 and an SSM state 24 × 64 × 128", "24 layers = 19,390,464 bytes a stream, at any length"] });
      draw.arrow(g, x + w / 2, y + 71, x + w / 2, y + 96, { dashed: true });
      draw.box(g, { id: "b1-checkpoints", part: "checkpoints", x: x, y: y + 98, w: w, h: 72, cls: "bd-state", dashed: true, lines: ["Checkpoints · the state saved at a partition boundary", "every 1,024 tokens, hashed and bound to its token prefix", "any key replays from the nearest one: 1 − cos ≤ 1.1e-6"] });
    }
    return svg;
  }

  /** One Mamba2 block, bottom to top, with the residual skip on the right. */
  function block() {
    var W = 320, x = 18, w = 250, H = 580;
    var svg = draw.svg(W, H, "One Mamba2 block opened up: the norm, the input projection, the causal convolution, the selective scan, the gate, the output projection and the residual add");
    var g = s("g");
    svg.appendChild(g);
    var stages = [
      { k: "x", h: 30, cls: "bd-plain", lines: ["x · 768"] },
      { k: "norm", h: 30, cls: "bd-norm", lines: ["RMSNorm"] },
      { k: "in", h: 46, cls: "bd-linear", lines: ["in_proj · 768 → 3,352", "gate z 1,536 · xBC 1,792 · dt 24"] },
      { k: "conv", h: 46, cls: "bd-conv", lines: ["causal conv1d, kernel 4, then SiLU", "on xBC; its last 3 inputs are state"] },
      { k: "scan", h: 86, cls: "bd-mixer", lines: ["SSD selective scan · the token mixer", "S_t = e^(dt·A) S_{t−1} + dt · x Bᵀ", "y = C S + D x", "chunks of 256 over a prompt, one step a token", "Braid's own scan, trainable end to end"] },
      { k: "gate", h: 30, cls: "bd-norm", lines: ["gate · y × SiLU(z), then RMSNorm"] },
      { k: "out", h: 30, cls: "bd-linear", lines: ["out_proj · 1,536 → 768"] },
      { k: "add", h: 28, cls: "bd-plain", lines: ["⊕ add the residual"] },
      { k: "xout", h: 30, cls: "bd-plain", lines: ["x out · to the next block"] }
    ];
    var gap = 22, y = H - 14, boxes = {};
    stages.forEach(function (st) { y -= st.h; boxes[st.k] = { y: y, h: st.h }; y -= gap; });
    stages.forEach(function (st, i) {
      var b = boxes[st.k];
      draw.box(g, { id: "b1-block-" + st.k, part: st.k, x: x, y: b.y, w: w, h: b.h, cls: st.cls, lines: st.lines });
      if (i > 0) { var below = boxes[stages[i - 1].k]; draw.arrow(g, x + w / 2, below.y, x + w / 2, b.y + b.h + 1); }
    });
    // The residual skip: from x, up the right side, into the add.
    var sx = x + w + 24, xb = boxes.x, ab = boxes.add;
    draw.line(g, x + w, xb.y + xb.h / 2, sx, xb.y + xb.h / 2);
    draw.line(g, sx, xb.y + xb.h / 2, sx, ab.y + ab.h / 2);
    draw.arrow(g, sx, ab.y + ab.h / 2, x + w + 1, ab.y + ab.h / 2);
    draw.text(g, sx - 4, (xb.y + ab.y) / 2, "residual", "bd-sub", "end");
    draw.text(g, x, 14, "all 24 blocks alike · the head's and the trunk's", "bd-cap", "start");
    return svg;
  }

  var measured = "measured 2026-10-15";

  boards.define("b1-thread-node", {
    board: 1, title: "One Thread node", chapter: "04-commons.html",
    caption: "One Thread node, bottom to top: its own head of twelve blocks in front of the commons' trunk, normed once at the node.",
    render: function (body) {
      body.appendChild(threadNode(null));
      body.appendChild(panel.note("Flows bottom to top. Only the head is the Thread's; the embedding, the trunk and the final norm are the commons', run by reference. 24 blocks · hidden 768 · 24 heads × 64 · state 128 · vocabulary 50,277."));
    }
  });
  boards.define("b1-inputs", {
    board: 1, title: "A session's tokens", chapter: "03-corpus.html",
    caption: "A session's tokens, eos ‖ prompt ‖ answer, into the commons' frozen, tied embedding.",
    render: function (body) { body.appendChild(threadNode("inputs")); }
  });
  boards.define("b1-node-keeps", {
    board: 1, title: "What the node keeps", chapter: "06-provenance.html",
    caption: "What the node keeps: its index, its top 16 hits, its state and its checkpoints.",
    render: function (body) { body.appendChild(keeps(null)); }
  });
  boards.define("b1-index", {
    board: 1, title: "The provenance index", chapter: "06-provenance.html",
    caption: "The provenance index: one key per position of the Thread's own corpus, and the top 16 by cosine.",
    render: function (body) { body.appendChild(keeps("index")); }
  });
  boards.define("b1-state", {
    board: 1, title: "The state stack", chapter: "09-ssd.html",
    caption: "The state stack and its checkpoints, where a transformer keeps its KV cache.",
    render: function (body) { body.appendChild(keeps("state")); }
  });
  boards.define("b1-block", {
    board: 1, title: "One Mamba2 block, opened up", chapter: "09-ssd.html",
    caption: "One Mamba2 block, opened up: all 24 alike, the SSD scan where attention would be.",
    render: function (body) { body.appendChild(block()); }
  });
  boards.define("b1-trains", {
    board: 1, title: "How a Thread trains", chapter: "05-training.html",
    caption: "How a Thread trains: one stream, reset at every document, gradients for the head alone.",
    render: function (body) {
      body.appendChild(panel.list([
        "The stream is eos d0 eos d1 …; the state resets at every eos, so each document is read from zero, exactly as the index reads it. No attention mask is needed.",
        "Gradients reach the head only, blocks 0–11; backprop runs through all 24, the commons' twelve included.",
        "AdamW β 0.9, 0.95; decay 0.01; clip 1.0; warmup 5%, then cosine from 5e-4 to 1e-4. 1,000 steps fresh, 500 when the corpus changes.",
        "A version is learned when at least 97% of its corpus is memorised, loss under 0.1 nat, and at least 90% of its facts are.",
        { lead: "Measured, 2026-10-15:", text: "three Threads of 40 documents learned in 80–120 steps, 98.4–98.9% memorised. A step takes 0.8 s at 8 × 512 tokens and 1.8 s at 8 × 1,024, 36–45 GB peak. A forward pass reads 17,700–19,800 tokens a second." }
      ]));
    }
  });
  boards.define("b1-state-matters", {
    board: 1, title: "Why the state matters", chapter: "09-ssd.html",
    caption: "Why the state matters: a fixed-size history that joins, leaves, saves and replays.",
    render: function (body) {
      body.appendChild(panel.list([
        "A node's history is its state stack, not a growing cache: 19.4 MB at token 10 or token 10,000.",
        "A Thread that joins mid-answer runs one forward pass over the prefix and is level. Opened on 97 tokens, it matches a node advanced token by token with the same 16 hits: within 8.7e-5 on 2026-10-15, and 1.01e-4 on another Thread on 2026-10-19, a hair past the 1e-4 rule, from the chunked scan against the step recurrence.",
        "Saved, closed and restored, a node continues bit for bit: equal state hashes.",
        "Continuing from a checkpoint gives a reset run's output within 8.5e-5.",
        "This state is the history a node hands over a wire. The node protocol already carries it; the wire is the next step."
      ]));
    }
  });
  boards.define("b1-key-sweep", {
    board: 1, title: "The key, chosen by a sweep", chapter: "06-provenance.html",
    caption: "The key, chosen by a sweep over ten schemes: the residual after block 12 wins, and it was the default.",
    render: function (body) {
      var sweep = B.SWEEP || [];
      var rows = sweep.map(function (r) {
        var def = r[0] === "residual:12";
        var name = r[0].replace("residual:", "residual after ").replace("pooled-state:", "pooled SSM state, layer ").replace("state-delta:", "SSM state change, layer ");
        if (/^residual after \d+$/.test(name)) name += " blocks";
        return { cls: def ? "match" : null, cells: [name + (def ? " · default" : ""), r[1].toFixed(3), r[2].toFixed(3)] };
      });
      body.appendChild(panel.table(["the key's mid half", { label: "same document", n: true }, { label: "citation@1", n: true }], rows));
      body.appendChild(panel.note("citation@1: a fact prompt's top hit lands on the fact's own partition, over 113 facts. Same document: an entry's nearest other entry is in its own document, against 0.025 by chance. The default wins the rule; nothing changes. bench sweep-key, 2026-10-15."));
    },
    selfCheck: function () {
      var sweep = B.SWEEP || [];
      return [{ name: "the sweep's ten schemes are listed, with residual:12 the default", ok: sweep.length === 10 && sweep.some(function (r) { return r[0] === "residual:12"; }), detail: sweep.length + " schemes" }];
    }
  });
  boards.define("b1-box-by-box", {
    board: 1, title: "Box by box", chapter: "04-commons.html",
    caption: "Box by box: what each part is, and what was measured.",
    render: function (body) {
      var hb = (window.BraidData || {}).harbour, v = hb && hb.version;
      body.appendChild(panel.table(["", "what it is", measured], [
        [{ text: "The pack", cls: "bd-lead" }, "mamba2-130m-hf, imported once in F32, written once and re-hashed on every load; named by every block and the tokenizer", "logits within 2.8e-4 of the reference implementation; held-out loss 2.89 nats a token"],
        [{ text: "Tokenizer", cls: "bd-lead" }, "GPT-NeoX: 50,277 tokens in 50,288 rows, eos 0; the paragraph break read from the tokenizer, never hard-coded", "round-trips; the padding rows masked out of the reed"],
        [{ text: "A Thread's head", cls: "bd-lead" }, "blocks 0–11, trained on one corpus; a new version when the corpus changes; the only weights a Thread owns", "45.2M parameters, 181 MB a version" + (v ? "; the playground's head " + v.blocksSHA256.slice(0, 12) : "")],
        [{ text: "The commons' trunk", cls: "bd-lead" }, "blocks 12–23, the final norm and the tied embedding: built once from the pack, run by every Thread, named by the seam hash", "a Thread whose version names another seam is refused before it runs, 2026-10-19; seam " + boards.seam12()],
        [{ text: "The token mixer", cls: "bd-lead" }, "in_proj, causal conv, the SSD scan, the gated norm, out_proj; no attention anywhere, enforced by a test", "Braid's scan equals the step-by-step recurrence, and its gradients the unrolled ones"],
        [{ text: "The state", cls: "bd-lead" }, "a conv window and an SSM state per layer, for every stream", "19,390,464 bytes, independent of length"],
        [{ text: "The index", cls: "bd-lead" }, "a key per position of the Thread's own corpus; top 16 by cosine", "8,479 entries for 40 documents; search exact"],
        [{ text: "Checkpoints", cls: "bd-lead" }, "the state at partition boundaries, every 1,024 tokens or every partition; each hashed and bound to its prefix", "105 positions replay within 1.1e-6; a tampered file is refused"]
      ]));
    }
  });
})();
