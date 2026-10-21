# The braid command

`braid` with no arguments, in a terminal, opens the studio. Everywhere else it prints its help. Every subcommand is a tool for training or testing the braid, and every one takes `--work-area` where it reads or writes data.

Run it through `Scripts/cli.sh`, which:
- builds the binary (`BRAID_CONFIG=release` builds release; `BRAID_SKIP_BUILD=1` skips the build);
- installs `mlx.metallib` beside it;
- points SwiftPM's AII dependency at `../AII` when that checkout exists.

## Where data lives

The work area is chosen in this order:
1. `--work-area`;
2. `BRAID_WORK_AREA`;
3. `/Volumes/T9/rao/projects/braid` when the T9 is mounted.

Otherwise the command refuses.

Layout under the work area:
- `braid.toml` (written by `braid init`)
- `packs/<sha12>/`
- `models/huggingface/`
- `threads/<name>/{thread.json, live.json, snapshots/, versions/vNNNN/}`
- `sessions/*.jsonl` (with `.verify.json` beside them)
- `bench/<bench>/`
- `logs/`

Datasets come from `BRAID_DATASETS_DIR`, else `<work area>/datasets`, else `/Volumes/T9/rao/projects/raolm/datasets`.

Demo AII homes live under `<repo>/aii/<name>` (`BRAID_DEMO_HOMES` overrides). They must be on APFS, because AII provisions homes with hard links.

## Commands

### Setup

| Command | What it does |
|---|---|
| `braid doctor` | Checks the Metal library, the work area and its free space, `braid.toml`, the pack (hashes re-derived), the tokenizer round trip, the trunk (the commons' seam, which every Thread's live version must name, and its cut), and the machine's AII (home, lanes, Thread health). Also the AII contract this build links against what is installed and served, the installed AIIServer against `install.json`'s SHA-256, and the demo AIIs and their ports. Exits 1 if any check fails. |
| `braid init [--base <pack\|hf-id>] [--force] [--measure]` | Imports the pack if `--base` is a Hugging Face id, validates it, writes `braid.toml` and prints the storage table: a Thread node's head (blocks 0..<cut) and the commons' trunk (blocks cut..<L, the embedding, `norm_f`), which every Thread runs by reference. `--measure` times the trunk on this machine: forward tokens per second, one training step, and peak memory, at B×L 4×512, 8×512, 4×1024 and 8×1024, for chunk sizes 256 and 128. With an existing `braid.toml` it only measures. The report goes to `bench/measure/`. |
| `braid import <hf-id\|dir> [--revision R] [--name N] [--cut N] [--tap N] [--check]` | Converts a pretrained Mamba2 checkpoint into a pack: F32, tied, the tokenizer's SHA-256, padding rows masked. `--check` runs a greedy sample and the held-out loss and records them. |
| `braid pack list` · `braid pack show <ref>` | The packs; `show` re-derives the hashes and prints the split, a Thread node and the commons' trunk. |

### Threads

| Command | What it does |
|---|---|
| `braid thread create <name> --corpus <src> [--limit N] [--label L] [--scheme S] [--no-train] [--steps N] [--batch B] [--seq-len L] [--withhold F] [--seed S] [--no-attach]` | Snapshots the corpus, trains the Thread's own blocks 0..<cut behind the commons' trunk (unless `--no-train`, which indexes the pack's own blocks), indexes the snapshot, makes the version live and adds the Thread to `[cluster] attach`. The commons is built first, since every head runs behind its trunk. Sources: `dataset:<name>#<node>`, `dir:<path>`, `aii:<aii>/<lane>` (Braid's corpus deposited in a lane), or `app:<aii>/<app>` (the records an app filed in its own lane). `--withhold F` trains on every document but leaves a seeded fraction F out of the index, recorded as `excluded` in `index.json`; re-index and sync keep them out. `--seed` sets the training seed. |
| `braid thread sync <name> [--no-train] [--steps N]` | Reads the Thread's source again. If the corpus hash changed, it prints what was added, removed and changed, trains on from the live blocks (500 steps by default), and indexes a new live version. |
| `braid thread index <name> [--scheme S] [--checkpoint-every-partition]` | Keys the live version again under another key scheme, or with a checkpoint at every partition boundary, as a new live version. Nothing is trained. |
| `braid thread list` · `braid thread show <name>` | The Threads and their live versions. |

Key schemes are `residual:<n>` (the residual stream after n blocks), `pooled-state:<layer>` and `state-delta:<layer>`.

### The braid

