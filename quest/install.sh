#!/bin/sh
# Install a game's APK on a headset over adb and copy the game to it.
#
#   quest/install.sh <game> "/path/to/the game's folder"
#
# <game> is a folder name under games/; its game.conf says where on the
# headset the game goes. The folder is the one the desktop build runs from.
# The game is copied once; run again with only <game> to update the APK.
set -e
Q=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$Q")
ID=$1
[ -n "$ID" ] && [ -f "$ROOT/games/$ID/game.conf" ] || { echo "usage: $0 <game> [game folder]; games: $(ls "$ROOT/games")"; exit 1; }
. "$ROOT/games/$ID/game.conf"
[ -f "$Q/$ID/build.gradle" ] || { echo "$TITLE has no Quest port yet" >&2; exit 1; }
adb install -r "$Q/$APK.apk"
# the game is read from shared storage
adb shell appops set --uid "$PKG" MANAGE_EXTERNAL_STORAGE allow
if [ -n "$2" ]; then
    GAME=$(find_game "$2")
    [ -n "$GAME" ] || { echo "$2 has no $ELF - give the game's folder ($FOLDER_HINT)"; exit 1; }
    if type check_game >/dev/null 2>&1 && ! check_game "$GAME" && [ "${LINDBERGH_ALLOW_DAMAGED_GAME:-}" != 1 ]; then
        echo "install stopped: fix the game files above (or LINDBERGH_ALLOW_DAMAGED_GAME=1 to copy it anyway)" >&2; exit 1
    fi
    DEST=$HEADSET_DIR${HEADSET_SUB:+/$HEADSET_SUB}
    echo "copying the game to $DEST ($SIZE)"
    adb shell mkdir -p "$DEST"
    for part in $GAME_PARTS; do
        if [ "$part" = . ]; then    # the contents, so the folder on the headset has its name whatever it is called here
            (cd "$GAME" && for f in * .[!.]*; do [ -e "$f" ] && adb push "$f" "$DEST/"; done)
        else
            adb push "$GAME/$part" "$DEST/"
        fi
    done
fi
echo "Installed. Start \"$APP\" from Unknown Sources."
echo "Log of the last run: adb shell cat $HEADSET_DIR/$LOG"
