/*
 * The code explorer (code.html): every Swift file under Sources/, verbatim, with its scopes, four trails
 * through the code, training and inference and the same two for questions, and a call graph matched by name and argument labels when the
 * site was built (src/sources.py).
 * A page-level app, not a figure: the find box, the source pane's scroll and the tree's open folders must
 * outlive each other's updates, and a figure redraws its whole body. Braid.explorer.mount(root) draws it;
 * Braid.explorer.selfCheck() needs no root, so the self-test page can load the data and check it.
 */
(function () {
  "use strict";
  var B = window.Braid, h = B.h;
  var KIND = { f: "func", i: "init", d: "deinit", s: "subscript", v: "var", S: "struct", C: "class", E: "enum", A: "actor", X: "extension", P: "protocol" };
  var TAG = { f: "func", i: "init", d: "deinit", s: "subs", v: "var", S: "struct", C: "class", E: "enum", A: "actor", X: "ext", P: "proto" };
  var TIERS = ["exact", "likely", "ambiguous"];
  var REQUIREMENT = 1, OPERATOR = 2, LOCAL = 4;
  var CALLABLE = "fis";
  var NARROW = 900;

  function sources() { return (window.BraidData || {}).sources || null; }
  function push(map, key, value) { (map[key] = map[key] || []).push(value); }

  // MARK: The model, built once from the data

  var model = null;
  function build() {
    if (model) return model;
    var src = sources();
    if (!src || !src.index) return null;
    var index = src.index, files = [], scopes = [], byPath = {}, missing = [];
    index.modules.forEach(function (mod) {
      if (!src[mod]) { missing.push(mod); return; }
      src[mod].files.forEach(function (f) {
        var file = { path: f.path, name: f.path.split("/").pop(), module: mod, text: f.text, header: f.header, marks: f.marks || [], first: f.first,
                     lineCount: f.lines, bytes: f.bytes, scopes: [], lines: null };
        f.scopes.forEach(function (row, k) {
          var sc = { g: f.first + k, local: k, file: file, kind: row[0], name: row[1], labels: row[2], mods: row[3], decl: row[4], sig: row[5],
                     brace: row[6], end: row[7], doc: row[8], parent: row[9], flags: row[10], cases: row[11] || null };
          file.scopes.push(sc);
          scopes[sc.g] = sc;
        });
        files.push(file);
        byPath[file.path] = file;
      });
    });
    var byQualified = {}, byName = {}, byLabelled = {};
    files.forEach(function (file) {
      var seen = {};
      file.scopes.forEach(function (sc) {
        var names = [], k = sc.local;
        while (k >= 0) { names.unshift(file.scopes[k].name); k = file.scopes[k].parent; }
        sc.qualified = names.join(".");
        sc.callable = CALLABLE.indexOf(sc.kind) >= 0;
        sc.labelText = sc.callable ? "(" + sc.labels.map(function (l) { return l + ":"; }).join("") + ")" : "";
        var tail = sc.kind === "X" ? "extension:" + sc.qualified : sc.qualified + sc.labelText;
        var base = file.path.replace(/^Sources\//, "") + ":" + tail;
        seen[base] = (seen[base] || 0) + 1;
        sc.id = seen[base] === 1 ? base : base + "~" + seen[base];
        sc.tail = sc.id.slice(sc.id.indexOf(":") + 1);
        sc.label = (sc.kind === "X" ? "extension " : "") + sc.qualified + sc.labelText;
        sc.depth = 0;
        for (var p = sc.parent; p >= 0; p = file.scopes[p].parent) sc.depth++;
        push(byQualified, sc.qualified, sc);
        push(byName, sc.name, sc);
        if (sc.callable) { push(byLabelled, sc.qualified + sc.labelText, sc); push(byLabelled, sc.name + sc.labelText, sc); }
      });
    });
    var out = scopes.map(function () { return []; }), into = scopes.map(function () { return []; });
    index.edges.forEach(function (e) { if (out[e[0]] && into[e[1]]) { out[e[0]].push(e); into[e[1]].push(e); } });
    // The four trails, and every place a declaration sits on them: once a trail at most.
    var trails = index.trails || [], trailById = {}, onTrail = {};
    trails.forEach(function (t) {
      trailById[t.id] = t;
      t.steps.forEach(function (st) { st.entries.forEach(function (en, k) { push(onTrail, en.scope, { trail: t, step: st.n, pos: k }); }); });
    });
    model = { index: index, files: files, scopes: scopes, byPath: byPath, byQualified: byQualified, byName: byName, byLabelled: byLabelled,
              out: out, into: into, trails: trails, trailById: trailById, onTrail: onTrail, missing: missing, stripped: {} };
    return model;
  }

  /** A trail's name inside a sentence: "the training trail", "the Q/A inference trail". */
  function trailName(t) { return t.title.replace(/^[A-Z](?=[a-z])/, function (c) { return c.toLowerCase(); }); }
  /** The trail being walked; a declaration's places on the trails; its place on the walked one, or null. */
  function current() { return model.trailById[state.trail] || model.trails[0]; }
  function placesOf(sc) { return (sc && model.onTrail[sc.g]) || []; }
  function onCurrent(sc) { return placesOf(sc).filter(function (o) { return o.trail === current(); })[0] || null; }
  /** The overview step whose code link opens step n of trail t, or 0. */
  function overviewStepOf(t, n) {
    var steps = B.overviewSteps || [];
    for (var k = 1; k < steps.length; k++) if (steps[k].code === t.id + "-" + n) return k;
    return 0;
  }

  function linesOf(file) {
    if (!file.lines) {
      file.lines = file.text.split("\n");
      if (file.lines.length && file.lines[file.lines.length - 1] === "") file.lines.pop();
    }
    return file.lines;
  }
  function lastLine(sc) { return sc.end || sc.sig; }
  /** The innermost scope whose lines hold line n, or null. */
  function scopeAt(file, n) {
    var best = null;
    file.scopes.forEach(function (sc) {
      var from = sc.doc ? Math.min(sc.doc[0], sc.decl) : sc.decl;
      if (from <= n && n <= lastLine(sc) && (!best || sc.decl > best.decl || (sc.decl === best.decl && sc.local > best.local))) best = sc;
    });
    return best;
  }
  function dedent(lines) {
    var pad = Infinity;
    lines.forEach(function (l) { if (l.trim()) pad = Math.min(pad, l.match(/^\s*/)[0].length); });
    return lines.map(function (l) { return l.slice(pad === Infinity ? 0 : pad); });
  }
  function signature(sc) {
    var lines = linesOf(sc.file), to = sc.brace ? sc.brace[0] : lastLine(sc), parts = [];
    for (var n = sc.decl; n <= to; n++) {
      var line = lines[n - 1] || "";
      if (sc.brace && n === sc.brace[0]) line = line.slice(0, sc.brace[1]);
      parts.push(line.replace(/\s+$/, ""));
    }
    return dedent(parts).join("\n");
  }
  function docText(sc) {
    if (!sc.doc) return null;
    return linesOf(sc.file).slice(sc.doc[0] - 1, sc.doc[1]).map(function (l) { return l.replace(/^\s*\/\/\/ ?/, ""); }).join("\n");
  }
  function headerText(file, range) {
    if (!range) return null;
    return linesOf(file).slice(range[0] - 1, range[1]).map(function (l) {
      return l.replace(/^\/\/(?:  (?:WHAT|PIN|IN|OUT):)?/, "").replace(/^ {0,8}/, "");
    }).join("\n");
  }
  function kindWords(sc) {
    var words = [];
    if (sc.mods) words.push(sc.mods);
    words.push(sc.flags & LOCAL && sc.kind === "f" ? "local func" : KIND[sc.kind]);
    if (sc.flags & REQUIREMENT) words.push("protocol requirement");
    if (sc.flags & OPERATOR) words.push("operator");
    return words.join(" · ");
  }

  // MARK: Search

  function stripped(file) {
    var m = model.stripped[file.path];
    if (m) return m;
    var chars = [], lines = [], line = 1, text = file.text;
    for (var i = 0; i < text.length; i++) {
      var c = text[i];
      if (c === "\n") { line++; continue; }
      if (c === " " || c === "\t" || c === "\r") continue;
      chars.push(c);
      lines.push(line);
    }
    m = model.stripped[file.path] = { text: chars.join(""), lines: lines };
    return m;
  }
  function labelsFrom(params) {
    var out = [], depth = 0, cur = "";
    for (var i = 0; i <= params.length; i++) {
      var c = params[i];
      if (c === "(" || c === "[" || c === "<") depth++;
      else if (c === ")" || c === "]" || c === ">") depth--;
      if ((c === "," && depth === 0) || i === params.length) {
        var before = cur.split(":")[0].trim().split(/\s+/);
        if (cur.indexOf(":") >= 0 && before[0]) out.push(before[0].replace(/`/g, ""));
        cur = "";
      } else cur += c;
    }
    return out;
  }
  function uniq(list) { var seen = {}; return list.filter(function (sc) { if (seen[sc.g]) return false; seen[sc.g] = true; return true; }); }
  function findSymbol(q) {
    var m = model, hits = [];
    if (/\(/.test(q)) {
      hits = (m.byLabelled[q] || []).slice();
      if (!hits.length) m.scopes.forEach(function (sc) { if (sc.callable && (sc.qualified + sc.labelText).slice(-q.length) === q) hits.push(sc); });
    } else {
      hits = (m.byQualified[q] || []).concat(q.indexOf(".") < 0 ? m.byName[q] || [] : []);
      if (!hits.length && q.indexOf(".") > 0) m.scopes.forEach(function (sc) { if (sc.qualified.slice(-q.length - 1) === "." + q) hits.push(sc); });
      var cases = m.scopes.filter(function (sc) {
        return sc.cases && q.indexOf(".") > 0 && sc.qualified === q.slice(0, q.lastIndexOf(".")) && sc.cases.indexOf(q.slice(q.lastIndexOf(".") + 1)) >= 0;
      });
      hits = hits.concat(cases);
    }
    return uniq(hits);
  }
  function findSignature(line) {
    var m = model, name = null, labels = null, kinds = null, r;
    if ((r = /\bfunc\s+([^\s(<]+)\s*(?:<[^(]*>)?\s*\(([\s\S]*?)\)\s*(?:async|throws|rethrows|->|where|\{|$)/.exec(line))) { name = r[1].replace(/`/g, ""); labels = labelsFrom(r[2]); kinds = "f"; }
    else if ((r = /\binit[?!]?\s*(?:<[^(]*>)?\s*\(([\s\S]*?)\)/.exec(line))) { name = "init"; labels = labelsFrom(r[1]); kinds = "i"; }
    else if ((r = /\bsubscript\s*\(([\s\S]*?)\)/.exec(line))) { name = "subscript"; labels = labelsFrom(r[1]); kinds = "s"; }
    else if ((r = /\bvar\s+`?(\w+)`?\s*:/.exec(line))) { name = r[1]; kinds = "v"; }
    else if ((r = /\b(struct|class|enum|protocol|actor)\s+`?(\w+)/.exec(line))) { name = r[2]; kinds = "SCEPA"; }
    else if ((r = /\bextension\s+([\w.]+)/.exec(line))) { name = r[1].split(".").pop(); kinds = "X"; }
    if (!name) return [];
    var hits = (m.byName[name] || []).filter(function (sc) { return kinds.indexOf(sc.kind) >= 0; });
    if (labels) {
      var exact = hits.filter(function (sc) { return sc.labels && sc.labels.join(":") === labels.join(":"); });
      if (exact.length) hits = exact;
    }
    return hits;
  }
  function findBody(q) {
    var needle = q.replace(/\s+/g, "");
    if (needle.length < 24) return [];
    var hits = [];
    model.files.forEach(function (file) {
      var s = stripped(file), at = s.text.indexOf(needle);
      if (at < 0) return;
      var first = s.lines[at], last = s.lines[at + needle.length - 1], sc = null;
      file.scopes.forEach(function (c) {
        var from = c.doc ? Math.min(c.doc[0], c.decl) : c.decl;
        if (from <= first && last <= lastLine(c) && (!sc || c.decl > sc.decl)) sc = c;
      });
      hits.push(sc ? { sc: sc, line: first } : { file: file, line: first });
    });
    return hits;
  }
  function findLoose(q) {
    var low = q.toLowerCase(), ranked = [];
    model.scopes.forEach(function (sc) {
      var name = sc.name.toLowerCase(), qual = sc.qualified.toLowerCase(), file = sc.file.name.toLowerCase();
      var rank = name === low ? 0 : qual === low ? 0 : name.indexOf(low) === 0 ? 1 : qual.indexOf(low) >= 0 ? 2 : file.indexOf(low) >= 0 && sc.parent < 0 ? 3 : -1;
      if (rank >= 0) ranked.push({ sc: sc, rank: rank });
    });
    ranked.sort(function (a, b) { return a.rank - b.rank || a.sc.qualified.length - b.sc.qualified.length || a.sc.g - b.sc.g; });
    return ranked.map(function (r) { return r.sc; });
  }
  /** Results for a query, best first: [{ sc, line?, file?, how }]. */
  function search(raw) {
    var q = (raw || "").trim();
    if (!q || !build()) return [];
    var multi = /\n/.test(q), out = [];
    function add(list, how) { list.forEach(function (x) { out.push(x.g !== undefined ? { sc: x, how: how } : Object.assign({ how: how }, x)); }); }
    if (!multi && /^[\w.<>=!+\-*\/%&|^~?`]+(\([\w:]*\))?$/.test(q)) add(findSymbol(q.replace(/`/g, "")), "by name");
    if (!out.length && /\b(func|init|subscript|var|struct|class|enum|protocol|actor|extension)\b/.test(q)) {
      if (multi) add(findBody(q), "by its text");
      if (!out.length) add(findSignature(q.split("\n").filter(function (l) { return /\b(func|init|subscript|var|struct|class|enum|protocol|actor|extension)\b/.test(l); })[0] || q), "by its signature");
    }
    if (!out.length) add(findBody(q), "by its text");
    if (!out.length && !multi) add(findLoose(q), "by part of its name");
    var seen = {};
    return out.filter(function (r) { var key = r.sc ? "s" + r.sc.g : "f" + r.file.path + r.line; if (seen[key]) return false; seen[key] = true; return true; });
  }

  // MARK: Deep links

  /** "#Sources/<path>.swift[:<line>|:<scope tail>]", "#trail-<trail>-<n>[;n=<k>]" or "#q=<text>" → what it names. */
  function parseTarget(raw) {
    var m = build(), r;
    if (!m || !raw) return null;
    if ((r = /^trail-([a-z]+(?:-[a-z]+)*)-(\d+)(?:;n=(\d+))?$/.exec(raw))) {
      var t = m.trailById[r[1]], n = +r[2];
      if (!t || n < 1 || n > t.steps.length) return null;
      return { trail: t.id, step: n, pos: r[3] ? Math.max(0, Math.min(+r[3] - 1, t.steps[n - 1].entries.length - 1)) : 0 };
    }
    if ((r = /^trail-(\d+)(?:;n=(\d+))?$/.exec(raw))) {
      // A link from before there were several trails, to the one trail's step n: it opens what the overview's step n opens now.
      var o = (B.overviewSteps || [])[+r[1]];
      return +r[1] > 0 && o && o.code ? parseTarget("trail-" + o.code + (r[2] ? ";n=" + r[2] : "")) : null;
    }
    if ((r = /^q=([\s\S]*)$/.exec(raw))) return { query: r[1] };
    if ((r = /^(Sources\/.+?\.swift)(?::([\s\S]+))?$/.exec(raw))) {
      var file = m.byPath[r[1]];
      if (!file) return null;
      if (!r[2]) return { file: file };
      if (/^\d+$/.test(r[2])) return { file: file, line: +r[2], sc: scopeAt(file, +r[2]) };
      var hit = file.scopes.filter(function (sc) { return sc.tail === r[2]; });
      if (!hit.length) hit = file.scopes.filter(function (sc) { return sc.qualified === r[2]; });
      return hit.length === 1 ? { file: file, sc: hit[0], line: hit[0].sig } : { file: file };
    }
    return null;
  }

  // MARK: The app

  var ui = null, state = { file: null, sc: null, trail: null, step: 0, pos: -1, lastPos: 0, at: {}, only: false, results: [], active: 0 };

  function mount(root) {
    if (!root) return;
    var m = build();
    if (!m) { root.appendChild(h("p", { class: "fig-error" }, "The sources were not built. Run Docs/site/src/sources.py, then reload.")); return; }
    ui = { root: root };
    var kept = B.storage.get("explorer:trail", "");
    state.trail = m.trailById[kept] ? kept : (m.trails[0] || {}).id;
    root.appendChild(statusLine());
    root.appendChild(findBox());
    root.appendChild(trailStrip());
    root.appendChild(treePanel());
    root.appendChild(sourcePanel());
    ui.card = h("aside", { class: "xp-card", "aria-live": "polite", "aria-label": "The selected declaration" });
    root.appendChild(ui.card);
    root.appendChild(h("p", { class: "keys xp-keys" }, ["Keys: ", h("kbd", null, "/"), " finds · ", h("kbd", null, "["), " ", h("kbd", null, "]"), " walk the chosen trail · ",
      h("kbd", null, "↑"), " ", h("kbd", null, "↓"), " in the source move between declarations · ", h("kbd", null, "Esc"), " clears the box."]));
    root.addEventListener("keydown", onKey);
    document.addEventListener("keydown", function (e) {
      var el = document.activeElement;
      if (e.key === "/" && !e.metaKey && !e.ctrlKey && !(el && /INPUT|TEXTAREA|SELECT/.test(el.tagName))) { ui.find.focus(); e.preventDefault(); }
    });
    window.addEventListener("hashchange", function () { readHash(false); });
    window.addEventListener("resize", fitTree);
    fitTree();
    if (!readHash(true)) {
      var last = parseTarget(B.storage.get("explorer:last", ""));
      if (last && last.sc) select(last.sc, { hash: false, quiet: true });
      else walk(1, 0, { hash: false, quiet: true });
    }
    renderCard();
    renderTrail();
  }

  function statusLine() {
    var m = model, c = m.index.counts, manifest = (window.BraidData || {}).manifest || {};
    var parts = [h("span", null, B.fmt.int(c.files) + " files · " + B.fmt.int(c.lines) + " lines · " + B.fmt.int(c.scopes) + " declarations · built from " + (m.index.commit || "an unknown commit"))];
    var notes = [];
    if (m.index.dirty) notes.push("Built from Sources/ with uncommitted edits. Line numbers can differ from Xcode's until the site is rebuilt.");
    var base = String(m.index.commit || "").split(",")[0];
    if (manifest.braidCommit && base && manifest.braidCommit !== base) notes.push("The sources were built at " + base + " and the chapters' data at " + manifest.braidCommit + ". Run Docs/site/src/build.sh to bring them level.");
    if (m.missing.length) notes.push("Missing: data/sources/" + m.missing.join(".js, data/sources/") + ".js.");
    return h("div", { class: "xp-status" }, parts.concat(notes.map(function (n) { return h("p", { class: "xp-stale" }, n); })));
  }

  function findBox() {
    ui.find = h("textarea", { rows: 2, spellcheck: "false", autocomplete: "off", "aria-label": "Find a declaration", "aria-controls": "xp-results",
                              placeholder: "Gate.observe, a signature, or a whole function body" });
    ui.results = h("ol", { class: "xp-results", id: "xp-results", role: "listbox", hidden: true, "aria-label": "Matches" });
    var timer = null, pasted = false;
    ui.find.addEventListener("paste", function () { pasted = true; });
    ui.find.addEventListener("input", function () {
      clearTimeout(timer);
      fitFind();
      timer = setTimeout(function () { runSearch(pasted); pasted = false; }, 120);
    });
    ui.find.addEventListener("keydown", function (e) {
      var single = ui.find.value.indexOf("\n") < 0, open = !ui.results.hidden && state.results.length;
      if (e.key === "Escape") { ui.find.value = ""; fitFind(); runSearch(false); if (ui.pre) ui.pre.focus(); e.preventDefault(); }
      else if (open && single && (e.key === "ArrowDown" || e.key === "ArrowUp")) { activate(state.active + (e.key === "ArrowDown" ? 1 : -1)); e.preventDefault(); }
      else if (open && e.key === "Enter" && (single || e.metaKey || e.ctrlKey) && !e.shiftKey) { choose(state.active); e.preventDefault(); }
      e.stopPropagation();
    });
    return h("div", { class: "xp-find" }, [
      h("label", { class: "xp-find-label" }, ["Find", ui.find]),
      h("p", { class: "note" }, "Paste a name, Type.method, a signature line or a whole function body straight from Xcode."),
      ui.results
    ]);
  }
  function fitFind() { ui.find.rows = Math.min(6, Math.max(2, ui.find.value.split("\n").length)); }
  function runSearch(jump) {
    var q = ui.find.value;
    state.results = search(q);
    state.active = 0;
    ui.results.textContent = "";
    if (!q.trim()) { ui.results.hidden = true; ui.find.removeAttribute("aria-activedescendant"); return; }
    ui.results.hidden = false;
    if (!state.results.length) {
      ui.results.appendChild(h("li", { class: "xp-none" }, "Nothing in Sources/ matches. Try the bare function name, or paste the whole signature line."));
      return;
    }
    state.results.slice(0, 30).forEach(function (r, k) {
      var sc = r.sc, where = (sc ? sc.file : r.file);
      var li = h("li", { role: "option", id: "xp-opt-" + k, "aria-selected": k === 0 ? "true" : "false" }, [
        h("b", null, sc ? sc.label : where.name),
        h("small", null, (sc ? KIND[sc.kind] + " · " : "") + where.module + " · " + where.name + ":" + (r.line || (sc ? sc.sig : 1)) + " · found " + r.how)
      ]);
      li.addEventListener("mousedown", function (e) { e.preventDefault(); });
      li.addEventListener("click", function () { choose(k); });
      ui.results.appendChild(li);
    });
    if (state.results.length > 30) ui.results.appendChild(h("li", { class: "xp-none" }, "and " + (state.results.length - 30) + " more"));
    ui.find.setAttribute("aria-activedescendant", "xp-opt-0");
    if (jump && state.results.length >= 1) choose(0, { keepFocus: true });
  }
  function activate(k) {
    var n = Math.min(state.results.length, 30);
    if (!n) return;
    state.active = (k + n) % n;
    Array.prototype.forEach.call(ui.results.querySelectorAll("[role=option]"), function (li, i) { li.setAttribute("aria-selected", i === state.active ? "true" : "false"); });
    ui.find.setAttribute("aria-activedescendant", "xp-opt-" + state.active);
    var li = ui.results.querySelector("#xp-opt-" + state.active);
    if (li && li.scrollIntoView) li.scrollIntoView({ block: "nearest" });
  }
  function choose(k, opts) {
    var r = state.results[k];
    if (!r) return;
    if (r.sc) select(r.sc, { line: r.line, from: "find" });
    else { open(r.file); flash(r.line); }
    if (!(opts && opts.keepFocus) && ui.pre) ui.pre.focus({ preventScroll: true });
  }

  function trailStrip() {
    var m = model;
    ui.trailButtons = m.trails.map(function (t) {
      var b = h("button", { type: "button", "data-trail": t.id, "aria-pressed": "false", title: t.say },
                [h("span", { class: "xp-trail-name" }, t.title), h("span", { class: "xp-trail-sub" }, t.subtitle)]);
      b.addEventListener("click", function () { chooseTrail(t.id); });
      return b;
    });
    ui.stepList = h("ol", { class: "xp-steps" });
    ui.say = h("p", { class: "xp-say" });
    ui.prev = h("button", { type: "button", class: "xp-walk" }, "← previous");
    ui.next = h("button", { type: "button", class: "xp-walk" }, "next →");
    ui.prev.addEventListener("click", function () { stepBy(-1); });
    ui.next.addEventListener("click", function () { stepBy(1); });
    // The text trails on one line, the question trails on the next: each Q/A trail sits under its twin.
    var row = [];
    ui.trailButtons.forEach(function (b, i) {
      if (i && /^qa-/.test(m.trails[i].id) && !/^qa-/.test(m.trails[i - 1].id)) row.push(h("span", { class: "xp-trails-break", "aria-hidden": "true" }));
      row.push(b);
    });
    return h("div", { class: "xp-trail" }, [h("div", { class: "xp-trails", role: "group", "aria-label": "The trails through the code" }, row),
                                           h("div", { class: "scroll" }, ui.stepList),
                                           h("div", { class: "xp-say-row" }, [ui.say, h("span", { class: "xp-walks" }, [ui.prev, ui.next])])]);
  }
  /** The walked trail's step buttons, rebuilt when the trail changes. */
  function stepButtons() {
    var t = current();
    if (ui.stepsOf === t.id) return;
    ui.stepsOf = t.id;
    ui.stepList.textContent = "";
    ui.stepList.setAttribute("aria-label", "The " + trailName(t) + " trail, step by step");
    ui.steps = t.steps.map(function (st) {
      var b = h("button", { type: "button", "data-step": st.n, "aria-pressed": "false", title: st.title }, [h("span", { class: "xp-n" }, String(st.n)), h("span", { class: "xp-t" }, st.title)]);
      b.addEventListener("click", function () { walk(st.n, 0, { from: "trail" }); });
      var li = h("li", null, b);
      ui.stepList.appendChild(li);
      return li;
    });
  }
  function renderTrail() {
    var t = current();
    stepButtons();
    ui.trailButtons.forEach(function (b) { b.setAttribute("aria-pressed", b.getAttribute("data-trail") === t.id ? "true" : "false"); });
    ui.steps.forEach(function (li, k) { li.firstChild.setAttribute("aria-pressed", state.step === k + 1 ? "true" : "false"); });
    ui.say.textContent = "";
    if (!state.step) {
      ui.say.appendChild(document.createTextNode(t.say + " Pick a step."));
    } else {
      var st = t.steps[state.step - 1];
      if (state.pos >= 0) {
        ui.say.appendChild(h("b", null, "Step " + st.n + " of " + t.steps.length));
        ui.say.appendChild(document.createTextNode(" · " + st.title + " · function " + (state.pos + 1) + " of " + st.entries.length + " · "));
        ui.say.appendChild(chapterLinks(st.chapters));
      } else {
        var back = h("button", { type: "button", class: "xp-link" }, "back to function " + (state.lastPos + 1));
        back.addEventListener("click", function () { walk(state.step, state.lastPos, { from: "trail" }); });
        ui.say.appendChild(document.createTextNode("Step " + st.n + " · off the " + trailName(t) + " trail · "));
        ui.say.appendChild(back);
        var other = placesOf(state.sc)[0];
        if (other) {
          var go = h("button", { type: "button", class: "xp-link" }, "this one is on the " + trailName(other.trail) + " trail, step " + other.step);
          go.addEventListener("click", function () { walkTo(other.trail.id, other.step, other.pos, { from: "trail" }); });
          ui.say.appendChild(document.createTextNode(" · "));
          ui.say.appendChild(go);
        }
      }
    }
    var end = t.steps[t.steps.length - 1];
    ui.prev.disabled = !state.step || (state.step === 1 && state.pos === 0);
    ui.next.disabled = state.step === t.steps.length && state.pos === end.entries.length - 1;
    ui.root.setAttribute("data-trail", t.id);
    ui.root.setAttribute("data-step", String(state.step));
  }
  function chapterLinks(files) {
    var numbered = B.chapters.filter(function (c) { return !c.start; }), out = h("span", { class: "xp-chapters" }, "In the tour: ");
    files.forEach(function (f, i) {
      var n = numbered.findIndex(function (c) { return c.file === f; });
      if (i) out.appendChild(document.createTextNode(i === files.length - 1 ? " and " : ", "));
      out.appendChild(h("a", { href: B.root() + f, title: n >= 0 ? numbered[n].short : f }, "chapter " + (n >= 0 ? n : f)));
    });
    return out;
  }
  /** Walks another trail. The selected declaration stays when it is on that trail too; otherwise the walk
   * resumes where it last stood on that trail, or at its first function. */
  function chooseTrail(id, opts) {
    var t = model.trailById[id];
    if (!t || (t === current() && state.step)) return;
    setTrail(id);
    var on = onCurrent(state.sc);
    if (on) {
      state.step = on.step; state.pos = on.pos; state.lastPos = on.pos; state.at[id] = { step: on.step, pos: on.pos };
      renderCard();
      renderTrail();
      if (!opts || opts.hash !== false) writeHash();
      return;
    }
    var at = state.at[id] || { step: 1, pos: 0 };
    walk(at.step, at.pos, Object.assign({ from: "trail" }, opts || {}));
  }
  function setTrail(id) {
    if (state.trail === id) return;
    state.trail = id;
    B.storage.set("explorer:trail", id);
  }
  function walk(n, k, opts) {
    var t = current(), st = t.steps[n - 1];
    if (!st) return;
    k = Math.max(0, Math.min(k, st.entries.length - 1));
    state.step = n;
    state.pos = k;
    state.lastPos = k;
    state.at[t.id] = { step: n, pos: k };
    select(model.scopes[st.entries[k].scope], Object.assign({ trail: true }, opts || {}));
  }
  function walkTo(id, n, k, opts) { setTrail(id); walk(n, k, opts); }
  function stepBy(d) {
    var t = current();
    if (!state.step) return walk(1, 0, { from: "trail" });
    if (state.pos < 0) return walk(state.step, state.lastPos, { from: "trail" });
    var k = state.pos + d, n = state.step;
    if (k >= t.steps[n - 1].entries.length) { if (n < t.steps.length) { n++; k = 0; } else return; }
    if (k < 0) { if (n > 1) { n--; k = t.steps[n - 1].entries.length - 1; } else return; }
    walk(n, k, { from: "trail" });
  }

  function treePanel() {
    var m = model, roots = {};
    m.files.forEach(function (file) {
      var parts = file.path.replace(/^Sources\//, "").split("/"), node = roots[parts[0]] = roots[parts[0]] || { key: parts[0], folders: {}, files: [] };
      for (var i = 1; i < parts.length - 1; i++) {
        var key = node.key + "/" + parts[i];
        node = node.folders[parts[i]] = node.folders[parts[i]] || { key: key, folders: {}, files: [] };
      }
      node.files.push(file);
    });
    var remembered = B.storage.get("explorer:open", {}) || {};
    ui.fileNodes = {};
    function count(node) { var n = node.files.length; Object.keys(node.folders).forEach(function (k) { n += count(node.folders[k]); }); return n; }
    function remember(d, key) {
      d.addEventListener("toggle", function () {
        var open = B.storage.get("explorer:open", {}) || {};
        if (d.open) open[key] = true; else delete open[key];
        B.storage.set("explorer:open", open);
      });
    }
    function folder(label, node) {
      var d = h("details", { class: "xp-node", "data-node": node.key, open: remembered[node.key] ? true : null },
                h("summary", null, [label, h("small", null, count(node) + " files")]));
      var list = h("div", { class: "xp-kids" });
      Object.keys(node.folders).sort().forEach(function (k) { list.appendChild(folder(k, node.folders[k])); });
      node.files.slice().sort(function (a, b) { return a.name < b.name ? -1 : 1; }).forEach(function (f) { list.appendChild(fileNode(f)); });
      d.appendChild(list);
      remember(d, node.key);
      return d;
    }
    function fileNode(file) {
      // One badge a trail, naming every step of it that reads this file: T1,2,3,6.
      var steps = {};
      file.scopes.forEach(function (sc) { placesOf(sc).forEach(function (o) { var s = steps[o.trail.id] = steps[o.trail.id] || []; if (s.indexOf(o.step) < 0) s.push(o.step); }); });
      var marks = m.trails.filter(function (t) { return steps[t.id]; }).map(function (t) {
        var list = steps[t.id].sort(function (a, b) { return a - b; });
        return h("span", { class: "xp-badge", "data-trail": t.id, title: "On the " + trailName(t) + " trail at step" + (list.length > 1 ? "s " : " ") + list.join(", ") }, t.mark + list.join(","));
      });
      var d = h("details", { class: "xp-file", "data-file": file.path, open: remembered[file.path] ? true : null },
                h("summary", null, [h("span", { class: "xp-fname" }, file.name), marks, h("small", null, String(file.scopes.length))]));
      d.querySelector("summary").addEventListener("click", function () { open(file, { from: "tree" }); });
      d.addEventListener("toggle", function () { if (d.open) scopeList(file); });
      if (d.open) scopeList(file);
      remember(d, file.path);
      ui.fileNodes[file.path] = d;
      return d;
    }
    var mods = m.index.modules.filter(function (k) { return roots[k]; }).map(function (k) { return folder(k, roots[k]); });
    ui.treeLabel = h("span", null, "Files");
    ui.files = h("details", { class: "xp-files", open: true }, [h("summary", null, ui.treeLabel), h("div", { class: "xp-tree-inner" }, mods)]);
    ui.tree = h("nav", { class: "xp-tree", "aria-label": "Every Swift file, by module and folder" }, ui.files);
    return ui.tree;
  }
  function fitTree() {
    var narrow = window.innerWidth <= NARROW;
    if (ui && ui.files && ui.narrow !== narrow) { ui.files.open = !narrow; ui.narrow = narrow; }
  }
  function scopeList(file) {
    var d = ui.fileNodes[file.path];
    if (!d || d.querySelector("ul")) return;
    var ul = h("ul", { class: "xp-scopes" });
    file.scopes.forEach(function (sc) {
      var b = h("button", { type: "button", "data-fn": sc.id, style: "padding-left:" + (0.5 + sc.depth * 0.8) + "rem", title: sc.label },
                [h("span", { class: "xp-kind" }, TAG[sc.kind]), h("span", { class: "xp-sname" }, sc.name + sc.labelText)].concat(badges(placesOf(sc))));
      b.addEventListener("click", function () { select(sc, { from: "tree" }); });
      ul.appendChild(h("li", null, b));
    });
    d.appendChild(ul);
  }

  /** A trail's mark, then the step: T3 is step 3 of training, QI2 step 2 of Q/A inference. */
  function badges(places) {
    return places.map(function (o) {
      return h("span", { class: "xp-badge", "data-trail": o.trail.id, title: "On the " + trailName(o.trail) + " trail at step " + o.step }, o.trail.mark + o.step);
    });
  }

  function sourcePanel() {
    ui.path = h("span", { class: "xp-path" }, "");
    ui.copyLine = h("button", { type: "button", title: "Copy File.swift:line for Xcode's Open Quickly" }, "Copy line");
    ui.copyLink = h("button", { type: "button", title: "Copy a link to this declaration" }, "Copy link");
    ui.onlyButton = h("button", { type: "button", "aria-pressed": "false", title: "Show only the selected declaration" }, "Only this scope");
    ui.copyLine.addEventListener("click", function () { copy(state.sc ? state.sc.file.name + ":" + state.sc.sig : state.file ? state.file.name + ":1" : "", "Copied " + (state.sc ? state.sc.file.name + ":" + state.sc.sig : "")); });
    ui.copyLink.addEventListener("click", function () { copy(location.href.split("#")[0] + "#" + hashFor(), "Link copied"); });
    ui.onlyButton.addEventListener("click", function () { state.only = !state.only; B.storage.set("explorer:only", state.only); applyOnly(); });
    state.only = !!B.storage.get("explorer:only", false);
    ui.pre = h("pre", { tabindex: "0", "aria-label": "Swift source" });
    ui.pre.addEventListener("click", function (e) {
      var row = e.target.closest && e.target.closest(".ln");
      if (!row || !state.file || (window.getSelection && String(window.getSelection()))) return;
      var n = +row.getAttribute("data-n"), sc = scopeAt(state.file, n);
      if (sc && sc !== state.sc) select(sc, { from: "source", scroll: false });
    });
    ui.source = h("section", { class: "xp-source code", "aria-label": "The open file" }, [
      h("div", { class: "code-head" }, [ui.path, h("span", { class: "xp-tools" }, [ui.copyLine, ui.copyLink, ui.onlyButton])]), ui.pre]);
    return ui.source;
  }
  function open(file, opts) {
    if (!file) return;
    if (state.file !== file) {
      state.file = file;
      renderSource(file);
      ui.path.textContent = file.path;
      ui.pre.setAttribute("aria-label", "Swift source " + file.name);
      ui.treeLabel.textContent = "Files · " + file.name;
      ui.root.setAttribute("data-file", file.path);
    }
    if (opts && opts.from === "tree" && state.sc && state.sc.file !== file) { state.sc = null; mark(null); renderCard(); writeHash(); }
  }
  function renderSource(file) {
    var lines = linesOf(file), frag = document.createDocumentFragment(), starts = {}, inString = false;
    file.scopes.forEach(function (sc) { if (!starts[sc.decl]) starts[sc.decl] = sc; });
    ui.rows = [];
    lines.forEach(function (line, i) {
      var n = i + 1, quotes = (line.match(/"""/g) || []).length;
      var body = inString ? h("span", { class: "tk-s" }, line) : B.highlight(line);
      var row = h("div", { class: "ln" + (starts[n] ? " sc" : ""), "data-n": n }, [h("span", null, String(n)), h("span", null, body)]);
      if (starts[n]) row.setAttribute("data-fn", starts[n].id);
      if (quotes % 2) inString = !inString;
      ui.rows.push(row);
      frag.appendChild(row);
    });
    ui.pre.replaceChildren(frag);
    ui.marked = [];
    ui.pre.scrollTop = 0;
  }
  function row(n) { return ui.rows[n - 1] || null; }
  function mark(sc) {
    (ui.marked || []).forEach(function (r) { r.classList.remove("hl", "sig", "doc"); });
    ui.marked = [];
    if (!sc) return;
    var from = sc.doc ? sc.doc[0] : sc.decl;
    for (var n = from; n <= lastLine(sc); n++) {
      var r = row(n);
      if (!r) continue;
      r.classList.add("hl");
      if (sc.doc && n <= sc.doc[1]) r.classList.add("doc");
      if (n === sc.sig) r.classList.add("sig");
      ui.marked.push(r);
    }
    applyOnly();
  }
  function applyOnly() {
    ui.onlyButton.setAttribute("aria-pressed", state.only ? "true" : "false");
    Array.prototype.forEach.call(ui.pre.querySelectorAll(".xp-gap"), function (g) { g.remove(); });
    var sc = state.sc, from = sc ? (sc.doc ? sc.doc[0] : sc.decl) : 1, to = sc ? lastLine(sc) : ui.rows.length;
    var hiding = state.only && sc, run = 0;
    ui.rows.forEach(function (r, i) {
      var n = i + 1, hide = hiding && (n < from || n > to);
      r.hidden = !!hide;
      if (hide) run++;
      if ((!hide || n === ui.rows.length) && run) {
        var gap = h("div", { class: "xp-gap", "aria-hidden": "true" }, "… " + run + (run === 1 ? " line" : " lines"));
        if (hide) r.after(gap); else r.before(gap);
        run = 0;
      }
    });
  }
  function scrollRow(r, where) {
    if (!r || r.hidden) return;
    var p = ui.pre.getBoundingClientRect(), b = r.getBoundingClientRect();
    if (b.top < p.top || b.bottom > p.bottom - 8 || where === "top") {
      ui.pre.scrollTop = ui.pre.scrollTop + b.top - p.top - Math.min(p.height / 4, 80);
    }
  }
  function flash(n) {
    var r = row(n);
    if (!r) return;
    if (r.hidden) { state.only = false; applyOnly(); }
    scrollRow(r, "top");
    r.classList.add("flash");
    setTimeout(function () { r.classList.remove("flash"); }, 1600);
  }

  function select(sc, opts) {
    opts = opts || {};
    if (!sc) return;
    open(sc.file);
    state.sc = sc;
    if (!opts.trail) {
      var on = onCurrent(sc);
      if (on) { state.step = on.step; state.pos = on.pos; state.lastPos = on.pos; state.at[state.trail] = { step: on.step, pos: on.pos }; }
      else if (state.step) { state.pos = -1; }
    }
    mark(sc);
    if (opts.scroll !== false) scrollRow(row(sc.doc ? sc.doc[0] : sc.decl), "top");
    if (opts.line && opts.line !== sc.decl) flash(opts.line);
    revealInTree(sc);
    renderCard();
    renderTrail();
    ui.root.setAttribute("data-scope", sc.id);
    ui.root.setAttribute("data-line", String(sc.sig));
    try { window.dispatchEvent(new CustomEvent("braid:context")); } catch (e) { /* an old browser: the orb reads the selection when it opens */ }
    if (opts.hash !== false) writeHash();
    B.storage.set("explorer:last", sc.file.path + ":" + sc.tail);
    if (!opts.quiet && window.innerWidth <= NARROW && (opts.from === "find" || opts.from === "trail" || opts.from === "hash")) ui.source.scrollIntoView({ block: "start" });
  }
  function revealInTree(sc) {
    var d = ui.fileNodes[sc.file.path];
    if (!d) return;
    for (var p = d; p && p !== ui.tree; p = p.parentElement) if (p.tagName === "DETAILS" && !p.open && p !== ui.files) p.open = true;
    scopeList(sc.file);
    Array.prototype.forEach.call(ui.tree.querySelectorAll("[aria-current]"), function (b) { b.removeAttribute("aria-current"); });
    var b = d.querySelector('[data-fn="' + cssEscape(sc.id) + '"]');
    if (!b) return;
    b.setAttribute("aria-current", "true");
    if (ui.narrow) return;
    var t = ui.tree.getBoundingClientRect(), r = b.getBoundingClientRect();
    if (r.top < t.top || r.bottom > t.bottom) ui.tree.scrollTop += r.top - t.top - t.height / 3;
  }
  function cssEscape(s) { return window.CSS && CSS.escape ? CSS.escape(s) : s.replace(/["\\]/g, "\\$&"); }

  function renderCard() {
    var card = ui.card, sc = state.sc;
    card.textContent = "";
    if (!sc) {
      card.appendChild(h("p", { class: "xp-empty" }, state.file ? "Pick a declaration in " + state.file.name + ", in the tree or in the source." : "Pick a file in the tree, a step on a trail, or paste a function from Xcode into the box."));
      if (state.file) card.appendChild(headerBlock(state.file));
      return;
    }
    var parent = sc.parent >= 0 ? sc.file.scopes[sc.parent] : null;
    card.appendChild(h("h3", null, sc.label));
    card.appendChild(h("p", { class: "xp-kindline" }, [kindWords(sc), " · ", sc.file.name + ":" + sc.sig, parent ? [" · in ", jump(parent, parent.qualified)] : null]));
    card.appendChild(h("pre", { class: "xp-sig" }, signature(sc).split("\n").map(function (l, i) { return [i ? "\n" : "", B.highlight(l)]; })));
    var doc = docText(sc);
    if (doc) {
      card.appendChild(h("h4", null, "Doc comment"));
      card.appendChild(h("pre", { class: "xp-doc" }, doc));
    }
    if (sc.cases && sc.cases.length) {
      card.appendChild(h("h4", null, "Cases"));
      card.appendChild(h("p", { class: "xp-cases" }, sc.cases.join(", ")));
    }
    placesOf(sc).slice().sort(function (a, b) { return (b.trail === current()) - (a.trail === current()); })
      .forEach(function (on) { card.appendChild(trailBlock(sc, on)); });
    card.appendChild(headerBlock(sc.file));
    card.appendChild(edgeBlock("Calls", model.out[sc.g], 1, "Calls nothing the matcher could name."));
    card.appendChild(edgeBlock("Called by", model.into[sc.g], 0, "Nothing calls it by name."));
    card.appendChild(h("p", { class: "note xp-honest" }, "Matched by name and argument labels when the site was built, not by a compiler. Exact: one declaration in Sources/ fits, and its type is named or implied. Likely: the name and labels are unique, and the receiver's type was not read. Ambiguous: more than one fits, and every one is listed."));
  }
  function trailBlock(sc, on) {
    var t = on.trail, st = t.steps[on.step - 1], entry = st.entries[on.pos];
    var wrap = h("div", { class: "xp-on-trail", "data-trail": t.id }, [
      h("h4", null, "On the " + trailName(t) + " trail"),
      h("p", { class: "xp-step-line" }, "Step " + st.n + " of " + t.steps.length + " · " + st.title + " · function " + (on.pos + 1) + " of " + st.entries.length),
      h("p", { class: "xp-note" }, entry.note)
    ]);
    var links = h("p", { class: "xp-links" }, chapterLinks(st.chapters)), ov = overviewStepOf(t, st.n);
    if (ov) {
      links.appendChild(document.createTextNode(" · "));
      links.appendChild(h("a", { href: B.root() + "index.html#fig-overview;step=" + ov }, "the overview at step " + ov));
    }
    if (entry.cite === "PIN" || entry.cite === "WHAT") {
      links.appendChild(document.createTextNode(" · from the file's " + entry.cite));
    }
    wrap.appendChild(links);
    var prev = h("button", { type: "button", class: "xp-walk" }, "← previous on this trail"), next = h("button", { type: "button", class: "xp-walk" }, "next on this trail →");
    prev.disabled = st.n === 1 && on.pos === 0;
    next.disabled = st.n === t.steps.length && on.pos === st.entries.length - 1;
    function from(d) { setTrail(t.id); state.step = st.n; state.pos = on.pos; stepBy(d); }
    prev.addEventListener("click", function () { from(-1); });
    next.addEventListener("click", function () { from(1); });
    wrap.appendChild(h("p", { class: "xp-walks" }, [prev, next]));
    return wrap;
  }
  function headerBlock(file) {
    var d = h("details", { class: "xp-header" }, h("summary", null, "The file's header: what it is, and what is pinned"));
    [["WHAT", file.header && file.header.what], ["PIN", file.header && file.header.pin], ["IN", file.header && file.header.in], ["OUT", file.header && file.header.out]].forEach(function (x) {
      if (!x[1]) return;
      d.appendChild(h("h4", null, x[0]));
      d.appendChild(h("pre", { class: "xp-doc" }, headerText(file, x[1])));
    });
    return d;
  }
  function jump(sc, text, line) {
    var b = h("button", { type: "button", class: "xp-link", "data-fn": sc.id, title: sc.id }, text);
    b.addEventListener("click", function () { select(sc, { from: "card", line: line }); });
    return b;
  }
  function edgeBlock(title, edges, end, empty) {
    var wrap = h("div", { class: "xp-edges" }, h("h4", null, [title, h("small", null, edges.length ? " " + edges.length : "")]));
    if (!edges.length) { wrap.appendChild(h("p", { class: "xp-empty" }, empty)); return wrap; }
    [0, 1, 2].forEach(function (tier) {
      var list = edges.filter(function (e) { return e[2] === tier; }).sort(function (a, b) { return a[end] - b[end]; });
      if (!list.length) return;
      var ul = h("ul", null);
      list.forEach(function (e, k) {
        var other = model.scopes[e[end]], caller = model.scopes[e[0]];
        var at = h("button", { type: "button", class: "xp-at", title: "The call, in " + caller.file.name }, caller.file.name + ":" + e[3]);
        at.addEventListener("click", function () {
          if (state.sc !== caller) select(caller, { from: "card", scroll: false });
          flash(e[3]);
        });
        var li = h("li", { hidden: k >= 40 ? true : null }, [jump(other, other.label), e[4] > 1 ? h("small", null, " ×" + e[4]) : null, " ", at]);
        ul.appendChild(li);
      });
      var group = h("div", { class: "xp-tier" }, [h("span", { class: "tier tier-" + TIERS[tier] }, TIERS[tier]), ul]);
      if (list.length > 40) {
        var more = h("button", { type: "button", class: "xp-link" }, "and " + (list.length - 40) + " more");
        more.addEventListener("click", function () { Array.prototype.forEach.call(ul.children, function (li) { li.hidden = false; }); more.remove(); });
        group.appendChild(more);
      }
      wrap.appendChild(group);
    });
    return wrap;
  }

  function hashFor() {
    if (state.sc && state.pos >= 0 && state.step) return "trail-" + state.trail + "-" + state.step + ";n=" + (state.pos + 1);
    if (state.sc) return state.sc.file.path + ":" + state.sc.tail;
    return state.file ? state.file.path : "";
  }
  function writeHash() {
    var target = hashFor();
    try { history.replaceState(null, "", "#" + target); } catch (e) { /* file:// may refuse; the page still works */ }
  }
  function readHash(first) {
    var raw = "";
    try { raw = decodeURIComponent((location.hash || "").slice(1)); } catch (e) { raw = (location.hash || "").slice(1); }
    var t = parseTarget(raw);
    if (!t) return false;
    if (t.query !== undefined) { ui.find.value = t.query; fitFind(); runSearch(true); return true; }
    if (t.step) { walkTo(t.trail, t.step, t.pos, { hash: false, from: "hash", quiet: first }); return true; }
    if (t.sc) { select(t.sc, { hash: false, from: "hash", line: t.line, quiet: first }); return true; }
    if (t.file) { open(t.file); ui.root.setAttribute("data-line", String(t.line || 1)); if (t.line) flash(t.line); renderCard(); return true; }
    return false;
  }

  function copy(text, done) {
    function fallback() {
      var field = h("input", { class: "copy-field", value: text, readonly: true, "aria-label": "Copy this" });
      var old = ui.source.querySelector(".copy-field");
      if (old) old.remove();
      ui.source.appendChild(field);
      field.select();
    }
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(function () { B.toast(done); }, fallback);
      else fallback();
    } catch (e) { fallback(); }
  }

  function onKey(e) {
    if (e.target === ui.find) return;
    var inSource = ui.pre.contains(e.target);
    if (e.key === "]" || e.key === "[") { stepBy(e.key === "]" ? 1 : -1); e.preventDefault(); }
    else if (inSource && (e.key === "ArrowDown" || e.key === "ArrowUp") && state.file && !e.metaKey && !e.altKey) {
      var list = state.file.scopes, at = state.sc ? list.indexOf(state.sc) : -1;
      var k = Math.max(0, Math.min(list.length - 1, at + (e.key === "ArrowDown" ? 1 : -1)));
      if (list[k] && list[k] !== state.sc) select(list[k], { from: "source" });
      e.preventDefault();
    }
  }

  // MARK: Self-check

  function selfCheck() {
    var src = sources(), out = [];
    function check(name, ok, detail) { out.push({ name: name, ok: !!ok, detail: detail || "" }); }
    if (!src || !src.index) return [{ name: "the sources are loaded", ok: false, detail: "data/sources/index.js is missing" }];
    var m = build(), idx = m.index, bad;
    check("every module's sources are loaded", !m.missing.length, m.missing.join(", "));
    bad = idx.files.filter(function (f, i) { var file = m.files[i]; return !file || file.path !== f.path || file.scopes.length !== f.scopes || file.first !== f.first; });
    check("the index and the module files agree, file by file", !bad.length && idx.files.length === m.files.length, bad.length ? bad[0].path : m.files.length + " files");
    bad = m.scopes.filter(function (sc) { return !sc || sc.decl < 1 || sc.decl > sc.sig || lastLine(sc) < sc.sig || lastLine(sc) > linesOf(sc.file).length; });
    check("every declaration's lines lie inside its file", !bad.length, bad.length ? bad[0].id : m.scopes.length + " declarations");
    var word = { f: /\bfunc\b/, i: /\binit\b/, d: /\bdeinit\b/, s: /\bsubscript\b/, v: /\bvar\b/, S: /\bstruct\b/, C: /\bclass\b/, E: /\benum\b/, A: /\bactor\b/, X: /\bextension\b/, P: /\bprotocol\b/ };
    bad = m.scopes.filter(function (sc) { return !word[sc.kind].test(linesOf(sc.file)[sc.sig - 1] || ""); });
    check("every declaration's signature line holds its keyword", !bad.length, bad.length ? bad[0].id : "");
    bad = idx.sample.filter(function (s) { return !m.scopes[s[0]] || m.scopes[s[0]].id !== s[1]; });
    check("ids derived here equal the build's", !bad.length, bad.length ? bad[0][1] + " is " + (m.scopes[bad[0][0]] || {}).id : idx.sample.length + " sampled");
    bad = idx.edges.filter(function (e) { return !m.scopes[e[0]] || !m.scopes[e[1]] || !(e[2] >= 0 && e[2] <= 2); });
    check("every call edge joins two declarations, with a tier", !bad.length, B.fmt.int(idx.edges.length) + " edges");
    var trails = m.trails, files = B.chapters.map(function (c) { return c.file; });
    check("four trails, training, inference, Q/A training and Q/A inference, each with its own mark and its steps numbered from 1",
          trails.map(function (t) { return t.id; }).join() === "training,inference,qa-training,qa-inference" &&
          trails.every(function (t, i) { return t.mark && trails.findIndex(function (u) { return u.mark === t.mark; }) === i; }) &&
          trails.every(function (t) { return t.steps.length >= 3 && t.steps.every(function (st, i) { return st.n === i + 1 && st.entries.length > 0; }); }),
          trails.map(function (t) { return t.id + " " + t.steps.length + " steps, " + t.steps.reduce(function (a, st) { return a + st.entries.length; }, 0) + " functions"; }).join(" · "));
    bad = [];
    trails.forEach(function (t) {
      var seen = {};
      t.steps.forEach(function (st) {
        st.entries.forEach(function (en) {
          if (!m.scopes[en.scope] || m.scopes[en.scope].id !== en.id) bad.push(en.id);
          if (seen[en.scope]) bad.push(t.id + " holds " + en.id + " twice");
          seen[en.scope] = true;
        });
        st.chapters.forEach(function (f) { if (files.indexOf(f) < 0) bad.push(f); });
      });
    });
    check("every trail entry resolves, once a trail, and every chapter it names exists", !bad.length, bad.join(", "));
    var overview = B.overviewSteps || [];
    bad = [];
    overview.forEach(function (o, k) {
      if (!k) return;
      var at = parseTarget("trail-" + o.code), st = at && m.trailById[at.trail].steps[at.step - 1];
      if (!st) bad.push("step " + k + " links " + o.code);
      else if (!st.chapters.some(function (f) { return o.chapters.indexOf(f) >= 0; })) bad.push("step " + k + " shares no chapter with " + o.code);
    });
    check("each of the overview's seven steps links a trail step that shares its chapters", overview.length === 8 && !bad.length,
          bad.join(", ") || (overview.length ? overview.slice(1).map(function (o) { return o.code; }).join(", ") : "the overview's script is not loaded"));
    var code = (window.BraidData || {}).code || {};
    bad = Object.keys(code).filter(function (id) {
      var c = code[id];
      if ((c.repo && c.repo !== "braid") || !/^Sources\//.test(c.path)) return false;
      var file = m.byPath[c.path];
      return !file || linesOf(file).slice(c.lines[0] - 1, c.lines[1]).join("\n") !== c.text;
    });
    check("every chapter excerpt from Sources/ reads the same here", !bad.length, bad.join(", "));
    var first = m.scopes[trails[0].steps[0].entries[0].scope], top = function (q) { var r = search(q)[0]; return r && r.sc; };
    var body = linesOf(first.file).slice(first.decl - 1, lastLine(first)).join("\n");
    check("the first trail function is found by name, by signature and by its body",
          top(first.qualified + first.labelText) === first && top(signature(first).split("\n").join(" ")) === first && top(body) === first, first.label);
    var reads = [runTool("read_declaration", { name: "Gate.observe" }), runTool("read_file", { path: "Gate.swift" }), runTool("search_text", { text: "valueAndGrad" }),
                 runTool("find_declarations", { query: "Mixer.shares" }), runTool("read_file", { path: "Sources/BraidCore/Mixture/Gate/Gate.swift", from: 60, to: 64 })];
    check("the chat's tools read a declaration, a file, a search, a lookup and a range of lines",
          /func observe/.test(reads[0].text) && /Declarations:/.test(reads[1].text) && /valueAndGrad/.test(reads[2].text) && /Mixer\.shares/.test(reads[3].text) && /^60  /m.test(reads[4].text),
          reads.map(function (r) { return r.text.length; }).join(", ") + " characters");
    check("the codebase map names every file and every trail", codeMap().split("\n").filter(function (l) { return /\.swift: /.test(l); }).length === m.files.length &&
          trails.every(function (t) { return codeMap().indexOf(t.title + ", " + t.subtitle + ":") >= 0; }),
          Math.round(codeMap().length / 1000) + " thousand characters");
    var a = parseTarget(first.file.path + ":" + first.sig), b = parseTarget(first.file.path + ":" + first.tail), c = parseTarget("trail-training-1;n=1"), d = parseTarget("trail-1");
    check("every deep-link form names the same place: a line, an id, a trail step, and an old step link through the overview",
          a && b && a.sc === first && b.sc === first && c && c.trail === "training" && c.step === 1 && c.pos === 0 && d && d.trail === c.trail && d.step === c.step);
    return out;
  }

  /** What the chat orb tells its model about the selection: the declaration, its code, its trail note and its calls. */
  /** One declaration as the chat reads it: where it sits, its trail note, its file's header, its code with Xcode's line numbers, its calls. */
  function describe(sc, lead, cap) {
    var m = build(), file = sc.file, lines = linesOf(file);
    var from = sc.doc ? sc.doc[0] : sc.decl, to = lastLine(sc), last = Math.min(to, from + cap - 1), parts = [];
    var parent = sc.parent >= 0 ? file.scopes[sc.parent] : null;
    parts.push(lead + sc.label + ": " + kindWords(sc) + " in " + file.path + ", line " + sc.sig + (parent ? ", inside " + parent.qualified : "") + ".");
    (m.onTrail[sc.g] || []).forEach(function (on) {
      var t = on.trail, st = t.steps[on.step - 1], en = st.entries[on.pos];
      parts.push("It is on the " + trailName(t) + " trail, " + t.subtitle + ": step " + st.n + " of " + t.steps.length + ", \"" + st.title + "\", function " + (on.pos + 1) +
                 " of " + st.entries.length + ". The trail's note on it: " + en.note + (en.cite ? " Source of the note: " + en.cite + "." : ""));
    });
    var what = headerText(file, file.header && file.header.what), pin = headerText(file, file.header && file.header.pin);
    if (what) parts.push("The file's header, WHAT: " + what.replace(/\s+/g, " ").trim());
    if (pin) parts.push("The file's header, PIN: " + pin.replace(/\s+/g, " ").trim());
    var code = [];
    for (var n = from; n <= last; n++) code.push(n + "  " + lines[n - 1]);
    parts.push("Its code, " + file.name + " lines " + from + " to " + last + (last < to ? " of " + to + ", cut there" : "") + ", each line numbered as in Xcode:\n```swift\n" + code.join("\n") + "\n```");
    function names(edges, end) {
      return edges.slice(0, 30).map(function (e) { return m.scopes[e[end]].label + " (" + TIERS[e[2]] + ", the call at " + m.scopes[e[0]].file.name + ":" + e[3] + ")"; }).join("; ") +
             (edges.length > 30 ? "; and " + (edges.length - 30) + " more" : "");
    }
    parts.push("What it calls, matched by name and argument labels when the site was built, not by a compiler: " + (m.out[sc.g].length ? names(m.out[sc.g], 1) : "nothing the matcher could name") + ".");
    parts.push("What calls it, matched the same way: " + (m.into[sc.g].length ? names(m.into[sc.g], 0) : "nothing by name") + ".");
    return parts.join("\n\n");
  }

  /** What the chat orb tells its model about the selection. */
  function context() {
    if (!ui || !state.sc) return null;
    var on = onCurrent(state.sc) || placesOf(state.sc)[0];
    return { kind: "code", label: state.sc.label + (on ? " · " + trailName(on.trail) + " step " + on.step : ""), text: describe(state.sc, "The reader is on the code explorer, looking at ", 220) };
  }

  /** The codebase at a glance, for the chat: every file with the first sentence of its WHAT, folder by folder, then both trails. */
  var mapText = null;
  function codeMap() {
    if (mapText) return mapText;
    var m = build(), out = [], folder = null;
    out.push(m.files.length + " Swift files in " + m.index.modules.length + " modules (" + m.index.modules.join(", ") + "), by folder, each with the first sentence of its header:");
    m.files.forEach(function (f) {
      var dir = f.path.replace(/^Sources\//, "").split("/").slice(0, -1).join("/");
      if (dir !== folder) { out.push(dir + "/"); folder = dir; }
      var what = (headerText(f, f.header && f.header.what) || "").replace(/\s+/g, " ").trim(), cut = what.search(/\.\s/);
      var first = cut > 0 ? what.slice(0, cut + 1) : what;
      out.push("  " + f.name + ": " + (first.length > 120 ? first.slice(0, 117) + "…" : first));
    });
    out.push("", "The trails through the code, each in the order it runs:");
    m.trails.forEach(function (t) {
      out.push(t.title + ", " + t.subtitle + ":");
      t.steps.forEach(function (st) { out.push("  " + st.n + ". " + st.title + ": " + st.entries.map(function (en) { return m.scopes[en.scope].qualified; }).join(", ")); });
    });
    mapText = out.join("\n");
    return mapText;
  }

  // MARK: The chat's tools: the whole codebase, read on demand, from the data this page already holds

  var TOOL_SPECS = [
    { type: "function", "function": { name: "find_declarations", description: "Find declarations in Sources/ by name, Type.method, or part of a name. Returns up to 20, each with its file, line and id.",
      parameters: { type: "object", properties: { query: { type: "string", description: "A name such as observe, Gate.observe or Gate.observe(_:likelihoods:module:settings:)" } }, required: ["query"] } } },
    { type: "function", "function": { name: "read_declaration", description: "Read one declaration whole: its code with line numbers, its doc comment, its file's header, its trail note, and what it calls and what calls it.",
      parameters: { type: "object", properties: { name: { type: "string", description: "Its qualified name, with argument labels when several share it, or an id from find_declarations" } }, required: ["name"] } } },
    { type: "function", "function": { name: "search_text", description: "Search every Swift file under Sources/ for a piece of text, ignoring case. Returns up to 40 matching lines with their file and line.",
      parameters: { type: "object", properties: { text: { type: "string", description: "The text to look for, such as valueAndGrad or openFloor" } }, required: ["text"] } } },
    { type: "function", "function": { name: "read_file", description: "Read a Swift file under Sources/. Without lines, returns its header and the outline of its declarations; with from and to, returns those lines, numbered, at most 300.",
      parameters: { type: "object", properties: { path: { type: "string", description: "Its path, such as Sources/BraidCore/Mixture/Gate/Gate.swift, or its file name when unique" },
                                                   from: { type: "integer" }, to: { type: "integer" } }, required: ["path"] } } }
  ];
  function resolveDeclaration(q) {
    var m = build();
    q = String(q || "").trim().replace(/^`+|`+$/g, "");
    if (!q) return [];
    var byId = m.scopes.filter(function (sc) { return sc.id === q || sc.file.path + ":" + sc.tail === q; });
    if (byId.length) return byId;
    if (/^Sources\/.+\.swift:/.test(q)) { var t = parseTarget(q); if (t && t.sc) return [t.sc]; }
    var hits = findSymbol(q);
    if (!hits.length && /\(/.test(q)) hits = findSymbol(q.replace(/\(.*$/, ""));
    return hits;
  }
  function fileNamed(p) {
    var m = build();
    p = String(p || "").trim().replace(/^\/+/, "");
    var file = m.byPath[p] || m.byPath["Sources/" + p];
    if (file) return [file];
    return m.files.filter(function (f) { return f.name === p || f.path.slice(-p.length - 1) === "/" + p; });
  }
  var TOOLS = {
    find_declarations: function (a) {
      var q = String(a.query || "").trim(), m = build();
      if (!q) return { text: "Give a name to find." };
      var found = search(q).filter(function (r) { return r.sc; }).slice(0, 20);
      if (!found.length) return { text: "Nothing in Sources/ is named like \"" + q + "\". Try search_text for words inside the code.", read: { label: "looked for " + q } };
      return { read: { label: "looked for " + q }, text: found.map(function (r) {
        var sc = r.sc, places = m.onTrail[sc.g] || [];
        return sc.label + ": " + KIND[sc.kind] + ", " + sc.file.path + ":" + sc.sig + places.map(function (o) { return ", " + trailName(o.trail) + " trail step " + o.step; }).join("") + ". id " + sc.id;
      }).join("\n") };
    },
    read_declaration: function (a) {
      var hits = resolveDeclaration(a.name);
      if (!hits.length) return { text: "No declaration matches \"" + a.name + "\". Use find_declarations first." };
      if (hits.length > 1) return { text: "Several declarations match; read one by its id:\n" + hits.slice(0, 12).map(function (sc) { return sc.id + " (" + KIND[sc.kind] + ", " + sc.file.path + ":" + sc.sig + ")"; }).join("\n") };
      var sc = hits[0];
      return { read: { label: sc.qualified + sc.labelText, href: "#" + sc.file.path + ":" + sc.tail }, text: describe(sc, "", 260) };
    },
    search_text: function (a) {
      var needle = String(a.text || "").trim(), low = needle.toLowerCase(), out = [], total = 0;
      if (low.length < 2) return { text: "Give at least two characters to search for." };
      build().files.forEach(function (f) {
        linesOf(f).forEach(function (l, i) {
          if (l.toLowerCase().indexOf(low) < 0) return;
          total++;
          if (out.length < 40) out.push(f.path + ":" + (i + 1) + ": " + l.trim().slice(0, 160));
        });
      });
      return { read: { label: "searched \"" + needle + "\"" },
               text: total ? out.join("\n") + (total > 40 ? "\nand " + (total - 40) + " more lines" : "") : "No line under Sources/ contains \"" + needle + "\"." };
    },
    read_file: function (a) {
      var files = fileNamed(a.path);
      if (files.length > 1) return { text: "Several files match: " + files.map(function (f) { return f.path; }).join(", ") };
      if (!files.length) return { text: "No file " + a.path + " under Sources/." };
      var file = files[0], lines = linesOf(file);
      if (!a.from && !a.to) {
        var head = [headerText(file, file.header && file.header.what), headerText(file, file.header && file.header.pin)].filter(Boolean).map(function (x) { return x.replace(/\s+/g, " ").trim(); });
        var outline = file.scopes.slice(0, 160).map(function (sc) { return "  line " + sc.sig + ": " + new Array(sc.depth + 1).join("  ") + KIND[sc.kind] + " " + sc.name + sc.labelText; });
        return { read: { label: file.name, href: "#" + file.path }, text: file.path + ", " + lines.length + " lines.\nHeader: " + head.join(" PIN: ") + "\nDeclarations:\n" + outline.join("\n") };
      }
      var from = Math.max(1, Math.floor(+a.from || 1)), to = Math.min(lines.length, Math.floor(+a.to || from + 119));
      if (to < from) to = Math.min(lines.length, from + 119);
      if (to - from > 299) to = from + 299;
      var body = [];
      for (var n = from; n <= to; n++) body.push(n + "  " + lines[n - 1]);
      return { read: { label: file.name + " " + from + "–" + to, href: "#" + file.path + ":" + from }, text: file.path + " lines " + from + " to " + to + " of " + lines.length + ":\n```swift\n" + body.join("\n") + "\n```" };
    }
  };
  /** Runs one tool call from the chat: its name and its JSON arguments in, { text, read } out, the text capped. */
  function runTool(name, args) {
    if (!build()) return { text: "The sources are not loaded on this page." };
    try { args = typeof args === "string" ? JSON.parse(args || "{}") : (args || {}); } catch (e) { return { text: "The arguments were not JSON: " + String(args).slice(0, 100) }; }
    var fn = TOOLS[name];
    if (!fn) return { text: "There is no tool named " + name + "." };
    var out = fn(args);
    if (out.text.length > 14000) out.text = out.text.slice(0, 14000) + "\n[cut here]";
    return out;
  }

  B.explorer = {
    mount: mount, selfCheck: selfCheck, search: search, parseTarget: parseTarget, model: build, context: context,
    map: codeMap, tools: TOOL_SPECS, tool: runTool,
    trailFile: function (id, n) { var m = build(), t = m && m.trailById[id], st = t && t.steps[n - 1]; return st ? m.scopes[st.entries[0].scope].file.path : null; }
  };
  if (sources()) B.extraChecks.push({ name: "explorer", run: selfCheck });
})();
