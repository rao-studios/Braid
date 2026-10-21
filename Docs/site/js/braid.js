/*
 * Braid, step by step: the runtime every page loads after js/model.js.
 *
 * window.Braid: the chapters and navigation, data access (sessions and Threads, parsed once),
 * figures (Braid.define registers one, Braid.mount draws every <figure data-fig> on the page),
 * deep links (#fig-<id>;key=value), code excerpts, board panels, a small chart kit, the
 * self-check every figure can add to, and the SVG export the exporter calls.
 *
 * Classic script, no modules and no fetch: the site is read from file://.
 */
(function () {
  "use strict";
  var Braid = (window.Braid = window.Braid || {});
  var M = Braid.model;
  var f32 = Math.fround;
  var SVGNS = "http://www.w3.org/2000/svg";

  Braid.chapters = [
    { file: "index.html", slug: "overview", short: "The braid at a glance", start: true },
    { file: "00-entropy.html", slug: "entropy", short: "What is entropy, and why does a citation need it?", step: 6 },
    { file: "01-aii.html", slug: "aii", short: "What is AII, and how does an app join it?", step: 1 },
    { file: "02-records.html", slug: "records", short: "What goes into a record?", step: 2 },
    { file: "03-corpus.html", slug: "corpus", short: "Why does a Thread need the whole corpus?", step: 4 },
    { file: "04-commons.html", slug: "commons", short: "Why does Braid need a commons?", step: 3 },
    { file: "05-training.html", slug: "training", short: "Why train, and what does the model read?", step: 4 },
    { file: "06-provenance.html", slug: "provenance", short: "Where does provenance come from?", step: 4 },
    { file: "07-inference.html", slug: "inference", short: "What happens at each token?", step: 6 },
    { file: "08-trace.html", slug: "trace", short: "What is the trace, and what steers?", step: 6 },
    { file: "09-ssd.html", slug: "ssd", short: "Why a state, and not attention?", step: 5 },
    { file: "10-verify.html", slug: "verify", short: "What does the log prove?", step: 7 }
  ];
  Braid.appendices = [
    { file: "lexicon.html", slug: "lexicon", short: "The lexicon" },
    { file: "aii-storage.html", slug: "aii-storage", short: "Inside AII's storage" },
    { file: "boards.html", slug: "boards", short: "The architecture boards" },
    { file: "code.html", slug: "code", short: "The code explorer" },
    { file: "selftest.html", slug: "selftest", short: "The self-test" }
  ];

  // MARK: Small helpers

  function h(tag, attrs, children) {
    var node = document.createElement(tag);
    setAttrs(node, attrs);
    append(node, children);
    return node;
  }
  function s(tag, attrs, children) {
    var node = document.createElementNS(SVGNS, tag);
    setAttrs(node, attrs);
    append(node, children);
    return node;
  }
  function setAttrs(node, attrs) {
    if (!attrs) return;
    Object.keys(attrs).forEach(function (k) {
      var v = attrs[k];
      if (v === null || v === undefined || v === false) return;
      if (k === "text") node.textContent = v;
      else if (k === "html") node.innerHTML = v;
      else if (k.slice(0, 2) === "on" && typeof v === "function") node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v === true ? "" : String(v));
    });
  }
  function append(node, children) {
    if (children === null || children === undefined) return;
    if (!Array.isArray(children)) children = [children];
    children.forEach(function (c) {
      if (c === null || c === undefined || c === false) return;
      if (Array.isArray(c)) { append(node, c); return; }
      node.appendChild(typeof c === "string" || typeof c === "number" ? document.createTextNode(String(c)) : c);
    });
  }
  Braid.h = h;
  Braid.s = s;

  Braid.storage = {
    get: function (key, fallback) { try { var v = window.localStorage.getItem("braid:" + key); return v === null ? fallback : JSON.parse(v); } catch (e) { return fallback; } },
    set: function (key, value) { try { window.localStorage.setItem("braid:" + key, JSON.stringify(value)); } catch (e) { /* storage may be unavailable */ } }
  };

  var fmt = (Braid.fmt = {
    /** A probability or share: four decimals; below 0.0001, one significant figure in exponent form. */
    p: function (x) {
      if (x === null || x === undefined || isNaN(x)) return "–";
      if (x === 0) return "0";
      var a = Math.abs(x);
      if (a < 5e-5) return x.toExponential(1).replace("e-", "e−");
      return x.toFixed(4);
    },
    n: function (x, d) { if (x === null || x === undefined || isNaN(x)) return "–"; return Number(x).toFixed(d === undefined ? 2 : d).replace(/^-/, "−"); },
    e: function (x) { return x === 0 ? "0" : x.toExponential(1).replace("e-", "e−"); },
    int: function (x) { return Number(x).toLocaleString("en-US"); },
    /** A token as the studio quotes it, with a newline made visible. */
    tok: function (text) { return "“" + String(text).replace(/\n/g, "↵") + "”"; },
    raw: function (text) { return String(text).replace(/\n/g, "↵"); },
    full: function (x) { return x === null || x === undefined ? "" : String(x); }
  });

  Braid.root = function () { return (document.body && document.body.getAttribute("data-root")) || ""; };
  Braid.reducedMotion = function () { try { return window.matchMedia("(prefers-reduced-motion: reduce)").matches; } catch (e) { return false; } };

  // MARK: Data

  var sessionCache = {}, threadCache = {};
  function data() { return window.BraidData || {}; }

  Braid.thread = function (name) {
    if (threadCache[name]) return threadCache[name];
    var t = (data().threads || {})[name];
    if (!t) throw new Error("missing data/threads/" + name + ".js");
    var layout = null;
    var out = Object.assign({}, t, {
      layoutIndex: function () { if (!layout) layout = M.layout(t); return layout; },
      text: function (row, offset) {
        var p = t.partitions[row];
        if (!p) return "?";
        if (offset >= p.tokens.length) return "¶";
        return p.text.slice(p.offsets[offset], p.offsets[offset + 1]);
      },
      span: function (row, from, to) { var p = t.partitions[row]; return p.text.slice(p.offsets[Math.max(0, from)], p.offsets[Math.min(p.tokens.length, to)]); },
      document: function (row) { return t.documents[t.partitions[row].doc]; }
    });
    threadCache[name] = out;
    return out;
  };

  Braid.sessionKeys = function () {
    var manifest = data().manifest;
    var keys = manifest ? manifest.sessions.map(function (x) { return x.slug; }) : Object.keys(data().sessions || {});
    return keys.filter(function (k) { return (data().sessions || {})[k]; });
  };

  /** A session by slug or by its 8-hex id, parsed once, with every view derived on demand. */
  Braid.session = function (key) {
    var all = data().sessions || {};
    var slug = all[key] ? key : Object.keys(all).find(function (k) { return all[k].id === key; });
    if (!slug) throw new Error("missing data/sessions/" + key + ".js");
    if (sessionCache[slug]) return sessionCache[slug];
    var raw = all[slug];
    var parsed = M.parseSession(raw.lines);
    var g = parsed.generations[0];
    var header = parsed.header;
    var strands = M.strandsOf(header, g);
    var commons = strands.findIndex(function (x) { return x.commons; });
    if (commons < 0) commons = null;
    var slots = M.slotsOf(header, g);
    var sharedIndex = [];
    g.steps.forEach(function (st, i) { if (st.src !== "ctx") sharedIndex.push(i); });
    var shared = sharedIndex.map(function (i) { return g.steps[i]; });
    var sharedSlots = sharedIndex.map(function (i) { return slots[i]; });
    var threads = {};
    header.threads.forEach(function (x) { if (!x.commons && (data().threads || {})[x.name]) threads[x.name] = Braid.thread(x.name); });
    var palette = ["s-blue", "s-green", "s-orange"], k = 0, classes = {};
    strands.forEach(function (x) { classes[x.name] = x.commons ? "s-gold" : palette[(k++) % palette.length]; });
    var memo = {};
    function once(name, fn) { return function () { if (!(name in memo)) memo[name] = fn(); return memo[name]; }; }
    var firstGen = g.steps.findIndex(function (st) { return st.src === "gen"; });
    var session = {
      slug: slug, id: raw.id, label: raw.label, file: raw.file, sha256: raw.sha256, lines: raw.lines,
      header: header, generation: g, gen: g.gen, steps: g.steps, end: g.end, strands: strands, commons: commons, slots: slots,
      shared: shared, sharedSlots: sharedSlots, threads: threads, firstGen: firstGen < 0 ? g.steps.length : firstGen,
      strandClass: function (t) { var st = strands[t]; return st ? classes[st.name] : ""; },
      classOf: function (name) { return classes[name] || ""; },
      table: once("table", function () { var td = {}; Object.keys(threads).forEach(function (n) { td[n] = threads[n]; }); return M.partitionTable(header, td); }),
      layouts: once("layouts", function () { var out = {}; Object.keys(threads).forEach(function (n) { out[n] = threads[n].layoutIndex(); }); return out; }),
      replay: once("replay", function () { return M.replay(header, g); }),
      traces: once("traces", function () { return M.replayTrace(header, g, session.layouts()); }),
      annotate: once("annotate", function () { return M.annotate(shared, sharedSlots, session.table()); }),
      credits: once("credits", function () { var c = M.credit(shared, sharedSlots); var d = M.followedCredit(c, shared, sharedSlots, session.table()); return { rows: c, decisions: d }; }),
      royalties: once("royalties", function () { return M.royalties(shared, session.credits().rows, sharedSlots, session.table()); }),
      module: once("module", function () { return M.moduleSeries(g.steps, commons).map(function (ser) { return { series: ser, readings: M.moduleReadAll(ser, header.module) }; }); }),
      bodyOK: once("body", function () { return M.bodySHA256(g.body) === g.end.bodySHA256; }),
      /** The text a hit of strand t points at. */
      hitText: function (t, hit) { var st = strands[t]; var th = st && threads[st.name]; return th ? th.text(hit[3], hit[4]) : "?"; },
      /** Index into `shared` for a step index. */
      sharedAt: function (i) { return sharedIndex.indexOf(i); }
    };
    sessionCache[slug] = session;
    return session;
  };

  // MARK: Figures

  var defined = (Braid.figures = {});
  var mounted = (Braid.mounted = {});
  Braid.define = function (name, spec) { defined[name] = spec; };

  function parseValue(spec, key, value) {
    var p = (spec.params || {})[key];
    if (!p) return value;
    if (p.type === "int") { var n = parseInt(value, 10); return isNaN(n) ? p.default : n; }
    if (p.type === "number") { var x = parseFloat(value); return isNaN(x) ? p.default : x; }
    if (p.type === "list") return String(value).split(",").filter(Boolean);
    return value;
  }

  function hashTarget() {
    var raw = decodeURIComponent((location.hash || "").slice(1));
    if (!raw) return null;
    var parts = raw.split(";");
    var params = {};
    parts.slice(1).forEach(function (kv) { var i = kv.indexOf("="); if (i > 0) params[kv.slice(0, i)] = kv.slice(i + 1); });
    return { id: parts[0], params: params };
  }

  function searchParams() {
    var out = {};
    (location.search || "").replace(/^\?/, "").split("&").forEach(function (kv) {
      if (!kv) return;
      var i = kv.indexOf("=");
      out[decodeURIComponent(i < 0 ? kv : kv.slice(0, i))] = decodeURIComponent(i < 0 ? "" : kv.slice(i + 1));
    });
    return out;
  }
  Braid.searchParams = searchParams;

  /**
   * Makes `top` hold `fresh`'s drawing while `kept` never leaves the page. Only the elements on the
   * path from `top` down to `kept` are reused, with the new drawing's attributes; every other node
   * is the new drawing's own. Moving `kept` instead would blur it and end a drag. Returns false,
   * changing nothing, when the two paths differ in shape.
   */
  function graft(top, fresh, kept, twin) {
    var oldPath = [], newPath = [], a;
    for (a = kept; a && a !== top; a = a.parentNode) oldPath.unshift(a);
    for (a = twin; a && a !== fresh; a = a.parentNode) newPath.unshift(a);
    if (!oldPath.length || oldPath.length !== newPath.length) return false;
    for (var i = 0; i < oldPath.length; i++) if (oldPath[i].nodeName !== newPath[i].nodeName) return false;
    for (i = 0; i < oldPath.length; i++) {
      var oldParent = i ? oldPath[i - 1] : top, newParent = i ? newPath[i - 1] : fresh;
      if (i) {
        Array.prototype.slice.call(oldParent.attributes).forEach(function (at) { if (!newParent.hasAttribute(at.name)) oldParent.removeAttribute(at.name); });
        Array.prototype.slice.call(newParent.attributes).forEach(function (at) { oldParent.setAttribute(at.name, at.value); });
      }
      var stay = oldPath[i], skip = newPath[i], before = true;
      Array.prototype.slice.call(oldParent.childNodes).forEach(function (c) { if (c !== stay) oldParent.removeChild(c); });
      Array.prototype.slice.call(newParent.childNodes).forEach(function (c) {
        if (c === skip) { before = false; return; }
        if (before) oldParent.insertBefore(c, stay); else oldParent.appendChild(c);
      });
    }
    return true;
  }
  function mountFigure(fig, embed) {
    var name = fig.getAttribute("data-fig");
    var spec = defined[name];
    var id = fig.id ? fig.id.replace(/^fig-/, "") : name;
    if (!fig.id) fig.id = "fig-" + id;
    var caption = fig.querySelector(":scope > figcaption");
    if (caption && spec && spec.caption && !(caption.firstChild && caption.firstChild.nodeType === 3 && caption.firstChild.textContent.trim())) {
      caption.insertBefore(document.createTextNode(spec.caption + " "), caption.firstChild);
    }
    var body = h("div", { class: "fig-body" });
    var titleText = fig.getAttribute("data-title") || (spec && spec.title) || name;
    var linkButton = h("button", { type: "button", title: "Copy a link to this figure", "aria-label": "Copy a link to this figure" }, "link");
    var openLink = h("a", { href: Braid.root() + "figures/" + id + ".html", title: "Open this figure on its own page" }, "open");
    var head = h("div", { class: "fig-head" }, [h("span", { class: "fig-title" }, titleText), h("span", { class: "fig-tools" }, embed ? [linkButton] : [linkButton, openLink])]);
    fig.insertBefore(head, caption || null);
    fig.insertBefore(body, caption || null);
    if (!spec) { body.appendChild(h("p", { class: "fig-error" }, "Unknown figure: " + name)); fig.setAttribute("data-rendered", "error"); return; }
    var state = {};
    Object.keys(spec.params || {}).forEach(function (k) { state[k] = spec.params[k].default; });
    Object.keys(spec.params || {}).forEach(function (k) { var v = fig.getAttribute("data-" + k); if (v !== null) state[k] = parseValue(spec, k, v); });
    if (embed) { var sp = searchParams(); Object.keys(spec.params || {}).forEach(function (k) { if (sp[k] !== undefined) state[k] = parseValue(spec, k, sp[k]); }); }
    var target = hashTarget();
    if (target && (target.id === fig.id || (embed && target.id === "fig-" + id))) Object.keys(target.params).forEach(function (k) { state[k] = parseValue(spec, k, target.params[k]); });
    var record = { fig: fig, spec: spec, id: id, body: body, state: state, checks: null };
    var ctx = {
      id: id, fig: fig, embed: !!embed, exporting: document.body.classList.contains("export"), reducedMotion: Braid.reducedMotion(),
      get: function () { return record.state; },
      /** Updates the state now and redraws once, on the next frame, however many updates arrive before it. */
      set: function (partial) {
        record.state = Object.assign({}, record.state, partial);
        if (pending) return;
        pending = true;
        (window.requestAnimationFrame || function (f) { return setTimeout(f, 16); })(function () { pending = false; draw(); });
      },
      /** The figure's drawn width now (render works in a detached container, which has none). */
      width: function () { return body.clientWidth || fig.clientWidth || 640; },
      model: M, fmt: fmt, h: h, s: s
    };
    record.ctx = ctx;
    var pending = false;
    /**
     * Draws into a detached container, then swaps it in. A control the reader is using right now
     * (a slider under a pressed pointer, a text box being typed into) stays in the page: the new
     * drawing is grafted around it, so a drag keeps following the cursor and a caret stays put.
     */
    function draw() {
      var active = document.activeElement;
      var focusKey = active && body.contains(active) ? active.getAttribute("data-key") : null;
      var kept = null;
      body.querySelectorAll("[data-keep]").forEach(function (el) {
        if (kept) return;
        var pressed = el.getAttribute("data-active") === "1" || el.querySelector('[data-active="1"]');
        var typing = el.contains(active) && (el.matches("textarea, input[type=text]") || el.querySelector("textarea, input[type=text]"));
        if (pressed || typing) kept = el;
      });
      var fresh = document.createElement("div");
      try {
        spec.render(fresh, record.state, ctx);
        var twin = kept ? fresh.querySelector('[data-keep="' + kept.getAttribute("data-keep") + '"]') : null;
        if (!twin || !graft(body, fresh, kept, twin)) {
          body.textContent = "";
          while (fresh.firstChild) body.appendChild(fresh.firstChild);
        }
        fig.setAttribute("data-rendered", "ok");
      } catch (e) {
        body.textContent = "";
        body.appendChild(h("p", { class: "fig-error" }, "This figure could not draw: " + (e && e.message)));
        fig.setAttribute("data-rendered", "error");
        if (window.console) console.error(e);
      }
      if (!focusKey || body.contains(document.activeElement) && document.activeElement !== document.body) return;
      var again = /^tk-/.test(focusKey) ? body.querySelector(".strip .tk.cur") : body.querySelector('[data-key="' + focusKey + '"]');
      if (again) again.focus();
    }
    linkButton.addEventListener("click", function () { copyLink(record); });
    mounted[id] = record;
    draw();
    if (spec.selfCheck && !embed) {
      var details = h("details", { class: "fig-check" }, h("summary", null, "What this figure checks"));
      details.addEventListener("toggle", function () {
        if (!details.open || details.querySelector("ul")) return;
        var results = runChecks(record);
        details.appendChild(h("ul", null, results.map(function (r) {
          return h("li", null, [h("span", { class: r.ok ? "ok" : "bad" }, r.ok ? "✓ " : "✗ "), r.name, r.detail ? " · " + r.detail : ""]);
        })));
      });
      fig.appendChild(details);
    }
  }

  function runChecks(record) {
    if (record.checks) return record.checks;
    try { record.checks = record.spec.selfCheck(record.state, record.ctx) || []; }
    catch (e) { record.checks = [{ name: record.id, ok: false, detail: "the check threw: " + e.message }]; }
    return record.checks;
  }

  function linkFor(record) {
    var spec = record.spec, parts = [record.fig.id];
    Object.keys(spec.params || {}).forEach(function (k) {
      if (spec.params[k].link === false) return;
      var v = record.state[k];
      if (v === undefined || v === null) return;
      parts.push(k + "=" + (Array.isArray(v) ? v.join(",") : v));
    });
    var base = location.href.split("#")[0];
    return base + "#" + parts.join(";");
  }
  Braid.linkFor = function (id) { return mounted[id] ? linkFor(mounted[id]) : null; };

  function copyLink(record) {
    var url = linkFor(record);
    try { history.replaceState(null, "", "#" + url.split("#")[1]); } catch (e) { location.hash = url.split("#")[1]; }
    function done() { toast("Link copied"); }
    function fallback() {
      var field = h("input", { class: "copy-field", value: url, readonly: true, "aria-label": "Link to this figure" });
      var old = record.fig.querySelector(".copy-field");
      if (old) old.remove();
      record.body.appendChild(field);
      field.select();
    }
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(url).then(done, fallback);
      else fallback();
    } catch (e) { fallback(); }
  }
  function toast(text) {
    var t = h("div", { class: "copied", role: "status" }, text);
    document.body.appendChild(t);
    setTimeout(function () { t.remove(); }, 1400);
  }
  Braid.toast = toast;

  function applyHash(first) {
    var target = hashTarget();
    if (!target) return;
    var node = document.getElementById(target.id);
    if (!node) return;
    var parent = node.closest("details");
    while (parent) { parent.open = true; parent = parent.parentElement ? parent.parentElement.closest("details") : null; }
    if (node.tagName === "DETAILS") node.open = true;
    var record = mounted[target.id.replace(/^fig-/, "")];
    if (record && !first && Object.keys(target.params).length) {
      var next = Object.assign({}, record.state);
      Object.keys(target.params).forEach(function (k) { next[k] = parseValue(record.spec, k, target.params[k]); });
      record.ctx.set(next);
    }
    setTimeout(function () { node.scrollIntoView({ block: "start", behavior: first || Braid.reducedMotion() ? "auto" : "smooth" }); }, first ? 30 : 0);
  }

  // MARK: Code excerpts

  var KEYWORDS = /^(func|let|var|if|else|guard|return|for|in|while|struct|enum|class|public|private|fileprivate|internal|static|mutating|case|switch|default|nil|true|false|self|Self|init|extension|protocol|import|throws|throw|try|where|some|any|inout|defer|break|continue|repeat|do|catch|lazy|weak|final|override|async|await|typealias|associatedtype|@discardableResult|let)$/;
  function highlight(line) {
    var out = [], re = /(\/\/.*$)|("(?:[^"\\]|\\.)*")|(\b\d[\d_]*(?:\.\d+)?(?:e-?\d+)?\b|\b0x[0-9A-Fa-f_]+\b)|(@?[A-Za-z_][A-Za-z0-9_]*)|(\s+)|([^\sA-Za-z0-9_"@\/]+|\/)/g, m;
    while ((m = re.exec(line))) {
      if (m[1]) out.push(h("span", { class: "tk-c" }, m[1]));
      else if (m[2]) out.push(h("span", { class: "tk-s" }, m[2]));
      else if (m[3]) out.push(h("span", { class: "tk-n" }, m[3]));
      else if (m[4]) out.push(KEYWORDS.test(m[4]) ? h("span", { class: "tk-k" }, m[4]) : /^[A-Z]/.test(m[4]) ? h("span", { class: "tk-t" }, m[4]) : document.createTextNode(m[4]));
      else out.push(document.createTextNode(m[0]));
      if (m[0] === "") re.lastIndex++;
    }
    return out;
  }
  Braid.highlight = highlight;
  function renderCode(node) {
    var id = node.getAttribute("data-code");
    var c = (data().code || {})[id];
    if (!c) { node.appendChild(h("p", { class: "fig-error" }, "Missing excerpt " + id)); return; }
    var lines = c.text.split("\n"), first = c.lines[0], marks = new Set();
    (c.highlight || []).forEach(function (r) { if (Array.isArray(r)) { for (var i = r[0]; i <= r[1]; i++) marks.add(i); } else marks.add(r); });
    var where = (c.repo === "aii" ? "AII/" : "") + c.path + ":" + c.lines[0] + "–" + c.lines[1];
    var right = [c.commit ? "@" + c.commit : ""];
    // Braid's own sources are all in the code explorer: link the excerpt to the same lines there.
    if ((!c.repo || c.repo === "braid") && /^Sources\//.test(c.path)) right.push(" · ", h("a", { href: Braid.root() + "code.html#" + c.path + ":" + c.lines[0], title: "Open this file in the code explorer" }, "explore"));
    node.appendChild(h("div", { class: "code-head" }, [h("span", null, where), h("span", null, right)]));
    var pre = h("pre", { tabindex: "0", "aria-label": "Swift source " + where });
    lines.forEach(function (line, i) {
      var n = first + i;
      pre.appendChild(h("div", { class: "ln" + (marks.has(n) ? " hl" : "") }, [h("span", null, String(n)), h("span", null, highlight(line))]));
    });
    node.appendChild(pre);
    var doIt = node.getAttribute("data-do");
    if (doIt) node.appendChild(h("div", { class: "do", html: doIt }));
  }

  // MARK: Board panels

  /**
   * <figure class="board" data-board="<id>"> becomes the figure "board:<id>" that js/boards/*.js defined,
   * drawn by mountFigure like any other, with a caption that links to its place on the boards page (or,
   * on that page, to its chapter, at the panel's own id or at `anchor`, the id of the chapter figure a reused
   * panel repeats). A panel no loaded board file defines is an error on the page.
   */
  function renderBoard(node) {
    var id = node.getAttribute("data-board"), root = Braid.root();
    var spec = defined["board:" + id];
    if (!spec) { node.appendChild(h("p", { class: "fig-error" }, "Missing board panel " + id)); return; }
    node.classList.add("fig", "board-panel");
    node.setAttribute("data-fig", "board:" + id);
    if (!node.id) node.id = "fig-" + id;
    var onBoards = /boards\.html$/.test(location.pathname), custom = node.getAttribute("data-caption");
    var chapter = Braid.chapters.concat(Braid.appendices).find(function (c) { return c.file === spec.chapter; });
    var link = onBoards && chapter ? h("a", { href: root + spec.chapter + "#" + (spec.anchor || "fig-" + id) }, "in " + (chapter.start ? "the overview" : chapter.file === "lexicon.html" ? "the lexicon" : "chapter " + Braid.chapters.filter(function (c) { return !c.start; }).findIndex(function (c) { return c.file === spec.chapter; })))
                              : h("a", { href: root + "boards.html#crop-" + id }, "see it on the board");
    node.appendChild(h("figcaption", null, [custom || spec.caption, " · ", link]));
  }

  // MARK: Navigation

  function currentFile() { var p = location.pathname.split("/").pop() || "index.html"; return p; }
  function buildNav() {
    var side = document.querySelector("nav.side");
    if (!side || side.childElementCount) return;
    var here = currentFile(), visited = Braid.storage.get("visited", {});
    visited[here] = true;
    Braid.storage.set("visited", visited);
    var root = Braid.root();
    side.appendChild(h("a", { class: "brand", href: root + "index.html" }, "Braid, step by step"));
    side.appendChild(h("p", { class: "brand-sub" }, "Entropy-gated citations, from the first question to your own Thread"));
    var list = h("ol", { class: "questions" });
    Braid.chapters.forEach(function (c) {
      var a = h("a", { class: "q" + (visited[c.file] && c.file !== here ? " visited" : ""), href: root + c.file }, c.short);
      if (c.file === here) a.setAttribute("aria-current", "page");
      var li = h("li", { class: c.start ? "start" : null }, a);
      if (c.file === here && document.getElementById("engineers")) li.appendChild(h("a", { class: "eng", href: "#engineers" }, "for model engineers"));
      list.appendChild(li);
    });
    side.appendChild(list);
    side.appendChild(h("h3", null, "Appendices"));
    var more = h("ol", { class: "more" });
    Braid.appendices.forEach(function (c) {
      var a = h("a", { class: "q", href: root + c.file }, c.short);
      if (c.file === here) a.setAttribute("aria-current", "page");
      more.appendChild(h("li", null, a));
    });
    side.appendChild(more);
    var menu = document.querySelector("button.menu");
    if (menu) menu.addEventListener("click", function () { side.classList.toggle("open"); menu.setAttribute("aria-expanded", side.classList.contains("open")); });
    var main = document.querySelector("main.page");
    var index = Braid.chapters.findIndex(function (c) { return c.file === here; });
    if (main && index >= 0 && !main.querySelector("nav.prevnext")) {
      var prev = Braid.chapters[index - 1], next = Braid.chapters[index + 1];
      var nav = h("nav", { class: "prevnext", "aria-label": "Previous and next chapter" }, [
        prev ? h("a", { class: "prev", href: root + prev.file, rel: "prev" }, [h("small", null, "← Previous"), prev.short]) : h("span"),
        next ? h("a", { class: "next", href: root + next.file, rel: "next" }, [h("small", null, "Next →"), next.short]) : null
      ]);
      main.appendChild(nav);
      main.appendChild(h("p", { class: "keys" }, ["Keys: ", h("kbd", null, "←"), " ", h("kbd", null, "→"), " move between chapters; inside a figure they step through it."]));
      document.addEventListener("keydown", function (e) {
        if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
        var el = document.activeElement;
        if (el && el !== document.body && (el.closest("figure, [data-app]") || /INPUT|SELECT|TEXTAREA|BUTTON/.test(el.tagName))) return;
        if (e.key === "ArrowLeft" && prev) location.href = root + prev.file;
        if (e.key === "ArrowRight" && next) location.href = root + next.file;
      });
    }
    var bar = document.querySelector(".progress");
    if (bar) {
      var onScroll = function () { var d = document.documentElement; var max = d.scrollHeight - d.clientHeight; bar.style.width = (max > 0 ? (d.scrollTop / max) * 100 : 0) + "%"; };
      window.addEventListener("scroll", onScroll, { passive: true });
      onScroll();
    }
    document.querySelectorAll("main h2[id]").forEach(function (hd) {
      if (!hd.querySelector(".anchor")) hd.appendChild(h("a", { class: "anchor", href: "#" + hd.id, "aria-label": "Link to this section" }, "#"));
    });
  }

  // MARK: Mount

  Braid.mount = function (root) {
    var scope = root || document;
    var embed = document.body.classList.contains("embed");
    if (embed) {
      var sp = searchParams();
      if (sp.theme === "light" || sp.theme === "dark") document.documentElement.setAttribute("data-theme", sp.theme);
      if (sp.export === "1") document.body.classList.add("export");
      if (sp.bg === "transparent") document.body.classList.add("bg-transparent");
    }
    buildNav();
    scope.querySelectorAll("[data-code]").forEach(renderCode);
    scope.querySelectorAll("figure.board[data-board]").forEach(renderBoard);
    scope.querySelectorAll("figure.fig[data-fig]").forEach(function (fig) { mountFigure(fig, embed); });
    applyHash(true);
    window.addEventListener("hashchange", function () { applyHash(false); });
    if (embed && window.parent !== window) {
      var post = function () { try { window.parent.postMessage({ braidFigure: (scope.querySelector("figure.fig") || {}).id, height: document.documentElement.scrollHeight }, "*"); } catch (e) { /* no parent */ } };
      window.addEventListener("load", post);
      window.addEventListener("resize", post);
      setTimeout(post, 50);
    }
    // The chat orb, on every page but an embedded figure: one script, loaded once, that adds itself.
    if (!embed && !Braid.chat && !document.querySelector("script[data-chat]")) {
      var chat = document.createElement("script");
      chat.src = Braid.root() + "js/chat.js";
      chat.setAttribute("data-chat", "");
      document.body.appendChild(chat);
    }
    document.documentElement.setAttribute("data-mounted", "1");
  };

  // MARK: Self-check

  /** Every check the site can make in the browser: each bundled session replayed as braid verify would, and every mounted figure's own checks. */
  Braid.selfCheck = function (opts) {
    var results = [];
    var withSessions = !opts || opts.sessions !== false;
    if (withSessions) Braid.sessionKeys().forEach(function (key) {
      Braid.sessionChecks(key).forEach(function (r) { results.push(r); });
    });
    Object.keys(mounted).forEach(function (id) {
      if (mounted[id].spec.selfCheck) runChecks(mounted[id]).forEach(function (r) { results.push(Object.assign({ figure: id }, r)); });
    });
    Braid.extraChecks.forEach(function (x) {
      var rows;
      try { rows = x.run() || []; } catch (e) { rows = [{ name: "its checks ran", ok: false, detail: e && e.message }]; }
      rows.forEach(function (r) { results.push(Object.assign({ figure: x.name }, r)); });
    });
    return results;
  };
  /** Checks a page-level app adds to the self-test: { name, run() → [{ name, ok, detail }] }. */
  Braid.extraChecks = [];

  Braid.sessionChecks = function (key) {
    var se = Braid.session(key), out = [];
    var tol = M.tolerances;
    function add(name, ok, detail, value) { out.push({ session: se.slug, name: name, ok: ok, detail: detail, value: value }); }
    add("body hash", se.bodyOK(), "SHA-256 of the generation's lines is the end line's");
    var r = se.replay();
    add("Σ shares = 1", r.worst.shareSum <= tol.shareSum, "worst " + fmt.e(r.worst.shareSum) + " (verify allows " + tol.shareSum + ")", r.worst.shareSum);
    add("w′ from memory and the open set", r.worst.weights <= tol.arithmetic, "worst " + fmt.e(r.worst.weights), r.worst.weights);
    add("p from the open strands", r.worst.p <= tol.arithmetic * 10, "worst " + fmt.e(r.worst.p), r.worst.p);
    add("every share from p_lm, p_knn, λ and w′", r.worst.share <= tol.arithmetic * 10, "worst " + fmt.e(r.worst.share), r.worst.share);
    add("H_knn from the hits", r.worst.hknn <= tol.entropy, "worst " + fmt.e(r.worst.hknn), r.worst.hknn);
    add("the shadow β4 from memory and the traces", r.worst.shadow <= tol.arithmetic * 10, "worst " + fmt.e(r.worst.shadow), r.worst.shadow);
    add("the memory recursion (the clamp held)", r.worst.memory <= 1e-6, "worst " + fmt.e(r.worst.memory) + " over " + r.counts.observed + " prompt tokens (verify allows 1e−5; this page 1e−6)", r.worst.memory);
    var traces = se.traces(), tPos = 0, tMiss = 0;
    Object.keys(traces).forEach(function (n) { tPos += traces[n].positions; tMiss += traces[n].mismatches; });
    add("every chain state replays", tMiss === 0, (tPos - tMiss) + " of " + tPos + " strand positions");
    var hits = 0, misses = 0;
    se.steps.forEach(function (st) {
      (st.thr || []).forEach(function (rec, t) {
        var strand = se.strands[t];
        if (strand.commons) return;
        var lay = se.threads[strand.name].layoutIndex();
        rec.hits.forEach(function (hit) { hits++; if (lay.values[hit[0]] !== hit[2] || lay.valueRow[hit[0]] !== hit[3] || lay.valueOffset[hit[0]] !== hit[4]) misses++; });
      });
    });
    add("every hit sits on the index layout", misses === 0, (hits - misses) + " of " + hits + " hits");
    var ann = se.annotate(), spans = ann.spans.filter(function (sp) { return sp.kind === "verbatim"; }), good = 0;
    spans.forEach(function (sp) {
      var p = sp.partition.part, toks = p.tokens.slice(sp.offset, sp.offset + sp.tokens.length);
      var hashOK = M.hex(M.sha256(p.text)) === sp.partition.textSHA256;
      if (hashOK && toks.length === sp.tokens.length && toks.every(function (x, i) { return x === sp.tokens[i]; })) good++;
    });
    add("every span re-reads from its source", good === spans.length, good + " of " + spans.length + " spans verified");
    var worstMod = 0;
    se.module().forEach(function (m, t) {
      var logged = M.loggedModule(m.series, se.header.module);
      var withThr = se.steps.filter(function (st) { return st.src !== "ctx" && st.thr; });
      withThr.forEach(function (st, j) { worstMod = Math.max(worstMod, Math.abs(logged[j] - f32(st.thr[t].mod || 0))); });
    });
    add("every logged e_t recomputes", worstMod <= 1e-6, "worst " + fmt.e(worstMod), worstMod);
    return out;
  };

  // MARK: SVG export

  var PRESENTATION = ["fill", "stroke", "stroke-width", "stroke-dasharray", "stroke-linecap", "stroke-linejoin", "opacity", "fill-opacity", "stroke-opacity",
    "font-family", "font-size", "font-weight", "font-style", "letter-spacing", "text-anchor", "dominant-baseline", "paint-order"];
  /** A figure's SVG, standalone: computed styles written as attributes (so CSS variables resolve), with a background, a title and a description. */
  Braid.exportSVG = function (selector) {
    var fig = typeof selector === "string" ? document.querySelector(selector) : selector;
    var svg = fig && fig.querySelector(".fig-body svg");
    if (!svg) return null;
    var clone = svg.cloneNode(true);
    var a = svg.querySelectorAll("*"), b = clone.querySelectorAll("*");
    function inline(src, dst) {
      var cs = getComputedStyle(src);
      PRESENTATION.forEach(function (p) { var v = cs.getPropertyValue(p); if (v && v !== "normal" && v !== "auto") dst.setAttribute(p, v); });
      dst.removeAttribute("class");
      dst.removeAttribute("style");
    }
    inline(svg, clone);
    for (var i = 0; i < a.length; i++) inline(a[i], b[i]);
    var box = svg.viewBox && svg.viewBox.baseVal && svg.viewBox.baseVal.width ? svg.viewBox.baseVal : svg.getBBox();
    clone.setAttribute("xmlns", SVGNS);
    clone.setAttribute("viewBox", [box.x, box.y, box.width, box.height].join(" "));
    clone.setAttribute("width", box.width);
    clone.setAttribute("height", box.height);
    var bg = getComputedStyle(fig).backgroundColor || getComputedStyle(document.body).backgroundColor;
    var rect = document.createElementNS(SVGNS, "rect");
    rect.setAttribute("x", box.x); rect.setAttribute("y", box.y); rect.setAttribute("width", box.width); rect.setAttribute("height", box.height); rect.setAttribute("fill", bg);
    clone.insertBefore(rect, clone.firstChild);
    var title = document.createElementNS(SVGNS, "title");
    title.textContent = (fig.querySelector(".fig-title") || {}).textContent || "";
    var desc = document.createElementNS(SVGNS, "desc");
    desc.textContent = ((fig.querySelector("figcaption") || {}).textContent || "").trim();
    clone.insertBefore(desc, clone.firstChild);
    clone.insertBefore(title, clone.firstChild);
    return new XMLSerializer().serializeToString(clone);
  };

  // MARK: The chart kit

  var chart = (Braid.chart = {});
  chart.scale = function (d0, d1, r0, r1) { var k = d1 === d0 ? 0 : (r1 - r0) / (d1 - d0); var f = function (v) { return r0 + (v - d0) * k; }; f.invert = function (y) { return d0 + (y - r0) / k; }; return f; };
  chart.niceMax = function (v) { if (v <= 0) return 1; var p = Math.pow(10, Math.floor(Math.log10(v))); var m = v / p; return (m <= 1 ? 1 : m <= 2 ? 2 : m <= 2.5 ? 2.5 : m <= 5 ? 5 : 10) * p; };
  /**
   * A line chart over integer positions. opts: width, height, n (positions), labels (per position, optional),
   * series [{label, cls, values, dash, area}], yMin, yMax, yTicks, yFormat, refs [{y, label}], shade [{from, to, label}],
   * cursor (position), onPick(position), xTicks (every k), title, markers [{x, y, cls, label}], step (draw as steps).
   */
  chart.lines = function (o) {
    var W = o.width || 640, H = o.height || 180, L = o.left === undefined ? 40 : o.left, R = o.right === undefined ? 12 : o.right, T = o.top === undefined ? 12 : o.top, Bm = o.bottom === undefined ? (o.labels ? 34 : 22) : o.bottom;
    var n = o.n, yMin = o.yMin === undefined ? 0 : o.yMin, yMax = o.yMax;
    if (yMax === undefined) { var mx = 0; o.series.forEach(function (se) { se.values.forEach(function (v) { if (v !== null && v > mx) mx = v; }); }); yMax = chart.niceMax(mx || 1); }
    var x = chart.scale(o.x0 === undefined ? 0 : o.x0, Math.max(1, (o.x1 === undefined ? n - 1 : o.x1)), L, W - R), y = chart.scale(yMin, yMax, H - Bm, T);
    var svg = s("svg", { viewBox: "0 0 " + W + " " + H, role: "img", "aria-label": o.title || "chart" });
    if (o.title) svg.appendChild(s("title", null, o.title));
    (o.shade || []).forEach(function (sh) {
      var x0 = x(sh.from - 0.5), x1 = x(sh.to + 0.5);
      svg.appendChild(s("rect", { class: sh.cls || "shade", x: Math.max(L, x0), y: T, width: Math.max(0, Math.min(W - R, x1) - Math.max(L, x0)), height: H - Bm - T }));
      if (sh.label) svg.appendChild(s("text", { class: "t-small", x: Math.max(L, x0) + 4, y: T + 10 }, sh.label));
    });
    var ticks = o.yTicks || [yMin, (yMin + yMax) / 2, yMax];
    var grid = s("g", { class: "grid" });
    ticks.forEach(function (t) {
      grid.appendChild(s("line", { x1: L, x2: W - R, y1: y(t), y2: y(t) }));
      svg.appendChild(s("text", { class: "t-small", x: L - 6, y: y(t) + 3, "text-anchor": "end" }, o.yFormat ? o.yFormat(t) : String(+t.toFixed(2))));
    });
    svg.insertBefore(grid, svg.firstChild.nextSibling || null);
    (o.refs || []).forEach(function (r) {
      svg.appendChild(s("line", { x1: L, x2: W - R, y1: y(r.y), y2: y(r.y), style: "stroke: var(--faint); stroke-dasharray: 4 3" }));
      if (r.label) svg.appendChild(s("text", { class: "t-small", x: W - R - 2, y: y(r.y) - 3, "text-anchor": "end", style: "fill: var(--dim)" }, r.label));
    });
    if (o.yLabel) svg.appendChild(s("text", { class: "t-small", x: 2, y: T - 2 }, o.yLabel));
    o.series.forEach(function (se) {
      var d = "", started = false;
      se.values.forEach(function (v, i) {
        if (v === null || v === undefined || isNaN(v)) { started = false; return; }
        var px = x(i + (o.x0 || 0)), py = y(Math.min(Math.max(v, yMin), yMax));
        if (o.step && started) { d += "H" + px.toFixed(1); d += "V" + py.toFixed(1); }
        else d += (started ? "L" : "M") + px.toFixed(1) + "," + py.toFixed(1);
        started = true;
      });
      var g = s("g", { class: se.cls || "" });
      if (se.area) g.appendChild(s("path", { d: d + "V" + y(yMin) + "H" + x(o.x0 || 0) + "Z", style: "fill: var(--s); opacity: .12; stroke: none" }));
      g.appendChild(s("path", { d: d, style: "fill: none; stroke: var(--s, var(--fg-2)); stroke-width: " + (se.width || 2) + (se.dash ? "; stroke-dasharray: " + se.dash : "") }));
      if (se.points !== false && n <= 48) se.values.forEach(function (v, i) {
        if (v === null || v === undefined || isNaN(v)) return;
        g.appendChild(s("circle", { cx: x(i + (o.x0 || 0)), cy: y(Math.min(Math.max(v, yMin), yMax)), r: se.dash ? 2 : 2.6, style: "fill: var(--bg-raised); stroke: var(--s, var(--fg-2)); stroke-width: 1.4" }));
      });
      svg.appendChild(g);
    });
    (o.markers || []).forEach(function (mk) { svg.appendChild(s("circle", { cx: x(mk.x), cy: y(mk.y), r: 4, class: mk.cls || "", style: "fill: var(--s, var(--fg)); stroke: var(--bg-raised); stroke-width: 1.5" })); });
    var axis = s("g", { class: "axis" }, s("line", { x1: L, x2: W - R, y1: H - Bm, y2: H - Bm }));
    svg.appendChild(axis);
    if (o.labels) o.labels.forEach(function (lab, i) {
      if (lab === null || lab === undefined) return;
      svg.appendChild(s("text", { class: "t-small t-mono", x: x(i + (o.x0 || 0)), y: H - Bm + 13, "text-anchor": "middle", transform: o.rotate ? "rotate(-40 " + x(i + (o.x0 || 0)) + " " + (H - Bm + 13) + ")" : null }, lab));
    });
    else if (o.xTicks) for (var i = o.x0 || 0; i <= (o.x1 === undefined ? n - 1 : o.x1); i += o.xTicks) svg.appendChild(s("text", { class: "t-small", x: x(i), y: H - Bm + 13, "text-anchor": "middle" }, o.xFormat ? o.xFormat(i) : String(i)));
    if (o.cursor !== undefined && o.cursor !== null) svg.appendChild(s("line", { class: "cursor", x1: x(o.cursor), x2: x(o.cursor), y1: T, y2: H - Bm }));
    if (o.onPick) {
      var step = (W - R - L) / Math.max(1, (o.x1 === undefined ? n - 1 : o.x1) - (o.x0 || 0));
      for (var k = o.x0 || 0; k <= (o.x1 === undefined ? n - 1 : o.x1); k++) (function (k) {
        var r = s("rect", { class: "hover-target", x: x(k) - step / 2, y: T, width: step, height: H - Bm - T });
        r.addEventListener("click", function () { o.onPick(k); });
        if (o.tip) r.appendChild(s("title", null, o.tip(k)));
        svg.appendChild(r);
      })(k);
    }
    return svg;
  };

  /** A labelled slider row. */
  /** A labelled slider row. While the pointer holds its knob it is marked active, so a redraw keeps this very element and the drag goes on. */
  Braid.slider = function (label, value, min, max, step, onInput, text) {
    var key = "slider:" + label;
    var out = h("output", null, text ? text(value) : String(value));
    var input = h("input", { type: "range", min: min, max: max, step: step, value: value, "aria-label": label, "aria-valuetext": text ? text(value) : String(value), "data-key": key });
    input.addEventListener("input", function () { var v = parseFloat(input.value); out.textContent = text ? text(v) : String(v); input.setAttribute("aria-valuetext", out.textContent); onInput(v); });
    input.addEventListener("pointerdown", function () { input.setAttribute("data-active", "1"); });
    input.addEventListener("blur", function () { input.removeAttribute("data-active"); });
    return h("label", { "data-keep": key }, [label, input, out]);
  };
  ["pointerup", "pointercancel"].forEach(function (type) {
    window.addEventListener(type, function () {
      document.querySelectorAll('[data-active="1"]').forEach(function (el) { el.removeAttribute("data-active"); });
    }, true);
  });
  Braid.select = function (label, options, value, onChange) {
    var sel = h("select", { "aria-label": label, "data-key": "select:" + label }, options.map(function (o) { return h("option", { value: o.value, selected: o.value === value }, o.label); }));
    sel.addEventListener("change", function () { onChange(sel.value); });
    return h("label", null, [label, sel]);
  };
  Braid.legend = function (items) {
    return h("div", { class: "legend" }, items.map(function (it) {
      return h("span", { class: "key " + (it.cls || "") }, [h("span", { class: it.line ? "ln" + (it.dash ? " dash" : "") : "sw", style: it.line ? "border-color: var(--s, " + (it.color || "var(--fg-2)") + ")" : "background: var(--s, " + (it.color || "var(--fg-2)") + ")" }), it.label]);
    }));
  };
})();
