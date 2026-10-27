"""Renders how one Thread's language module is read twice at every token, in the hero's style.

    python3 -I Docs/README_Assets/src/readings.py Docs/README_Assets

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts.
Outputs: two-readings.png in argv[1].

The head (blocks 0..<cut, the Thread's, trained: the delta) runs in front of the commons' tail. Two
points are tapped: the residual at the cut (the key's mid half) and the normed state after norm_f
(s, the key's final half, and what the reed reads). s through the reed gives p_lm, so H_lm and lift:
detection. The key [h₁₂ ‖ s] searched in the Thread's index gives 16 hits, so p_knn and H_knn:
citation (ProvenanceKey.swift, Mixer.swift). The numbers are the proof's craft run, rules fixed
before it ran (Examples/Sources/Proof/ProofRules.swift; report 20261020-061446.json, 2026-10-19).
"""

import os
import sys
import tempfile

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

# The hero's colours (build.py). The delta takes Craft's green: the proof ran on craft.
GREEN, GOLD, LINE = "#28a883", "#c7a659", "#cbc8c0"
W, H = 1600, 1170

# The header's rhythm, shared by Rao's plates: the mark's ink sits 70 px from the top and the left; every
# header line's ink starts at the mark's left edge (an italic first glyph overhangs by its own amount, so
# the page measures it); the title's ink starts 70 px under the mark's; what follows starts HEADER_GAP px
# under the subtitle's baseline, and the page grows or shrinks to keep its foot.
INK, TITLE_INK, HEADER_GAP = 70.5, 174, 54
HEADER_JS = """<script>
document.fonts.ready.then(() => {
  const ctx = document.createElement("canvas").getContext("2d");
  const measure = (el) => {
    const cs = getComputedStyle(el), text = el.textContent.trim();
    ctx.font = `italic ${cs.fontWeight} ${cs.fontSize} Playfair`;
    const probe = document.createElement("span");
    probe.style.cssText = "display:inline-block; width:0; height:0";
    el.prepend(probe);
    const baseline = probe.getBoundingClientRect().bottom;
    probe.remove();
    return {left: parseFloat(cs.paddingLeft), top: parseFloat(cs.top), baseline,
            ink: baseline - ctx.measureText(text).actualBoundingBoxAscent, overhang: ctx.measureText(text[0]).actualBoundingBoxLeft};
  };
  const title = document.querySelector(".title"), sub = document.querySelector(".sub");
  const t = measure(title), s = measure(sub), dy = __TITLE_INK__ - t.ink;
  for (const [el, m] of [[title, t], [sub, s]]) {
    el.style.left = (__INK__ - m.left + m.overhang) + "px";
    el.style.top = (m.top + dy) + "px";
  }
  const header = ".mark, .caption, .title, .sub, script, style", rest = [...document.body.children].filter((el) => !el.matches(header));
  let first = Infinity;
  for (const el of rest) {
    const r = el.getBoundingClientRect();
    if (el instanceof SVGSVGElement) {
      const b = el.getBBox();
      if (b.width || b.height) first = Math.min(first, r.top + b.y);
    } else if (r.width && r.height) first = Math.min(first, r.top);
  }
  const shift = Math.round(s.baseline + dy + __GAP__ - first);
  for (const el of rest) el.style.translate = `0 ${shift}px`;
  const height = parseFloat(getComputedStyle(document.body).height) + shift;
  document.documentElement.style.height = document.body.style.height = height + "px";
  document.body.dataset.height = height;
});
</script>""".replace("__INK__", str(INK)).replace("__TITLE_INK__", str(TITLE_INK)).replace("__GAP__", str(HEADER_GAP))
MONO = "Menlo, 'SF Mono', monospace"

