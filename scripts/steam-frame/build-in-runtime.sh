#!/bin/sh
# Runs inside the Steam Linux Runtime 4 arm64 SDK (scripts/build-steam-frame.sh
# starts it): configures, builds and packages one game for Steam Frame.
set -eu
B=/src/build-frame/$GAME
apt-get -qq update >/dev/null 2>&1 || true
command -v spirv-cross >/dev/null || apt-get -qq install -y spirv-cross >/dev/null
GLARG=
[ -z "${GLROOT:-}" ] || GLARG="-DLINDBERGH_GL_HEADERS=$GLROOT/GL/gl.h;$GLROOT/GL/glext.h"
cmake -S /src -B "$B/cmake" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DLINDBERGH_GAMES="$GAME" -DLINDBERGH_RENDERER=VULKAN -DLINDBERGH_OPENXR=ON \
    -DBUILD_TESTING=OFF $GLARG
cmake --build "$B/cmake" --target "$GAME" --parallel "$(nproc)" -- -k 0

# The package: the program, its shader archives, the libraries the Frame
# may not carry, and the launcher.
NAME=$APK-steamframe-arm64
P=$B/dist/$NAME
rm -rf "$B/dist"; mkdir -p "$P/vulkan" "$P/lib"
strip --strip-unneeded -o "$P/$GAME" "$B/cmake/$GAME"
cp "$B/inputs/game.lvsp" "$P/vulkan/game.lvsp"
if [ -f "$B/inputs/fixed.lvsp" ]; then cp "$B/inputs/fixed.lvsp" "$P/vulkan/fixed.lvsp"
else cp "$B/cmake/lindberghrecomp/src/renderer/vulkan/fixed-pack/fixed.lvsp" "$P/vulkan/fixed.lvsp"; fi
[ ! -f "$B/inputs/pipelines.lvpr" ] || cp "$B/inputs/pipelines.lvpr" "$P/vulkan/pipelines.lvpr"
# the driver pipeline cache harvested on a Frame: used where the GPU and driver match
[ ! -f "$B/inputs/pipelines.bin" ] || cp "$B/inputs/pipelines.bin" "$P/vulkan/pipelines.bin"
# SDL2, OpenAL Soft and the OpenXR loader from the runtime: used when the
# game is started outside the Steam Linux Runtime container. The Vulkan
# loader and driver always come from the system.
for l in libSDL2-2.0.so.0 libopenal.so.1 libopenxr_loader.so.1 libjsoncpp.so.26; do
    f=$(ldd "$P/$GAME" | awk -v l="$l" '$1==l{print $3}')
    [ -n "$f" ] && cp -L "$f" "$P/lib/$l"
done
# the runtime's SDL2 is sdl2-compat: it loads SDL3 at run time
f=$(ldconfig -p | awk '$1=="libSDL3.so.0"{print $NF; exit}')
[ -n "$f" ] && cp -L "$f" "$P/lib/libSDL3.so.0"
sed -e "s|@GAME@|$GAME|g" -e "s|@TITLE@|$TITLE|g" -e "s|@ELF@|$ELF|g" \
    /src/scripts/steam-frame/launch.sh.in > "$P/launch.sh"
chmod +x "$P/launch.sh"
cp /src/scripts/steam-frame/README.txt "$P/README.txt"
(cd "$P" && sha256sum "$GAME" vulkan/* lib/* > SHA256SUMS)
echo "built from $(cd /src && cat games/$GAME/generated/*.elf.sha256 2>/dev/null | head -1) (executable SHA-256)" >> "$P/SHA256SUMS"
file "$P/$GAME" || true
ldd "$P/$GAME" | sed 's/^/  /'
tar -C "$B/dist" -czf "$B/dist/$NAME.tar.gz" "$NAME"
chown -R "$HOST_UID:$HOST_GID" "$B" 2>/dev/null || true
