/*
 * The boards' kit: what every board panel is drawn with. Braid.draw makes the SVG parts (a box of
 * lines, an arrow with its own head so an export needs no markers, a dashed frame, text), Braid.panel
 * makes the HTML parts (a list, cards, tiles, a table in a scroll box, a formula, the studio's detail
 * block) and Braid.boards is the registry: define(id, spec) registers "board:<id>" as a figure with a
 * board, a title, a caption and a chapter; reuse(name, fixed) wraps a figure the chapters already
 * draw, with fixed settings; the checks run on the self-test page and on boards.html. A chapter shows
 * a panel with <figure class="board" data-board="<id>">, which braid.js turns into that figure.
 */
(function () {
  "use strict";
  var B = window.Braid, h = B.h, s = B.s;
  function r1(v) { return Math.round(v * 10) / 10; }

  // MARK: SVG parts

  var draw = (B.draw = {});
  draw.svg = function (W, H, label, cls) {
    return s("svg", { viewBox: "0 0 " + W + " " + H, class: "board-svg" + (cls ? " " + cls : ""), role: "img", "aria-label": label });
  };
  /** A box with centred lines, the first one its title. o: x, y, w, h, lines, cls, strand, id, part, dashed, align, lh. */
  draw.box = function (g, o) {
    var grp = s("g", { class: o.strand || null, "data-part": o.part || null, "data-box": o.id || null });
    grp.appendChild(s("rect", { x: r1(o.x), y: r1(o.y), width: r1(o.w), height: r1(o.h), rx: o.rx === undefined ? 6 : o.rx,
                                class: "bd-box " + (o.cls || "bd-plain") + (o.dashed ? " bd-dashed" : "") }));
    var lines = (o.lines || []).filter(function (l) { return l !== null && l !== undefined && l !== ""; });
    var lh = o.lh || 12.5, left = o.align === "left", cx = left ? r1(o.x + 9) : r1(o.x + o.w / 2);
    var top = o.y + o.h / 2 - (lines.length - 1) * lh / 2 + 3.5;
    lines.forEach(function (text, i) {
      grp.appendChild(s("text", { x: cx, y: r1(top + i * lh), "text-anchor": left ? "start" : "middle", class: i === 0 ? (o.titleCls || "bd-t") : (o.subCls || "bd-sub") }, text));
    });
    g.appendChild(grp);
    return grp;
  };
  /** An arrow from (x1, y1) to (x2, y2) with a drawn head. o: part, dashed, cls. */
  draw.arrow = function (g, x1, y1, x2, y2, o) {
    o = o || {};
    var grp = s("g", { "data-part": o.part || null });
    var a = Math.atan2(y2 - y1, x2 - x1), len = 6, half = 3.2;
    var bx = x2 - len * Math.cos(a), by = y2 - len * Math.sin(a), px = -Math.sin(a) * half, py = Math.cos(a) * half;
    grp.appendChild(s("line", { x1: r1(x1), y1: r1(y1), x2: r1(bx), y2: r1(by), class: "bd-line" + (o.dashed ? " dash" : "") + (o.cls ? " " + o.cls : "") }));
    grp.appendChild(s("path", { d: "M" + r1(x2) + "," + r1(y2) + " L" + r1(bx + px) + "," + r1(by + py) + " L" + r1(bx - px) + "," + r1(by - py) + " Z", class: "bd-head" + (o.cls ? " " + o.cls : "") }));
    g.appendChild(grp);
    return grp;
  };
  /** A plain line (no head). */
  draw.line = function (g, x1, y1, x2, y2, o) {
    o = o || {};
    g.appendChild(s("line", { x1: r1(x1), y1: r1(y1), x2: r1(x2), y2: r1(y2), class: "bd-line" + (o.dashed ? " dash" : "") + (o.cls ? " " + o.cls : "") }));
  };
  /** Lines of text from (x, y) downwards. */
  draw.text = function (g, x, y, lines, cls, anchor, lh) {
    var grp = s("g");
    (Array.isArray(lines) ? lines : [lines]).forEach(function (t, i) {
      grp.appendChild(s("text", { x: r1(x), y: r1(y + i * (lh || 12.5)), class: cls || "bd-sub", "text-anchor": anchor || "start" }, t));
    });
    g.appendChild(grp);
    return grp;
  };
  /** A dashed frame with a small-caps caption at its top left. o: x, y, w, h, title, strand. */
  draw.frame = function (g, o) {
    var grp = s("g", { class: o.strand || null });
    grp.appendChild(s("rect", { x: r1(o.x), y: r1(o.y), width: r1(o.w), height: r1(o.h), rx: 10, class: "bd-frame" }));
    if (o.title) grp.appendChild(s("text", { x: r1(o.x + 10), y: r1(o.y + 15), class: "bd-cap" }, o.title));
    g.appendChild(grp);
    return grp;
  };

  // MARK: HTML parts

  var panel = (B.panel = {});
  function item(it) {
    if (typeof it === "string") return [it];
    if (Array.isArray(it)) return [h("strong", null, it[0]), " ", it[1]];
    return [it.lead ? h("strong", null, it.lead) : null, it.lead ? " " : null, it.text];
  }
  /** A list; an item is a string, [lead, text] or { lead, text }. */
  panel.list = function (items, o) {
    o = o || {};
    return h(o.ordered ? "ol" : "ul", { class: "bd-list" + (o.cls ? " " + o.cls : "") }, items.map(function (it) { return h("li", null, item(it)); }));
  };
  /** Numbered cards: { n, title, text, strand }. */
  panel.cards = function (cards, o) {
    o = o || {};
    return h("div", { class: "bd-cards" + (o.cls ? " " + o.cls : "") }, cards.map(function (c) {
      return h("div", { class: "bd-card " + (c.strand || "") }, [c.n !== undefined ? h("div", { class: "bd-n" }, String(c.n)) : null, c.title ? h("h5", null, c.title) : null, h("div", null, c.text)]);
    }));
  };
  /** Big numbers: { value, text }. */
  panel.tiles = function (tiles) {
    return h("div", { class: "bd-tiles" }, tiles.map(function (t) { return h("div", { class: "bd-tile" }, [h("div", { class: "bd-big" }, t.value), h("div", { class: "bd-sub" }, t.text)]); }));
  };
  /** A table in a scroll box. cols: strings or { label, n }; a cell is a string, a node, or { text, cls, n }. */
  panel.table = function (cols, rows, o) {
    o = o || {};
    function cell(c, tag, k) {
      var col = cols[k] || {}, n = (c && c.n !== undefined) ? c.n : col.n, cls = (c && c.cls) || "";
      var content = c && c.nodeType ? c : (c && c.text !== undefined ? c.text : c);
      return h(tag, { class: ((n ? "n " : "") + cls).trim() || null }, content);
    }
    var table = h("table", { class: "bd-table" }, [
      h("thead", null, h("tr", null, cols.map(function (c, k) { return cell(typeof c === "string" ? c : c.label, "th", k); }))),
      h("tbody", null, rows.map(function (r) { return h("tr", { class: r.cls || null }, (r.cells || r).map(function (c, k) { return cell(c, "td", k); })); }))
    ]);
    return h("div", { class: "scroll" }, table);
  };
  /** A formula card: a lead, mono lines, then a plain line on what it means. */
  panel.formula = function (o) {
    return h("div", { class: "bd-formula" + (o.strand ? " " + o.strand : "") }, [
      o.lead ? h("p", { class: "bd-lead" }, o.lead) : null,
      (o.lines || []).map(function (l) { return h("p", null, l); }),
      o.why ? h("p", { class: "bd-why" }, o.why) : null
    ]);
  };
  /** The studio's detail block, as 07-inference prints it. */
  panel.detail = function (lines) { return h("div", { class: "detail" }, lines.map(function (l, i) { return [i ? "\n" : "", l]; })); };
  panel.note = function (text) { return h("p", { class: "note" }, text); };

  // MARK: The registry

  var boards = (B.boards = { panels: {}, order: [] });
  boards.BOARDS = {
    1: { title: "A Thread's blocks: a head of twelve, on the commons' trunk" },
    2: { title: "The braid: the commons and every Thread under one reed" },
    3: { title: "The model in detail: tensor by tensor, entropy by entropy" },
    4: { title: "Braid for product teams" }
  };
  /** The pack's seam, from the playground's version record when a page loads it; the imported pack's otherwise. */
  boards.seam12 = function () {
    var hb = (window.BraidData || {}).harbour;
    return ((hb && hb.version && hb.version.seamSHA256) || "079ebc0f9299").slice(0, 12);
  };
  boards.define = function (id, spec) {
    if (!spec.board || !spec.caption || !spec.chapter || !spec.title) throw new Error("board panel " + id + " needs a board, a title, a caption and a chapter");
    boards.panels[id] = spec;
    boards.order.push(id);
    B.define("board:" + id, spec);
  };
  /** A figure the chapters draw, with fixed settings: its render and self-check, its params defaulting to `fixed` and left out of links. */
  boards.reuse = function (name, fixed, spec) {
    var base = B.figures[name];
    if (!base) {
      // The figure's script is not on this page: the panel says so, and every other panel of the board still defines.
      return Object.assign({ render: function (body) { body.appendChild(h("p", { class: "fig-error" }, "This panel reuses the figure “" + name + "”, whose script is not loaded on this page.")); } }, spec);
    }
    var params = {};
    Object.keys(base.params || {}).forEach(function (k) {
      params[k] = Object.assign({}, base.params[k]);
      if (fixed && k in fixed) { params[k].default = fixed[k]; params[k].link = false; }
    });
    return Object.assign({ params: params, render: base.render, selfCheck: base.selfCheck, reuses: name }, spec);
  };
  boards.get = function (id) { return boards.panels[id] || null; };
  boards.all = function () { return boards.order.map(function (id) { return Object.assign({ id: id }, boards.panels[id]); }); };

  // MARK: The checks

  var BANNED = ["in other words", "essentially", "basically", "note that", "it is worth", "importantly", "in this chapter", "as we will see"];
  B.extraChecks.push({ name: "boards", run: function () {
    var out = [], files = B.chapters.concat(B.appendices).map(function (c) { return c.file; });
    var bad = [];
    boards.order.forEach(function (id) {
      var p = boards.panels[id], cap = p.caption || "";
      if (!(p.board >= 1 && p.board <= 4)) bad.push(id + ": board " + p.board);
      if (files.indexOf(p.chapter) < 0) bad.push(id + ": chapter " + p.chapter);
      BANNED.forEach(function (phrase) { if (cap.toLowerCase().indexOf(phrase) >= 0) bad.push(id + ": the caption says “" + phrase + "”"); });
      if (/\([^)]*[a-z][^)]*\)/.test(cap)) bad.push(id + ": a parenthesis in the caption");
    });
    out.push({ name: "every panel names a board, a chapter that exists and a caption in the site's voice", ok: !bad.length, detail: bad.join("; ") || boards.order.length + " panels" });
    var missing = Array.prototype.map.call(document.querySelectorAll("[data-board]"), function (f) { return f.getAttribute("data-board"); }).filter(function (id) { return !boards.panels[id]; });
    out.push({ name: "every board panel this page asks for is defined", ok: !missing.length, detail: missing.join(", ") });
    if (/boards\.html$/.test(location.pathname)) {
      var counts = {};
      Array.prototype.forEach.call(document.querySelectorAll("figure[data-board], figure[data-fig^='board:']"), function (f) {
        var id = f.getAttribute("data-board") || f.getAttribute("data-fig").slice(6);
        counts[id] = (counts[id] || 0) + 1;
      });
      var absent = boards.order.filter(function (id) { return !counts[id]; }), twice = Object.keys(counts).filter(function (id) { return counts[id] > 1; });
      out.push({ name: "the boards page holds every defined panel once", ok: !absent.length && !twice.length, detail: (absent.length ? "missing " + absent.join(", ") : "") + (twice.length ? " twice " + twice.join(", ") : "") });
    }
    return out;
  } });
})();
