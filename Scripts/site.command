#!/bin/zsh
# WHAT: Open Braid, step by step, the tutorial site in Docs/site, in the default browser.
#       Double-click it in Finder, or run Scripts/site.command from anywhere.
# PIN:  The site is plain HTML read from file://, so nothing is built or served. Its data is
#       committed; Docs/site/src/build.sh regenerates it and checks every page. The one thing it
#       writes is Docs/site/local/chat.js, the chat orb's key, which git ignores.
set -euo pipefail
cd "$(dirname "$0")/.."
page="Docs/site/index.html"
if [[ ! -f "$page" ]]; then
  echo "site.command: no $page under $(pwd)" >&2
  exit 1
fi
# The chat orb uses this Mac's Mistral key (the one Ambient and Sewn use), written to a gitignored file.
python3 -I Docs/site/src/chatkey.py || true
open "$page"
echo "opened $(pwd)/$page"
