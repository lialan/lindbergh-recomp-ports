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
`glslangValidator`, SPIRV-Tools and `spirv-cross`. Shader compilation happens at build time. The self-test
explicitly permits software Vulkan; the normal device selector does not.

## References

- [Valve's native engine guidance](https://partner.steamgames.com/doc/steamhardware/steamframe/engines/custom)
- [Valve's Vulkan foveation integration](https://github.com/ValveSoftware/Unity/blob/main/com.valvesoftware.openxr.utils/Runtime/Features/ValveOpenXRFoveatedRenderingFeature.cs)
- [Khronos fragment density maps](https://registry.khronos.org/vulkan/specs/latest/man/html/VK_EXT_fragment_density_map.html)
- [OpenXR Vulkan foveation images](https://registry.khronos.org/OpenXR/specs/1.1/man/html/XR_FB_foveation_vulkan.html)

## Offline shader conversion

The build tool `lindberghrecomp/tools/vulkan/compile_shaders.py` consumes exact
linked vertex/fragment pairs and attribute bindings from a development capture.
Each successful link gets immutable source snapshots, including when a shared
shader object is edited before a later link.
`tools/vulkan/capture-gl-macos.c` provides that capture for the existing macOS
reference renderer; it is never linked into the Vulkan runtime. Captures and
compiled game shaders remain local build artifacts.

The bounded HOTD4 boot/intro reference produced 323 successful program links
(310 unique source/binding pairs). All compile to Vulkan 1.1 SPIR-V, pass
`spirv-val`, and agree on reflected uniform-block layouts across stages.
This is sampled shader coverage, not full gameplay coverage. The converter
moves legacy matrices/material/light/fog state into uniform buffers, preserves
explicit vertex bindings, and adds multiview reprojection and clip conversion.
A source-owned GLSL 1.20 fixture is converted by the same tool during the build;
its front-face color and stereo output are checked with actual Vulkan readback.

Guest matrix stacks and immediate-mode primitive assembly now produce indexed
Vulkan geometry with reused CPU storage. Guest vertex-array planning now
captures VBO bindings at pointer-definition time, binds static geometry without
another CPU upload, and uploads client arrays in their original native formats.
Disabled arrays use current attribute values. Tests cover nonzero vertex
offsets, normalized byte colors and guest memory at the 32-bit address limit.
Unsupported fetch formats and out-of-bounds ranges fail explicitly.

Uniform descriptors are allocated/written once per buffered frame slot; shader
state changes use aligned dynamic offsets into persistent storage. A converted
GLSL fixture passes pixel checks across 12 asynchronous submissions. Textured
stereo checks also pass for GPU-resident vertex/index buffers, 16-bit indices,
texture orientation, mip selection and immutable material descriptors. Texture
uploads transition individual mip/layer subresources explicitly. BC textures
require enabled device support; asset conversion for GPUs without that support
remains pending.

These components execute directly on Vulkan without host GL calls. The game
still uses its existing renderer until complete state/texture/GLX semantics and
guest HLE wiring are integrated. OpenXR Vulkan
and runtime foveation negotiation remain pending.

## Shader archives and runtime uniform state

`lindberghrecomp/tools/vulkan/pack_shaders.py` packages validated modules and
reflection into a versioned `.lvsp` archive. It verifies module hashes before
packaging and writes the result atomically. `ShaderPack` loads this format using
only the C++ standard library. Program selection uses SHA-256 source identities
and captured active attribute bindings; there is no runtime GLSL compiler or
silent fallback for an unknown variant. The normal Vulkan driver still builds
native pipelines during explicit preparation; its device-specific cache is
persisted separately.

The 310 unique captured programs produce a 7,424,808-byte archive. The native
ARM64 test loads all pairs, selects them by source/bindings, reads 38,392 uniform
fields and creates all shader modules under Vulkan validation. This checks
archive loading, not gameplay with those shaders. The source-owned rendering
fixture now loads its modules and reflected guest uniforms through the archive.
Uniform writes preserve std140 vector/matrix/array padding and transpose
semantics, and unchanged values do not advance the data version.

Guest shader-source normalization and link-time compatibility repairs still
need to be connected to these captured source identities. The standalone pack
lookup is not yet the game's `glLinkProgram` implementation.

After compiling a local capture, package and inspect it with:

```sh
python3 lindberghrecomp/tools/vulkan/pack_shaders.py build-vulkan-shaders \
  build-vulkan-shaders/hotd4.lvsp
VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation \
  ./build-vulkan-core/lindbergh_vulkan_selftest build-vulkan-shaders/hotd4.lvsp
```

The ordinary CTest test uses only source-owned fixtures and needs no game data.
