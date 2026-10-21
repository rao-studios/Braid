#!/usr/bin/env python3
"""Gives the site's chat orb this Mac's Mistral key, the one Ambient and Sewn use.

    python3 -I Docs/site/src/chatkey.py            # write Docs/site/local/chat.js from ~/.rao/keys/providers.json
    python3 -I Docs/site/src/chatkey.py --remove   # delete it

The key is read from AII's provider store (`MISTRAL_API_KEY`, written by Ambient), or from the environment
variable of that name. It is written to Docs/site/local/chat.js, which .gitignore keeps out of git, with mode
600. Nothing here prints the key. Scripts/site.command runs this before it opens the site; the orb works
without it too, if the reader pastes a key into the chat, which keeps it in that browser only.

The model is Sewn's default chat model, mistral-large-4, with its reasoning off as Sewn runs it: left on,
Large 4 spends its tokens reasoning and many replies come back empty (AII's ModelConfig, 2026-10-17).
"""

import argparse
import json
import os
import sys
from pathlib import Path

SITE = Path(__file__).resolve().parents[1]
OUT = SITE / "local" / "chat.js"
STORE = Path.home() / ".rao" / "keys" / "providers.json"
MODEL = "mistral-large-4"


def read_key():
    env = os.environ.get("MISTRAL_API_KEY", "").strip()
    if env:
        return env, "the MISTRAL_API_KEY environment variable"
    try:
        entry = json.loads(STORE.read_text(encoding="utf-8")).get("MISTRAL_API_KEY") or {}
    except (OSError, ValueError):
        return None, None
    value = (entry.get("value") or "").strip() if isinstance(entry, dict) else ""
    return (value, f"{STORE} (written by {entry.get('writtenBy', 'an app')})") if value else (None, None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--remove", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()
    if args.remove:
        if OUT.exists():
            OUT.unlink()
        print("chat: removed Docs/site/local/chat.js")
        return
    key, source = read_key()
    if not key:
        if not args.quiet:
            print(f"chat: no Mistral key in {STORE} or the environment; the orb will ask for one")
        return
    config = {"provider": "mistral", "model": MODEL, "reasoning": "none", "key": key, "source": "this Mac's Ambient key"}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    text = ("/* written by Docs/site/src/chatkey.py from this Mac's key store - local only, never commit */\n"
            "window.BraidData = window.BraidData || {};\n"
            f"window.BraidData.chat = {json.dumps(config)};\n")
    fd = os.open(OUT, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(OUT, 0o600)
    if not args.quiet:
        print(f"chat: the orb uses {MODEL} with the key from {source} (Docs/site/local/chat.js, gitignored, mode 600)")


if __name__ == "__main__":
    try:
        main()
    except OSError as e:
        print(f"chat: {e}", file=sys.stderr)
        sys.exit(1)
