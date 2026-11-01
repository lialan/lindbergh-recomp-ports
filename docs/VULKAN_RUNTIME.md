# Shared direct Vulkan runtime

Development continues on `work/hotd4-steam-frame`; the branch name is
historical. Establish macOS game execution through Mesa KosmicKrisp first.
Then validate HOTD4 Special on Quest 3, HOTD4, Ghost Squad Evolution, and
Let's Go Jungle. Zink is paused separately on
`work/hotd4-zink`, with its unresolved black-view state documented there.

The renderer consumes the existing guest graphics ABI. It creates no host GL
context and uses neither Zink nor gl4es. CPU recompilation, memory, audio,
cabinet input, game hooks and renderer mechanisms remain shared.

## Common mechanisms and game policy

| Mechanism | Common implementation | Game-specific policy |
| --- | --- | --- |
| Multiview | Vulkan targets, render passes, SPIR-V reprojection and draw submission | Camera/HUD classification and projection rules |
| Batched submission | `FrameRing`, draw packets and the guest render worker | Whether the worker is enabled by default |
| Redundant-state filtering | Existing `gl_thread.c` producer/worker filters and Vulkan state/pipeline keys | Compatibility exceptions established by a regression |
| Persistent geometry/uploads | Buffer/texture versions, native vertex formats and buffered upload storage | Asset formats and loading behavior |
| Render-target reuse | Shared target/renderer ownership and lifetime handling | Target sizes and the roles of individual passes |
| GPU depth copies | Vulkan image transfers and retained depth attachments | Which pass has the final world depth and required precision |

`render_queue.h` is the common queue contract. The implementation retains its
legacy `gl_thread.c` name because it queues the games' GL ABI calls. OpenGL
supplies checked context ownership callbacks. Vulkan uses the same argument
snapshots, client-array handling, state filtering and one-frame CPU overlap
without creating or transferring a GL context. Shutdown drains the worker
before GPU and loader teardown.

Shared mechanisms do not imply identical pass ordering or steady 60 fps for
every game. Preserve draw order, shader/material semantics, attachment sizes,
depth/stencil behavior, HUD placement and physical input while moving policy
into game profiles. Do not create separate game render loops to work around
missing common functionality.

## First resumed checkpoint

- Enabled supported portability-subset image-view swizzles at Vulkan device
  creation, and reject swizzles explicitly when the enabled device lacks them.
  The native pixel fixture samples a swizzled R8 luminance texture.
- Released all native guest GPU resources through an exit callback registered
  after loader initialization. This avoids validation-layer teardown preceding
  the process-global guest state's destructor.
- Reused the OpenGL queue's checked startup and drained shutdown in Vulkan.
- Captured 600 reference OpenGL frames of HOTD4 Special: 204 linked programs,
  202 unique pairs. All converted offline with zero compilation failures into
  a 2,848,036-byte local shader archive.
- HOTD4 Special completes 3,600 requested frames (3,601 observed) through
  KosmicKrisp with the shared worker and Vulkan validation enabled: ride
  confirmation, intro playback, stage loading and active combat. Captures show
  full-color world geometry, enemies, effects and HUD. The OpenGL reference
  has the same scene layout; animated poses/timing differ, so this is visual
  bring-up evidence rather than a pixel-exact gameplay acceptance test.
- The longer OpenGL capture has 205 shader links / 203 unique pairs, including
  `YUVCompose`, with zero offline compilation failures (2,854,045-byte archive).
  Streamed movie planes use shared texture subimage uploads with unpack row
  length, alignment, skip offsets and PBO bounds checks.
- Fixed grayscale world output: RGBA internal textures allocated with a
  luminance upload format must retain RGBA storage for later framebuffer
  copies. `guest_pixels` handles that conversion independently of any game.
  Full-level GPU color/depth copies skip staging the obsolete CPU pixels.
- Diagnostic runs exercised 3,000-frame movie/control sequences as well.
  Native periodic captures use the same `LINDBERGH_SHOT_EVERY` / `FROM`
  controls as OpenGL. Temporary uniform/copy tracing stays in ignored local
  diagnostic binaries, not the runtime.
- Fixed the apparent missing `GetBrightArea.dat` program: the reference and
  runtime sources differed only by an optional final newline. Offline/runtime
  identity normalization now agrees; raw SHA-256 integrity stays unchanged.
