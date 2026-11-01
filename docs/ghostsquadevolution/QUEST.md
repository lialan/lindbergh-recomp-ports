# Ghost Squad Evolution VR for Meta Quest

The recompiled game running standalone on a Quest 3, in stereo, aimed with a
tracked controller.

**Status:** plays on a Quest 3 at 50-60 fps from attract mode through the
missions, both eyes drawn in one pass, aimed with a tracked controller;
released as an APK (see the README). It also runs in the Android XR emulator
with the stand-in gun below.

## Build

Needs the lifted game in `games/ghostsquadevolution/generated` (see the
README), the Android SDK with NDK 27.3.13750724 and build-tools, a JDK 17+,
CMake and Ninja.

```sh
quest/deps.sh      # SDL2, gl4es (patched), OpenAL Soft, OpenXR loader -> ../deps
quest/build.sh ghostsquadevolution     # -> quest/GhostSquadEvolutionVR.apk (about 8 MB, no game data)
```

`DEPS`, `ANDROID_SDK_ROOT`, `ANDROID_NDK` and `JAVA_HOME` override the default
locations.

**One APK with everything:** give the build your `vsg_l` folder and it goes
inside the APK (about 380 MB):

```sh
quest/build.sh ghostsquadevolution --with-game "/path/to/Ghost Squad Evolution/vsg_l"
adb install -r quest/GhostSquadEvolutionVR-with-game.apk
```

On its first start the app unpacks the game into its own folder
(`/sdcard/Android/data/org.lindbergh.gse.vr/files/vsg_l`, no permissions
needed), then plays from there; later starts skip straight to the game, and an
update with different files unpacks again. The game itself is native arm64
code in `libmain.so` - nothing is emulated; the unpacked files are its data
(models, textures, sound, movies). This APK contains the game's files: it is
for your own headset, not for sharing.

## Release APKs

`.github/workflows/quest.yml` builds the APK on every push to `main`
(a workflow artifact) and publishes it as a GitHub release for each `v*` tag.
The APK carries the game's lifted code but none of its files; players copy
their own `vsg_l` to the headset, as the release notes say
([QUEST-RELEASE.md](../QUEST-RELEASE.md)). The app refuses any `vsg` other than
the one the code was lifted from, by SHA-256 (`generated/vsg.sha256`).

CI needs three secrets on this repo:

| Secret | What |
| --- | --- |
| `GSE_GENERATED_KEY` | read-only deploy key for the private repo `lialan/gse-recomp-generated`, which holds the contents of `games/ghostsquadevolution/generated` |
| `GSE_KEYSTORE_B64` | the release signing key (PKCS12, alias `gse`), base64 |
| `GSE_KEYSTORE_PASSWORD` | its password |

After relifting, push the new `generated/` files (and `vsg.sha256`) to the
private repo. To release: `git tag v0.2.0 && git push fork v0.2.0`.

Release APKs are signed with the project key, local builds with your debug
key, so moving between the two needs an uninstall (which deletes the app's
folder, game copy included).

## Install (code-only APK)

Enable developer mode on the headset, connect it with USB and accept
debugging, then give the script the game's `vsg_l` folder (the one the desktop
build runs from):

```sh
quest/install.sh ghostsquadevolution "/path/to/Ghost Squad Evolution/vsg_l"
```

This installs the APK, grants it all-files access, and copies the game (about
570 MB) to `/sdcard/GhostSquadEvolution/vsg_l`. Later updates need only
`quest/install.sh ghostsquadevolution` with no folder. Start **Ghost Squad Evolution VR** from
*Unknown Sources*.

## Controls

