# The Braid playground

One program, read top to bottom, that runs the whole loop on this Mac:

1. **Join AII as an app.** The playground is an app of its own on the Ambient Intelligence Index, `braidplayground`. `AIIInstance(PlaygroundApp.self).join()` registers its lane (a secret, and an entry in `~/.rao/aii/lanes.json`) and adopts the Mac's running Sewn and Thread.
2. **Record test data.** `LogEntry` is an `AIIRecordable` structure. `remember` files 18 invented harbour-log entries in the app's lane, as `braidplayground/log/<id>`, and AII's own search finds them.
3. **A Braid work area** of its own, `Examples/.work`, with the commons' pack.
4. **Train one Thread** on the app's records:

   ```swift
   ThreadRecipe("harbour", corpus: .app("home/braidplayground"))
       .training(.on(steps: 300, seqLen: 128))
   ```

   The recipe is planned, then built.
5. **A braid:** the commons and the `harbour` Thread under one reed.
6. **A test query:** the lighthouse entry in its own words, up to the fact only the log holds, "Its keeper is". The braid completes it, and each token is shown with the strand that supplied it, its share, and the record it is cited to.
7. **Verify the session log**, as `braid verify` does.
8. **Let go of the servers**, stopping nothing. The lane and its records stay.

A second program sits in the same package: [the proof](#the-proof). It tests why Braid's citations work at all.

The code is in `Sources/`:

| File | Holds |
|---|---|
| `Braid/main.swift` | the eight steps |
| `Braid/Records.swift` | the app, the record structure, the test data, the query |
| `Braid/Show.swift` | how an answer is printed |
| `Scratch/Scratch.swift` | the work area and the pack, for both programs |
| `Proof/` | the proof: its steps, its rules, its texts, its printing, its options |

## Requirements

- **AII installed on this Mac**, its servers running or startable. `aii status` should show them; `aii install` installs AII.
- **Xcode with the Metal toolchain.** SwiftPM fetches Frigate and AII; a sibling `../AII` checkout stands in for AII when there is one.
- **The commons' pack.**
  - With the T9 mounted, the playground links the T9's pack: nothing is copied, nothing written there.
  - Without it, the playground downloads `AntonV/mamba2-130m-hf` once, about 0.5 GB, into `Examples/.work`.
- **Nothing else on the GPU**: one MLX workload at a time.

## Run

```sh
Examples/run.sh
```

`run.sh` does four things:
1. It points SwiftPM at the sibling AII checkout.
2. It builds the playground in release. The first build compiles Braid's whole graph, MLX included, and takes minutes.
3. It puts `mlx.metallib` beside the binary.
4. It runs the binary.

The exit code is 0 only when the answer names the fact and the session verifies.

**From Xcode.** Open `Examples/Package.swift` and press Run (the `Braid` scheme); the output appears in Xcode's console.
- **The Metal library:** Xcode builds into DerivedData, where `run.sh` never puts the Metal library. So step 0 copies the one Frigate's `build-metallib.sh` staged (`Examples/.build/checkouts/Frigate/.build/metallib-release/mlx.metallib`) beside Xcode's binary, before MLX starts.
- **Speed:** Xcode builds Debug, which trains several times slower. For release speed, set Product › Scheme › Edit Scheme › Run › Build Configuration to Release.

A first run on 2026-10-17 took 33 seconds after the build (paths shortened):

```
1 join      the braidplayground lane is registered; Sewn and Thread proved its secret (owner local-braidplayground)
2 remember  18 entries as braidplayground/log/<id> in braidplayground-harbour
  recall    Harlow Light (braidplayground/log/harlow-light) · distance 5.004
3 work area …/Braid/Examples/.work · pack mamba2-130m-hf d3e4516a2fa2, linked from the T9
4 plan      harbour: create
            snapshot  runs   18 documents, 18 partitions from app:home/braidplayground
            train     runs   from the pack's blocks
            index     runs   keyed residual:12, a checkpoint every 1024 tokens
            promote   runs   v1 made live
            attach    runs   added to [cluster] attach
    thread harbour: 18 documents, 18 partitions, corpus 6bd493d12a77
    thread harbour: training blocks 0..<12 on 662 tokens, 0 facts located
    thread harbour: stream 645 tokens, 5 windows of 128, 1 steps/epoch, 300 epochs planned, eval every 40 epochs
    thread harbour: step 1  loss 4.491  lr 5.00e-06  |g| 3.07  2.1 s
    …
    thread harbour: eval epoch 40 step 40  loss 0.263  memorised 93.6%  facts —
    …
    thread harbour: eval epoch 80 step 80  loss 0.075  memorised 98.6%  facts —  → learned
    thread harbour: indexing 0/18 documents
    thread harbour: v1 live, index 808c1ea74123 (608 entries), memorised 98.6%, mean loss 0.075, 16.8 s
  built     harbour  v1  residual:12  index 808c1ea74123  corpus 6bd493d12a77  attached
5 braid     commons + harbour · harbour v1, 608 entries, memorised 98.6%
6 query
  > Harlow Light stands at the end of the north mole in Skerrow. Its keeper is▸ Ines Calloway, who has trimmed the lamp every night since the winter of 1987.
    " In"           ← harbour 1.00 · the commons alone p 0.00 · cited braidplayground/log/harlow-light p0@19
    "es"            ← harbour 1.00 · the commons alone p 0.01 · cited braidplayground/log/harlow-light p0@20
    " C"            ← harbour 1.00 · the commons alone p 0.01 · cited braidplayground/log/harlow-light p0@21
    "allow"         ← harbour 1.00 · the commons alone p 0.00 · cited braidplayground/log/harlow-light p0@22
    …
    "."             ← harbour 1.00 · the commons alone p 0.36 · cited braidplayground/log/harlow-light p0@37
  royalties over 20 generated tokens
    commons    led 0  share Σ 0.00  credit·bits 24.8
    harbour    led 20  share Σ 20.00  credit·bits 86.9
    harbour · braidplayground/log/harlow-light  19 tokens  share Σ 19.00
  span  "low Light stands at the end of the north mole in Skerrow. Its keeper is Ines Calloway, …" → braidplayground/log/harlow-light p0@1
  ✓ the answer names Ines Calloway, which only the harbour log holds
7 verify    ok: 0 issues, 0 trace mismatches, spans 1 verified, 0 failed
  session   …/Examples/.work/sessions/<session>.jsonl
8 kept      the braidplayground lane and its 18 records (owner local-braidplayground)
  remove    Examples/run.sh forget, then aii lanes remove braidplayground --yes; the braid: rm -rf Examples/.work
```

Each generated token shows:
- the strand that led it, with its share;
- what the commons alone gave that token;
- the record it is cited to.

The commons (the pretrained model alone) can't know the keeper's name, so the Thread supplies every token and each one cites the lighthouse entry. The commons still earns credit for form words (`credit·bits`), by Braid's credit rule.

## What it writes

- **In `~/.rao`, the Mac's AII:**
  - the app's secret, `secrets/braidplayground`;
  - its lane in `aii/lanes.json`;
  - 18 records in the Thread's index, under the owner `local-braidplayground` and the group `braidplayground-harbour`;
  - a lease while it runs.
- **In `Examples/.work`** (gitignored): `braid.toml`, the pack link, `threads/harbour`, and a session log per run in `sessions/`.

It never writes the T9's work area or `BRAID_WORK_AREA`.

It never calls `AIIInstance.leave()`. With no other app holding the servers, that would stop the Mac's Sewn and Thread. The playground only releases its own hold.

**Two things AII does.** Both were seen on 2026-10-17; neither is the playground's choice:
- **The first run restarts the Mac's Sewn and Thread once.** When `join()` registers a new lane, a running server that can't yet prove the new secret is respawned if no app holds a lease. Later runs adopt the servers as they are.
- **AII's own search finds records only through the entities a query names.** The entries' tags are their only entities, because tags turn graph extraction off. So step 2 recalls with the tag `lighthouse`; a question such as "Who looks after the lighthouse?" found nothing. Braid doesn't search: the Thread reads every record through the lane's export.

## Reruns

Running again re-files the same records. Their ids and texts are unchanged, so the Thread's corpus hash is too: step 4 plans `harbour: up to date`, nothing is trained, and the query runs in a new session.

Edit an entry in `Records.swift` and run again: the Thread syncs. It trains on from v1 and makes v2 live.

Removing an entry from `Records.swift` doesn't remove its record from the lane; `run.sh forget` does.

## Look at it with the braid CLI

The playground's work area is an ordinary Braid work area:

```sh
Scripts/cli.sh thread show harbour --work-area Examples/.work
Scripts/cli.sh thread sync harbour --no-train --work-area Examples/.work
Scripts/cli.sh cluster spawn --work-area Examples/.work --prompt "Harlow Light stands at the end of the north mole in Skerrow. Its keeper is"
Scripts/cli.sh verify --work-area Examples/.work Examples/.work/sessions/<session>.jsonl --live
BRAID_WORK_AREA=Examples/.work Scripts/cli.sh
```

- `thread sync` should print "up to date" while the records are unchanged.
- `cluster spawn` encodes the prompt as the playground does. `chat` prepends a space.
- `verify --live` re-reads every span from the app's lane, `app:home/braidplayground`.
- The last command opens the studio on the playground's braid.

`aii lanes` lists the lane, and `aii lanes doctor braidplayground` walks it down the stack.

## The proof

Braid cites every token to the text it came from. The proof tests what makes that work: a Thread's own trained blocks, the delta, and the two places it acts.

The thinking starts from an essay on entropy, Suchir Balaji's [*When does generative AI qualify for fair use?*](https://suchir.net/fair_use.html) (2024): a model's low-entropy outputs are the likeliest to carry its training data. Braid is distributed, many Threads on one commons, each with a delta of its own. Put the two together, and each Thread's delta can be asked what it was trained on, through its own entropy.

Braid reads two entropies. H_lm is the Thread's own, from its reed. H_knn is retrieval's, low when the hits a Thread's index returns agree on the next token. The proof puts each in its place:
- **Detection, H_lm.** Does a text hold the Thread's training? Read where no index holds a copy.
- **Citation, H_knn.** Where did a token come from? Read where the index holds the text.

It builds two Threads on the same 60 documents of `braid-n3`'s craft node:
- **proof-craft-delta** trains blocks 0..<12 of its own, in front of the commons' tail.
- **proof-craft-frozen** keeps the commons' blocks. Its index holds the same documents, keyed the same way.

Both leave the same 20 documents out of their index. Then the texts go through both arms in one braid: the Thread's own documents, the same documents with their sentences shuffled, the 20 withheld, the unread documents in the same voice, and text from other nodes.

Five rules read the result. They were written into `Sources/Proof/ProofRules.swift` before craft was read.

| Rule | Asks |
|---|---|
| C0 | Is the frozen arm really the commons? |
| D1 | Does the delta's lift over the commons find the documents it trained on, where no index holds them? |
| D2 | Does the delta's H_lm tell those documents from unread ones, where the commons' blocks can't? |
| R1 | Does the index find its own text against unrelated text, whichever blocks keyed it? |
| R2 | Does the delta make that retrieval surer? |

The proof passes when all five rules do. Only then does it close on the two places the delta works, each with the rules and numbers that proved it.

```sh
Examples/proof.sh            # build both arms once, then score the texts and read the rules
Examples/proof.sh --help     # the options
Examples/proof.sh --fresh    # delete both arms and build them again
```

The first run on a node trains its delta, about two minutes. Later runs reuse both arms and only score, in half a minute. Each run writes a report to `Examples/.work/bench/proof/` and keeps a session log that `braid verify` replays. The exit code is 0 only when the proof passes.

### What it showed on craft, 2026-10-19

The five rules were fixed, then craft was read for the first time on 2026-10-19. A rerun on 2026-10-21 reused both arms and gave every reading again exactly. Its output, trimmed, paths shortened:

```
Proof · the delta over entropy                                                            2026-10-21

1 work area …/Braid/Examples/.work · pack mamba2-130m-hf d3e4516a2fa2, linked from the T9
2 dataset   braid-n3 · craft, 130 documents; both arms read the first 60 and withhold 33% of them from their index (seed 42)
            …
            proof-craft-frozen is up to date
            proof-craft-delta is up to date
4 braid     commons + proof-craft-delta + proof-craft-frozen under one reed, τ 0.05, k 16
            proof-craft-delta   v1 · blocks 0..<12 of its own, trained 117 steps over 39 epochs · memorised 99% · 7,985 entries · 20 withheld
            proof-craft-frozen  v1 · the commons' blocks 0..<12, untrained · memorised 18% · 7,985 entries · 20 withheld
5 texts     own 20 · own, shuffled 20 · withheld 19 · unseen 20 · unrelated 24
6 scoring   103 texts through 3 strands, nothing generated
            scored in 29 s

7 readings  each text's mean from position 24, then the mean over its set; H_knn's bar runs from 0 to ln 16 = 2.77
  set               n   H_knn, delta         H_knn, frozen        frozen − delta
  own              20   0.257 ▉              0.769 ██▊            +0.513
  own, shuffled    20   0.409 █▌             0.868 ███▏           +0.460
  withheld         19   0.585 ██▏            1.011 ███▋           +0.426
  unseen           20   0.568 ██             0.944 ███▍           +0.376
  unrelated        24   1.353 ████▉          1.612 █████▉         +0.259
  …
8 rules     written in ProofRules.swift before this data was read; the verdict reads C0, D1, D2, R1 and R2
  the control
    C0  PASS      the control is the commons
  detection · H_lm and lift, on the texts no index holds
    D1  PASS      the delta knows its training without its index
    D2  PASS      the commons' blocks do not
  citation · H_knn, on the texts the index holds
    R1  PASS      the index finds what it cites
    R2  PASS      the delta sharpens what it cites
  …
  ┌──────────────────────────────────────────────────────────────────────────────────────┐
  │ Proved on 2026-10-21 on braid-n3's craft node: C0, D1, D2, R1 and R2 pass. The       │
  │ delta, a Thread’s own first 12 blocks on the commons’ tail, is the key. It works in  │
  │ two places.                                                                          │
  │                                                                                      │
  │ Citation, H_knn. R1, the index finds the copy whichever blocks keyed it: AUROC 1.000 │
  │ delta, 1.000 frozen. R2, the delta makes that retrieval surer: lower on 100% of 20   │
  │ own texts, Welch's z 26.731.                                                         │
  │                                                                                      │
  │ Detection, H_lm. D1, lift over the commons finds the documents the delta trained on  │
  │ that no index holds: AUROC 1.000, 19 withheld against 20 unseen. D2, the delta’s own │
  │ entropy tells them from documents it never read, where the commons’ blocks cannot:   │
  │ AUROC 1.000 delta, 0.529 frozen.                                                     │
  │                                                                                      │
  │ The reading of entropy it starts from: Suchir Balaji, “When does generative AI       │
  │ qualify for fair use?”, suchir.net/fair_use.html, 2024.                              │
  └──────────────────────────────────────────────────────────────────────────────────────┘
```

**Proved.** All five rules passed.

The delta works in both places, in different ways. For detection it is the whole signal: the commons' blocks could not tell trained documents from unread ones, and the delta's own entropy told them apart every time. For citation it is a refinement: the index found its own text in both arms, and the delta made that retrieval surer on every own text.

One reported number shows the line between them. Retrieval could not tell withheld documents from unseen ones, AUROC 0.476 for the delta. With no copy in the index, only the delta's own entropy knows.

`braid verify` replayed the 2026-10-21 session with 0 arithmetic issues and 0 mismatches across 206 trace replays.

The limit: one model and one node, with 19 withheld documents against 20 unseen. R1 shows the index finds a copy, not that every token's citation names the right document.

### The first run, on ambient, 2026-10-19

The first run read ambient's first 40 documents with 8 withheld, under other rules: P1 to P3, since replaced by the five above. They are kept here as written.

| Rule | Asks |
|---|---|
| C0 | Is the frozen arm really the commons? |
| P1 | Is the delta's retrieval surer on its own text? |
| P2 | Does the delta tell its own text from unrelated text, where the frozen arm falls short? |
| P3 | Does the delta tell its own text from a shuffled copy? Reported, not decisive. |

A first run on 2026-10-19, trimmed (paths shortened):

```
Proof · the delta over entropy                                                            2026-10-19

1 work area …/Braid/Examples/.work · pack mamba2-130m-hf d3e4516a2fa2, linked from the T9
2 dataset   braid-n3 · ambient, 132 documents; both arms read the first 40 and withhold 20% of them from their index (seed 42)
            craft and veil give the unrelated texts, from what a Thread of each would read
3 plan      proof-frozen: create
            …
    thread proof-frozen: v1 live, index 7e1490b73cf2 (6723 entries), memorised 17.8%, mean loss 3.198, 1.2 s
    thread proof-delta: training blocks 0..<12 on 8599 tokens, 113 facts located
    …
    thread proof-delta: eval epoch 60 step 120  loss 0.016  memorised 98.7%  facts 93%  → learned
    thread proof-delta: v1 live, index 245523edad73 (6723 entries), memorised 98.7%, mean loss 0.016, 132.0 s
            arms ready in 133 s
4 braid     commons + proof-delta + proof-frozen under one reed, τ 0.05, k 16
            proof-delta   v1 · blocks 0..<12 of its own, trained 120 steps over 60 epochs · memorised 99% · 6,723 entries · 8 withheld
            proof-frozen  v1 · the commons' blocks 0..<12, untrained · memorised 18% · 6,723 entries · 8 withheld
5 texts     own 20 · own, shuffled 20 · withheld 8 · unseen 20 · unrelated 24
6 scoring   92 texts through 3 strands, nothing generated
            scored in 26 s

7 readings  each text's mean from position 24, then the mean over its set; H_knn's bar runs from 0 to ln 16 = 2.77
  set               n   H_knn, delta         H_knn, frozen        frozen − delta
  own              20   0.231 ▉              0.658 ██▍            +0.427
  own, shuffled    20   0.347 █▎             0.727 ██▋            +0.380
  withheld          8   0.620 ██▎            0.874 ███▏           +0.253
  unseen           20   0.599 ██▏            0.863 ███▏           +0.264
  unrelated        24   1.292 ████▋          1.508 █████▌         +0.216
  …
8 rules     written in ProofRules.swift before the first run; the verdict reads C0, P1 and P2
  C0  PASS      the control is the commons
  P1  PASS      the delta sharpens its own text
  P2  FAIL      the delta separates own from unrelated
                AUROC 1.000 delta (needs 0.95), 1.000 frozen (needs below 0.95 and at most the
                delta's less 0.10), 24 unrelated texts against 20 own
  P3  PASS      own against its pastiche
  …
  ──────────────────────────────────────────────────────────────────────────────────────────────────
  Not proved on 2026-10-19. P2 fails: the frozen arm tells own from unrelated too (AUROC 1.000),
  so the index did it, not the delta.
```

**Not proved.** P2 fails: the frozen arm tells own text from unrelated text as well as the delta does, AUROC 1.000 for both. Every own text sits word for word in both indexes, so both arms find it at cosine 1.000. The index did that work, not the delta.

The delta still changes what retrieval sees. Its H_knn was lower on all 20 own texts, 0.231 against 0.658. And only the delta told a text from its shuffled copy, at AUROC 0.958 against 0.728. P3 was written not to decide, so the verdict stands.

That failure put H_knn in its place: the index finds what a Thread cites, and the delta sharpens it. The rules above were written from it.

## Clean up

```sh
Examples/run.sh forget                    # the records out of the lane
aii lanes remove braidplayground --yes    # the lane (its documents stay unless forgotten first)
rm -rf Examples/.work                     # the playground's braid
```
