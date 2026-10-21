#!/usr/bin/env python3
"""Builds the tutorial site's data files from Braid's fixtures and the playground's run.

    python3 -I Docs/site/src/data.py                                  # from the committed fixtures
    python3 -I Docs/site/src/data.py --refresh                        # first copy the playground run from Examples/.work
    python3 -I Docs/site/src/data.py --refresh --aii-home ~/.rao      # and the playground lane's stored form from AII
    python3 -I Docs/site/src/data.py --check-only                     # check, write nothing

Inputs:  Docs/README_Assets/src/fixtures (four sessions, three snapshots); Docs/site/fixtures/harbour (the
         playground's session, snapshot, training logs, version and index records, and the lane's stored
         form); Docs/PAPER.md, README.md and Docs/ARCHITECTURE.md; the excerpts in Docs/site/src/code.json;
         the pack's tokenizer.json (or, without it, the tokens already in data/threads/*.js).
Outputs: Docs/site/data/*.js: classic scripts assigning into window.BraidData. With --refresh, the copied
         fixtures and their PROVENANCE.json.
Checks:  the tokenizer is every session's; every partition's text hashes to its textSHA256 and encodes to
         the log's token count; every logged hit's value sits at its (row, offset) and its entry at its
         position; every logged chain state sits on its entry; the verify arithmetic replays (the worst
         deviations go into data/manifest.js); the AII fixture holds nothing from another lane. A failed
         check stops the run and writes nothing.
"""

import argparse
import base64
import datetime as dt
import hashlib
import html
import json
import math
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import unicodedata
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SITE = REPO / "Docs" / "site"
DATA = SITE / "data"
FIXTURES = SITE / "fixtures" / "harbour"
README_FIXTURES = REPO / "Docs" / "README_Assets" / "src" / "fixtures"
AII_REPO = REPO.parent / "AII"

SESSION_SLUGS = {"4b07074b": "hello", "17c0fbc5": "tillyburn", "c809fc97": "joltvault", "e00a78d5": "window-in-autumn"}
SESSION_LABELS = {"hello": "Hello there", "harbour": "Harlow Light's keeper"}
PLAYGROUND_APP = "braidplayground"
PLAYGROUND_LANE = "app:home/braidplayground"
EOS = 0
BREAK = [535]
TOLERANCES = {"shareSum": 1e-5, "arithmetic": 1e-6, "entropy": 1e-5, "memory": 1e-5}


class Failure(Exception):
    pass


def fail(message):
    raise Failure(message)


def shown(path):
    """A path as the docs write it: repo-relative, under Docs/."""
    try:
        return str(Path(path).resolve().relative_to(REPO.resolve())).replace("docs/", "Docs/", 1) if str(Path(path).resolve()).lower().startswith(str(REPO.resolve()).lower()) else str(path)
    except ValueError:
        return str(path)


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    return sha256_bytes(Path(path).read_bytes())


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def f32_short(x):
    """The shortest decimal that reads back as the same float32 (so JS's Math.fround recovers it)."""
    f = f32(x)
    for p in range(6, 10):
        s = "%.*g" % (p, f)
        if f32(float(s)) == f:
            return float(s)
    return f


def git_head(repo):
    try:
        return subprocess.run(["git", "-C", str(repo), "rev-parse", "--short", "HEAD"], capture_output=True, text=True, check=True).stdout.strip()
    except Exception:
        return None


# MARK: The tokenizer

def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("¡"), ord("¬") + 1)) + list(range(ord("®"), ord("ÿ") + 1))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return {b: chr(c) for b, c in zip(bs, cs)}


class Tokenizer:
    """The pack's GPT-NeoX tokenizer through Hugging Face `tokenizers`: ids, and each token's span of the text."""

    def __init__(self, path):
        from tokenizers import Tokenizer as HF
        self.path = Path(path)
        self.sha256 = sha256_file(path)
        self.hf = HF.from_file(str(path))
        spec = json.loads(Path(path).read_text(encoding="utf-8"))
        decoder = {v: k for k, v in bytes_to_unicode().items()}
        self.added = {a["id"]: a["content"].encode("utf-8") for a in spec.get("added_tokens", [])}
        self.piece = {}
        for token, i in spec["model"]["vocab"].items():
            if i not in self.added:
                self.piece[i] = bytes(decoder[c] for c in token)

    def token_bytes(self, i):
        return self.added[i] if i in self.added else self.piece[i]

    def encode(self, text):
        """Ids, and offsets in UTF-16 code units (JavaScript string indices), one more than the ids."""
        if unicodedata.normalize("NFC", text) != text:
            fail("a partition's text is not NFC; the token offsets would not index it")
        ids = self.hf.encode(text, add_special_tokens=False).ids
        raw = text.encode("utf-8")
        joined = b"".join(self.token_bytes(i) for i in ids)
        if joined != raw:
            fail("the tokens of a partition do not spell its text byte for byte")
        # byte offset → UTF-16 offset, at character starts
        starts = {}
        b = u = 0
        for ch in text:
            starts[b] = u
            b += len(ch.encode("utf-8"))
            u += len(ch.encode("utf-16-le")) // 2
        starts[b] = u
        boundaries = sorted(starts)
        offsets = []
        pos = 0
        for i in ids + [None]:
            if pos in starts:
                offsets.append(starts[pos])
            else:  # inside a multi-byte character: the character's start
                offsets.append(starts[max(k for k in boundaries if k <= pos)])
            if i is not None:
                pos += len(self.token_bytes(i))
        return ids, offsets


def find_tokenizer(arg, work):
    candidates = []
    if arg:
        candidates.append(Path(arg).expanduser())
    candidates += sorted(Path(work).glob("packs/*/tokenizer/tokenizer.json"))
    area = os.environ.get("BRAID_WORK_AREA")
    if area:
        candidates += sorted(Path(area).expanduser().glob("packs/*/tokenizer/tokenizer.json"))
    candidates += sorted(Path("/Volumes/T9/rao/projects/braid").glob("packs/*/tokenizer/tokenizer.json"))
    for c in candidates:
        try:
            if c.is_file():
                return c
        except OSError:
            continue
    return None


# MARK: Data files