| Action | Controller |
| --- | --- |
| Aim and fire | Point and pull the trigger (hold for automatic fire). Either hand: pulling the other trigger moves the gun there |
| Reload | Grip, or pull the trigger while pointing off the screen (the arcade way) |
| Action button (mission level, in-game actions) | A / X on the gun hand |
| Fire mode | B / Y on the gun hand |
| Laser / dot / off | Hold the upper button (B / Y) on the other hand for a second; saved |
| Start | Click either thumbstick; with automatic coins this also inserts the coin |
| Coin | Left menu button (only needed with `coins manual`) |
| Recentre | Hold the Meta button (the game's camera follows) |

**Coins** are automatic by default: one goes in at start-up and one with every
press of Start, so Start alone begins or continues a game.

**The gun** is a low-poly SMG drawn in your hand on the controller's aim pose,
with its barrel on the aim ray. While you fire at the screen it kicks back,
flashes at the muzzle and pulses the controller ten times a second.

**The laser** runs from the muzzle to where the aim ray meets the game's screen,
ending in a dot; that point is exactly where the game aims. `dot` shows only
the dot, `off` neither.

The game's sight is drawn on a screen fixed in front of you, the size of the
arcade monitor's view; the controller's ray hits that screen exactly where the
game aims. The world itself fills the headset's whole view.

## Settings

`vr.cfg` in `/sdcard/GhostSquadEvolution/vsg_l`, one setting per line:

```
scale 1.0        game units per metre (world size)
screen 3.0       distance of the HUD screen, metres
aim 15           how far along the laser (metres) the game's shot meets it: the game fires from your head, the laser leaves your gun
resolution 2208  each eye's image height, pixels (default: Quest 3's panel, 2064x2208)
width 2064       each eye's width; 0 keeps the headset's own proportions
refresh 120      display rate to ask for: 72, 80, 90 or 120 (120 shows each of the game's 60 frames twice, evenly)
hand right       starting gun hand
laser laser      aim aid: laser, dot or off
coins auto       auto (a coin with every Start) or manual
```

`env.txt` in the same folder sets runtime options, one `NAME=value` per line,
for example `LINDBERGH_MUTE=1`. Logs: `adb shell cat /sdcard/GhostSquadEvolution/gse.log`
or, for the one-APK build,
`adb shell cat /sdcard/Android/data/org.lindbergh.gse.vr/files/gse.log`, or
`adb logcat -s gse LIBGL`.

## How it works

The desktop build already runs the game's own code natively; the port adds
three layers between it and the headset.

1. **Stereo** (`lindberghrecomp/src/runtime/stereo.c`). Every GL call the game
   makes is recorded while it draws the first eye; at the swap the recording
   is replayed for the second. Framebuffer 0 becomes the eye's image, render
   targets and viewports are scaled to the eye's resolution, and the game's
   perspective is replaced by the eye's (its pose relative to the game camera
   and its field of view). Screen content (2D, menu 3D, render targets drawn
   as sprites) goes on a virtual screen matching the game's own field of
   view, scissored to its edge; full-screen passes stay full-screen. Cinema
   bars are dropped. `LINDBERGH_STEREO=1` shows both eyes side by side on a
   desktop.