- Added deferred shader/program deletion, detach, float-vector attributes,
  secondary-color arrays, 2x2/3x3 uniforms and multidraw packet recording.
- Guest `glFlush` now submits without a GPU wait or presenting/reacquiring the
  image. `glFinish` waits for the latest submission. A source-owned swapchain
  test exercises more partial submissions than ring slots before presenting.
- BGRA8888, RGB565 and BGRA4444 retain packed storage. BGRA4444 uses an
  image-view swizzle, avoiding CPU pixel conversion. Pixel tests check channel
  ordering and alpha on KosmicKrisp.
- Native pipeline caches now save at drained shutdown and reload at startup.
  The default is per game under SDL's preferences directory; an explicit
  `LINDBERGH_VULKAN_CACHE` path overrides it (empty disables persistence).
  Cold/write/warm-load and default-path startup/shutdown checks pass on
  KosmicKrisp, including a 145,626-byte diagnostic cache. This is cache
  persistence evidence, not a measured warm-start speedup.
- KosmicKrisp validation self-tests pass, including stereo pixels, asynchronous
  uniform snapshots, persistent vertex/index buffers, texture sampling,
  bottom-origin render targets and GPU depth/color copies. The shared default
  OpenGL runtime self-test still passes.

These are Mac/core bring-up results, not a playable Quest port or a steady
60 fps claim. The corrected 3,600-frame run's five-second gameplay samples
range roughly 59.2–60.2 fps on this M4 Pro; loading samples are lower. Validation
and screenshot readbacks are enabled in this diagnostic, and per-frame tail
latency, sustained play and other stages still need measurement. The source-owned
Android Vulkan core pixel suite also passed on Quest 3 (Adreno 740), covering
multiview, asynchronous uniform snapshots, persistent geometry, packed textures
and GPU color/depth copies. A separate native OpenXR probe presented 120
two-layer frames with required medium foveation at 1680x1760 per eye. Runtime
logs establish session/foveation bring-up; during-session and post-session
screencaps are black and do not establish visible scene correctness. Neither test runs a game.

The shared game runtime now builds an Android Vulkan/OpenXR `libmain.so`:
SDL supplies a retained Activity/JVM reference, the native enable2 factory
creates the device, and game submissions target the foveated two-layer
swapchain without GL/EGL imports. Shader archives are packaged as assets and
extracted before guest startup. JNI setup on the shared worker uses SDL's
thread-local attach/detach mechanism. Unfocused guest work uses a private
scratch target which is never submitted or captured as XR output.

The isolated HOTD4 Special experiment boots guest shaders on Adreno and creates
the foveated swapchain. Initial runs stayed at XR IDLE. After stopping our stale
Zink diagnostic, the native game reached READY, VISIBLE and FOCUSED, acquired
its first game target, and received a runtime-confirmed 90 -> 120 Hz change.
The session lost focus and stopped roughly two seconds later. An early-frame
capture retry did not produce a live game PID; exit-info contained only prior
force-stop cleanup records, and no fresh crash record established its cause.
These startup logs do not establish sustained game rendering or combat performance. World reprojection, per-eye offscreen copies, overlays, input parity
and full game-call coverage remain pending. Target retirement/resizing and pipeline preparation also need
complete game-path coverage. The reproducible Quest probe runner in
`lindberghrecomp/tools/vulkan/test_quest_probe.py` holds the shared lock through
cleanup, tests the core separately, and rejects stale XR logs using a unique
launch token and fresh process ID.

## Mac-first work and coordinated Quest access

Continue source work, offline conversion and Mac Vulkan pixel/reference
checks first. The user subsequently made Quest access available through a
shared exclusive lock with the other Codex thread. Device validation remains
a separate acceptance step.

For Quest serial `2G97C5ZJ0G02DQ`, run the **entire** device test script through
`python3 ~/.local/bin/quest3-lock bash /tmp/my-quest-test.sh`. The wrapper holds
`fcntl.flock` on `/tmp/quest3-2G97C5ZJ0G02DQ.lock`; never delete that file.
Installation, launch, screenshots, log collection, app stop and cleanup must
all complete before the script exits. Every device command must target that
explicit serial. Do not issue direct ADB outside the wrapper. Status 75 means
the headset is busy: continue local work and retry later. The wrapper has been
read and the cooperating thread notified. Completed probe sessions stopped
only the diagnostic app, disabled proximity automation and released the lock.