def js_file(path, key, value, sources, sub=None):
    """Writes `window.BraidData.<key>[<sub>] = <json>;` with a header naming the script and inputs."""
    path.parent.mkdir(parents=True, exist_ok=True)
    body = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    head = "/* generated by Docs/site/src/data.py from " + ", ".join(sources) + " - do not edit */\n"
    lines = [head, "window.BraidData = window.BraidData || {};\n"]
    if sub is None:
        lines.append(f"window.BraidData.{key} = {body};\n")
    else:
        lines.append(f"window.BraidData.{key} = window.BraidData.{key} || {{}};\n")
        lines.append(f"window.BraidData.{key}[{json.dumps(sub)}] = {body};\n")
    text = "".join(lines)
    path.write_text(text, encoding="utf-8")
    return len(text.encode("utf-8"))


def read_js_value(path):
    """The JSON a data file assigns (for rebuilding without the tokenizer)."""
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        m = re.match(r"^window\.BraidData\.\w+(\[[^\]]+\])? = (.*);$", line)
        if m and m.group(2) != "window.BraidData." and not m.group(2).startswith("window.BraidData"):
            return json.loads(m.group(2))
    fail(f"{shown(path)} holds no data line")


# MARK: Threads

def load_thread(name, label, source, snapshot_path, tokenizer, cached):
    snapshot = json.loads(Path(snapshot_path).read_text(encoding="utf-8"))
    docs = sorted(snapshot["documents"], key=lambda d: d["id"])
    if [d["id"] for d in snapshot["documents"]] != [d["id"] for d in docs]:
        fail(f"{name}: the snapshot's documents are not in id order")
    old = {p["textSHA256"] + "#" + str(p["row"]): p for p in cached["partitions"]} if cached else {}
    partitions, documents, entry_base = [], [], []
    entries = 0
    for di, d in enumerate(docs):
        rows, length = [], 0
        parts = sorted(d["partitions"], key=lambda p: p["index"])
        for n, p in enumerate(parts):
            text = p["text"]
            if sha256_bytes(text.encode("utf-8")) != p["textSHA256"]:
                fail(f"{name}: {d['id']} partition {p['index']} does not hash to its textSHA256")
            row = len(partitions)
            if tokenizer:
                ids, offsets = tokenizer.encode(text)
            else:
                prior = old.get(p["textSHA256"] + "#" + str(row))
                if not prior:
                    fail(f"{name}: no tokenizer and no earlier tokens for row {row}; pass --tokenizer")
                ids, offsets = prior["tokens"], prior["offsets"]
            entry = {"row": row, "doc": di, "index": p["index"], "textSHA256": p["textSHA256"], "text": text, "tokens": ids, "offsets": offsets}
            for extra in ("url", "threadPartitionID"):
                if p.get(extra):
                    entry[extra] = p[extra]
            partitions.append(entry)
            rows.append(row)
            length += len(ids) + (len(BREAK) if n < len(parts) - 1 else 0)
        document = {"id": d["id"], "name": d.get("name", d["id"]), "rows": rows}
        if d.get("createdAt"):
            document["createdAt"] = d["createdAt"]
        documents.append(document)
        entry_base.append(entries)
        entries += max(0, length - 1)
    return {
        "name": name, "label": label, "source": source, "corpusHash": snapshot["corpusHash"],
        "snapshot": {"file": shown(snapshot_path), "sha256": sha256_file(snapshot_path), "exportedAt": snapshot.get("exportedAt"),
                     "documentCount": len(docs), "partitionCount": len(partitions), "owner": snapshot.get("owner"),
                     "documentIDPrefix": snapshot.get("documentIDPrefix")},
        "eos": EOS, "break": BREAK, "documents": documents, "partitions": partitions,
        "layout": {"rule": "L-1", "entryBase": entry_base, "entries": entries},
    }


def expand_layout(thread):
    """Per entry: value, key address, value address, document (what the index holds, rebuilt from the tokens)."""
    values, key_row, key_off, val_row, val_off, doc_of = [], [], [], [], [], []
    parts = thread["partitions"]
    for di, d in enumerate(thread["documents"]):
        stream = []  # (token, row, offset) for content positions 1..L
        for n, row in enumerate(d["rows"]):
            toks = parts[row]["tokens"]
            for i, t in enumerate(toks):
                stream.append((t, row, i))
            if n < len(d["rows"]) - 1:
                for j, t in enumerate(BREAK):
                    stream.append((t, row, len(toks) + j))
        for k in range(len(stream) - 1):
            values.append(stream[k + 1][0])
            key_row.append(stream[k][1])
            key_off.append(stream[k][2])
            val_row.append(stream[k + 1][1])
            val_off.append(stream[k + 1][2])
            doc_of.append(di)
    if len(values) != thread["layout"]["entries"]:
        fail(f"{thread['name']}: {len(values)} entries rebuilt, {thread['layout']['entries']} counted")
    return {"values": values, "keyRow": key_row, "keyOffset": key_off, "valueRow": val_row, "valueOffset": val_off, "doc": doc_of}


# MARK: Sessions

def parse_session(path):
    raw = Path(path).read_text(encoding="utf-8")
    lines = [line for line in raw.split("\n") if line.strip()]
    objects = [json.loads(line) for line in lines]
    if not objects or objects[0].get("kind") != "header":
        fail(f"{shown(path)}: the first line is not a header")
    if objects[0].get("schema") != 1:
        fail(f"{shown(path)}: schema {objects[0].get('schema')} is not 1")
    gens = []
    current = None
    for line, obj in zip(lines[1:], objects[1:]):
        kind = obj.get("kind")
        if kind == "gen":
            current = {"gen": obj, "steps": [], "end": None, "membership": [], "body": [line]}
            gens.append(current)
        elif kind == "tok":
            current["steps"].append(obj)
            current["body"].append(line)
        elif kind in ("attach", "detach"):
            if current is not None:
                current["membership"].append((len(current["steps"]), obj))
                current["body"].append(line)
        elif kind == "end":
            current["end"] = obj
            current = None
    for g in gens:
        g["bodySHA256"] = sha256_bytes("".join(l + "\n" for l in g["body"]).encode("utf-8"))
    return lines, objects[0], gens


class GateState:
    def __init__(self, strands, commons, prior):
        n = strands
        self.memory = [1 / n if n else 0] * n
        self.credibility = [0.0] * n
        self.commons = commons
        if commons is not None and 0 <= commons < n:
            p = min(max(prior, 0), 1) if n > 1 else 1
            self.memory = [p if t == commons else (1 - p) / (n - 1) for t in range(n)]


