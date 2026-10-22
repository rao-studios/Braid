"""Renders the plan for running a braid across machines, in the hero's style: one request's calls.

    python3 -I Docs/README_Assets/src/across.py Docs/README_Assets

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts.
Outputs: across-machines.png in argv[1]. A plan, not a result: the wire is not built.

The request enters at the commons (A), prefilled with the asker's own node if it offers one. A finds
and attaches the nodes and runs the cluster: the shared tail, the reed and the mixture. What crosses
the wire follows the code: the residual after block 11 (the cut, the key's mid half), the normed state
after the tail and norm_f (the key's final half, ProvenanceKey.swift), the hits (k = 16) and the
token. Today a node runs its own tail and advance(session:token:k:) returns s and its hits. Half a
StateStack (19,390,464 bytes at 130m) is 9.7 MB.
"""

import os
import sys
import tempfile

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

# The hero's colours (build.py), and a fourth for the asker's own node.
BLUE, GREEN, ORANGE, GOLD, LINE, VIOLET = "#5e8fda", "#28a883", "#d8773f", "#c7a659", "#cbc8c0", "#a88bd6"
W, H = 1600, 1180
MONO = "Menlo, 'SF Mono', monospace"
SANS = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"

E = dict(left=70, right=300, top=372, bottom=872)             # the asker's machine
ASKER = dict(top=420, bottom=580)                             # the asker, inside E
OWN = dict(top=692, bottom=832)                               # its own node, optional, inside E
A = dict(left=430, right=910, top=372, bottom=872)            # the commons: entry, grouping, tail, reed
NODE_LEFT, NODE_RIGHT = 1160, 1480                             # B, C, D
NODES = [("B", BLUE, 372), ("C", GREEN, 552), ("D", ORANGE, 732)]  # name, colour, top
NODE_H = 140
CUT_X = 1035
LANES = (-42, -18, 18, 42)   # Advance out, h₁₂ back, Search out, hits back


def arrowhead(x, y, direction, colour):
    d = 1 if direction == "left" else -1
    return (f'<path d="M{x + d * 9},{y - 7} L{x},{y} L{x + d * 9},{y + 7}" fill="none" stroke="{colour}" '
            f'stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>')


def badge(x, y, n):
    return (f'<circle cx="{x}" cy="{y}" r="11" fill="#191917" stroke="{GOLD}" stroke-width="1.6"/>'
            f'<text x="{x}" y="{y + 4.6}" text-anchor="middle" font-family="{SANS}" font-size="13" font-weight="600" fill="{GOLD}">{n}</text>')


def call(x0, x1, y, colour=GOLD):
    """A request: dashed, from x0 to x1."""
    return (f'<line x1="{x0}" y1="{y}" x2="{x1}" y2="{y}" stroke="{colour}" stroke-width="1.8" stroke-dasharray="6 5" stroke-linecap="round"/>'
            + arrowhead(x1, y, "right" if x1 > x0 else "left", colour))


def reply(x0, x1, y, colour, width=2.8):
    """A reply: solid, from x0 to x1."""
    return (f'<line x1="{x0}" y1="{y}" x2="{x1}" y2="{y}" stroke="{colour}" stroke-width="{width}" stroke-linecap="round"/>'
            + arrowhead(x1, y, "right" if x1 > x0 else "left", colour))


def lanes(node_edge, a_edge, cy, colour):
    """Calls 3 and 5 between the commons and one node, on either side of it."""
    advance, h12, search, hits = (cy + d for d in LANES)
    step = 4 if node_edge > a_edge else -4
    return [call(a_edge, node_edge - step, advance), reply(node_edge, a_edge + step, h12, colour),
            call(a_edge, node_edge - step, search), reply(node_edge, a_edge + step, hits, colour, width=2)]


def svg():
    p = []
    # The cut, between a node's head and the commons' tail.
    p.append(f'<line x1="{CUT_X}" y1="{A["top"]}" x2="{CUT_X}" y2="{A["bottom"]}" stroke="#4a4944" stroke-width="1.4" stroke-dasharray="2 6" stroke-linecap="round"/>')
    # 1 and 7: the asker and the commons.
    y = (ASKER["top"] + ASKER["bottom"]) / 2
    inner = E["right"] - 14
    p.append(call(inner, A["left"] - 4, y - 18))
    p.append(f'<line x1="{A["left"]}" y1="{y + 18}" x2="{inner + 22}" y2="{y + 18}" stroke="{LINE}" stroke-width="3" stroke-linecap="round"/>')
    p.append(f'<circle cx="{inner + 12}" cy="{y + 18}" r="9.5" fill="#191917" stroke="{GOLD}" stroke-width="2.4"/>')
    p.append(f'<circle cx="{inner + 12}" cy="{y + 18}" r="4" fill="{GOLD}"/>')
    p.append(badge(404, y - 18, 1))
    p.append(badge(404, y + 18, 7))
    # 3 and 5: the commons and each node; the asker's own first, if it offered one.
    p += lanes(inner, A["left"], (OWN["top"] + OWN["bottom"]) / 2, VIOLET)
    for i, (name, colour, top) in enumerate(NODES):
        cy = top + NODE_H / 2
        p += lanes(NODE_LEFT, A["right"], cy, colour)
        if i == 0:
            p.append(badge(1100, cy + LANES[0], 3))
            p.append(badge(1100, cy + LANES[2], 5))
    return f'<svg width="{W}" height="{H}">{"".join(p)}</svg>'


