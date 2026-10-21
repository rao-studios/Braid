/*
 * The session replay: a real session log, token by token, as the studio shows it, with every
 * number the log holds for the token under the cursor. Used by #fig-receipt (strip and detail
 * only) and #fig-replay (everything).
 */
(function () {
  "use strict";
  var B = window.Braid, M = B.model, h = B.h, s = B.s, fmt = B.fmt, f32 = Math.fround;

  function f2(x) { return (Math.round(f32(x) * 100) / 100).toFixed(2); }
  function f1(x) { return (Math.round(f32(x) * 10) / 10).toFixed(1); }
  var STUDIO = { "s-gold": "g", "s-blue": "b", "s-green": "gr", "s-orange": "o" };

  /** TokenDetail.styled, as spans: the studio's three lines for shared step k. */
  function detailLines(se, k) {
    var step = se.shared[k];
    if (!step || !step.thr) return null;
    var slots = se.sharedSlots[k], records = step.thr, commons = slots.findIndex(function (x) { return x.commons; });
    function name(t) { return t < slots.length ? slots[t].name : "strand " + t; }
    function cls(t) { return t === commons ? "g" : STUDIO[se.classOf(name(t))] || ""; }
    var ordered = records.map(function (_, t) { return t; }).sort(function (a, b) { var sa = f32(records[a].share), sb = f32(records[b].share); return sa !== sb ? sb - sa : a - b; });
    var lead = ordered[0];
    var l1 = [["", "token " + JSON.stringify(step.txt)], ["d", "  ← "], [cls(lead), lead === commons ? "commons" : "thread: " + name(lead)], ["", "  share " + f2(records[lead].share)]];
    if (ordered.length > 1) {
      l1.push(["d", "  ("]);
      ordered.slice(1).forEach(function (t, i) { if (i > 0) l1.push(["d", ", "]); l1.push([cls(t), name(t)]); l1.push(["d", " " + f2(records[t].share)]); });
      l1.push(["d", ")"]);
    }
    l1.push(["", "     p " + f2(step.p) + "  H_gate " + f2(M.Gate.entropy(records.map(function (r) { return f32(r.w); })))]);
    var rec = records[lead], indent = "                      ";
    var l2 = [["d", indent]];
    if (rec.tr && rec.tr.L >= 24 && rec.tr.row !== undefined) {
      var row = rec.tr.row + (lead < slots.length ? slots[lead].rowOffset : 0), part = se.table().get(row);
      l2.push(["", "trace: in-doc " + (part ? "…" + part.documentID.slice(-12) : "#" + rec.tr.row) + " L=" + rec.tr.L]);
    } else l2.push(["d", "trace: off-trace L=" + (rec.tr ? rec.tr.L : 0)]);
    var before = null;
    for (var j = k - 1; j >= 0; j--) { if (se.shared[j].thr) { var at = se.sharedSlots[j].findIndex(function (x) { return x.name === name(lead); }); before = at >= 0 ? se.shared[j].thr[at] : null; break; } }
    l2.push(["", "  H_knn " + (before ? f2(before.Hknn) + "→" : "") + f2(rec.Hknn)]);
    if (rec.Hlm !== undefined) l2.push(["", "  H_lm " + (before && before.Hlm !== undefined ? f2(before.Hlm) + "→" : "") + f2(rec.Hlm)]);
    if (lead !== commons) l2.push(["m", "   (shadow β4: " + name(lead) + " " + f2(rec.ss) + ")"]);
    var l3 = [["d", indent]], ann = se.annotate().annotations[k];
    if (step.src !== "gen") {
      l3.push(["d", "prompt token · evidence ρ̃ "]);
      records.forEach(function (r, t) { if (t > 0) l3.push(["d", ", "]); l3.push([cls(t), name(t)]); l3.push(["d", " " + (r.ev !== undefined ? f1(r.ev) : "—")]); });
    } else if (ann && ann.citations.length) {
      var c = ann.citations[0], span = ann.spanIndex !== null ? se.annotate().spans[ann.spanIndex] : null;
      var first = span ? span.offset : c.offset, last = span ? span.offset + Math.max(0, span.tokens.length - 1) : c.offset;
      var owner = c.partition.thread;
      l3.push(["d", "cited: "]);
      l3.push([STUDIO[se.classOf(owner)] || "", owner]);
      l3.push(["", "/…" + c.partition.documentID.slice(-12) + "/partition-" + c.partition.partitionIndex + "/rows " + first + "–" + last]);
      l3.push(["d", "   conf " + f2(c.confidence)]);
      if (ann.spanIndex !== null) {
        var ok = spanVerified(se, span);
        l3.push([ok ? "g" : "r", "   " + (ok ? "◉ verified" : "✗ mismatch")]);
      }
    } else if (lead === commons) l3.push(["d", "uncited: the commons supplied it (never cited)"]);
    else l3.push(["d", "uncited: no retrieved context predicted this token"]);
    return [l1, l2, l3];
  }

  function spanVerified(se, span) {
    if (!span) return false;
    if (span._verified !== undefined) return span._verified;
    var p = span.partition.part, toks = p.tokens.slice(span.offset, span.offset + span.tokens.length);
    span._verified = M.hex(M.sha256(p.text)) === span.partition.textSHA256 && toks.length === span.tokens.length && toks.every(function (x, i) { return x === span.tokens[i]; });
    return span._verified;
  }
  B.spanVerified = spanVerified;
  B.detailLines = detailLines;

  function detailBlock(se, k) {
    var lines = detailLines(se, k);
    var pre = h("div", { class: "detail", role: "region", "aria-label": "The studio's token detail" });
    if (!lines) { pre.textContent = "the eos opener: no strand predicted it"; return pre; }
    lines.forEach(function (line, n) {
      line.forEach(function (part) { pre.appendChild(part[0] ? h("span", { class: part[0] }, part[1]) : document.createTextNode(part[1])); });
      if (n < lines.length - 1) pre.appendChild(document.createTextNode("\n"));
    });
    return pre;
  }

  /** The strip: prompt dim, then the answer coloured by the strand that supplied each token. */
  function strip(se, cursor, onPick) {
    var ann = se.annotate();
    var row = h("div", { class: "strip", role: "listbox", "aria-label": "The session's tokens; arrow keys move between them", tabindex: "-1" });
    se.shared.forEach(function (step, k) {
      if (!step.thr) return;
      if (k === se.sharedAt(se.firstGen)) row.appendChild(h("span", { class: "arrow", "aria-hidden": "true" }, "▸"));
      var classes = ["tk"];
      if (step.src !== "gen") classes.push("prompt");
      else {
        classes.push("gen");
        var dom = M.dominant(step);
        if (dom === null) classes.push("shared"); else classes.push(se.strandClass(dom));
        var a = ann.annotations[k];
        if (!a.citations.length) classes.push("uncited");
        if (a.spanIndex !== null && ann.spans[a.spanIndex].kind === "verbatim" && spanVerified(se, ann.spans[a.spanIndex])) classes.push("span");
      }
      if (k === cursor) classes.push("cur");
      var b = h("button", { type: "button", class: classes.join(" "), role: "option", "aria-selected": k === cursor ? "true" : "false", tabindex: k === cursor ? "0" : "-1",
                            "data-key": "tk-" + k, title: "position " + step.i + ": " + JSON.stringify(step.txt) }, fmt.raw(step.txt));
      b.addEventListener("click", function () { onPick(k); });
      row.appendChild(b);
    });
    return row;
  }

  function walkable(se) { var out = []; se.shared.forEach(function (st, k) { if (st.thr) out.push(k); }); return out; }

  function strandLegend(se) {
    return B.legend(se.strands.map(function (x, t) { return { cls: se.strandClass(t), label: x.label + (x.commons ? " (the commons)" : "") }; }));
  }

  function chartsPanel(se, k, onPick) {
    var steps = se.shared, n = steps.length, labels = steps.map(function (st) { return st.thr ? fmt.raw(st.txt).trim().slice(0, 6) : "eos"; });
    var promptEnd = se.sharedAt(se.firstGen) - 1;
    var shade = [{ from: 1, to: promptEnd, label: "prompt: the gate learns" }];
    var tip = function (j) { var st = steps[j]; return "position " + st.i + " " + JSON.stringify(st.txt); };
    function series(get, filter) {
      return se.strands.map(function (x, t) {
        if (filter && !filter(x)) return null;
        return { label: x.label, cls: se.strandClass(t), dash: x.commons ? "5 3" : null, values: steps.map(function (st) { return st.thr ? get(st.thr[t]) : null; }) };
      }).filter(Boolean);
    }
    var floor = M.Gate.floor(se.header.gate.openFloor, se.strands.length);
    var memory = B.chart.lines({ width: 420, height: 170, n: n, x0: 0, series: series(function (r) { return f32(r.mem); }), yMin: 0, yMax: 1, yTicks: [0, 0.5, 1],
      refs: [{ y: floor, label: "open floor " + floor.toFixed(3) }], shade: shade, cursor: k, onPick: onPick, tip: tip, title: "Memory per strand", left: 34 });
    var shares = sharesChart(se, k, onPick, shade);
    var hlm = B.chart.lines({ width: 420, height: 170, n: n, series: series(function (r) { return r.Hlm === undefined ? null : f32(r.Hlm); }), yMin: 0, yMax: 8, yTicks: [0, 4, 8],
      shade: shade, cursor: k, onPick: onPick, tip: tip, title: "H_lm per strand: the claim", left: 34 });
    var ln16 = Math.log(16);
    var hknn = B.chart.lines({ width: 420, height: 170, n: n, series: series(function (r) { return f32(r.Hknn); }, function (x) { return !x.commons; }), yMin: 0, yMax: 3, yTicks: [0, 1, 2, 3],
      refs: [{ y: ln16, label: "ln 16: spread evenly" }, { y: ln16 / 2, label: "½ ln 16" }, { y: Math.log(2), label: "ln 2" }], shade: shade, cursor: k, onPick: onPick, tip: tip, title: "H_knn per Thread: the evidence", left: 34 });
    return h("div", { class: "grid2" }, [
      h("div", { class: "panel" }, [h("h4", null, "Memory: who the gate trusts"), memory]),
      h("div", { class: "panel" }, [h("h4", null, "Shares of each token"), shares]),
      h("div", { class: "panel" }, [h("h4", null, "H_lm: the claim, in nats"), hlm]),
      h("div", { class: "panel" }, [h("h4", null, "H_knn: the evidence, in nats"), hknn])
    ]);
  }

  function sharesChart(se, k, onPick, shade) {
    var steps = se.shared, n = steps.length, W = 420, H = 170, L = 34, R = 12, T = 12, Bm = 22;
    var x = B.chart.scale(0, Math.max(1, n - 1), L, W - R), y = B.chart.scale(0, 1, H - Bm, T), bw = Math.max(2, (W - L - R) / n - 2);
    var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "Each token's shares, stacked by strand" });
    shade.forEach(function (sh) { svg.appendChild(s("rect", { class: "shade", x: x(sh.from - 0.5), y: T, width: x(sh.to + 0.5) - x(sh.from - 0.5), height: H - Bm - T })); });
    [0, 0.5, 1].forEach(function (t) { svg.appendChild(s("text", { class: "t-small", x: L - 6, y: y(t) + 3, "text-anchor": "end" }, String(t))); });
    steps.forEach(function (st, j) {
      if (!st.thr) return;
      var acc = 0;
      st.thr.forEach(function (r, t) {
        var v = f32(r.share);
        if (v <= 0) return;
        var g = s("g", { class: se.strandClass(t) });
        g.appendChild(s("rect", { x: x(j) - bw / 2, y: y(acc + v), width: bw, height: Math.max(0, y(acc) - y(acc + v)), style: "fill: var(--s)" }));
        svg.appendChild(g);
        acc += v;
      });
      var hit = s("rect", { class: "hover-target", x: x(j) - bw / 2 - 1, y: T, width: bw + 2, height: H - Bm - T });
      hit.appendChild(s("title", null, "position " + st.i + " " + JSON.stringify(st.txt) + ": " + st.thr.map(function (r, t) { return se.strands[t].name + " " + fmt.p(f32(r.share)); }).join(", ")));
      hit.addEventListener("click", function () { onPick(j); });
      svg.appendChild(hit);
    });
    svg.appendChild(s("line", { class: "cursor", x1: x(k), x2: x(k), y1: T, y2: H - Bm }));
    svg.appendChild(s("line", { x1: L, x2: W - R, y1: H - Bm, y2: H - Bm, style: "stroke: var(--border-strong)" }));
    return svg;
  }

  /** The Thread the hit table follows at step k: the lead if it is a Thread, else the Thread with the largest share. */
  function focusThread(se, k) {
    var st = se.shared[k], best = null;
    st.thr.forEach(function (r, t) { if (se.strands[t].commons) return; if (best === null || f32(r.share) > f32(st.thr[best].share)) best = t; });
    return best;
  }

  function hitsPanel(se, k) {
    var st = se.shared[k], t = focusThread(se, k);
    if (t === null) return h("p", { class: "note" }, "No Thread in this braid.");
    var rec = st.thr[t], strand = se.strands[t], thread = se.threads[strand.name];
    var knn = M.Mixer.knn(rec.hits, f32(strand.tau));
    var rows = rec.hits.map(function (hit, i) {
      var match = hit[2] === st.tok, part = thread.partitions[hit[3]], doc = thread.documents[part.doc];
      var cls = match ? "match" : (knn.weights[i] < 1e-4 ? "dim" : "");
      return h("tr", { class: cls }, [
        h("td", { class: "n" }, String(i + 1)), h("td", { class: "n" }, f32(hit[1]).toFixed(4)), h("td", { class: "n" }, fmt.p(knn.weights[i])),
        h("td", { class: "mono" }, fmt.tok(thread.text(hit[3], hit[4]))), h("td", null, doc.name + " · p" + part.index + "@" + hit[4]),
        h("td", { class: "n" }, f32(hit[5]).toFixed(4)), h("td", null, match && i < 3 ? "span-eligible" : match ? "matches" : "")
      ]);
    });
    return h("div", { class: "panel" }, [
      h("h4", null, [h("span", { class: "chip " + se.strandClass(t) }, strand.label), " · its 16 hits at position " + st.i]),
      h("div", { class: "scroll" }, h("table", null, [h("thead", null, h("tr", null, ["rank", "cosine", "w = softmax(s/τ)", "value", "where the value sits", "loss", ""].map(function (c, i) { return h("th", { class: i < 3 || i === 5 ? "n" : "" }, c); }))),
        h("tbody", null, rows)])),
      h("p", { class: "note" }, ["H_knn of these weights grouped by value: ", h("b", null, fmt.n(knn.entropy, 4)), " (logged ", fmt.n(f32(rec.Hknn), 4), "). Highlighted rows predicted the token that was written."])
    ]);
  }

  function sidePanel(se, k) {
    var st = se.shared[k], t = focusThread(se, k), commons = se.commons;
    var items = [];
    if (st.cand) items.push(h("div", null, [h("h4", null, "The three likeliest tokens"), h("table", null, [h("thead", null, h("tr", null, [h("th", null, "token"), h("th", { class: "n" }, "p")].concat(se.strands.map(function (x) { return h("th", { class: "n" }, x.label); })))),
      h("tbody", null, st.cand.map(function (c) { return h("tr", { class: c.tok === st.tok ? "match" : "" }, [h("td", { class: "mono" }, fmt.tok(c.txt)), h("td", { class: "n" }, fmt.p(f32(c.p)))].concat(c.parts.map(function (p) { return h("td", { class: "n" }, fmt.p(f32(p))); }))); }))])]));
    var gateRows = st.thr.map(function (r, u) {
      return h("tr", null, [h("td", null, h("span", { class: "chip " + se.strandClass(u) }, se.strands[u].label)), h("td", { class: "n" }, fmt.p(f32(r.mem))), h("td", { class: "n" }, r.open ? fmt.p(f32(r.w)) : "closed"),
        h("td", { class: "n" }, r.plm === undefined ? "–" : fmt.p(f32(r.plm))), h("td", { class: "n" }, fmt.p(f32(r.pknn))), h("td", { class: "n" }, fmt.p(f32(r.share))),
        h("td", { class: "n" }, r.ev === undefined ? "–" : fmt.n(f32(r.ev), 3)), h("td", { class: "n" }, fmt.p(f32(r.ss)))]);
    });
    items.push(h("div", null, [h("h4", null, st.src === "gen" ? "Every strand at this token (memory frozen)" : "Every strand at this prompt token (the gate learns)"), h("div", { class: "scroll" }, h("table", null, [
      h("thead", null, h("tr", null, ["strand", "memory", "w′", "p_lm(y)", "p_knn(y)", "share", "ρ̃", "shadow share"].map(function (c, i) { return h("th", { class: i ? "n" : "" }, c); }))), h("tbody", null, gateRows)]))]));
    if (t !== null) {
      var rec = st.thr[t], tr = rec.tr || { L: 0, tr: 0 }, mod = se.module()[t];
      var withThr = se.shared.filter(function (x) { return x.thr; }), j = withThr.indexOf(st), reading = mod && j >= 0 ? mod.readings[j] : null;
      var thread = se.threads[se.strands[t].name];
      var where = tr.e !== undefined ? thread.documents[thread.partitions[tr.row].doc].name + " · p" + thread.partitions[tr.row].index + "@" + tr.off + ", expecting " + fmt.tok(thread.text(thread.layoutIndex().valueRow[tr.e], thread.layoutIndex().valueOffset[tr.e])) : "no live chain";
      items.push(h("div", null, [h("h4", null, ["The trace and the module for ", h("span", { class: "chip " + se.strandClass(t) }, se.strands[t].label)]),
        h("p", { class: "readout" }, ["chain length L ", h("b", null, String(tr.L)), " · trace ", h("b", null, fmt.n(f32(tr.tr), 3)), tr.L < 24 ? " (a phrase: under 24 tokens counts 0)" : "", h("br"), where]),
        h("p", { class: "readout" }, ["module e_t logged ", h("b", null, fmt.n(f32(rec.mod || 0), 3)), reading ? " · label " + reading.label : "", " · κ = ", h("b", null, String(se.header.gate.moduleGain)), " so it moved nothing"])]));
    }
    return h("div", { class: "panel" }, items);
  }

  function citationPanel(se, k) {
    var st = se.shared[k], ann = se.annotate(), a = ann.annotations[k];
    if (st.src !== "gen") return h("div", { class: "panel" }, [h("h4", null, "The citation"), h("p", { class: "note" }, "Prompt tokens are not cited; the gate learns from them.")]);
    if (!a.citations.length) {
      var dom = M.dominant(st);
      return h("div", { class: "panel" }, [h("h4", null, "The citation"), h("p", { class: "note" }, dom !== null && se.strands[dom].commons ? "Uncited: the commons supplied it, and the commons is never cited." : "Uncited: no retrieved place predicted this token.")]);
    }
    var c = a.citations[0], span = a.spanIndex !== null ? ann.spans[a.spanIndex] : null, part = c.partition.part, thread = se.threads[c.partition.thread];
    var lo = Math.max(0, (span ? span.offset : c.offset) - 30), hi = Math.min(part.tokens.length, (span ? span.offset + span.length : c.offset + 1) + 30);
    var text = h("p", { class: "readout", style: "white-space: pre-wrap; line-height: 1.7" });
    if (lo > 0) text.appendChild(document.createTextNode("…"));
    for (var o = lo; o < hi; o++) {
      var piece = part.text.slice(part.offsets[o], part.offsets[o + 1]);
      var inSpan = span && o >= span.offset && o < span.offset + span.length, here = o === c.offset;
      text.appendChild(here ? h("mark", { style: "background: color-mix(in srgb, var(--gold) 45%, transparent); color: inherit; border-radius: 2px" }, piece)
        : inSpan ? h("span", { style: "text-decoration: underline 2px var(--gold); text-underline-offset: 3px" }, piece) : document.createTextNode(piece));
    }
    if (hi < part.tokens.length) text.appendChild(document.createTextNode("…"));
    var ok = span ? spanVerified(se, span) : null;
    return h("div", { class: "panel" }, [
      h("h4", null, ["The citation · ", h("span", { class: "chip " + se.classOf(c.partition.thread) }, c.partition.label)]),
      h("p", { class: "readout" }, [h("b", null, c.partition.documentName), " · partition " + c.partition.partitionIndex + " · token " + c.offset + " · confidence " + fmt.n(c.confidence, 2) +
        (span ? " · in a span of " + span.length + " tokens" + (ok ? ", re-read: verified" : ", re-read: mismatch") : " · no span here")]),
      text,
      h("p", { class: "note" }, thread ? "The marked token is where the matching hit's value sits in " + c.partition.thread + "'s own text; the underline is the verbatim span." : "")
    ]);
  }

  function verifyLine(se) {
    var checks = B.sessionChecks(se.slug), bad = checks.filter(function (c) { return !c.ok; });
    var spans = checks.find(function (c) { return c.name === "every span re-reads from its source"; });
    var traces = checks.find(function (c) { return c.name === "every chain state replays"; });
    return h("p", { class: "readout" }, ["verify in this browser: ", h("b", null, bad.length ? bad.length + " failed" : "ok"), " · ", traces.detail, " · ", spans.detail,
      " · ", h("a", { href: B.root() + "10-verify.html#fig-browser-verify" }, "every check")]);
  }

  B.define("replay", {
    title: "A session, token by token",
    data: ["sessions", "threads"],
    params: { s: { default: "joltvault" }, i: { type: "int", default: null }, panels: { type: "list", default: ["controls", "strip", "detail", "charts", "hits", "side", "citation", "verify"], link: false } },
    render: function (body, state, ctx) {
      var se = B.session(state.s);
      var walk = walkable(se);
      var k = state.i === null || state.i === undefined ? se.sharedAt(se.firstGen) : se.sharedAt(state.i);
      if (walk.indexOf(k) < 0) k = walk[walk.length - 1];
      var panels = new Set(state.panels);
      function pick(j) { if (walk.indexOf(j) >= 0) ctx.set({ i: se.shared[j].i }); }
      function move(d) { var at = walk.indexOf(k) + d; if (at >= 0 && at < walk.length) pick(walk[at]); }
      if (panels.has("controls")) {
        var playing = !!ctx.timer;
        var play = h("button", { type: "button", "aria-pressed": playing ? "true" : "false" }, playing ? "Pause" : "Play");
        play.addEventListener("click", function () {
          if (ctx.timer) { clearInterval(ctx.timer); ctx.timer = null; ctx.set({}); return; }
          if (walk.indexOf(k) === walk.length - 1) pick(se.sharedAt(se.firstGen));
          ctx.timer = setInterval(function () {
            var now = ctx.get(), cur = se.sharedAt(now.i === null ? se.firstGen : now.i), at = walk.indexOf(cur);
            if (at >= walk.length - 1) { clearInterval(ctx.timer); ctx.timer = null; ctx.set({}); return; }
            ctx.set({ i: se.shared[walk[at + 1]].i });
          }, 600);
          ctx.set({});
        });
        var prev = h("button", { type: "button", "aria-label": "Previous token" }, "←"), next = h("button", { type: "button", "aria-label": "Next token" }, "→");
        prev.addEventListener("click", function () { move(-1); });
        next.addEventListener("click", function () { move(1); });
        body.appendChild(h("div", { class: "fig-controls" }, [
          B.select("Session", B.sessionKeys().map(function (key) { var x = B.session(key); return { value: x.slug, label: x.label + " · " + x.id }; }), se.slug, function (v) { if (ctx.timer) { clearInterval(ctx.timer); ctx.timer = null; } ctx.set({ s: v, i: null }); }),
          h("span", null, [prev, " ", next, " ", play]),
          h("span", { class: "readout" }, "position " + se.shared[k].i + " of " + (se.shared.length - 1) + (se.shared[k].src === "gen" ? " · generated" : " · prompt"))
        ]));
      }
      if (panels.has("strip")) {
        var row = strip(se, k, pick);
        row.addEventListener("keydown", function (e) {
          if (e.key === "ArrowRight") { move(1); e.preventDefault(); }
          else if (e.key === "ArrowLeft") { move(-1); e.preventDefault(); }
          else if (e.key === "Home") { pick(walk[0]); e.preventDefault(); }
          else if (e.key === "End") { pick(walk[walk.length - 1]); e.preventDefault(); }
        });
        body.appendChild(strandLegend(se));
        body.appendChild(row);
        body.appendChild(h("p", { class: "note", "aria-live": "polite" }, "Prompt in grey, then the answer in the colour of the strand that supplied each token; a dashed box means no strand reached 0.6; faded means uncited; underlined means a verbatim span re-read from its source."));
      }
      if (panels.has("detail")) body.appendChild(detailBlock(se, k));
      if (panels.has("charts")) body.appendChild(chartsPanel(se, k, function (j) { pick(j); }));
      if (panels.has("entropies")) {
        var only = chartsPanel(se, k, function (j) { pick(j); });
        body.appendChild(h("div", { class: "grid2" }, [only.children[2], only.children[3]]));
      }
      if (panels.has("hits") || panels.has("side")) body.appendChild(h("div", { class: "grid2", style: "margin-top: .9rem" }, [panels.has("hits") ? hitsPanel(se, k) : null, panels.has("side") ? sidePanel(se, k) : null]));
      if (panels.has("citation")) body.appendChild(citationPanel(se, k));
      if (panels.has("verify")) body.appendChild(verifyLine(se));
    },
    selfCheck: function (state) {
      var se = B.session(state.s), out = [];
      var studio = { joltvault: [["410", 'token " 410"  ← thread: craft  share 1.00  (commons 0.00, ambient 0.00, veil 0.00)     p 0.30  H_gate 0.00'],
                                 ["410", "                      trace: off-trace L=7  H_knn 0.20→1.31  H_lm 1.33→3.62   (shadow β4: craft 1.00)"],
                                 ["410", "                      cited: craft/…63f9267b9c8b/partition-1/rows 8–12   conf 0.71   ◉ verified"]] };
      var want = studio[se.slug];
      if (want) {
        var k = se.shared.findIndex(function (st) { return st.src === "gen" && st.txt === " 410"; });
        var lines = detailLines(se, k).map(function (line) { return line.map(function (p) { return p[1]; }).join(""); });
        want.forEach(function (w, n) { out.push({ name: "detail line " + (n + 1) + " equals the studio's", ok: lines[n] === w[1], detail: lines[n] === w[1] ? "byte for byte" : JSON.stringify(lines[n]) }); });
      }
      return out.concat(B.sessionChecks(se.slug));
    }
  });
})();
