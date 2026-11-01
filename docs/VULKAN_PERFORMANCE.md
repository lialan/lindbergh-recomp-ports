# Vulkan combat performance acceptance

Quest 3 combat must remain near 60 game frames per second with smooth delivery.
Occasional dips are allowed by the user; recurring pacing spikes or a sustained
regression against the established OpenGL port are not. Average FPS alone is
insufficient. This is an acceptance gate for HOTD4 Special, followed by HOTD4,
Ghost Squad Evolution and Let's Go Jungle using the same renderer/runtime.
Mac KosmicKrisp results establish bring-up and local regressions, not Quest
performance acceptance.

## Comparable runs

Use the same game assets, combat inputs, view resolution, image quality,
multiview policy, CPU culling volume, foveation mode/level, game pacing and actual runtime refresh
for baseline and candidate. Record build/APK hashes and settings alongside
results. Warm shaders/assets first, separate loading from combat, and include
heavy effects, slow motion, dual wield and longer scenes. Record thermal and
power conditions for sustained headset runs. Record actual runtime refresh;
a requested rate alone does not prove evenly paced game-frame delivery.
Do not lower image quality or skip game/render work to satisfy the comparison.

Capture interval distributions (p50/p95/p99/p99.9/max), missed deadlines and
consecutive late-frame bursts alongside throughput. Retain rare outliers in
the report and correlate them with game events, GPU work and compositor data.
Use GPU/compositor evidence and a headset visual check for display pacing.
CPU submission cadence is one diagnostic, not proof of headset delivery.

## Shared CPU boundary recorder

Both the OpenGL and Vulkan paths in `host_sdl.c` use the same opt-in recorder.
Set `LINDBERGH_FRAME_TIMINGS=/writable/path/frames.csv` and optionally:

- `LINDBERGH_TIMING_FROM=3000`, `LINDBERGH_TIMING_TO=5999`: inclusive game-frame window.
- `LINDBERGH_TIMING_SAMPLES=60000`: preallocated record capacity (maximum 1,000,000).

There are no per-frame file writes, sorting, GPU queries or additional GPU
waits. Timestamp collection is disabled by default. The game thread initializes
the recorder before the worker starts. It atomically publishes the CSV after
recording the requested final boundary, so a Quest test can collect it before
force-stop. A drained exit is the fallback for an open-ended capture; Android
force-stop does not run normal exit handlers. Use a unique output path per
run. Full buffers are labeled `truncated=1` rather than silently
pretending to cover the requested interval. The one-time file write happens
after the final measured timestamp; no measured interval includes that write.

Vulkan records after native presentation returns; desktop OpenGL records after
SDL swap returns; OpenGL/OpenXR records after `xr_frame_end` returns and before
the next frame wait. Every trace labels this as `cpu_present_return`, which
must not be confused with GPU completion or displayed-frame timing. Disable
screenshots, shader tracing, validation layers and other instrumentation during
performance runs after separate correctness validation.

```sh
python3 lindberghrecomp/tools/vulkan/frame_timings.py candidate.csv \
  --baseline opengl.csv --target-fps 60 --output comparison.json
```

The analyzer rejects missing frames, nonmonotonic clocks and differing A/B
frame windows. Its default late threshold is a 60 Hz budget plus 0.5 ms; this
is a diagnostic tolerance, not a declared hardware acceptance threshold. It
also counts intervals above 25 ms / 33.333 ms and the longest late burst.
A trace with good mean FPS can still expose a pacing regression. The report also
includes adjacent interval changes, short/long alternation runs, the slowest
rolling 60-interval window (for a 60 FPS target), and the ten worst intervals
with frame numbers. `--pacing-swing-ms` defaults to 2 ms and controls the
minimum short/long change counted in the alternation diagnostic; it is not an
acceptance threshold. An 8.333/25 ms alternating sequence averages 60 FPS but
is explicitly identified as uneven. Optional
`--from-frame` / `--to-frame` selects an explicit analysis window from the raw
capture and rejects uncaptured endpoints; retain the original trace. Use game
events to separate combat from transitions rather than removing slow frames
from combat. `LINDBERGH_VULKAN_PREPARE_TIMING=1` separately logs packet/pipeline
preparation cost and new pipeline counts for diagnosis; disable it for the
final performance comparison.

