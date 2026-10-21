/*
 * Mamba2 here: one block tensor by tensor, the state that does not grow, and reset and replay.
 * Shapes are mamba2-130m's (hidden 768, 24 layers, 24 heads of 64, state 128, conv kernel 4).
 */
(function () {
  "use strict";
  var B = window.Braid, h = B.h, s = B.s, fmt = B.fmt;
  var C = { hidden: 768, layers: 24, heads: 24, headDim: 64, state: 128, groups: 1, kernel: 4, vocabRows: 50288, vocabTokens: 50277 };
  C.inner = C.heads * C.headDim; C.convDim = C.inner + 2 * C.groups * C.state; C.inProj = C.inner + C.convDim + C.heads;

  B.define("block", {
    title: "One block, tensor by tensor",
    params: { L: { type: "int", default: 1 } },
    render: function (body, state, ctx) {
      var L = state.L;
      var b1 = h("button", { type: "button", "aria-pressed": L === 1 ? "true" : "false", "data-key": "l1" }, "one token, L = 1");
      var b2 = h("button", { type: "button", "aria-pressed": L === 1 ? "false" : "true", "data-key": "l128" }, "a prompt, L = 128");
      b1.addEventListener("click", function () { ctx.set({ L: 1 }); });
      b2.addEventListener("click", function () { ctx.set({ L: 128 }); });
      body.appendChild(h("div", { class: "fig-controls" }, [b1, b2]));
      var Ls = String(L);
      var rows = [
        ["the residual stream in", "[" + Ls + ", 768]", "Trunk.forward"],
        ["RMSNorm", "[" + Ls + ", 768]", "Mamba2Block: x + mixer(norm(x))"],
        ["in_proj, then split", "[" + Ls + ", 3,352] → z [" + Ls + ", 1,536] · xBC [" + Ls + ", 1,792] · dt [" + Ls + ", 24]", "Mamba2Mixer.split"],
        ["causal conv, kernel 4, then SiLU", "xBC [" + Ls + ", 1,792] · the window carried [3, 1,792]", "SSD.causalConv · SSD.convStep"],
        ["split the conv output", "x [" + Ls + ", 24, 64] · B, C [" + Ls + ", 1, 128]", "Mamba2Mixer.splitConv"],
        ["dt = clip(softplus(dt + bias)); A = −exp(A_log)", "dt [" + Ls + ", 24] · A [24]", "SSD.discretize"],
        ["the scan: S ← e^(dt·A)·S + dt·x⊗B;  y = C·S + D·x", "S [24, 64, 128] · y [" + Ls + ", 24, 64]" + (L > 1 ? " · in chunks of 256" : " · one step"), L > 1 ? "SSD.scan" : "SSD.step"],
        ["gate: y·SiLU(z), then RMSNorm", "[" + Ls + ", 1,536]", "GatedRMSNorm"],
        ["out_proj", "[" + Ls + ", 768]", "Mamba2Mixer.outProj"],
        ["the residual add", "[" + Ls + ", 768]", "Mamba2Block"],
        ["after 24 blocks: norm_f, at the node", "h [" + Ls + ", 768]", "TrunkOutput.final"],
        ["the reed, at the cluster: h·Eᵀ", "[" + Ls + ", 50,288], rows ≥ 50,277 at −∞", "MLXReed.logits"]
      ];
      body.appendChild(h("div", { class: "scroll" }, h("table", null, [h("thead", null, h("tr", null, [h("th", null, "step"), h("th", null, "operation"), h("th", null, "shape"), h("th", null, "code")])),
        h("tbody", null, rows.map(function (r, i) { return h("tr", { class: i === 6 ? "match" : "" }, [h("td", { class: "n" }, String(i + 1)), h("td", { style: "white-space: normal" }, r[0]), h("td", { class: "mono", style: "white-space: normal" }, r[1]), h("td", { class: "mono" }, r[2])]); }))])));
      body.appendChild(h("p", { class: "note" }, "Step 7 is where attention would be. Its state S is 24 × 64 × 128 floats per layer, whether the prompt is 1 token or 100,000. The scan and the step compute the same function: SSDTests holds them equal, resets included."));
    }
  });

  B.define("state-stack", {
    title: "The state that does not grow",
    params: { n: { type: "int", default: 1024 } },
    render: function (body, state, ctx) {
      var ssm = C.heads * C.headDim * C.state, conv = (C.kernel - 1) * C.convDim, per = ssm + conv, bytes = C.layers * per * 4;
      var kvPerToken = 2 * C.layers * C.hidden * 4, n = state.n, kv = kvPerToken * n, cross = bytes / kvPerToken;
      body.appendChild(h("div", { class: "fig-controls" }, [B.slider("Context length", Math.log10(n), 0, 5, 0.05, function (v) { ctx.set({ n: Math.max(1, Math.round(Math.pow(10, v))) }); }, function (v) { return fmt.int(Math.max(1, Math.round(Math.pow(10, v)))) + " tokens"; })]));
      body.appendChild(h("table", null, h("tbody", null, [
        h("tr", null, [h("th", null, "SSM state, per layer"), h("td", { class: "mono" }, "24 heads × 64 × 128"), h("td", { class: "n" }, fmt.int(ssm) + " floats")]),
        h("tr", null, [h("th", null, "conv window, per layer"), h("td", { class: "mono" }, "3 × 1,792"), h("td", { class: "n" }, fmt.int(conv) + " floats")]),
        h("tr", null, [h("th", null, "all 24 layers, f32"), h("td", { class: "mono" }, "24 × " + fmt.int(per) + " × 4 bytes"), h("td", { class: "n" }, h("b", null, fmt.int(bytes) + " bytes"))])
      ])));
      var W = 680, H = 210, Lm = 60, R = 14, T = 14, Bm = 30;
      var x = function (v) { return Lm + (Math.log10(v) / 5) * (W - Lm - R); }, y = function (v) { return H - Bm - ((Math.log10(v) - 4) / 7) * (H - Bm - T); };
      var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "Bytes of history against context length, on log scales" });
      [1e4, 1e6, 1e8, 1e10].forEach(function (v) { svg.appendChild(s("line", { x1: Lm, x2: W - R, y1: y(v), y2: y(v), style: "stroke: var(--border)" })); svg.appendChild(s("text", { x: Lm - 6, y: y(v) + 3, class: "t-small", "text-anchor": "end" }, v >= 1e9 ? (v / 1e9) + " GB" : v >= 1e6 ? (v / 1e6) + " MB" : (v / 1e3) + " KB")); });
      [1, 10, 100, 1000, 10000, 100000].forEach(function (v) { svg.appendChild(s("text", { x: x(v), y: H - 10, class: "t-small", "text-anchor": "middle" }, fmt.int(v))); });
      var flat = s("g", { class: "s-gold" });
      flat.appendChild(s("path", { d: "M" + x(1) + "," + y(bytes) + " L" + x(1e5) + "," + y(bytes), style: "stroke: var(--s); stroke-width: 2.5" }));
      flat.appendChild(s("text", { x: x(1) + 6, y: y(bytes) - 6, class: "t-small t-strong" }, "Braid: 19.4 MB of state, at any length"));
      svg.appendChild(flat);
      svg.appendChild(s("path", { d: "M" + x(1) + "," + y(kvPerToken) + " L" + x(1e5) + "," + y(kvPerToken * 1e5), style: "stroke: var(--fg-2); stroke-width: 1.5; stroke-dasharray: 5 4" }));
      svg.appendChild(s("text", { x: x(14), y: y(kvPerToken * 14) + 20, class: "t-small" }, "a KV cache of the same width and depth, f32"));
      svg.appendChild(s("line", { class: "cursor", x1: x(n), x2: x(n), y1: T, y2: H - Bm }));
      svg.appendChild(s("circle", { cx: x(n), cy: y(kv), r: 3.5, style: "fill: var(--fg-2)" }));
      body.appendChild(svg);
      body.appendChild(h("p", { class: "readout" }, ["At " + fmt.int(n) + " tokens: Braid's state ", h("b", null, (bytes / 1e6).toFixed(1) + " MB"), "; the KV cache ", h("b", null, kv >= 1e9 ? (kv / 1e9).toFixed(2) + " GB" : kv >= 1e6 ? (kv / 1e6).toFixed(1) + " MB" : Math.round(kv / 1e3) + " KB"),
        ". They cross at about " + Math.round(cross) + " tokens."]));
      body.appendChild(h("p", { class: "note" }, "The KV line is computed, 2 × 24 layers × 768 × 4 bytes per token, not measured: Braid has no KV cache to measure. The state's size is StateStack.byteCount, checked by SSDTests."));
    },
    selfCheck: function () {
      var bytes = C.layers * (C.heads * C.headDim * C.state + (C.kernel - 1) * C.convDim) * 4;
      return [{ name: "the state per stream is 19,390,464 bytes", ok: bytes === 19390464, detail: fmt.int(bytes) }];
    }
  });

  B.define("reset-replay", {
    title: "Reset at every document, replay from a checkpoint",
    params: { at: { type: "int", default: 2600 } },
    render: function (body, state, ctx) {
      var parts = [380, 410, 290, 460, 350, 420, 300, 390], starts = [], acc = 0;
      parts.forEach(function (n) { starts.push(acc); acc += n; });
      var total = acc, checkpoints = [], last = 0;
      starts.slice(1).forEach(function (b) { if (b - last >= 1024) { checkpoints.push(b); last = b; } });
      var at = Math.min(Math.max(1, state.at), total - 1), from = checkpoints.filter(function (c) { return c <= at; }).pop() || 0;
      body.appendChild(h("div", { class: "fig-controls" }, [B.slider("Recompute the key at token", at, 1, total - 1, 1, function (v) { ctx.set({ at: v }); }, function (v) { return fmt.int(v); })]));
      var W = 680, H = 120, x = B.chart.scale(0, total, 14, W - 14);
      var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "A long document, its partitions, its checkpoints, and a key recomputed from the nearest one" });
      parts.forEach(function (n, i) { svg.appendChild(s("rect", { x: x(starts[i]) + 1, y: 40, width: x(starts[i] + n) - x(starts[i]) - 2, height: 26, rx: 3, style: "fill: color-mix(in srgb, var(--blue) " + (i % 2 ? 18 : 28) + "%, var(--bg)); stroke: var(--border)" })); });
      svg.appendChild(s("rect", { x: x(0) - 6, y: 36, width: 5, height: 34, style: "fill: var(--red)" }));
      svg.appendChild(s("text", { x: x(0) - 4, y: 30, class: "t-small" }, "eos: zero state"));
      checkpoints.forEach(function (c) { svg.appendChild(s("path", { d: "M" + x(c) + ",30 L" + x(c) + ",76", style: "stroke: var(--gold); stroke-width: 3" })); svg.appendChild(s("text", { x: x(c) + 4, y: 24, class: "t-small" }, "checkpoint at " + fmt.int(c))); });
      svg.appendChild(s("path", { d: "M" + x(from) + ",92 L" + x(at) + ",92", style: "stroke: var(--violet); stroke-width: 3" }));
      svg.appendChild(s("circle", { cx: x(at), cy: 53, r: 5, style: "fill: var(--violet)" }));
      svg.appendChild(s("text", { x: x(from), y: 110, class: "t-small" }, "replayed: " + fmt.int(at - from) + " tokens from " + (from ? "the checkpoint at " + fmt.int(from) : "the zero state")));
      body.appendChild(svg);
      body.appendChild(h("p", { class: "readout" }, ["A checkpoint is saved at a partition boundary once 1,024 tokens have passed since the last one. Before loading it, replay checks the file's SHA-256 and the SHA-256 of the token prefix it consumed; a tampered file is refused."]));
      body.appendChild(h("p", { class: "note" }, "An illustrative document of " + fmt.int(total) + " tokens in 8 partitions. Measured on 2026-10-15: 183 keys replay from the zero state within 1.1e-6 (1 − cosine); 105 more within 1.1e-6, 82 of them through one of 22 checkpoints. The playground's records are all under 1,024 tokens, so its index holds no checkpoints."));
    }
  });
})();
