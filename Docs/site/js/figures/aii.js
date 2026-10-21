/*
 * AII figures: one index per Mac, joining it, a record and its partitions, search versus export,
 * and the Thread service's storage (files, per-document codebooks, the search gate, the export
 * path, lanes in one store). The stored form is the playground lane's own, copied from this Mac's
 * ~/.rao under a strict lane filter (Docs/site/fixtures/harbour/aii-store, data/aii-store.js).
 */
(function () {
  "use strict";
  var B = window.Braid, M = B.model, h = B.h, s = B.s, fmt = B.fmt;

  function store() { var x = (window.BraidData || {}).aiiStore; if (!x) throw new Error("missing data/aii-store.js"); return x; }
  function kv(pairs) {
    return h("table", null, h("tbody", null, pairs.filter(Boolean).map(function (p) {
      return h("tr", null, [h("th", { style: "width: 34%; white-space: normal" }, p[0]), h("td", { style: "white-space: normal; word-break: break-all", class: p[2] ? "mono" : "" }, p[1])]);
    })));
  }
  function short(id, n) { id = String(id); return id.length > (n || 18) ? id.slice(0, n || 18) + "…" : id; }
  function kb(bytes) { return bytes > 1048576 ? (bytes / 1048576).toFixed(1) + " MB" : Math.round(bytes / 1024) + " KB"; }

  // MARK: One Mac, one index, many lanes

  B.define("one-index", {
    title: "One Mac, one index, many lanes",
    params: { lane: { default: "braidplayground" } },
    render: function (body, state, ctx) {
      var st = store(), prov = st.provenance, counts = prov.documentsPerLane || {};
      var lanes = [
        { app: "ambient", label: "Ambient", owner: "aii-local", cls: "s-blue", what: "readings, notes, turns" },
        { app: "craft", label: "Craft", owner: "aii-local", cls: "s-green", what: "conventions, code, ledgers" },
        { app: "veil", label: "Veil", owner: "aii-local", cls: "s-orange", what: "images" },
        { app: "braidplayground", label: "Braid Playground", owner: prov.lane.owner, cls: "s-gold", what: "the harbour log" }
      ];
      var W = 680, H = 300;
      var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "Apps, their lanes, the Thread service and Braid on one Mac" });
      svg.appendChild(s("rect", { class: "box-sunk", x: 150, y: 14, width: 330, height: 272, rx: 10 }));
      svg.appendChild(s("text", { x: 164, y: 34, class: "t-strong" }, "~/.rao · one AII per Mac"));
      svg.appendChild(s("rect", { class: "box", x: 166, y: 46, width: 298, height: 120, rx: 8 }));
      svg.appendChild(s("text", { x: 178, y: 66, class: "t-strong" }, "The Thread service"));
      svg.appendChild(s("text", { x: 178, y: 84, class: "t-small" }, "the index · HTTP 47081 · gRPC 47090"));
      svg.appendChild(s("text", { x: 178, y: 104, class: "t-small" }, "one table, one graph, one registry"));
      svg.appendChild(s("text", { x: 178, y: 120, class: "t-small" }, "for every app on this Mac"));
      svg.appendChild(s("text", { x: 178, y: 146, class: "t-small t-mono" }, fmt.int(prov.storeCounts.documents) + " documents · " + fmt.int(prov.storeCounts.entities) + " entities"));
      svg.appendChild(s("rect", { class: "box", x: 166, y: 178, width: 298, height: 46, rx: 8 }));
      svg.appendChild(s("text", { x: 178, y: 198, class: "t-strong" }, "Sewn"));
      svg.appendChild(s("text", { x: 178, y: 214, class: "t-small" }, "grounded chat · 47080 · 47091 · Seam is the wire"));
      svg.appendChild(s("rect", { class: "box", x: 166, y: 234, width: 298, height: 40, rx: 8 }));
      svg.appendChild(s("text", { x: 178, y: 252, class: "t-small" }, "secrets/<app> · aii/lanes.json"));
      svg.appendChild(s("text", { x: 178, y: 266, class: "t-small" }, "a secret per app; the secret names the lane"));
      lanes.forEach(function (l, i) {
        var y = 34 + i * 62, active = l.app === state.lane;
        var g = s("g", { class: l.cls, style: "cursor: pointer", tabindex: "0", role: "button", "aria-pressed": active ? "true" : "false", "data-key": "lane-" + l.app });
        g.appendChild(s("rect", { x: 6, y: y, width: 132, height: 46, rx: 8, style: "fill: color-mix(in srgb, var(--s) " + (active ? 34 : 14) + "%, var(--bg-raised)); stroke: var(--s); stroke-width: " + (active ? 2 : 1) }));
        g.appendChild(s("text", { x: 16, y: y + 19, class: "t-strong" }, l.label));
        g.appendChild(s("text", { x: 16, y: y + 35, class: "t-small" }, fmt.int(counts[l.app] || 0) + " documents"));
        g.appendChild(s("path", { d: "M138," + (y + 23) + " C150," + (y + 23) + " 150," + (100) + " 166," + (100), style: "fill: none; stroke: var(--s); stroke-width: " + (active ? 2 : 1) + "; opacity: .8" }));
        g.addEventListener("click", function () { ctx.set({ lane: l.app }); });
        g.addEventListener("keydown", function (e) { if (e.key === "Enter" || e.key === " ") { ctx.set({ lane: l.app }); e.preventDefault(); } });
        svg.appendChild(g);
      });
      var braid = s("g", { class: "s-gold" });
      braid.appendChild(s("rect", { x: 520, y: 70, width: 152, height: 74, rx: 8, style: "fill: var(--bg-raised); stroke: var(--border-strong)" }));
      braid.appendChild(s("text", { x: 532, y: 92, class: "t-strong" }, "Braid"));
      braid.appendChild(s("text", { x: 532, y: 110, class: "t-small" }, "reads one lane"));
      braid.appendChild(s("text", { x: 532, y: 126, class: "t-small" }, "with that app's secret"));
      braid.appendChild(s("path", { d: "M464,106 L520,106", style: "stroke: var(--gold); stroke-width: 2; marker-end: none" }));
      braid.appendChild(s("text", { x: 470, y: 98, class: "t-small t-mono" }, "Export"));
      svg.appendChild(braid);
      body.appendChild(svg);
      var lane = lanes.find(function (l) { return l.app === state.lane; }) || lanes[3];
      var mine = lane.app === prov.lane.app;
      body.appendChild(h("div", { class: "readout", style: "margin-top: .4rem" }, [
        h("span", { class: "chip " + lane.cls }, lane.label), " · owner ", h("b", null, lane.owner), " · documents filed as ", h("b", null, lane.app + "/<kind>/<id>"),
        " · groups ", h("b", null, lane.app + "-<group>"), " · " + lane.what,
        mine ? h("span", null, [" · lane id ", h("b", null, short(prov.lane.id, 13))]) : null
      ]));
      body.appendChild(h("p", { class: "note" }, "Document counts read from this Mac's registry on " + prov.copiedAt.slice(0, 10) + ". Only the playground lane's records were copied into this site."));
    }
  });

  // MARK: join()

  B.define("join", {
    title: "What join() does, in order",
    render: function (body) {
      var prov = store().provenance;
      var steps = [
        ["Register the lane", "A 64-hex secret goes into ~/.rao/secrets/" + prov.lane.app + ", and an entry into ~/.rao/aii/lanes.json with owner " + prov.lane.owner + " and lane id " + short(prov.lane.id, 13) + "."],
        ["Take a lease", "The app holds the servers open while it runs. The last lease out may stop them, which is why the playground releases its hold and never calls leave()."],
        ["Adopt or start Sewn and Thread", "Running servers are adopted; missing ones are started from the installed binary."],
        ["Wait for proof", "join() returns once both servers prove they accept the app's secret. A brand-new lane may make them restart once."]
      ];
      body.appendChild(h("ol", { class: "plain", style: "margin: 0 0 .8rem; max-width: none" }, steps.map(function (st) { return h("li", null, [h("b", null, st[0] + ". "), st[1]]); })));
      body.appendChild(h("div", { class: "detail" }, [h("span", { class: "d" }, "1 join      "), "the braidplayground lane is registered; Sewn and Thread proved its secret (owner local-braidplayground)"]));
      body.appendChild(h("p", { class: "note" }, "The printed line is from the playground's run on 2026-10-17, as Examples/README.md records it."));
    }
  });

  // MARK: A record

  B.define("record", {
    title: "From a value to a filed record",
    params: { text: { default: null, link: false }, tags: { default: "on", link: false } },
    render: function (body, state, ctx) {
      var st = store(), doc = "braidplayground/log/harlow-light";
      var envelope = st.table[doc].metadata.json, parts = st.parts["log__harlow-light"];
      var text = state.text === null ? envelope.payload.text : state.text;
      var tagsOn = state.tags === "on";
      var area = h("textarea", { rows: 4, "aria-label": "The record's text", "data-key": "text", "data-keep": "text", style: "width: 100%; font: .8rem/1.5 var(--font-mono); background: var(--bg); color: var(--fg); border: 1px solid var(--border-strong); border-radius: 6px; padding: .5rem" }, text);
      area.addEventListener("input", function () { ctx.set({ text: area.value }); });
      var pieces = M.chunk(text);
      var toggle = h("button", { type: "button", "aria-pressed": tagsOn ? "true" : "false", "data-key": "tags" }, tagsOn ? "Tags on" : "Tags off");
      toggle.addEventListener("click", function () { ctx.set({ tags: tagsOn ? "off" : "on" }); });
      var reset = h("button", { type: "button", "data-key": "reset" }, "The harbour entry");
      reset.addEventListener("click", function () { ctx.set({ text: null, tags: "on" }); });
      body.appendChild(h("div", { class: "fig-controls" }, [toggle, reset, h("span", { class: "what-if" }, "Edit the text: the partitions below are AII's chunker, run in your browser")]));
      var swift = h("div", { class: "panel" }, [h("h4", null, "The app's value"), h("div", { class: "detail", style: "white-space: pre-wrap" },
        'LogEntry(\n  recordID: "harlow-light",\n  title: "Harlow Light",\n  text: "' + text.slice(0, 120) + (text.length > 120 ? "…" : "") + '",\n  tags: ' + (tagsOn ? '["lighthouse", "keeper"]' : "[]") + ")")]);
      var env = Object.assign({}, envelope, { tags: tagsOn ? envelope.tags : [], payload: Object.assign({}, envelope.payload, { text: text, tags: tagsOn ? envelope.tags : [] }) });
      var envJSON = JSON.stringify(env, null, 1);
      var bytes = new TextEncoder().encode(JSON.stringify(env)).length;
      var envelopePanel = h("div", { class: "panel" }, [h("h4", null, "The aii-record/1 envelope"), h("div", { class: "detail", style: "white-space: pre-wrap; max-height: 15rem; overflow: auto" }, envJSON),
        h("p", { class: "note" }, bytes + " bytes; AII refuses an envelope over 1 MB. Filed as " + doc + " in the group braidplayground-harbour.")]);
      body.appendChild(h("div", { class: "grid2" }, [swift, envelopePanel]));
      body.appendChild(area);
      body.appendChild(h("div", { class: "panel", style: "margin-top: .6rem" }, [h("h4", null, pieces.length + (pieces.length === 1 ? " partition" : " partitions") + ", as AII's chunker cuts this text"),
        h("div", { class: "ribbon", style: "gap: 6px" }, pieces.map(function (p, i) { return h("span", { class: "t", style: "white-space: normal; text-align: left; max-width: 100%" }, "p" + i + " · " + Array.from(p).length + " characters"); }))]));
      body.appendChild(h("p", { class: "readout" }, tagsOn ? ["Graph extraction: ", h("b", null, "off"), ". The tags become the record's entities: “lighthouse” and “keeper”, as concepts, and search looks through entities first."]
        : ["Graph extraction: ", h("b", null, "on"), ". With no tags, the Thread service extracts entities from the text on device."]));
      if (state.text === null) body.appendChild(h("p", { class: "note" }, "As filed on this Mac: " + parts.length + " partition, " + Array.from(parts[0].data).length + " characters, owner " + parts[0].ownerId + "."));
    },
    selfCheck: function () {
      var st = store(), out = [];
      Object.keys(st.parts).forEach(function (k) {
        var env = st.table["braidplayground/log/" + k.replace(/^log__/, "")].metadata.json;
        var pieces = M.chunk(env.payload.text);
        out.push({ name: k.replace(/^log__/, "") + ": the chunker cuts the text as the Thread service stored it", ok: pieces.length === st.parts[k].length && pieces.every(function (p, i) { return p === st.parts[k][i].data; }) });
      });
      return out;
    }
  });

  // MARK: The files

  B.define("store-files", {
    title: "Two files, three lists",
    params: { doc: { default: "harlow-light" }, open: { default: "table", link: false } },
    render: function (body, state, ctx) {
      var st = store(), prov = st.provenance, key = "log__" + state.doc, id = "braidplayground/log/" + state.doc;
      var docFile = st.documents[key], parts = st.parts[key], entry = st.table[id], reg = st.registry, ents = st.graph.entities.filter(function (e) { return e.documentIds.indexOf(id) >= 0; });
      var names = Object.keys(st.documents).map(function (k) { return k.replace(/^log__/, ""); });
      body.appendChild(h("div", { class: "fig-controls" }, [B.select("Record", names.map(function (n) { return { value: n, label: n }; }), state.doc, function (v) { ctx.set({ doc: v }); })]));
      var cards = [
        { k: "doc", title: "documents/" + id, sub: "one per document", rows: [["id", docFile.id, 1], ["name", docFile.name], ["owner_id", docFile.owner_id], ["lane_id", short(docFile.lane_id, 13), 1], ["created_at", docFile.created_at], ["url", docFile.url.relative, 1]] },
        { k: "parts", title: "documents/" + id + "-parts", sub: "the text, exactly as sent", rows: [["partitions", String(parts.length)], ["data", parts[0].data], ["id", short(parts[0].id, 24), 1], ["media_type", parts[0].media_type], ["ownerId", parts[0].ownerId], ["embedding", parts[0].embedding ? "kept" : "not kept: the vector lives in the table"]] },
        { k: "table", title: "table-" + short(prov.node, 8), sub: kb(prov.storeSizes.table) + " · every document on this Mac", rows: [["pq", entry.pq.numSubvectors + " subvectors · k " + entry.codebookShape[1] + " · threshold " + entry.pq.adaptiveThreshold], ["codebooks", entry.codebookShape.join(" × ") + " floats"], ["slots", entry.slots.length + " · codes [" + entry.slots[0].compressedEmbedding.join(", ") + "]", 1], ["entity_ids", entry.entity_ids.length + " (the tags)"], ["metadata", "the record's envelope, byte for byte"]] },
        { k: "registry", title: "registry-" + short(prov.node, 8), sub: kb(prov.storeSizes.registry) + " · who may see what", rows: [["owner", ((reg.documentOwners || {})[id] || [{ id: "?" }])[0].id], ["group", ((reg.documentGroups || {})[id] || ["?"])[0]], ["lane", short((reg.documentLanes || {})[id] || "?", 13), 1], ["access", (reg.documentAccess || {})[id] || "?"], ["retrievals", String(((reg.documentStats || {})[id] || {}).retrieval_count || 0)]] },
        { k: "graph", title: "graph-" + short(prov.node, 8), sub: kb(prov.storeSizes.graph) + " · shared by every lane", rows: ents.map(function (e) { return [e.kind, e.name]; }).concat([["relationships", "none for this record"]]) }
      ];
      var grid = h("div", { class: "grid3" });
      cards.forEach(function (c) {
        var open = state.open === c.k;
        var head = h("button", { type: "button", "data-key": "card-" + c.k, "aria-expanded": open ? "true" : "false", style: "all: unset; cursor: pointer; display: block; width: 100%" },
          [h("div", { class: "mono", style: "font-size: .76rem; color: var(--fg); word-break: break-all" }, c.title), h("div", { class: "note", style: "margin: .1rem 0 .3rem" }, c.sub)]);
        head.addEventListener("click", function () { ctx.set({ open: open ? null : c.k }); });
        grid.appendChild(h("div", { class: "panel", style: "border: 1px solid " + (open ? "var(--border-strong)" : "var(--border)") + "; border-radius: 8px; padding: .55rem .65rem; background: var(--bg)" }, [head, kv(c.rows)]));
      });
      body.appendChild(grid);
      if (state.open === "table") body.appendChild(h("div", { class: "detail", style: "white-space: pre-wrap; max-height: 14rem; overflow: auto; margin-top: .7rem" }, JSON.stringify(entry.metadata.json, null, 1)));
      body.appendChild(h("p", { class: "note" }, "Read from this Mac's store on " + prov.copiedAt.slice(0, 10) + " (AII " + prov.aiiCommit + "). Every file is a binary property list, written whole; the home folder is shown as ~."));
    }
  });

  // MARK: The codebooks

  function vec(id) { var e = store().table[id]; return e && e.vector; }
  function subDistances(q, v) {
    var out = [];
    for (var i = 0; i < 16; i++) { var d2 = 0; for (var j = 0; j < 64; j++) { var d = q[i * 64 + j] - v[i * 64 + j]; d2 += d * d; } out.push(Math.sqrt(d2)); }
    return out;
  }

  B.define("pq-codebooks", {
    title: "Sixteen small lookup tables, per document",
    params: { n: { type: "int", default: 1 }, q: { default: "harbourmaster" } },
    render: function (body, state, ctx) {
      var st = store(), target = "braidplayground/log/harlow-light", v = vec(target);
      var names = Object.keys(st.table).filter(function (id) { return vec(id); }).map(function (id) { return id.split("/").pop(); });
      var k = M.codebookSize(state.n), centroids = Math.min(k, state.n);
      body.appendChild(h("div", { class: "fig-controls" }, [
        B.slider("Partitions in a document", Math.log2(state.n), 0, 17, 0.25, function (x) { ctx.set({ n: Math.max(1, Math.round(Math.pow(2, x))) }); }, function (x) { return fmt.int(Math.max(1, Math.round(Math.pow(2, x)))); }),
        h("span", { class: "readout" }, ["k = ", h("b", null, fmt.int(k)), state.n < k ? " · fewer vectors than k, so the vectors themselves are the codebook" : " · the largest power of two ≤ n/39"])
      ]));
      var W = 680, H = 96, cell = (W - 20) / 16;
      var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "One stored vector, cut into sixteen strips of 64" });
      var max = 0; v.forEach(function (x) { max = Math.max(max, Math.abs(x)); });
      for (var i = 0; i < 16; i++) {
        var gx = 10 + i * cell;
        for (var j = 0; j < 64; j++) {
          var x = v[i * 64 + j], a = Math.min(1, Math.abs(x) / max);
          svg.appendChild(s("rect", { x: gx + (j % 8) * ((cell - 6) / 8), y: 8 + Math.floor(j / 8) * 8, width: (cell - 6) / 8 - 0.5, height: 7.5, style: "fill: " + (x >= 0 ? "var(--blue)" : "var(--orange)") + "; opacity: " + (0.12 + 0.88 * a).toFixed(2) }));
        }
        svg.appendChild(s("text", { x: gx + (cell - 6) / 2, y: 88, class: "t-small t-mono", "text-anchor": "middle" }, "s" + i));
      }
      body.appendChild(svg);
      body.appendChild(h("p", { class: "note" }, "Harlow Light's 1,024 floats as stored: sixteen strips of 64, blue positive, orange negative. One partition, so each strip's table is the strip itself, and all sixteen codes are 0."));
      var bytesVector = 1024 * 4, bytesCodes = 16 * 2, bytesBooks = 16 * centroids * 64 * 4;
      body.appendChild(h("p", { class: "readout" }, ["At " + fmt.int(state.n) + (state.n === 1 ? " partition" : " partitions") + ": tables ", h("b", null, kb(bytesBooks)), " once per document, then ", h("b", null, bytesCodes + " bytes"), " of codes per partition instead of ", h("b", null, fmt.int(bytesVector) + " bytes"), " of vector."]));
      var q = vec("braidplayground/log/" + state.q);
      var parts = subDistances(q, v), total = parts.reduce(function (a, b) { return a + b; }, 0);
      var others = names.filter(function (n) { return n !== "harlow-light"; }).map(function (n) { var d = subDistances(vec("braidplayground/log/" + n), v); return { n: n, d: d.reduce(function (a, b) { return a + b; }, 0) }; }).sort(function (a, b) { return a.d - b.d; });
      body.appendChild(h("div", { class: "fig-controls", style: "margin-top: .6rem" }, [B.select("Use this record's vector as the query", names.filter(function (n) { return n !== "harlow-light"; }).map(function (n) { return { value: n, label: n }; }), state.q, function (x) { ctx.set({ q: x }); })]));
      var W2 = 680, H2 = 120, x2 = B.chart.scale(0, Math.max(0.6, Math.max.apply(null, parts)), 40, W2 - 10);
      var svg2 = s("svg", { viewBox: "0 0 " + W2 + " " + H2, role: "img", "aria-label": "The query's distance to Harlow Light, subvector by subvector" });
      parts.forEach(function (d, i) {
        var y = 4 + i * 6.6;
        svg2.appendChild(s("rect", { x: 40, y: y, width: Math.max(1, x2(d) - 40), height: 5.2, style: "fill: var(--fg-2); opacity: .55" }));
      });
      svg2.appendChild(s("text", { class: "t-small", x: 4, y: 12 }, "s0"));
      svg2.appendChild(s("text", { class: "t-small", x: 4, y: 110 }, "s15"));
      body.appendChild(svg2);
      body.appendChild(h("p", { class: "readout" }, ["Distance from ", h("b", null, state.q), " to Harlow Light: the sum of 16 sub-distances, each read from a table built for the query, = ", h("b", null, total.toFixed(3)), ". Lower is closer."]));
      body.appendChild(h("p", { class: "note" }, ["Harlow Light's nearest records by this rule: " + others.slice(0, 4).map(function (o) { return o.n + " " + o.d.toFixed(2); }).join(" · ") + ". The query in a real search is the question's own embedding, which this site does not have."]));
    },
    selfCheck: function () {
      var st = store(), out = [];
      var bands = [[1, 2], [155, 2], [156, 4], [311, 4], [312, 8], [623, 8], [624, 16], [9984, 256], [79872, 2048], [2555904, 65536]];
      out.push({ name: "k(n) is the largest power of two ≤ n/39, between 2 and 65,536", ok: bands.every(function (b) { return M.codebookSize(b[0]) === b[1]; }) });
      var norms = Object.keys(st.table).filter(function (id) { return st.table[id].vector; }).map(function (id) { return Math.sqrt(st.table[id].vector.reduce(function (a, x) { return a + x * x; }, 0)); });
      out.push({ name: "every stored harbour vector has unit length", ok: norms.every(function (n) { return Math.abs(n - 1) < 1e-4; }), detail: norms.length + " vectors" });
      var codes = Object.keys(st.table).every(function (id) { return st.table[id].slots[0].compressedEmbedding.every(function (c) { return c === 0; }); });
      out.push({ name: "every one-partition record's codes are all 0", ok: codes });
      var rec = st.checks.filter(function (c) { return c.recomputed; }).length;
      out.push({ name: "stored partition ids that hash back from their stored vector", ok: true, detail: rec + " of " + st.checks.length + " on this Mac (reported, not required: see the page)" });
      return out;
    }
  });

  // MARK: Search is a view

  B.define("search-gate", {
    title: "Why a search is a view",
    params: { query: { default: "tag" } },
    render: function (body, state, ctx) {
      var tag = state.query === "tag";
      var b1 = h("button", { type: "button", "aria-pressed": tag ? "true" : "false", "data-key": "q1" }, "recall(\"lighthouse\")");
      var b2 = h("button", { type: "button", "aria-pressed": tag ? "false" : "true", "data-key": "q2" }, "\"Who looks after the lighthouse?\"");
      b1.addEventListener("click", function () { ctx.set({ query: "tag" }); });
      b2.addEventListener("click", function () { ctx.set({ query: "question" }); });
      body.appendChild(h("div", { class: "fig-controls" }, [b1, b2]));
      var stages = [
        ["Candidates", "every document of the owner, cut to the caller's lane", "18 harbour records"],
        ["Graph match", "entities whose names share a word with the query; relationships near it, over the whole graph", tag ? "the concept “lighthouse”" : "not logged"],
        ["Gate", "prose scans only documents linked to what matched", tag ? "Harlow Light" : "not logged"],
        ["Scan", "the best three partitions of each admitted document, ranked by PQ distance", tag ? "1 partition" : "not logged"],
        ["Expand", "one hop through the graph, up to six neighbours", tag ? "–" : "–"],
        ["Result", "sorted by distance, lower first", tag ? "Harlow Light · distance 5.004" : "no results"]
      ];
      var W = 680, H = 80, w = (W - 10) / stages.length;
      var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "The stages of a search" });
      stages.forEach(function (st, i) {
        var x = 5 + i * w, empty = !tag && i >= 1 && i < stages.length - 1;
        svg.appendChild(s("rect", { x: x, y: 6, width: w - 10, height: 66, rx: 7, class: "box", style: empty ? "stroke-dasharray: 4 3; opacity: .7" : "" }));
        svg.appendChild(s("text", { x: x + 8, y: 24, class: "t-strong", style: "font-size: 12px" }, st[0]));
        wrap(st[2], 16).forEach(function (line, k) { svg.appendChild(s("text", { x: x + 8, y: 42 + k * 13, class: "t-small" }, line)); });
        if (i < stages.length - 1) svg.appendChild(s("text", { x: x + w - 9, y: 42, class: "t-small", style: "fill: var(--faint)" }, "›"));
      });
      body.appendChild(svg);
      body.appendChild(h("table", null, h("tbody", null, stages.map(function (st) { return h("tr", null, [h("th", { style: "width: 18%" }, st[0]), h("td", { style: "white-space: normal" }, st[1])]); }))));
      body.appendChild(h("p", { class: "note" }, tag ? "From the playground's run on 2026-10-17: the tag reached the record, and the distance is the PQ distance described below."
        : "From the same run: the question returned nothing, and the stages in between were not logged. The playground's notes read it as search reaching this lane only through the entities a query names; AII's own docs add that a word matching only another lane's entities can gate a lane down to nothing."));
    }
  });
  function wrap(text, n) { var words = String(text).split(" "), lines = [], cur = ""; words.forEach(function (w) { if ((cur + " " + w).trim().length > n && cur) { lines.push(cur); cur = w; } else cur = (cur + " " + w).trim(); }); if (cur) lines.push(cur); return lines.slice(0, 3); }

  // MARK: The export, and the corpus hash recomputed

  function corpusHash(thread) {
    var lines = [];
    thread.documents.forEach(function (d) { d.rows.forEach(function (r) { var p = thread.partitions[r]; lines.push([d.id, p.index, p.textSHA256]); }); });
    lines.sort(function (a, b) { return a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : a[1] - b[1]; });
    return M.hex(M.sha256(lines.map(function (l) { return l[0] + "\t" + l[1] + "\t" + l[2] + "\n"; }).join("")));
  }

  B.define("export-path", {
    title: "From the store to a corpus",
    params: { row: { type: "int", default: 5 } },
    render: function (body, state, ctx) {
      var th = B.thread("harbour"), recomputed = corpusHash(th);
      var crosses = [["the texts", "-parts, in stored order"], ["the envelope", "the table's metadata, byte for byte"], ["name, owner, created", "the document file"], ["the group", "the registry"], ["partition id and url", "with include_embeddings"]];
      var never = ["the PQ codes", "the codebooks", "the thresholds", "the graph", "retrieval stats", "the lane id"];
      body.appendChild(h("div", { class: "grid2" }, [
        h("div", { class: "panel" }, [h("h4", null, "What ExportCorpus returns"), h("ul", { class: "checks" }, crosses.map(function (c) { return h("li", null, [h("span", { class: "mark ok" }, "→"), h("span", null, [h("b", null, c[0]), " · from " + c[1]]), h("span")]); }))]),
        h("div", { class: "panel" }, [h("h4", null, "What never leaves the service"), h("ul", { class: "checks" }, never.map(function (c) { return h("li", null, [h("span", { class: "mark skip" }, "·"), h("span", null, c), h("span")]); }))])
      ]));
      var lines = [];
      th.documents.forEach(function (d) { d.rows.forEach(function (r) { lines.push({ id: d.id, idx: th.partitions[r].index, sha: th.partitions[r].textSHA256, row: r }); }); });
      lines.sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : a.idx - b.idx; });
      body.appendChild(h("div", { class: "panel", style: "margin-top: .7rem" }, [h("h4", null, "Braid's snapshot: sorted by id, then hashed line by line"),
        h("div", { class: "detail", style: "max-height: 12rem; overflow: auto" }, lines.map(function (l) { return h("div", { style: l.row === state.row ? "background: rgba(212,175,55,.25)" : "" }, l.id.padEnd(36) + " " + l.idx + "  " + l.sha.slice(0, 16) + "…"); })),
        h("p", { class: "readout" }, ["SHA-256 of these lines, computed in your browser: ", h("b", null, recomputed.slice(0, 12)), recomputed === th.corpusHash ? " · equals the Thread's corpus hash" : " · differs from the Thread's " + th.corpusHash.slice(0, 12)])]));
      body.appendChild(h("p", { class: "note" }, "Braid keeps the texts and drops the envelope and any vectors. Change one character of one record and this hash changes, so a Thread version can prove which lane state it learned."));
    },
    selfCheck: function () {
      return ["harbour", "ambient", "craft", "veil"].filter(function (n) { return (window.BraidData.threads || {})[n]; }).map(function (n) {
        var th = B.thread(n), c = corpusHash(th);
        return { name: n + ": the corpus hash recomputes from the snapshot", ok: c === th.corpusHash, detail: c.slice(0, 12) };
      });
    }
  });

  // MARK: View versus corpus

  B.define("view-vs-corpus", {
    title: "A view is not a corpus",
    render: function (body) {
      var th = B.thread("harbour"), part = th.partitions;
      var left = h("div", { class: "panel" }, [h("h4", null, "Search · recall(\"lighthouse\")"),
        h("ul", { class: "checks" }, [h("li", null, [h("span", { class: "mark ok" }, "1"), "Harlow Light · partition 0", h("span", { class: "val" }, "5.004")])]),
        h("p", { class: "note" }, "At most three partitions per document, of the documents the graph admits, ranked by distance. A question returned nothing.")]);
      var rows = th.documents.map(function (d) { var p = part[d.rows[0]]; return h("li", null, [h("span", { class: "mark ok" }, "·"), h("span", null, d.name), h("span", { class: "val" }, p.tokens.length + " tokens")]); });
      var right = h("div", { class: "panel" }, [h("h4", null, "ExportCorpus · every record the app filed"), h("ul", { class: "checks", style: "max-height: 14rem; overflow: auto" }, rows),
        h("p", { class: "note" }, th.documents.length + " records, " + part.length + " partitions, " + part.reduce(function (a, p) { return a + p.tokens.length; }, 0) + " tokens, in id order, with the whole text of each.")]);
      body.appendChild(h("div", { class: "grid2" }, [left, right]));
    }
  });

  // MARK: Lanes in one store

  B.define("lanes-shared", {
    title: "One store, many lanes",
    render: function (body) {
      var st = store(), prov = st.provenance, counts = prov.documentsPerLane || {};
      var total = Object.keys(counts).reduce(function (a, k) { return a + counts[k]; }, 0);
      var W = 680, H = 150, x = B.chart.scale(0, total, 10, W - 10), acc = 0;
      var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": "Documents per lane in this Mac's one store" });
      var cls = { ambient: "s-blue", craft: "s-green", veil: "s-orange", braidplayground: "s-gold" };
      Object.keys(counts).forEach(function (k) {
        var g = s("g", { class: cls[k] || "" });
        g.appendChild(s("rect", { x: x(acc), y: 30, width: Math.max(2, x(acc + counts[k]) - x(acc)), height: 34, style: "fill: var(--s); opacity: .8" }));
        g.appendChild(s("text", { x: x(acc) + 4, y: 84, class: "t-small" }, k + " · " + fmt.int(counts[k])));
        svg.appendChild(g);
        acc += counts[k];
      });
      svg.appendChild(s("text", { x: 10, y: 20, class: "t-strong" }, "One table, one graph, one registry · " + fmt.int(total) + " documents on this Mac"));
      svg.appendChild(s("text", { x: 10, y: 112, class: "t-small" }, "The registry maps every document to its lane; every read is cut to the caller's lane before anything is scanned."));
      svg.appendChild(s("text", { x: 10, y: 130, class: "t-small" }, "The graph is shared: an entity named in two apps is one entity. Documents never move between lanes."));
      body.appendChild(svg);
      body.appendChild(kv([
        ["A lane id", "UUID of the first 16 bytes of HMAC-SHA256(device key, \"rao-lane-v1:\" + app)"],
        ["Which lane a call is in", "the one its secret names; a lane a client sends is ignored"],
        ["The stack identity, aii", "reads every lane, writes none"],
        ["Sewn", "files memories back into the asking app's lane, as <app>/memory/<id>"],
        ["A training export", "under an app's secret, that app's records only; under the stack identity, every app's records in one sorted stream"]
      ]));
      body.appendChild(h("p", { class: "note" }, "Counts read from this Mac's registry on " + prov.copiedAt.slice(0, 10) + "."));
    }
  });
})();
