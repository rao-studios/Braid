#!/usr/bin/env bash
# WHAT: Build the playground (release), point SwiftPM at the sibling AII checkout, put MLX's Metal
#       library beside the binary when it is missing, and run it. Arguments go to the playground:
#       `run.sh forget` takes its records out of the AII lane.
# IN:   BRAID_METALLIB=rebuild reinstalls mlx.metallib (after a Frigate/MLX update), as in
#       Scripts/cli.sh. FRIGATE_DIR overrides SwiftPM's checkout of Frigate. BRAID_PRODUCT names the program
#       (Braid, the playground, by default); Examples/proof.sh runs this script with Proof. Both
#       programs build into one folder, so one mlx.metallib serves both.
# OUT:  The build's output in .build/run-<product>.log; on a failed build, its errors and that path.
# PIN:  One MLX workload at a time: never beside training, benches or GPU tests. Paths are taken
#       with /bin/pwd -P, so `./examples/run.sh` on a case-insensitive disk builds the same package,
#       spelled as on disk, rather than the same files under a second spelling.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && /bin/pwd -P)"
BRAID_ROOT="$(cd "$HERE/.." && /bin/pwd -P)"
AII_DIR="$BRAID_ROOT/../AII"

# A sibling AII checkout stands in for the URL dependency, as Scripts/cli.sh does for Braid.
# Mirrors are read from the package being built, so the playground needs its own. Resolving
# through it can record AII's pin as a local checkout; Package.resolved must keep AII as
# remoteSourceControl, or a clone with no ../AII cannot resolve.
MIRRORS="$HERE/.swiftpm/configuration/mirrors.json"
if [ -d "$AII_DIR/Sources/AII" ] && ! grep -q 'rao-studios/AII.git' "$MIRRORS" 2>/dev/null; then
    echo "run.sh: pointing SwiftPM at the sibling AII checkout" >&2
    swift package --package-path "$HERE" config set-mirror \
        --original https://github.com/rao-studios/AII.git --mirror "$(cd "$AII_DIR" && pwd)" >&2
fi

# Braid's sources build against the playground's pins, so they should be Braid's.
aii_pin() { sed -n '/"identity" : "aii"/,/"revision"/s/.*"revision" : "\([0-9a-f]*\)".*/\1/p' "$1" 2>/dev/null; }
if [ -f "$HERE/Package.resolved" ] && [ "$(aii_pin "$BRAID_ROOT/Package.resolved")" != "$(aii_pin "$HERE/Package.resolved")" ]; then
    echo "run.sh: Examples/Package.resolved pins another AII than Braid's: cp ../Package.resolved Package.resolved" >&2
fi

PRODUCT="${BRAID_PRODUCT:-Braid}"
echo "run.sh: building $PRODUCT (release)" >&2
log="$HERE/.build/run-$PRODUCT.log"
mkdir -p "$HERE/.build"
if ! swift build --package-path "$HERE" -c release --product "$PRODUCT" > "$log" 2>&1; then
    # SwiftPM's own last line is often a bare "Build failed"; the errors above it are the reason.
    if grep -q "error:" "$log"; then grep "error:" "$log" | head -n 40 >&2 || true; else tail -n 20 "$log" >&2; fi
    echo "run.sh: building $PRODUCT failed; the whole log is $log" >&2
    exit 1
fi
bin_dir="$(swift build --package-path "$HERE" -c release --show-bin-path)"
if [ ! -f "$bin_dir/mlx.metallib" ] || [ "${BRAID_METALLIB:-}" = "rebuild" ]; then
    echo "run.sh: installing mlx.metallib beside the binary" >&2
    # The shaders of the Frigate this package resolved, else a sibling checkout.
    if [ -z "${FRIGATE_DIR:-}" ]; then
        FRIGATE_DIR="$HERE/.build/checkouts/Frigate"
        [ -x "$FRIGATE_DIR/scripts/build-metallib.sh" ] || FRIGATE_DIR="$BRAID_ROOT/../Frigate"
    fi
    if [ ! -x "$FRIGATE_DIR/scripts/build-metallib.sh" ]; then
        echo "run.sh: no scripts/build-metallib.sh in $FRIGATE_DIR; set FRIGATE_DIR to a Frigate checkout" >&2
        exit 1
    fi
    "$FRIGATE_DIR/scripts/build-metallib.sh" release --package "$HERE" > /dev/null
fi
exec "$bin_dir/$PRODUCT" "$@"
