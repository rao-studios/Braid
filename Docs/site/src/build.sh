#!/bin/zsh
# WHAT: Rebuilds the tutorial site's generated files and checks the site, in order.
#   1. data/*.js from the fixtures (src/data.py; add --refresh to copy a new playground run first)
#      and data/sources/*.js, the code explorer's, from Sources/ and src/trails.json (src/sources.py)
#   2. one embeddable page per figure and per board panel (src/figures.py)
#   3. every page from file://, in Chrome (src/check.py)
# The export (src/export.py) is separate: run it when you want images.
set -euo pipefail
cd "$(dirname "$0")/../../.."
python3 -I Docs/site/src/data.py "$@"
python3 -I Docs/site/src/sources.py
python3 -I Docs/site/src/figures.py
python3 -I Docs/site/src/check.py