Run the shared Mac suite with `scripts/test-vulkan-macos.sh`. It selects
`/opt/homebrew/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json` by default,
prints the selected ICD and enables Vulkan validation. `VK_DRIVER_FILES` may
explicitly select another installed path; there is no silent driver fallback.

Combat performance is a release gate: see [VULKAN_PERFORMANCE.md](VULKAN_PERFORMANCE.md)
for the shared recorder, matched Mac comparisons and still-open Quest/cold-cache
gates. Average FPS alone is insufficient. All performance diagnostics are opt-in.

Next, extend Mac gameplay/reference coverage (including slow-motion and longer
runs), cover remaining target/resource lifetime gaps, and bring up HOTD4 using
the same runtime. Keep these Mac execution gates ahead of standalone Android
integration; Quest/OpenXR acceptance remains pending.

## Experimental Android game build

Build without touching the OpenGL app's libraries or package identity:

```sh
python3 quest/build_vulkan.py hotd4sp \
  --shader-pack build-vulkan-shaders-hotd4sp-play/hotd4sp.lvsp \
  --gl-headers-root /path/to/mesa/include
```

The builder takes portable GL headers as guest ABI declarations only, compiles
SPIR-V offline, and packages `game.lvsp` plus `fixed.lvsp`. It uses a separate
build directory and `.vulkan` application ID suffix. It neither installs nor
operates a headset, and carries no game data. Its inputs and APK hashes are
recorded in `apk-manifest.json`. All four game modules use the same packaging
path; only HOTD4 Special has been built through it so far.

The existing GL display-cadence policy is shared in `display_cadence.c`:
actual predicted display timing drives a near-60 Hz guest budget, including the
one-time half-display-period correction for repeated 1/3 delivery. Atomic
publication prevents the guest/renderer data race. Rate/session changes reset
phase history; unsupported non-divisor refresh rates retain the guest's own
budget. Runtime tests cover stable 120 Hz, phase correction, 60/72/90 Hz,
period noise and reset behavior. The native host requests supported 120 Hz
(or 60 Hz), logging the request separately from runtime-reported refresh.
Do not equate a requested rate or CPU submission cadence with displayed FPS.

## Shared stereo copy and projection work

The native core preserves both eyes in GPU color/depth copies, including
independently initialized destination layers and explicit eye routing. Both
layers travel through one copy/blit command. The guest frontend allocates two
layers for XR pbuffers and propagates their layer count into copied textures;
full-level copies still skip obsolete CPU uploads.

