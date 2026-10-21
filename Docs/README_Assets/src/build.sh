#!/bin/zsh
# Rebuilds the README's images: the studio's frames exported from the README fixtures (no MLX, no
# work area), then rendered by Google Chrome through Playwright (pip install playwright; it drives
# the installed Chrome). Writes Docs/README_Assets/{hero.png,braid.gif,braid-screen.png,studio-legend.png,cli-guide.png}.
set -euo pipefail
repo=${0:A:h:h:h:h}
export=$(mktemp -d)
trap 'rm -rf "$export"' EXIT
cd "$repo"
BRAID_MLX_TESTS=0 BRAID_README_ASSETS="$export" Scripts/test.sh --filter ReadmeAssetsExport | grep -E "README ASSETS|error|failed" || true
python3 -I Docs/README_Assets/src/build.py "$export" Docs/README_Assets
