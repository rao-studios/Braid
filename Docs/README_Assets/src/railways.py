"""Renders the two railways for royalties, completion and Q/A, and the open question for part 2, in the hero's style.

    python3 -I Docs/README_Assets/src/railways.py Docs/README_Assets

Inputs:  this folder's rr-mark.png; Playfair Display Italic from ~/Library/Fonts.
Outputs: two-railways.png in argv[1].

Completion: the proof's craft run (2026-10-19). Q/A by retrieval: Gita's payout log of April 2026, from
paka.la/blog/royalty-language-and-diffusion-models. The measured line is Braid's question path,
bench question and Docs/ARCHITECTURE.md "Questions" (2026-10-15): Q3 14 of 14 exact answers cite the
fact's partition; Q5a 0 of 23 retold facts decided. The two options for Q/A are a plan, not a result.
"""

import os
import sys
import tempfile

from playwright.sync_api import sync_playwright

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.abspath(sys.argv[1])
PLAYFAIR = os.path.expanduser("~/Library/Fonts/PlayfairDisplay-Italic-VariableFont_wght.ttf")

GREEN, GOLD, LINE, BLUE = "#28a883", "#c7a659", "#cbc8c0", "#5e8fda"
W, H = 1600, 1210
MONO = "Menlo, 'SF Mono', monospace"

LANES = [
    ("COMPLETION", "Token-level citation, solved", GREEN, "proved on craft, 2026-10-19", [
        ("a writer writes", "the passage so far"),
        ("every Thread reads it", "sure or unsure of the next word; the trace checks the index"),
        ("one token is chosen", "its shares add up to 1"),
        ("each token is cited", "to the author's own text, with a royalty share"),
    ]),
    ("Q/A", "Retrieval, the railway in the meantime", BLUE, "the payout half ran in Gita, April 2026", [
        ("a question is asked", "a person or a chatbot"),
        ("Threads retrieve", "the passages that hold the answer"),
        ("a model writes the answer", "from those passages"),
        ("the passages are cited", "to their author, not a website, with a royalty share"),
    ]),
]


def lanes():
    out = []
    for i, (tag, title, colour, chip, steps) in enumerate(LANES):
        top = 340 + i * 196
        cells = "".join(f'<div class="step"><b>{t}</b><p>{d}</p></div>' + ('<div class="arr">→</div>' if k < 3 else "") for k, (t, d) in enumerate(steps))
        out.append(f'<div class="lane" style="top:{top}px; border-color:{colour}55">'
                   f'<div class="lh"><span class="tag" style="color:{colour}">{tag}</span><span class="lt">{title}</span><span class="chip" style="border-color:{colour}88; color:{colour}">{chip}</span></div>'
                   f'<div class="flow">{cells}</div></div>')
    return "".join(out)