The offline shader converter lowers 2D sampling, projective sampling, explicit
LOD and depth comparisons to per-eye array sampling. Static textures retain one
physical layer and a cached array view. Hardware array-layer clamping selects
that same static image for either eye; there is no shader texture-size query,
branch, or duplicate static-image upload. See the [Vulkan sampling rule](https://docs.vulkan.org/spec/latest/chapters/textures.html#textures-unnormalized-to-integer).
Old mono archives still work on desktop; XR copied arrays require a rebuilt
archive and fail explicitly if a mono sampler would flatten the result.

The source-owned tests render different eye images, copy and resample them
through converted guest GLSL, and compare both images and depth layers. These
pass with validation on KosmicKrisp and on Quest 3's Adreno GPU. All 203 captured
HOTD4 Special shader pairs compile offline with zero failures. A 5,600-frame
Mac repeat with the rebuilt archive exits normally, retains full-color world
and HUD output, and reports no validation errors. Its screenshot is a dialogue
scene, not a combat-performance measurement.

`stereo_projection.c` now supplies the existing GL world/HUD/pass/fill math to
both renderers. Direct Vulkan pixel tests use its clip reprojection rather
than hand-written eye offsets. CPU checks cover head/world-locked HUDs,
foreground fills, singular-matrix rejection and a truly infinite far plane.
Finite GL projection arithmetic is retained. The guest draw packets now use live camera classification and cached
transforms, with anchored headset views and shared target-resolution scaling.
Input/overlay parity, HUD clipping and game world-pass foveation validation remain open; this
is not a finished stereo port or a Quest performance acceptance result.

The latest probe collector retains its authenticated START across rolling
logcat snapshots. An initial run emitted a 120-frame foveated PASS but lost
its START from the last snapshot; the corrected collector then captured a
fresh Activity-destruction failure during startup. Neither observation is
combat validation. Sessions completed cleanup and released the shared lock.

## Shared live-camera policy foundation

The shared settings parser now supplies the same vr.cfg precedence, 2064x2280
default eye size and 120 Hz request to both renderers. GL and native Vulkan
also share pose rotation, draw classification and bounded offscreen target
scaling. The Vulkan camera policy publishes poses once per frame and caches
world/HUD transforms, avoiding repeated camera inversions for matching draws.
Its tests exercise head locking, dominant lenses, zoom persistence, bounds
reads from CPU VBO shadows and the 1024-pixel offscreen scaling cap.

The native OpenXR host can anchor views, honor configured resolution and
request sustained CPU performance and renderer-thread registration. Requests
are logged separately from runtime acceptance. Mac Vulkan pixel/runtime tests,
three settings tests and Android GL/Vulkan compilation pass. Live headset
validation of these additions remains pending.

Guest live-camera wiring now preserves completed eye images during fullscreen
composition. Initial simulated-pose output lost the world, while the world
pbuffer and a two-layer identity-transform control retained it. Full-frame
copy composites now retain guest clip space instead of receiving a second
camera transform. A 3600-frame simulated-pose repeat retains combat geometry
and HUD without validation errors. This remains Mac correctness evidence;
Quest input/overlay, game world-pass foveation validation and combat acceptance are pending.

Diagnostic captures can select a guest drawable with
LINDBERGH_VULKAN_SHOT_DRAWABLE=<id>. Such captures are explicitly logged as
intermediate targets, not final display output. Keep this and classification
logging disabled during performance comparisons.

## Shared foveated world attachments

Full-eye world pbuffers now reuse prepared framebuffer variants with the
current acquired OpenXR image's density-map view. The same color/depth storage,
render passes and pipeline objects persist; frame changes select a handle.
An owned full-rate density map covers unfocused scratch rendering without
using an unacquired runtime resource. The shared ConstantDensityMap helper
initializes once and completes its upload before publishing a static view.
No density-map upload, framebuffer allocation or additional GPU wait is added
to the per-frame path. Non-world targets keep their existing bounded sizing.

Quest headless pixel tests pass with the production map helper and alternating
maps across asynchronous two-eye draws. Mac validation/core tests and Android
game/APK builds pass. The latest bounded game launch produced no native log,
so live world-pbuffer activation, visual quality and combat performance remain
open. See VULKAN_PERFORMANCE.md for evidence and measurement requirements.

## Shared controller and cabinet input

GL and native Vulkan now use xr_actions.c for the established Touch bindings,
active action values, aim spaces and haptics. xr_controls.c holds hand switching,
120 ms grip-reload pulses, offscreen reload, player-specific buttons, Start,
automatic credits and delayed P2 join. GL keeps its existing panel/recoil
callback ordering. Cabinet button definitions live in cabinet_buttons.h.

The renderer-independent ControllerInput class maps anchored controller poses
through shared screen/HUD ray math and publishes a snapshot for the game
thread. Short trigger pulses and coin events survive between reads; focus or
tracking loss clears held input and shot rays. This adds no GPU work or wait.
Native Vulkan provides stereo_gun_ray rather than the former disabled bridge,
so HOTD4 Special's existing per-player shot hook can use the controller ray.
Its input coordinates use the profile's 1024x768 cabinet range, independently
of the render target resolution. The native OpenXR host reanchors on focus,
matching the GL host's policy.

Source-owned controls/action tests cover binding initialization and cleanup,
inactive/invalid poses, focus loss, haptics, reload timing, hand selection,
separate player actions and credit-before-Start ordering. Mac core tests also
cover head-locked aim and game-thread delivery. The same core tests pass on
Quest's Adreno 740 in quest-stereo-core-20261101-012529 (no XR session or
physical-controller validation). Full Android GL game linking and native
Vulkan APK packaging pass.

