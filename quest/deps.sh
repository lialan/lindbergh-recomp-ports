#!/bin/sh
# Fetch and build the Quest build's dependencies for arm64 Android, into
# $DEPS (default: the folder next to this repository, ../deps):
#
#   SDL2-2.32.10/     SDL source (its Java side goes into the APK)
#   sdl2-android/     SDL 2.32.10, built
#   gl4es/            gl4es at a fixed commit with quest/gl4es.patch applied;
#                     lib/libGL.a is the build
#   openal-soft/      OpenAL Soft 1.24.3 source; openal-android/ its build
#   oxr/              the Khronos OpenXR loader for Android 1.1.49 (an .aar,
#                     unpacked)
#
#   quest/deps.sh
#
# Steps whose output already exists are skipped; delete a folder to redo it.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SDK=${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}
NDK=${ANDROID_NDK:-$SDK/ndk/27.3.13750724}
DEPS=${DEPS:-$ROOT/../deps}
TC="-DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-29 -DCMAKE_BUILD_TYPE=Release"
JOBS=$(getconf _NPROCESSORS_ONLN)
GL4ES_COMMIT=1891af323d4547487296e50ba5932bde65c7b345
mkdir -p "$DEPS"
cd "$DEPS"

if [ ! -f sdl2-android/lib/libSDL2.so ]; then
    [ -d SDL2-2.32.10 ] || curl -fsSL https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz | tar xz
    cmake -S SDL2-2.32.10 -B sdl2-build -G Ninja $TC -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST=OFF \
        -DCMAKE_INSTALL_PREFIX="$DEPS/sdl2-android" >/dev/null
    cmake --build sdl2-build -j"$JOBS" && cmake --install sdl2-build >/dev/null
fi

if [ ! -f gl4es/lib/libGL.a ]; then
    [ -d gl4es ] || git clone -q https://github.com/ptitSeb/gl4es.git
    git -C gl4es checkout -q "$GL4ES_COMMIT"
    # the fixes the games need (multiview, texture targets, shader conversion): docs/QUEST.md
    git -C gl4es apply --check "$ROOT/quest/gl4es.patch" 2>/dev/null && git -C gl4es apply "$ROOT/quest/gl4es.patch"
    cmake -S gl4es -B gl4es-android -G Ninja $TC -DANDROID=ON -DNOX11=ON -DNOEGL=ON -DSTATICLIB=ON \
        -DNO_INIT_CONSTRUCTOR=ON -DUSE_ANDROID_LOG=ON -DDEFAULT_ES=2 \
        -DCMAKE_C_FLAGS_RELEASE="-O3 -DNDEBUG -fno-stack-protector -U_FORTIFY_SOURCE" >/dev/null   # as the runtime's release build
    cmake --build gl4es-android -j"$JOBS"
fi

if [ ! -f openal-android/libopenal.so ]; then
    [ -d openal-soft ] || git clone -q --depth 1 --branch 1.24.3 https://github.com/kcat/openal-soft.git
    cmake -S openal-soft -B openal-android -G Ninja $TC -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF \
        -DALSOFT_TESTS=OFF -DALSOFT_INSTALL=OFF -DALSOFT_BACKEND_OBOE=OFF -DALSOFT_REQUIRE_OPENSL=ON >/dev/null
    cmake --build openal-android -j"$JOBS"
fi

if [ ! -f oxr/jni/arm64-v8a/libopenxr_loader.so ]; then
    curl -fsSLo openxr_loader_for_android-1.1.49.aar \
        https://repo1.maven.org/maven2/org/khronos/openxr/openxr_loader_for_android/1.1.49/openxr_loader_for_android-1.1.49.aar
    mkdir -p oxr && (cd oxr && unzip -qo ../openxr_loader_for_android-1.1.49.aar)
fi
echo "dependencies ready in $DEPS"
