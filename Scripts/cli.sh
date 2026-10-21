#!/usr/bin/env bash
# WHAT: Run the braid CLI from a checkout: build it when a source is newer than the binary
#       (Braid's, its pins or the local AII mirror's), put MLX's Metal library beside it the
#       first time, point SwiftPM at a sibling AII checkout when one exists, then hand every
#       argument to braid. With no arguments in a terminal, braid opens the studio.
# IN:   Arguments go to braid unchanged.
#       BRAID_CONFIG=release   build and run the release binary (default debug)
#       BRAID_BUILD=always     run swift build even when nothing looks newer
#       BRAID_SKIP_BUILD=1     run the binary that is already built
#       BRAID_METALLIB=rebuild reinstall mlx.metallib (after a Frigate/MLX update)
# PIN:  Never changes directory, so relative paths in the arguments resolve against yours.
#       Build chatter goes to stderr and braid's own output to stdout, so
#       `Scripts/cli.sh chat … --json | jq` stays clean. The metallib is only installed when it
#       is missing: build-metallib.sh also copies it into the test bundles, which Scripts/test.sh
#       has to strip again before the next test build.
#
#   Scripts/cli.sh                                   # the studio
#   Scripts/cli.sh doctor
#   Scripts/cli.sh init --base AntonV/mamba2-130m-hf
#   BRAID_CONFIG=release Scripts/cli.sh bench trace --report bench/trace.json
#
set -euo pipefail

source_path="${BASH_SOURCE[0]}"
while [ -L "$source_path" ]; do
    target="$(readlink "$source_path")"
    case "$target" in
        /*) source_path="$target" ;;
        *) source_path="$(dirname "$source_path")/$target" ;;
    esac
done
REPO_ROOT="$(cd "$(dirname "$source_path")/.." && /bin/pwd -P)"   # /bin/pwd -P: spelled as on disk; bash's own pwd keeps the typed case

config="${BRAID_CONFIG:-debug}"
case "$config" in
    debug | release) ;;
    *)
        echo "cli.sh: BRAID_CONFIG must be debug or release, not '$config'" >&2
        exit 64
        ;;
esac

# A sibling AII checkout stands in for the URL dependency (AII's README documents the mirror).
# Resolving through it can record AII's pin as a local checkout; Package.resolved must keep AII as
# remoteSourceControl, or a clone with no ../AII cannot resolve.
AII_DIR="$REPO_ROOT/../AII"
MIRRORS="$REPO_ROOT/.swiftpm/configuration/mirrors.json"
if [ -d "$AII_DIR/Sources/AII" ] && ! grep -q 'rao-studios/AII.git' "$MIRRORS" 2>/dev/null; then
    echo "cli.sh: pointing SwiftPM at the sibling AII checkout" >&2
    swift package --package-path "$REPO_ROOT" config set-mirror \
        --original https://github.com/rao-studios/AII.git --mirror "$(cd "$AII_DIR" && pwd)" >&2
fi

# SwiftPM's build system decides where products land (.build/out/Products/<Config> today): ask it.
bin_dir="$(swift build --package-path "$REPO_ROOT" -c "$config" --show-bin-path 2>/dev/null)"
binary="$bin_dir/braid"

watched=()
for path in "$REPO_ROOT/Sources" "$REPO_ROOT/Package.swift" "$REPO_ROOT/Package.resolved" \
    "$AII_DIR/Sources" "$AII_DIR/Package.swift"; do
    [ -e "$path" ] && watched+=("$path")
done

needs_build() {
    [ "${BRAID_BUILD:-}" = "always" ] && return 0
    [ -x "$binary" ] || return 0
    [ -n "$(find "${watched[@]}" -newer "$binary" -type f -print -quit 2>/dev/null)" ]
}

if [ -z "${BRAID_SKIP_BUILD:-}" ] && needs_build; then
    echo "cli.sh: building braid ($config)" >&2
    if ! swift build --package-path "$REPO_ROOT" -c "$config" --product braid -q >&2; then
        echo "cli.sh: swift build -c $config failed" >&2
        exit 1
    fi
    bin_dir="$(swift build --package-path "$REPO_ROOT" -c "$config" --show-bin-path)"
    binary="$bin_dir/braid"
    touch "$binary"
fi
if [ ! -x "$binary" ]; then
    echo "cli.sh: no braid binary in $bin_dir" >&2
    echo "  build it first, or unset BRAID_SKIP_BUILD" >&2
    exit 1
fi

if [ ! -f "$bin_dir/mlx.metallib" ] || [ "${BRAID_METALLIB:-}" = "rebuild" ]; then
    echo "cli.sh: installing mlx.metallib beside the $config binary" >&2
    "$REPO_ROOT/build-metallib.sh" "$config" > /dev/null
fi

exec "$binary" "$@"
