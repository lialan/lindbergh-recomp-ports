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
    parser.add_argument('--pipeline-recipes',type=Path,help='portable observed pipeline catalogue to prepare during loading')
    parser.add_argument('--pipeline-cache',type=Path,help="driver pipeline cache harvested on a Quest 3 (used where the GPU and driver match)")
    parser.add_argument('--seeds',type=Path,default=Path(os.environ.get('LINDBERGH_SEEDS',root/'build-seeds')),
                        help='scripts/harvest-pipelines.sh output: <seeds>/<game>/pipelines.lvpr and quest/pipelines.bin are the defaults')
    parser.add_argument('--gl-headers-root', type=Path, required=True, help='declaration-only include root containing GL/gl.h and GL/glext.h')
    parser.add_argument('--deps', type=Path, default=root.parent/'deps')
    parser.add_argument('--sdk', type=Path, default=Path(os.environ.get('ANDROID_HOME', Path.home()/'Library/Android/sdk')))
    parser.add_argument('--ndk', type=Path)
    parser.add_argument('--build-dir', type=Path)
    parser.add_argument('--jobs', type=int, default=6)
    parser.add_argument('--no-apk', action='store_true')
    parser.add_argument('--offscreen',action='store_true',help='build an executable diagnostic without APK, Activity or OpenXR')
    args = parser.parse_args()
    if args.jobs < 1: parser.error('--jobs must be positive')
    default_build=root/('build-quest-vulkan-offscreen' if args.offscreen else 'build-quest-vulkan')/args.game
    build = (args.build_dir or default_build).resolve()
    deps, sdk, headers = args.deps.resolve(), args.sdk.resolve(), args.gl_headers_root.resolve()
    ndk = (args.ndk or sdk/'ndk/27.3.13750724').resolve()
    pack = args.shader_pack.resolve()
    for path in [pack, headers/'GL/gl.h', headers/'GL/glext.h', ndk/'build/cmake/android.toolchain.cmake',
                 root/'games'/args.game/'generated/recomp_imports.h']:
        if not path.is_file(): parser.error('missing required input: '+str(path))
    seeds=args.seeds/args.game
    if not args.pipeline_recipes and (seeds/'pipelines.lvpr').is_file():args.pipeline_recipes=seeds/'pipelines.lvpr'
    if not args.pipeline_cache and (seeds/'quest/pipelines.bin').is_file():args.pipeline_cache=seeds/'quest/pipelines.bin'
    if args.pipeline_recipes and not args.pipeline_recipes.is_file():parser.error('missing pipeline recipes')
    if args.pipeline_cache and not args.pipeline_cache.is_file():parser.error('missing pipeline cache')
    print('pipeline seed:',args.pipeline_recipes or 'none','; driver cache:',args.pipeline_cache or 'none',flush=True)
    run('cmake', '-S', root, '-B', build, '-G', 'Ninja',
        '-DCMAKE_TOOLCHAIN_FILE='+str(ndk/'build/cmake/android.toolchain.cmake'),
        '-DANDROID_ABI=arm64-v8a', '-DANDROID_PLATFORM=android-29', '-DCMAKE_BUILD_TYPE=Release',
        '-DLINDBERGH_GAMES='+args.game, '-DLINDBERGH_RENDERER=VULKAN', '-DLINDBERGH_OPENXR='+('OFF' if args.offscreen else 'ON'),
        '-DBUILD_TESTING=OFF', '-DLINDBERGH_VULKAN_OFFSCREEN='+('ON' if args.offscreen else 'OFF'), '-DLINDBERGH_GL_HEADERS='+str(headers/'GL/gl.h')+';'+str(headers/'GL/glext.h'),
        '-DSDL2_DIR='+str(deps/'sdl2-android/lib/cmake/SDL2'),
        '-DOPENAL_DIR='+str(deps/'openal-soft'), '-DOPENAL_LIB='+str(deps/'openal-android/libopenal.so'),
        '-DOpenXR_DIR='+str(deps/'oxr'))
    target=args.game+'_vulkan_offscreen' if args.offscreen else args.game
    run('cmake', '--build', build, '--target', target, '--parallel', args.jobs)
    if args.offscreen:
        manifest={'game':args.game,'renderer':'native-vulkan-offscreen-diagnostic','openxr':False,
                  'executable_sha256':hashlib.sha256((build/target).read_bytes()).hexdigest(),
                  'library_sha256':hashlib.sha256((build/'libmain.so').read_bytes()).hexdigest(),
                  'game_shader_sha256':hashlib.sha256(pack.read_bytes()).hexdigest(),
                  'world_controls_performance_accepted':False}
        (build/'offscreen-manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
        print('Offscreen diagnostic:',build/target,'(no APK or OpenXR session)')
        return
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
    seed=assets/'pipelines.lvpr'
    if args.pipeline_recipes:shutil.copy2(args.pipeline_recipes,seed)
    elif seed.exists():seed.unlink() # never retain an earlier invocation's seed
    driver_cache=assets/'pipelines.bin'
    if args.pipeline_cache:shutil.copy2(args.pipeline_cache,driver_cache)
    elif driver_cache.exists():driver_cache.unlink()
    env = os.environ.copy()
    env['ANDROID_HOME'] = str(sdk)
    java = Path('/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home')
    if 'JAVA_HOME' not in env and java.is_dir(): env['JAVA_HOME'] = str(java)
    config = (root/'games'/args.game/'game.conf').read_text().splitlines()
    sha_name = next(shlex.split(line, comments=True)[0].split('=',1)[1]
                    for line in config if line.startswith('SHA_FILE='))
    sha_file = root/'games'/args.game/'generated'/sha_name
    if not sha_file.is_file(): parser.error('missing lifted ELF hash: '+str(sha_file))
    # quest/build.sh (the OpenGL build) copies SDL's Java into the module; this
    # build adds it from SDL's tree (sdlJavaDir), so a leftover copy duplicates
    # every class. The copy is generated and gitignored.
    shutil.rmtree(root/'quest'/args.game/'src/main/java/org/libsdl', ignore_errors=True)
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
    if args.pipeline_recipes:manifest['pipeline_recipes_sha256']=hashlib.sha256(args.pipeline_recipes.read_bytes()).hexdigest()
    if args.pipeline_cache:manifest['pipeline_cache_sha256']=hashlib.sha256(args.pipeline_cache.read_bytes()).hexdigest()
    (build/'apk-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    print('Experimental APK:', output)


if __name__ == '__main__':
    main()
