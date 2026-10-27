"""Renders the gap the trace exposed and the delta fills, in the hero's style: three panels, one per sentence.

    python3 -I Docs/README_Assets/src/blindspot.py Docs/README_Assets

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts.
Outputs: trace-blind-spot.png in argv[1].

The numbers are the proof's craft run (Examples/.work/bench/proof/20261020-061446.json, 2026-10-19), the
mean per set from position 24, typed in from its rows: trace and H_lm for the delta arm and the frozen arm.
The trace follows one document through the index, so it reads the index alone and is the same for both arms.
"""

import os
import sys
import tempfile

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

GREEN, GOLD, LINE = "#28a883", "#c7a659", "#cbc8c0"
W, H = 1600, 1010

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
COLS = [70, 560, 1050]
CW = 480


def chain(lit):
    """Eight positions of a passage. Lit: one document followed in order. Unlit: each match from a different document."""
    dots, links = [], []
    for i in range(8):
        x = 40 + i * 56
        colour = GOLD if lit else ["#5e8fda", "#d8773f", "#28a883", "#8a877f", "#5e8fda", "#d8773f", "#28a883", "#8a877f"][i]
        y = 30 if lit else 30 + (14 if i % 2 else -14)
        dots.append(f'<circle cx="{x}" cy="{y}" r="9" fill="{colour}" opacity="{1 if lit else .75}"/>')
        if lit and i:
            links.append(f'<line x1="{x - 56 + 9}" y1="30" x2="{x - 9}" y2="30" stroke="{GOLD}" stroke-width="3"/>')
    return f'<svg width="460" height="60" style="position:static">{"".join(links)}{"".join(dots)}</svg>'


def bar(value, scale, colour, label):
    return (f'<div class="barrow"><div class="bar" style="width:{max(value * scale, 3):.0f}px; background:{colour}"></div>'
            f'<span class="val">{label}</span></div>')