## Quest coordination

Use `python3 ~/.local/bin/quest3-lock bash /tmp/my-quest-test.sh` for the entire
session targeting serial `2G97C5ZJ0G02DQ`. Hold the exclusive lock through
installation, launch, timing/screenshots/log collection, app stop and cleanup.
Do not delete `/tmp/quest3-2G97C5ZJ0G02DQ.lock` or issue ADB commands outside
the wrapper. Status 75 means continue local work and retry later. Use an
app-writable trace destination and collect the finished file within the lock.

## Current gate

The native Quest game host/OpenXR integration is still incomplete. The shared
Android game library and isolated APK build now link with no GL/EGL imports;
first startup creates the foveated swapchain and selects offline guest shaders,
and a short session reached FOCUSED with runtime-confirmed 120 Hz before losing
focus again. This is startup evidence, not sustained gameplay. No Quest
Vulkan combat-performance claim is established yet. The recorder, its
lifecycle/error handling and the first Mac A/B runs are now verified. Retain the same measurement contract for the standalone Quest port
and add compositor/GPU instrumentation.

## First Mac measurements

M4 Pro, KosmicKrisp, 1360x768, shared worker enabled, identical auto-start/gun
settings, no screenshot readbacks inside the measured window. OpenGL was built
from this worktree too. These are single-run CPU cadence observations; no GPU
or headset-display performance conclusion follows.

Both raw initial traces span frames 3000–5999. Game-over resource unloading
starts after roughly frame 5670 and accounts for the largest 200+ ms Vulkan
outliers. The comparison retains raw traces and separately selects frames
3000–5599 for combat (2,599 intervals), including all its stalls.

| Run | Mean cadence (FPS) | p99 interval (ms) | p99.9 (ms) | Max (ms) | Over 25 ms |
| --- | ---: | ---: | ---: | ---: | ---: |
| OpenGL baseline | 60.11 | 18.55 | 23.76 | 84.16 | 2 |
| Vulkan with initially incomplete pipeline cache | 60.06 | 19.02 | 58.61 | 95.73 | 4 |
| Vulkan warm, preparation logging disabled | 60.16 | 18.56 | 23.74 | 25.31 | 1 |
| Vulkan warm, inactive-state filtering | 60.16 | 18.50 | 23.74 | 25.46 | 1 |

A separate warm diagnostic repeat logged 42 first-use pipeline objects at
frame 3244 taking 3.848 ms in total; other combat preparation batches were
smaller. Warm timing closely matching the baseline supports pipeline-cache
coverage as a major contributor to the earlier tail, but is not a complete
causality proof or a cold-run solution. Runs have different animated poses and
small timing shifts. Raw CSV/JSON/log artifacts remain in ignored
`build-vulkan-reference/` and `build-mac-vulkan-game/` directories.

The shared renderer also canonicalizes disabled blending, depth and stencil
parameters so dormant guest state does not create redundant pipeline variants.
Pixel tests verify unchanged drawing and preserve front-face semantics even
when culling is disabled. Its 5,600-frame game repeat retains full-color
world/HUD output and remains close to the baseline in the same combat window.
The final screenshot is taken after the measurement window, not inside it.

Remaining performance work includes preparing known pipeline variants before
combat on a fresh installation, GPU/compositor timing, and actual Quest A/B
runs. A populated Mac pipeline cache is not sufficient to close those gates.
Depth/stencil format and copy costs also need device measurement: the reference
pbuffer uses depth24/stencil8 while the current Vulkan target uses D32/S8.
Preserve required precision/behavior while selecting efficient supported
storage; do not assume this difference is free on Quest.

