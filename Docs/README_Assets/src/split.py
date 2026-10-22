"""Renders what the head/tail split buys, against two designs without it, in the hero's style.

    python3 -I Docs/README_Assets/src/split.py Docs/README_Assets

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts.
Outputs: what-the-split-buys.png in argv[1].

An ablation by construction, not a bench: one model fine-tuned on everyone's writing, one full
fine-tune per corpus, and Braid's trained head per corpus on the commons' shared tail. Only the third
column's marks are measured (the proof's craft run, 2026-10-19). The point it makes is about the split,
not attention: detection by lift needs a per-corpus delta on a shared, frozen base, which a transformer
split the same way, or per-corpus adapters on one base, would also have.
"""

import os
import sys
import tempfile

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

BLUE, GREEN, ORANGE, GOLD, LINE = "#5e8fda", "#28a883", "#d8773f", "#c7a659", "#cbc8c0"
COLOURS = (BLUE, GREEN, ORANGE)
W, H = 1600, 1190
MONO = "Menlo, 'SF Mono', monospace"
SANS = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"

LABEL_W = 300
COLS = [(400, 770), (790, 1160), (1180, 1530)]
STACK_BOTTOM, BAR, GAP = 540, 18, 6

DESIGNS = [
    ("A", "one model for everyone", "all the writing trained into one set of weights", "one set of weights, everyone's writing mixed"),
    ("B", "a full copy per corpus", "a whole model fine-tuned for each body of writing", "three full copies"),
    ("C", "a head per corpus, one tail", "Braid: each Thread trains the first half", "three heads on one shared tail"),
]

# (capability, [(mark, note) for A, B, C]); mark: y yes, n no
ROWS = [
    ("tells writing it learned from new writing", [
        ("y", "against the base model"), ("y", "each copy against the base"), ("y", "each head against the commons: <code class='rid'>D1</code> <code class='rid'>D2</code>")]),
    ("says whose writing it learned", [
        ("n", "every contributor is in the same weights"), ("y", "a copy holds one body of writing"), ("y", "a head holds one body of writing")]),
    ("has an exact control for each", [
        ("n", "no version without one contributor, short of retraining"), ("y", "the base, unchanged"), ("y", "the commons' head, equal to 0.00001: <code class='rid'>C0</code>")]),
    ("points to the place it came from", [
        ("y", "an index works on any model"), ("y", "an index per copy"), ("y", "an index per Thread: <code class='rid'>R1</code> <code class='rid'>R2</code>")]),
    ("stores the shared part once", [
        ("y", "one model"), ("n", "every layer copied per corpus"), ("y", "the tail once; each Thread adds 12 of 24 blocks")]),
    ("withdraws one body of writing", [
        ("n", "retrain without it"), ("y", "delete its copy"), ("y", "detach its Thread, even mid-answer")]),
]


def stack(cx, width, layers, fill, bottom=STACK_BOTTOM):
    """Bars from the bottom up; fill(i) gives a list of (colour, opacity) segments for layer i."""
    out = []
    for i in range(layers):
        y = bottom - (i + 1) * BAR - i * GAP
        segs = fill(i)
        seg_w = width / len(segs)
        for j, (colour, opacity) in enumerate(segs):
            x = cx - width / 2 + j * seg_w
            out.append(f'<rect x="{x:.1f}" y="{y}" width="{seg_w:.1f}" height="{BAR}" fill="{colour}" opacity="{opacity}"/>')
        out.append(f'<rect x="{cx - width / 2:.1f}" y="{y}" width="{width}" height="{BAR}" rx="3" fill="none" stroke="rgba(255,255,255,.18)" stroke-width="1"/>')
    return out


def dots(xs, y=562):
    return [f'<circle cx="{x}" cy="{y}" r="6" fill="{c}"/>' for x, c in zip(xs, COLOURS)]


def svg():
    p = []
    centre = [(a + b) / 2 for a, b in COLS]
    # A: one stack, every layer holding all three.
    order = [COLOURS, COLOURS[1:] + COLOURS[:1], COLOURS[2:] + COLOURS[:2]]
    p += stack(centre[0], 160, 6, lambda i: [(c, .75) for c in order[i % 3]])
    xs = [centre[0] - 50, centre[0], centre[0] + 50]
    p += dots(xs)
    # B: three stacks, each its own colour all the way up.
    xs = [centre[1] - 90, centre[1], centre[1] + 90]
    for x, c in zip(xs, COLOURS):
        p += stack(x, 66, 6, lambda i, c=c: [(c, .75)])
    p += dots(xs)
    # C: three coloured heads, one shared grey tail on top.
    xs = [centre[2] - 90, centre[2], centre[2] + 90]
    for x, c in zip(xs, COLOURS):
        p += stack(x, 66, 3, lambda i, c=c: [(c, .75)])
    p += stack(centre[2], 246, 3, lambda i: [(LINE, .38)], bottom=STACK_BOTTOM - 3 * (BAR + GAP))
    p += dots(xs)
    return f'<svg width="{W}" height="{H}">{"".join(p)}</svg>'


def mark(m):
    return '<span class="mk y">✓</span>' if m == "y" else '<span class="mk n">✕</span>'