For device-free integration, set LINDBERGH_VULKAN_FAKE_YAW=0 and
LINDBERGH_VULKAN_FAKE_GUN=1 or 2. The latter drives the same pose/cabinet path;
it is disabled by default. On Mac, LINDBERGH_SHOT_FROM_GUN=1 explicitly enables
HOTD4 Special's shot-ray game hook. Two 3600-frame simulated-controller runs
retain world/HUD output and show both players joined. The ray-enabled repeat
logs successful GetTarget calls with a native ray and no validation errors.
Artifacts remain under build-mac-vulkan-game/controller-ray-dual-3600.log and
build-vulkan-reference/hotd4sp-controller-ray-dual-3600.ppm. These are local
integration checks, not Quest combat or precision-aim acceptance.

The capture control, HUD clipping, path-box and depth-aware aiming, and
special game-menu/CQC/horizon policies remain open. Native settings/FPS
panel integration is described below.
The current non-HUD aim path uses the configured aim distance until depth
sampling is ported. Actual runtime/controller binding, world foveation,
visual quality and sustained combat frame times still require Quest testing.

## Native multiview gun, laser and sight overlay

The source-owned gun mesh, pose, beam/spot billboards and sight glass geometry
are shared with GL in xr_overlay_geometry.c. All nine model/sight mesh variants
match the pre-extraction GL vertex bytes (reference commit 9cae523). GL uses
the same functions and still links on Android. The Vulkan Overlay class keeps
all nine meshes in GPU buffers and prepares its pipelines for every swapchain
target before gameplay. Shaders are embedded build-time SPIR-V; no GL driver,
translation layer or runtime shader compiler is introduced.

Each primitive is drawn once with multiview. Per-eye billboard positions share
one buffered vertex upload; gun transforms and uniforms use persistent frame
storage. Guns retain the GL lighting, recoil and muzzle flashes; red/blue
lasers preserve the game's alpha channel. Red-dot/holographic sights use the
same glass geometry and a temporary depth mask, including independent eye
visibility. Equal-depth viewport mapping preserves clip-plane behavior.

Overlay drawing can adopt the final game render pass, retaining color without
an extra tile load/store. It starts its own preserving pass only when the game
has already closed that pass. The Mac 3600-frame diagnostic run retained nine
meshes/three prepared targets. Its additional overlay-pass counter reached 17
by frame 1200 and remained 17 through frame 3600; combat added none. This is
mechanism validation, not a Quest FPS or bandwidth measurement.

Source-owned GPU tests check stereo separation, laser alpha, a sight dot visible
through one eye's glass only, and a laser collinear with one eye without losing
the other eye's gradient. They verify 28 multiview draws instead of per-eye
replay, zero additional passes when adopting the background, and stable mesh/
target resources. Both ordinary and density-map render-pass cases pass on
Adreno 740; evidence: quest-stereo-core-20261101-014705. Mac validation tests,
mesh reference tests, Android GL linking and native APK packaging pass. The
native Android library has no GL/EGL/SDL_GL imports.

A 3600-frame Mac game repeat shows both guns, flashes and red/blue beams over
combat without validation errors. Inspect
build-vulkan-reference/hotd4sp-overlay-dual-3600.png and
build-mac-vulkan-game/overlay-pass-3600.log. The image also exposes scene-edge
gaps that required diagnosis (the street-wall case is covered below); it is not final visual acceptance. No headed
Quest session was run for this overlay milestone. Settings/capture/FPS panels,
remaining aiming/classification policies, color handling and actual headset
combat quality/performance remain open.

### Shared settings panel policy foundation

The settings item definitions, action cycles, reset confirmation and controller
ray/panel intersection now live in `runtime/xr_panel.{h,c}`. The established
OpenGL host uses this policy, and the native Vulkan core links the same policy
and CPU painter. Android GL linking, pure policy/geometry tests and Mac Vulkan
core validation pass. That foundation commit did not draw a native Vulkan panel
or activate native menu actions; the subsequent integration is described below. The
policy does no per-frame allocation, file IO or GPU work.

## Native settings and FPS panels

`SettingsPanel` now drives the native render worker from the shared settings
policy, painter, Touch actions and cabinet controls. Left Menu toggles the
panel; the offhand upper button held for one second toggles it in single-gun
mode. Valid controller rays select rows on trigger edges. An open panel
suppresses game coordinates, shot rays and queued trigger edges while retaining
the pointing guns. The shared cabinet policy also blocks a previously scheduled
P2 join Start while the panel is open. Test/Service and coin actions use the
existing game-thread mailbox.