def gate_observe(state, likelihoods, module, settings):
    n = len(state.memory)
    floor = max(settings["evidenceFloor"], 1e-6)
    reach = max(settings["evidenceCeiling"] / max(settings["evidenceFloor"], 1e-6), 1 + 1e-6)
    span = math.log(reach)
    c = state.commons
    if c is not None and settings.get("evidence", "lift") == "lift":
        base = max(likelihoods[c], 1e-12)
        ratios = []
        for t in range(n):
            if t == c:
                ratios.append(1.0)
                continue
            evidence = math.log(max(likelihoods[t], 1e-300) / base)
            if settings["moduleGain"] > 0 and module is not None:
                evidence += settings["moduleGain"] * min(max(module[t], -1), 1) * span
            ratios.append(math.exp(min(max(evidence, -span), span)))
        gains = [max(0.0, math.log(r)) / span for r in ratios]
        losses = [max(0.0, -math.log(r)) / span for r in ratios]
    else:
        ceiling = max(settings["evidenceCeiling"], floor)
        hits = [min(max(x, floor), ceiling) for x in likelihoods]
        ratios = [h / ceiling for h in hits]
        losses = [math.log(ceiling / h) / span if span > 0 else 0 for h in hits]
        gains = [1 - l for l in losses]
    rate = min(max(settings["credibilityRate"], 0), 1)
    state.credibility = [(1 - rate) * state.credibility[t] + rate * gains[t] for t in range(n)]
    if n <= 1:
        state.memory = [1.0]
        return ratios
    others = [t for t in range(n) if t != c] if (settings.get("evidence", "lift") == "lift" and c is not None) else list(range(n))
    weight = max([state.credibility[t] for t in others], default=0)
    updated = [state.memory[t] * (ratios[t] ** weight) for t in range(n)]
    total = sum(updated)
    updated = [u / total for u in updated] if total > 0 else state.memory
    alpha = min(max(settings["shareRate"], 0), 1)
    given = [updated[t] * (1 - (1 - alpha) ** losses[t]) for t in range(n)]
    pool = sum(given)
    state.memory = [updated[t] - given[t] + (pool - given[t]) / (n - 1) for t in range(n)]
    return ratios


def renormalised(gates, open_):
    total = sum(g for g, o in zip(gates, open_) if o)
    count = sum(1 for o in open_ if o)
    return [(g / total if total > 0 else 1 / max(count, 1)) if o else 0.0 for g, o in zip(gates, open_)]


def shadow_weights(memory, traces, beta):
    if not memory or len(traces) != len(memory):
        return memory
    mean = sum(traces) / len(traces)
    gates = [m * math.exp(beta * (tr - mean)) for m, tr in zip(memory, traces)]
    total = sum(gates)
    return [g / total for g in gates] if total > 0 else memory


def knn_weights(scores, tau):
    if not scores:
        return []
    top = max(scores)
    t = max(tau, 1e-4)
    exps = [math.exp((s - top) / t) for s in scores]
    total = sum(exps)
    return [e / total for e in exps]


def entropy(ps):
    return -sum(p * math.log(p) for p in ps if p > 0)


def replay(header, g):
    """SessionReplay.check, in Python: the worst deviation of every check, and the issues past tolerance."""
    worst = {k: 0.0 for k in ("shareSum", "weights", "p", "share", "hknn", "shadow", "memory")}
    issues = []
    if g["end"] and g["end"]["bodySHA256"] != g["bodySHA256"]:
        issues.append("body hash")
    names = g["gen"]["strands"]
    known = {t["name"]: t for t in header["threads"]}
    strands = [known[n] for n in names]
    commons = next((i for i, s in enumerate(strands) if s["commons"]), None)
    settings = header["gate"]
    state = GateState(len(strands), commons, settings["commonsPrior"])
    if g["membership"]:
        fail("membership lines inside a generation are not replayed by data.py yet")
    for k, step in enumerate(g["steps"]):
        threads = step.get("thr")
        if not threads or step["src"] == "ctx":
            continue
        n = len(threads)
        share_sum = sum(f32(r["share"]) for r in threads)
        worst["shareSum"] = max(worst["shareSum"], abs(share_sum - 1))
        gates = [f32(r.get("g", r["mem"])) for r in threads]
        open_ = [r["open"] for r in threads]
        weights = renormalised(gates, open_)
        for t in range(n):
            worst["weights"] = max(worst["weights"], abs(weights[t] - f32(threads[t]["w"])))
        lambdas = [f32(s["lambda"]) for s in strands]
        probs = [None if r.get("plm") is None else lambdas[t] * f32(r["pknn"]) + (1 - lambdas[t]) * f32(r["plm"]) for t, r in enumerate(threads)]
        p = sum(weights[t] * (probs[t] or 0) for t in range(n) if open_[t])
        worst["p"] = max(worst["p"], abs(p - f32(step["p"])))
        if p > 0:
            for t in range(n):
                expected = weights[t] * (probs[t] or 0) / p if open_[t] else 0
                worst["share"] = max(worst["share"], abs(expected - f32(threads[t]["share"])))
        if header.get("hitsLogged", 0) >= 16:
            for t, r in enumerate(threads):
                w = knn_weights([f32(h[1]) for h in r["hits"]], f32(strands[t]["tau"]))
                knn = {}
                for i, h in enumerate(r["hits"]):
                    knn[h[2]] = knn.get(h[2], 0) + w[i]
                worst["hknn"] = max(worst["hknn"], abs(entropy(knn.values()) - f32(r["Hknn"])))
        traces = [f32(r["tr"]["tr"]) if r.get("tr") else 0.0 for r in threads]
        shadow = shadow_weights([f32(r["mem"]) for r in threads], traces, settings["shadowBeta"])
        for t in range(n):
            worst["shadow"] = max(worst["shadow"], abs(shadow[t] - f32(threads[t]["sg"])))
        for t in range(n):
            worst["memory"] = max(worst["memory"], abs(state.memory[t] - f32(threads[t]["mem"])))
        if step["src"] == "prompt":
            likelihoods = [probs[t] if probs[t] is not None else lambdas[t] * f32(threads[t]["pknn"]) for t in range(n)]
            module = [f32(r["mod"]) for r in threads] if all(r.get("mod") is not None for r in threads) else None
            gate_observe(state, likelihoods, module, settings)
    limits = {"shareSum": TOLERANCES["shareSum"], "weights": TOLERANCES["arithmetic"], "p": TOLERANCES["arithmetic"] * 10,
              "share": TOLERANCES["arithmetic"] * 10, "hknn": TOLERANCES["entropy"], "shadow": TOLERANCES["arithmetic"] * 10,
              "memory": TOLERANCES["memory"]}
    for key, value in worst.items():
        if value > limits[key]:
            issues.append(f"{key} off by {value:.3g} (tolerance {limits[key]:g})")
    return worst, issues


