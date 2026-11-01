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
multiview policy, foveation mode/level, game pacing and actual runtime refresh
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
A trace with good mean FPS can still expose a pacing regression. Optional
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

The native Quest game host/OpenXR integration is still incomplete. No Quest
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