MID = 540                                   # the main line
UP, DOWN = (336, 466), (670, 800)           # the detection row, the citation row
CUT, S = 515, 910                           # the two taps
BOX = {
    "head": (200, 470, 470, 610),
    "tail": (560, 470, 860, 610),
    "reed": (980, UP[0], 1240, UP[1]),
    "hlm": (1290, UP[0], 1530, UP[1]),
    "key": (600, DOWN[0], 860, DOWN[1]),
    "index": (1010, DOWN[0], 1250, DOWN[1]),
    "hknn": (1290, DOWN[0], 1530, DOWN[1]),
}


def head(x, y, colour):
    return f'<path d="M{x - 10},{y - 7} L{x},{y} L{x - 10},{y + 7}" fill="none" stroke="{colour}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>'


def down_head(x, y, colour):
    return f'<path d="M{x - 7},{y - 10} L{x},{y} L{x + 7},{y - 10}" fill="none" stroke="{colour}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>'


def up_head(x, y, colour):
    return f'<path d="M{x - 7},{y + 10} L{x},{y} L{x + 7},{y + 10}" fill="none" stroke="{colour}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>'


def svg():
    p = []
    line = lambda d, c, w=2.6: p.append(f'<path d="{d}" fill="none" stroke="{c}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/>')
    # The token into the head.
    line(f"M160,{MID} H{BOX['head'][0] - 4}", LINE)
    p.append(head(BOX["head"][0] - 4, MID, LINE))
    # The cut.
    p.append(f'<line x1="{CUT}" y1="430" x2="{CUT}" y2="630" stroke="#4a4944" stroke-width="1.4" stroke-dasharray="2 6" stroke-linecap="round"/>')
    # The delta's path: out of the head, through the tail, to s, and down both taps into the key.
    line(f"M{BOX['head'][2]},{MID} H{BOX['tail'][0] - 4}", GREEN, 3.2)
    p.append(head(BOX["tail"][0] - 4, MID, GREEN))
    line(f"M{BOX['tail'][2]},{MID} H{S}", GREEN, 3.2)
    line(f"M{CUT},{MID} V{(DOWN[0] + DOWN[1]) / 2} H{BOX['key'][0] - 4}", GREEN, 2.4)
    p.append(head(BOX["key"][0] - 4, (DOWN[0] + DOWN[1]) / 2, GREEN))
    line(f"M{S},{MID} V{(UP[0] + UP[1]) / 2} H{BOX['reed'][0] - 4}", GREEN, 2.4)
    p.append(head(BOX["reed"][0] - 4, (UP[0] + UP[1]) / 2, GREEN))
    line(f"M{S},{MID} V{(DOWN[0] + DOWN[1]) / 2 - 22} H{BOX['key'][2] + 4}", GREEN, 2.4)
    p.append(f'<path d="M{BOX["key"][2] + 14},{(DOWN[0] + DOWN[1]) / 2 - 29} L{BOX["key"][2] + 4},{(DOWN[0] + DOWN[1]) / 2 - 22} L{BOX["key"][2] + 14},{(DOWN[0] + DOWN[1]) / 2 - 15}" fill="none" stroke="{GREEN}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"/>')
    # The taps.
    for x in (CUT, S):
        p.append(f'<circle cx="{x}" cy="{MID}" r="8" fill="#191917" stroke="{GREEN}" stroke-width="2.4"/>')
    # Reed to H_lm; key to index to H_knn.
    y = (UP[0] + UP[1]) / 2
    line(f"M{BOX['reed'][2]},{y} H{BOX['hlm'][0] - 4}", LINE)
    p.append(head(BOX["hlm"][0] - 4, y, LINE))
    y = (DOWN[0] + DOWN[1]) / 2
    line(f"M{BOX['key'][2]},{y + 14} H{BOX['index'][0] - 4}", LINE)
    p.append(head(BOX["index"][0] - 4, y + 14, LINE))
    line(f"M{BOX['index'][2]},{y} H{BOX['hknn'][0] - 4}", LINE)
    p.append(head(BOX["hknn"][0] - 4, y, LINE))
    return f'<svg width="{W}" height="{H}">{"".join(p)}</svg>'