def page():
    heads = "".join(f'<div class="design" style="left:{a}px; width:{b - a}px"><div class="id">{i}</div><b>{t}</b><p>{s}</p></div>'
                    for (a, b), (i, t, s, _) in zip(COLS, DESIGNS))
    captions = "".join(f'<div class="scap" style="left:{a}px; width:{b - a}px">{c}</div>' for (a, b), (_, _, _, c) in zip(COLS, DESIGNS))
    rows = "".join(f'<div class="row"><span class="cap">{name}</span>' + "".join(f'<span class="cell {"c" if k == 2 else ""}">{mark(m)}<span>{note}</span></span>'
                                                                        for k, (m, note) in enumerate(cells)) + '</div>'
                   for name, cells in ROWS)
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic; color: #a29f97;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 62.5px; top: 50px; width: 64px; }}
.caption {{ position: absolute; left: 150px; top: 68px; letter-spacing: .3em; font-size: 15px; color: #8b8a84; }}
.title {{ position: absolute; left: 22px; padding-left: 40px; top: 104px; font-size: 98px; line-height: 1; font-weight: 500; letter-spacing: -.005em; padding-right: 30px; padding-bottom: 32px;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; }}
.sub {{ position: absolute; left: 69px; top: 222px; font-size: 30px; color: #9b9991; }}
svg {{ position: absolute; left: 0; top: 0; }}
.design {{ position: absolute; top: 318px; }}
.design .id {{ font-family: {MONO}; font-style: normal; font-size: 12.5px; color: {GOLD}; }}
.design b {{ display: block; font-weight: 400; font-size: 23px; color: #ecebe5; margin-top: 2px; }}
.design p {{ margin: 3px 0 0; font-size: 15px; line-height: 1.3; color: #8f8c84; }}
.scap {{ position: absolute; top: 578px; text-align: center; font-size: 15px; color: #a29f97; }}
.hint {{ position: absolute; left: 70px; width: {LABEL_W - 20}px; font-size: 15px; line-height: 1.4; color: #8f8c84; }}
.hint b {{ font-weight: 400; color: #e3e1da; }}
.table {{ position: absolute; left: 70px; top: 628px; width: 1460px; }}
.row {{ display: grid; grid-template-columns: {LABEL_W + 30}px 370px 370px 350px; column-gap: 20px; align-items: start; padding: 13px 0;
       border-top: 1px solid rgba(255,255,255,.08); }}
.row .cap {{ font-size: 18px; color: #e3e1da; }}
.cell {{ display: grid; grid-template-columns: 26px 1fr; font-size: 15.5px; line-height: 1.35; color: #a29f97; }}
.cell.c span:last-child {{ color: #c9c6be; }}
.rid {{ font-family: {MONO}; font-style: normal; font-size: .8em; color: {GOLD}; }}
.mk {{ font-family: {SANS}; font-style: normal; font-weight: 600; font-size: 15px; }}
.mk.y {{ color: {GREEN}; }}
.mk.n {{ color: #8a5a4a; }}
.foot {{ position: absolute; left: 70px; top: 980px; width: 1460px; display: grid; grid-template-columns: 1fr 1fr; column-gap: 48px; }}
.foot div {{ border-top: 1px solid rgba(255,255,255,.12); padding-top: 12px; }}
.foot h4 {{ margin: 0; font-size: 11.5px; font-weight: 400; letter-spacing: .22em; color: #77756f; }}
.foot p {{ margin: 8px 0 0; font-size: 17px; line-height: 1.42; color: #b4b1a9; }}
.tag {{ position: absolute; right: 70px; top: 1138px; font-size: 17px; color: #8b8a84; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">RAO STUDIOS · A BRAIDED LANGUAGE MODEL · THE SPLIT</div>
<div class="title">What the split buys</div>
<div class="sub">detection needs one trained part per body of writing, on a shared, frozen base</div>
{svg()}
{heads}
<div class="hint" style="top:330px"><b>Three ways to train on three bodies of writing.</b></div>
<div class="hint" style="top:420px">Each bar is a layer, first at the bottom. Colour is whose writing trained it; grey is shared and never trained.</div>
{captions}
<div class="table">{rows}</div>
<div class="foot">
  <div><h4>THE SPLIT, NOT ATTENTION</h4><p>Any architecture can run this test once it is split this way: a transformer whose first layers are trained per body of writing in front of shared, frozen last layers, or per-corpus adapters on one frozen base. RaoLM, Braid's transformer predecessor, cited through an index too.</p></div>
  <div><h4>WHAT MAMBA2 ADDS</h4><p>A fixed-size state, 19 MB a strand at 130m whatever the context, with no cache that grows. Many strands can run, checkpoint and replay side by side. It makes the braid practical; it is not what makes detection work.</p></div>
</div>
<div class="tag">marks are by construction; C's are also measured, on craft, 2026-10-19 · Examples/proof.sh</div>
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
            tab.screenshot(path=os.path.join(OUT, "what-the-split-buys.png"))
            browser.close()
    finally:
        os.unlink(name)


if __name__ == "__main__":
    main()
