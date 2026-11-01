Steam Frame build (native AArch64 Linux, Vulkan + OpenXR)
=========================================================

What is here
  <game>            the recompiled game, linked against the Steam Linux Runtime 4
  vulkan/           its offline shader archives (game.lvsp, fixed.lvsp) and,
                    if present, the pipeline seed (pipelines.lvpr)
  lib/              SDL2, OpenAL Soft and the OpenXR loader, used only when the
                    system lacks them
  launch.sh         the launcher
  SHA256SUMS        checksums, and the SHA-256 of the executable the code was
                    lifted from

No game data is included. Copy your own game folder (the one holding the
executable named in launch.sh) to the headset.

Run
  1. Copy this folder and your game folder to the Frame (Desktop Mode).
  2. ./launch.sh "/path/to/the game's folder"   (remembered in game-dir.txt)
  3. To start it from the headset: Steam > Add a Non-Steam Game > launch.sh.
     If it fails to find SDL2/OpenAL or misbehaves, set its compatibility
     tool to "Steam Linux Runtime 4.0", which it was built against.

It needs SteamVR's OpenXR runtime with XR_KHR_vulkan_enable2 and the FB
foveation extensions (XR_FB_foveation, _configuration, _vulkan,
XR_FB_swapchain_update_state); it says which is missing and stops otherwise.
Log of the last run: <game>.log beside launch.sh.
