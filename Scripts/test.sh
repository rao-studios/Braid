#!/usr/bin/env bash
# WHAT: Build Braid's tests, put MLX's Metal library where the test bundles can load it, and
#       run them. Extra arguments go to `swift test` (e.g. --filter BraidCoreTests).
# IN:   BRAID_MLX_TESTS (default 1) enables the MLX suites, which run one at a time;
#       BRAID_AII_TESTS=1 also runs the suites that talk to the machine's AII Thread and create
#       demo AIIs under ./aii.
# PIN:  build-metallib.sh copies mlx.metallib into every .xctest bundle so MLX can find it, and
#       those copies break the bundle's ad-hoc re-sign on the next build ("code object is not
#       signed at all"). So the copies are stripped first, the build runs, they are reinstalled,
#       and the tests run with --skip-build.
#
#   Scripts/test.sh
#   Scripts/test.sh --filter BraidCoreTests
#   BRAID_AII_TESTS=1 Scripts/test.sh --filter BraidThreadTests
#
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && /bin/pwd -P)"   # /bin/pwd -P: spelled as on disk; bash's own pwd keeps the typed case

BUILD_DIR="$(swift build --show-bin-path 2>/dev/null || true)"
if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
    while IFS= read -r -d '' bundle; do
        rm -f "$bundle/Contents/MacOS/mlx.metallib"
        rm -rf "$bundle/Contents/MacOS/Resources"
    done < <(find "$BUILD_DIR" -maxdepth 1 -name '*.xctest' -print0 2>/dev/null)
fi

swift build --build-tests
./build-metallib.sh debug > /dev/null
BRAID_MLX_TESTS="${BRAID_MLX_TESTS:-1}" swift test --skip-build "$@"