2. **GLES** (Android only). The game is a GL 2.1 fixed-function and
   ARB-assembly program. [gl4es](https://github.com/ptitSeb/gl4es) provides
   GL 2.1 on GLES 3; the runtime's own ARB-to-GLSL translator (`arbprog.c`)
   handles every assembly program, so the driver never sees one. Rectangle
   textures are sampled as 2D with per-unit normalisation.
   `quest/gl4es.patch` fixes two gl4es bugs the game hits.
3. **OpenXR** (`lindberghrecomp/src/runtime/host_xr.c`). Session,
   swapchains, refresh rate, controller actions and haptics. Each game frame
   waits for the headset's next frame, takes the predicted eye poses, and
   submits both eye images.

Audio is OpenAL Soft on OpenSL ES; the APK is SDL2's Java activity plus
`libmain.so`.

## How this follows DR-89's ports

[time-crisis-2-vr](https://github.com/DR-89/time-crisis-2-vr) and
[crisis-zone-vr](https://github.com/DR-89/crisis-zone-vr) take a native
reconstruction of the arcade game and put an OpenXR host around it. This port
has the same shape; the main difference is where the 3D comes from. Their
System 23 renderer is rewritten for VR, while this game is a GL program, so
its own GL stream is re-projected per eye.

| DR-89 port | Here |
| --- | --- |
| `upstream/` native reconstruction (namco22-decompile) | the statically recompiled game (`games/…/generated`) plus `lindberghrecomp` |
| `quest/quest_host.c`: OpenXR instance, GLES binding, swapchains, refresh rate choice, actions, haptics | `host_xr.c`, same structure (Android create-instance and GLES-enable extensions, FB refresh-rate extension, Touch controller profile) |
| `quest/tc2_scene.c` / `tc2_gl.c`: arcade geometry drawn from tracked stereo viewpoints | `stereo.c`: the game's own GL frame recorded and replayed per eye with the eye's projection |
| Ray from the controller to the arcade screen coordinates (`qvr_aim`) | `stereo_ray_to_screen()`, fed to the cabinet's gun position |
| Flat HUD layer on the arcade camera plane | the virtual HUD screen, matched to the game's field of view |
| Cinematic black bars removed in VR | `letterbox_bar()` |
| sRGB swapchain written raw | the same: `GL_SRGB8_ALPHA8` with sRGB writes off |
| Manifest: VR categories, OpenXR permissions and broker queries, `quest3` devices | `quest/ghostsquadevolution/src/main/AndroidManifest.xml` |
| `tools/build.py`, `Install-Quest.ps1`, `Export-Quest-Diagnostics.ps1` | `quest/build.sh`, `quest/install.sh`, `gse.log` / `env.txt` |
| ROMs bundled or imported | game files copied to shared storage; none ship in the APK |

Also following them: a weapon in the hand (here a low-poly SMG built in code,
`xr_overlay.c`) with recoil and haptics, and a laser aim aid cycled from the
off hand. Not carried over yet: the in-headset options panel, tracer shots,
input recording and replay. Ghost Squad has no cover, so there is no cover
mode.

## Testing without controllers

`LINDBERGH_XR_FAKE_GUN=1` (in `env.txt`) holds a gun at the right hip when no
controller is tracked: it sweeps across the screen, fires in half-second
bursts, and for one second in six points at the floor with the trigger held.
With it the emulator shows the gun, laser, recoil and flash, and the game
reloading from the off-screen trigger (the cabinet sees the reload bit, 0x20,
and the ammunition bar refills).

## Debugging on a GL you cannot watch

`LINDBERGH_RT_DUMP=<frame>` writes every render target as the first eye left
it that frame (`rt_*.ppm` in the game folder), and logs the centre pixel after
every draw. Running the same frame on the Mac and on the emulator and
comparing the two logs finds the first draw that differs. That is how the
white-scene bug here was traced to gl4es' `glIsEnabled`.

`LINDBERGH_FRAMEMAP=<frame>` lists one frame's GL calls with what each draw
had bound. `LINDBERGH_SCENE_STATS=1` reports world draws per frame, which is
what menu detection would go by (`LINDBERGH_MENU_DRAWS=<n>`; off by default,
as sparse gameplay scenes tripped it and flattened the world onto the screen).

Getting to a scene for testing: `LINDBERGH_ROUTE=<n>` puts the player on
route `n` a second into a mission (`LINDBERGH_ROUTE_LOG=1` reports route
changes; the plane's routes are 20-38, its cargo hold 34-38), and
`LINDBERGH_PATHFRAME=<f>` places them `f` frames along it (negative: from its
end). `LINDBERGH_GOD=1` makes the player take no damage.
`LINDBERGH_SHIMMER=<strength>` turns on the plane finale's air shimmer
(`3` is the finale's) in whatever scene is running.

On the headset itself, the game folder in the app's own storage is not
writable over adb, but the folder above it is: put `env.txt` (and `vr.cfg`)
in `/sdcard/Android/data/org.lindbergh.gse.vr/files/` and they are read from
there too.

## Performance

Gameplay holds 60 fps on a Quest 3 (59.2-60 in every five-second window of
a mission once it is running); the dips left are the loads at a mission's
start. The game is limited by one CPU thread: it makes 15-25 thousand GL
calls a frame, each translated by gl4es. What made it fit:

- **Both eyes in one pass** (`GL_OVR_multiview2`, multiview.c in
  quest/gl4es.patch). Every shader gl4es builds is rewritten as GLSL ES 3.00
  for two views; render targets are two-layer texture arrays; a uniform
  block holds the per-view matrices. The second eye is no longer recorded
  and replayed. `LINDBERGH_MULTIVIEW=0` goes back to replaying it.
- **The view matrices are written ahead**, into a ring of slots through an
  unsynchronised mapping. Rewriting the block with glBufferSubData made the
  driver wait on every 2D draw (200 us each).
- **DXT textures go to the driver as they are**: Adreno reads S3TC, and
  decoding them on the CPU stalled every level load by half a second.
- **gl4es copies uniforms to the program variant it draws with only when
  they changed**, and copies an array in one call, not one per element.
- **Shader programs are kept on disk** (`files/shadercache`): from the
  second run a program loads in about 1 ms instead of 30-110 ms.
- **Sustained high CPU clocks** through `XR_EXT_performance_settings`.

A draw now costs about 16 us: gl4es' program and uniform setup ~6 us, the
driver's own draw ~7.5 us, textures ~1 us; the game's other GL calls about
0.16 us each.

Measuring: `LINDBERGH_GLPROF=1` logs GL time per frame, the costliest
imports, the time inside gl4es' draws, and what any frame over 40 ms spent
its time on. The `[perf]` line splits a frame into the game's own work,
submitting and waiting for the headset. `LINDBERGH_LATENCY=1` times every
program build; `LIBGL_MV_CHECK=1` reports GL errors around draws and what
multiview binds; `LINDBERGH_RT_DUMP=<frame>` writes every render target
(the first view's layer).

## Known limitations

- Controllers, aim and world scale are only lightly tested on hardware.
- A zoomed view (the sniper scope, close-up cutscene shots) is drawn on the
  virtual screen; `LINDBERGH_ZOOM_LENS` (8, held for 6 frames) is the lens it
  takes for one. The game's camera zooms on targets reach about 6, so a lower
  value flattens the world during those moves.
- World scale (`scale`) is a guess of one game unit per metre; it needs
  measuring in the headset, as the TC2 port did.
- Each game frame is one headset frame: the game paces itself at 60 Hz, so
  at the default 120 Hz each frame is shown exactly twice.
- Menu detection is off: menu 3D models sit at their true depth rather than
  on the screen beside the 2D panels.