Sight, laser, gun visibility, hand, dual wield, FPS, distance, HUD pitch and
credit policy update live. Refresh cycles advertised runtime rates and issues
an OpenXR request; actual timing remains authoritative. Resolution persists
for the next launch. Recenter requests the existing anchored-space mechanism.
Reset retains the two-selection confirmation and calls the existing Android
Activity restart method. Settings persistence occurs only on a real choice;
the fake-menu demonstration disables choices and config writes.

The crosshair recognizer is shared with GL in `runtime/xr_sight.h`. It retains
the existing small-sprite, gun-center, distinct-frame and movement conditions
before learning P1/P2 textures. Native HUD packet filtering uses that same
policy and producer-side cabinet coordinates. Unknown HUD sprites remain
visible. Actual per-game recognition still requires headset gameplay checks.

The native overlay owns two persistent image/descriptor sets (768x752 settings,
224x48 FPS) and a resident quad, with pipelines prepared before play. Dirty
pictures upload before game render passes begin. Each visible panel is one
multiview draw in the adopted final pass; guns draw once over an open menu.
There are no per-frame descriptor/image/geometry allocations or added GPU
waits. A closed menu adds no panel draw or image upload. The optional FPS
label updates its image only when the displayed number changes.

Mac validation and Adreno source-owned tests cover menu selection, hand-change
trigger ordering, live camera changes, coin/Test delivery, double reset,
focus loss, suppression of game rays/queued fire, and crosshair learning.
GPU checks cover top-first texture UV, both eyes, preserved alpha, one shared
pass, and four draws for four frames. A 45-frame UI/FPS test performs just
one settings and one FPS upload. Ordinary and density-map cases pass on
Quest 3's Adreno 740; retained session:
`build-vulkan-android-core/quest-stereo-core-20261101-011100/`.
Android GL/native builds and isolated APK packaging pass.

Device-free game checks exit normally without validation errors and show the
panel over the game with both controller overlays. Artifacts:
`build-vulkan-reference/hotd4sp-native-panel.png`,
`build-vulkan-reference/hotd4sp-native-panel-look.png`,
`build-mac-vulkan-game/native-panel.log` and `native-panel-look.log`.
The look demonstration uses `LINDBERGH_VULKAN_FAKE_MENU_LOOK=1` with the fake
eye/controller/menu switches: it turns toward the placed panel after frame
120 without moving that panel. These checks do not prove physical controller
interaction, Android restart/refresh/recenter behavior, full game visual
parity or Quest combat performance. No headed Quest session was run for this
milestone. Capture controls, remaining aiming/HUD policies, scene-edge gaps,
color/depth format parity and sustained Quest combat pacing remain open.

## Shared NN culling and the Special street-edge gap

HOTD4's existing OpenXR hook for `nnSetClipPlane` now lives in the common
`runtime/nn_culling.{h,c}` implementation. It temporarily divides the two
focal-length inputs while the guest builds its CPU side planes, calls the
original lifted routine and restores the render-projection bits before
returning. It adds no render pass, GPU work, allocation or GPU wait. Drawing
newly visible objects can of course increase CPU/GPU work; that cost remains
part of the combat performance gate.

The supported HOTD4 Special image's stripped counterpart is at `0x08346AA0`.
Its lifted code has the same projection-type split, four normalized side
planes and focal-length reads as HOTD4's named routine at `0x08303008`.
Per-title metadata is limited to the entry and focal-length addresses:

| Title | Plane builder | Projection X | Projection Y |
| --- | --- | --- | --- |
| HOTD4 | `guest_symbol("nnSetClipPlane")` | `0x0A767C80` | `0x0A767C94` |
| HOTD4 Special | `0x08346AA0` | `0x0A6F34C0` | `0x0A6F34D4` |

The Special candidate is the unique lifted function with the relevant scalar
divides/global plane writes; source comparison confirms matching math rather
than identical register allocation. The real game invokes it: the opt-in
`LINDBERGH_CULL_LOG=1` reports its first three focal input changes. Pure tests
verify shortened inputs inside the guest callback, balanced guest return-stack
handling, bit-exact restoration (including signed zero/NaN/infinity), disabled/
invalid overrides and failed installation. One hook can be installed per
process. The `LINDBERGH_CULL_WIDEN=1` control leaves the cabinet behavior intact.

