"""Renders the proposed protocol as an RPC sequence diagram, in the hero's style: one request, call by call.

    python3 -I Docs/README_Assets/src/sequence.py Docs/README_Assets

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts.
Outputs: call-sequence.png in argv[1]. A plan, not a result: the wire is not built.

The same plan as across.py, drawn for readers outside the code: the request enters at the commons,
which attaches the nodes (the asker's own first, if offered), runs the shared tail, the reed and the
mixture, and streams each token back with its shares and citations. Sizes follow the code: 768 f32
states (3 KB) and k = 16 hits.
"""

import os
import sys
import tempfile

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

# The hero's colours (build.py).
BLUE, GREEN, ORANGE, GOLD, LINE = "#5e8fda", "#28a883", "#d8773f", "#c7a659", "#cbc8c0"
CALL, REPLY = "#d6d3cb", "#8f8c84"
W, H = 1600, 1500
MONO = "Menlo, 'SF Mono', monospace"
SANS = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"

ASKER, COMMONS, NODES = 250, 800, 1330          # lifeline x
HEAD_TOP, HEAD_H, HEAD_W = 330, 96, 340
LIFE_TOP, LIFE_BOTTOM = HEAD_TOP + HEAD_H, 1300
LOOP = (708, 1262)                               # the per-token frame, top and bottom

# (y, kind, from, to, number, words, code)
MESSAGES = [
    (500, "call", ASKER, COMMONS, 1, "the prompt, and the asker's own node if it has one", "Ask(prompt, node?)"),
    (580, "call", COMMONS, NODES, 2, "invites the nodes that fit the prompt", "Attach(session)"),
    (652, "reply", NODES, COMMONS, None, "joins, if it was trained on this commons", "ok · the seam matches"),
    (782, "call", COMMONS, NODES, 3, "the last token", "Advance(token) · 4 B"),
    (854, "reply", NODES, COMMONS, None, "the node's state after its own blocks", "h₁₂ · 3 KB"),
    (926, "self", COMMONS, COMMONS, 4, "runs the shared tail on each state", "blocks 12–23"),
    (1010, "call", COMMONS, NODES, 5, "the state after the shared tail", "Search(s) · 3 KB"),
    (1082, "reply", NODES, COMMONS, None, "the 16 closest passages in its own data", "16 hits"),
    (1150, "self", COMMONS, COMMONS, 6, "mixes every vote into one next token", "reed · mixture"),
    (1226, "call", COMMONS, ASKER, 7, "the token, who supplied it, and the citations", "token · shares · citations"),
]


def arrow(x0, x1, y, kind):
    colour = CALL if kind == "call" else REPLY
    d = 1 if x1 > x0 else -1
    tip = x1 - d * 4
    dash = '' if kind == "call" else ' stroke-dasharray="7 6"'
    out = f'<line x1="{x0 + d * 6}" y1="{y}" x2="{tip}" y2="{y}" stroke="{colour}" stroke-width="2"{dash} stroke-linecap="round"/>'
    if kind == "call":
        out += f'<path d="M{tip},{y} L{tip - d * 13},{y - 6.5} L{tip - d * 13},{y + 6.5} Z" fill="{colour}"/>'
    else:
        out += f'<path d="M{tip - d * 12},{y - 7} L{tip},{y} L{tip - d * 12},{y + 7}" fill="none" stroke="{colour}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'
    return out


def self_call(x, y):
    w, h = 54, 40
    return (f'<path d="M{x + 6},{y} H{x + w} V{y + h} H{x + 10}" fill="none" stroke="{CALL}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>'
            f'<path d="M{x + 10},{y + h} L{x + 23},{y + h - 6.5} L{x + 23},{y + h + 6.5} Z" fill="{CALL}"/>')


def badge(x, y, n):
    return (f'<circle cx="{x}" cy="{y}" r="12" fill="#191917" stroke="{GOLD}" stroke-width="1.6"/>'
            f'<text x="{x}" y="{y + 4.8}" text-anchor="middle" font-family="{SANS}" font-size="13.5" font-weight="600" fill="{GOLD}">{n}</text>')


def svg():
    p = []
    for x in (ASKER, COMMONS, NODES):
        p.append(f'<line x1="{x}" y1="{LIFE_TOP}" x2="{x}" y2="{LIFE_BOTTOM}" stroke="#55534d" stroke-width="1.6" stroke-dasharray="3 7" stroke-linecap="round"/>')
    # The commons is busy for the whole request.
    p.append(f'<rect x="{COMMONS - 6}" y="{MESSAGES[0][0] - 4}" width="12" height="{MESSAGES[-1][0] - MESSAGES[0][0] + 8}" rx="3" fill="#2a2925" stroke="#4d4b45" stroke-width="1"/>')
    # The loop frame.
    p.append(f'<rect x="{ASKER - 150}" y="{LOOP[0]}" width="{NODES - ASKER + 300}" height="{LOOP[1] - LOOP[0]}" rx="12" fill="rgba(255,255,255,.018)" stroke="rgba(199,166,89,.45)" stroke-width="1.4"/>')
    p.append(f'<path d="M{ASKER - 150},{LOOP[0] + 30} H{ASKER + 52} L{ASKER + 68},{LOOP[0] + 14} V{LOOP[0]}" fill="none" stroke="rgba(199,166,89,.45)" stroke-width="1.4"/>')
    for y, kind, x0, x1, n, _, _ in MESSAGES:
        if kind == "self":
            p.append(self_call(x0, y - 20))
        else:
            p.append(arrow(x0, x1, y, kind))
        if n:
            bx = (x0 - 34) if kind == "self" else (x0 + (28 if x1 > x0 else -28))
            p.append(badge(bx, y, n))
    return f'<svg width="{W}" height="{H}">{"".join(p)}</svg>'


