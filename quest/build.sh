#!/bin/sh
# Build a game's Meta Quest APK.
#
#   quest/build.sh <game>                        -> quest/<APK>.apk
#   quest/build.sh <game> --with-game <folder>   -> quest/<APK>-with-game.apk
#
# <game> is a folder name under games/ (ghostsquadevolution, hotd4); its
# game.conf names the APK. The first carries no game files (quest/install.sh
# copies them to the headset). The second has your game folder inside and
# unpacks it on its first start: one file to install. It holds the game's
# files - keep it to yourself.
#
# Needs the lifted game in games/<game>/generated (see the README), the
# Android SDK with NDK 27, a JDK 17+, and the dependencies built for arm64
# Android in $DEPS (quest/deps.sh) - see docs/<game>/QUEST.md.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
Q=$ROOT/quest
ID=$1
[ -n "$ID" ] && [ -f "$ROOT/games/$ID/game.conf" ] || { echo "usage: $0 <game> [--with-game <folder>]; games: $(ls "$ROOT/games")"; exit 1; }
shift
. "$ROOT/games/$ID/game.conf"
M=$Q/$ID                                # the game's Android module
[ -f "$M/build.gradle" ] || { echo "$TITLE has no Quest port yet" >&2; exit 1; }
SDK=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}
NDK=${ANDROID_NDK:-$SDK/ndk/27.3.13750724}
DEPS=${DEPS:-$ROOT/../deps}
SDL_SRC=${SDL_SRC:-$DEPS/SDL2-2.32.10}
[ -n "$JAVA_HOME" ] || [ ! -d /opt/homebrew/opt/openjdk@21 ] || export JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home
case "$(uname -s)" in Darwin) HOST=darwin-x86_64 ;; *) HOST=linux-x86_64 ;; esac
GAME=
if [ "$1" = --with-game ]; then
    GAME=$(find_game "$2")
    [ -n "$GAME" ] || { echo "--with-game needs the game's folder ($FOLDER_HINT, with $ELF in it)"; exit 1; }
fi
STRIP=$NDK/toolchains/llvm/prebuilt/$HOST/bin/llvm-strip

# one game per build: each is the app's libmain.so
B=$ROOT/build-quest/$ID
cmake -S "$ROOT" -B "$B" -G Ninja -DLINDBERGH_GAMES="$ID" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DCMAKE_BUILD_TYPE=Release \
    -DSDL2_DIR="$DEPS/sdl2-android/lib/cmake/SDL2" \
    -DGL4ES_DIR="$DEPS/gl4es" -DGL4ES_LIB="$DEPS/gl4es/lib/libGL.a" \
    -DOPENAL_DIR="$DEPS/openal-soft" -DOPENAL_LIB="$DEPS/openal-android/libopenal.so" \
    -DOPENXR_DIR="$DEPS/oxr/prefab/modules/headers" -DOPENXR_LIB="$DEPS/oxr/jni/arm64-v8a/libopenxr_loader.so" >/dev/null
cmake --build "$B" -j"$(getconf _NPROCESSORS_ONLN)"

LIBS=$M/src/main/libs/arm64-v8a
mkdir -p "$LIBS"
"$STRIP" --strip-unneeded -o "$LIBS/libmain.so" "$B/libmain.so"
"$STRIP" --strip-unneeded -o "$LIBS/libopenal.so" "$DEPS/openal-android/libopenal.so"
cp "$DEPS/sdl2-android/lib/libSDL2.so" "$DEPS/oxr/jni/arm64-v8a/libopenxr_loader.so" "$LIBS/"
rm -rf "$M/src/main/java/org/libsdl"
cp -R "$SDL_SRC/android-project/app/src/main/java/org/libsdl" "$M/src/main/java/org/"
echo "sdk.dir=$SDK" > "$Q/local.properties"

# the game, as assets - or none
ASSETS=$M/src/main/assets
rm -rf "$ASSETS"
OUT=$Q/$APK.apk
if [ -n "$GAME" ]; then
    A=$ASSETS/$ASSET_DIR
    mkdir -p "$A"
    # not this machine's saved cabinet state, key bindings or test output,
    # nor what Android's packager drops anyway (SourceSafe's vssver.scc and
    # the like), so the file list matches the APK
    for part in $GAME_PARTS; do
        if [ "$part" = . ]; then src="$GAME/"; else src="$GAME/$part"; fi
        rsync -a --exclude lindbergh_nvram.bin --exclude lindbergh.ini --exclude env.txt --exclude vr.cfg \
            --exclude '*.ppm' --exclude '*.pgm' --exclude '*.log' --exclude '.*' \
            --exclude '*.scc' --exclude '*~' --exclude thumbs.db --exclude picasa.ini --exclude CVS --exclude '_*/' \
            "$src" "$A/"
    done
    (cd "$A" && find . -type f | sed 's|^\./||' | sort) > "$ASSETS/$ASSET_DIR.files"
    (cd "$A" && find . -type f -exec ls -ln {} + | awk '{print $5, $9}' | sort) | shasum | cut -c1-16 > "$ASSETS/$ASSET_DIR.id"
    echo "bundling $(wc -l < "$ASSETS/$ASSET_DIR.files" | tr -d ' ') game files ($(du -sh "$A" | cut -f1))"
    OUT=$Q/$APK-with-game.apk
fi

cd "$Q"
# the executable the game's code came from (the app refuses any other), and
# the version: VERSION (a release tag like v0.2.0) or 0.1.0
SHA=$(cat "$ROOT/games/$ID/generated/$SHA_FILE" 2>/dev/null || true)
VER=${VERSION:-v0.1.0}; VER=${VER#v}
VCODE=$(echo "$VER" | awk -F. '{print $1*10000 + $2*100 + $3}')
./gradlew --no-daemon -q ":$ID:assembleRelease" -PelfSha256="$SHA" -PappVersionName="$VER" -PappVersionCode="$VCODE"
cp "$ID/build/outputs/apk/release/$ID-release.apk" "$OUT"
rm -rf "$ASSETS"
ls -la "$OUT"