def box(name, caption, title, body, cls=""):
    x0, y0, x1, y1 = BOX[name]
    cap = f'<div class="machine">{caption}</div>' if caption else ""
    return f'<div class="card {cls}" style="left:{x0}px; top:{y0}px; width:{x1 - x0}px; height:{y1 - y0}px">{cap}<b>{title}</b><p>{body}</p></div>'


RESULTS = [
    ("THE CONTROL", "An untrained Thread is the commons exactly: its confidence matched the commons' at all 20,600 words read. Every difference below comes from training."),
    ("DETECTION", "On writing it studied but kept out of its index, the trained Thread was nearly certain of each next word (H<sub>lm</sub> 0.015; 0 is certain), the untrained one was not (3.40). It told studied writing from new writing every time; untrained, about a coin flip."),
    ("CITATION", "On writing its index holds, both Threads found the source every time. Training made the 16 matches agree on it: their spread (H<sub>knn</sub>) fell from 0.769 to 0.257, on 20 of 20 documents."),
    ("THE LIMIT", "An index cannot find what it does not hold: on studied but unindexed writing, citation did no better than chance. Detection is what catches that writing."),
]


def page():
    results = "".join(f'<div><h4>{h}</h4><p>{t}</p></div>' for h, t in RESULTS)
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic; color: #a29f97;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 62.5px; top: 60px; width: 64px; }}
.caption {{ position: absolute; left: 150px; top: 78px; letter-spacing: .3em; font-size: 15px; color: #8b8a84; }}
.title {{ position: absolute; left: 33.5px; padding-left: 40px; top: 162px; font-size: 98px; line-height: 1; font-weight: 500; letter-spacing: -.005em; padding-right: 30px; padding-bottom: 32px;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; }}
.sub {{ position: absolute; left: 69px; top: 280px; font-size: 32px; color: #9b9991; }}
svg {{ position: absolute; left: 0; top: 0; }}
.card {{ position: absolute; box-sizing: border-box; border: 1px solid rgba(255,255,255,.12); border-radius: 14px; background: #1c1c19; padding: 13px 18px; }}
.card.delta {{ border-color: rgba(40,168,131,.7); background: #17211c; }}
.card.cite {{ border-color: rgba(199,166,89,.55); }}
.card b {{ display: block; font-weight: 400; font-size: 24px; color: #ecebe5; margin-top: 2px; }}
.card p {{ margin: 6px 0 0; font-size: 16px; line-height: 1.3; color: #a29f97; }}
.machine {{ font-size: 11px; letter-spacing: .22em; color: #77756f; white-space: nowrap; font-style: italic; }}
.delta .machine {{ color: {GREEN}; }}
.pill {{ position: absolute; left: 70px; top: {MID - 20}px; width: 90px; height: 40px; box-sizing: border-box; border: 1px solid rgba(255,255,255,.14);
        border-radius: 20px; text-align: center; line-height: 38px; font-size: 18px; color: #d9d6ce; }}
.wire {{ position: absolute; font-family: {MONO}; font-style: normal; font-size: 13px; color: {GREEN}; white-space: nowrap; }}
.cutlabel {{ position: absolute; left: {CUT - 30}px; top: 408px; font-size: 11px; letter-spacing: .22em; color: #77756f; }}
.row {{ position: absolute; font-size: 11.5px; letter-spacing: .22em; color: #8b8a84; white-space: nowrap; }}
.row em {{ font-style: italic; letter-spacing: 0; font-size: 17px; color: #a29f97; margin-left: 10px; }}
.note {{ position: absolute; font-size: 17px; line-height: 1.35; color: {GREEN}; }}
.legend {{ position: absolute; left: 980px; top: 494px; width: 550px; }}
.legend .grid {{ display: grid; grid-template-columns: auto 1fr auto 1fr; column-gap: 12px; row-gap: 6px; margin-top: 8px; font-size: 15px; line-height: 1.3; }}
.legend .sym {{ color: #e3e1da; }}
.legend .sym code {{ font-family: {MONO}; font-style: normal; font-size: 13px; color: {GREEN}; }}
.legend .grid span:nth-child(4n+3) {{ padding-left: 26px; }}
.legend .grid span:nth-child(even) {{ color: #a29f97; }}
.results {{ position: absolute; left: 70px; top: 880px; width: 1460px; }}
.results .grid {{ display: grid; grid-template-columns: repeat(4, 1fr); column-gap: 36px; margin-top: 12px; }}
.results .grid div {{ border-top: 1px solid rgba(255,255,255,.1); padding-top: 12px; }}
.results h4 {{ margin: 0; font-size: 11.5px; font-weight: 400; letter-spacing: .22em; color: #77756f; }}
.results p {{ margin: 8px 0 0; font-size: 17px; line-height: 1.4; color: #b4b1a9; }}
sub {{ font-size: .68em; vertical-align: -.3em; line-height: 0; }}
.tag {{ position: absolute; right: 70px; top: 1112px; font-size: 18px; color: #8b8a84; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">RAO STUDIOS · A BRAIDED LANGUAGE MODEL · THE PROOF</div>
<div class="title">Detection and citation</div>
<div class="sub">every word a Thread writes is checked twice: does it know this, and where is it from</div>
{svg()}
<div class="pill">token</div>
<div class="cutlabel">THE CUT</div>
{box("head", "THE THREAD'S", "head", "the first 12 layers, trained on its own writing: the delta", "delta")}
{box("tail", "THE COMMONS'", "tail", "the last 12 layers, shared by every Thread, never trained")}
<div class="wire" style="left:{CUT + 14}px; top:{MID + 12}px">h₁₂</div>
<div class="wire" style="left:{S + 14}px; top:{MID + 12}px">s</div>
<div class="row" style="left:980px; top:{UP[0] - 34}px">DETECTION<em>has this Thread learned this text? no index needed</em></div>
{box("reed", "THE COMMONS' EMBEDDING", "the reed", "turns the state into odds for every possible next word")}
{box("hlm", "", "H<sub>lm</sub> and lift", "how sure the Thread is of the next word, against the commons")}
{box("key", "", "the key", "a fingerprint of this moment, [h₁₂ ‖ s], taken at both taps")}
{box("index", "THE THREAD'S", "index", "the same fingerprint, stored for every word of its writing")}
{box("hknn", "", "H<sub>knn</sub> and the hits", "the 16 closest fingerprints, each a document and a place in it", "cite")}
<div class="row" style="left:600px; top:{DOWN[1] + 18}px">CITATION<em>where in the Thread's writing is this from?</em></div>
<div class="note" style="left:200px; top:640px; width:290px">training the head changes both checks: the state and the fingerprint are both computed through it</div>
<div class="legend"><div class="row" style="position:static">READING THE SYMBOLS</div><div class="grid">
  <span class="sym"><code>h₁₂</code></span><span>lowercase h, a hidden state: after the head's 12 blocks</span>
  <span class="sym">H</span><span>capital H, entropy: how unsure; 0 is certain</span>
  <span class="sym"><code>s</code></span><span>the hidden state after all 24 blocks</span>
  <span class="sym">lift</span><span>how much likelier the word is to the Thread than to the commons</span>
  <span class="sym"><code>‖</code></span><span>joined end to end</span>
</div></div>
<div class="results"><div class="row" style="position:static">WHAT THE PROOF FOUND · 60 DOCUMENTS, 2026-10-19 · A TRAINED THREAD AGAINST AN UNTRAINED ONE</div><div class="grid">{results}</div></div>
<div class="tag">detection: the model learned this · citation: here is where it is written</div>
{HEADER_JS}
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
            tab.wait_for_selector("body[data-height]", state="attached")
            tab.set_viewport_size({"width": W, "height": round(float(tab.evaluate("document.body.dataset.height")))})
            tab.wait_for_timeout(100)
            tab.screenshot(path=os.path.join(OUT, "two-readings.png"))
            browser.close()
    finally:
        os.unlink(name)


if __name__ == "__main__":
    main()
