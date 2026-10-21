# Braid, step by step

A guided tour of Braid in plain HTML: the whole machine in one picture, then eleven chapters, each a question, with figures that compute with the real formulas and a token-by-token replay of real session logs. Double-click `Scripts/site.command`, or open `index.html` in a browser. Nothing to install, no build step, no network.

| Need | What for |
|---|---|
| A browser (Chrome is what the checks run) | reading the site from `file://` |
| Python 3 with `playwright`, `tokenizers`; Google Chrome | regenerating data, figure pages, exports; running the checks |
| The pack's tokenizer (`Examples/.work/packs/*/tokenizer/tokenizer.json`, or the T9) | `src/data.py --refresh` only |
| The machine's AII home (`~/.rao`) | the lane-filtered storage fixture, `src/data.py --refresh --aii-home ~/.rao` only |

## Rebuilding

```
python3 -I Docs/site/src/data.py                 # data/*.js from the committed fixtures
python3 -I Docs/site/src/data.py --refresh       # also copies the playground run from Examples/.work (and ~/.rao with --aii-home)
python3 -I Docs/site/src/sources.py              # data/sources/*.js: every Swift file under Sources/, its scopes, the calls and the trails
python3 -I Docs/site/src/sources.py --self-test  # the Swift parser against the shapes it must survive
python3 -I Docs/site/src/chatkey.py              # the chat orb's key, from ~/.rao, into local/chat.js (gitignored); Scripts/site.command runs it
python3 -I Docs/site/src/figures.py              # figures/<id>.html, one per figure on the chapter pages
python3 -I Docs/site/src/export.py               # export/<id>@2x.png, -dark@2x.png, .svg
python3 -I Docs/site/src/check.py                # every page from file://, both themes, self-checks, links, lint, prose, size, spacing, slider drags
```

`src/build.sh` runs data, sources, figures and the check in that order. Every generated file starts with a comment naming the script and its inputs; do not edit generated files by hand.

`src/export.py --blog-assets <dir> --post <slug> --only <id,id,…>` copies chosen figures into a blog's asset folder as `NN-<id>.svg` (or `.png`) and writes `captions.md`, one line per figure in the form `![caption](/blog-assets/<slug>/NN-<id>.svg "float-right")`.

## The constraints a page lives under

The site is read from `file://`. In Chrome that means `fetch()` of a local file is blocked and `<script type="module">` imports are blocked, so:

- data is loaded with classic `<script src="data/….js">` tags; every data file begins `window.BraidData = window.BraidData || {};` and assigns into it, so load order among data files does not matter;
- code is classic scripts on one global, `window.Braid`; `js/braid.js` and `js/model.js` load first, then `js/figures/*.js`, and `Braid.mount()` is the last script in `<body>`;
- there are exactly two globals, `Braid` and `BraidData`;
- every URL is relative. The one network call is the chat orb's, to Mistral, made only when the reader sends a message (`js/chat.js`); the rest of the site works offline;
- `localStorage` may be unavailable, so every read and write is wrapped in `try/catch` and the page works without it;
- `crypto.subtle` is used for SHA-256 with a pure-JS fallback.

`src/check.py` lints for all of this.

## Page conventions

```html
<body>
  <a class="skip" href="#main">Skip to the chapter</a>
  <header class="top">…chapter title, prev/next…</header>
  <nav class="side">…the overview, the eleven questions, then the appendices…</nav>
  <main class="page" id="main">
    <h1 id="ch-<slug>">The question</h1>
    <p class="lede"><em>One italic line saying what the chapter is about.</em></p>
    <p class="step-link">The playground, step N · <a href="…">…</a></p>
    <p>Prose…</p>
    <figure class="fig float-right" data-fig="<name>" data-s="<session>" data-i="<step>" id="fig-<name>">
      <figcaption>One sentence that could stand alone.</figcaption>
    </figure>
    <figure class="board float-left" data-board="<id>"></figure>
    <div class="code" data-code="<excerpt-id>"></div>
    <details class="explore" id="explore-<name>"><summary>Explore: …</summary>…</details>
    <details class="engineers"><summary>For model engineers</summary>…</details>
    <nav class="prevnext">…</nav>
  </main>
</body>
```

