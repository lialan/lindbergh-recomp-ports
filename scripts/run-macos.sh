#!/usr/bin/env bash
# run-macos.sh - start a game from inside its own folder, as the cabinet does.
#
#   ./scripts/run-macos.sh [--opengl] <game> /path/to/the/game
#
# Runs the Vulkan build (build-mac-vulkan/) by default, --opengl the OpenGL
# one (build-mac/). Vulkan needs the game's offline shader archive:
# LINDBERGH_VULKAN_SHADERS=/path/to/game.lvsp, else build-vulkan-shaders-<game>/<game>.lvsp.
#
# Starts muted; M toggles sound, or LINDBERGH_MUTE=0 starts with it on.
# Any other LINDBERGH_* switch in the environment is passed through, and
# arguments after the folder go to the game.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

OPENGL=
[ "${1:-}" = --opengl ] && { OPENGL=1; shift; }
ID="${1:-}"
[ -n "$ID" ] && [ -f "$ROOT/games/$ID/game.conf" ] || die "usage: $0 <game> /path/to/the/game (games: $(ls "$ROOT/games" | tr '\n' ' '))"
. "$ROOT/games/$ID/game.conf"
if [ -n "$OPENGL" ]; then BUILD="$ROOT/build-mac"; FLAG="--opengl "; else BUILD="$ROOT/build-mac-vulkan"; FLAG=; fi
BIN="$BUILD/$ID"
[ $# -ge 2 ] || die "usage: $0 [--opengl] $ID \"$FOLDER_HINT\""
[ -x "$BIN" ] || die "not built yet  ->  $ROOT/scripts/build-macos.sh $FLAG$ID \"$2\""
if [ -z "$OPENGL" ]; then
    if [ -z "${LINDBERGH_VULKAN_SHADERS:-}" ]; then
        PACK="$ROOT/build-vulkan-shaders-$ID/$ID.lvsp"
        [ -f "$PACK" ] || die "no Vulkan shader archive for $ID: set LINDBERGH_VULKAN_SHADERS=/path/to/$ID.lvsp (or run with --opengl)"
        export LINDBERGH_VULKAN_SHADERS="$PACK"
    fi
    # Mesa KosmicKrisp (Vulkan on Metal) when installed and no driver was chosen
    KK=/opt/homebrew/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json
    [ -n "${VK_ICD_FILENAMES:-}${VK_DRIVER_FILES:-}" ] || [ ! -f "$KK" ] || export VK_ICD_FILENAMES="$KK"
fi

GAME="$(find_game "$2")"
[ -n "$GAME" ] || die "no $ELF in $2 (expected $TITLE's folder, $FOLDER_HINT)"

cd "$GAME/$(dirname "$ELF")"
# macOS names a program without an app bundle after its file, in the menu
# bar and the Dock: start it through a link with the game's name
LINK="$BUILD/$TITLE"
[ "$(readlink "$LINK" 2>/dev/null)" = "$ID" ] || ln -sfn "$ID" "$LINK"
exec "$LINK" "$(basename "$ELF")" "${@:3}"
