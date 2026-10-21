#!/usr/bin/env bash
# WHAT: Build the proof (release) and run it: two Threads on one corpus, one with blocks 0..<12 of
#       its own (the delta) and one with the commons' blocks, the same texts scored through both,
#       and the rules in Sources/Proof/ProofRules.swift read over them. Arguments go to the proof:
#       `proof.sh --help` lists them.
# IN:   run.sh's switches (BRAID_METALLIB=rebuild, FRIGATE_DIR). The braid-n3 dataset: the T9
#       mounted, or BRAID_DATASETS_DIR pointing at a folder that holds it.
# PIN:  One MLX workload at a time: never beside training, benches or GPU tests.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
BRAID_PRODUCT=Proof exec "$HERE/run.sh" "$@"
