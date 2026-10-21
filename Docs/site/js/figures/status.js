/*
 * Where Braid stands: the short "what moves the answer" table, the full claims table generated from
 * Docs/PAPER.md (data/claims.js), and the verify checklist run in the browser over every bundled session.
 */
(function () {
  "use strict";
  var B = window.Braid, h = B.h, fmt = B.fmt;
  var GLYPH = { backed: "✓ backed", partial: "◐ backed in part", fails: "✗ fails", "not-claimed": "○ not claimed", pending: "◌ pending" };

  function claimRow(prefix) {
    var c = (window.BraidData || {}).claims;
    if (!c) return null;
    for (var g = 0; g < c.groups.length; g++) for (var r = 0; r < c.groups[g].rows.length; r++) {
      var row = c.groups[g].rows[r], plain = row.claim.replace(/<[^>]+>/g, "");
      if (plain.indexOf(prefix) === 0) return row;
    }
    return null;
  }
  function statusCell(row) { return row ? h("span", { class: "status " + row["class"] }, GLYPH[row["class"]]) : h("span", { class: "status pending" }, "–"); }

  var STEERS = [
    { what: "The gate's memory", does: "Moves the answer. It learns at prompt tokens only, from each Thread's lift over the commons, clamped at ten to one.", claim: "The gate's memory recursion is replayable" },
    { what: "H_lm and H_knn", does: "Logged at every position and replayed by braid verify. They move nothing yet.", claim: "H_knn ≈ the evidence's entropy" },
    { what: "The trajectory module, e_t", does: "Reads the two entropies and logs e_t. Its gain κ is 0, so it never reaches the gate.", claim: "The entropy module can replace the β4 trace gate" },
    { what: "The trace", does: "Follows each Thread's hits through one of its documents. Checked and logged, never applied.", claim: "The trace detects a Thread's own text" },
    { what: "The β4 trace gate", does: "A counterfactual gate from memory and the trace, logged beside the live one as a shadow. Never applied.", claim: "The entropy module can replace the β4 trace gate", note: "the shadow it would replace" }
  ];

  B.define("what-steers", {
    title: "What moves the answer today",
    render: function (body) {
      var c = (window.BraidData || {}).claims || {};
      body.appendChild(h("div", { class: "scroll" }, h("table", null, [
        h("thead", null, h("tr", null, [h("th", null, "Part"), h("th", null, "What it does today"), h("th", null, "The claim behind it")])),
        h("tbody", null, STEERS.map(function (x) {
          var row = claimRow(x.claim);
          return h("tr", null, [h("td", null, h("b", null, x.what)), h("td", { style: "white-space: normal; min-width: 16rem" }, x.does),
            h("td", { style: "white-space: normal; min-width: 12rem" }, [statusCell(row), " ", row ? h("span", { html: row.backedBy.replace(/^<code>[^<]+<\/code>:?\s*/, "") }) : ""])]);
        }))
      ])));
      body.appendChild(h("p", { class: "note" }, "Statuses as of " + (c.asOf || "–") + ", read from the claims in chapter 10 when this site's data was built. Rules were fixed before the numbers."));
    },
    selfCheck: function () {
      return STEERS.map(function (x) { var row = claimRow(x.claim); return { name: "the claims hold “" + x.claim + "…”", ok: !!row, detail: row ? GLYPH[row["class"]] : "not found" }; });
    }
  });

  B.define("status", {
    title: "Where Braid stands",
    render: function (body) {
      var c = (window.BraidData || {}).claims;
      if (!c) throw new Error("missing data/claims.js");
      c.groups.forEach(function (g) {
        body.appendChild(h("h4", { style: "margin: .9rem 0 .3rem; font: 600 .78rem var(--font-sans); letter-spacing: .06em; text-transform: uppercase; color: var(--dim)" }, g.title));
        body.appendChild(h("div", { class: "scroll" }, h("table", null, [
          h("thead", null, h("tr", null, [h("th", null, "Claim"), h("th", null, "Backed by"), h("th", null, "Status")])),
          h("tbody", null, g.rows.map(function (r) {
            var id = "status-" + r.claim.replace(/<[^>]+>/g, "").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 48);
            return h("tr", { id: id }, [h("td", { style: "white-space: normal; min-width: 14rem", html: r.claim }), h("td", { style: "white-space: normal; min-width: 16rem", html: r.backedBy }),
              h("td", { style: "white-space: normal; min-width: 9rem" }, [h("span", { class: "status " + r["class"] }, GLYPH[r["class"]]), r["class"] !== "backed" && r.status.replace(/<[^>]+>/g, "").length > 12 ? h("div", { class: "note", html: r.status }) : null])]);
          }))
        ])));
      });
      body.appendChild(h("p", { class: "note" }, "Statuses as of " + c.asOf + ". Transformer reference numbers from RaoLM are not shown, because they are not Braid results."));
    }
  });

  B.define("browser-verify", {
    title: "Your browser replays the logs",
    render: function (body) {
      var keys = B.sessionKeys(), started = performance.now();
      var all = keys.map(function (k) { return B.sessionChecks(k); });
      var names = all[0].map(function (c) { return c.name; });
      var table = h("table", null, [
        h("thead", null, h("tr", null, [h("th", null, "Check")].concat(keys.map(function (k) { var se = B.session(k); return h("th", { class: "n", title: se.label }, se.slug); })))),
        h("tbody", null, names.map(function (name, i) {
          return h("tr", null, [h("td", { style: "white-space: normal" }, name)].concat(all.map(function (checks) {
            var c = checks[i];
            return h("td", { class: "n", title: c.detail }, h("span", { class: "status " + (c.ok ? "backed" : "fails") }, c.ok ? "✓" : "✗"));
          })));
        }))
      ]);
      var failed = all.reduce(function (n, checks) { return n + checks.filter(function (c) { return !c.ok; }).length; }, 0);
      body.appendChild(h("div", { class: "scroll" }, table));
      body.appendChild(h("p", { class: "readout" }, [h("b", null, failed ? failed + " checks failed" : "Every check passed"), " · " + keys.length + " sessions, " + names.length + " checks each, in " + Math.round(performance.now() - started) + " ms. Hover a mark for the worst deviation."]));
      var worst = {};
      all.forEach(function (checks) { checks.forEach(function (c) { if (typeof c.value === "number") worst[c.name] = Math.max(worst[c.name] || 0, c.value); }); });
      body.appendChild(h("ul", { class: "checks" }, Object.keys(worst).map(function (n) {
        return h("li", null, [h("span", { class: "mark ok" }, "·"), n, h("span", { class: "val" }, "worst " + fmt.e(worst[n]))]);
      })));
    },
    selfCheck: function () {
      var out = [];
      B.sessionKeys().forEach(function (k) { B.sessionChecks(k).forEach(function (c) { out.push({ name: k + ": " + c.name, ok: c.ok, detail: c.detail }); }); });
      return out;
    }
  });
})();
