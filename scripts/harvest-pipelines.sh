#!/bin/sh
# Pull a game's Vulkan pipelines off a headset after a play session, so the
# next build ships them and a fresh install compiles nothing before play.
#
#   scripts/harvest-pipelines.sh <game> quest           # Quest 3 over adb (the Vulkan APK)
#   scripts/harvest-pipelines.sh <game> frame [host]    # Steam Frame over ssh (default steamos@frame.local)
#
# Writes $LINDBERGH_SEEDS/<game>/ (default build-seeds/<game>/):
#   pipelines.lvpr          the portable recipe catalogue: every pipeline the
#                           game has drawn with, on any GPU (the headset's
#                           catalogue already holds the seed it shipped with)
#   <quest|frame>/pipelines.bin
#                           that headset's driver cache, compiled from it;
#                           ignored by the runtime on another GPU or driver
# build-steam-frame.sh and quest/build_vulkan.py pick both up. Play the game
# through what should be covered (attract, every stage, menus) before
# harvesting; the previous files are kept as *.prev.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "error: $*" >&2; exit 1; }
ID=${1:-}; DEV=${2:-}
[ -n "$ID" ] && [ -f "$ROOT/games/$ID/game.conf" ] && { [ "$DEV" = quest ] || [ "$DEV" = frame ]; } ||
    die "usage: $0 <game> quest|frame [ssh host]"
. "$ROOT/games/$ID/game.conf"
OUT=${LINDBERGH_SEEDS:-$ROOT/build-seeds}/$ID
mkdir -p "$OUT/$DEV"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/harvest.XXXXXX"); trap 'rm -rf "$TMP"' EXIT

if [ "$DEV" = frame ]; then
    HOST=${3:-steamos@frame.local}
    # SDL_GetPrefPath("lindberghrecomp", <the game profile's title>): game.conf's
    # TITLE, or that with a suffix (Ghost Squad Evolution's profile adds " VR")
    DIR=$(ssh -o BatchMode=yes "$HOST" "cd ~/.local/share/lindberghrecomp 2>/dev/null && for d in \"$TITLE\" \"$TITLE\"*; do [ -f \"\$d/vulkan-pipelines.bin\" ] && { echo \".local/share/lindberghrecomp/\$d\"; break; }; done")
    [ -n "$DIR" ] ||
        die "no pipeline cache for \"$TITLE\" on $HOST (run the game there first); have: $(ssh -o BatchMode=yes "$HOST" 'ls ~/.local/share/lindberghrecomp' | tr '\n' ',')"
    scp -q "$HOST:\"$DIR/vulkan-pipelines.bin\"" "$TMP/pipelines.bin"
    scp -q "$HOST:\"$DIR/vulkan-pipelines.bin.recipes\"" "$TMP/pipelines.lvpr" 2>/dev/null || true
else
    APP=$PKG.vulkan
    adb shell pm path "$APP" >/dev/null 2>&1 || die "$APP is not installed on the Quest"
    # the Vulkan APK is a debug build, so its files are readable through run-as
    F=$(adb shell run-as "$APP" sh -c "'find files -name vulkan-pipelines.bin -o -name pipelines.bin'" | tr -d '\r' | grep -v '/vulkan/pipelines.bin$' | head -1)
    [ -n "$F" ] || die "no pipeline cache in $APP's files (run the game first)"
    adb exec-out run-as "$APP" cat "$F" > "$TMP/pipelines.bin"
    adb exec-out run-as "$APP" cat "$F.recipes" > "$TMP/pipelines.lvpr" 2>/dev/null || true
fi

[ -s "$TMP/pipelines.bin" ] || die "the pipeline cache came back empty"
for f in pipelines.lvpr "$DEV/pipelines.bin"; do [ ! -f "$OUT/$f" ] || mv "$OUT/$f" "$OUT/$f.prev"; done
cp "$TMP/pipelines.bin" "$OUT/$DEV/pipelines.bin"
if [ -s "$TMP/pipelines.lvpr" ]; then cp "$TMP/pipelines.lvpr" "$OUT/pipelines.lvpr"
elif [ -f "$OUT/pipelines.lvpr.prev" ]; then mv "$OUT/pipelines.lvpr.prev" "$OUT/pipelines.lvpr"; fi
ls -l "$OUT/pipelines.lvpr" "$OUT/$DEV/pipelines.bin" 2>/dev/null
echo "harvested $TITLE from the $DEV into $OUT"
