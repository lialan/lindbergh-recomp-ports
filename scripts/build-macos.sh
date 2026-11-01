#!/usr/bin/env bash
# build-macos.sh - lift your own copy of a game and build it for macOS.
#
#   ./scripts/build-macos.sh [--opengl] <game> /path/to/the/game
#
# Builds the native Vulkan renderer by default (into build-mac-vulkan/);
# --opengl builds the OpenGL renderer instead (into build-mac/).
#
# <game> is a folder name under games/ (ghostsquadevolution, hotd4); its
# game.conf says what the game's folder holds. Nothing from it is copied into
# this repo; the lifted C goes to the gitignored games/<game>/generated/.
#
# Safe to run again: unchanged lifted files keep their timestamps, so a
# rebuild only recompiles what moved.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLKIT="$ROOT/lindberghrecomp"
RENDERER=VULKAN
[ "${1:-}" = --opengl ] && { RENDERER=OPENGL; shift; }
ID="${1:-}"
[ -n "$ID" ] && [ -f "$ROOT/games/$ID/game.conf" ] || {
    printf 'usage: %s <game> /path/to/the/game\ngames: %s\n' "$0" "$(ls "$ROOT/games" | tr '\n' ' ')" >&2; exit 1; }
. "$ROOT/games/$ID/game.conf"
GEN="$ROOT/games/$ID/generated"
if [ "$RENDERER" = VULKAN ]; then BUILD="$ROOT/build-mac-vulkan"; else BUILD="$ROOT/build-mac"; fi
VENV="$ROOT/.venv"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

[ "$(uname -s)" = Darwin ] || die "this script is for macOS; see the README for Windows"
[ $# -ge 2 ] || die "usage: $0 $ID \"$FOLDER_HINT\""

# ---- the game folder ----
GAME="$(find_game "$2")"
[ -n "$GAME" ] || die "no $ELF in $2 (expected $TITLE's folder, $FOLDER_HINT)"
for f in $ELF ${SOLIBS:-}; do
    [ -f "$GAME/$f" ] || die "$GAME/$f is missing"
done
say "$TITLE: $GAME"

# ---- tools ----
missing=()
for t in cmake ninja; do command -v "$t" >/dev/null || missing+=("$t"); done
PY="$(command -v python3.11 || command -v python3 || true)"
[ -n "$PY" ] || missing+=("python@3.11")
PREFIX="$(brew --prefix 2>/dev/null || true)"
# sdl2, or sdl2-compat (what newer Homebrew installs for "sdl2"): either leaves
# a CMake package or sdl2-config behind
[ -d "${PREFIX:-/opt/homebrew}/lib/cmake/SDL2" ] || command -v sdl2-config >/dev/null || missing+=("sdl2")
if [ "$RENDERER" = VULKAN ]; then
    [ -e "${PREFIX:-/opt/homebrew}/lib/libvulkan.dylib" ] || missing+=("vulkan-loader")
    [ -d "${PREFIX:-/opt/homebrew}/include/vulkan" ] || missing+=("vulkan-headers")
    for t in glslangValidator:glslang spirv-cross:spirv-cross spirv-opt:spirv-tools; do
        command -v "${t%%:*}" >/dev/null || missing+=("${t#*:}")
    done
fi
[ ${#missing[@]} -eq 0 ] || die "missing: ${missing[*]}  ->  brew install ${missing[*]}"
xcrun --show-sdk-path >/dev/null 2>&1 || die "no macOS SDK  ->  xcode-select --install"
"$PY" -c 'import sys; sys.exit(sys.version_info < (3, 10))' || die "$PY is too old; need Python 3.10+"

if [ ! -d "$TOOLKIT/pcrecomp/tools" ]; then
    say "fetching submodules"
    git -C "$ROOT" submodule update --init --recursive
fi

if [ ! -x "$VENV/bin/python" ]; then
    say "creating $VENV"
    "$PY" -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install -q --disable-pip-version-check capstone pyelftools
VPY="$VENV/bin/python"

# ---- lift ----
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/$ID-lift.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
GLH="$(xcrun --show-sdk-path)/System/Library/Frameworks/OpenGL.framework/Headers"

BOUNDS_ARG=()
if [ -n "${STRIPPED:-}" ]; then
    # A stripped executable lists no functions; find them (minutes, so the
    # result is kept, keyed by the executable's hash).
    BOUNDS="$GEN/bounds.txt"
    SUM="$(shasum -a 256 "$GAME/$ELF" | cut -d' ' -f1)"
    if [ ! -f "$BOUNDS" ] || [ "$(cat "$GEN/bounds.sha256" 2>/dev/null)" != "$SUM" ]; then
        say "finding its functions (a few minutes)"
        mkdir -p "$GEN"
        ( cd "$TOOLKIT" && "$VPY" -m tools bounds "$GAME/$ELF" "$BOUNDS" --names "$ROOT/games/$ID/names.txt" )
        echo "$SUM" > "$GEN/bounds.sha256"
    fi
    cp "$BOUNDS" "$GEN/bounds.sha256" "$STAGE/"
    BOUNDS_ARG=(--bounds "$BOUNDS")
fi
say "lifting the game"
( cd "$TOOLKIT" && "$VPY" -m tools recomp "$GAME/$ELF" "$STAGE" ${BOUNDS_ARG[@]+"${BOUNDS_ARG[@]}"} )
if [ -n "${SOLIBS:-}" ]; then
    say "lifting the libraries it loads"
    # The order (game.conf) fixes where each library lands in guest memory.
    libs=(); for f in $SOLIBS; do libs+=("$GAME/$f"); done
    ( cd "$TOOLKIT" && "$VPY" -m tools.recomp.solib "$STAGE" --main-elf "$GAME/$ELF" "${libs[@]}" )
fi
say "generating GL thunks"
"$VPY" "$TOOLKIT/tools/gen_gl_thunks.py" "$STAGE/recomp_imports.h" "$GLH/gl.h" "$GLH/glext.h" > "$STAGE/recomp_gl_thunks.c"

# copy only what changed, so unchanged files keep their timestamps
mkdir -p "$GEN"
for f in "$STAGE"/*; do
    cmp -s "$f" "$GEN/${f##*/}" || cp "$f" "$GEN/"
done
for f in "$GEN"/*; do
    case "${f##*/}" in *_android.c|*.elf.sha256) continue ;; esac  # the Quest build's, made separately
    [ -e "$STAGE/${f##*/}" ] || rm -f "$f"
done

# ---- build ----
say "building"
say "building ($RENDERER renderer; --opengl for OpenGL)"
cmake -S "$ROOT" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DLINDBERGH_RENDERER="$RENDERER" \
      ${PREFIX:+-DCMAKE_PREFIX_PATH="$PREFIX"} >/dev/null
cmake --build "$BUILD" --target "$ID"

[ -x "$BUILD/$ID" ] || die "build finished without $BUILD/$ID"
say "built $BUILD/$ID"
printf '\nRun it with:\n  %s/scripts/run-macos.sh %s%s "%s"\n' "$ROOT" "$([ "$RENDERER" = OPENGL ] && echo '--opengl ')" "$ID" "$GAME"