def wire_labels():
    cy = NODES[0][2] + NODE_H / 2
    advance, h12, search, hits = (cy + d for d in LANES)
    y = (ASKER["top"] + ASKER["bottom"]) / 2
    own = (OWN["top"] + OWN["bottom"]) / 2
    return f"""
<div class="wire" style="left:926px; top:{advance - 18}px; color:{GOLD}">Advance(token)</div>
<div class="wire" style="left:926px; top:{h12 - 18}px; color:{BLUE}">h₁₂</div>
<div class="wire" style="left:926px; top:{search - 18}px; color:{GOLD}">Search(s)</div>
<div class="wire" style="left:926px; top:{hits - 18}px; color:{BLUE}">16 hits</div>
<div class="wire" style="left:312px; top:{y - 36}px; color:{GOLD}">Ask</div>
<div class="wire" style="left:322px; top:{y + 24}px">token</div>
<div class="wire" style="left:312px; top:{own + LANES[0] - 18}px; color:{GOLD}">Advance</div>
<div class="wire" style="left:312px; top:{own + LANES[1] - 18}px; color:{VIOLET}">h₁₂</div>
<div class="wire" style="left:312px; top:{own + LANES[2] - 18}px; color:{GOLD}">Search</div>
<div class="wire" style="left:312px; top:{own + LANES[3] - 18}px; color:{VIOLET}">hits</div>
<div class="cutlabel" style="left:{CUT_X - 28}px; top:{A['top'] - 22}px">THE CUT</div>"""


def node_cards():
    out = []
    for name, colour, top in NODES:
        out.append(f"""<div class="card" style="left:{NODE_LEFT}px; top:{top}px; width:{NODE_RIGHT - NODE_LEFT}px; height:{NODE_H}px">
  <div class="head"><span><i class="dot" style="background:{colour}"></i><b>Node {name}</b></span><span class="machine">MACHINE {name}</span></div>
  <p>its head · blocks 0–11</p>
  <p>{'<span class="step">5</span>' if name == 'B' else ''}its index · searched with [h₁₂ ‖ s]</p>
</div>""")
    return "".join(out)


STEPS = [
    ("1", "the asker to A: the prompt, and its own node if offered", "Ask(prompt, node?)", ""),
    ("2", "A finds the nodes that fit and attaches them, the asker's first", "", ""),
    ("3", "A to each node: the node runs its head, returns h₁₂", "Advance(token)", "4 B · 3 KB"),
    ("4", "A runs the shared tail on h₁₂, giving s", "", ""),
    ("5", "A to each node: the node searches its index", "Search(s)", "3 KB · 16 hits"),
    ("6", "A: the reed scores each s, the mixture splits the token", "", ""),
    ("7", "A to the asker: the token, its shares, its citations", "", ""),
]


def steps():
    rows = "".join(
        f'<div class="row"><span class="step">{n}</span><span>{text}</span><code>{call}</code><code class="size">{size}</code></div>'
        for n, text, call, size in STEPS)
    return f'<div class="steps"><div class="machine">STEPS 3 TO 7 REPEAT FOR EVERY TOKEN</div><div class="grid">{rows}</div></div>'


