#!/usr/bin/env bash
# WHAT: Build MLX's mlx.metallib into this package's .build.
# IN:   [debug|release] (default debug). FRIGATE_DIR overrides where Frigate lives; by default
#       it is SwiftPM's checkout in .build/checkouts, else a sibling ../Frigate.
# OUT:  mlx.metallib beside every Braid binary and inside every .xctest bundle.
# PIN:  A delegate, not an implementation. Frigate owns the vendored .metal sources, so it
#       owns the compile; `swift build` has no Metal step, and without this script the first
#       GPU op dies with "Failed to load the default metallib". Run it after `swift build`
#       (or `swift build --build-tests`), because it installs into the existing .build tree.
#
#   ./build-metallib.sh [debug|release]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
# The checkout is the revision Package.resolved pins, so its shaders match the MLX the binaries link.
if [ -z "${FRIGATE_DIR:-}" ]; then
    FRIGATE_DIR="$REPO_ROOT/.build/checkouts/Frigate"
    [ -x "$FRIGATE_DIR/scripts/build-metallib.sh" ] || FRIGATE_DIR="$REPO_ROOT/../Frigate"
fi
CANONICAL="$FRIGATE_DIR/scripts/build-metallib.sh"

if [ ! -x "$CANONICAL" ]; then
    echo "build-metallib: cannot find $CANONICAL" >&2
    echo "  Run swift build first, so SwiftPM checks Frigate out, or set FRIGATE_DIR." >&2
    exit 1
fi

exec "$CANONICAL" "${1:-debug}" --package "$REPO_ROOT"