def labels():
    out = []
    for y, kind, x0, x1, n, words, code in MESSAGES:
        if kind == "self":
            out.append(f'<div class="label self" style="left:{x0 + 72}px; top:{y - 26}px"><span>{words}</span><code>{code}</code></div>')
        else:
            left, right = min(x0, x1), max(x0, x1)
            out.append(f'<div class="label {kind}" style="left:{left + 50}px; width:{right - left - 100}px; top:{y - 30}px"><span>{words}</span></div>')
            out.append(f'<div class="label {kind}" style="left:{left + 50}px; width:{right - left - 100}px; top:{y + 7}px"><code>{code}</code></div>')
    return "".join(out)


def heads():
    def box(x, inner, extra=""):
        return f'<div class="lifehead{extra}" style="left:{x - HEAD_W / 2}px; top:{HEAD_TOP}px; width:{HEAD_W}px; height:{HEAD_H}px">{inner}</div>'
    stack = "".join(f'<div class="lifehead ghost" style="left:{NODES - HEAD_W / 2 + d}px; top:{HEAD_TOP - d}px; width:{HEAD_W}px; height:{HEAD_H}px"></div>' for d in (16, 8))
    dots = "".join(f'<i class="dot" style="background:{c}"></i>' for c in (BLUE, GREEN, ORANGE))
    return (box(ASKER, f'<b><i class="dot" style="background:{GOLD}"></i>The asker</b><p>an app or a person</p>')
            + box(COMMONS, f'<b><i class="dot" style="background:{LINE}"></i>The commons</b><p>machine A · the shared model, the mixer</p>')
            + stack
            + box(NODES, f'<b><span class="dots">{dots}</span>The nodes</b><p>machines B, C, D … each owns its data</p>'))


def page():
    return f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: {W}px; height: {H}px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic; color: #a29f97;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 62.5px; top: 50px; width: 64px; }}
.caption {{ position: absolute; left: 150px; top: 68px; letter-spacing: .3em; font-size: 15px; color: #8b8a84; }}
.title {{ position: absolute; left: 25px; padding-left: 40px; top: 104px; font-size: 104px; line-height: 1; font-weight: 500; letter-spacing: -.005em; padding-right: 30px; padding-bottom: 32px;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; }}
.sub {{ position: absolute; left: 69px; top: 222px; font-size: 32px; color: #9b9991; }}
svg {{ position: absolute; left: 0; top: 0; }}
.lifehead {{ position: absolute; box-sizing: border-box; border: 1px solid rgba(255,255,255,.13); border-radius: 14px; background: #1d1d1a;
            padding: 16px 20px; text-align: center; }}
.lifehead.ghost {{ background: #1a1a18; border-color: rgba(255,255,255,.08); }}
.lifehead b {{ display: block; font-weight: 400; font-size: 27px; color: #ecebe5; }}
.lifehead p {{ margin: 6px 0 0; font-size: 16px; color: #8f8c84; }}
.dot {{ display: inline-block; width: 12px; height: 12px; border-radius: 50%; margin-right: 10px; transform: translateY(-3px); }}
.dots .dot {{ margin-right: 5px; }}
.dots {{ margin-right: 6px; }}
.label {{ position: absolute; text-align: center; white-space: nowrap; }}
.label span {{ font-size: 18px; color: #d9d6ce; }}
.label.reply span {{ color: #a29f97; }}
.label code {{ font-family: {MONO}; font-style: normal; font-size: 13px; color: #8f8c84; }}
.label.self {{ text-align: left; display: flex; flex-direction: column; gap: 6px; }}
.looplabel {{ position: absolute; left: {ASKER - 136}px; top: {LOOP[0] + 7}px; font-size: 12px; letter-spacing: .24em; color: {GOLD}; }}
.foot {{ position: absolute; left: 70px; top: 1338px; width: 1460px; display: grid; grid-template-columns: repeat(3, 1fr); column-gap: 40px; }}
.foot div {{ border-top: 1px solid rgba(255,255,255,.1); padding-top: 14px; }}
.foot h4 {{ margin: 0; font-size: 12px; font-weight: 400; letter-spacing: .24em; color: #77756f; }}
.foot p {{ margin: 8px 0 0; font-size: 18px; line-height: 1.4; color: #b4b1a9; }}
.tag {{ position: absolute; right: 70px; top: 1446px; font-size: 18px; color: #8b8a84; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">RAO STUDIOS · A BRAIDED LANGUAGE MODEL · PROPOSED PROTOCOL</div>
<div class="title">Call by call</div>
<div class="sub">one request between the asker, the commons and the nodes</div>
{svg()}
{heads()}
<div class="looplabel">FOR EVERY TOKEN</div>
{labels()}
<div class="foot">
  <div><h4>WHAT MOVES</h4><p>per node, per token: one token, two 3 KB states and 16 hits</p></div>
  <div><h4>WHAT NEVER MOVES</h4><p>a node's weights and its documents; they stay on its machine</p></div>
  <div><h4>WHAT THE ASKER GETS</h4><p>every token split among the commons and the nodes that supplied it, each part cited</p></div>
</div>
<div class="tag">proposed, not built · today a braid runs on one machine</div>
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
            tab.screenshot(path=os.path.join(OUT, "call-sequence.png"))
            browser.close()
    finally:
        os.unlink(name)


if __name__ == "__main__":
    main()
