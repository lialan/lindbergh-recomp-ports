Sega Lindbergh arcade games in VR, for Meta Quest 3, Quest 3S and Quest Pro:

| Game | APK |
| --- | --- |
| Ghost Squad Evolution | `GhostSquadEvolutionVR-<version>-quest3.apk` |
| The House of the Dead 4 | `HouseOfTheDead4VR-<version>-quest3.apk` |
| The House of the Dead 4 Special | `HouseOfTheDead4SpecialVR-<version>-quest3.apk` |

Let's Go Jungle! is not part of this release: its latest build is
[v0.2.7](https://github.com/lialan/lindbergh-recomp-ports/releases/tag/v0.2.7)
(experimental, a bit buggy).

**The games themselves are not included.** Each APK holds a port: the game's
code recompiled to run natively on the headset, the VR host, and its
libraries. You need your own copy of the arcade game.

## New in v0.4.0

- **Native Vulkan.** Ghost Squad Evolution, The House of the Dead 4 and The
  House of the Dead 4 Special now draw with Vulkan on the headset, instead of
  OpenGL translated by gl4es. Each game's shaders are compiled ahead of time
  and its pipelines prepared before play, so scenes no longer stutter while
  shaders compile.
- **Frame rate.** The House of the Dead 4 runs at a steady 60 fps on the
  Quest 3. Ghost Squad Evolution is much faster than in v0.2.7; its heaviest
  scenes can still dip below 60.
- **First start:** a *Compiling shaders* box shows for a few seconds while
  the game's pipelines are built; later starts skip it. A shader program the
  game builds that the packaged set lacks is compiled on the headset the
  first time it is needed (a brief hitch, once), so nothing is left undrawn.
- **Foveation:** a new setting (Off, Low, Medium, High; High by default)
  renders the edges of your view at lower detail, for frame rate.
- **Show stats** (it was *Show FPS*): a panel at the top right with the frame
  rate, CPU and GPU load, and memory.
- **Menus and the sniping scope:** menus, and a held sniping scope in Ghost
  Squad Evolution, are the arcade's own picture on the screen in front of
  you, with nothing of the game outside it, as in the OpenGL builds.
- **Ghost Squad Evolution fixes:** missing ground and other polygons in
  Mission 3; voice lines play (one could crash the game); fewer hitches as a
  mission starts.
- Installing over v0.2.7 keeps your settings and saved cabinet data (same
  package and signing keys). As before, bring your own game files: the APKs
  contain no game data.

## New in v0.2.7

- **Smoother frame rate.** In The House of the Dead 4, gameplay now runs at a
  steady 60 fps on the Quest 3. What changed: GL state calls that would
  change nothing are skipped instead of sent to the GPU; the queue that
  carries GL calls to the graphics thread is lighter; the games' SIMD (SSE)
  code is now compiled to real ARM vector code; Let's Go Jungle! no longer
  stalls waiting on the graphics thread; and some framebuffer copies stay on
  the GPU instead of being read back to the CPU. All four games are
  re-translated with the new lifter.
- **Show FPS:** a new option in the headset's settings panel that shows the
  frame rate.
- **Fixes:**
  - The House of the Dead 4 Special could freeze at the start (two threads
    got the same thread id).
  - Dual wielding: player 2's shots, reload and hit splash now follow player
    2's own gun in The House of the Dead 4 and The House of the Dead 4
    Special, and player 2 joins with their first shot.
- Let's Go Jungle! is still experimental (a bit buggy).
- Installing over v0.2.6 keeps your settings (same signing keys). As before,
  bring your own game files: the APKs contain no game data.

## Install

1. Enable developer mode on the headset and install the APK with
   [SideQuest](https://sidequestvr.com) or `adb install -r <apk>`.
2. Copy the game to the headset's shared storage (over USB, allow file
   access in the headset: *Internal shared storage*; SideQuest's file browser
   works too):
   - **Ghost Squad Evolution:** your whole `vsg_l` folder as
     `GhostSquadEvolution/vsg_l`, so the executable is at
     `/sdcard/GhostSquadEvolution/vsg_l/vsg`
     (`adb push vsg_l /sdcard/GhostSquadEvolution/`).
   - **The House of the Dead 4:** the game's `elf`, `fs` and `drv` folders
     into `HouseOfTheDead4`, so the executable is at
     `/sdcard/HouseOfTheDead4/elf/hod4M.elf`
     (`adb push elf fs drv /sdcard/HouseOfTheDead4/`).
   - **Let's Go Jungle!:** `lgj_final` and its `data`, `shader` and
     `extraShader` folders into `LetsGoJungle`
     (`adb push lgj_final data shader extraShader /sdcard/LetsGoJungle/`).
   - **The House of the Dead 4 Special:** the game's `elf` and `fs` folders
     into `HouseOfTheDead4Special`, so the executable is at
     `/sdcard/HouseOfTheDead4Special/elf/hod4M.elf`
     (`adb push elf fs /sdcard/HouseOfTheDead4Special/`).
3. Start the game from *Unknown Sources*. The first time it opens the system
   screen to allow access to all files: allow it, then start the app again.
   (Or grant it from a computer:
   `adb shell appops set --uid <package> MANAGE_EXTERNAL_STORAGE allow`, with
   `org.lindbergh.gse.vr`, `org.lindbergh.hotd4.vr`, `org.lindbergh.lgj.vr`
   or `org.lindbergh.hotd4sp.vr`.)

Each port only runs the exact game version it was built from:

| Game | Executable | SHA-256 |
| --- | --- | --- |
| Ghost Squad Evolution | `vsg` | `2966eed7254b485bd086215df226240ae97464132714a1a1504c52ba2a9e4815` |
| The House of the Dead 4 | `elf/hod4M.elf` | `72fdd45830acd9317ec1e4f97de35a270c94746068fdaf827381c91bb47aa296` |
| Let's Go Jungle! | `lgj_final` | `3edbf6a4c5c97cc37e0ff353cacd265360da42c3b5efa4d1370dfa5e63f58ec9` |
| The House of the Dead 4 Special | `elf/hod4M.elf` | `b84c70d9940d5f5fa7d287fd8c6b050444fdcbc2fd742d3afc74a1099bbec5fe` |

If the game is missing or a different version, the app closes and explains
why in `Android/data/<package>/files/HOW-TO-ADD-THE-GAME.txt`.

Updates install over the previous version and keep the game files, settings
and saved cabinet data.

## Play

Trigger fires, grip reloads (or pull the trigger pointing off the screen), a
thumbstick click is Start, and coins are automatic; in The House of the Dead 4
Special, shake the gun to reload. The left controller's
menu button opens the settings panel: sights, laser, gun model, gun hand,
dual wield, show stats, resolution, display rate, foveation, recentring, and
Reset game. With dual
wield on, the other hand is player 2, and each hand's thumbstick click is its
player's Start.

More: [Ghost Squad Evolution](https://github.com/lialan/lindbergh-recomp-ports/blob/main/docs/ghostsquadevolution/QUEST.md),
[The House of the Dead 4](https://github.com/lialan/lindbergh-recomp-ports/blob/main/docs/hotd4/QUEST.md),
[Let's Go Jungle!](https://github.com/lialan/lindbergh-recomp-ports/blob/main/docs/lgj/QUEST.md),
[The House of the Dead 4 Special](https://github.com/lialan/lindbergh-recomp-ports/blob/main/docs/hotd4sp/QUEST.md).