## Live-camera integration follow-up

The shared XR settings/camera foundation and guest draw integration are
committed. Mac core/runtime tests, three settings tests, eight timing tests
and Android compilation pass. Initial simulated-pose output lost the world
during final composition despite a valid world pbuffer. Depth reconstruction
and HUD-lens-only experiments did not resolve it and were reverted. An
identity-matrix control preserved two-layer storage and restored geometry.
The fix recognizes fullscreen composites of full-frame GPU copies and keeps
their guest clip space: those images already contain each eye projection.
A 3600-frame KosmicKrisp run with simulated poses now retains combat world
and HUD output without validation errors. Both eyes still travel through the
GPU-copy/array-sampling path; no effects are skipped. This is local correctness
evidence, not Quest performance acceptance.

World pbuffers initially had no density-map attachment despite a foveated
OpenXR swapchain. They now pre-create framebuffer variants for the runtime's
maps and select the acquired image's map once per frame. A separately owned,
immutable full-rate map is used before acquisition or while unfocused; scratch
rendering never borrows an unacquired runtime map. Its one-time initialization
wait is outside gameplay. Frame selection adds no allocation, upload or GPU
wait. Small offscreen targets retain the existing GL size cap.

The source-owned test alternates full-rate/coarse maps across asynchronous
stereo draws, checks pixels in both eyes, verifies handle reuse and rejects an
unprepared map. It passes on Quest 3's Adreno 740, including the production
constant-map resource helper. Evidence is retained in
build-vulkan-android-core/quest-stereo-core-20261101-010615/. Mac tests pass
with validation, explicitly skipping FDM because KosmicKrisp lacks it. Native
Android game/APK builds pass. The bounded game-host launch ended before any
native renderer log appeared, so actual game world-pass activation and combat
performance remain unverified. The app was stopped, experiment env files
restored, automation disabled and the shared device lock released. Do not
infer a graphics crash or successful game foveation from that launch.