A first cabinet-style-input Mac comparison did not reproduce the reported
edge gap, so it was not used as a fix result. The exact dual-controller/shot-ray
scenario did reproduce it: at frame 3600 with culling unchanged, the street's
near left wall/ground is absent, exposing sky/clear color beneath the bridge.
The otherwise matched 4x side-plane run restores the wall and ground. Both
runs exit normally with validation enabled, and use the same render projection,
resolution, pose/controller script and shader archive. Enemy/animation timing
varies between runs; this is visual evidence for that static-scene gap rather
than pixel-identical whole-frame replay.

Artifacts are retained in `build-vulkan-reference/hotd4sp-dual-cull{1,4}-3600.png`
and `build-mac-vulkan-game/dual-cull{1,4}-3600.log`. The initial desktop OpenGL
stereo replay capture has nested composition and a black right view; it is not
a valid image-parity baseline for the Quest multiview path.

HOTD4 and Special now share the established 4x default in OpenXR and explicit
desktop stereo/simulated-eye modes. Ordinary desktop execution stays at 1x.
The environment override wins. This restores the identified Mac scenario;
remaining visual issues, turning coverage and Quest combat cost still require
verification. No headset session was used for this milestone.

## Actual guest offscreen diagnostics on Quest

`LINDBERGH_VULKAN_OFFSCREEN=ON` is an explicit build mode, incompatible with
OpenXR. It uses the same game/lifted code, guest ABI, queue, camera/control
policy and Vulkan core with an owned two-layer target and a dummy SDL window.
It does not link the SDL Vulkan-surface host or OpenXR host. Normal APK builds
explicitly select `OFF`, so the diagnostic cannot silently replace the headset
host. Android builds add `<game>_vulkan_offscreen`, calling `game_main` directly
without SDL's Activity/storage entry point. The render-target scaling policy
is shared with the headset path. Optional constant density-map attachments use
the device's supported texel extent; their uniform values are diagnostic,
not the runtime's foveation pattern.

Build HOTD4 Special with the normal builder and the additional `--offscreen`
flag, a separate build directory, and the same offline shader pack/GL ABI
headers. This produces no APK. For example:

```sh
python3 quest/build_vulkan.py hotd4sp --offscreen \
  --shader-pack build-vulkan-shaders-hotd4sp-stereo/hotd4sp.lvsp \
  --gl-headers-root /path/to/mesa/include \
  --build-dir build-quest-vulkan-offscreen
python3 ~/.local/bin/quest3-lock python3 quest/run_vulkan_offscreen.py \
  --build-dir build-quest-vulkan-offscreen \
  --shader-pack build-vulkan-shaders-hotd4sp-stereo/hotd4sp.lvsp \
  --output build-quest-vulkan-offscreen/unique-run \
  --frames 120 --timeout 90 --width 2064 --height 2280 --density 1 --dual
```

The entire runner must remain inside the shared lock wrapper. It targets the
explicit serial, verifies the ELF hash against the lifted input and checks
available space, then copies `elf`/`fs` into a private UUID tree. NVRAM, config,
shader cache, captures and logs are private too. It never installs or launches
an app, creates an XR session, or changes wake/proximity/Guardian settings.
Cleanup stops only a process whose command line matches its own UUID, removes
the private copy and verifies both installed HOTD4SP APK hashes. A fresh output
directory retains binary/compiler/environment provenance, streaming logs,
CPU-boundary timing and two-eye captures. Optional `--pipeline-cache` loads a
same-device cache from a prior diagnostic; incompatible driver cache data is
still rejected by the existing renderer helper.

The first CLI attempts reached Vulkan and then failed in SDL's audio thread:
`Android_JNI_AudioSetThreadPriority` dereferences the missing JavaVM even for
the dummy audio driver. Retained module/offset and unwind output established
that failure. Only the diagnostic Android build now runs the existing SEGA
mix/voice clock on an owned pthread and discards output. The thread stops and
joins at exit. Production audio remains unchanged. The crash reporter also
reports module offsets for unnamed functions and an Android unwind trace.

