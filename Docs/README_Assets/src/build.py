"""Builds the README's images from HTML, rendered by the installed Google Chrome through Playwright.

    Docs/README_Assets/src/build.sh            # exports the studio frames, then runs this

Inputs:  the frames and still `ReadmeAssetsExport` wrote (argv[1]): frames/*.html, frames.json,
         braid-screen.html; this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts.
Outputs: hero.png, braid.gif, braid-screen.png, studio-legend.png, cli-guide.png in argv[2].
"""

import html
import json
import math
import os
import re
import sys
import tempfile

from PIL import Image
from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
EXPORT = os.path.abspath(sys.argv[1])
OUT = os.path.abspath(sys.argv[2])
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

# The studio's palette (BraidTerminal/Style/Palette.swift, true colour).
BG, FG, DIM, MUTED, BORDER, WHITE = "#141414", "#E6E2D8", "#8A8A8A", "#6E6E6E", "#3A3A3A", "#F4F4F4"
BLUE, GREEN, ORANGE, GOLD, RED = "#4C8DF5", "#2EB67D", "#F0883E", "#D4AF37", "#E5484D"
# The hero's own colours (RaoLM's og-image).
HERO_BLUE, HERO_GREEN, HERO_ORANGE, HERO_GOLD, HERO_LINE = "#5e8fda", "#28a883", "#d8773f", "#c7a659", "#cbc8c0"
# Region outlines in the legend, one colour each.
REGION = ["#b197fc", "#4dabf7", "#69db7c", "#ffd43b", "#ff8787", "#38d9a9", "#ffa94d", "#91a7ff", "#c0eb75", "#f783ac"]

SANS = "-apple-system, 'SF Pro Text', 'Helvetica Neue', Helvetica, Arial, sans-serif"
MONO = "Menlo, 'SF Mono', monospace"
CELL_H = 19  # px per terminal row, as CanvasHTML.page draws them


def shoot(browser, page_html, path, selector=None, viewport=(1200, 800), scale=2):
    """Writes `page_html` beside the inputs (so relative URLs resolve) and screenshots it."""
    with tempfile.NamedTemporaryFile("w", suffix=".html", dir=HERE, delete=False, encoding="utf-8") as f:
        f.write(page_html)
        name = f.name
    try:
        page = browser.new_page(device_scale_factor=scale, viewport={"width": viewport[0], "height": viewport[1]})
        page.goto("file://" + name)
        page.wait_for_timeout(150)
        if selector:
            page.locator(selector).screenshot(path=path)
        else:
            page.screenshot(path=path, full_page=True)
        page.close()
    finally:
        os.unlink(name)


def terminal_rows(path):
    """The rows of a frame CanvasHTML wrote, and the page's background."""
    text = open(path, encoding="utf-8").read()
    rows = re.findall(r'<div class="row">.*?</div>', text)
    return "\n".join(rows)


# MARK: The hero

def strand_path(phase, x0=68, x1=740, y=469, amplitude=40, period=250):
    points = []
    x = x0
    while x <= x1:
        t = (x - x0) / (x1 - x0)
        a = amplitude * (1 - t) ** 1.25
        points.append((x, y + a * math.sin(2 * math.pi * (x - x0) / period + phase)))
        x += 3
    return "M" + " L".join(f"{px:.1f},{py:.1f}" for px, py in points)


