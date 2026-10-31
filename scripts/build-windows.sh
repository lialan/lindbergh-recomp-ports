#!/usr/bin/env bash
# HOTD4 PC VR: MSYS2 MINGW64, or a MinGW-w64 cross compiler on macOS/Linux.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ $# -ge 1 ] || die "usage: $0 /path/to/House-of-the-Dead-4 [--reuse-generated]"
. "$ROOT/games/hotd4/game.conf"
GAME="$(find_game "$1" || true)"
[ -n "$GAME" ] || die "missing elf/hod4M.elf in $1"
GEN="$ROOT/games/hotd4/generated"
BUILD="$ROOT/build-win64"
PY="${PYTHON:-python3}"
CC="${CC:-x86_64-w64-mingw32-gcc}"
export CC
case "$(uname -s)" in
    MINGW*|MSYS*)
        DEPS="${WIN64_DEPS:-$(cygpath -m /mingw64)}"
        TOOLCHAIN=()
        ;;
    *)
        [ -n "${WIN64_DEPS:-}" ] || die "set WIN64_DEPS to the Windows mingw64 dependency prefix"
        DEPS="$WIN64_DEPS"
        TOOLCHAIN=(-DCMAKE_TOOLCHAIN_FILE="$ROOT/cmake/toolchains/mingw64.cmake" -DWIN64_DEPS="$DEPS")
        ;;
esac
[ -f "$DEPS/include/GL/glew.h" ] || die "missing GLEW in $DEPS"
command -v "$CC" >/dev/null || die "missing $CC"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
SUM="$("$PY" -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$GAME/$ELF")"
if [ "${2:-}" = --reuse-generated ]; then
    [ -f "$GEN/recomp_imports.h" ] && [ "$(cat "$GEN/$SHA_FILE")" = "$SUM" ] || die "generated code missing or ELF hash mismatch; rebuild without --reuse-generated"
else
    "$PY" -c 'import capstone, elftools' || die "install Python capstone and pyelftools"
    (cd "$ROOT/lindberghrecomp" && "$PY" -m tools recomp "$GAME/$ELF" "$STAGE")
    mkdir -p "$GEN"
    # Replace this platform's lift; preserve other platforms' GL thunks.
    for f in "$GEN"/recomp_funcs_*.c; do
        [ -e "$STAGE/${f##*/}" ] || rm -f "$f"
    done
    for f in "$STAGE"/*; do
        cmp -s "$f" "$GEN/${f##*/}" || cp "$f" "$GEN/"
    done
    printf '%s\n' "$SUM" > "$GEN/$SHA_FILE"
fi
"$PY" "$ROOT/lindberghrecomp/tools/gen_gl_thunks.py" "$GEN/recomp_imports.h" \
    "$DEPS/include/GL/glew.h" > "$STAGE/recomp_gl_thunks_windows.c"
cmp -s "$STAGE/recomp_gl_thunks_windows.c" "$GEN/recomp_gl_thunks_windows.c" || cp "$STAGE/recomp_gl_thunks_windows.c" "$GEN/"
cmake -S "$ROOT" -B "$BUILD" -G Ninja "${TOOLCHAIN[@]}" \
    -DCMAKE_C_COMPILER="$CC" -DCMAKE_PREFIX_PATH="$DEPS" \
    -DCMAKE_BUILD_TYPE=Release -DLINDBERGH_GAMES=hotd4 -DLINDBERGH_OPENXR=ON
cmake --build "$BUILD" --target hotd4 lindbergh_rt_selftest --parallel "${JOBS:-8}"
"$PY" "$ROOT/scripts/package-windows.py" "$BUILD" "$DEPS" "$GEN/$SHA_FILE"
