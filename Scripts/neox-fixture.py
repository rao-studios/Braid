#!/usr/bin/env python3
# WHAT: Record how Hugging Face's own tokenizers library encodes a handful of strings with the
#       pack's tokenizer.json, so BraidTokenizer (Frigate's non-strict BPE fallback) is checked
#       against an independent implementation. One-time; the fixture is committed.
# IN:   the tokenizer.json path and the output path.
import json, sys
from tokenizers import Tokenizer
tok = Tokenizer.from_file(sys.argv[1])
texts = [
    "Hello world.", "  two  spaces\n\nand a break", "naïve café 日本", "The history of the city begins in 1848, when",
    "It was the best of times, it was the worst of times.", " the cat sat on the mat.", "Question: When was the Eiffel Tower completed?\nStem: The Eiffel Tower was completed in ___",
    "v2.1.7 shipped; 3.14159 is pi\tand tabs.", "", "a",
]
out = {t: tok.encode(t, add_special_tokens=False).ids for t in texts}
out["<vocab>"] = tok.get_vocab_size(with_added_tokens=True)
json.dump(out, open(sys.argv[2], "w"), ensure_ascii=False, indent=1)
print("wrote", sys.argv[2], "vocab", out["<vocab>"])
