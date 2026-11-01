#!/bin/sh
# Build a game's native Steam Frame package: an AArch64 Linux executable on
# native Vulkan and OpenXR, built inside Valve's Steam Linux Runtime 4 SDK
# (the runtime native Frame titles target), plus its shader archives and a
# launcher. No game data goes in it.
#
#   scripts/build-steam-frame.sh <game> --shader-pack <game.lvsp> \
#       [--pipeline-recipes <pipelines.lvpr>] [--gl-headers-root <dir with GL/gl.h, GL/glext.h>]
#
#   -> build-frame/<game>/dist/<APK name>-steamframe-arm64.tar.gz
#
# Needs Docker (OrbStack/Docker Desktop on an Apple-silicon Mac runs the
# arm64 SDK natively) and the lifted game in games/<game>/generated. The
# shader pack is the same offline archive the Quest Vulkan build bundles
# (quest/build_vulkan.py --shader-pack); see docs/hotd4/STEAM-FRAME.md.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMAGE=${STEAMRT_IMAGE:-registry.gitlab.steamos.cloud/steamrt/steamrt4/sdk/arm64:latest}
die() { echo "error: $*" >&2; exit 1; }

ID=${1:-}
[ -n "$ID" ] && [ -f "$ROOT/games/$ID/game.conf" ] || die "usage: $0 <game> --shader-pack <game.lvsp> [--pipeline-recipes <file>] [--gl-headers-root <dir>]"
shift
PACK= RECIPES= GLH=
while [ $# -gt 0 ]; do
    case $1 in
        --shader-pack) PACK=$2; shift 2 ;;
        --pipeline-recipes) RECIPES=$2; shift 2 ;;
        --gl-headers-root) GLH=$2; shift 2 ;;
        *) die "unknown argument $1" ;;
    esac
done
[ -n "$PACK" ] && [ -f "$PACK" ] || die "--shader-pack <game.lvsp> is required (the game's offline Vulkan shader archive)"
[ -z "$RECIPES" ] || [ -f "$RECIPES" ] || die "no such pipeline recipes file: $RECIPES"
[ -f "$ROOT/games/$ID/generated/recomp_imports.h" ] || die "no lifted code in games/$ID/generated (scripts/build-macos.sh $ID <game folder> makes it)"
# The guest GL ABI headers: declarations only, never linked. Default: the
# Mesa headers quest/build_vulkan.py is given, else the SDK's own.
if [ -z "$GLH" ] && [ -f "$ROOT/../deps/mesa-26.2.6/include/GL/glext.h" ]; then GLH=$ROOT/../deps/mesa-26.2.6/include; fi
if [ -n "$GLH" ] && { [ ! -f "$GLH/GL/gl.h" ] || [ ! -f "$GLH/GL/glext.h" ]; }; then
    die "--gl-headers-root needs GL/gl.h and GL/glext.h"
fi
command -v docker >/dev/null || die "Docker is required"

. "$ROOT/games/$ID/game.conf"
OUT=$ROOT/build-frame/$ID
mkdir -p "$OUT/inputs"
cp "$PACK" "$OUT/inputs/game.lvsp"
rm -f "$OUT/inputs/pipelines.lvpr"
[ -z "$RECIPES" ] || cp "$RECIPES" "$OUT/inputs/pipelines.lvpr"
# The fixed-function shader archive, built here when this machine has the
# shader tools: the same glslang/spirv-cross the Quest packs are made with
# (the runtime SDK's 2021 spirv-cross gives a different, untested archive).
rm -f "$OUT/inputs/fixed.lvsp"
if command -v glslangValidator >/dev/null && command -v spirv-cross >/dev/null && command -v python3 >/dev/null; then
    python3 "$ROOT/lindberghrecomp/tools/vulkan/build_fixed.py" "$OUT/fixed-pack" \
        "$(command -v glslangValidator)" "$(command -v spirv-cross)" >/dev/null
    cp "$OUT/fixed-pack/fixed.lvsp" "$OUT/inputs/fixed.lvsp"
fi
GLMOUNT=
if [ -n "$GLH" ]; then
    rm -rf "$OUT/inputs/GL"; mkdir -p "$OUT/inputs/GL"
    cp "$GLH/GL/gl.h" "$GLH/GL/glext.h" "$OUT/inputs/GL/"
    GLMOUNT=/src/build-frame/$ID/inputs
fi

# The worktree's own path is mounted at /src; the build writes only below
# build-frame/<game>.
docker run --rm --platform linux/arm64 \
    -v "$ROOT:/src" -w /src \
    -e GAME="$ID" -e TITLE="$TITLE" -e APK="$APK" -e ELF="$ELF" -e GLROOT="$GLMOUNT" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    "$IMAGE" sh /src/scripts/steam-frame/build-in-runtime.sh
ls -la "$OUT/dist/"