def check_hits(header, g, threads_by_name, layouts):
    """Every logged hit and chain state against the index layout rebuilt from the tokens."""
    hits = chains = 0
    names = g["gen"]["strands"]
    for k, step in enumerate(g["steps"]):
        for t, r in enumerate(step.get("thr") or []):
            name = names[t]
            if name not in threads_by_name:
                if r.get("hits"):
                    fail(f"{name} logged hits but has no thread data")
                continue
            thread, layout = threads_by_name[name], layouts[name]
            parts = thread["partitions"]
            for h in r["hits"]:
                entry, score, value, row, offset, loss = h
                part = parts[row]
                if offset < len(part["tokens"]):
                    if part["tokens"][offset] != value:
                        fail(f"step {k} {name}: hit value {value} is not token {part['tokens'][offset]} at ({row}, {offset})")
                elif value not in BREAK:
                    fail(f"step {k} {name}: hit past the partition at ({row}, {offset}) is not a break")
                if layout["values"][entry] != value or layout["valueRow"][entry] != row or layout["valueOffset"][entry] != offset:
                    fail(f"step {k} {name}: entry {entry} does not sit at ({row}, {offset})")
                hits += 1
            tr = r.get("tr")
            if tr and tr.get("e") is not None:
                e = tr["e"]
                if layout["keyRow"][e] != tr["row"] or layout["keyOffset"][e] != tr["off"] or layout["values"][e] != tr["nx"]:
                    fail(f"step {k} {name}: the chain's entry {e} is not at ({tr['row']}, {tr['off']}) expecting {tr['nx']}")
                chains += 1
    end = g["end"]
    for ref in end["partitions"]:
        owner = next((s for s in header["threads"] if not s["commons"] and s["rowOffset"] <= ref["row"] < s["rowOffset"] + s["rowCount"]), None)
        if owner is None:
            fail(f"row {ref['row']} belongs to no strand")
        part = threads_by_name[owner["name"]]["partitions"][ref["row"] - owner["rowOffset"]]
        doc = threads_by_name[owner["name"]]["documents"][part["doc"]]
        if (doc["id"], part["index"], part["textSHA256"], len(part["tokens"])) != (ref["documentID"], ref["partitionIndex"], ref["textSHA256"], ref["tokenCount"]):
            fail(f"row {ref['row']}: the end line's partition is not the snapshot's")
    return hits, chains


# MARK: The playground run, copied in