def hero(browser):
    strands = "".join(
        f'<path d="{strand_path(phase)}" fill="none" stroke="{colour}" stroke-width="3.6" stroke-linecap="round"/>'
        for phase, colour in [(math.pi * 0.62, HERO_BLUE), (math.pi * 1.95, HERO_GREEN), (math.pi * 1.28, HERO_ORANGE)])
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
@font-face {{ font-family: "Playfair"; font-style: italic; font-weight: 400 900; src: url("file://{PLAYFAIR}") format("truetype"), local("Playfair Display Italic"); }}
html, body {{ margin: 0; width: 1200px; height: 630px; overflow: hidden; }}
body {{ position: relative; font-family: "Playfair", Georgia, serif; font-style: italic;
       background: radial-gradient(ellipse 90% 100% at 22% 20%, #20201c 0%, #191917 45%, #121211 100%); }}
.mark {{ position: absolute; left: 57.5px; top: 52px; width: 72px; }}
.caption {{ position: absolute; left: 143.5px; top: 72px; letter-spacing: .3em; font-size: 16.5px; color: #8b8a84; font-variant-numeric: lining-nums; }}
.title {{ position: absolute; left: 34px; top: 112px; padding-left: 40px; font-size: 220px; line-height: 1; font-weight: 500; letter-spacing: -.005em;
         background: linear-gradient(100deg, #8d9097 0%, #c8cad0 35%, #f2f3f6 58%, #b6b9c1 100%);
         -webkit-background-clip: text; background-clip: text; color: transparent; padding-right: 30px; }}
.sub {{ position: absolute; left: 65.5px; top: 334px; font-size: 45px; color: #9b9991; }}
svg {{ position: absolute; left: 0; top: 0; }}
.legend {{ position: absolute; left: 66px; top: 543px; width: 1050px; display: flex; gap: 32px; align-items: baseline; font-size: 24px; color: #8b8a84; }}
.legend b {{ font-weight: 400; color: #e9e7e0; }}
.dot {{ display: inline-block; width: 13px; height: 13px; border-radius: 50%; margin-right: 10px; transform: translateY(-1px); }}
.tag {{ margin-left: auto; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">RAO STUDIOS · A MAMBA2 BRAID</div>
<div class="title">Braid</div>
<div class="sub">every token, split by the Thread that wrote it</div>
<svg width="1200" height="630">{strands}
  <line x1="740" y1="469" x2="1092" y2="469" stroke="{HERO_LINE}" stroke-width="3" stroke-linecap="round"/>
  <circle cx="1102" cy="469" r="9.5" fill="none" stroke="{HERO_GOLD}" stroke-width="2.4"/>
  <circle cx="1102" cy="469" r="4" fill="{HERO_GOLD}"/>
</svg>
<div class="legend">
  <span><i class="dot" style="background:{HERO_BLUE}"></i><b>Ambient</b> · text</span>
  <span><i class="dot" style="background:{HERO_GREEN}"></i><b>Craft</b> · code</span>
  <span><i class="dot" style="background:{HERO_ORANGE}"></i><b>Veil</b> · visuals</span>
  <span class="tag">one Thread each, one braid, every token cited</span>
</div>
</body></html>"""
    shoot(browser, page, os.path.join(OUT, "hero.png"), viewport=(1200, 630))


# MARK: The GIF and the still

def gif(browser):
    records = json.load(open(os.path.join(EXPORT, "frames.json")))
    shots = []
    with tempfile.TemporaryDirectory() as tmp:
        for i, record in enumerate(records):
            page = open(os.path.join(EXPORT, record["file"]), encoding="utf-8").read()
            path = os.path.join(tmp, f"{i:04d}.png")
            shoot(browser, page, path, selector="#term", scale=1)
            shots.append((path, record["milliseconds"]))
        frames = [Image.open(p).convert("RGB") for p, _ in shots]
        # One palette for every frame, so frames diff cleanly: taken from every answer's last frame
        # stacked together, so each strand's colour (gold, blue, green, orange) is in it.
        ends = [frames[i] for i, (_, ms) in enumerate(shots) if ms >= 1000] or [frames[-1]]
        stack = Image.new("RGB", (ends[0].width, sum(e.height for e in ends)))
        y = 0
        for e in ends:
            stack.paste(e, (0, y))
            y += e.height
        palette_image = stack.quantize(colors=160, method=Image.Quantize.MEDIANCUT)
        quantized = [f.quantize(palette=palette_image, dither=Image.Dither.NONE) for f in frames]
        quantized[0].save(os.path.join(OUT, "braid.gif"), save_all=True, append_images=quantized[1:],
                          duration=[ms for _, ms in shots], loop=0, optimize=True, disposal=1)


def still(browser):
    page = open(os.path.join(EXPORT, "braid-screen.html"), encoding="utf-8").read()
    shoot(browser, page, os.path.join(OUT, "braid-screen.png"), selector="#term", scale=2)


# MARK: The legend

# (number, title, description, row, rows, col, cols, side)
REGIONS = [
    (1, "Header", "the screen, the pack, the strands in the braid and λ; fixtures or the running job on the right", 0, 1, 0, 120, "left"),
    (2, "Tabs", "Braid, AII and Doctor (1–3 switch)", 1, 1, 0, 120, "left"),
    (3, "Prompt ▸ answer", "the prompt, then the answer, each token in the colour of the strand that supplied it", 3, 1, 1, 118, "left"),
    (4, "Token", "the cursor token: who supplied it, every share, p and the gate's entropy; its trace, H_knn and H_lm, the shadow β4; its citation and verification", 6, 3, 1, 118, "left"),
    (5, "Threads", "every Thread: its source, attached or detached, its share of the answer (tab focuses, space attaches or detaches)", 11, 8, 0, 72, "left"),
    (6, "Royalties", "tokens led and summed share, by strand; R switches to credit and the cited documents", 11, 8, 72, 48, "right"),
    (7, "Prompt", "the prompt field, the settings (λ, likeliest or sampled, Q/A) and the answer's status", 19, 13, 0, 72, "left"),
    (8, "Events", "asks, attaches and detaches, verifications, jobs", 19, 13, 72, 48, "right"),
    (9, "Key hints", "the keys this screen takes (? lists every key)", 32, 1, 0, 120, "left"),
    (10, "Status bar", "the braid and its strands, the work area; the last message on the right", 33, 1, 0, 120, "left"),
]

MARKS = [
    (f'<span style="color:{DIM}">on port</span> <span style="color:{GOLD}">▸</span><span style="color:{GREEN}"> 41027.</span>',
     "where the prompt ends and the answer begins"),
    (f'<span style="color:{BLUE}">1128</span>  <span style="color:{GREEN}">41027</span>  <span style="color:{ORANGE}">Olmira</span>  <span style="color:{GOLD}">newbie</span>',
     "a token's colour is the strand that supplied it: Ambient, Craft, Veil, or the commons"),
    (f'<span style="color:{FG}">shared</span>  <span style="color:{GREEN};opacity:.62">uncited</span>  <span style="color:{GREEN};text-decoration:underline;text-underline-offset:3px">verified span</span>',
     "no strand reached 0.6 of it · no retrieved context predicted it · inside a span re-read from its source"),
    (f'<span style="color:{GREEN}"> </span><span style="color:{BG};background:{GREEN}">410</span><span style="color:{GREEN};text-decoration:underline;text-underline-offset:3px">27.</span>',
     "the cursor token (← → move it)"),
    (f'<span style="color:{GOLD}">◉ verified</span>  <span style="color:{RED}">✗ stale</span>',
     "a cited span re-read from its source, token for token, or changed since"),
    (f'<span style="color:{GREEN}">● attached</span>  <span style="color:{MUTED}">○ detached</span>',
     "a Thread in the braid or out of it; space switches at the next token"),
    (f'<span style="color:{GREEN}">█████▌</span><span style="color:{MUTED}">░░</span> <span style="color:{FG}">Σ 12.00</span>',
     "a strand's summed share of the answer"),
    (f'<span style="color:{MUTED}">(shadow β4: craft 1.00)</span>',
     "the counterfactual trace gate: logged at every token, never applied"),
    (f'<span style="color:{FG}">trace: in-doc …63f9 L=31</span>',
     "how long the text has followed one of the Thread's documents, in order"),
]


def legend(browser):
    rows = terminal_rows(os.path.join(EXPORT, "braid-screen.html"))
    boxes, badges = [], []
    for number, title, _, row, nrows, col, ncols, side in REGIONS:
        colour = REGION[number - 1]
        boxes.append(f'<div class="box" style="border-color:{colour};left:calc(16px + {col}ch - 3px);top:{14 + row * CELL_H - 2}px;'
                     f'width:calc({ncols}ch + 2px);height:{nrows * CELL_H}px"></div>')
        centre = 14 + row * CELL_H + nrows * CELL_H / 2
        if side == "left":
            badges.append(f'<div class="badge" style="background:{colour};left:-46px;top:{centre - 13}px">{number}</div>'
                          f'<div class="wire" style="background:{colour};left:-20px;width:{20 + 16 + 0}px;top:{centre - 1}px"></div>')
        else:
            badges.append(f'<div class="badge" style="background:{colour};right:-46px;top:{centre - 13}px">{number}</div>'
                          f'<div class="wire" style="background:{colour};right:-20px;width:36px;top:{centre - 1}px"></div>')
    regions = "".join(
        f'<li><i style="background:{REGION[n - 1]}">{n}</i><div><b style="color:{REGION[n - 1]}">{html.escape(t)}</b><span>{html.escape(d)}</span></div></li>'
        for n, t, d, *_ in REGIONS)
    marks = "".join(f'<li><code>{example}</code><span>{html.escape(meaning)}</span></li>' for example, meaning in MARKS)
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
html, body {{ margin: 0; background: {BG}; color: {FG}; font-family: {SANS}; }}
.sheet {{ padding: 36px 70px 40px 70px; width: 1150px; }}
h1 {{ font-size: 30px; margin: 0 0 4px 0; color: {WHITE}; font-weight: 700; }}
.lede {{ color: {DIM}; font-size: 17px; margin-bottom: 26px; }}
.screen {{ position: relative; display: inline-block; }}
.term {{ position: relative; display: inline-block; padding: 14px 16px; background: {BG}; font-family: {MONO}; font-size: 15px; line-height: {CELL_H}px;
        border: 1px solid #262626; border-radius: 6px; }}
.row {{ white-space: pre; height: {CELL_H}px; }}
.box {{ position: absolute; border: 2px solid; border-radius: 4px; pointer-events: none; }}
.badge {{ position: absolute; width: 26px; height: 26px; border-radius: 50%; color: #111; font: 700 14px/26px {SANS}; text-align: center; }}
.wire {{ position: absolute; height: 2px; }}
.cols {{ display: flex; gap: 60px; margin-top: 34px; border-top: 1px solid #2a2a2a; padding-top: 26px; }}
.cols > div {{ flex: 1; }}
h2 {{ font-size: 21px; color: {WHITE}; margin: 0 0 16px 0; }}
ul {{ list-style: none; margin: 0; padding: 0; }}
.regions li {{ display: flex; gap: 14px; margin-bottom: 13px; }}
.regions i {{ flex: 0 0 26px; height: 26px; border-radius: 50%; color: #111; font: normal 700 14px/26px {SANS}; text-align: center; }}
.regions b {{ display: block; font-size: 17px; }}
.regions span, .marks span {{ color: #b9b6ae; font-size: 14.5px; line-height: 1.4; }}
.marks li {{ margin-bottom: 13px; }}
.marks code {{ display: block; font-family: {MONO}; font-size: 15px; margin-bottom: 3px; white-space: pre; }}
</style></head><body><div class="sheet" id="sheet">
<h1>The Braid screen</h1>
<div class="lede">braid ui · 1 Braid: every token split by the strand that supplied it, cited and verified</div>
<div class="screen"><div class="term">{rows}{"".join(boxes)}</div>{"".join(badges)}</div>
<div class="cols">
  <div class="regions"><h2>Regions</h2><ul>{regions}</ul></div>
  <div class="marks"><h2>Marks, in the studio's colours</h2><ul>{marks}</ul></div>
</div>
</div></body></html>"""
    shoot(browser, page, os.path.join(OUT, "studio-legend.png"), selector="#sheet", viewport=(1300, 1500), scale=2)


# MARK: The CLI guide

STEPS = [
    ("#b197fc", "Set up", "once per machine",
     [("braid doctor", "checks the Metal library, the work area, the pack, the AII"),
      ("braid init --base AntonV/mamba2-130m-hf", "imports the Mamba2 pack and writes braid.toml")]),
    ("#4dabf7", "Bring a corpus", "an AII lane, a dataset node or a folder",
     [("braid aii create demo-a", "a demo AII on this machine (or use your own ~/.rao)"),
      ("braid aii ingest demo-a/ambient --from dataset:braid-n3#ambient", "documents into a lane")]),
    ("#69db7c", "Make a Thread", "its own blocks, trained; its own index",
     [("braid thread create ambient --corpus aii:demo-a/ambient", "snapshot → train → index → live"),
      ("braid thread sync ambient", "when the lane changes: a new version")]),
    ("#ffd43b", "Ask the braid", "the commons and every attached Thread",
     [("braid", "the studio: ⏎ asks, space attaches or detaches"),
      ('braid chat "When was Tillyburn founded?"', "a question: stem, context, one sentence")]),
    ("#ff8787", "Check the answer", "replayed from the session log",
     [("braid verify <session> --live --keys", "arithmetic, traces, spans re-read, keys"),
      ("braid credit <session>", "credit and royalties by Thread and document")]),
    ("#38d9a9", "Measure", "rules fixed before numbers",
     [("braid bench trace | lift | gaming | question", "the acceptance benches"),
      ("braid init --measure", "what the language module costs on this machine")]),
]


def cli_guide(browser):
    cards = []
    for i, (colour, title, note, commands) in enumerate(STEPS, 1):
        lines = "".join(f'<div class="cmd"><code><span class="dollar">$</span> {html.escape(c)}</code><span>{html.escape(d)}</span></div>'
                        for c, d in commands)
        cards.append(f'<div class="card" style="--c:{colour}"><div class="head"><i>{i}</i><b>{title}</b><em>{note}</em></div>{lines}</div>')
    flow = " ".join(
        f'<span class="node" style="color:{c}">{t}</span>' + ('<span class="arrow">→</span>' if j < 4 else "")
        for j, (c, t) in enumerate([(BLUE, "corpus"), (GREEN, "Thread · blocks + index"), (GOLD, "braid · commons + Threads"),
                                    (FG, "session log"), (GOLD, "◉ verified")]))
    page = f"""<!doctype html><html><head><meta charset="utf-8"><style>
html, body {{ margin: 0; background: {BG}; color: {FG}; font-family: {SANS}; }}
.sheet {{ padding: 36px 44px 38px 44px; width: 1150px; }}
h1 {{ font-size: 30px; margin: 0 0 4px 0; color: {WHITE}; }}
.lede {{ color: {DIM}; font-size: 17px; margin-bottom: 18px; }}
.flow {{ font-family: {MONO}; font-size: 15px; margin-bottom: 26px; padding: 12px 16px; border: 1px solid #262626; border-radius: 6px; display: inline-block; }}
.arrow {{ color: {MUTED}; margin: 0 10px; }}
.grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 18px; }}
.card {{ border: 1px solid #2a2a2a; border-left: 4px solid var(--c); border-radius: 6px; padding: 16px 18px 12px 18px; background: #181818; }}
.head {{ display: flex; align-items: baseline; gap: 12px; margin-bottom: 12px; }}
.head i {{ font: normal 700 14px/26px {SANS}; width: 26px; height: 26px; border-radius: 50%; background: var(--c); color: #111; text-align: center; flex: 0 0 26px; transform: translateY(-2px); }}
.head b {{ font-size: 19px; color: var(--c); }}
.head em {{ font-style: normal; color: {DIM}; font-size: 14.5px; }}
.cmd {{ margin-bottom: 10px; }}
.cmd code {{ display: block; font-family: {MONO}; font-size: 14px; color: {WHITE}; white-space: pre; overflow: hidden; text-overflow: ellipsis; }}
.cmd .dollar {{ color: {MUTED}; }}
.cmd > span {{ display: block; color: #b9b6ae; font-size: 14px; margin-top: 2px; padding-left: 2ch; }}
.head b {{ white-space: nowrap; }}
</style></head><body><div class="sheet" id="sheet">
<h1>The braid command</h1>
<div class="lede">From a pack to a cited answer, in six steps. Bare <code style="font-family:{MONO};color:{WHITE}">braid</code> opens the studio; every step is also a subcommand.</div>
<div class="flow">{flow}</div>
<div class="grid">{"".join(cards)}</div>
</div></body></html>"""
    shoot(browser, page, os.path.join(OUT, "cli-guide.png"), selector="#sheet", viewport=(1240, 1200), scale=2)


def main():
    os.makedirs(OUT, exist_ok=True)
    with sync_playwright() as p:
        browser = p.chromium.launch(channel="chrome")
        hero(browser)
        still(browser)
        legend(browser)
        cli_guide(browser)
        gif(browser)
        browser.close()
    for name in ("hero.png", "braid.gif", "braid-screen.png", "studio-legend.png", "cli-guide.png"):
        path = os.path.join(OUT, name)
        with Image.open(path) as im:
            print(f"{name}: {im.size[0]}×{im.size[1]}, {os.path.getsize(path) // 1024} KB")


if __name__ == "__main__":
    main()
