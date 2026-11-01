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
- HOTD4 Special completes 600 requested frames (601 observed) through
  KosmicKrisp with the shared worker and Vulkan validation enabled. A captured
  frame shows the ride-reset instruction panel. This is startup/UI evidence;
  scripted gameplay and reference-image acceptance remain in progress.
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
- KosmicKrisp validation self-tests pass, including stereo pixels, asynchronous
  uniform snapshots, persistent vertex/index buffers, texture sampling,
  bottom-origin render targets and GPU depth/color copies. The shared default
  OpenGL runtime self-test still passes.

These are Mac/core bring-up results, not a playable Quest port or a 60 fps
claim. The standalone Android Vulkan core pixel suite also passed in the Android XR
emulator before the macOS-first priority was clarified. An Android loader and
source-owned NativeActivity probe are compiled and packaged, but the probe has
not been installed or run. The emulator has been stopped. Game host/JNI
integration, OpenXR world/overlay
integration, shared input wiring, asset conversion, full game-call coverage,
foveation and on-device acceptance remain pending. Target retirement/resizing
and pipeline preparation also need complete game-path coverage.

## Device-free work while the headset is unavailable

The user has asked that the headset remain untouched. Continue source work,
offline captures/conversion and Mac Vulkan pixel/reference checks first. Do not discover, install, launch or inspect the headset until the user
makes it available again. Device validation remains a separate acceptance step.

Run the shared Mac suite with `scripts/test-vulkan-macos.sh`. It selects
`/opt/homebrew/share/vulkan/icd.d/kosmickrisp_mesa_icd.aarch64.json` by default,
prints the selected ICD and enables Vulkan validation. `VK_DRIVER_FILES` may
explicitly select another installed path; there is no silent driver fallback.

Next, reach gameplay with scripted inputs, collect additional offline shader
variants if required, and compare the game image with OpenGL. Keep the native
draw/resource mechanisms common before integrating the standalone Android host.
