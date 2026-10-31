# Direct Vulkan renderer

The `work/hotd4-steam-frame` branch targets native Linux ARM64 on Steam Frame.
The renderer is being replaced; the existing Win64 experiment remains on
`work/hotd4-windows-openxr`.

## Runtime path

```
lifted HOTD4 → guest graphics HLE → render state / draw packets → Vulkan
```

The guest API remains the game's Linux/i386 GL ABI. The host renderer must
not create an OpenGL/EGL context or call gl4es, ANGLE or Zink. Interpreting
guest state and converting it to Vulkan work is still necessary; zero CPU
overhead is not a meaningful guarantee. The performance goal is to eliminate
redundant state translation, shader compilation and pipeline creation from
steady-state gameplay.

CPU recompilation, guest memory, audio, cabinet controls, gun hooks and culling
fixes remain shared. Vulkan is a shared runtime backend, not HOTD4-specific
graphics code.

## Implementation order

1. Vulkan device/queue ownership, buffered command submission, offscreen render
   targets, real pixel readback tests, and pipeline-cache persistence. This
   target must build and run independently of the GL runtime.
2. Guest state, matrices, immediate geometry, client arrays, buffers, textures,
   samplers, blend/depth/stencil/raster state and GLX drawable routing. Missing
   rendering operations must fail explicitly, rather than silently disappear.
3. Extract shader translation from GL program management. Compile the game's
   shader variants to SPIR-V in build tools and load them by content hash.
   Persist device-specific pipelines and prepare them before gameplay; report
   unexpected runtime compilation and cache misses.
4. Direct OpenXR Vulkan sessions, eye-array swapchains and multiview. Render
   the world into the eye targets, without a full-size GL-to-Vulkan copy.
   Preserve the established input actions and HOTD4 gun/reload semantics.
5. Runtime-provided `XR_FB_foveation_vulkan` density maps attached to the
   **world render passes**, including the eye-tracked configuration supported
   by Steam Frame. Keep gun/menu overlays at appropriate full resolution.
   Negotiate other Vulkan shading-rate capabilities for PC hardware separately.
6. Native ARM64 packaging and hardware validation. Compare CPU and GPU frame
   times, shader/pipeline stalls, multiview and foveation on/off at the same
   scene and eye resolution. Validate picture, aim, depth, HUD, transitions,
   reflections, audio and resume behavior before claiming a playable port or
   improved performance.

## Gates

An instance/device probe, a clear frame or successful presentation is not a
HOTD4 Vulkan port. Attaching foveation only to a final copy does not reduce
the game's fragment work and does not satisfy the foveation requirement.
Hardware foveation must be explicitly reported as active or unavailable; the
Frame launch must not quietly accept its absence.

The Vulkan core now builds and executes as native AArch64 Linux. A render test
checks distinct images in two eye-array layers produced by one multiview draw.
Buffered upload/readback and pipeline-cache rejection/reload tests also pass,
including a run with `VK_LAYER_KHRONOS_validation` and no validation messages.
The test uses Mesa lavapipe in an ARM64 Linux container on macOS. It establishes
correctness of this foundation, not headset support or GPU performance.

The direct Vulkan backend is in development; HOTD4's rendering has not yet
migrated. Runtime-provided density-map attachments are represented in the render
pass API, but the test GPU has no hardware foveation. Required foveation is
rejected explicitly on that GPU. OpenXR profile/image negotiation and Frame
hardware validation remain to be implemented.

Build this independent target (no game data or GL runtime required):

```sh
cmake -S lindberghrecomp/src/renderer/vulkan -B build-vulkan-core -G Ninja \
  -DCMAKE_BUILD_TYPE=Release
cmake --build build-vulkan-core
ctest --test-dir build-vulkan-core --output-on-failure
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
  ./build-vulkan-core/lindbergh_vulkan_selftest
```

It requires a C++17 compiler, Vulkan headers/loader, Python 3 and
`glslangValidator`. Shader compilation happens at build time. The self-test
explicitly permits software Vulkan; the normal device selector does not.

## References

- [Valve's native engine guidance](https://partner.steamgames.com/doc/steamhardware/steamframe/engines/custom)
- [Valve's Vulkan foveation integration](https://github.com/ValveSoftware/Unity/blob/main/com.valvesoftware.openxr.utils/Runtime/Features/ValveOpenXRFoveatedRenderingFeature.cs)
- [Khronos fragment density maps](https://registry.khronos.org/vulkan/specs/latest/man/html/VK_EXT_fragment_density_map.html)
- [OpenXR Vulkan foveation images](https://registry.khronos.org/OpenXR/specs/1.1/man/html/XR_FB_foveation_vulkan.html)