Mac dummy-window boot and two-eye readbacks pass validation. Actual Quest
Adreno boot first passed four frames, then 120 frames at 2064x2280 per eye with
full-rate density attachments on the final target and world pbuffer. Both
eye images are valid, nonblank and different. Their startup screen and gun/UI
rendering are visible in `build-quest-vulkan-offscreen/quest-fdm-stereo-120/`.
That first capture's FPS label used a simulated-input clock and is not timing
evidence; the label now uses a separate elapsed host clock for simulated
controllers, with a CPU regression test. The runner also overrides settings
explicitly rather than inheriting the copied tree's FPS setting.

The subsequent actual-guest run completed 3601 frames with dual simulated gun
input and native shot rays, retaining two valid 2064x2280 combat images. The
restored street wall, world textures and HUD are visible. Artifacts:
`build-quest-vulkan-offscreen/quest-fdm-game-3600/` (report, game log,
capture/capture.right images, raw timing and analysis). All these device
sessions cleaned their private trees and preserved installed APK hashes.
These are real Adreno guest/renderer results, but do not establish physical
controller accuracy, runtime foveation-map acquisition, headset display
correctness, audio output, thermal stability or VR/combat pacing acceptance.
The first measured combat window contains large stalls, detailed in the
performance document; that gate remains open.


## Portable pipeline recipes and retained preparation

The shared `PipelineRecipes` helper captures only descriptions of observed
native pipelines, not game resources, shader code or opaque driver binaries.
Its `LVPREC1` file contains little-endian records with compiled shader-content
identities, vertex bindings/attributes, target compatibility and canonical
raster keys, protected by a SHA-256 checksum. Shader identities include both
SPIR-V modules and the archive record key. Bounds, counts, canonical state,
vertex-input limits and format support are checked before creating pipelines.
Corrupt files are ignored atomically; records for changed or absent compiled
shaders are skipped. Changing the recipe ABI requires a version bump.

With a nonempty normal driver-cache path, the default writable catalogue is
`<cache path>.recipes`. `LINDBERGH_VULKAN_RECIPES` overrides that path; an empty
path disables collection unless a seed is explicitly supplied.
`LINDBERGH_VULKAN_RECIPES_SEED` supplies a portable seed. Catalogue file I/O
occurs at load/shutdown. Shader hashing occurs at load, and new recipes are
recorded only when a pipeline is first created. Cached draws perform their
existing pipeline lookup without recipe hashing, file I/O or synchronization.

After loading shader archives, the host prepares compatible recipes against
its actual final targets. New guest pbuffers prepare their compatible recipes
when created, before they are first bound. Renderers and pipelines remain
resident and are reused by the guest draw path; a warmed driver cache is not
used as a substitute for retaining the actual objects. Descriptor layouts are
reconstructed from the current shader reflection, matching the shared dynamic
UBO and sampled-image schemas. GPU tests bind independently created runtime
sets to those preloaded layouts and verify distinct stereo output. Target
resolution is dynamic and does not create another recipe; origin, layers,
format, final-layout class and density-attachment presence remain distinct.

At exit the helper reports prepared pipeline objects, first-use creations in
the shader-record path and catalogue entries. The basic diagnostic colored
renderer is outside this catalogue; its few startup pipelines are still
covered by the existing preparation profiler. Optional
`LINDBERGH_VULKAN_PREPARE_TIMING=1` reports unexpected creations during combat.
Seed coverage is limited to the observed materials/states. New levels or
control paths may add recipes and must be exercised before coverage claims.

The offscreen runner now pulls `pipeline-cache.bin.recipes` and accepts
`--pipeline-recipes FILE`. This supplies a seed independently of
`--pipeline-cache`, so first-install preparation can be tested without prior
opaque cache bytes. `--no-recipes` disables collection/preparation for a
control. Build an APK with `quest/build_vulkan.py ... --pipeline-recipes FILE`
to package `assets/vulkan/pipelines.lvpr`. Android extracts that optional seed
alongside the required shader archives. The builder removes stale seed assets
when the option is omitted and records the seed hash in its manifest.

Mac GPU validation passes catalogue capture, read-only seed loading, retained
objects, compatible runtime descriptors, resolution reuse, origin separation,
corrupt-file rejection and unknown-shader rejection. Actual Mac guest boot
records four recipes; a subsequent cold-cache boot with the seed prepares all
four and reaches its endpoint with zero shader-record first-use creations.
The corresponding Quest combat result is documented in VULKAN_PERFORMANCE.md.
