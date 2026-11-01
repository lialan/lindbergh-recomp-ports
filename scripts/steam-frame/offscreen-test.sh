#!/bin/sh
# Inside the Steam Linux Runtime 4 arm64 SDK: build a game's offscreen Vulkan
# diagnostic (the same lifted game and Vulkan renderer as the Frame build,
# without OpenXR) and render it on Mesa lavapipe, capturing the last frame.
# It proves the AArch64 Linux game and renderer, not the headset.
#
#   docker run --rm --platform linux/arm64 -v "$PWD:/src" -v "<game folder>:/game:ro" \
#       -e GAME=hotd4 -e FRAMES=900 <steamrt4 sdk arm64 image> sh /src/scripts/steam-frame/offscreen-test.sh
#
# Writes build-frame/<game>/offscreen-run/ (capture.ppm, frames.csv, log.txt).
set -eu
GAME=${GAME:?}
FRAMES=${FRAMES:-900}
B=/src/build-frame/$GAME
apt-get -qq update >/dev/null 2>&1 || true
apt-get -qq install -y spirv-cross mesa-vulkan-drivers >/dev/null
GLARG=
[ ! -f "$B/inputs/GL/glext.h" ] || GLARG="-DLINDBERGH_GL_HEADERS=$B/inputs/GL/gl.h;$B/inputs/GL/glext.h"
cmake -S /src -B "$B/offscreen" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DLINDBERGH_GAMES="$GAME" -DLINDBERGH_RENDERER=VULKAN -DLINDBERGH_OPENXR=OFF \
    -DLINDBERGH_VULKAN_OFFSCREEN=ON -DBUILD_TESTING=OFF $GLARG >/dev/null
cmake --build "$B/offscreen" --target "$GAME" --parallel "$(nproc)" >/dev/null
R=$B/offscreen-run
rm -rf "$R"; mkdir -p "$R"
FIXED=$B/inputs/fixed.lvsp; [ -f "$FIXED" ] || FIXED=$B/offscreen/lindberghrecomp/src/renderer/vulkan/fixed-pack/fixed.lvsp
export VK_DRIVER_FILES=$(ls /usr/share/vulkan/icd.d/lvp_icd*.json | head -1) LINDBERGH_VULKAN_ALLOW_SOFTWARE=1
export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy LINDBERGH_MUTE=1 LINDBERGH_GL_THREAD=1 \
    LINDBERGH_HIDDEN=1 LINDBERGH_WINDOW=640x480 LINDBERGH_EXIT_AFTER=$FRAMES LINDBERGH_AUTOSTART=8 \
    LINDBERGH_SHOT_FROM_GUN=1 LINDBERGH_VULKAN_FAKE_YAW=0 LINDBERGH_VULKAN_FAKE_GUN=1 \
    LINDBERGH_XR_SET="width=1024,resolution=1024,dual=off,scale=1,screen=3,aim=15,hand=right,laser=laser,sight=none,crosshair=on,gun=on,hud_pitch=0,coins=auto,fps=off" \
    LINDBERGH_VULKAN_CACHE=$R/pipeline-cache.bin LINDBERGH_NVRAM=$R/nvram.bin \
    LINDBERGH_VULKAN_SHADERS=$B/inputs/game.lvsp LINDBERGH_VULKAN_FIXED_SHADERS=$FIXED \
    LINDBERGH_SHOT=$R/capture.ppm LINDBERGH_SHOT_FRAME=$((FRAMES - 1)) \
    LINDBERGH_FRAME_TIMINGS=$R/frames.csv LINDBERGH_TIMING_FROM=60 LINDBERGH_TIMING_TO=$((FRAMES - 2))
[ ! -f "$B/inputs/pipelines.lvpr" ] || export LINDBERGH_VULKAN_RECIPES_SEED=$B/inputs/pipelines.lvpr
# CACHE_SEED=<driver cache>: start from it, as a packaged vulkan/pipelines.bin does
[ -z "${CACHE_SEED:-}" ] || export LINDBERGH_VULKAN_CACHE_SEED=$CACHE_SEED
ulimit -s 262144 2>/dev/null || ulimit -s unlimited 2>/dev/null || true
. /src/games/$GAME/game.conf
cd "/game/$(dirname "$ELF")"
set +e
timeout 1200 "$B/offscreen/$GAME" "$(basename "$ELF")" > "$R/log.txt" 2>&1
echo "exit $?" >> "$R/log.txt"
chown -R "${HOST_UID:-0}:${HOST_GID:-0}" "$B" 2>/dev/null || true
tail -5 "$R/log.txt"
