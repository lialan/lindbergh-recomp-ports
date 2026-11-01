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
The session lost focus and stopped roughly two seconds later. These startup
logs do not establish sustained game rendering or combat performance. World reprojection, per-eye offscreen copies, overlays, input parity
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