| Command | What it does |
|---|---|
| `braid` · `braid ui [--fixtures DIR]` | The studio (see below). `--fixtures` (or `BRAID_UI_FIXTURES`) replays a recorded session with no MLX and no work area. |
| `braid chat "<prompt>" [--threads a,b] [--no-question] [--lambda 0.5] [--max-tokens 24] [--temperature 0] [--json]` | One turn of the braid. A prompt ending in `?` is a question: the commons rewrites it into a stem, each Thread finds its own context sentence, and the answer stops at the sentence's end. Any other prompt is completed as written. Prints the per-token block, or the session's lines with `--json`. Without a prompt it opens the studio. |
| `braid cluster spawn --prompt "<text>" [--threads a,b] [--attach name@pos …] [--detach name@pos …] [--no-commons] [--max-tokens 24] [--lambda 0.5] [--temperature 0] [--json]` | One generation with scripted membership. The commons is loaded first and its trunk named once, since every Thread runs behind it; `--no-commons` leaves the commons' strand out of the braid and keeps its trunk. A Thread attached at generated position *pos* catches up on the session in one forward pass and joins at the next token boundary. A detached one leaves there. |
| `braid verify <session.jsonl> [--live] [--keys [--all-hits]] [--no-write]` | Replays a session log: body hashes, share arithmetic, the gate's memory recursion, the shadow gate, every Thread's trace, and every verbatim span re-read from its source. `--live` re-reads spans from the AII lane that holds the document, as it stands now: Braid's corpus there, or the app's records. `--keys` recomputes every cited hit's key from the nearest state checkpoint; `--all-hits` extends that to every logged hit. Writes `<session>.verify.json`. |
| `braid credit <session.jsonl> [--json]` | Derives views from a log: credit, the followed-credit decision per sentence, and royalties by Thread and by cited document. |
| `braid import-raolm <dump> [--arm A] [--out DIR] [--check]` | Converts RaoLM's trajectory-bench dump (one `CitedGeneration` per scored text, made with `raolm braid bench-trajectory --dump`) into Braid session logs with `source: raolm`, under `/Volumes/T9/rao/projects/braid/raolm-import` by default, with an `import.json` that records every field mapping. `--arm` takes `base` or one gate arm by name or directory. `--check` validates the port instead: (a) RaoLM's logged shares recomputed, (b) RaoLM's chains replayed by Braid's tracker over RaoLM's own indices, (c) phase A, which re-scores T1–T3 and regates RaoLM's logs under Braid's live gate. It writes `check.json` and exits 65 if a check fails. `braid verify` reads an imported log without a work area; the memory recursion, shadow and spans do not apply and are listed as skipped. |

### Benches

Each bench's rules are fixed in code before its numbers. Each writes a dated JSON report under `bench/<bench>/` and keeps its session logs so `braid verify` can replay them. Common options:
- `--rescore <report>` re-applies the rules to a saved report without running a model.
- `--module-gain κ` sets the trajectory module's weight in the gate for one run, without touching `braid.toml`. It is recorded in the report and the session header.
- `--copy a,b` names two Threads that hold the same documents; G3 and Q5b run on a braid of the commons and these two.

| Command | Rules |
|---|---|
| `braid bench trace` | T1–T3: the trace tells a Thread's own text from shuffles, collages and its voice. Reports the holder's share of told and source answers under the live gate and under the shadow β4. |
| `braid bench gaming` | G1–G3: on unknown subjects and generic text, every Thread stays open and the largest gate stays bounded; copies tie. |
| `braid bench lift` | L1–L4: the commons leads text nobody holds; inherited knowledge is not attributed; the owner's lift carries its facts. Held-out loss against the commons alone is reported. |
| `braid bench stitched [--withheld T]` | S1–S3: the trajectory module's stitched signature fires on documents a Thread trained on but withheld from its index (`thread create --withhold`), and not on unseen, unrelated or indexed text. |
| `braid bench entropy` | E1–E3: the entropy path's coherent runs (H_knn ≤ ln 2 for 24 positions) against the trace, on the trace bench's texts. |
| `braid bench question` | Q1–Q5b: each fact's first question through the path `braid chat` uses, against the stored stem, the corpus slice and a paraphrase; retold facts (Q5a) and copied facts (Q5b). |
| `braid bench replacement` | R1–R3, the owner's replacement criterion: sessions A (κ 0, shadow β4 logged) against B (κ > 0), read from saved trace and gaming reports and B's verify reports. It reads only and deletes nothing. |
| `braid bench sweep-key --thread <name> [--arms …] [--sample 2000] [--facts N]` | Re-indexes one Thread under each key scheme. For each scheme it reports the document-identity probe and fact retrieval at the prompt's last token (partition@1, offset@1, answer@1, answer mass) for the corpus prompt, the question stem and a paraphrase. It names a winner, and whether the +0.02 rule would ship it. |

