#!/usr/bin/env python3
"""Exports every figure as images, through the installed Google Chrome.

    python3 -I Docs/site/src/export.py                                   # every figure: PNG light and dark at 2x, SVG where it is one drawing
    python3 -I Docs/site/src/export.py --only receipt,gate-memory
    python3 -I Docs/site/src/export.py --blog-assets <dir> --post <slug> --only two-entropies,receipt,gate-memory

Reads Docs/site/figures/<id>.html (run src/figures.py first). Writes Docs/site/export/<id>@2x.png,
<id>-dark@2x.png, <id>.svg and index.json. With --blog-assets it also writes NN-<id>.svg (or .png) into
that folder, in the order given, and a captions.md with one line per figure in the blog's form:
![<caption>](/blog-assets/<slug>/NN-<id>.svg "float-right").

A figure exports as SVG only when it is a single drawing; a figure made of several drawings, tables or
controls exports as PNG, which is then the faithful copy. The SVG has every computed colour and font
written into it, so it stands alone in either theme it was exported from.
"""

import argparse
import json
import re
import shutil
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
SITE = REPO / "Docs" / "site"
FIGS = SITE / "figures"
OUT = SITE / "export"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default=None)
    parser.add_argument("--blog-assets", default=None)
    parser.add_argument("--post", default=None)
    parser.add_argument("--width", type=int, default=960)
    args = parser.parse_args()
    if args.blog_assets and not args.post:
        parser.error("--blog-assets needs --post <slug>")
    pages = sorted(FIGS.glob("*.html"))
    if args.only:
        wanted = args.only.split(",")
        by = {p.stem: p for p in pages}
        missing = [w for w in wanted if w not in by]
        if missing:
            sys.exit(f"export.py: no figure page for {', '.join(missing)}; run src/figures.py")
        pages = [by[w] for w in wanted]
    OUT.mkdir(exist_ok=True)
    from playwright.sync_api import sync_playwright
    index = []
    with sync_playwright() as pw:
        browser = pw.chromium.launch(channel="chrome")
        for theme in ("light", "dark"):
            context = browser.new_context(viewport={"width": args.width, "height": 900}, device_scale_factor=2, color_scheme=theme, reduced_motion="reduce")
            for page_path in pages:
                fid = page_path.stem
                page = context.new_page()
                errors = []
                page.on("pageerror", lambda e, errors=errors: errors.append(str(e)))
                page.goto(page_path.as_uri() + f"?theme={theme}&export=1")
                page.wait_for_function("document.documentElement.getAttribute('data-mounted') === '1'", timeout=20000)
                page.wait_for_timeout(120)
                fig = page.locator("figure.fig").first
                if fig.get_attribute("data-rendered") != "ok" or errors:
                    sys.exit(f"export.py: {fid} did not draw ({'; '.join(errors) or fig.get_attribute('data-rendered')})")
                png = OUT / (f"{fid}@2x.png" if theme == "light" else f"{fid}-dark@2x.png")
                fig.screenshot(path=str(png))
                entry = next((e for e in index if e["id"] == fid), None)
                if entry is None:
                    entry = {"id": fid, "png": {}, "svg": {}}
                    index.append(entry)
                entry["png"][theme] = png.name
                drawings = page.evaluate("document.querySelectorAll('figure.fig .fig-body svg').length")
                tables = page.evaluate("[...document.querySelectorAll('figure.fig .fig-body > *')].filter(el => !(el.matches('svg, .fig-controls, .legend, .note, .readout'))).length")
                if drawings == 1 and tables == 0:
                    svg = page.evaluate("Braid.exportSVG(document.querySelector('figure.fig'))")
                    name = f"{fid}.svg" if theme == "light" else f"{fid}-dark.svg"
                    (OUT / name).write_text('<?xml version="1.0" encoding="UTF-8"?>\n' + svg, encoding="utf-8")
                    entry["svg"][theme] = name
                else:
                    entry["svgSkipped"] = "more than one drawing, or tables and text: the PNG is the faithful copy"
                entry["caption"] = page.evaluate("(document.querySelector('figure.fig > figcaption') || {}).textContent || ''").replace("In context", "").strip()
                page.close()
            context.close()
        browser.close()
    (OUT / "index.json").write_text(json.dumps(index, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"exported {len(index)} figures to Docs/site/export ({sum(1 for e in index if e['svg'])} with SVG)")
    if args.blog_assets:
        dest = Path(args.blog_assets).expanduser()
        dest.mkdir(parents=True, exist_ok=True)
        lines = []
        for n, entry in enumerate(index, start=1):
            src = entry["svg"].get("light") or entry["png"]["light"]
            ext = Path(src).suffix
            name = f"{n:02d}-{entry['id']}{ext}"
            shutil.copyfile(OUT / src, dest / name)
            # A blog image is static: drop the sentences that tell a reader what to click or drag.
            sentences = re.split(r"(?<=[.!?])\s+", entry["caption"])
            caption = " ".join(x for x in sentences if not re.match(r"^(Drag|Click|Pick|Slide|Switch|Push|Hover|Paste|Step|Select|Use)\b", x) and "the arrow keys" not in x).replace('"', "'")
            lines.append(f'![{caption}](/blog-assets/{args.post}/{name} "float-right")')
        (dest / "captions.md").write_text("\n\n".join(lines) + "\n", encoding="utf-8")
        print(f"wrote {len(index)} figures and captions.md to {dest}")


if __name__ == "__main__":
    main()