def page():
    p1 = f"""<div class="num">1</div><h3>The trace follows one document</h3>
<p>Tracing the passage to decide which Thread to credit: does it keep following the same document, word for word?</p>
<div class="viz"><div class="lab">own text</div>{chain(True)}<div class="res"><b>trace 0.775</b> one document, in order</div>
<div class="lab" style="margin-top:22px">a shared sentence template</div>{chain(False)}<div class="res"><b>trace 0.000</b> a different document at each word</div></div>"""
    p2 = f"""<div class="num">2</div><h3>It checks what H<sub>knn</sub> claims</h3>
<p>On writing the Thread learned but never indexed, the 16 matches still agree on the next word. That looks like a citation. It is not.</p>
<div class="viz"><div class="pair"><span class="k">H<sub>knn</sub></span><b>0.585</b><span class="t">the matches agree</span></div>
<div class="arrow">but</div>
<div class="pair"><span class="k">trace</span><b>0.000</b><span class="t">no one document is followed</span></div>
<div class="res" style="margin-top:20px">So it is a template the index happens to match, not a source. The trace is how we know.</div></div>"""
    p3 = f"""<div class="num green">3</div><h3 class="g">Yet the Thread is far surer</h3>
<p>On that same writing, nothing indexed, the trained Thread is nearly certain of each next word. The commons' head is not.</p>
<div class="viz">{bar(0.015, 100, GREEN, "0.015 <i>the Thread, with its delta</i>")}{bar(3.402, 70, "#4a4944", "3.402 <i>the commons' head</i>")}
<div class="res" style="margin-top:18px">H<sub>lm</sub> is how unsure it is; 0 is certain. This detection comes from training, not the index: an emergent behaviour of the delta.</div></div>"""
    cards = "".join(f'<div class="card {"d" if i == 2 else ""}" style="left:{x}px">{c}</div>' for i, (x, c) in enumerate(zip(COLS, [p1, p2, p3])))
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic; color: #a29f97;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 62.5px; top: 60px; width: 64px; }}
.caption {{ position: absolute; left: 150px; top: 78px; letter-spacing: .3em; font-size: 15px; color: #8b8a84; }}
.title {{ position: absolute; left: 22px; padding-left: 40px; top: 162px; font-size: 98px; line-height: 1; font-weight: 500; letter-spacing: -.005em; padding-right: 30px; padding-bottom: 32px;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; }}
.sub {{ position: absolute; left: 69px; top: 280px; font-size: 30px; color: #9b9991; }}
.card {{ position: absolute; top: 330px; width: {CW}px; height: 520px; box-sizing: border-box; border: 1px solid rgba(255,255,255,.12); border-radius: 14px; background: #1c1c19; padding: 22px 24px; }}
.card.d {{ border-color: rgba(40,168,131,.7); background: #17211c; }}
.num {{ width: 28px; height: 28px; border: 1.6px solid {GOLD}; border-radius: 50%; text-align: center; line-height: 27px; font-family: -apple-system, 'Helvetica Neue', sans-serif; font-style: normal; font-weight: 600; font-size: 14px; color: {GOLD}; }}
.num.green {{ border-color: {GREEN}; color: {GREEN}; }}
h3 {{ margin: 12px 0 0; font-weight: 400; font-size: 27px; color: #ecebe5; }}
h3.g {{ color: {GREEN}; }}
.card > p {{ margin: 8px 0 0; font-size: 17px; line-height: 1.4; color: #b4b1a9; min-height: 96px; }}
.viz {{ margin-top: 14px; border-top: 1px solid rgba(255,255,255,.08); padding-top: 14px; }}
.lab {{ font-size: 11.5px; letter-spacing: .2em; color: #77756f; text-transform: uppercase; }}
.res {{ font-size: 16px; line-height: 1.4; color: #b4b1a9; }}
.res b {{ font-weight: 400; color: #ecebe5; font-family: {MONO}; font-style: normal; font-size: 14px; }}
.pair {{ display: grid; grid-template-columns: 70px 90px 1fr; align-items: baseline; padding: 8px 0; }}
.pair .k {{ font-size: 18px; color: #e3e1da; }}
.pair b {{ font-family: {MONO}; font-style: normal; font-weight: 400; font-size: 22px; color: #ecebe5; }}
.pair .t {{ font-size: 15.5px; }}
.arrow {{ text-align: center; font-size: 17px; color: {GOLD}; padding: 2px 0; }}
.barrow {{ display: flex; align-items: center; height: 40px; }}
.bar {{ height: 22px; border-radius: 4px; flex: none; }}
.val {{ margin-left: 12px; font-family: {MONO}; font-style: normal; font-size: 14px; color: #e3e1da; }}
.val i {{ font-family: "Playfair", Georgia, serif; font-size: 14px; color: #8f8c84; margin-left: 6px; }}
sub {{ font-size: .68em; vertical-align: -.3em; line-height: 0; }}
.close {{ position: absolute; left: 70px; top: 884px; width: 1460px; border-top: 1px solid rgba(255,255,255,.12); padding-top: 16px; font-size: 21px; line-height: 1.4; color: #c9c6be; }}
.close b {{ font-weight: 400; color: #ecebe5; }}
.close .g {{ color: {GREEN}; }}
.tag {{ position: absolute; right: 70px; top: 960px; font-size: 16px; color: #8b8a84; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">RAO STUDIOS · A BRAIDED LANGUAGE MODEL · THE PROOF</div>
<div class="title">The gap the trace found</div>
<div class="sub">tracing which Thread to credit showed what the delta fills</div>
{cards}
<div class="close">The trace says <b>no document is followed</b>. H<sub>lm</sub> says <span class="g">the Thread still learned it</span>. That gap is the delta.</div>
<div class="tag">craft, 2026-10-19 · means from position 24 · withheld set · Examples/proof.sh</div>
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
            tab.screenshot(path=os.path.join(OUT, "trace-blind-spot.png"))
            browser.close()
    finally:
        os.unlink(name)


if __name__ == "__main__":
    main()
