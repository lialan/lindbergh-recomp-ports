# Shared direct Vulkan runtime

Development continues on `work/hotd4-steam-frame`; the branch name is
historical. The game order is HOTD4 Special on Quest 3, HOTD4, Ghost Squad
Evolution, then Let's Go Jungle. Zink is paused separately on
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
- HOTD4 Special runs 12 requested native Vulkan frames with the worker (13
  observed), with no validation messages or shutdown failure. A longer run
  stops explicitly on a missing offline program variant while loading
  `GetBrightArea.dat`; that gate remains open.
- MoltenVK validation self-tests pass, including stereo pixels, asynchronous
  uniform snapshots, persistent vertex/index buffers, texture sampling,
  bottom-origin render targets and GPU depth/color copies. The shared default
  OpenGL runtime self-test still passes.

These are Mac/core bring-up results, not a playable Quest port or a 60 fps
claim. Direct Vulkan Android host/JNI integration, OpenXR world/overlay
integration, shared input wiring, asset conversion, full game-call coverage,
foveation and on-device acceptance remain pending. Target retirement/resizing
and pipeline preparation also need complete game-path coverage.

## Device-free work while the headset is unavailable

The user has asked that the headset remain untouched. Continue source work,
offline captures/conversion, Mac Vulkan pixel/reference checks and Android
builds. Do not discover, install, launch or inspect the headset until the user
makes it available again. Device validation remains a separate acceptance step.

Next, collect missing shader identities and bindings without adding a runtime
compiler, extend the source-owned render tests, and advance HOTD4 Special's
native draw/resource path before integrating the standalone Android host.