def page():
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
.lane {{ position: absolute; left: 70px; width: 1460px; height: 172px; box-sizing: border-box; border: 1px solid; border-radius: 14px; background: #1c1c19; padding: 14px 22px; }}
.lh {{ display: flex; align-items: baseline; gap: 16px; }}
.tag {{ font-size: 12px; letter-spacing: .24em; }}
.lt {{ font-size: 23px; color: #ecebe5; }}
.chip {{ margin-left: auto; border: 1px solid; border-radius: 12px; padding: 2px 12px; font-size: 14px; }}
.flow {{ display: flex; align-items: stretch; margin-top: 14px; }}
.step {{ flex: 1; border: 1px solid rgba(255,255,255,.1); border-radius: 10px; padding: 10px 14px; background: rgba(255,255,255,.02); }}
.step b {{ display: block; font-weight: 400; font-size: 19px; color: #ecebe5; }}
.step p {{ margin: 4px 0 0; font-size: 15px; line-height: 1.3; }}
.arr {{ align-self: center; padding: 0 10px; color: #77756f; font-family: -apple-system, "Helvetica Neue", sans-serif; font-style: normal; font-size: 20px; }}
.sec {{ position: absolute; left: 70px; top: 750px; font-size: 11.5px; letter-spacing: .24em; color: #8b8a84; }}
.sec em {{ font-style: italic; letter-spacing: 0; font-size: 18px; color: #a29f97; margin-left: 12px; }}
.opt {{ position: absolute; top: 784px; width: 710px; height: 270px; box-sizing: border-box; border: 1px solid rgba(255,255,255,.12); border-radius: 14px; background: #1c1c19; padding: 16px 22px; }}
.opt .letter {{ font-family: {MONO}; font-style: normal; font-size: 12.5px; color: {GOLD}; }}
.opt h3 {{ margin: 2px 0 0; font-weight: 400; font-size: 24px; color: #ecebe5; }}
.opt > p {{ margin: 6px 0 10px; font-size: 16px; line-height: 1.35; color: #b4b1a9; }}
.opt ul {{ margin: 0; padding: 0; list-style: none; }}
.opt li {{ display: grid; grid-template-columns: 22px 1fr; font-size: 16px; line-height: 1.35; color: #a29f97; margin-top: 6px; }}
.p {{ color: {GREEN}; font-style: normal; font-weight: 600; }}
.m {{ color: #c0705a; font-style: normal; font-weight: 600; }}
.note {{ position: absolute; left: 70px; top: 1078px; width: 1460px; border-top: 1px solid rgba(255,255,255,.12); padding-top: 12px; font-size: 17px; line-height: 1.4; color: #b4b1a9; }}
.note b {{ font-weight: 400; color: #e3e1da; }}
.tag2 {{ position: absolute; right: 70px; top: 1160px; font-size: 16px; color: #8b8a84; }}
</style></head><body>
<img class="mark" src="rr-mark.png">
<div class="caption">RAO STUDIOS · A BRAIDED LANGUAGE MODEL · THE SERIES</div>
<div class="title">Two ways to be cited</div>
<div class="sub">completion cites each token; Q/A cites the passages behind an answer</div>
{lanes()}
<div class="sec">PART 2 · THE OPEN QUESTION<em>where should Q/A citation live?</em></div>
<div class="opt" style="left:70px"><span class="letter">A · KEEP</span><h3>Retrieval answers, the author is cited</h3>
  <p>Questions are answered from retrieved passages, as today.</p>
  <ul><li><span class="p">+</span><span>The author is credited for the passage, not a web page.</span></li>
  <li><span class="p">+</span><span>Completion keeps its own method: follow the writer's trajectory, pay the Thread whose writing is followed.</span></li>
  <li><span class="m">−</span><span>The answer is only as good as what retrieval finds.</span></li></ul></div>
<div class="opt" style="left:820px; width:710px"><span class="letter">B · TRAIN IT IN</span><h3>The Thread answers, cited with a share</h3>
  <p>Questions are stemmed from facts, so the Thread answers without retrieval and the answer is cited.</p>
  <ul><li><span class="p">+</span><span>One model does both jobs, and nothing is retrieved at answer time.</span></li>
  <li><span class="m">−</span><span>It leaves the completion philosophy: Q/A is paid by fact, not by a followed trajectory.</span></li>
  <li><span class="m">−</span><span>When several Threads hold the same fact there is nothing to follow, so no reason to lift one, unless a reliability score can be read from a record of trust and dependability.</span></li></ul></div>
<div class="note"><b>Measured so far</b>, on Braid's own question path (2026-10-15): when an answer is exact, its citation is right, 14 of 14. Facts held by several Threads are not yet decided, 0 of 23. That second number is option B's problem, in a small test.</div>
<div class="tag2">royalty railways · the thinking behind this is in Royalty Language &amp; Diffusion Models, paka.la</div>
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
            tab.screenshot(path=os.path.join(OUT, "two-railways.png"))
            browser.close()
    finally:
        os.unlink(name)


if __name__ == "__main__":
    main()