The runtime density images are paired with their corresponding swapchain
images by [XR_FB_foveation_vulkan](https://registry.khronos.org/OpenXR/specs/1.1/man/html/XrSwapchainImageFoveationVulkanFB.html).
The density attachment retains the required DONT_CARE store operation from
[VkRenderPassFragmentDensityMapCreateInfoEXT](https://docs.vulkan.org/refpages/latest/refpages/source/VkRenderPassFragmentDensityMapCreateInfoEXT.html).
Verify the actual combat world pass and preserve image quality in matched
OpenGL/Vulkan device comparisons. Final-swapchain foveation alone is not a
performance acceptance result.

## Input integration validation boundary

The shared control policy and native pose/cabinet snapshot path now compile
and pass CPU/core tests on Mac and Quest. Simulated dual-controller Mac combat
runs exercise cabinet input and the game shot-ray bridge. They run with
validation and diagnostic logging; their FPS logs are not a performance
comparison. The Android GL game still links after sharing its controls and
bindings. No claim of actual Touch-controller gameplay, input latency or
Quest combat performance follows from these tests. Native gun/laser/sight and settings/FPS panel drawing are now implemented;
physical UI interaction and additional aiming policies still require gameplay acceptance.

## Overlay runtime-cost checks

Gun/sight geometry is resident and all overlay pipelines are prepared before
play. Billboard positions and small uniforms use the existing upload ring;
there is no per-frame descriptor or mesh allocation, shader compilation or
additional CPU/GPU wait. The renderer issues one multiview draw per primitive
and adopts the final game pass where available. In the Mac diagnostic repeat,
the additional overlay-pass count stopped increasing at 17 before frame 1200
and remained unchanged to frame 3600. Cold startup/transition passes remain in
the retained log rather than being hidden.

Adreno pixel tests also pass inside a density-map render pass. These support
the implementation's resource/submission policy, but do not establish full
Quest game foveation, visual acceptance or combat frame pacing. The next live
comparison must include the actual gun/laser settings and retain the earlier
matched-quality, thermal, GPU/compositor and frame-time requirements.

## CPU pacing diagnostic follow-up

Re-analysis of the retained Mac runs (frames 3000–5599, no new device run)
using the same 2 ms swing diagnostic reports:

| Metric | OpenGL | Vulkan, warm inactive-state filtering |
| --- | ---: | ---: |
| Adjacent interval change p95 (ms) | 2.098 | 1.979 |
| Alternating uneven pairs | 112 | 110 |
| Longest alternating run (intervals) | 4 | 5 |
| Slowest rolling 60-interval cadence (FPS) | 56.41 | 59.82 |

The source trace contains one large OpenGL outlier; these single-run results
do not establish a Vulkan speedup. Retained artifact:
`build-vulkan-reference/hotd4sp-pacing-comparison.json`. This analysis adds no
runtime instrumentation overhead. Quest GPU/compositor timing and sustained
combat acceptance remain open.

## Bounded Quest startup recheck

The isolated APK rebuilt after the shared panel extraction. Session
`build-quest-vulkan-game/quest-game-20261101-010224/` retained APK SHA256,
raw all-buffer logcat, per-PID logs, process state, activity state and cleanup
results. The real game loaded resources and the runtime reported loss of
FOCUSED followed by VISIBLE, SYNCHRONIZED, STOPPING and IDLE. Android activity
events show GuardianDialogActivity opening at 06:02:32.216 before session
stop at 06:02:32.794. At the watchdog boundary, frame 26 was paused in
`SDL_WaitEventTimeout`/`SDL_SemWait`; guest helper threads were waiting on
conditions. This is a paused startup, not a measured Vulkan combat stall.
The earlier launch with no native logs remains separate evidence.

No Guardian/tracking bypass was attempted. Only proximity-close and wake were
used. The app was stopped, both experiment env files restored, automation
disabled, test capture cleanup completed and the exclusive lock released.
The next headed measurement requires a valid tracking/boundary state, stable
XR focus and actual combat before any FPS/pacing conclusion. A future log
collector should stream all-buffer logcat from before launch: a bounded
snapshot can lose early native startup logs to buffer turnover.

## Native settings UI cost boundary

The native settings/FPS panels use persistent images, sampled descriptors and
quad geometry. The source-owned Adreno test confirms four frames draw one
panel each in the existing final render pass. A separate 45-frame UI/FPS
sequence paints/uploads the settings image once and the FPS label once, then
reuses them; both ordinary and FDM render passes pass. There are no extra
GPU waits, descriptor allocations or render passes in this path. Real user
choices still save config and may request a refresh or restart, as on GL;
those events must remain identifiable in performance captures. This does not
close the cold-pipeline, full-game FDM or sustained combat acceptance gates.

## Culling correctness before comparing speed

The matched simulated dual-controller Mac scene exposed a missing near-left
wall/ground at the unchanged cabinet culling volume. HOTD4 Special now shares
HOTD4's NN side-plane widening mechanism, restoring that visible geometry in
the tested scene without changing the render projection. Its 4x OpenXR default
is shared by GL and Vulkan; 1x remains an explicit diagnostic control.
Do not claim a speed win by using the 1x run that omits required visible objects.
The wrapper itself performs two scalar divisions and restores two words;
additional geometry still has to be measured on Quest at matched quality.
The retained validation captures are correctness evidence, not FPS acceptance.

A separate warm Mac CPU-cadence control used simulated dual controllers and
native shot rays, 1360x768, frames 3000–3599 (599 intervals per run), with
validation, screenshots, cull logging and preparation logging disabled:

| Diagnostic | Mean cadence (FPS) | p99 interval (ms) | Max (ms) | Slowest rolling 60-interval cadence (FPS) |
| --- | ---: | ---: | ---: | ---: |
| 1x, missing required geometry | 60.157 | 19.230 | 25.463 | 59.818 |
| 4x, restored geometry | 60.166 | 19.208 | 25.236 | 59.835 |

No additional CPU pacing regression is visible in this short, game-paced
pair. It does not measure uncapped throughput, GPU cost, cold-cache behavior,
thermal stability or headset display delivery. The 1x row is a diagnostic
cost control, not an acceptable visual-quality baseline. Original CSV traces,
binary/settings manifests and analysis remain in
`build-vulkan-reference/hotd4sp-dual-cull*-cadence*` and
`hotd4sp-dual-cull-cadence.json`. Sustained Quest GL/Vulkan comparisons must
both render the restored geometry and retain the existing matched-quality
and compositor/GPU requirements.

## First actual Quest guest combat diagnostic

The offscreen actual-guest build completed 3601 frames on Adreno 740 at
2064x2280 per eye with a constant full-rate density map, the same shared
renderer and restored culling volume, dual simulated controllers and native
shot rays. The settings are explicit, generated code uses the recorded `-O3`
release flags, and the startup cache came from the preceding 120-frame run.
No app/OpenXR session was used. The mix/voice clock runs in a diagnostic
pthread because SDL's Android audio thread requires Java. This is a rendering
and CPU-cadence diagnostic, not a quality-equivalent GL/XR performance baseline.

The raw combat window is frames 3000–3598 (598 intervals), ending before the
final screenshot readback. Mean CPU return cadence is 52.90 FPS, median
interval 16.57 ms, p95 20.52 ms, p99 32.12 ms, and max 983.44 ms at 3056→3057.
Other retained stalls include 159.33 ms at 3073→3074, 136.94 ms at 3152→3153,
and 95.50 ms at 3122→3123. The late burst reaches ten intervals. Later runtime
logs return to about 60 FPS; that does not cancel these stalls.

The observed spike coincides with the beginning of the heavier world interval;
pipeline/resource preparation is a hypothesis pending a prepared-cache and
preparation-timing control. The initial cache contains startup, not full combat
coverage. Do not classify the stall as loading and remove it from combat, or
claim steady 60 FPS from the later mean. Retained evidence is under
`build-quest-vulkan-offscreen/quest-fdm-game-3600/`; the installed GL/Vulkan APKs
were unchanged and private test data was removed before releasing the lock.

The diagnostic also caught a misleading FPS label: simulated input time advanced
at exactly 60 Hz regardless of host elapsed time. Native fake-controller UI now
uses a separate host readout clock, while actual OpenXR continues using its
runtime timing. Source-owned tests prevent a fast/slow simulation clock from
opening the FPS label's measurement window early. Compositor/GPU timing and
physical VR tests remain required for acceptance.


### Cold pipeline preparation confirmed on Quest

Two more whole-lock, private-tree, actual-guest runs completed 3601 frames at
2064x2280 per eye with dual simulated input and full-rate density attachments.
Both returned valid distinct stereo captures, removed their private trees and
preserved both installed HOTD4SP APK hashes. The binary and offline game/fixed
shader hashes match between these runs. Artifacts are retained under:

- `build-quest-vulkan-offscreen/quest-fdm-game-warm-3600/`
- `build-quest-vulkan-offscreen/quest-fdm-game-cold-profile-3600/`

The runner now accepts `--prepare-timing`, enabling the existing opt-in native
preparation profiler. The warm run loads the previous full-combat pipeline
cache; the cold run supplies no cache. Neither uses OpenXR, its compositor or
actual runtime foveation maps. The same frame-window numbers do not guarantee
identical game states: timed loading shifts the first heavy world frame.
These runs establish a cause, rather than a precise scene-matched speedup.

| Diagnostic, frames 3000-3598 | CPU cadence | p99 interval | Worst interval | Intervals above 33.33 ms |
| --- | ---: | ---: | ---: | ---: |
| Cold cache with prepare logging | 53.04 FPS | 32.48 ms | 977.84 ms | 5 |
| Prior full-combat cache with prepare logging | 59.15 FPS | 29.08 ms | 68.81 ms | 1 |

Cold frame 3062 creates 45 pipelines in 928.415 ms; its presentation-return
interval is 977.839 ms. Subsequent preparation batches take 124.745 ms for
four pipelines, 71.184 ms for five and 122.828 ms for four. These account for
the major combat hitches. The warm first-heavy-world batch also creates
45 in-process pipeline objects, but driver cache reuse reduces preparation
to 19.341 ms. A populated driver cache therefore helps substantially but
still permits a visible first-use spike and does not close the pacing gate.

The next shared renderer work must move known pipeline variants into loading
and retain their objects before combat. A portable pipeline-recipe catalogue
should identify offline shader content, vertex inputs, descriptor layouts,
render-pass compatibility and canonical raster state, then prepare those
recipes against the current device/driver. Opaque driver caches alone cannot
be shipped as a cross-device solution. Keep cold-install and warm-launch
controls, report unexpected combat pipeline misses, and investigate remaining
warm CPU/GPU cadence separately. Do not hide preparation time by dropping
transition frames from the acceptance window. Physical OpenXR display timing,
matched OpenGL quality/performance and sustained combat/thermal validation
remain required before claiming no Quest regression.


### Portable prewarming removes the large cold combat compilation stalls

The shared renderer now captures portable pipeline recipes and prepares and
retains their actual objects before target use. An actual HOTD4SP cold run
recorded 260 entries (61,860 bytes); a subsequent run supplied that seed with
**no initial opaque driver-cache file**. Both used 2064x2280 per eye, full-rate
FDM attachments, dual simulated gun input and the actual guest/queue/renderer.
The seed run retained 197 final-target and 63 world-pbuffer pipelines before
use. Its shader-record path reported **zero first-use creations across all
3601 completed frames**. Preparation logs show no new pipelines in the combat
window. The separate basic colored renderer creates its few pipelines during
startup and is not included in the catalogue counter.

| Frames 3000-3598, including transition | CPU cadence | p99 interval | Worst interval |
| --- | ---: | ---: | ---: |
| Cold recipe-recording run | 53.10 FPS | 33.05 ms | 984.17 ms |
| Cold cache path, portable seed | 59.74 FPS | 26.90 ms | 49.49 ms |

Artifacts: `build-quest-vulkan-offscreen/quest-recipes-record-3600/` and
`quest-recipes-seed-cold-3600/`. The seed SHA-256 is
`0510b1da0723e26b2769006cef2f8fadb3beea12e9db2915442b78ec2b4f541e`.
The seed test uses a later binary containing callback-lifetime protection;
recorded binaries, compiler flags, environment and shader hashes are in each
report. Gameplay/transition frames shift with timed loading, so this is not a
claim of a precisely identical scene or a formal backend speedup. Both runs
returned valid distinct stereo images, cleaned their private trees and
preserved installed APK hashes. Both seed-run combat images were inspected:
street geometry, textures, HUD, enemies and the two native guns remain visible.

The large compilation stalls in this observed sequence are gone. Residual
unevenness remains: eight CPU intervals exceed 25 ms and three exceed
33.33 ms, with a 49.49 ms worst interval. There is no pipeline-preparation miss
at those frames; resource preparation, GPU work and scheduling need separate
measurement. The current seed covers startup and this early combat sequence,
not every level or control path. Physical OpenXR/compositor timing, sustained
combat, thermal behavior and a matched-quality OpenGL comparison remain open.
The normal Vulkan/OpenXR APK builds with the seed, and archive inspection
confirms the exact seed and staged native library are packaged; that APK has
not been installed or physically accepted as part of this milestone.
