# The House of the Dead 4 VR on Steam Frame

A native AArch64 Linux build of the recompiled *The House of the Dead 4* for
Valve's Steam Frame: the same lifted game and native Vulkan renderer as the
Quest's Vulkan build ([VULKAN.md](VULKAN.md)), presented through SteamVR's
OpenXR runtime, built against the Steam Linux Runtime 4 (`steamrt4`, the
runtime Valve's native-engine guidance targets).

**Status:** builds and packages; starts natively on AArch64 Linux in the
Steam Linux Runtime 4 (loads and runs the lifted game, finds its shader
archives, reaches OpenXR). Not yet run on a Frame.

## Build

Needs Docker (OrbStack or Docker Desktop on an Apple-silicon Mac runs the
arm64 SDK natively), the lifted game in `games/hotd4/generated`
(`scripts/build-macos.sh hotd4 "/path/to/House of the Dead 4"`), and the
game's offline shader archive, the same one the Quest Vulkan build bundles
(`quest/build_vulkan.py --shader-pack`; see [VULKAN.md](VULKAN.md)).

Rebuild the shader archive whenever the converter changes, from the OpenGL
capture's `programs.jsonl`, so it matches the code:

```sh
python3 lindberghrecomp/tools/vulkan/compile_shaders.py <capture>/programs.jsonl build-frame/hotd4/shaders
python3 lindberghrecomp/tools/vulkan/pack_shaders.py build-frame/hotd4/shaders build-frame/hotd4/hotd4.lvsp
scripts/build-steam-frame.sh hotd4 --shader-pack build-frame/hotd4/hotd4.lvsp [--pipeline-recipes pipelines.lvpr]
# -> build-frame/hotd4/dist/HouseOfTheDead4VR-steamframe-arm64.tar.gz
```

The script pulls `registry.gitlab.steamos.cloud/steamrt/steamrt4/sdk/arm64`
(`STEAMRT_IMAGE` overrides it), builds with its clang, SDL2, OpenAL Soft,
Vulkan loader and OpenXR 1.1 loader, and packages:

| | |
|-|-|
| `hotd4` | the game (stripped AArch64 PIE) |
| `vulkan/` | `game.lvsp`, `fixed.lvsp` and, if given, `pipelines.lvpr` |
| `lib/` | SDL2, OpenAL Soft, the OpenXR loader and its jsoncpp, for a system without them |
| `launch.sh` | the launcher |

The guest GL ABI headers default to the Mesa ones the Quest build uses
(`../deps/mesa-26.2.6/include`); `--gl-headers-root` names others. The
fixed-function archive is built on the host when it has `glslangValidator`
and `spirv-cross`, as for the Quest: the runtime SDK's 2021 `spirv-cross`
makes a different archive, which is used only as a fallback.

## Install and run

Copy the unpacked folder and your game folder (the one holding
`elf/hod4M.elf`, `fs/` and `drv/`) to the Frame, then in Desktop Mode:

```sh
./launch.sh "/path/to/House of the Dead 4"    # remembered in game-dir.txt
```

To start it from the headset, add `launch.sh` to Steam as a non-Steam game;
if it does not start that way, set its compatibility tool to *Steam Linux
Runtime 4.0*. `env.txt` beside the launcher sets runtime options
(`NAME=value` per line); `vr.cfg` in the game's `elf/` folder holds the VR
settings, as on the Quest. The log of the last run is `hotd4.log` beside
the launcher.

## Foveation

Foveation is required, as on the Quest: the world is drawn into the
runtime's fragment density maps (`XR_FB_foveation`, `_configuration`,
`_vulkan`, `XR_FB_swapchain_update_state`, with Vulkan
`VK_EXT_fragment_density_map`), and the game says which piece is missing and
stops rather than run without it. The level (off, low, medium, high) is the
settings panel's foveation row and `vr.cfg`'s `foveation`.

On the Frame it is also **eye-tracked**: when the runtime offers
`XR_META_foveation_eye_tracked` and the headset reports support, each level
profile carries the eye-tracked profile, so the sharp region follows the
gaze instead of staying at the lens centre. Otherwise it is fixed and the
log says why. `LINDBERGH_XR_EYE_FOVEATION=0` forces fixed foveation; on
Android it is off unless set to `1` (Quest 3 has no eye tracking).

## Validation so far

- Builds in the Steam Linux Runtime 4 arm64 SDK (clang 19, glibc 2.41).
- In a clean `steamrt4` container with the real game data and no OpenXR
  runtime: the guest loads, the HLE layer binds, the game's own threads
  start, its VR profile (640x480 into the stereo screen) applies, the
  shader archives are found, and startup stops at OpenXR with
  `XR_ERROR_RUNTIME_UNAVAILABLE` (-51), as it should without a runtime.
- `scripts/steam-frame/offscreen-test.sh` builds the offscreen diagnostic
  (no OpenXR; the same lifted game and Vulkan renderer) in the same runtime
  and renders the game on Mesa lavapipe (`LINDBERGH_VULKAN_ALLOW_SOFTWARE=1`,
  the diagnostic's opt-in for a CPU rasterizer). Run with the real data for
  900 frames at 1024x1024 per eye, it reaches the first stage in play with
  its HUD, gun model and laser in both eyes; all 314 pipeline recipes are
  prepared before use (no first-use pipelines) and every guest program comes
  from the offline SPIR-V archive. lavapipe has no density maps, so this run
  has no foveation.
- The Quest Vulkan build of the same tree still builds (the shared OpenXR
  and guest changes are guarded for Android).

Still to do on a Frame: SteamVR's extension set (above all the FB foveation
and eye-tracked extensions), Frame controller bindings (the action set
suggests Touch bindings; SteamVR remaps them, Frame-native bindings are not
written yet), picture, aim, HUD, audio and performance.