def refresh_harbour(work, session_choice):
    work = Path(work).expanduser()
    if not (work / "threads" / "harbour").is_dir():
        fail(f"{shown(work)} holds no harbour Thread; run Examples/run.sh first")
    sessions = []
    for p in sorted((work / "sessions").glob("*.jsonl")):
        if p.name.startswith("._"):
            continue
        header = json.loads(p.read_text(encoding="utf-8").split("\n", 1)[0])
        if any(t.get("lane") == PLAYGROUND_LANE for t in header.get("threads", [])):
            sessions.append(p)
    if not sessions:
        fail("no playground session in " + shown(work / "sessions"))
    if session_choice and session_choice != "NEWEST":
        picked = [p for p in sessions if session_choice in p.name]
        if not picked:
            fail(f"no session matches {session_choice}")
        session = picked[-1]
    else:
        session = sessions[-1]
    bodies = {p.name: p.read_text(encoding="utf-8").split("\n")[2:] for p in sessions}
    identical = sum(1 for b in bodies.values() if b == bodies[session.name])
    header = json.loads(session.read_text(encoding="utf-8").split("\n", 1)[0])
    strand = next(t for t in header["threads"] if t.get("lane") == PLAYGROUND_LANE)
    thread_dir = work / "threads" / strand["name"]
    live = json.loads((thread_dir / "live.json").read_text())
    vdir = thread_dir / "versions" / ("v%04d" % live["version"])
    version = json.loads((vdir / "version.json").read_text())
    snapshot = thread_dir / "snapshots" / strand["corpusHash"][:12] / "snapshot.json"
    if not snapshot.is_file():
        fail(f"no snapshot {shown(snapshot)}")
    if FIXTURES.exists():
        for child in ("sessions", "threads"):
            if (FIXTURES / child).exists():
                shutil.rmtree(FIXTURES / child)
    copies = {
        session: FIXTURES / "sessions" / session.name,
        snapshot: FIXTURES / "threads" / strand["name"] / "snapshot.json",
        thread_dir / "thread.json": FIXTURES / "threads" / strand["name"] / "thread.json",
        thread_dir / "live.json": FIXTURES / "threads" / strand["name"] / "live.json",
        thread_dir / "training-steps.jsonl": FIXTURES / "threads" / strand["name"] / "training-steps.jsonl",
        thread_dir / "training-evals.jsonl": FIXTURES / "threads" / strand["name"] / "training-evals.jsonl",
        vdir / "version.json": FIXTURES / "threads" / strand["name"] / "versions" / vdir.name / "version.json",
        vdir / "index" / "index.json": FIXTURES / "threads" / strand["name"] / "versions" / vdir.name / "index" / "index.json",
        vdir / "index" / "partitions.json": FIXTURES / "threads" / strand["name"] / "versions" / vdir.name / "index" / "partitions.json",
        vdir / "index" / "checkpoints.json": FIXTURES / "threads" / strand["name"] / "versions" / vdir.name / "index" / "checkpoints.json",
        work / "braid.toml": FIXTURES / "braid.toml",
    }
    for src, dst in copies.items():
        if not src.is_file():
            fail(f"missing {shown(src)}")
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(src, dst)
        os.chmod(dst, 0o644)
    gen = json.loads(session.read_text(encoding="utf-8").split("\n")[1])
    manifest = {
        "threads": [{"name": strand["name"], "label": strand["label"], "source": PLAYGROUND_LANE,
                     "version": f"v{live['version']} trained · {version.get('entries', 0) and len(json.loads((vdir / 'index' / 'partitions.json').read_text()))} records"}],
        "examples": [{"thread": strand["name"], "label": "keeper · Harlow Light", "prompt": gen["prompt"]["text"], "expected": " Ines Calloway"}],
    }
    (FIXTURES / "fixtures.json").write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    provenance = {
        "copiedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "from": shown(work) if str(work).startswith(str(REPO)) else str(work),
        "braidCommit": git_head(REPO),
        "session": {"file": session.name, "sessionID": header["sessionID"], "createdAt": header["createdAt"], "generationID": gen["generationID"],
                    "identicalRuns": identical, "runs": len(sessions)},
        "thread": {"name": strand["name"], "threadID": strand.get("threadID"), "corpusHash": strand["corpusHash"], "version": live["version"],
                   "versionSHA256": strand.get("versionSHA256"), "indexSHA256": version.get("indexSHA256"), "blocksSHA256": version.get("blocksSHA256"),
                   "checkpointsSHA256": version.get("checkpointsSHA256"), "steps": version.get("steps"), "memorised": version.get("memorised"),
                   "learned": version.get("learned"), "trainedAt": version.get("createdAt")},
        "pack": {"name": header["pack"].get("name"), "sha256": header["pack"].get("sha256"), "tokenizerSHA256": header["pack"]["tokenizerSHA256"]},
        "notCopied": ["blocks.safetensors (172 MB of weights)", "index.safetensors (the keys)", "shared-ngrams.bin"],
    }
    (FIXTURES / "PROVENANCE.json").write_text(json.dumps(provenance, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"copied the playground run: {session.name} ({identical} of {len(sessions)} runs identical after the gen line), v{live['version']}")


# MARK: The playground lane's stored form, from the machine's AII

def plain(value, home):
    """A plist value as JSON: dates as ISO strings, bytes as base64 (or JSON when they are JSON), the home folder as ~."""
    if isinstance(value, dict):
        return {k: plain(v, home) for k, v in value.items()}
    if isinstance(value, list):
        return [plain(v, home) for v in value]
    if isinstance(value, dt.datetime):
        return value.replace(tzinfo=dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if value.tzinfo is None else value.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if isinstance(value, bytes):
        try:
            return {"json": json.loads(value.decode("utf-8"))}
        except Exception:
            return {"base64": base64.b64encode(value).decode("ascii")}
    if isinstance(value, str):
        return value.replace(home, "~") if home else value
    if isinstance(value, float):
        return f32_short(value)
    return value


def decimal_digits(digest):
    return "".join(str(b) for b in digest)


def refresh_aii_store(aii_home):
    home = Path(aii_home).expanduser()
    lanes = json.loads((home / "aii" / "lanes.json").read_text())
    lane = lanes["lanes"].get(PLAYGROUND_APP)
    if not lane:
        fail(f"{home}/aii/lanes.json has no {PLAYGROUND_APP} lane; run Examples/run.sh first")
    lane_id, owner = lane["id"], lane["owner"]
    db = home / "aii" / "thread" / "db"
    node = (db / "node-id").read_text().strip()
    prefix = PLAYGROUND_APP + "/"
    group = f"{PLAYGROUND_APP}-harbour"
    home_text = str(Path.home())
    out = FIXTURES / "aii-store"
    if out.exists():
        shutil.rmtree(out)
    (out / "documents").mkdir(parents=True)
    (out / "parts").mkdir(parents=True)
    doc_ids = []
    for path in sorted((db / "documents" / PLAYGROUND_APP).rglob("*")):
        if path.is_dir() or path.name.startswith("._") or path.name.endswith("-parts"):
            continue
        rel = path.relative_to(db / "documents").as_posix()
        doc_ids.append(rel)
        name = rel[len(prefix):].replace("/", "__")
        document = plain(plistlib.loads(path.read_bytes()), home_text)
        parts = plain(plistlib.loads((path.parent / (path.name + "-parts")).read_bytes()), home_text)
        (out / "documents" / f"{name}.json").write_text(json.dumps(document, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
        (out / "parts" / f"{name}.json").write_text(json.dumps(parts, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    table = plistlib.loads((db / f"table-{node}").read_bytes())
    entries = {k: v for k, v in table["indices"].items() if k.startswith(prefix)}
    checks = []
    for doc_id, entry in entries.items():
        codebooks = entry["pq"]["codebooks"]
        if all(len(cb) == 1 for cb in codebooks):  # one partition: the single centroid is the vector itself
            vector = [f32(x) for cb in codebooks for x in cb[0]]
            digest = hashlib.sha256(struct.pack("<%df" % len(vector), *vector) + doc_id.encode("utf-8") + b"#0").digest()
            stored = entry["slots"][0]["id"]
            checks.append({"document": doc_id, "partitionID": stored, "recomputed": decimal_digits(digest) == stored,
                           "norm": math.sqrt(sum(x * x for x in vector)), "codes": entry["slots"][0].get("compressedEmbedding")})
    rows = [json.dumps(k, ensure_ascii=False) + ": " + json.dumps(v, ensure_ascii=False, separators=(",", ":")) for k, v in plain(entries, home_text).items()]
    (out / "table-entries.json").write_text("{\n" + ",\n".join(rows) + "\n}\n", encoding="utf-8")  # one document per line
    registry = plistlib.loads((db / f"registry-{node}").read_bytes())

    def keep_key(k):
        return k.startswith(prefix) or k == lane_id or k == group or k == owner

    lane_rows = {}
    for key, value in registry.items():
        if isinstance(value, dict):
            kept = {k: v for k, v in value.items() if keep_key(k)}
            if kept:
                lane_rows[key] = kept
        elif isinstance(value, list):
            kept = [v for v in value if (isinstance(v, dict) and v.get("id") in (owner, lane_id, group)) or (isinstance(v, str) and keep_key(v))]
            if kept:
                lane_rows[key] = kept
    (out / "registry-lane.json").write_text(json.dumps(plain(lane_rows, home_text), indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    graph = plistlib.loads((db / f"graph-{node}").read_bytes())
    entities = []
    for e in graph["entities"].values():
        mine = [d for d in e["documentIds"] if d.startswith(prefix)]
        if not mine:
            continue
        row = {"id": e["id"], "name": e["name"], "kind": e["kind"], "documentIds": sorted(mine)}
        if len(mine) == len(e["documentIds"]):
            row["mentionCount"] = e["mentionCount"]
        entities.append(row)
    relationships = []
    for r in graph.get("relationships", {}).values():
        mine = [d for d in r.get("documentIds", []) if d.startswith(prefix)]
        if mine:
            relationships.append({"id": r["id"], "predicate": r.get("predicate"), "documentIds": sorted(mine)})
    entities.sort(key=lambda e: (e["name"], e["id"]))
    (out / "graph-entities.json").write_text(json.dumps({"entities": entities, "relationships": relationships}, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    embedder = plain(plistlib.loads((db / f"embedder-{node}").read_bytes()), home_text)
    (out / "embedder.json").write_text(json.dumps(embedder, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    sizes = {name: (db / name).stat().st_size for name in (f"table-{node}", f"graph-{node}", f"registry-{node}")}
    counts = {}
    for lid, docs in registry.get("laneDocuments", {}).items():
        app = next((a for a, l in lanes["lanes"].items() if l["id"] == lid), None)
        if app:
            counts[app] = len(docs)
    provenance = {
        "copiedAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "from": "~/" + str(db.relative_to(Path.home())) if str(db).startswith(home_text) else str(db),
        "aiiCommit": git_head(AII_REPO), "node": node, "lane": {"app": PLAYGROUND_APP, "id": lane_id, "owner": owner, "group": group},
        "documents": len(doc_ids), "partitionIDsRecomputed": sum(1 for c in checks if c["recomputed"]), "partitionIDsChecked": len(checks),
        "storeSizes": {k.split("-")[0]: v for k, v in sizes.items()}, "documentsPerLane": counts,
        "storeCounts": {"documents": len(table["indices"]), "entities": len(graph["entities"]), "relationships": len(graph.get("relationships", {})),
                        "predicates": len(graph.get("predicates", {}))},
        "redacted": "paths under the home folder are written as ~; nothing from another lane, owner or group is copied",
    }
    (out / "PROVENANCE.json").write_text(json.dumps(provenance, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    (out / "checks.json").write_text(json.dumps(checks, indent=1) + "\n", encoding="utf-8")
    for p in out.rglob("*.json"):
        os.chmod(p, 0o644)
    print(f"copied the {PLAYGROUND_APP} lane's stored form: {len(doc_ids)} documents, {len(entities)} entities; "
          f"{provenance['partitionIDsRecomputed']} of {len(checks)} partition ids recomputed from their vectors")


def check_store_filter(store_dir, lane_id, node, owner):
    """Fails if the AII fixture names anything outside the playground lane."""
    allowed_uuids = {lane_id.lower(), node.lower()}
    uuid = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
    docid = re.compile(r"^([a-z][a-z0-9]{1,31})/[a-z0-9]+/")
    bad = []

    def walk(v, where):
        if isinstance(v, dict):
            for k, x in v.items():
                walk(k, where)
                walk(x, where)
        elif isinstance(v, list):
            for x in v:
                walk(x, where)
        elif isinstance(v, str):
            for m in uuid.findall(v):
                if m.lower() not in allowed_uuids:
                    bad.append((where, m))
            m = docid.match(v)
            if m and m.group(1) != PLAYGROUND_APP:
                bad.append((where, v[:40]))
            if v in ("aii-local",) or (v.startswith("local-") and v != owner):
                bad.append((where, v))
            for other in ("ambient/", "craft/", "veil/", "notes/", "ambient-", "craft-", "veil-"):
                if v.startswith(other):
                    bad.append((where, v[:40]))

    for p in sorted(Path(store_dir).rglob("*.json")):
        walk(json.loads(p.read_text(encoding="utf-8")), p.name)
    if bad:
        fail("the AII fixture names something outside the playground lane: " + "; ".join(f"{w}: {s}" for w, s in bad[:5]))


# MARK: Claims, status, findings

def inline_md(text):
    out = html.escape(text.strip(), quote=False)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1", out)
    return out


def status_class(cell):
    s = re.sub(r"[*`]", "", cell).strip().lower()
    if s.startswith("backed ("):
        return "partial"
    if s.startswith("backed"):
        return "backed"
    if s.startswith("fails"):
        return "fails"
    if s.startswith("not claimed"):
        return "not-claimed"
    if s.startswith("pending"):
        return "pending"
    fail(f"PAPER.md: unknown status {cell!r}")


def table_rows(lines):
    rows = []
    for line in lines:
        if not line.startswith("|") or re.match(r"^\|[-| ]+\|$", line.strip()):
            continue
        cells = [c for c in re.split(r"(?<!\\)\|", line.strip())[1:-1]]
        rows.append([c.strip() for c in cells])
    return rows[1:] if rows else []


def claims(paper, readme, architecture):
    text = Path(paper).read_text(encoding="utf-8")
    as_of = re.search(r"Statuses as of (\d{4}-\d{2}-\d{2})", text)
    groups = []
    for block in re.split(r"^## ", text, flags=re.M)[1:]:
        title, _, body = block.partition("\n")
        rows = table_rows(body.splitlines())
        if not rows:
            continue
        groups.append({"title": title.strip(), "rows": [{"claim": inline_md(r[0]), "backedBy": inline_md(r[1]), "status": inline_md(r[2]),
                                                       "class": status_class(r[2])} for r in rows]})
    legend = [{"status": m.group(1), "means": m.group(2).rstrip(";.")} for m in re.finditer(r"^- \*\*([a-z ]+)\*\*: (.+)$", text, flags=re.M)]
    readme_text = Path(readme).read_text(encoding="utf-8")
    where = re.search(r"^## Where it stands \(([^)]+)\)\n(.*?)(?=^## )", readme_text, flags=re.M | re.S)
    status_rows = [{"label": re.sub(r"\*", "", r[0]), "text": inline_md(r[1])} for r in table_rows(where.group(2).splitlines())] if where else []
    arch = Path(architecture).read_text(encoding="utf-8")
    findings_block = re.search(r"^## Findings and open decisions\n(.*)", arch, flags=re.M | re.S).group(1)
    findings = []
    for m in re.finditer(r"^(\d+)\. \*\*(.+?)\*\*(.*)$", findings_block, flags=re.M):
        findings.append({"n": int(m.group(1)), "title": inline_md(m.group(2)), "text": inline_md(m.group(3))})
    return {"asOf": as_of.group(1) if as_of else None, "legend": legend, "groups": groups,
            "readme": {"date": where.group(1) if where else None, "rows": status_rows}, "findings": findings}


# MARK: Code excerpts

def excerpts(spec_path):
    if not Path(spec_path).is_file():
        return {}, []
    spec = json.loads(Path(spec_path).read_text(encoding="utf-8"))
    commits = {"braid": git_head(REPO), "aii": git_head(AII_REPO)}
    roots = {"braid": REPO, "aii": AII_REPO}
    out, sources = {}, []
    for item in spec:
        root = roots[item.get("repo", "braid")]
        path = root / item["path"]
        lines = path.read_text(encoding="utf-8").split("\n")
        start, end = item["lines"]
        if end > len(lines):
            fail(f"code.json {item['id']}: {item['path']} has {len(lines)} lines, not {end}")
        text = "\n".join(lines[start - 1:end])
        for anchor in item.get("anchors", []):
            if anchor not in text:
                fail(f"code.json {item['id']}: {item['path']}:{start}-{end} no longer holds {anchor!r}; re-check the range")
        dirty = subprocess.run(["git", "-C", str(root), "diff", "--quiet", "HEAD", "--", item["path"]]).returncode != 0
        commit = commits[item.get("repo", "braid")]
        out[item["id"]] = {"repo": item.get("repo", "braid"), "path": item["path"], "lines": [start, end], "highlight": item.get("highlight", []),
                           "text": text, "commit": (commit + ", with uncommitted edits") if dirty else commit}
        sources.append(item["path"])
    return out, sources


# MARK: Main

def main():
    parser = argparse.ArgumentParser(description="Builds Docs/site/data from Braid's fixtures and the playground's run.")
    parser.add_argument("--refresh", action="store_true", help="copy the playground run from --work into Docs/site/fixtures/harbour first")
    parser.add_argument("--work", default=str(REPO / "Examples" / ".work"))
    parser.add_argument("--session", default="NEWEST")
    parser.add_argument("--aii-home", default=None, help="with --refresh: copy the playground lane's stored form from this AII home")
    parser.add_argument("--tokenizer", default=None)
    parser.add_argument("--readme-fixtures", default=str(README_FIXTURES))
    parser.add_argument("--paper", default=str(REPO / "Docs" / "PAPER.md"))
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    if args.refresh:
        refresh_harbour(args.work, args.session)
        if args.aii_home:
            refresh_aii_store(args.aii_home)
    elif args.aii_home:
        fail("--aii-home is read only with --refresh")

    readme_fixtures = Path(args.readme_fixtures)
    manifest = json.loads((readme_fixtures / "fixtures.json").read_text(encoding="utf-8"))
    examples = {e["prompt"]: e for e in manifest.get("examples", [])}

    session_files = sorted(p for p in (readme_fixtures / "sessions").glob("*.jsonl") if not p.name.startswith("._"))
    harbour_sessions = sorted(p for p in (FIXTURES / "sessions").glob("*.jsonl") if not p.name.startswith("._"))
    if not harbour_sessions:
        fail("Docs/site/fixtures/harbour holds no session; run with --refresh")
    sessions = []
    for path in session_files + harbour_sessions[-1:]:
        lines, header, gens = parse_session(path)
        suffix = path.stem.split("-")[-1]
        slug = SESSION_SLUGS.get(suffix) or ("harbour" if path in harbour_sessions else suffix)
        prompt = gens[0]["gen"]["prompt"]["text"]
        label = SESSION_LABELS.get(slug) or (examples[prompt]["label"] if prompt in examples else prompt)
        sessions.append({"path": path, "slug": slug, "suffix": suffix, "label": label, "lines": lines, "header": header, "gens": gens})
    tokenizer_sha = {s["header"]["pack"]["tokenizerSHA256"] for s in sessions}
    if len(tokenizer_sha) != 1:
        fail("the sessions name more than one tokenizer")
    tokenizer_sha = tokenizer_sha.pop()

    tok_path = find_tokenizer(args.tokenizer, args.work)
    tokenizer = None
    if tok_path:
        tokenizer = Tokenizer(tok_path)
        if tokenizer.sha256 != tokenizer_sha:
            fail(f"the tokenizer {tokenizer.sha256[:12]} at {tok_path} is not the sessions' {tokenizer_sha[:12]}")
        if tokenizer.hf.encode("\n\n", add_special_tokens=False).ids != BREAK:
            fail("encode(\"\\n\\n\") is not [535]")
        print(f"tokenizer {tokenizer.sha256[:12]} from {tok_path}")
    else:
        print("no tokenizer found: reusing the tokens in Docs/site/data/threads/*.js")

    # Threads: the README fixtures' three, and the playground's harbour.
    thread_specs = []
    for spec in manifest.get("threads", []):
        thread_specs.append((spec["name"], spec["label"], spec["source"], readme_fixtures / "threads" / spec["name"] / "snapshot.json"))
    harbour_thread = json.loads((FIXTURES / "threads" / "harbour" / "thread.json").read_text(encoding="utf-8"))
    thread_specs.append(("harbour", harbour_thread["label"], harbour_thread["source"], FIXTURES / "threads" / "harbour" / "snapshot.json"))
    threads, layouts = {}, {}
    for name, label, source, snap in thread_specs:
        cached_path = DATA / "threads" / f"{name}.js"
        cached = read_js_value(cached_path) if (not tokenizer and cached_path.is_file()) else None
        thread = load_thread(name, label, source, snap, tokenizer, cached)
        threads[name] = thread
        layouts[name] = expand_layout(thread)

    # The harbour's layout against its own index record.
    index_json = json.loads((FIXTURES / "threads" / "harbour" / "versions" / "v0001" / "index" / "index.json").read_text())
    partitions_json = json.loads((FIXTURES / "threads" / "harbour" / "versions" / "v0001" / "index" / "partitions.json").read_text())
    h = threads["harbour"]
    if h["layout"]["entries"] != index_json["count"]:
        fail(f"harbour: {h['layout']['entries']} entries rebuilt, the index holds {index_json['count']}")
    for ref in partitions_json:
        part = h["partitions"][ref["row"]]
        if (h["documents"][part["doc"]]["id"], part["index"], part["textSHA256"], len(part["tokens"])) != (ref["documentID"], ref["partitionIndex"], ref["textSHA256"], ref["tokenCount"]):
            fail(f"harbour row {ref['row']}: partitions.json disagrees with the snapshot")
    if index_json.get("paragraphBreak") != BREAK:
        fail("the harbour index's paragraph break is not [535]")

    # Sessions: hits and chains on the layouts, end partitions, the verify arithmetic.
    report = {}
    for s in sessions:
        for g in s["gens"]:
            hits, chains = check_hits(s["header"], g, threads, layouts)
            worst, issues = replay(s["header"], g)
            if issues:
                fail(f"{s['path'].name}: " + "; ".join(issues))
            report[s["slug"]] = {"hits": hits, "chains": chains, "worst": worst, "steps": len(g["steps"]), "generated": g["end"]["generated"]}
        print(f"{s['slug']:>17}: {report[s['slug']]['hits']:>5} hits and {report[s['slug']]['chains']:>3} chain states on the layout; "
              f"worst Σshare−1 {report[s['slug']]['worst']['shareSum']:.1e}, memory {report[s['slug']]['worst']['memory']:.1e}, "
              f"H_knn {report[s['slug']]['worst']['hknn']:.1e}, shadow {report[s['slug']]['worst']['shadow']:.1e}")

    store_dir = FIXTURES / "aii-store"
    store = None
    if store_dir.is_dir():
        prov = json.loads((store_dir / "PROVENANCE.json").read_text())
        check_store_filter(store_dir, prov["lane"]["id"], prov["node"], prov["lane"]["owner"])
        checks = json.loads((store_dir / "checks.json").read_text())
        # Not a failure: the site reports how many stored vectors hash back to their stored partition ids.
        store = {"provenance": prov, "documents": {}, "parts": {}, "checks": checks}
        for p in sorted((store_dir / "documents").glob("*.json")):
            store["documents"][p.stem] = json.loads(p.read_text())
        for p in sorted((store_dir / "parts").glob("*.json")):
            store["parts"][p.stem] = json.loads(p.read_text())
        table = json.loads((store_dir / "table-entries.json").read_text())
        store["table"] = {}
        for doc_id, entry in table.items():
            short = {"pq": {k: v for k, v in entry["pq"].items() if k != "codebooks"}, "slots": entry["slots"], "entity_ids": entry["entity_ids"],
                     "metadata": entry.get("metadata"),
                     "codebookShape": [len(entry["pq"]["codebooks"]), len(entry["pq"]["codebooks"][0]), len(entry["pq"]["codebooks"][0][0])]}
            if doc_id.endswith("/harlow-light"):
                short["pq"]["codebooks"] = entry["pq"]["codebooks"]
            if all(len(cb) == 1 for cb in entry["pq"]["codebooks"]):
                # one partition: its single centroid per subvector is the vector itself, kept to 6 decimals for the distance figures
                short["vector"] = [round(x, 6) for cb in entry["pq"]["codebooks"] for x in cb[0]]
            store["table"][doc_id] = short
        store["registry"] = json.loads((store_dir / "registry-lane.json").read_text())
        store["graph"] = json.loads((store_dir / "graph-entities.json").read_text())
        store["embedder"] = json.loads((store_dir / "embedder.json").read_text())
        print(f"AII store: {len(store['documents'])} documents, {sum(1 for c in checks if c['recomputed'])} of {len(checks)} partition ids recomputed, filter clean")
    else:
        print("no AII store fixture (run with --refresh --aii-home ~/.rao to copy it)")

    claim_data = claims(args.paper, REPO / "README.md", REPO / "Docs" / "ARCHITECTURE.md")
    code, code_sources = excerpts(SITE / "src" / "code.json")

    if args.check_only:
        print("checks passed; nothing written (--check-only)")
        return

    written = {}
    for s in sessions:
        value = {"slug": s["slug"], "id": s["suffix"], "label": s["label"], "file": shown(s["path"]), "sha256": sha256_file(s["path"]), "lines": s["lines"]}
        written[f"sessions/{s['slug']}.js"] = js_file(DATA / "sessions" / f"{s['slug']}.js", "sessions", value, [shown(s["path"])], sub=s["slug"])
    for name, thread in threads.items():
        written[f"threads/{name}.js"] = js_file(DATA / "threads" / f"{name}.js", "threads", thread, [thread["snapshot"]["file"]], sub=name)
    steps = [json.loads(l) for l in (FIXTURES / "threads" / "harbour" / "training-steps.jsonl").read_text().splitlines() if l.strip()]
    evals = [json.loads(l) for l in (FIXTURES / "threads" / "harbour" / "training-evals.jsonl").read_text().splitlines() if l.strip()]
    stream = 1 + sum(sum(len(h["partitions"][r]["tokens"]) for r in d["rows"]) + (len(d["rows"]) - 1) * len(BREAK) + 1 for d in h["documents"])
    harbour = {
        "steps": steps, "evals": evals,
        "version": json.loads((FIXTURES / "threads" / "harbour" / "versions" / "v0001" / "version.json").read_text()),
        "index": index_json, "partitions": partitions_json,
        "checkpoints": json.loads((FIXTURES / "threads" / "harbour" / "versions" / "v0001" / "index" / "checkpoints.json").read_text()),
        "thread": harbour_thread, "braidToml": (FIXTURES / "braid.toml").read_text(encoding="utf-8"),
        "provenance": json.loads((FIXTURES / "PROVENANCE.json").read_text()),
        "counts": {"contentTokens": sum(len(p["tokens"]) for p in h["partitions"]), "stream": stream,
                   "tokenCount": sum(sum(len(h["partitions"][r]["tokens"]) for r in d["rows"]) + (len(d["rows"]) - 1) * len(BREAK) + 2 for d in h["documents"]),
                   "entries": h["layout"]["entries"], "records": len(h["documents"])},
    }
    written["harbour.js"] = js_file(DATA / "harbour.js", "harbour", harbour, ["Docs/site/fixtures/harbour"])
    if store:
        written["aii-store.js"] = js_file(DATA / "aii-store.js", "aiiStore", store, ["Docs/site/fixtures/harbour/aii-store"])
    written["claims.js"] = js_file(DATA / "claims.js", "claims", claim_data, ["Docs/PAPER.md", "README.md", "Docs/ARCHITECTURE.md"])
    if code:
        written["code.js"] = js_file(DATA / "code.js", "code", code, ["Docs/site/src/code.json"])
    data_manifest = {
        "builtAt": dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"), "braidCommit": git_head(REPO), "aiiCommit": git_head(AII_REPO),
        "tokenizerSHA256": tokenizer_sha, "tokenized": bool(tokenizer),
        "sessions": [{"slug": s["slug"], "id": s["suffix"], "label": s["label"], "file": shown(s["path"]), "sha256": sha256_file(s["path"]),
                      "strands": s["gens"][0]["gen"]["strands"], "prompt": s["gens"][0]["gen"]["prompt"]["text"],
                      "answer": s["gens"][0]["end"]["text"], "createdAt": s["header"]["createdAt"]} for s in sessions],
        "threads": [{"name": n, "documents": len(t["documents"]), "partitions": len(t["partitions"]), "tokens": sum(len(p["tokens"]) for p in t["partitions"]),
                     "entries": t["layout"]["entries"], "corpusHash": t["corpusHash"]} for n, t in threads.items()],
        "checks": report, "tolerances": TOLERANCES, "bytes": written,
    }
    written["manifest.js"] = js_file(DATA / "manifest.js", "manifest", data_manifest, ["Docs/site/src/data.py"])
    total = sum(written.values())
    print(f"wrote {len(written)} data files, {total / 1024:.0f} KB")
    if total > 1.8 * 1024 * 1024:
        fail(f"data/ is {total / 1048576:.2f} MB, over the 1.8 MB budget")


if __name__ == "__main__":
    try:
        main()
    except Failure as error:
        print(f"data.py: {error}", file=sys.stderr)
        sys.exit(1)