### AII

| Command | What it does |
|---|---|
| `braid aii status` | The machine's AII (`~/.rao`, or `AII_HOME`) and every demo AII: home, lanes, Thread health. |
| `braid aii create <name> [--at PATH] [--ports http,grpc] [--server BIN]` | Provisions a demo AII home and starts its Thread on the first free port pair of the plan (47181/47190, 47281/47290, …). The home goes under `<repo>/aii/<name>` by default and must be on APFS. The embedder snapshot is shared from `~/.rao/models/huggingface` by symlink. The server is `BRAID_AII_SERVER`, else `~/.rao/aii/bin/AIIServer`. |
| `braid aii start <name>` · `braid aii stop <name>` | Starts (or adopts) or stops a demo AII's Thread. |
| `braid aii ingest <aii>/<lane> --from dataset:<name>#<node>\|dir:<path> [--limit N] [--batch 16]` | Deposits documents into a lane under the owner `braid` and the group `braid-<lane>`, with one tag, partitions in order and `braid://` URLs. Waits until every document is exported. |
| `braid aii wipe <aii>/<lane> --yes` | Removes Braid's documents from a lane by their exported ids. It never sends an empty list, which AII would read as "everything". |

## The studio

There are three screens: **1 Braid** (the main screen), **2 AII** and **3 Doctor**.

The Braid screen shows:
- the answer, coloured by the strand that supplied each token;
- the token detail block: who supplied the token, every share, p and the gate's entropy; the trace and the two entropies with their one-step changes, and the shadow β4 share; the citation and its verification;
- the Threads, with live share bars; the Commons row names the trunk every Thread runs, by its seam;
- the royalties;
- the prompt and the events.

| Key | Action |
|---|---|
| `⏎` | Ask (a trailing `?` goes through the question path while Q/A is on) |
| `/` | Edit the prompt |
| `tab` / `⇧tab` | Focus a Thread |
| `space` | Attach or detach the focused Thread at the next token boundary |
| `n` | A new Thread (name and source) |
| `R` | Royalties: shares or credit |
| `←` `→` | Walk the tokens |
| `v` | Verify the spans |
| `o` | Open a saved session and replay it |
| `x` | The next example prompt |
| `r` | Q/A on or off |
| `t` | Likeliest token or sampled |
| `-` `+` | λ |
| `c` | Cancel |
| `1`–`3`, `?`, `q` | Screens, every key, quit |

Display variables:
- `BRAID_COLOR=truecolor|256|16|none` sets the colour depth.
- `BRAID_ASCII=1` draws ASCII glyphs.
- `BRAID_NO_ITALIC=1` turns italics off.
- `BRAID_UI_THEME=terminal` keeps the terminal's own background.

What libraries print goes to `<work area>/logs/studio.log`.

## Environment

| Variable | Meaning |
|---|---|
| `BRAID_WORK_AREA` | The work area. |
| `BRAID_DATASETS_DIR` | Where braid datasets live. |
| `BRAID_DEMO_HOMES` | Where demo AII homes live (default `<repo>/aii`). |
| `BRAID_AII_SERVER` | The AIIServer binary for demo AIIs. |
| `AII_HOME` | The machine's AII home (default `~/.rao`), passed through. |
| `BRAID_NO_UI` | Print help instead of opening the studio. |
| `BRAID_UI_FIXTURES` | Fixtures for the studio. |
| `BRAID_CONFIG`, `BRAID_BUILD`, `BRAID_SKIP_BUILD`, `BRAID_METALLIB` | `Scripts/cli.sh`: build configuration, rebuild, skip the build, reinstall the Metal library. |
| `BRAID_MLX_TESTS` | `Scripts/test.sh`: run the GPU suites (default 1). |
| `BRAID_AII_TESTS` | Run the live AII tests. The machine's AII and every demo AII must be running (`braid aii start <name>`). |

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | `braid doctor` found a failing check |
| 3 | `braid verify`: a span no longer matches its source |
| 64 | Usage |
| 65 | Bad data: a log that does not replay, a hash that does not match |
| 66 | Missing input |
| 69 | Unavailable: an AII that does not answer |
| 70 | Internal error |
| 73 | Already exists |
| 75 | Temporary: retry, for example while an AII's embedder is loading |
| 78 | Configuration |
| 130 | Interrupted |