Ids: `ch-<slug>` on the chapter heading, `fig-<name>` on figures, `explore-<name>` on expanders, `status-<test>` on status rows, `crop-<id>` on the boards page. Figure names are nouns in kebab-case. The `float-right` and `float-left` classes float a figure beside its paragraph on wide screens; under 1100 px everything stacks in reading order.

## Deep links

- `#ch-<slug>` scrolls to a chapter heading; `#fig-<name>` to a figure.
- `#fig-<name>;key=value;key2=value2` also sets that figure's state (one figure per hash), for example `07-inference.html#fig-replay;s=c809fc97;i=10`.
- `figures/<name>.html?s=c809fc97&i=10&theme=dark` is the same figure on its own page for an iframe; `?export=1` hides the controls.
- Every figure has a copy-link glyph and an open glyph.

## Data files

`data/sessions/<slug>.js` sets `BraidData.sessions[<slug>]`:

```js
{ slug, label, file, sha256,
  lines: ["{…}", …],                       // the JSONL lines verbatim, so the body hash can be recomputed
  header, gen, steps: [...], end }         // the same lines parsed: header, gen, every tok (steps[i].i === i), end
```

A `tok` step carries `i, tok, txt, src, p, lam, cand?, stop?, thr?`; `thr[t]` carries `mem, w, open, plm, pknn, share, Hlm, Hknn, ev?, mod?, sg, ss, hits: [[entry, score, value, row, offset, loss], …], tr?`. Step 0 is the eos opener and has no `thr`. The strand order is `gen.strands`, which equals `header.threads.map(t => t.name)`.

`data/threads/<name>.js` sets `BraidData.threads[<name>]`:

```js
{ name, label, source, corpusHash, threadID, snapshot: { file, sha256, exportedAt, documentCount, partitionCount },
  eos: 0, break: [535],
  documents: [{ id, name, rows: [row, …] }],
  partitions: [{ row, doc, index, textSHA256, text, tokens: [id, …], offsets: [charOffset, …] }],   // offsets has tokens.length + 1 entries
  layout: { rule: "L-1", entryBase: [entryOfFirstPositionOfDocument, …] } }
```

A hit's `(row, offset)` is the address of the value token: `partitions[rowOffset + row].tokens[offset] === value`, and an offset equal to the token count is the break after that partition (value 535). A hit's `entry` is `entryBase[doc] + position - 1` within its document, where a document's positions run over `eos ‖ p0 ‖ break ‖ p1 ‖ … ‖ eos` and a document contributes `L − 1` entries.

`data/harbour.js` sets `BraidData.harbour` (training steps and evals, `version`, `index`, `checkpoints`, `thread`, `braidToml`, `provenance`). `data/claims.js` sets `BraidData.claims` (PAPER.md's tables). `data/code.js` sets `BraidData.code[<id>] = { path, lines: [from, to], highlight: [...], text, commit }`. `data/aii-store.js` sets `BraidData.aiiStore` (the playground lane's stored form). `data/manifest.js` sets `BraidData.manifest` (sources, hashes, counts, check results).

## Size budget

Tracked bytes under `docs/site` stay under 6 MB: data ≤ 1.8 MB, sources ≤ 1.6 MB, fixtures ≤ 0.4 MB, pages, css and js ≤ 1.0 MB. `data/sources/` is its own bucket, the code explorer's verbatim Swift; `src/sources.py` fails when it would pass its budget. `export/` and `.check/` are regenerable and gitignored.

## The boards

The four architecture boards are the site's own figures, drawn as panels. `js/boards.js` is the kit: `Braid.draw` (svg, box, arrow, line, text, frame), `Braid.panel` (list, cards, tiles, table, formula, detail, note) and `Braid.boards`, whose `define(id, spec)` registers a panel as the figure `board:<id>` with four fields of its own, `board`, `title`, `caption` and `chapter`, and whose `reuse(name, fixed, spec)` wraps a chapter figure with fixed settings. `js/boards/board-N.js` holds board N's panels; a panel that reads data (the Joltvault log, `claims.js`, the harbour version) checks itself against it.

