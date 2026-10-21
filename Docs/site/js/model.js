/*
 * Braid, step by step: the model.
 *
 * Ports of Braid's pure Swift the figures compute with, under the same names: the gate
 * (BraidCore/Mixture/Gate), the mixer (Mixture/Mixer), the verify arithmetic (Record/Verify/
 * SessionReplay), the index layout and the trace tracker (Strand/IndexLayout, Mixture/Trace),
 * citations and spans (Record/Verify/Spans), credit (Record/Credit), the trajectory module
 * (Mixture/Trajectory), the sentence stop (Strand/AnswerStop), the training sampler's generator
 * (Support/Stats SplitMix64, BraidKit DeltaTrainer BatchSampler), and from AII the chunker and
 * the codebook size rule. Logged numbers are float32 in Swift, so they are read through
 * Math.fround here; the arithmetic is in double, as Swift's is.
 *
 * A classic script: it adds Braid.model to window.Braid and nothing else.
 */
(function () {
  "use strict";
  var Braid = (window.Braid = window.Braid || {});
  var M = (Braid.model = {});
  var f32 = Math.fround;

  // MARK: Gate (BraidCore/Mixture/Gate/Gate.swift)

  function GateState(strands, commons, prior) {
    var n = Math.max(0, strands);
    this.memory = [];
    this.credibility = [];
    for (var t = 0; t < n; t++) { this.memory.push(n > 0 ? 1 / n : 0); this.credibility.push(0); }
    this.commons = null;
    if (commons !== null && commons !== undefined && commons >= 0 && commons < n) {
      this.commons = commons;
      var p = n > 1 ? Math.min(Math.max(prior === undefined ? 0.9 : prior, 0), 1) : 1;
      for (var u = 0; u < n; u++) this.memory[u] = u === commons ? p : (1 - p) / (n - 1);
    }
  }
  GateState.prototype.clone = function () {
    var s = Object.create(GateState.prototype);
    s.memory = this.memory.slice(); s.credibility = this.credibility.slice(); s.commons = this.commons;
    return s;
  };

  var Gate = {
    GateState: GateState,
    reach: function (settings) { return Math.max(settings.evidenceCeiling / Math.max(settings.evidenceFloor, 1e-6), 1 + 1e-6); },
    floor: function (openFloor, strands) { return openFloor * 2 / Math.max(2, strands); },
    /** One prompt token: returns every intermediate the figures draw (ratios are the bounded ρ̃). */
    observe: function (state, likelihoods, module, settings) {
      var n = state.memory.length;
      var before = state.memory.slice();
      var floorValue = Math.max(settings.evidenceFloor, 1e-6);
      var span = Math.log(Gate.reach(settings));
      var ratios = [], gains = [], losses = [], raw = [];
      var c = state.commons;
      if (c !== null && (settings.evidence || "lift") === "lift") {
        var base = Math.max(likelihoods[c], 1e-12);
        for (var t = 0; t < n; t++) {
          if (t === c) { ratios.push(1); raw.push(1); continue; }
          var evidence = Math.log(Math.max(likelihoods[t], 1e-300) / base);
          raw.push(Math.exp(evidence));
          if (settings.moduleGain > 0 && module) evidence += settings.moduleGain * Math.min(Math.max(module[t], -1), 1) * span;
          ratios.push(Math.exp(Math.min(Math.max(evidence, -span), span)));
        }
        for (var i = 0; i < n; i++) { gains.push(Math.max(0, Math.log(ratios[i])) / span); losses.push(Math.max(0, -Math.log(ratios[i])) / span); }
      } else {
        var ceiling = Math.max(settings.evidenceCeiling, floorValue);
        for (var a = 0; a < n; a++) {
          var hit = Math.min(Math.max(likelihoods[a], floorValue), ceiling);
          ratios.push(hit / ceiling); raw.push(likelihoods[a]);
          var l = span > 0 ? Math.log(ceiling / hit) / span : 0;
          losses.push(l); gains.push(1 - l);
        }
      }
      var rate = Math.min(Math.max(settings.credibilityRate, 0), 1);
      for (var k = 0; k < n; k++) state.credibility[k] = (1 - rate) * state.credibility[k] + rate * gains[k];
      if (n <= 1) { state.memory = [1]; return { ratios: ratios, raw: raw, gains: gains, losses: losses, before: before, after: [1], weight: 0 }; }
      var others = [];
      for (var o = 0; o < n; o++) if (!((settings.evidence || "lift") === "lift" && c !== null) || o !== c) others.push(o);
      var weight = 0;
      for (var w = 0; w < others.length; w++) weight = w === 0 ? state.credibility[others[w]] : Math.max(weight, state.credibility[others[w]]);
      if (others.length === 0) weight = 0;
      var updated = [], total = 0;
      for (var x = 0; x < n; x++) { updated.push(state.memory[x] * Math.pow(ratios[x], weight)); total += updated[x]; }
      if (total > 0) for (var y = 0; y < n; y++) updated[y] /= total; else updated = state.memory.slice();
      var alpha = Math.min(Math.max(settings.shareRate, 0), 1);
      var given = [], pool = 0;
      for (var z = 0; z < n; z++) { given.push(updated[z] * (1 - Math.pow(1 - alpha, losses[z]))); pool += given[z]; }
      var after = [];
      for (var q = 0; q < n; q++) after.push(updated[q] - given[q] + (pool - given[q]) / (n - 1));
      state.memory = after;
      return { ratios: ratios, raw: raw, gains: gains, losses: losses, before: before, multiplied: updated, given: given, after: after.slice(), weight: weight,
               credibility: state.credibility.slice() };
    },
    shadowWeights: function (memory, traces, beta) {
      if (!memory.length || traces.length !== memory.length) return memory.slice();
      var mean = 0; traces.forEach(function (v) { mean += v; }); mean /= traces.length;
      var gates = memory.map(function (m, t) { return m * Math.exp(beta * (traces[t] - mean)); });
      var total = gates.reduce(function (s, v) { return s + v; }, 0);
      return total > 0 ? gates.map(function (g) { return g / total; }) : memory.slice();
    },
    open: function (gates, commons, floor) {
      if (!gates.length) return [];
      if (gates.every(function (g) { return g <= 0; })) return gates.map(function () { return true; });
      var best = 0;
      for (var t = 0; t < gates.length; t++) if (gates[t] > gates[best]) best = t;
      return gates.map(function (g, t) { return t === best || t === commons || (g >= floor && g > 0); });
    },
    renormalised: function (gates, open) {
      var total = 0, count = 0;
      gates.forEach(function (g, t) { if (open[t]) { total += g; count++; } });
      return gates.map(function (g, t) { return !open[t] ? 0 : (total > 0 ? g / total : 1 / Math.max(count, 1)); });
    },
    entropy: function (weights) { var h = 0; weights.forEach(function (w) { if (w > 0) h -= w * Math.log(w); }); return h; },
    attach: function (state) {
      var n = state.memory.length, threads = [], mass = 0;
      for (var t = 0; t < n; t++) if (t !== state.commons) { threads.push(t); mass += state.memory[t]; }
      var k = threads.length, newcomer;
      if (k > 0) { newcomer = mass / (k + 1); threads.forEach(function (u) { state.memory[u] *= k / (k + 1); }); }
      else if (state.commons !== null) { newcomer = Math.min(Math.max(1 - 0.9, 0), state.memory[state.commons]); state.memory[state.commons] -= newcomer; }
      else newcomer = 1;
      state.memory.push(newcomer); state.credibility.push(0);
    },
    detach: function (state, index) {
      if (index < 0 || index >= state.memory.length || index === state.commons) return;
      var leaving = state.memory[index];
      state.memory.splice(index, 1); state.credibility.splice(index, 1);
      if (state.commons !== null && state.commons > index) state.commons -= 1;
      var threads = [], mass = 0;
      state.memory.forEach(function (m, t) { if (t !== state.commons) { threads.push(t); mass += m; } });
      if (mass > 0) threads.forEach(function (t) { state.memory[t] += leaving * state.memory[t] / mass; });
      else if (state.commons !== null) state.memory[state.commons] += leaving;
      else threads.forEach(function (t) { state.memory[t] += leaving / threads.length; });
    }
  };
  M.Gate = Gate;

  // MARK: Mixer (BraidCore/Mixture/Mixer/Mixer.swift)

  var Mixer = {
    weights: function (scores, tau) {
      if (!scores.length) return [];
      var top = Math.max.apply(null, scores), t = Math.max(tau, 1e-4);
      var exps = scores.map(function (s) { return Math.exp((s - top) / t); });
      var total = exps.reduce(function (a, b) { return a + b; }, 0);
      return exps.map(function (e) { return e / total; });
    },
    entropy: function (ps) { var h = 0; ps.forEach(function (p) { if (p > 0) h -= p * Math.log(p); }); return h; },
    /** A strand's own kNN distribution from its logged hits: per-hit weights, the mass on each value, H_knn. */
    knn: function (hits, tau) {
      var w = Mixer.weights(hits.map(function (h) { return f32(h[1]); }), tau);
      var mass = new Map();
      hits.forEach(function (h, i) { mass.set(h[2], (mass.get(h[2]) || 0) + w[i]); });
      var values = []; mass.forEach(function (v) { values.push(v); });
      return { weights: w, mass: mass, entropy: Mixer.entropy(values) };
    },
    /** p_t(y) = λ·p_knn(y) + (1 − λ)·p_lm(y), from a logged record. */
    probability: function (record, lambda) {
      if (record.plm === undefined || record.plm === null) return null;
      return lambda * f32(record.pknn) + (1 - lambda) * f32(record.plm);
    },
    tieBand: 1e-6
  };
  M.Mixer = Mixer;

  // MARK: Sessions (BraidCore/Record/Session)

  /** Parses a session's JSONL lines into its header and generations, keeping each generation's body lines for the hash. */
  M.parseSession = function (lines) {
    var objects = lines.map(function (l) { return JSON.parse(l); });
    var header = objects[0];
    if (!header || header.kind !== "header") throw new Error("the first line is not a header");
    var gens = [], current = null;
    for (var i = 1; i < objects.length; i++) {
      var o = objects[i], kind = o.kind;
      if (kind === "gen") { current = { gen: o, steps: [], end: null, membership: [], body: [lines[i]] }; gens.push(current); }
      else if (kind === "tok") { if (!current) throw new Error("a tok line outside a generation"); current.steps.push(o); current.body.push(lines[i]); }
      else if (kind === "attach" || kind === "detach") { if (current) { current.membership.push({ before: current.steps.length, line: o }); current.body.push(lines[i]); } }
      else if (kind === "end") { if (current) { current.end = o; current = null; } }
    }
    return { header: header, generations: gens };
  };

  /** The strands of a generation, in its own order, as the header (or an attach line) names them. */
  M.strandsOf = function (header, generation) {
    var known = header.threads.slice();
    generation.membership.forEach(function (m) { if (m.line.kind === "attach") known.push(m.line.thread); });
    return generation.gen.strands.map(function (name) {
      for (var i = known.length - 1; i >= 0; i--) if (known[i].name === name) return known[i];
      throw new Error("no strand named " + name);
    });
  };

  /** Per step, the slots its records are in (attach and detach move strands). */
  M.slotsOf = function (header, generation) {
    var current = M.strandsOf(header, generation).map(slot);
    var result = [], mi = 0;
    generation.steps.forEach(function (step, k) {
      while (mi < generation.membership.length && generation.membership[mi].before === k) {
        var line = generation.membership[mi].line;
        if (line.kind === "attach") current.push(slot(line.thread)); else if (line.t >= 0 && line.t < current.length) current.splice(line.t, 1);
        current = current.slice();
        mi++;
      }
      result.push(step.src === "ctx" && step.t !== undefined ? [current[step.t]] : current);
    });
    return result;
  };
  function slot(thread) { return { name: thread.name, rowOffset: thread.rowOffset, rowCount: thread.rowCount, tau: f32(thread.tau), commons: !!thread.commons, lambda: f32(thread.lambda) }; }

  /** The strand that supplied most of a step's token, when it supplied at least `threshold` (Step.dominant). */
  M.dominant = function (step, threshold) {
    var th = threshold === undefined ? 0.6 : threshold;
    if (!step.thr || !step.thr.length) return null;
    var best = 0;
    for (var t = 1; t < step.thr.length; t++) if (f32(step.thr[t].share) > f32(step.thr[best].share)) best = t;
    return f32(step.thr[best].share) >= f32(th) ? best : null;
  };

  // MARK: The verify arithmetic (BraidCore/Record/Verify/SessionReplay.swift)

  M.tolerances = { shareSum: 1e-5, arithmetic: 1e-6, entropy: 1e-5, memory: 1e-5 };

  /** SessionReplay.check over one generation: the worst deviation per check, the issues past tolerance, and the replayed memory per step. */
  M.replay = function (header, generation, tolerances) {
    var tol = tolerances || M.tolerances;
    var worst = { shareSum: 0, weights: 0, p: 0, share: 0, hknn: 0, shadow: 0, memory: 0 };
    var counts = { steps: 0, shares: 0, weights: 0, hknn: 0, shadow: 0, memory: 0, observed: 0 };
    var issues = [];
    var strands = M.strandsOf(header, generation);
    var commons = strands.findIndex(function (s) { return s.commons; });
    if (commons < 0) commons = null;
    var settings = header.gate;
    var state = new GateState(strands.length, commons, settings.commonsPrior);
    var memoryTrace = [];
    var mi = 0;
    generation.steps.forEach(function (step, k) {
      while (mi < generation.membership.length && generation.membership[mi].before === k) {
        var line = generation.membership[mi].line;
        if (line.kind === "attach") { strands.push(line.thread); Gate.attach(state); } else { strands.splice(line.t, 1); Gate.detach(state, line.t); }
        mi++;
      }
      var threads = step.thr;
      memoryTrace.push(null);
      if (!threads || step.src === "ctx") return;
      if (threads.length !== strands.length) { issues.push({ step: k, check: "strands", detail: threads.length + " records for " + strands.length + " strands" }); return; }
      counts.steps++;
      var n = threads.length;
      var shareSum = 0;
      threads.forEach(function (r) { shareSum += f32(r.share); });
      note("shareSum", Math.abs(shareSum - 1), tol.shareSum, k, null, "Σ share " + shareSum);
      counts.shares += n;
      var gates = threads.map(function (r) { return f32(r.g !== undefined ? r.g : r.mem); });
      var open = threads.map(function (r) { return r.open; });
      var weights = Gate.renormalised(gates, open);
      threads.forEach(function (r, t) { note("weights", Math.abs(weights[t] - f32(r.w)), tol.arithmetic, k, t, "w′"); });
      counts.weights += n;
      var lambdas = strands.map(function (s) { return f32(s.lambda); });
      var probs = threads.map(function (r, t) { return Mixer.probability(r, lambdas[t]); });
      var p = 0;
      threads.forEach(function (r, t) { if (open[t]) p += weights[t] * (probs[t] || 0); });
      note("p", Math.abs(p - f32(step.p)), tol.arithmetic * 10, k, null, "p");
      if (p > 0) threads.forEach(function (r, t) {
        var expected = open[t] ? weights[t] * (probs[t] || 0) / p : 0;
        note("share", Math.abs(expected - f32(r.share)), tol.arithmetic * 10, k, t, "share");
      });
      if ((header.hitsLogged || 0) >= 16) threads.forEach(function (r, t) {
        var h = Mixer.knn(r.hits, f32(strands[t].tau)).entropy;
        note("hknn", Math.abs(h - f32(r.Hknn)), tol.entropy, k, t, "H_knn");
        counts.hknn++;
      });
      var traces = threads.map(function (r) { return r.tr ? f32(r.tr.tr) : 0; });
      var shadow = Gate.shadowWeights(threads.map(function (r) { return f32(r.mem); }), traces, settings.shadowBeta);
      threads.forEach(function (r, t) { note("shadow", Math.abs(shadow[t] - f32(r.sg)), tol.arithmetic * 10, k, t, "shadow gate"); });
      counts.shadow += n;
      threads.forEach(function (r, t) { note("memory", Math.abs(state.memory[t] - f32(r.mem)), tol.memory, k, t, "memory"); });
      counts.memory += n;
      memoryTrace[k] = state.memory.slice();
      if (step.src === "prompt") {
        var likelihoods = threads.map(function (r, t) { return probs[t] !== null ? probs[t] : lambdas[t] * f32(r.pknn); });
        var module = threads.every(function (r) { return r.mod !== undefined && r.mod !== null; }) ? threads.map(function (r) { return f32(r.mod); }) : null;
        Gate.observe(state, likelihoods, module, settings);
        counts.observed++;
      }
    });
    function note(check, value, limit, step, strand, label) {
      if (value > worst[check]) worst[check] = value;
      if (value > limit) issues.push({ step: step, strand: strand, check: check, detail: label + " off by " + value.toExponential(2) });
    }
    return { worst: worst, counts: counts, issues: issues, memory: memoryTrace };
  };

  // MARK: The index layout (BraidCore/Strand/IndexLayout, Mixture/Trace/TraceCorpus; BraidKit TokenizedCorpus)

  /** Rebuilds a Thread's index layout from its tokenized partitions: what each entry's key and value are, and where. */
  M.layout = function (thread) {
    var values = [], keyRow = [], keyOffset = [], valueRow = [], valueOffset = [], documents = [], positions = [];
    var parts = thread.partitions, brk = thread.break;
    thread.documents.forEach(function (d, di) {
      var stream = [];
      d.rows.forEach(function (row, n) {
        var toks = parts[row].tokens;
        for (var i = 0; i < toks.length; i++) stream.push([toks[i], row, i]);
        if (n < d.rows.length - 1) for (var j = 0; j < brk.length; j++) stream.push([brk[j], row, toks.length + j]);
      });
      for (var k = 0; k + 1 < stream.length; k++) {
        values.push(stream[k + 1][0]); keyRow.push(stream[k][1]); keyOffset.push(stream[k][2]);
        valueRow.push(stream[k + 1][1]); valueOffset.push(stream[k + 1][2]); documents.push(di); positions.push(k);
      }
    });
    if (values.length !== thread.layout.entries) throw new Error(thread.name + ": " + values.length + " entries rebuilt, " + thread.layout.entries + " counted");
    var rowTokenCount = parts.map(function (p) { return p.tokens.length; });
    return {
      count: values.length, values: values, keyRow: keyRow, keyOffset: keyOffset, valueRow: valueRow, valueOffset: valueOffset,
      documents: documents, positions: positions, rowTokenCount: rowTokenCount,
      successor: function (e) {
        var next = e + 1;
        if (e < 0 || next >= values.length || documents[next] !== documents[e] || documents[e] < 0 || positions[next] !== positions[e] + 1) return null;
        return next;
      }
    };
  };

  // MARK: The trace (BraidCore/Mixture/Trace)

  M.traceRule = function (rule) {
    var r = rule || { phrase: 24, arc: 96, bridge: 8, heads: 8, seeds: 4 };
    return { phrase: r.phrase, arc: r.arc, bridge: r.bridge, heads: r.heads, seeds: r.seeds,
             trace: function (length) { return r.arc > r.phrase ? Math.min(Math.max((length - r.phrase) / (r.arc - r.phrase), 0), 1) : (length > r.phrase ? 1 : 0); } };
  };

  /** TraceTracker, step for step. */
  function Tracker(corpus, rule) {
    this.corpus = corpus; this.rule = M.traceRule(rule);
    this.live = []; this.fresh = []; this.dormant = []; this.steps = 0;
  }
  Tracker.prototype.step = function (token, hits) {
    var corpus = this.corpus, rule = this.rule, self = this;
    var step = this.steps; this.steps += 1;
    var moved = [], finished = [];
    var heads = this.live.concat(this.fresh);
    for (var i = 0; i < heads.length; i++) {
      var head = Object.assign({}, heads[i]);
      if (head.entry >= corpus.count) continue;
      if (corpus.values[head.entry] === token) {
        head.mass += 1; head.run += 1;
        head.partitionRun = corpus.keyRow[head.entry] === head.partitionRow ? head.partitionRun + 1 : 1;
        if (corpus.keyRow[head.entry] !== head.partitionRow) head.partitionRow = corpus.keyRow[head.entry];
        if (head.run === rule.bridge) this.bridge(head, step);
        var next = corpus.successor(head.entry);
        if (next !== null) { head.entry = next; moved.push(head); }
        else { head.ended = step + 1; head.endPosition = corpus.positions[head.entry] + 1; this.dormant.push(head); finished.push(head); }
      } else if (head.run > 0) {
        head.ended = step; head.endPosition = corpus.positions[head.entry]; this.dormant.push(head);
      }
    }
    var byEntry = new Map();
    moved.forEach(function (h) { var ex = byEntry.get(h.entry); if ((ex ? ex.mass : -1) < h.mass) byEntry.set(h.entry, h); });
    var liveList = []; byEntry.forEach(function (h) { liveList.push(h); });
    liveList.sort(function (a, b) { return a.mass !== b.mass ? b.mass - a.mass : a.entry - b.entry; });
    this.live = liveList.slice(0, rule.heads);
    var sitting = new Set(this.live.map(function (h) { return h.entry; }));
    this.fresh = [];
    for (var s = 0; s < Math.min(rule.seeds, hits.length); s++) {
      var entry = hits[s][0];
      if (entry < 0 || entry >= corpus.count || sitting.has(entry)) continue;
      this.fresh.push({ entry: entry, document: corpus.documents[entry], mass: 0, run: 0, start: step + 1, startPosition: corpus.positions[entry],
                        ended: 0, endPosition: 0, partitionRun: 0, partitionRow: corpus.keyRow[entry] });
    }
    this.dormant = this.dormant.filter(function (d) { return step - d.ended <= 2 * rule.bridge; })
      .sort(function (a, b) { return a.mass !== b.mass ? b.mass - a.mass : a.entry - b.entry; }).slice(0, 2 * rule.heads);
    var best = this.live[0] || null;
    var length = Math.max(best ? best.mass : 0, finished.reduce(function (m, h) { return Math.max(m, h.mass); }, 0));
    var chain = best && best.mass === length ? best : null;
    var partitionRun = Math.max(this.live.reduce(function (m, h) { return Math.max(m, h.partitionRun); }, 0), finished.reduce(function (m, h) { return Math.max(m, h.partitionRun); }, 0));
    var state = { L: length, tr: rule.trace(length), pr: partitionRun };
    if (chain) { state.e = chain.entry; state.row = corpus.keyRow[chain.entry]; state.off = corpus.keyOffset[chain.entry]; state.nx = corpus.values[chain.entry]; }
    state.heads = this.live.map(function (h) { return { entry: h.entry, mass: h.mass, row: corpus.keyRow[h.entry], off: corpus.keyOffset[h.entry] }; });
    state.seeds = this.fresh.map(function (h) { return h.entry; });
    void self;
    return state;
  };
  Tracker.prototype.bridge = function (head, step) {
    var rule = this.rule, best = -1;
    for (var i = 0; i < this.dormant.length; i++) {
      var d = this.dormant[i];
      var text = head.start - d.ended, corpusGap = head.startPosition - d.endPosition;
      if (d.document === head.document && d.run >= rule.bridge && text >= 0 && text <= rule.bridge && corpusGap >= 0 && corpusGap <= rule.bridge) {
        if (best < 0 || this.dormant[best].mass < d.mass) best = i;
      }
    }
    if (best < 0) return;
    head.mass += this.dormant[best].mass;
    this.dormant.splice(best, 1);
    void step;
  };
  M.Tracker = Tracker;

  /** The verifier's trace replay: the tracker over the logged hits; mismatches where L or nx differ from the log. */
  M.replayTrace = function (header, generation, layouts) {
    var strands = M.strandsOf(header, generation);
    var out = {};
    strands.forEach(function (s, t) {
      if (s.commons || !layouts[s.name]) return;
      var tracker = new Tracker(layouts[s.name], header.trace), positions = 0, mismatches = 0, states = [];
      var previous = null;
      generation.steps.forEach(function (step, k) {
        var token = previous;
        previous = step.tok;
        states.push(null);
        if (step.src === "ctx" || !step.thr || token === null) return;
        var state = tracker.step(token, step.thr[t].hits);
        states[k] = state;
        positions++;
        var logged = step.thr[t].tr;
        if (logged && (logged.L !== state.L || (logged.nx === undefined ? null : logged.nx) !== (state.nx === undefined ? null : state.nx))) mismatches++;
      });
      out[s.name] = { strand: t, positions: positions, mismatches: mismatches, states: states };
    });
    return out;
  };

  // MARK: Citations and spans (BraidCore/Record/Verify/Spans.swift)

  var CitationMath = {
    simTerm: function (score) { return f32(Math.min(Math.max(f32((f32(score) - 0.5) / 0.5), 0), 1)); },
    confidence: function (score, support, loss) {
      var product = f32(f32(CitationMath.simTerm(score) * f32(Math.min(Math.max(support, 0), 1))) * f32(Math.exp(-Math.max(loss, 0))));
      return product > 0 ? f32(Math.pow(product, 1 / 3)) : 0;
    }
  };
  M.CitationMath = CitationMath;

  /** The braid's global partition table for a session: global row → its Thread, document and partition. */
  M.partitionTable = function (header, threads) {
    var table = new Map();
    header.threads.forEach(function (s) {
      if (s.commons) return;
      var thread = threads[s.name];
      if (!thread) return;
      thread.partitions.forEach(function (p) {
        var d = thread.documents[p.doc];
        table.set(s.rowOffset + p.row, { row: s.rowOffset + p.row, local: p.row, thread: s.name, label: s.label, documentID: d.id, documentName: d.name,
                                         partitionIndex: p.index, textSHA256: p.textSHA256, tokenCount: p.tokens.length, createdAt: d.createdAt || null, part: p });
      });
    });
    return table;
  };

  function globalHits(step, slots) {
    var hits = [];
    if (!step.thr) return hits;
    step.thr.forEach(function (record, t) {
      if (t >= slots.length) return;
      var w = Mixer.weights(record.hits.map(function (h) { return f32(h[1]); }), slots[t].tau);
      record.hits.forEach(function (h, i) {
        hits.push({ strand: t, rank: i + 1, score: f32(h[1]), weight: f32(f32(record.w) * w[i]), value: h[2], row: slots[t].rowOffset + h[3], offset: h[4], loss: f32(h[5]) });
      });
    });
    return hits;
  }
  function isBreak(row, offset, partitions) { var p = partitions.get(row); return p ? offset >= p.tokenCount : false; }

  function groupedCitations(hits, token, partitions) {
    var groups = new Map();
    hits.forEach(function (hit) {
      if (hit.value !== token || isBreak(hit.row, hit.offset, partitions)) return;
      var ex = groups.get(hit.row);
      if (ex) {
        var better = hit.score > ex.best.score || (hit.score === ex.best.score && hit.rank < ex.best.rank);
        groups.set(hit.row, { weight: f32(ex.weight + hit.weight), best: better ? hit : ex.best });
      } else groups.set(hit.row, { weight: hit.weight, best: hit });
    });
    var citations = [];
    groups.forEach(function (g, row) {
      var p = partitions.get(row);
      if (!p) return;
      citations.push({ row: row, partition: p, offset: g.best.offset, weight: g.weight, bestRank: g.best.rank, bestScore: g.best.score, sourceLoss: g.best.loss,
                       strand: g.best.strand, confidence: CitationMath.confidence(g.best.score, g.weight, g.best.loss) });
    });
    citations.sort(function (a, b) { return a.weight !== b.weight ? b.weight - a.weight : (a.bestScore !== b.bestScore ? b.bestScore - a.bestScore : a.row - b.row); });
    return citations;
  }

  M.spanSettings = { rankThreshold: 3, minSpanLength: 3, maxCitations: 3, maxAlternatives: 5 };

  /** Spans.annotate: citations per step and the selected verbatim spans. `steps` are the generation's non-ctx steps. */
  M.annotate = function (steps, slots, partitions, settings) {
    var S = settings || M.spanSettings;
    var hits = steps.map(function (step, k) { return globalHits(step, slots[k] || []); });
    var all = [], annotations = [];
    steps.forEach(function (step, k) {
      var grouped = groupedCitations(hits[k], step.tok, partitions);
      all.push(grouped);
      annotations.push({ citations: grouped.slice(0, S.maxCitations), confidence: grouped.length ? grouped[0].confidence : null, spanIndex: null });
    });
    var eligible = steps.map(function (step, k) {
      var map = new Map();
      hits[k].forEach(function (hit) {
        if (hit.value !== step.tok || hit.rank > S.rankThreshold || isBreak(hit.row, hit.offset, partitions)) return;
        var key = hit.row + ":" + hit.offset, ex = map.get(key);
        if (ex && ex.rank <= hit.rank) return;
        map.set(key, { rank: hit.rank, weight: hit.weight, row: hit.row, offset: hit.offset });
      });
      return map;
    });
    var chains = [];
    steps.forEach(function (step, k) {
      var keys = []; eligible[k].forEach(function (v) { keys.push(v); });
      keys.sort(function (a, b) { return a.row !== b.row ? a.row - b.row : a.offset - b.offset; });
      keys.forEach(function (pos) {
        if (k > 0 && eligible[k - 1].has(pos.row + ":" + (pos.offset - 1))) return;
        var chain = { start: k, length: 0, row: pos.row, offset: pos.offset, ranks: [], weights: [] };
        while (k + chain.length < steps.length) {
          var info = eligible[k + chain.length].get(pos.row + ":" + (pos.offset + chain.length));
          if (!info) break;
          chain.ranks.push(info.rank); chain.weights.push(info.weight); chain.length += 1;
        }
        if (chain.length >= S.minSpanLength) chains.push(chain);
      });
    });
    function total(c) { var s = 0; c.weights.forEach(function (w) { s = f32(s + w); }); return s; }
    chains.sort(function (a, b) {
      if (a.length !== b.length) return b.length - a.length;
      var ta = total(a), tb = total(b);
      if (ta !== tb) return tb - ta;
      var pa = partitions.get(a.row), pb = partitions.get(b.row);
      var da = pa ? pa.documentID : "", db = pb ? pb.documentID : "";
      if (da !== db) return da < db ? -1 : 1;
      var ia = pa ? pa.partitionIndex : 0, ib = pb ? pb.partitionIndex : 0;
      if (ia !== ib) return ia - ib;
      return a.offset - b.offset;
    });
    var selected = [], alternatives = [];
    chains.forEach(function (chain) {
      var owner = selected.findIndex(function (s) { return chain.start < s.start + s.length && s.start < chain.start + chain.length; });
      if (owner >= 0) {
        if (alternatives[owner].length < S.maxAlternatives && partitions.get(chain.row)) alternatives[owner].push({ row: chain.row, offset: chain.offset, length: chain.length, weight: total(chain) });
        return;
      }
      selected.push(chain); alternatives.push([]);
    });
    var order = selected.map(function (_, i) { return i; }).sort(function (a, b) { return selected[a].start - selected[b].start; });
    var spans = [];
    order.forEach(function (index) {
      var chain = selected[index], partition = partitions.get(chain.row);
      if (!partition) return;
      var members = steps.slice(chain.start, chain.start + chain.length);
      var confidences = members.map(function (_, t) { var c = all[chain.start + t].find(function (x) { return x.row === chain.row; }); return c ? c.confidence : 0; });
      var promptTokens = members.filter(function (s) { return s.src !== "gen"; }).length;
      var span = { kind: promptTokens === members.length ? "promptVerbatim" : "verbatim", start: members[0].i, end: members[members.length - 1].i + 1, startStep: chain.start,
                   length: chain.length, promptTokens: promptTokens, tokens: members.map(function (s) { return s.tok; }), text: members.map(function (s) { return s.txt; }).join(""),
                   row: chain.row, offset: chain.offset, partition: partition, ranks: chain.ranks, weights: chain.weights,
                   confidence: Math.min.apply(null, confidences), alternatives: alternatives[index] };
      var spanIndex = spans.length;
      spans.push(span);
      for (var t = 0; t < chain.length; t++) {
        var k = chain.start + t;
        annotations[k].spanIndex = spanIndex;
        var own = all[k].find(function (x) { return x.row === chain.row; });
        if (own) {
          annotations[k].citations = [own].concat(all[k].filter(function (x) { return x.row !== chain.row; })).slice(0, S.maxCitations);
          annotations[k].confidence = own.confidence;
        }
      }
    });
    return { annotations: annotations, spans: spans };
  };

  // MARK: Credit, followed credit, royalties (BraidCore/Record/Credit)

  var FUNCTION_WORDS = new Set(("a an the this that these those my your his her its our their i you he she it we they me him us them who whom whose which what " +
    "of in on at to for with by from about as into onto over under between through during before after above below up down out off " +
    "near since until upon within without and or but nor so yet if then than because while when where though although whether " +
    "is are was were be been being am has have had do does did will would can could may might shall should must " +
    "not no there here also just very too only more most such each every some any all both either neither other another own same").split(/\s+/));
  var CLITICS = new Set(["'s", "'t", "'re", "'ll", "'d", "'ve", "'m", "’s", "’t", "’re", "’ll", "’d", "’ve", "’m"]);
  var LETTER = /\p{L}/u, NUMBER = /\p{N}/u, SPACE = /\s/u, UPPER = /\p{Lu}/u;
  function chars(s) { return Array.from(s); }
  function isAlnum(ch) { return LETTER.test(ch) || NUMBER.test(ch); }

  var TokenRoles = {
    roles: function (texts) {
      var roles = texts.map(function () { return "content"; }), start = 0;
      function close(end) {
        if (end <= start) return;
        var role = TokenRoles.role(texts.slice(start, end).join("").trim());
        for (var i = start; i < end; i++) roles[i] = role;
        start = end;
      }
      for (var i = 1; i < texts.length; i++) if (TokenRoles.startsWord(texts[i], texts[i - 1])) close(i);
      close(texts.length);
      return roles;
    },
    role: function (word) {
      var cs = chars(word);
      if (!cs.some(isAlnum)) return "form";
      var lower = word.toLowerCase();
      if (CLITICS.has(lower)) return "form";
      if (cs.every(function (c) { return LETTER.test(c); }) && FUNCTION_WORDS.has(lower)) return "form";
      return "content";
    },
    startsWord: function (text, previous) {
      var cs = chars(text);
      if (!cs.length) return false;
      var first = cs[0];
      if (SPACE.test(first) || !isAlnum(first)) return true;
      var ps = chars(previous);
      if (!ps.length) return true;
      return !isAlnum(ps[ps.length - 1]);
    }
  };
  M.TokenRoles = TokenRoles;

  M.sentenceEnded = function (previous, next) {
    if (next.indexOf("\n") >= 0) return true;
    var ps = chars(previous), last = null;
    for (var i = ps.length - 1; i >= 0; i--) if (!SPACE.test(ps[i])) { last = ps[i]; break; }
    if (last === null || ".?!".indexOf(last) < 0) return false;
    var first = chars(next)[0];
    if (first === undefined) return false;
    return SPACE.test(first) || UPPER.test(first);
  };

  M.credit = function (steps, slots) {
    var roles = TokenRoles.roles(steps.map(function (s) { return s.txt; }));
    return steps.map(function (step, i) {
      if (!step.thr) return null;
      var here = slots[i] || [];
      var commons = here.findIndex(function (s) { return s.commons; });
      if (commons < 0) commons = null;
      var role = roles[i];
      var base = commons !== null && step.thr[commons] && step.thr[commons].plm !== undefined ? f32(step.thr[commons].plm) : null;
      var bits = base === null ? null : f32(-Math.log2(Math.max(base, 1e-30)));
      var credit = step.thr.map(function (r, t) { return role === "form" ? (t === commons ? 1 : 0) : f32(r.share); });
      return { role: role, bits: bits, credit: credit, followed: null };
    });
  };

  M.sentences = function (steps) {
    var windows = [], start = null, text = "";
    steps.forEach(function (step, i) {
      if (step.src !== "gen") return;
      if (start !== null && M.sentenceEnded(text, step.txt)) { windows.push({ start: start, end: i }); start = null; text = ""; }
      if (start === null) start = i;
      text += step.txt;
    });
    if (start !== null) windows.push({ start: start, end: steps.length });
    return windows;
  };

  M.followedCredit = function (credits, steps, slots, partitions, margin) {
    var mg = margin === undefined ? 2 : margin;
    var roles = TokenRoles.roles(steps.map(function (s) { return s.txt; }));
    return M.sentences(steps).map(function (window) {
      var advances = {}, documents = {};
      for (var i = window.start; i < window.end; i++) {
        var step = steps[i], here = slots[i] || [];
        if (!step.thr) continue;
        step.thr.forEach(function (record, t) {
          if (t >= here.length || here[t].commons) return;
          var tr = record.tr;
          if (!tr || tr.nx !== step.tok) return;
          var name = here[t].name;
          advances[name] = (advances[name] || 0) + 1;
          if (tr.row !== undefined) { var p = partitions.get(here[t].rowOffset + tr.row); if (p) { documents[name] = documents[name] || {}; documents[name][p.documentID] = (documents[name][p.documentID] || 0) + 1; } }
        });
      }
      var content = 0;
      for (var c = window.start; c < window.end; c++) if (roles[c] === "content") content++;
      var ranked = Object.keys(advances).filter(function (k) { return advances[k] > 0; })
        .sort(function (a, b) { return advances[a] !== advances[b] ? advances[b] - advances[a] : (a < b ? -1 : 1); });
      var followed = null, tied = [];
      if (ranked.length && advances[ranked[0]] * 2 > content) {
        var best = advances[ranked[0]], second = ranked.length > 1 ? advances[ranked[1]] : 0;
        if (second + mg <= best) followed = ranked[0];
        else tied = ranked.filter(function (k) { return advances[k] + mg > best; }).sort();
      }
      for (var j = window.start; j < window.end; j++) {
        var row = credits[j], here2 = slots[j] || [];
        if (!row || row.role !== "content" || !steps[j].thr) continue;
        var holders = steps[j].thr.map(function (_, t) { return t; }).filter(function (t) { return t < here2.length && !here2[t].commons && row.credit[t] > 0; });
        if (holders.length < 2) continue;
        var pooled = holders.reduce(function (s, t) { return f32(s + row.credit[t]); }, 0);
        var follower = followed ? here2.findIndex(function (s) { return s.name === followed; }) : -1;
        if (followed && follower >= 0) { holders.forEach(function (t) { row.credit[t] = 0; }); row.credit[follower] = pooled; row.followed = follower; }
        else if (tied.length >= 2) {
          var sharers = holders.filter(function (t) { return tied.indexOf(here2[t].name) >= 0; });
          if (sharers.length < 2) continue;
          var among = sharers.reduce(function (s, t) { return f32(s + row.credit[t]); }, 0);
          sharers.forEach(function (t) { row.credit[t] = f32(among / sharers.length); });
        }
      }
      return { window: window, followed: followed, tied: tied, advances: advances, content: content };
    });
  };

  M.royalties = function (steps, credits, slots, partitions) {
    var lines = {}, order = [], documents = {}, generated = 0;
    steps.forEach(function (step, i) {
      if (step.src !== "gen" || !step.thr) return;
      var here = slots[i] || [];
      generated++;
      var dominant = M.dominant(step);
      step.thr.forEach(function (record, t) {
        if (t >= here.length) return;
        var name = here[t].name;
        if (!lines[name]) { order.push(name); lines[name] = { name: name, commons: here[t].commons, led: 0, share: 0, credit: 0, bits: 0 }; }
        var line = lines[name];
        if (dominant === t) line.led++;
        line.share += f32(record.share);
        var row = credits[i];
        if (row && t < row.credit.length) { var bits = row.bits === null ? 1 : row.bits; line.credit += row.credit[t] * bits; line.bits += bits * f32(record.share); }
      });
      var top = 0;
      for (var t = 1; t < step.thr.length; t++) if (f32(step.thr[t].share) > f32(step.thr[top].share)) top = t;
      if (top < here.length && !here[top].commons) {
        var rec = step.thr[top], w = Mixer.weights(rec.hits.map(function (h) { return f32(h[1]); }), here[top].tau), best = null;
        rec.hits.forEach(function (h, k) { if (h[2] === step.tok && (best === null || w[k] > best.weight)) best = { weight: w[k], row: here[top].rowOffset + h[3] }; });
        if (best) {
          var p = partitions.get(best.row);
          if (p) { var key = here[top].name + "|" + p.documentID; documents[key] = documents[key] || { name: here[top].name, documentID: p.documentID, documentName: p.documentName, tokens: 0, share: 0 }; documents[key].tokens++; documents[key].share += f32(rec.share); }
        }
      }
    });
    var docs = Object.keys(documents).map(function (k) { return documents[k]; })
      .sort(function (a, b) { return a.share !== b.share ? b.share - a.share : (a.documentID !== b.documentID ? (a.documentID < b.documentID ? -1 : 1) : (a.name < b.name ? -1 : 1)); });
    return { strands: order.map(function (n) { return lines[n]; }), documents: docs, generated: generated };
  };

  // MARK: The trajectory module (BraidCore/Mixture/Trajectory)

  M.moduleSettings = function (s) {
    var m = Object.assign({ window: 8, minimumPoints: 4, horizon: 4, k: 16, thetaLM: 0.5, thetaKNN: 0.5, thetaLift: Math.log(2), span: 8, coherent: Math.log(2), coherentRun: 24 }, s || {});
    m.referenceSlope = Math.log(m.k) / m.window;
    return m;
  };
  M.slope = function (values) {
    if (values.length < 2) return null;
    var n = values.length, mx = (n - 1) / 2, my = values.reduce(function (a, b) { return a + b; }, 0) / n, sxy = 0, sxx = 0;
    values.forEach(function (y, i) { var dx = i - mx; sxy += dx * (y - my); sxx += dx * dx; });
    return sxx > 0 ? sxy / sxx : null;
  };
  /** The series the live module reads: every prompt and generated position with strands (no ctx in these sessions). */
  M.moduleSeries = function (steps, commons) {
    var positions = steps.filter(function (s) { return s.src !== "ctx" && s.thr; });
    if (!positions.length) return [];
    return positions[0].thr.map(function (_, t) {
      return {
        steps: positions.map(function (s) { return s.i; }),
        hlm: positions.map(function (s) { return s.thr[t].Hlm === undefined ? null : f32(s.thr[t].Hlm); }),
        hknn: positions.map(function (s) { return f32(s.thr[t].Hknn); }),
        lift: positions.map(function (s) {
          if (commons === null || t === commons || s.thr[t].plm === undefined || s.thr[commons].plm === undefined) return null;
          return Math.log(Math.max(f32(s.thr[t].plm), 1e-30)) - Math.log(Math.max(f32(s.thr[commons].plm), 1e-30));
        }),
        trace: positions.map(function (s) { return s.thr[t].tr ? f32(s.thr[t].tr.tr) : 0; }),
        commonsHLM: positions.map(function (s) { return commons === null || s.thr[commons].Hlm === undefined ? null : f32(s.thr[commons].Hlm); })
      };
    });
  };
  M.moduleRead = function (s, j, settings) {
    var S = M.moduleSettings(settings);
    var start = Math.max(0, j - S.window + 1), window = s.hknn.slice(start, j + 1);
    var slope = null, forecast = null, evidence = 0, collapse = 0, divergence = 0;
    var fitted = window.length >= S.minimumPoints ? M.slope(window) : null;
    if (fitted !== null) {
      slope = fitted;
      forecast = Math.min(Math.max(s.hknn[j] + S.horizon * fitted, 0), Math.log(S.k));
      collapse = Math.min(Math.max(-fitted / S.referenceSlope, 0), 1);
      divergence = Math.min(Math.max(fitted / S.referenceSlope, 0), 1);
      var own = s.hlm[j], base = s.commonsHLM[j];
      if (own !== null && base !== null) { if (!(s.hknn[j] > base && own > base)) divergence = 0; } else divergence = 0;
      evidence = collapse - divergence;
    }
    var lnk = Math.log(S.k), label = "silent";
    if (s.hlm[j] !== null && s.lift[j] !== null) {
      var b = s.commonsHLM[j] !== null ? s.commonsHLM[j] : lnk;
      var collapsed = s.hlm[j] <= S.thetaLM * b, unsupported = s.hknn[j] >= S.thetaKNN * lnk, lift = s.lift[j];
      if (lift <= 0) label = "commons";
      else if (collapsed && unsupported && lift >= S.thetaLift) label = "stitched";
      else if (collapsed && !unsupported) label = "retrieval";
      else if (!collapsed && unsupported) label = "unknown";
      else label = "retrieval";
    }
    return { slope: slope, forecast: forecast, collapse: collapse, divergence: divergence, evidence: evidence, label: label, coherent: s.hknn[j] <= S.coherent, window: [start, j] };
  };
  M.moduleReadAll = function (s, settings) {
    var S = M.moduleSettings(settings);
    var readings = s.hknn.map(function (_, j) { return M.moduleRead(s, j, S); });
    var stitched = runs(readings.map(function (r) { return r.label === "stitched"; }), S.span);
    var coherent = runs(readings.map(function (r) { return r.coherent; }), S.coherentRun);
    readings.forEach(function (r, j) { r.stitchedRun = stitched[j]; r.coherentRun = coherent[j]; });
    return readings;
  };
  function runs(flags, atLeast) {
    var marked = flags.map(function () { return false; }), start = 0;
    while (start < flags.length) {
      if (!flags[start]) { start++; continue; }
      var end = start;
      while (end < flags.length && flags[end]) end++;
      if (end - start >= atLeast) for (var k = start; k < end; k++) marked[k] = true;
      start = end;
    }
    return marked;
  }
  /** The e_t each step logs as `mod`: the reading at the previous position with strands (0 at the first). */
  M.loggedModule = function (series, settings) {
    var readings = M.moduleReadAll(series, settings);
    return series.hknn.map(function (_, j) { return j === 0 ? 0 : readings[j - 1].evidence; });
  };

  // MARK: The training sampler (BraidCore/Support/Stats SplitMix64; BraidKit/Build/Training/DeltaTrainer BatchSampler)

  function SplitMix64(seed) { this.state = BigInt.asUintN(64, BigInt(seed)); }
  SplitMix64.prototype.next = function () {
    this.state = BigInt.asUintN(64, this.state + 0x9E3779B97F4A7C15n);
    var z = this.state;
    z = BigInt.asUintN(64, (z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n);
    z = BigInt.asUintN(64, (z ^ (z >> 27n)) * 0x94D049BB133111EBn);
    return z ^ (z >> 31n);
  };
  /** Swift's next(upperBound:) (Lemire), for Int.random(in:using:) inside Array.shuffle(using:). */
  SplitMix64.prototype.below = function (upper) {
    var U = BigInt(upper), random = this.next(), m = random * U, low = BigInt.asUintN(64, m);
    if (low < U) {
      var t = BigInt.asUintN(64, -U) % U;
      while (low < t) { random = this.next(); m = random * U; low = BigInt.asUintN(64, m); }
    }
    return Number(m >> 64n);
  };
  M.SplitMix64 = SplitMix64;
  M.windowPlan = function (streamLength, seqLen, batchSize, seed, epoch) {
    var rng = new SplitMix64(BigInt.asUintN(64, BigInt(seed) + BigInt(epoch) * 0x9E3779B9n));
    var room = Math.max(1, Math.min(seqLen, streamLength - seqLen - 1));
    var offset = Number(rng.next() % BigInt(room));
    var starts = [];
    for (var s = offset; s < streamLength - seqLen - 1; s += seqLen) starts.push(s);
    if (!starts.length) starts = [0];
    var amount = starts.length, current = 0;
    while (amount > 1) { var r = rng.below(amount); amount -= 1; var tmp = starts[current]; starts[current] = starts[current + r]; starts[current + r] = tmp; current += 1; }
    var batches = [];
    for (var i = 0; i < starts.length; i += batchSize) {
      var batch = starts.slice(i, i + batchSize), fill = 0;
      while (batch.length < batchSize) { batch.push(starts[fill % starts.length]); fill++; }
      batches.push(batch);
    }
    return { offset: offset, room: room, starts: starts, batches: batches, windows: Math.max(1, Math.floor((streamLength - 1) / seqLen)) };
  };
  M.learningRate = function (step, planned, hyper) {
    var h = Object.assign({ peakLR: 5e-4, finalLR: 1e-4, warmupFraction: 0.05 }, hyper || {});
    var warm = Math.max(1, Math.floor(planned * h.warmupFraction));
    if (step < warm) return h.peakLR * (0.01 + 0.99 * step / warm);
    var progress = Math.min(1, (step - warm) / Math.max(1, planned - warm));
    return h.finalLR + 0.5 * (h.peakLR - h.finalLR) * (1 + Math.cos(Math.PI * progress));
  };

  // MARK: AII (Sources/AII/Join/AIIChunker.swift; Sources/Thread/.../PartitionQuantizer.swift)

  var graphemes = typeof Intl !== "undefined" && Intl.Segmenter ? new Intl.Segmenter("en", { granularity: "grapheme" }) : null;
  function count(s) { if (!graphemes) return chars(s).length; var n = 0; for (var _ of graphemes.segment(s)) n++; return n; }
  function prefix(s, n) { if (!graphemes) return chars(s).slice(0, n).join(""); var out = "", k = 0; for (var g of graphemes.segment(s)) { if (k++ >= n) break; out += g.segment; } return out; }
  function dropFirst(s, n) { if (!graphemes) return chars(s).slice(n).join(""); var out = "", k = 0; for (var g of graphemes.segment(s)) { if (k++ >= n) out += g.segment; } return out; }
  M.chunk = function (text, target, maximum) {
    var T = target || 1500, X = maximum || 2000;
    var paragraphs = text.split("\n\n").map(function (p) { return p.trim(); }).filter(function (p) { return p.length > 0; });
    var pieces = [], current = "";
    function flush() { if (current.length) pieces.push(current); current = ""; }
    paragraphs.forEach(function (paragraph) {
      if (count(paragraph) > X) { flush(); pieces = pieces.concat(sentencesOf(paragraph, T, X)); }
      else if (!current.length) current = paragraph;
      else if (count(current) + 2 + count(paragraph) <= T) current += "\n\n" + paragraph;
      else { flush(); current = paragraph; }
    });
    flush();
    return pieces;
  };
  function sentencesOf(paragraph, T, X) {
    var sentences = [];
    if (typeof Intl !== "undefined" && Intl.Segmenter) {
      for (var s of new Intl.Segmenter("en", { granularity: "sentence" }).segment(paragraph)) { var t = s.segment.trim(); if (t) sentences.push(t); }
    } else sentences = (paragraph.match(/[^.!?]+(?:[.!?]+|$)/g) || []).map(function (x) { return x.trim(); }).filter(Boolean);
    var pieces = [], current = "";
    sentences.forEach(function (sentence) {
      hardSplit(sentence, X).forEach(function (part) {
        if (!current.length) current = part;
        else if (count(current) + 1 + count(part) <= T) current += " " + part;
        else { pieces.push(current); current = part; }
      });
    });
    if (current.length) pieces.push(current);
    return pieces;
  }
  function hardSplit(sentence, X) {
    if (count(sentence) <= X) return [sentence];
    var parts = [], rest = sentence;
    while (rest.length) { parts.push(prefix(rest, X)); rest = dropFirst(rest, X); }
    return parts;
  }
  M.codebookSize = function (vectorCount) {
    var ideal = Math.floor(vectorCount / 39);
    if (ideal < 2) return 2;
    var k = 1;
    while (k * 2 <= ideal && k * 2 <= 65536) k *= 2;
    return k;
  };

  // MARK: SHA-256 (pure, synchronous: the same bytes in every browser, from file:// too)

  var K = new Uint32Array([0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
    0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb,
    0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c,
    0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2]);
  M.sha256 = function (input) {
    var bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
    var len = bytes.length, total = ((len + 9 + 63) >> 6) << 6, buf = new Uint8Array(total);
    buf.set(bytes); buf[len] = 0x80;
    var bits = len * 8, view = new DataView(buf.buffer);
    view.setUint32(total - 8, Math.floor(bits / 0x100000000)); view.setUint32(total - 4, bits >>> 0);
    var h = new Uint32Array([0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]), w = new Uint32Array(64);
    for (var off = 0; off < total; off += 64) {
      for (var i = 0; i < 16; i++) w[i] = view.getUint32(off + i * 4);
      for (var j = 16; j < 64; j++) {
        var x = w[j - 15], y = w[j - 2];
        var s0 = ((x >>> 7) | (x << 25)) ^ ((x >>> 18) | (x << 14)) ^ (x >>> 3), s1 = ((y >>> 17) | (y << 15)) ^ ((y >>> 19) | (y << 13)) ^ (y >>> 10);
        w[j] = (w[j - 16] + s0 + w[j - 7] + s1) >>> 0;
      }
      var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
      for (var r = 0; r < 64; r++) {
        var S1 = ((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7)), ch = (e & f) ^ (~e & g);
        var t1 = (hh + S1 + ch + K[r] + w[r]) >>> 0;
        var S0 = ((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10)), maj = (a & b) ^ (a & c) ^ (b & c);
        var t2 = (S0 + maj) >>> 0;
        hh = g; g = f; f = e; e = (d + t1) >>> 0; d = c; c = b; b = a; a = (t1 + t2) >>> 0;
      }
      h[0] = (h[0] + a) >>> 0; h[1] = (h[1] + b) >>> 0; h[2] = (h[2] + c) >>> 0; h[3] = (h[3] + d) >>> 0;
      h[4] = (h[4] + e) >>> 0; h[5] = (h[5] + f) >>> 0; h[6] = (h[6] + g) >>> 0; h[7] = (h[7] + hh) >>> 0;
    }
    var out = new Uint8Array(32), ov = new DataView(out.buffer);
    for (var q = 0; q < 8; q++) ov.setUint32(q * 4, h[q]);
    return out;
  };
  M.hex = function (bytes) { return Array.from(bytes).map(function (b) { return b.toString(16).padStart(2, "0"); }).join(""); };
  M.decimalDigits = function (bytes) { return Array.from(bytes).map(String).join(""); };
  M.bodySHA256 = function (bodyLines) { return M.hex(M.sha256(bodyLines.map(function (l) { return l + "\n"; }).join(""))); };
})();
