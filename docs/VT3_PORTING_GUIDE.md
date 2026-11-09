# Virtua Tennis 3 (Sega Lindbergh -> macOS & Meta Quest 3) Porting & Research Guide

This document contains the complete technical findings, workspace layout, binary reverse-engineering analysis, and step-by-step implementation guide for porting **Virtua Tennis 3** (*Power Smash 3*, Lindbergh Yellow, ID: `SBKX` / `DVP-0005`) to **macOS** and **Meta Quest 3** using [`lialan/lindbergh-recomp-ports`](https://github.com/lialan/lindbergh-recomp-ports) and its `lindberghrecomp` static recompilation toolkit.

---

## 1. Current Workspace & Extracted Files Layout

All archives, extracted game files, and the recompilation repository are placed under `<workspace>/`:

| Path | Description |
| :--- | :--- |
| `<workspace>/lindbergh-recomp-ports/` | Cloned `lialan/lindbergh-recomp-ports` repository with initialized submodules (`lindberghrecomp` and `lindberghrecomp/pcrecomp`). |
| `<workspace>/Virtua Tennis 3.7z` | Original archive containing `vt3.bin` (1.97 GB Linux rev 1.0 ext2 filesystem image). |
| `<workspace>/vt3/vt3.bin` | Unpacked raw ext2 filesystem image for *Virtua Tennis 3*. |
| `<workspace>/vt3/extracted/disk0/` | Extracted game root directory (`TEA_DIR`). Contains `vt3_Lindbergh/`, `shader/`, `lib/`, `game`, and `vt3rc`. |
| `<workspace>/House of the Dead 4.7z` | Original archive for *The House of the Dead 4* (reference game already supported by `lindbergh-recomp-ports`). |
| `<workspace>/hotd4/extracted/disk0/` | Extracted reference game root directory (`elf/`, `fs/`, `drv/`) ready to test `build-macos.sh hotd4`. |

### ⚠️ Note on `vt3.bin` Ext2 Extraction
When `7z x vt3.bin` unpacked `<workspace>/vt3/vt3.bin`, 7-Zip's built-in ext2 parser encountered `Unsupported Method` / `Data Error` on **11 player animation `.efo` files** (specifically `P_M_ANC_*` and `P_M_BLA_*` under `disk0/vt3_Lindbergh/resource/model/player/`, leaving them 0 bytes) because the ext2 image uses sparse/extended blocks that old p7zip misinterprets.
- **How to cleanly extract those 11 `.efo` files:** Install `e2fsprogs` (`brew install e2fsprogs`) and use:
  ```bash
  /opt/homebrew/opt/e2fsprogs/sbin/debugfs -R "rdump /disk0 <workspace>/vt3/extracted" <workspace>/vt3/vt3.bin
  ```
  This ensures no player models are 0-byte truncated during matches involving Mario Ancic or James Blake.

---

## 2. Virtua Tennis 3 Binary & Launch Architecture Analysis

### 2.1 How the Cabinet Boots VT3
From `<workspace>/vt3/extracted/disk0/game` and `vt3rc`:
1. Working directory at launch: **`disk0/vt3_Lindbergh/`** (the game opens `resource/...` relative to `vt3_Lindbergh/`).
2. Environment variables set by `game`:
   - `TEA_DIR=/home/disk0/` (relative to `vt3_Lindbergh/`, this is **`..`** — where `../shader` and `../lib` sit!).
   - `LD_LIBRARY_PATH` includes `../lib` (`libCg.so`, `libCgGL.so`, `libCgFX.so`, `libCgFXGL.so`).
   - `GLIBCPP_FORCE_NEW=1`

### 2.2 ELF Executables Comparison (`with debug_info, not stripped`)
Inside `disk0/vt3_Lindbergh/`, there are four main game executables (all **6,543,267 bytes**, 32-bit x86 SYSV ELF, dynamically linked, **not stripped**, with full C++ symbols and DWARF debug info!):

| Executable | SHA-256 | Exact Binary Differences |
| :--- | :--- | :--- |
| `vt3_Lindbergh_VGA` | `c10d3a572be39996516fa513ab51a810266bcdd284c55d244094997bcebb3b5d` | Original unmodified binary. Defaults to **640x480** unless DIP switch bits (`0xE0`) are set; skips the widescreen override via `jmp 0x8175b23` at `0x08175b03`. |
| `vt3_Lindbergh_HD` | `4bc1ff1735b382f9dd6246656cdeaa3260193283aa494d3e745ad83655d3c9aa` | Patched at 2 locations:<br>1. `0x08175b03` (`tennis::initializeSystem`): `eb 1e` -> `90 90` (NOPs out the jump so it unconditionally writes width `0x550` = **1360**, height `0x300` = **768**, mode `2` to `0x088bbe68`/`0x088bbe6c`).<br>2. `0x0831c63c` (`amDipswGetData`): forces DIP switch return byte to `0xE0`. |
| `vt3_Lindbergh_FULLHD` / `vt3_Lindbergh` | `556729756c9160c4a5b1c6ed0c2674d7363a936b4ca91f5e2661494a55eb66a2` | Same as `vt3_Lindbergh_HD`, except the immediate constants at `0x08175b0b` and `0x08175b15` are patched from `1360x768` (`0x550 x 0x300`) to `1920x1080` (`0x780 x 0x438`). |

> **Recommendation:** Use **`vt3_Lindbergh_HD`** because `1360x768` is the genuine Lindbergh Yellow widescreen resolution that the game's 2D HUD and camera aspect ratio (`mode 2`) were authored for, matching *The House of the Dead 4* and *Let's Go Jungle!* in `lindbergh-recomp-ports`.

### 2.3 Dynamic Library Dependencies (`DT_NEEDED`)
Running `objdump -p` on `vt3_Lindbergh_HD` shows:
- `libGLU.so.1`, `libGL.so.1` (handled by `lindberghrecomp` `hle_gl.c` / `gen_gl_thunks.py` / `vulkan_guest.cpp`)
- `libCg.so`, `libCgGL.so` (lifted via `solib.py` and HLE in `hle_cg.c`, detailed below)
- `libpthread.so.0`, `libc.so.6`, `libm.so.6`, `libstdc++.so.5`, `libgcc_s.so.1` (handled by `hle_pthread.c`, `hle_libc.c`, `hle_cxx.c`)
- `libX11.so.6`, `libXext.so.6` (handled by `hle_window.c`, `hle_glx_posix.c`, `hle_vidmode.c`)
- `libsegaapi.so`, `libkswapapi.so` (handled by `hle_segaapi.c`, `hle_sega.c`)

---

## 3. Critical Architectural Discoveries & Solutions

### 3.1 VT3's Use of NVIDIA Cg & Why `libCgGL.so` Must NOT Be Lifted

VT3 imports only **15 `cg*` functions** total (`games/vt3/generated/recomp_imports.h` lines 136-150):
- **12 from `libCg.so`:** `cgCompileProgram`, `cgCreateContext`, `cgCreateProgram`, `cgDestroyContext`, `cgDestroyProgram`, `cgGetError`, `cgGetErrorString`, `cgGetProfileString`, `cgGetProgramString`, `cgIsContext`, `cgIsProgramCompiled`, `cgSetErrorCallback`.
- **3 from `libCgGL.so`:** `cgGLGetLatestProfile`, `cgGLIsProfileSupported`, `cgGLSetOptimalOptions`.

#### VT3's In-Memory Shader Compilation Pipeline:
VT3 does **NOT** use `libCgGL.so` to load or bind shaders (`cgGLLoadProgram`, `cgGLBindProgram`, etc. are not imported). Instead, VT3 uses `libCg.so` purely as an **in-memory text-to-text compiler**:
1. Calls `cgCreateProgram(ctx, CG_SOURCE, src, profile, entry, args)`
2. Calls `cgGetProgramString(prog, CG_COMPILED_PROGRAM)` (`0x100a`) to get the compiled `!!ARBvp1.0` / `!!ARBfp1.0` (`OPTION NV_vertex_program3` / `OPTION NV_fragment_program2`) assembly string
3. Parses the `#var` comments in that compiled assembly string (via `_sShaderConstantTable::parseAsm` at `0x082dfae6` and `TScene::Shader::getParameter` at `0x081ae740`) to map Cg uniform names to `program.local[N]` / `program.env[N]` registers and texture sampler units!
4. Uploads the compiled assembly string to OpenGL via `glProgramStringARB`, which `lindberghrecomp/src/runtime/arbprog.c` translates to GLSL!

#### Why `libCgGL.so` must be answered by HLE:
`libCgGL.so`'s `cgGLGetLatestProfile` (`0xb401da4c`) and `cgGLIsProfileSupported` (`0xb401f968`) query the host's `glGetString(GL_EXTENSIONS)` for `GL_NV_vertex_program3` and `GL_NV_fragment_program2`. Because macOS OpenGL 2.1 Compatibility mode does not advertise NVIDIA-proprietary extensions (even though `arbprog.c` translates them in software), `libCgGL.so` would return `0` (unsupported) on macOS!

**Solution:**
- Keep `SOLIBS="lib/libCg.so"` in `games/vt3/game.conf` (excluding `libCgGL.so`).
- Implement the 3 `cgGL*` functions in `lindberghrecomp/src/runtime/hle_cg.c`, always registered even when `libCg.so` is loaded via `solib`:
  - `cgGLIsProfileSupported(profile)` -> returns `1`
  - `cgGLGetLatestProfile(type)` -> returns `0x1b59` (`7001`, `CG_PROFILE_VP40`) when `type == 8` (`CG_GL_VERTEX`), and `0x1807` (`6151`, `CG_PROFILE_FP40`) when `type == 9` (`CG_GL_FRAGMENT`)
  - `cgGLSetOptimalOptions(profile)` -> no-op, returns `0`

---

### 3.2 Lifting `libCg.so` via `solib.py` & Disassembler Speedup

1. `disk0/lib/libCg.so` has no `.symtab` (only `.dynsym` with 282 exported symbols), while it actually contains **13,221 functions** in `.text`.
2. In `libCg.so`, `.init` is at `0x32840..0x32858`, `.plt` is at `0x32858..0x33008`, `.text` is at `0x33010..0x18f400`, and `.fini` is at `0x18f400..0x18f41e`.
3. In `lindberghrecomp/pcrecomp/tools/disasm/disasm32.py`:
   - Added GCC prologue `b'\x55\x89\xE5'` alongside MSVC `b'\x55\x8B\xEC'`.
   - Chunked `disassemble_at` into 128-byte windows, avoiding decoding 8,192 bytes per basic block. This sped up function discovery by ~50x (13,221 functions discovered in ~25 seconds!).
4. In `lindberghrecomp/tools/recomp/solib.py`:
   - Updated `Lib.functions()` to run `Disassembler.find_functions` over `.text` (`[self.base + text.addr, self.base + text.addr + text.size)`), seeded with `.dynsym` functions, `.ctors`/`.dtors` entries, and call targets from `.init`/`.fini`.
   - Relocated and lifted 13,153 functions across 33 C translation units (`recomp_solib_funcs_0000.c` .. `recomp_solib_funcs_0032.c`)!

---

### 3.3 GCC 3.3 `libstdc++.so.5` Struct Layouts in Lifted Code

From VT3's lifted code in `recomp_funcs_0037.c` (`L_082DFAE6`: `_sShaderConstantTable::parseAsm`), VT3 constructs a stack-allocated `std::istringstream` at `[ebp - 0x108]`:
- `base + 0x00`: `istringstream` vptr (`0x84E795Cu`, virtual base offset to `basic_ios` at `vptr - 0xc` is `0x5c`).
- `base + 0x04`: `streamsize _M_gcount` (`0`).
- `base + 0x08`: `std::basic_stringbuf` subobject (`size = 0x54`):
  - `+0x00`: `basic_streambuf` vptr
  - `+0x04`: `char* _M_buf`
  - `+0x08`: `size_t _M_buf_size`
  - `+0x14`: `char* _M_in_beg` (`eback()`)
  - `+0x18`: `char* _M_in_cur` (`gptr()`)
  - `+0x1c`: `char* _M_in_end` (`egptr()`)
  - `+0x20`: `char* _M_out_beg` (`pbase()`)
  - `+0x24`: `char* _M_out_cur` (`pptr()`)
  - `+0x28`: `char* _M_out_end` (`epptr()`)
  - `+0x2c`: `ios_base::openmode _M_mode`
  - `+0x50` (`base + 0x58`): `std::string _M_string` (pointer to guest string data).
- `base + 0x5c`: `std::basic_ios` virtual base subobject:
  - `+0x00`: `basic_ios` vptr
  - `+0x14`: `_M_streambuf_state` (`_Ios_Iostate`: `goodbit = 0`, `badbit = 1`, `eofbit = 2`, `failbit = 4`)
  - `+0x18`: `basic_streambuf* _M_streambuf`

All HLE stream and string implementations in `lindberghrecomp/src/runtime/hle_cxx.c` match these exact offsets.

---

### 3.4 JVS Input Mapping (8-Way Lever + 3 Shot Buttons) — DONE

`hle_sega.c` (`jvs_switch_byte`) reports VT3's switches:

| Byte | Bit | Meaning | Cabinet bit (`cabinet_buttons.h`) |
| --- | --- | --- | --- |
| 0 | `0x80` | Start | `CAB_P1_START` |
| 0 | `0x40` | Service | `CAB_SERVICE` |
| 0 | `0x20` / `0x10` / `0x08` / `0x04` | Up / Down / Left / Right | `CAB_P1_UP/DOWN/LEFT/RIGHT` (bits 12-15) |
| 0 | `0x02` | Button 1 (topspin) | `CAB_P1_TRIGGER` |
| 0 | `0x01` | Button 2 (lob) | `CAB_P1_BUTTON2` (bit 16) |
| 1 | `0x80` | Button 3 (slice) | `CAB_P1_BUTTON3` (bit 17) |
| 1 | `0x40` | Button 4 | `CAB_P1_FIREMODE` |

Player 2's lever and buttons 2-3 are the same bits shifted by `CAB_P2_JOY_SHIFT` (8).

- **Keyboard** (defaults in `host_settings.c`, rebindable from the Controls menu): arrows = lever, Z / X / C = topspin / lob / slice, 5 = coin, 1 = start, M = mute (starts muted), Esc = quit.
- **Game controllers** (`host_sdl.c`): the first pad is P1, the second P2. D-pad or left stick = lever (8 sectors), A/B/X = buttons 1-3, Y = button 4, Start, Back = coin.
- **Quest** (`xr_controls.c`, when the profile sets `joystick`): either thumbstick = lever; right trigger = topspin; A or left trigger = lob; B or left X = slice. Untested on a headset.
- `game_profile.h` `joystick = 1` (VT3's `host.c`) also stops "pointer left the window" from pressing reload (which is button 2 here).

Menus: on the player-select and tournament screens press **Z**; on court select press **Enter**. Waiting for the timers costs about a minute per screen.

---

## 4. Current Status (2026-11-08)

### Works on macOS (OpenGL renderer, `--opengl`)

- Boots through `CARD R/W INITIALIZING`, the SEGA logo, attract mode (video plays), menus, and into a match at a steady 60 fps.
- All of VT3's shaders compile through the **lifted libCg.so** (no precompiled `.asm_gl` exists for VT3, so `hle_cg.c`'s disc lookup cannot be used).
- Logos, courts, crowd, umpire, ball kids, and **skinned players** (arms, shirts, hands) render correctly.

### Fixes made this session (all pushed, see Section 6)

pcrecomp (lifter/disassembler):
- `push ax` / `pop ax` (0x66 prefix) move esp by 2 (libCg passes shorts with `sub esp,2; push ax`).
- x87 rounding control: `fldcw` is honoured; `frndint` and `fist(p)` round by the RC bits (GCC's `(int)` casts; libCg's `ceil(log2 n)` array growth).
- Disassembler: straight runs longer than 4 KB continue as new leaders; GCC PIC switch tables (`sub r,[ebx+i*4+d]; jmp r`) recognised, bounded by the last live `cmp r, imm`.

lindberghrecomp `solib.py` (lifting libCg):
- Drop candidate function starts that fall inside another instruction; size discovered functions by their own control-flow reach (bodies may overlap).
- Switch arms, out-of-body branch targets and `lea r,[ebx+f@GOTOFF]` callbacks become entries; the lifter gets NOPs over inline switch tables.
- Data imports emitted (`SOLIB_DATA`) and filled at load (`__ctype_b/tolower/toupper`).

lindberghrecomp runtime:
- `arbprog.c` (ARB -> GLSL): classic vertex names (`vertex.color`, `vertex.texcoord[n]`, `vertex.weight`, ...) alias generic attributes as on NVIDIA; `fragment.facing`; register-relative constant reads clamped to the array; **program locals raised from 96 to 1024** (VT3's bone palette reaches `c[225]` — this was the missing-arms bug).
- `hle_cxx.c`: istream `basic_ios` found when the copied libstdc++ vtable reads 0 (shader parser spun forever); `hle_libc.c`: relative `fopen` retried under `TEA_DIR` (scene shaders `shader/*.fx`).
- `hle_glx_posix.c`: `GLX_SGIX_fbconfig/pbuffer` as framebuffer objects, behind profile flag `glx_sgix_pbuffer`.

### Open issues

1. ~~Replay camera / pre-match intro flat colour~~ — fixed, see Section 5.
2. ~~Audio~~ — works (confirmed by ear). SEGAAPI is answered by `hle_segaapi.c`; it starts muted, M toggles (or `LINDBERGH_MUTE=0`). `LINDBERGH_SEGA_METER=1` logs the mix peak and voice count every two seconds.
3. **Quest APK** — builds (`quest/VirtuaTennis3VR.apk`, 25 MB, no game data) but has **not been run on a headset** yet. Build steps on this machine:
   - `quest/deps.sh` with `ANDROID_NDK=~/Library/Android/sdk/ndk/28.2.13676358` (NDK 28.2 works; the scripts default to 27.3).
   - Gradle 8.9 needs JDK 21: `JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home` (JDK 26 is too new).
   - GL thunks against gl4es (recipe in `docs/hotd4/QUEST.md`): `llvm-nm` the exports of `../deps/gl4es/lib/libGL.a`, then `gen_gl_thunks.py --exports ... > games/vt3/generated/recomp_gl_thunks_android.c`. Redo this after every re-lift.
   - `quest/build.sh vt3`, then `quest/install.sh vt3 <disk0>` (copies about 1.8 GB to `/sdcard/VirtuaTennis3`).
   Launcher icons are hotd4 placeholders.

   **On the headset (2026-11-08):** boots, menus and attract at 60 fps; controls work (right trigger = confirm/topspin, A = lob, B = slice, stick = lever, stick click = start). **Open problems:**
   - **Only text is visible; the 3D and textured scene is black.** A capture (`LINDBERGH_CAPTURE=<frame>` in `env.txt`) shows the whole match being drawn into the eyes with valid programs, so the loss is later, most likely the post-process composite (the stage that broke on macOS too; under `LINDBERGH_GL4ES` the attribute aliasing in `arbprog.c` takes a different branch). The capture's eye readback fails ("cannot be read through a framebuffer"), and `LINDBERGH_EYE_DUMP` writes nothing after boot; fixing that readback is the next step.
   - **Match frame rate** was 3-6 fps from ~640 game-thread waits per frame on `glCallList` / client-attrib calls; now queued (0 waits). A match still ran at ~6 fps afterwards, game-thread bound (~150 ms), not yet profiled.
   - Ruled out as the frame-rate cause: render-target enlargement (`LINDBERGH_XR_TARGET_K=1`), the compositor depth copy (`LINDBERGH_XR_DEPTH=0`), fragment shading (`LINDBERGH_FP_SOLID=1` made it slower).
   - Testing: runtime options go in `/sdcard/VirtuaTennis3/env.txt`; `LINDBERGH_AUTOSTART` and `LINDBERGH_KEYS` drive the menus. The headset must be worn: it will not place the app on screen otherwise, even with the proximity sensor overridden. First launch into a match compiles ~7.5 s of shaders; later launches ~0.6 s from `/sdcard/VirtuaTennis3/shadercache`.
4. **Vulkan renderer** — untested for VT3 (needs a shader pack via `quest/build_vulkan.py`).
5. **Other games** (hotd4, lgj, gse) have not been rebuilt against the toolkit changes above. The lifter changes (16-bit push, x87 rounding) affect every game and should be regression-checked.
6. `lindbergh_nvram.bin` is written beside the executable; the card-reader message is Japanese-only (cabinet language setting).

---

## 5. Replay Camera / Pre-Match Intro — RESOLVED

### Symptom
After a point, the replay ("LIVE" logo) and the pre-match intro right after court selection showed one flat colour behind the 2D overlays, though the 3D scene was drawn correctly underneath.

### The pipeline (traced)
1. The scene is drawn to the window, then copied into texture 17 (`glCopyTexSubImage2D`).
2. A post-process chain runs through the game's FBOs: fb 1 / fb 2 (1360x768 textures 12 / 13) at several viewport sizes; **fb 3** (texture 14, 680x384) via `v32/f33` (4-tap blur); **fb 4** (texture 15) via `v26/f27` (glare).
3. One full-screen `v59/f60` draw composites: `(lerp(scene, blurred, saturate(|depth*c1.x + c1.y|)) + glare) * f_loc0.x + transition * f_loc0.y`. The DOF factor saturates for most pixels, so the screen is mostly texture 14.

### Cause
Texture 14 was always black. The blur quad is plain immediate mode (`glBegin`, `glTexCoord2f`, `glVertex3f`) with correct coordinates, but the translated shader picks texcoord 0 as `u_gen[8] > 0.5 ? va_8 : gl_MultiTexCoord0`, and `u_gen` came from the runtime's own record of `glEnable/DisableVertexAttribArrayARB`. That record went stale: `glPopClientAttrib` (called every pass) and entry points fetched through `glXGetProcAddress` change array state without passing the hook. With `u_gen[8]` stuck at 1 the shader read a stale generic array, every pixel sampled one texel, and the frame went flat.

### Fix
`arbprog.c` `upload()`: `u_gen` is filled from `glGetVertexAttribiv(i, GL_VERTEX_ATTRIB_ARRAY_ENABLED)` at each draw instead of the remembered state. Verified on the intro: texture 14 fills (261,120 pixels) and the close-up of the opponent fades in with the "LIVE" logo.

### A wrong turn worth knowing about
I first concluded the quads lived in display lists and sent texcoords with immediate `glVertexAttrib2fARB(8, ...)`. Both were wrong. The "display list" idea came from probes that called `glGetIntegerv` between `glBegin` and `glEnd`, which GL forbids, so they silently saw nothing. `LINDBERGH_LIST_LOG=1` showed VT3's lists hold only texture state, and `LINDBERGH_VA_LOG=1` showed the game never calls `glVertexAttrib*ARB`. The routing written for that theory (`va_alias` in `hle_gl_posix.c`: immediate generic attributes go to their classic twins, as on NVIDIA) is correct NVIDIA behaviour and harmless, so it stays, but nothing in VT3 exercises it.

---

## 6. Working Notes for the Next Agent

### Repos and branches
- `lindbergh-recomp-ports` (outer), submodule `lindberghrecomp`, nested `lindberghrecomp/pcrecomp`. Work is on branch **`vt3-port`** in all three, pushed to forks under `mrchrisster` (remote `fork`); upstream is `lialan`. Submodule URLs in `.gitmodules` are relative, so a clone of either owner resolves to that owner's submodules. PRs go inner-first: pcrecomp, lindberghrecomp, then the outer repo.
- Never commit `games/*/generated/` (lifted game code; gitignored) or any game data.

### Build and run
```bash
cd <workspace>/lindbergh-recomp-ports
./scripts/build-macos.sh --opengl vt3 <workspace>/vt3/extracted/disk0   # full re-lift + build (~5 min)
cd build-mac && ninja vt3                                                  # runtime-only changes
./scripts/run-macos.sh --opengl vt3 <workspace>/vt3/extracted/disk0
```
Run long tests in the background and stop them by PID; never `killall`.

### Driving the game without a person
- `LINDBERGH_AUTOSTART=1`: coin at frame 300, start every 2 s.
- `LINDBERGH_KEYS="frame:key,..."`: scripted key taps (`\r` = Enter). Reaching the pre-match intro (~frame 2500):
  ```bash
  K=""; for f in $(seq 1500 90 3300); do K="$K$f:z,"; done
  for f in 2000 2400 2800 3200; do K="$K$((f+45)):"$'\r'","; done
  LINDBERGH_AUTOSTART=1 LINDBERGH_KEYS="$K" ./scripts/run-macos.sh --opengl vt3 ...
  ```
  Without keys the first replay lands around frame 7800 (it drifts between runs).
- `LINDBERGH_SHOT=<path> LINDBERGH_SHOT_EVERY=N LINDBERGH_SHOT_FROM=F`: saves PPM frames.

### Diagnostic switches (all off by default)
| Switch | What it shows |
| --- | --- |
| `LINDBERGH_SOLIB_TRACE=1` | Calls into lifted libCg, args, and the Cg compiler listing on failure |
| `LINDBERGH_CXX_TRACE=1` | iostream open / read / getline |
| `LINDBERGH_ARB_DUMP=1` (+ `ARB_NOCACHE=1`) | The GLSL every ARB program translates to |
| `LINDBERGH_GL_TRACE=<frame>` | Every GL call of that frame, plus a `[draw]` block per draw: programs, target FBO status/attachments, scissor/stencil/cull/draw buffer, textures on units 0-4 with content readback, constants, attributes, and `[skin]` decoding of bone weights/indices |
| `LINDBERGH_TRACE_VP=26,51 LINDBERGH_TRACE_FROM=<frame>` | The same `[draw]` block for the first 60 draws using those vertex programs, plus that draw's `glTexCoord2f`/`glVertex3f` arguments up to its `glEnd`. Prefer this to frame numbers: scenes drift a few hundred frames between runs |
| `LINDBERGH_TEX_WATCH=<texture>` | That texture's content at every traced draw |
| `LINDBERGH_FB_PROBE=<fbo>` | Readback/vertices while that FBO is bound. Caveat: it queries GL inside `glBegin`/`glEnd`, where queries fail silently, so it misses immediate-mode quads |
| `LINDBERGH_FP_SOLID=1/2/3/4` (+ `FP_ONLY=<id>`) | Replace fragment programs: solid green / raw unit 0 / texcoord as colour / vertex colour |
| `LINDBERGH_ARB_NOCLAMP=1` | Turns off the relative-index clamp (comparison only) |
| `LINDBERGH_LIST_LOG=1` | The calls recorded into each display list |
| `LINDBERGH_VA_LOG=1` | Immediate `glVertexAttrib*ARB` calls and where they are routed |

### Method that has worked
Capture frames, then binary-search the pipeline with readbacks: which draw, which target, which texture, which constants, which inputs. Never query GL state between `glBegin` and `glEnd`: the query fails silently and misleads. Each bug so far was a one-line semantic gap between NVIDIA's 2006 GL and Apple's (attribute aliasing, out-of-range reads, local-parameter limits, rounding mode, 16-bit pushes), found by measuring rather than guessing.