A page shows a panel with `<figure class="board" data-board="<id>">`. `Braid.mount` turns it into an ordinary figure, with chrome, deep links, a figure page, export and its self-check; the caption is the panel's unless `data-caption` says otherwise, and it links to the panel's cell on `boards.html` (from there, to its chapter: to the panel's own id, or to `anchor`, the id of the chapter figure a reused panel repeats). `boards.html` is the registry of placement: every defined panel sits there once, in a `div.cell#crop-<id>`, so the old `#crop-<id>` links still land. To change a panel, edit its `render` in `board-N.js`; to add one, define it and give it a cell. The checks: `check.py`'s `check_boards` (the defined set equals the page's set, once each; every `data-board` on every page is defined; no `boards/` folder, `boards.py` or `crops.json` remains), and the kit's own checks (board, a chapter that exists, a caption in the site's voice), which `boards.html`, `selftest.html` and `code.html` report through `Braid.selfCheck()`.

## Figure pages

`src/figures.py` reads every `<figure class="fig" data-fig>` on the chapter pages, and every `<figure class="board" data-board>` on them and on `boards.html`, and writes the same figure, with the same settings, caption and scripts, to `figures/<id>.html` with no site chrome. The chapters are the registry, so a figure page cannot drift from its chapter. `src/code.json` lists the Swift excerpts the pages quote, each with anchor strings that must still be inside its line range, so a refactor that moves the code fails `data.py` instead of quoting the wrong lines.

## The code explorer

`code.html` holds every Swift file under `Sources/`, verbatim, in a file tree, with each file's declarations as scopes, four trails traced function by function, and "calls" and "called by" for every declaration. The trails are training, from an app's records in AII to a Thread node, and inference, from a prompt to a checked answer, then the same two for questions: Q/A training, how a Thread comes to hold its facts and how the question bench measures them, and Q/A inference, from a question to a cited answer.

- `src/sources.py` writes it. It is a lexer and a walk over the braces, not a compiler: it counts every file's declarations twice, by the walk and by their keywords, and fails the build when the two disagree. `--self-test` runs it against the shapes it must survive; `--dump <file>` prints one file's scopes; `--stats` lists the call names it could not resolve.
- Calls are matched by name and argument labels. Every edge carries a tier, and the page shows it: **exact** when the type is named or implied and one declaration fits, **likely** when the name and labels are unique but the receiver's type was not read, **ambiguous** when two to eight fit, all listed. A small list of names that are also Swift, Foundation or MLX methods (`append`, `map`, `encode`…) keeps only exact edges.
- `src/trails.json` holds the four trails: training, inference, Q/A training and Q/A inference. Each has a `title`, a `mark` for its badges in the tree (T, I, QT and QI, so T3 is step 3 of training), a `subtitle` and a `say` line for the page, then its steps: per step, the declarations in call order, each with an `anchor` that must still be inside it, a one- or two-sentence `note` in the site's voice, and a `cite` (`ARCHITECTURE.md#<heading>`, `PIN` or `WHAT`). A declaration sits on a trail once at most, and may sit on several, with a note for each. `"link": "none"` marks an entry that neither calls nor is called by the one before it, so the build's warning about a broken chain stays quiet there. Like `code.json`, a refactor that moves an anchor fails the build. The notes are rendered at runtime, so `sources.py` runs the banned-phrase and parenthesis rules on them itself.
- `data/sources/<Module>.js` sets `BraidData.sources[<Module>] = { module, files: [{ path, lines, bytes, header, marks, first, scopes, text }] }`. A scope is `[kind, name, labels, mods, decl, sig, brace, end, doc, parent, flags, cases?]`: `kind` one of `f i d s v S C E A X P`; `decl` the first line, attributes included; `sig` the line with the keyword; `brace` `[line, column]` or null for a protocol requirement; `doc` the `///` lines; `parent` an index in the same file or −1; `flags` 1 requirement, 2 operator, 4 local, 8 one line. `data/sources/index.js` holds the file list, the counts, `sample` ids, `edges` as `[from, to, tier, line, count]` over global scope indices, and `trails`, the four trails as `sources.py` resolved them.
- Ids are derived, never stored: the path without `Sources/`, a colon, the qualified name, and the argument labels for a callable, such as `BraidCore/Mixture/Gate/Gate.swift:Gate.observe(_:likelihoods:module:settings:)`. Python and the page derive them alike, and the page's self-check compares the two on `sample`.
- `check.py` does not lint `data/sources/`, since the Swift in it may say `fetch(` or `http`. It checks instead that each file is exactly the generated shape and that every embedded text equals the working tree, so a Swift edit without a rebuild fails the check.
- Deep links: `code.html#Sources/<path>.swift` opens a file, `…swift:<line>` the declaration at that line, `…swift:<qualified(labels:)>` a declaration by its id, `#trail-<trail>-<n>` or `#trail-<trail>-<n>;n=<k>` a step of a trail, such as `#trail-inference-5` or `#trail-qa-inference-2`, and `#q=<text>` a search. An older link, `#trail-<n>`, still lands: it opens what the overview's step n opens, since each overview step names its trail step as `code`. Every excerpt in a chapter links to its lines here.

## The chat orb

Every page but an embedded figure has an orb at the bottom right, half seen until a pointer or focus finds it. It opens into a mini chat about what the reader is looking at, and Esc or × folds it back. "New chat" forgets the conversation and stops an answer in progress; every question reads the page afresh, so nothing else carries over.

- **What it reads.** On `code.html`, the selected declaration: its code with Xcode's line numbers, its doc comment, its file's WHAT and PIN, its trail step and note, and its calls and callers with their tiers (`Braid.explorer.context()`). On any other page, the page's visible text. The panel's header names what it reads, and follows the explorer's selection.
- **The rest of the codebase, on the explorer.** Every request there also carries a map of the codebase, `Braid.explorer.map()`: every file with the first sentence of its WHAT, folder by folder, and every trail step by step, about 24,000 characters. The model also gets four tools that read the rest, `Braid.explorer.tools`: `find_declarations`, `read_declaration`, `search_text` and `read_file`. The page runs them itself, from the sources it already holds, so a read costs no extra call. A question gets up to five rounds of reading before the model must answer. Words from a round that only reads are dropped, and the answer lists what was read, each a link to that place in the explorer. On 2026-10-18 a question on where `Gate.observe`'s memory is read took three rounds and six reads, from `Gate.weights` to `Mixer.shares`, before it answered. Each round resends the map, so a question that reads costs a few cents.
- **The model.** `mistral-large-4`, called from the browser at `https://api.mistral.ai/v1/chat/completions`, which allows any origin, `file://` included. Its reasoning is off, as Sewn runs it: left on, Large 4 spent its tokens reasoning and many of Ambient's replies came back empty (AII's `ModelConfig`, 2026-10-17). Replies stream in, and are shown as text with a few marks of markdown, never as HTML. A reply's `File.swift:line` on the code page links to that line.
- **The key.** `src/chatkey.py` copies this Mac's `MISTRAL_API_KEY`, the one Ambient wrote to `~/.rao/keys/providers.json`, into `local/chat.js` with mode 600. `.gitignore` keeps `local/` out of git in both spellings of the folder, and `check.py` fails if git would track it. `Scripts/site.command` runs the script each time it opens the site. Without the file the orb asks for a key; a pasted key stays in that browser's storage, with a "Forget the key" link beside it.
- **The checks never call Mistral.** Every browser run blocks the endpoint, and the orb's test swaps `Braid.chat.transport` for a stand-in: half seen, whole under the pointer, open, ask, answer, new chat, Esc back to the orb. On the explorer the stand-in asks to read `Mixer.mix` once; the test checks that the first request carried the map and the four tools, the second carried the read, and the answer lists it. The lint allows `fetch` in `js/chat.js` alone, to that one URL.

## The voice

The prose is written the way the owner writes on paka.la; `00-entropy.html` and `07-inference.html` are the reference pages. `index.html` is the overview, the page the site opens on.
- Say the idea first, in one plain sentence, then earn it. One move per paragraph, ending on the sentence worth quoting.
- Concrete before abstract. The running text carries the one number that is the point; the rest live in the figure and its caption.
- One analogy for an idea, in one sentence, then drop it.
- Short sentences at the turns. Headers are short noun phrases; chapter titles are questions.
- Fairness, then the critique, then the limit, each in its own place. The limit is said once, plainly.
- Every figure carries one caption sentence that could stand alone.
- Never: announcing the chapter, saying a thing twice in two registers, hedging words, a parenthesis inside a paragraph, a term before its plain word. Depth goes in the closed "For model engineers" blocks, the "Explore" blocks and the appendices.
- Every number says when it was measured and which test or bench stands behind it. RaoLM's transformer numbers never appear as Braid results.

`src/check.py --prose` fails on the banned phrases and on a parenthesis in a paragraph, and lists long sentences, long paragraphs and number-heavy paragraphs for a human eye.
