#!/usr/bin/env python3
"""Build an experimental native Vulkan/OpenXR APK, separate from OpenGL ports.

Requires lifted game sources and that game's offline .lvsp shader archive.
This does not install or operate a headset, or bundle copyrighted game files.
World stereo, controller/overlay parity and combat performance are still gates.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess


def run(*command, **kwargs):
    print('+', ' '.join(map(str, command)), flush=True)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('game', choices=['hotd4sp', 'hotd4', 'ghostsquadevolution', 'lgj'])
    parser.add_argument('--shader-pack', type=Path, required=True)
    parser.add_argument('--gl-headers-root', type=Path, required=True, help='declaration-only include root containing GL/gl.h and GL/glext.h')
    parser.add_argument('--deps', type=Path, default=root.parent/'deps')
    parser.add_argument('--sdk', type=Path, default=Path(os.environ.get('ANDROID_HOME', Path.home()/'Library/Android/sdk')))
    parser.add_argument('--ndk', type=Path)
    parser.add_argument('--build-dir', type=Path)
    parser.add_argument('--jobs', type=int, default=6)
    parser.add_argument('--no-apk', action='store_true')
    args = parser.parse_args()
    if args.jobs < 1: parser.error('--jobs must be positive')
    build = (args.build_dir or root/'build-quest-vulkan'/args.game).resolve()
    deps, sdk, headers = args.deps.resolve(), args.sdk.resolve(), args.gl_headers_root.resolve()
    ndk = (args.ndk or sdk/'ndk/27.3.13750724').resolve()
    pack = args.shader_pack.resolve()
    for path in [pack, headers/'GL/gl.h', headers/'GL/glext.h', ndk/'build/cmake/android.toolchain.cmake',
                 root/'games'/args.game/'generated/recomp_imports.h']:
        if not path.is_file(): parser.error('missing required input: '+str(path))
    run('cmake', '-S', root, '-B', build, '-G', 'Ninja',
        '-DCMAKE_TOOLCHAIN_FILE='+str(ndk/'build/cmake/android.toolchain.cmake'),
        '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-29', '-DCMAKE_BUILD_TYPE=Release',
        '-DLINDBERGH_GAMES='+args.game, '-DLINDBERGH_RENDERER=VULKAN', '-DLINDBERGH_OPENXR=ON',
        '-DBUILD_TESTING=OFF', '-DLINDBERGH_GL_HEADERS='+str(headers/'GL/gl.h')+';'+str(headers/'GL/glext.h'),
        '-DSDL2_DIR='+str(deps/'sdl2-android/lib/cmake/SDL2'),
        '-DOPENAL_DIR='+str(deps/'openal-soft'), '-DOPENAL_LIB='+str(deps/'openal-android/libopenal.so'),
        '-DOpenXR_DIR='+str(deps/'oxr'))
    run('cmake', '--build', build, '--target', args.game, '--parallel', args.jobs)
    if args.no_apk: return
    libs, assets = build/'apk-libs/arm64-v8a', build/'apk-assets/vulkan'
    libs.mkdir(parents=True, exist_ok=True)
    assets.mkdir(parents=True, exist_ok=True)
    run(ndk/'toolchains/llvm/prebuilt'/('darwin-x86_64' if os.uname().sysname == 'Darwin' else 'linux-x86_64')/'bin/llvm-strip',
        '--strip-unneeded', '-o', libs/'libmain.so', build/'libmain.so')
    for source in [deps/'sdl2-android/lib/libSDL2.so', deps/'openal-android/libopenal.so', deps/'oxr/jni/arm64-v8a/libopenxr_loader.so']:
        shutil.copy2(source, libs/source.name)
    shutil.copy2(pack, assets/'game.lvsp')
    shutil.copy2(build/'lindberghrecomp/src/renderer/vulkan/fixed-pack/fixed.lvsp', assets/'fixed.lvsp')
    env = os.environ.copy()
    env['ANDROID_HOME'] = str(sdk)
    java = Path('/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home')
    if 'JAVA_HOME' not in env and java.is_dir(): env['JAVA_HOME'] = str(java)
    config = (root/'games'/args.game/'game.conf').read_text().splitlines()
    sha_name = next(shlex.split(line, comments=True)[0].split('=',1)[1]
                    for line in config if line.startswith('SHA_FILE='))
    sha_file = root/'games'/args.game/'generated'/sha_name
    if not sha_file.is_file(): parser.error('missing lifted ELF hash: '+str(sha_file))
    run(root/'quest/gradlew', '-p', root/'quest', ':'+args.game+':assembleDebug', '--offline',
        '-PnativeRenderer=vulkan', '-PnativeLibsDir='+str(libs.parent), '-PnativeAssetsDir='+str(assets.parent),
        '-PsdlJavaDir='+str(deps/'SDL2-2.32.10/android-project/app/src/main/java'),
        '-PelfSha256='+sha_file.read_text().strip(), env=env)
    apk = root/'quest'/args.game/'build/outputs/apk/debug'/(args.game+'-debug.apk')
    output = build/(args.game+'-vulkan-debug.apk')
    shutil.copy2(apk, output)
    manifest = {'game': args.game, 'renderer': 'native-vulkan-openxr',
                'apk_sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
                'game_shader_sha256': hashlib.sha256(pack.read_bytes()).hexdigest(),
                'world_controls_performance_accepted': False}
    (build/'apk-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print('Experimental APK:', output)


if __name__ == '__main__':
    main()