def page():
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic; color: #a29f97;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 62.5px; top: 50px; width: 64px; }}
.caption {{ position: absolute; left: 150px; top: 68px; letter-spacing: .3em; font-size: 15px; color: #8b8a84; }}
.title {{ position: absolute; left: 39.5px; padding-left: 40px; top: 104px; font-size: 104px; line-height: 1; font-weight: 500; letter-spacing: -.005em; padding-right: 30px;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; }}
.sub {{ position: absolute; left: 69px; top: 222px; font-size: 32px; color: #9b9991; }}
svg {{ position: absolute; left: 0; top: 0; }}
.card {{ position: absolute; box-sizing: border-box; border: 1px solid rgba(255,255,255,.11); border-radius: 14px;
        background: rgba(255,255,255,.028); padding: 16px 20px; }}
.card.machine-e {{ border: 1px dashed rgba(255,255,255,.14); background: transparent; }}
.card.inner {{ left: 84px; width: 202px; padding: 12px 14px; }}
.card.optional {{ border-style: dashed; }}
.card p {{ margin: 8px 0 0; font-size: 17px; line-height: 1.3; color: #a29f97; }}
.card.inner p {{ margin-top: 6px; font-size: 15.5px; }}
.card b {{ font-weight: 400; color: #ecebe5; }}
.card h4 {{ margin: 18px 0 0; font-weight: 400; font-size: 19px; color: #e3e1da; display: flex; align-items: center; }}
.card h4 + p {{ margin-top: 4px; }}
.head {{ display: flex; justify-content: space-between; align-items: baseline; }}
.head b {{ font-size: 26px; }}
.card.inner .head b {{ font-size: 22px; }}
.machine {{ font-size: 11.5px; letter-spacing: .22em; color: #77756f; white-space: nowrap; }}
.dot {{ display: inline-block; width: 12px; height: 12px; border-radius: 50%; margin-right: 10px; transform: translateY(-2px); }}
.step {{ display: inline-flex; align-items: center; justify-content: center; width: 20px; height: 20px; margin-right: 9px; border: 1.6px solid {GOLD};
        border-radius: 50%; font-family: {SANS}; font-style: normal; font-weight: 600; font-size: 12px; color: {GOLD}; transform: translateY(-1px); flex: none; }}
.wire {{ position: absolute; font-family: {MONO}; font-style: normal; font-size: 12.5px; color: #a7a49b; white-space: nowrap; }}
.cutlabel {{ position: absolute; font-size: 11.5px; letter-spacing: .22em; color: #77756f; }}
.elabel {{ position: absolute; left: 84px; top: {E['top'] + 16}px; }}
.steps {{ position: absolute; left: 70px; top: 910px; width: 1460px; }}
.steps .grid {{ display: grid; grid-template-columns: 1fr 1fr; grid-template-rows: repeat(4, auto); grid-auto-flow: column; column-gap: 56px; margin-top: 8px; }}
.steps .row {{ display: grid; grid-template-columns: 30px 1fr auto 110px; column-gap: 12px; align-items: center; padding: 8px 0;
              border-bottom: 1px solid rgba(255,255,255,.07); font-size: 17px; color: #a29f97; }}
.steps .row .step {{ margin: 0; }}
.steps code {{ font-family: {MONO}; font-style: normal; font-size: 12.5px; color: #a7a49b; white-space: nowrap; }}
.steps .size {{ text-align: right; }}
.tag {{ position: absolute; right: 70px; top: 1128px; font-size: 18px; color: #8b8a84; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">RAO STUDIOS · A BRAIDED LANGUAGE MODEL · THE PLAN</div>
<div class="title">Across machines</div>
<div class="sub">the commons gathers the nodes; states and hits cross the wire, never weights</div>
<div class="card machine-e" style="left:{E['left']}px; top:{E['top']}px; width:{E['right'] - E['left']}px; height:{E['bottom'] - E['top']}px"></div>
<div class="machine elabel">MACHINE E</div>
{svg()}
<div class="card inner" style="top:{ASKER['top']}px; height:{ASKER['bottom'] - ASKER['top']}px">
  <div class="head"><span><i class="dot" style="background:{GOLD}"></i><b>The asker</b></span></div>
  <p>sends the prompt and, if it has one, its own node</p>
  <p>gets each token, cited</p>
</div>
<div class="card inner optional" style="top:{OWN['top']}px; height:{OWN['bottom'] - OWN['top']}px">
  <div class="head"><span><i class="dot" style="background:{VIOLET}"></i><b>Node E</b></span></div>
  <p>optional, offered in the request</p>
  <p>its head and its index</p>
</div>
<div class="card" style="left:{A['left']}px; top:{A['top']}px; width:{A['right'] - A['left']}px; height:{A['bottom'] - A['top']}px">
  <div class="head"><span><i class="dot" style="background:{LINE}"></i><b>The commons</b></span><span class="machine">MACHINE A</span></div>
  <p>the pack, loaded once and frozen; every request enters here</p>
  <h4><span class="step">2</span>the grouping</h4>
  <p>attaches the asker's node if it offered one, then finds the nodes that fit the request; each joins only if its seam is the tail's</p>
  <h4><span class="step">4</span>the shared tail</h4>
  <p>blocks 12–23, norm_f and the embedding, run for every node; a tail state per node, 9.7 MB a session</p>
  <h4>its own strand</h4>
  <p>blocks 0–23, whole; it never leaves A</p>
  <h4><span class="step">6</span>the reed and the mixture</h4>
  <p>the embedding scores each s; the token is split among the commons and the nodes, summing to 1; the session log is written here</p>
</div>
{node_cards()}
{wire_labels()}
{steps()}
<div class="tag">a plan · today a node runs its own tail and Advance returns s and its hits; the wire is not built</div>
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
            tab.screenshot(path=os.path.join(OUT, "across-machines.png"))
            browser.close()
    finally:
        os.unlink(name)


if __name__ == "__main__":
    main()
