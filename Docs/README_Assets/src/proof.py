"""Renders how the proof tests the delta (Examples/Sources/Proof), in the hero's style.

    python3 -I Docs/README_Assets/src/proof.py Docs/README_Assets

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts.
Outputs: proof-test.png in argv[1].

Two arms on one corpus behind one commons: the delta arm trains blocks 0..<12 of its own, the frozen
arm keeps the commons' blocks bit for bit; both index the same documents and withhold the same ones
(main.swift, ProofOptions.swift: 60 documents, 0.33 withheld). Five text sets (ProofTexts.swift), five
rules fixed before the run (ProofRules.swift). The numbers are the craft run's report,
Examples/.work/bench/proof/20261020-061446.json (2026-10-19), typed in from it.
"""

import os
import sys
import tempfile

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

GREEN, GOLD, LINE = "#28a883", "#c7a659", "#cbc8c0"
W, H = 1600, 1330
MONO = "Menlo, 'SF Mono', monospace"
SANS = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"

# The arms: (top, label, head caption, head body, head class, index body)
ROWS = [
    (372, "DELTA ARM", "its head", "trained on all 60 documents", "delta", "the same 40"),
    (474, "FROZEN ARM", "its head", "the commons' own, bit for bit", "", "the same 40"),
]
ROW_H = 84
COLS = {"head": (390, 620), "tail": (656, 820), "reed": (856, 990), "index": (1026, 1180)}
LIFT_TOP, ZERO, SCALE = 702, 1400, 30

# Mean lift over the commons by set, the delta arm (the report's rows). The frozen arm's is 0 on every set.
LIFT = [("withheld", 3.615), ("own", 3.528), ("unseen", 2.347), ("unrelated", -2.871)]

SETS = [
    ("own", "20", "trained on and indexed", "CITATION", GOLD),
    ("own, shuffled", "20", "the same sentences, reordered", "REPORTED", "#77756f"),
    ("withheld", "19", "trained on, never indexed", "DETECTION", GREEN),
    ("unseen", "20", "the same voice, never read", "DETECTION'S NULL", GREEN),
    ("unrelated", "24", "other nodes and plain prose", "CITATION'S NULL", GOLD),
]

RULES = [
    ("C0", "the control is exact", "the frozen arm's H<sub>lm</sub> against the commons', at every position", "equal within 0.00001", "20,600 of 20,600", ""),
    ("D1", "the delta knows its training without an index", "lift: withheld ranked above unseen", "AUROC ≥ 0.95", "1.000", "det"),
    ("D2", "the commons' head does not", "H<sub>lm</sub>: withheld ranked surer than unseen", "delta ≥ 0.95; frozen below 0.95 and 0.10 under", "1.000 · frozen 0.529", "det"),
    ("R1", "the index finds what it holds", "H<sub>knn</sub>: own ranked surer than unrelated", "both arms ≥ 0.95", "1.000 · 1.000", ""),
    ("R2", "the delta sharpens what it cites", "H<sub>knn</sub>: the delta's below the frozen arm's on own texts", "≥ 90% of texts, z ≥ 3", "100% · z 26.7", ""),
]


def arrow(x0, x1, y, colour=LINE, width=2):
    return (f'<line x1="{x0}" y1="{y}" x2="{x1 - 3}" y2="{y}" stroke="{colour}" stroke-width="{width}" stroke-linecap="round"/>'
            f'<path d="M{x1 - 11},{y - 6} L{x1 - 2},{y} L{x1 - 11},{y + 6}" fill="none" stroke="{colour}" stroke-width="{width}" stroke-linecap="round" stroke-linejoin="round"/>')


