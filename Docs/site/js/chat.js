/*
 * The chat orb: on every page but the embedded figures, an orb at the bottom right that opens into a mini
 * chat about what the reader is looking at. On the code explorer it reads the selected declaration, its code
 * and its place on the trails; on any other page, the page's text. It calls Mistral's chat API from the
 * browser, and only when the reader sends a message, with the key src/chatkey.py copied from this Mac into
 * local/chat.js (gitignored) or one the reader pastes, which stays in this browser. Replies are rendered as
 * text and a few marks of markdown, never as HTML. Braid.chat.transport can be replaced, so the checks never
 * call the network.
 */
(function () {
  "use strict";
  var B = window.Braid, h = B.h;
  var ENDPOINT = "https://api.mistral.ai/v1/chat/completions";
  var DEFAULTS = { provider: "mistral", model: "mistral-large-4", reasoning: "none" };
  var HISTORY = 12;
  var ROUNDS = 5; // reads before the model must answer
  var READING = [
    "You can read the whole codebase. The map below lists every file and every trail, training and inference for text and for questions, and your tools read any declaration, file or line of text.",
    "Start from what the reader has selected. When a question reaches past it, read the declarations you need before you answer, and name what you read. " +
    "Read rather than guess, and stop reading once you can answer."
  ].join("\n");
  var SYSTEM = [
    "You are the guide on \"Braid, step by step\", a tutorial site about Braid.",
    "Braid is a language model made of strands under one reed. The commons is a pretrained Mamba2 model of 130 million parameters. " +
    "Each Thread is one corpus with its own trained blocks 0 to 11, its head, run in front of the commons' tail, blocks 12 to 23 with the embedding and the final norm, the same modules the commons runs, and a provenance index of every position in that corpus. Every token's " +
    "probability is split exactly among the strands, and each Thread's part is cited to its own text. The model is Mamba2 (SSD): no attention " +
    "and no KV cache anywhere. The code is Swift, on MLX.",
    "Answer the reader's question about what they are looking at, described below.",
    "- Give the answer first, in plain words and short sentences. Most answers fit in a few sentences.",
    "- Ground every claim about Braid in what follows. When it does not say, say so instead of guessing.",
    "- Never invent numbers, results, file names or line numbers.",
    "- Point at code as File.swift:line, with the line numbers given.",
    "- Use `backticks` for identifiers, and a fenced block only to show code."
  ].join("\n");

  var state = { messages: [], busy: null, tried: false, pasted: "", config: null };
  var ui = {};

  // MARK: What the reader is looking at

  function context() {
    var x = B.explorer && B.explorer.context ? B.explorer.context() : null;
    if (x) return x;
    var main = document.querySelector("main.page") || document.body;
    var title = ((main.querySelector("h1") || {}).textContent || document.title).trim();
    var text = (main.innerText || main.textContent || "").replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
    if (text.length > 9000) text = text.slice(0, 9000) + "\n[the page goes on]";
    return { kind: "page", label: title, text: "The reader is on the page \"" + title + "\" (" + location.pathname.split("/").pop() + "). What it shows:\n\n" + text };
  }
  function starters(kind) {
    return kind === "code" ? ["What does this do?", "Why is it built this way?", "How does it connect to the rest of its step?"]
                           : ["Explain this page in two sentences.", "What should I understand first here?"];
  }

  // MARK: The key

  var waiting = [];
  /** Calls done with the key and model: this Mac's (local/chat.js, loaded once, on first use), else a pasted key, else null. */
  function withConfig(done) {
    var local = (window.BraidData || {}).chat;
    if (local && local.key) return done(Object.assign({}, DEFAULTS, local));
    if (state.loading) { waiting.push(done); return; }
    if (!state.tried) {
      state.tried = true;
      state.loading = true;
      waiting.push(done);
      var s = document.createElement("script");
      var settle = function () { state.loading = false; var all = waiting; waiting = []; all.forEach(withConfig); };
      s.src = B.root() + "local/chat.js";
      s.onload = settle;
      s.onerror = function () { s.remove(); settle(); };
      document.head.appendChild(s);
      return;
    }
    var key = state.pasted || B.storage.get("chat:key", "");
    done(key ? Object.assign({}, DEFAULTS, { key: key, source: "a key pasted in this browser" }) : null);
  }

  // MARK: Talking to Mistral

  /** Sends one request, calls onDelta with each piece of text as it streams, and resolves to { content, toolCalls }. Replaceable for tests. */
  function mistral(body, key, onDelta, signal) {
    var content = "", calls = [];
    return fetch(ENDPOINT, {
      method: "POST", signal: signal,
      headers: { "Content-Type": "application/json", Accept: "text/event-stream", Authorization: "Bearer " + key },
      body: JSON.stringify(body)
    }).then(function (res) {
      if (!res.ok) return res.text().then(function (t) { var e = new Error(t.slice(0, 300)); e.status = res.status; throw e; });
      var reader = res.body.getReader(), decoder = new TextDecoder(), buffer = "";
      function pump() {
        return reader.read().then(function (r) {
          if (r.done) return { content: content, toolCalls: calls.filter(function (c) { return c && c["function"] && c["function"].name; }) };
          buffer += decoder.decode(r.value, { stream: true });
          var lines = buffer.split("\n");
          buffer = lines.pop();
          lines.forEach(function (line) {
            line = line.trim();
            if (line.indexOf("data:") !== 0) return;
            var data = line.slice(5).trim();
            if (!data || data === "[DONE]") return;
            try {
              var delta = ((JSON.parse(data).choices || [])[0] || {}).delta || {}, c = delta.content;
              if (Array.isArray(c)) c = c.filter(function (p) { return p && p.type === "text"; }).map(function (p) { return p.text; }).join("");
              if (c) { content += c; onDelta(c); }
              (delta.tool_calls || []).forEach(function (tc) {
                var known = tc.id ? calls.findIndex(function (x) { return x.id === tc.id; }) : -1;
                var at = typeof tc.index === "number" ? tc.index : known >= 0 ? known : tc.id ? calls.length : Math.max(0, calls.length - 1);
                var call = calls[at] || (calls[at] = { id: "", type: "function", "function": { name: "", arguments: "" } });
                if (tc.id) call.id = tc.id;
                if (tc["function"]) {
                  if (tc["function"].name) call["function"].name = tc["function"].name;
                  if (tc["function"].arguments) call["function"].arguments += typeof tc["function"].arguments === "string" ? tc["function"].arguments : JSON.stringify(tc["function"].arguments);
                }
              });
            } catch (e) { /* a partial line: the next read completes it */ }
          });
          return pump();
        });
      }
      return pump();
    });
  }

  /** True on a page that holds the sources, where the model may read the rest of the codebase. */
  function canRead() { return !!(B.explorer && B.explorer.tools && B.explorer.map && B.explorer.tool); }
  /** The first request for a question: the house rules, then on the explorer the codebase map, the tools and the selection; elsewhere the page. */
  function request(config, ctx) {
    var code = ctx.kind === "code" && canRead();
    var system = code ? SYSTEM + "\n" + READING + "\n\nThe codebase at a glance:\n\n" + B.explorer.map() + "\n\nWhat the reader has selected:\n\n" + ctx.text
                      : SYSTEM + "\n\nWhat the reader is looking at:\n\n" + ctx.text;
    var body = {
      model: config.model, stream: true, temperature: 0.3, max_tokens: 900,
      messages: [{ role: "system", content: system }].concat(
        state.messages.filter(function (m) { return m.role === "user" || (m.role === "assistant" && m.text); }).slice(-HISTORY)
          .map(function (m) { return { role: m.role, content: m.text }; }))
    };
    if (code) { body.tools = B.explorer.tools; body.tool_choice = "auto"; }
    if (config.reasoning && /^mistral-large-4/.test(config.model)) body.reasoning_effort = config.reasoning;
    return body;
  }

  function send(text) {
    text = (text || "").trim();
    if (!text || state.busy) return;
    withConfig(function (config) {
      if (!config) { renderLog(); return; }
      var ctx = context();
      state.messages.push({ role: "user", text: text, about: ctx.label });
      var reply = { role: "assistant", text: "", draft: "", reads: [], pending: true };
      state.messages.push(reply);
      ui.input.value = "";
      fitInput();
      var controller = window.AbortController ? new AbortController() : null;
      state.busy = controller || {};
      renderLog();
      var queued = false;
      function paint() { if (!queued) { queued = true; requestAnimationFrame(function () { queued = false; paintLast(); }); } }
      function onDelta(piece) { reply.draft += piece; reply.pending = false; paint(); }
      var body = request(config, ctx), rounds = 0;
      // A round that asks to read runs those reads here, from the code this page holds, and asks again; its own words are dropped.
      function round() {
        return B.chat.transport(body, config.key, onDelta, controller && controller.signal).then(function (got) {
          var calls = (got && got.toolCalls) || [];
          if (!calls.length || !body.tools) { reply.text += reply.draft; reply.draft = ""; return; }
          reply.draft = "";
          rounds++;
          body.messages.push({ role: "assistant", content: (got && got.content) || "", tool_calls: calls });
          calls.forEach(function (call) {
            var out = B.explorer.tool(call["function"].name, call["function"].arguments);
            if (out.read && !reply.reads.some(function (r) { return r.label === out.read.label; })) reply.reads.push(out.read);
            body.messages.push({ role: "tool", name: call["function"].name, tool_call_id: call.id, content: out.text });
          });
          reply.pending = true;
          paint();
          if (rounds >= ROUNDS) body.tool_choice = "none";
          return round();
        });
      }
      Promise.resolve().then(round).then(function () {
        if (!reply.text) reply.error = "Mistral sent no answer. Ask again, or rephrase.";
      }, function (e) {
        if (e && e.name === "AbortError") reply.note = "Stopped.";
        else if (e && e.status === 401) reply.error = "Mistral refused the key. Run Scripts/site.command again to refresh it, or paste another.";
        else if (e && e.status === 429) reply.error = "Mistral is limiting this key for now. Try again in a moment.";
        else if (e && e.status) reply.error = "Mistral answered " + e.status + ": " + e.message;
        else reply.error = "No answer from Mistral. The chat needs the network; the rest of the site does not.";
      }).then(function () {
        reply.pending = false;
        state.busy = null;
        renderLog();
      });
    });
  }

  // MARK: Showing replies, as text

  function inline(s) {
    var out = [], files = B.explorer && B.explorer.model ? B.explorer.model() : null;
    s.split(/(`[^`\n]+`|\*\*[^*\n]+\*\*|\b[\w+-]+\.swift:\d+\b)/).forEach(function (t) {
      if (!t) return;
      if (/^`[^`]+`$/.test(t)) out.push(h("code", null, t.slice(1, -1)));
      else if (/^\*\*[^*]+\*\*$/.test(t)) out.push(h("b", null, t.slice(2, -2)));
      else if (/\.swift:\d+$/.test(t) && files) {
        var name = t.split(":")[0], hit = files.files.filter(function (f) { return f.name === name; });
        out.push(hit.length === 1 ? h("a", { href: "#" + hit[0].path + ":" + t.split(":")[1], title: "Open it in the explorer" }, t) : t);
      } else out.push(t);
    });
    return out;
  }
  function markup(text) {
    var frag = document.createDocumentFragment();
    text.split("```").forEach(function (block, i) {
      if (i % 2) {
        var code = block.replace(/^[\w+-]*\n/, "").replace(/\n$/, "");
        var pre = h("pre", { class: "chat-code" });
        code.split("\n").forEach(function (line, k) { if (k) pre.appendChild(document.createTextNode("\n")); pre.appendChild(h("span", null, B.highlight(line))); });
        frag.appendChild(pre);
        return;
      }
      block.split(/\n{2,}/).forEach(function (para) {
        para = para.replace(/^\n+|\n+$/g, "");
        if (!para.trim()) return;
        var lines = para.split("\n");
        if (lines.every(function (l) { return /^\s*([-*•]|\d+[.)])\s+/.test(l); })) {
          var list = h(/^\s*\d/.test(lines[0]) ? "ol" : "ul");
          lines.forEach(function (l) { list.appendChild(h("li", null, inline(l.replace(/^\s*([-*•]|\d+[.)])\s+/, "")))); });
          frag.appendChild(list);
        } else if (/^#{1,4}\s/.test(lines[0]) && lines.length === 1) {
          frag.appendChild(h("p", null, h("b", null, inline(lines[0].replace(/^#+\s*/, "")))));
        } else {
          var p = h("p");
          lines.forEach(function (l, k) { if (k) p.appendChild(h("br")); p.appendChild(h("span", null, inline(l))); });
          frag.appendChild(p);
        }
      });
    });
    return frag;
  }
  function bubble(m) {
    if (m.role === "user") return h("div", { class: "chat-msg user" }, m.text);
    var div = h("div", { class: "chat-msg bot" + (m.error ? " error" : "") });
    if (m.reads && m.reads.length) div.appendChild(h("p", { class: "chat-reads" }, ["Read ", m.reads.map(function (r, i) {
      return [i ? " · " : "", r.href ? h("a", { href: r.href, title: "Open it in the explorer" }, r.label) : h("span", null, r.label)];
    })]));
    var shown = (m.text || "") + (m.draft || "");
    if (m.pending && !shown) div.appendChild(h("span", { class: "chat-wait" }, m.reads && m.reads.length ? "Reading more…" : "Reading…"));
    if (shown) div.appendChild(markup(shown));
    if (m.error) div.appendChild(h("p", null, m.error));
    if (m.note) div.appendChild(h("p", { class: "chat-aside" }, m.note));
    return div;
  }
  function paintLast() {
    var last = ui.log.lastElementChild, m = state.messages[state.messages.length - 1];
    if (!last || !m) return;
    last.replaceWith(bubble(m));
    ui.log.scrollTop = ui.log.scrollHeight;
  }
  function renderLog(after) {
    var log = ui.log;
    log.textContent = "";
    withConfig(function (config) {
      state.config = config;
      log.textContent = "";
      if (!config) { log.appendChild(setup()); syncControls(); if (after) after(); return; }
      var ctx = context(), lastAbout = null;
      if (!state.messages.length) {
        log.appendChild(h("p", { class: "chat-msg note" }, ctx.kind === "code" ? "Ask about the code you have selected. The chat starts there, and reads the rest of the codebase when a question reaches past it." : "Ask about this page. The answer reads what the page shows."));
        log.appendChild(h("div", { class: "chat-starters" }, starters(ctx.kind).map(function (q) {
          var b = h("button", { type: "button" }, q);
          b.addEventListener("click", function () { send(q); });
          return b;
        })));
      }
      state.messages.forEach(function (m) {
        if (m.role === "user" && m.about !== lastAbout) { log.appendChild(h("p", { class: "chat-msg note" }, "About " + m.about)); lastAbout = m.about; }
        log.appendChild(bubble(m));
      });
      ui.foot.textContent = "";
      ui.foot.appendChild(document.createTextNode(config.model + " via Mistral, with " + (config.source || "a key") + ". It reads what you see here, and it can be wrong."));
      if (config.source === "a key pasted in this browser") {
        var forget = h("button", { type: "button", class: "chat-link" }, "Forget the key");
        forget.addEventListener("click", function () { state.pasted = ""; B.storage.set("chat:key", ""); renderLog(); });
        ui.foot.appendChild(document.createTextNode(" "));
        ui.foot.appendChild(forget);
      }
      log.scrollTop = log.scrollHeight;
      syncControls();
      if (after) after();
    });
  }
  function setup() {
    var field = h("input", { type: "password", autocomplete: "off", spellcheck: "false", placeholder: "Mistral API key", "aria-label": "Mistral API key" });
    var use = h("button", { type: "button" }, "Use this key");
    function take() {
      var key = field.value.trim();
      if (!key) return;
      state.pasted = key;
      B.storage.set("chat:key", key);
      renderLog();
      ui.input.focus();
    }
    use.addEventListener("click", take);
    field.addEventListener("keydown", function (e) { if (e.key === "Enter") { take(); e.preventDefault(); } });
    ui.foot.textContent = "";
    return h("div", { class: "chat-setup" }, [
      h("p", null, "The chat needs a Mistral key. Open the site with Scripts/site.command and it uses this Mac's Ambient key, or paste one here. A pasted key stays in this browser."),
      h("div", { class: "chat-keyrow" }, [field, use])
    ]);
  }
  /** Forgets the conversation, stopping an answer in progress. Each question reads the page afresh, so nothing else carries over. */
  function newChat() {
    if (state.busy && state.busy.abort) state.busy.abort();
    state.messages = [];
    renderLog(function () { if (!ui.input.disabled) ui.input.focus(); });
  }
  function syncControls() {
    var busy = !!state.busy, ready = !!state.config;
    ui.reset.disabled = !state.messages.length;
    ui.send.textContent = busy ? "Stop" : "Send";
    ui.send.setAttribute("aria-label", busy ? "Stop the answer" : "Send");
    ui.input.disabled = !ready;
    ui.send.disabled = !ready;
  }

  // MARK: The orb and the panel

  function updateAbout() {
    if (!ui.about) return;
    var ctx = context();
    ui.about.textContent = "About " + (ctx.kind === "code" ? ctx.label : "this page: " + ctx.label);
    ui.input.placeholder = ctx.kind === "code" ? "Ask about this code" : "Ask about this page";
  }
  function fitInput() { ui.input.style.height = "auto"; ui.input.style.height = Math.min(ui.input.scrollHeight + 2, 128) + "px"; }
  function open() {
    ui.panel.hidden = false;
    ui.orb.hidden = true;
    ui.orb.setAttribute("aria-expanded", "true");
    updateAbout();
    renderLog(function () { (ui.input.disabled ? ui.panel.querySelector(".chat-setup input") || ui.close : ui.input).focus(); });
  }
  function close() {
    ui.panel.hidden = true;
    ui.orb.hidden = false;
    ui.orb.setAttribute("aria-expanded", "false");
    ui.orb.focus();
  }
  function mount() {
    if (ui.orb || !document.body || document.body.classList.contains("embed")) return;
    ui.orb = h("button", { type: "button", class: "chat-orb", "aria-label": "Ask about what you are reading", title: "Ask about what you are reading",
                           "aria-expanded": "false", "aria-controls": "chat-panel" });
    ui.about = h("span", { class: "chat-about" });
    ui.close = h("button", { type: "button", class: "chat-close", "aria-label": "Close the chat", title: "Close (Esc)" }, "×");
    ui.reset = h("button", { type: "button", class: "chat-new", title: "Forget this conversation and start again", disabled: true }, "New chat");
    ui.log = h("div", { class: "chat-log", "aria-live": "polite" });
    ui.input = h("textarea", { rows: 1, "aria-label": "Your question", spellcheck: "true" });
    ui.send = h("button", { type: "submit" }, "Send");
    ui.foot = h("p", { class: "chat-foot" });
    var form = h("form", { class: "chat-form" }, [ui.input, ui.send]);
    ui.panel = h("section", { class: "chat", id: "chat-panel", role: "dialog", "aria-label": "Ask about what you are reading", hidden: true }, [
      h("div", { class: "chat-head" }, [h("span", { class: "chat-dot", "aria-hidden": "true" }), h("span", { class: "chat-title" }, [h("b", null, "Ask"), ui.about]), ui.reset, ui.close]),
      ui.log, form, ui.foot
    ]);
    ui.orb.addEventListener("click", open);
    ui.close.addEventListener("click", close);
    ui.reset.addEventListener("click", newChat);
    ui.panel.addEventListener("keydown", function (e) { if (e.key === "Escape") { close(); e.preventDefault(); } e.stopPropagation(); });
    form.addEventListener("submit", function (e) {
      e.preventDefault();
      if (state.busy) { if (state.busy.abort) state.busy.abort(); return; }
      send(ui.input.value);
    });
    ui.input.addEventListener("keydown", function (e) { if (e.key === "Enter" && !e.shiftKey && !e.isComposing) { e.preventDefault(); form.requestSubmit ? form.requestSubmit() : form.dispatchEvent(new Event("submit")); } });
    ui.input.addEventListener("input", fitInput);
    window.addEventListener("braid:context", updateAbout);
    document.body.appendChild(ui.orb);
    document.body.appendChild(ui.panel);
  }

  B.chat = {
    transport: mistral, open: function () { if (ui.orb) open(); }, close: function () { if (ui.orb) close(); }, newChat: function () { if (ui.orb) newChat(); }, context: context, request: function (ctx) { return request(DEFAULTS, ctx || context()); },
    selfCheck: function () {
      var ctx = context(), body = request(DEFAULTS, ctx);
      return [
        { name: "the chat reads what the reader is looking at", ok: !!(ctx && ctx.text && ctx.text.length > 40 && ctx.text.length < 30000), detail: ctx ? ctx.kind + ", " + ctx.text.length + " characters" : "" },
        { name: "a request carries the context and the house rules, and nothing calls the network until a message is sent", ok: body.messages[0].role === "system" && body.messages[0].content.indexOf(ctx.text.slice(0, 60)) >= 0 && !state.messages.length },
        { name: "on the explorer, a request also carries the codebase map and the tools that read the rest", ok: ctx.kind !== "code" || (body.tools && body.tools.length === 4 && body.messages[0].content.indexOf("The codebase at a glance") >= 0),
          detail: ctx.kind === "code" ? Math.round(body.messages[0].content.length / 1000) + " thousand characters of system message" : "not on the explorer" }
      ];
    }
  };
  B.extraChecks.push({ name: "chat", run: B.chat.selfCheck });
  mount();
})();