def svg():
    p = []
    for top, _, _, _, cls, _ in ROWS:
        y = top + ROW_H / 2
        colour = GREEN if cls else LINE
        p.append(arrow(330, COLS["head"][0], y, colour, 2.4 if cls else 2))
        p.append(arrow(COLS["head"][1], COLS["tail"][0], y, colour, 2.4 if cls else 2))
        p.append(arrow(COLS["tail"][1], COLS["reed"][0], y, colour, 2.4 if cls else 2))
        p.append(f'<line x1="{COLS["reed"][1]}" y1="{y}" x2="{COLS["index"][0]}" y2="{y}" stroke="#55534d" stroke-width="1.4" stroke-dasharray="3 5"/>')
    # The lift chart.
    zero, top, scale = ZERO, LIFT_TOP, SCALE
    p.append(f'<line x1="{zero}" y1="{top - 8}" x2="{zero}" y2="{top + 4 * 34 - 4}" stroke="#77756f" stroke-width="1.2"/>')
    for i, (name, v) in enumerate(LIFT):
        y = top + i * 34
        x = zero if v >= 0 else zero + v * scale
        w = abs(v) * scale
        p.append(f'<rect x="{x}" y="{y}" width="{w}" height="18" rx="3" fill="{GREEN if v >= 0 else "#55534d"}" opacity="{1 if name == "withheld" else .55}"/>')
    return f'<svg width="{W}" height="{H}">{"".join(p)}</svg>'


def cell(col, top, caption, title, body, cls=""):
    x0, x1 = COLS[col]
    return (f'<div class="card {cls}" style="left:{x0}px; top:{top}px; width:{x1 - x0}px; height:{ROW_H}px">'
            f'<div class="cap">{caption}</div><b>{title}</b><p>{body}</p></div>')


def rows():
    out = []
    for top, label, title, body, cls, index in ROWS:
        out.append(cell("head", top, label, title, body, cls))
        out.append(cell("tail", top, "THE COMMONS'", "tail", "the same modules"))
        out.append(cell("reed", top, "THE COMMONS'", "reed", "the same"))
        out.append(cell("index", top, "ITS", "index", index))
    return "".join(out)


def page():
    sets = "".join(f'<div class="set"><div class="tagline" style="color:{c}">{t}</div><b>{n}</b><span class="count">{k}</span><p>{d}</p></div>'
                   for n, k, d, t, c in SETS)
    rules = "".join(f'<div class="rule {cls}"><span class="id">{i}</span><span class="claim">{c}</span><span>{how}</span><span class="bar">{bar}</span>'
                    f'<span class="result">{res}</span></div>' for i, c, how, bar, res, cls in RULES)
    lift_labels = "".join(f'<div class="liftlabel" style="top:{LIFT_TOP + i * 34 - 2}px">{n}</div>'
                          + (f'<div class="liftvalue" style="right:{W - ZERO + 8}px; top:{LIFT_TOP + i * 34 + 1}px">{v:+.2f}</div>' if v >= 0 else
                             f'<div class="liftvalue" style="left:{ZERO + 8}px; top:{LIFT_TOP + i * 34 + 1}px">{v:+.2f}</div>')
                          for i, (n, v) in enumerate(LIFT))
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic; color: #a29f97;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 62.5px; top: 50px; width: 64px; }}
.caption {{ position: absolute; left: 150px; top: 68px; letter-spacing: .3em; font-size: 15px; color: #8b8a84; }}
.title {{ position: absolute; left: 21px; padding-left: 40px; top: 104px; font-size: 98px; line-height: 1; font-weight: 500; letter-spacing: -.005em; padding-right: 30px; padding-bottom: 32px;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; }}
.sub {{ position: absolute; left: 69px; top: 222px; font-size: 30px; color: #9b9991; }}
svg {{ position: absolute; left: 0; top: 0; }}
.section {{ position: absolute; left: 70px; font-size: 11.5px; letter-spacing: .24em; color: #8b8a84; }}
.section em {{ font-style: italic; letter-spacing: 0; font-size: 17px; color: #a29f97; margin-left: 10px; }}
.card {{ position: absolute; box-sizing: border-box; border: 1px solid rgba(255,255,255,.12); border-radius: 12px; background: #1c1c19; padding: 9px 14px; }}
.card.delta {{ border-color: rgba(40,168,131,.75); background: #17211c; }}
.card .cap {{ font-size: 10.5px; letter-spacing: .2em; color: #77756f; white-space: nowrap; }}
.card.delta .cap {{ color: {GREEN}; }}
.card b {{ display: block; font-weight: 400; font-size: 20px; color: #ecebe5; margin-top: 1px; }}
.card p {{ margin: 2px 0 0; font-size: 14.5px; line-height: 1.25; color: #a29f97; }}
.corpus {{ position: absolute; left: 70px; top: 372px; width: 260px; height: 194px; box-sizing: border-box; border: 1px solid rgba(255,255,255,.12);
          border-radius: 12px; background: #1c1c19; padding: 12px 16px; }}
.corpus b {{ display: block; font-weight: 400; font-size: 24px; color: #ecebe5; }}
.corpus p {{ margin: 4px 0 0; font-size: 15px; line-height: 1.3; }}
.split {{ display: flex; height: 10px; border-radius: 5px; overflow: hidden; margin: 12px 0 8px; }}
.split i {{ display: block; }}
.why {{ position: absolute; left: 1236px; top: 372px; width: 294px; }}
.why h4, .liftbox h4 {{ margin: 0; font-size: 11.5px; font-weight: 400; letter-spacing: .22em; color: #8b8a84; }}
.why p {{ margin: 8px 0 0; font-size: 16.5px; line-height: 1.4; color: #b4b1a9; }}
.why p b {{ font-weight: 400; color: {GREEN}; }}
.sets {{ position: absolute; left: 70px; top: 684px; width: 1110px; display: grid; grid-template-columns: repeat(5, 1fr); column-gap: 14px; }}
.set {{ border: 1px solid rgba(255,255,255,.1); border-radius: 12px; padding: 10px 14px; background: rgba(255,255,255,.02); }}
.set .tagline {{ font-size: 10.5px; letter-spacing: .2em; }}
.set b {{ font-weight: 400; font-size: 20px; color: #ecebe5; }}
.set .count {{ margin-left: 8px; font-family: {MONO}; font-style: normal; font-size: 12.5px; color: #8f8c84; }}
.set p {{ margin: 3px 0 0; font-size: 14.5px; line-height: 1.25; }}
.liftbox {{ position: absolute; left: 1236px; top: 640px; display: none; width: 294px; }}
.liftbox p {{ margin: 6px 0 0; font-size: 14.5px; line-height: 1.3; }}
.rid {{ font-family: {MONO}; font-style: normal; font-size: .82em; color: {GOLD}; }}
.liftnote {{ position: absolute; left: 1236px; top: 670px; font-size: 14px; color: #8f8c84; }}
.liftlabel {{ position: absolute; left: 1236px; font-size: 15px; color: #a29f97; }}
.liftvalue {{ position: absolute; font-family: {MONO}; font-style: normal; font-size: 12px; color: #a7a49b; }}
.rules {{ position: absolute; left: 70px; top: 868px; width: 1110px; }}
.rule {{ display: grid; grid-template-columns: 40px 250px 1fr 230px 150px; column-gap: 14px; align-items: baseline; padding: 11px 6px;
        border-bottom: 1px solid rgba(255,255,255,.07); font-size: 15.5px; line-height: 1.3; }}
.rule.det {{ background: rgba(40,168,131,.07); }}
.rule .id {{ font-family: {MONO}; font-style: normal; font-size: 13px; color: {GOLD}; }}
.rule.det .id {{ color: {GREEN}; }}
.rule .claim {{ color: #e3e1da; }}
.rule .bar {{ color: #8f8c84; }}
.rule .result {{ font-family: {MONO}; font-style: normal; font-size: 13px; color: #e3e1da; text-align: right; }}
.rule.head {{ font-size: 10.5px; letter-spacing: .2em; color: #77756f; padding-top: 0; }}
.legend {{ position: absolute; left: 70px; top: 1190px; width: 1460px; display: grid; grid-template-columns: repeat(3, 1fr); column-gap: 36px; }}
.legend div {{ border-top: 1px solid rgba(255,255,255,.1); padding-top: 10px; font-size: 15.5px; line-height: 1.4; }}
.legend b {{ font-weight: 400; color: #e3e1da; }}
sub {{ font-size: .68em; vertical-align: -.3em; line-height: 0; }}
.tag {{ position: absolute; right: 70px; top: 1276px; font-size: 18px; color: #8b8a84; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">RAO STUDIOS · A BRAIDED LANGUAGE MODEL · THE PROOF</div>
<div class="title">Two arms, one difference</div>
<div class="sub">the same writing, index, tail and reed; only one head is trained</div>
{svg()}
<div class="section" style="top:338px">1 · THE ARMS<em>two Threads on one corpus, scored side by side with the commons in one braid</em></div>
<div class="corpus"><b>craft</b><p>60 documents from braid-n3</p>
  <div class="split"><i style="flex:40; background:{LINE}; opacity:.6"></i><i style="flex:20; background:{GREEN}"></i></div>
  <p>40 indexed by both arms<br><span style="color:{GREEN}">20 withheld: no index holds them; only the delta trained on them</span></p></div>
{rows()}
<div class="card" style="left:390px; top:{474 + ROW_H + 18}px; width:{1180 - 390}px; height:44px; padding-top:11px"><p style="margin:0; font-size:15px">the commons runs beside both, whole and untrained: the reference for lift, and the control <code class="rid">C0</code> checks against</p></div>
<div class="why"><h4>WHY THIS ISOLATES THE DELTA</h4>
  <p>H<sub>lm</sub> is read from the reed's odds on s, the state after head and tail. Both arms run the same tail and reed, so they can differ only by their heads.</p>
  <p>The frozen head is the commons' own, so its H<sub>lm</sub> must equal the commons'. <code class="rid">C0</code> checks that it does. <b>Any change in H<sub>lm</sub> is then the delta's.</b></p></div>
<div class="section" style="top:650px">2 · THE TEXTS<em>five sets, each read by the rule it fits</em></div>
<div class="sets">{sets}</div>
<div class="section" style="left:1236px; top:650px">LIFT, DELTA ARM</div><div class="liftnote">mean lift per set; the frozen arm\'s is 0 on every set</div>
{lift_labels}
<div class="section" style="top:836px">3 · THE RULES<em>written before the run; proved only if all five pass</em></div>
<div class="rules">
  <div class="rule head"><span></span><span>THE CLAIM</span><span>HOW IT IS READ</span><span>THE BAR</span><span style="text-align:right">CRAFT</span></div>
  {rules}
</div>
<div class="legend">
  <div><b>H<sub>lm</sub></b>: how unsure the Thread is of the next word; 0 is certain. <b>lift</b>: how much likelier the word is to the Thread than to the commons.</div>
  <div><b>H<sub>knn</sub></b>: how much the 16 closest places in the index disagree on the next word; low means they agree.</div>
  <div><b>AUROC</b>: how often a text from the first set ranks above one from the second. 1 is always; 0.5 is a coin flip.</div>
</div>
<div class="tag">proved on craft, 2026-10-19 · Examples/proof.sh</div>
</body></html>"""


def main():
    with tempfile.NamedTemporaryFile("w", suffix=".html", dir=HERE, delete=False, encoding="utf-8") as f:
        f.write(page())
        name = f.name
    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(channel="chrome")
            tab = browser.new_page(device_scale_factor=2, viewport={"width": W, "height": H})
            tab.goto("file://" + name)
            tab.wait_for_timeout(200)
            tab.screenshot(path=os.path.join(OUT, "proof-test.png"))
            browser.close()
    finally:
        os.unlink(name)


if __name__ == "__main__":
    main()
