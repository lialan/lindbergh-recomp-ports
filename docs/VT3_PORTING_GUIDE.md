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

## 4. Current Status (2026-11-08, macOS and Quest 3)

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
3. **Quest 3 (gl4es + OpenXR)** — playable: boots, menus and matches run at a steady **60 fps** with textured 3D, controls work. See Section 7 for what was fixed and how to test without a person. Still open on the headset:
   - **Court select and the versus screen are black.** Game shots (`LINDBERGH_GAME_SHOT`) show the Road to the Championship screen and the card with both players drawn black on the Quest (about frames 1740-1950 with the Quest menu script), so the menu seems to skip straight to the court. The game's timing is the same as on macOS (the screen moves on by itself after ~3 s there too; a button press skips it). Not investigated yet: start with `LINDBERGH_DRAW_LOG` / `LINDBERGH_MODE_LOG` over those frames (flat-menu detection, `stereo.c` `g_flat`).
   - **The match is shown as a flat screen** in front of the player, not as a 3D world: `stereo.c` judges VT3's camera "zoomed" (lens ~29, from the combined MVP in program locals) and falls back to the flat picture. See Section 8 for where this should go.
   - The last runs with the shadow variant averaged ~50 fps in some stretches; not yet profiled (`LINDBERGH_XR_PROF=1`, `LINDBERGH_FRAMEMAP=<frame>`).
   - Launcher icons are hotd4 placeholders.
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
- `lindbergh-recomp-ports` (outer), submodule `lindberghrecomp`, nested `lindberghrecomp/pcrecomp`. Work is on branch **`vt3-port`** in all three (Quest work continues on **`vt3-quest`** in lindberghrecomp and the outer repo), pushed to forks under `mrchrisster` (remote `fork`); upstream is `lialan`. Submodule URLs in `.gitmodules` are relative, so a clone of either owner resolves to that owner's submodules. PRs go inner-first: pcrecomp, lindberghrecomp, then the outer repo.
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
| `LINDBERGH_FORCE_SHADOW=1` (desktop) | Depth textures read as 2D become `sampler2DShadow` (the driver compares): the reference for the Quest's in-shader compare |
| `LINDBERGH_XR_SHOT=<first>,<every>` (+ `XR_SHOT_FULL=1`) | Quest: the left eye as handed to the headset, `xrshot_<frame>.ppm` beside the game (quarter size unless FULL) |
| `LINDBERGH_XR_PROF=1` | Quest: per 60 frames, the game's GPU work (a `glFinish` on entry to the frame's end), the eye copies, `xrEndFrame` |
| `LINDBERGH_FRAMEMAP=<frame>` | Quest: every draw of that frame with its GPU time (a finish after each), target, viewport and program pair |
| `LINDBERGH_SKIP_DRAWS=offscreen\|main\|all` | Quest: whole groups of draws left out, to find where GPU time goes |
| `LINDBERGH_DRAW_LOG=<frame>` | Quest: each draw's classification (`persp`, `hud`, target) in `stereo.c` |
| `LINDBERGH_CLEAR_LOG=1` | Quest: colour clears of the eyes while a world is drawn |
| `LINDBERGH_GLPROF=1` (+ `GLPROF_SLOW=<ms>`) | Quest: CPU time per GL call and the slowest frames |
| `LINDBERGH_SHADOW_BIAS=<depth>` | Quest: bias off the reference depth in the in-shader shadow compare (default: profile `vr.shadow_bias`, 0) |
| `LINDBERGH_GAME_SHOT=<first>,<every>[,1]` | Quest: the left eye as the game drew it, read from the eye array at the frame's end, as `game_<frame>.ppm` (quarter size unless `,1`). Works while the headset sleeps or sits at a Guardian prompt - use this, not `XR_SHOT`, for unattended runs |
| `LINDBERGH_FORCE_REPLAY=1` | Every point earns a replay (`replay::isReplay_point()` overridden): the replay camera ~a minute into a match |
| `LINDBERGH_INPUT_LOG=1` | Quest: each change of the cabinet buttons, with the controllers' raw state |
| `LINDBERGH_CUBE_LOG=1` | Cube maps: face uploads, what each cube unit holds at a draw, each cube's face contents and its state in gl4es and the driver |
| `LINDBERGH_CUBE_BIND_LOG=1` | Quest: draws where the driver's cube binding differs from gl4es' |
| `LINDBERGH_CUBE_GREY=1` / `LINDBERGH_SHADOW_LIT=1` | Every cube lookup a flat grey / every shadow lookup lit: which term darkens a model |
| `LINDBERGH_SHADOW_LOG=1`, `LINDBERGH_CMP_LOG=1` | Which texture each shadow lookup reads; each fragment program's link and its depth-compare unit mask |
| `LINDBERGH_SHADOW_PCF=0/1` | The in-shader shadow compare filtered over 2x2 texels (default on with `vr.depth_tex_shadow`) |
| `LINDBERGH_FORCE_SHADOW=1 LINDBERGH_SHADER_COMPARE=1` (desktop) | The Quest's in-shader shadow compare on macOS, to check it against the driver's |
| `LINDBERGH_COPY_LOG=1` | Each distinct copy from the framebuffer into a texture |

### Method that has worked
Capture frames, then binary-search the pipeline with readbacks: which draw, which target, which texture, which constants, which inputs. Never query GL state between `glBegin` and `glEnd`: the query fails silently and misleads. Each bug so far was a one-line semantic gap between NVIDIA's 2006 GL and Apple's (attribute aliasing, out-of-range reads, local-parameter limits, rounding mode, 16-bit pushes), found by measuring rather than guessing.

---

## 7. Meta Quest 3 Port (2026-11-08)

### 7.1 Build
- `quest/deps.sh` with `ANDROID_NDK=~/Library/Android/sdk/ndk/28.2.13676358` (NDK 28.2 works). It applies `quest/gl4es.patch` (multiview, texture targets, shader conversion, and now `gl4es_compare_units` / `gl4es_mark_shadow`) and builds `deps/gl4es-android`. After editing `deps/gl4es`, `cmake --build ../deps/gl4es-android` and regenerate the patch (`git -C ../deps/gl4es add -N src/gl/multiview.[ch] && git -C ../deps/gl4es diff > quest/gl4es.patch`).
- `JAVA_HOME=/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home ANDROID_NDK=... sh quest/build.sh vt3`, then `adb install -r quest/VirtuaTennis3VR.apk`. Game data: `quest/install.sh vt3 <disk0>` (to `/sdcard/VirtuaTennis3`).
- GL thunks against gl4es: `llvm-nm` the exports of `../deps/gl4es/lib/libGL.a`, then `gen_gl_thunks.py --exports ... > games/vt3/generated/recomp_gl_thunks_android.c`. Redo after every re-lift.
- The APK holds translated game code: keep it private.

### 7.2 Controls (lever cabinet)
Right trigger = confirm / topspin, A = lob, B = slice, left stick = 8-way lever, stick click = start. Lever mode turns off the gun, laser, sight and recoil rumble (`xr_controls.c` `lever_buttons`, profile `.joystick = 1`).

### 7.3 Testing without a person
The headset sleeps and will not show an app when nobody wears it. What works over adb (USB debugging authorised):
```bash
adb shell am broadcast -a com.oculus.vrpowermanager.prox_close   # proximity sensor reads "worn"
adb shell input keyevent KEYCODE_WAKEUP                           # repeat until dumpsys power says Awake
adb shell am start -n org.lindbergh.vt3.vr/org.lindbergh.vt3.VirtuaTennis3VR
# ... wait, pull /sdcard/VirtuaTennis3/vt3.log and vt3_Lindbergh/xrshot_*.ppm ...
adb shell am broadcast -a com.oculus.vrpowermanager.automation_disable   # undo the override
```
Runtime options go in `/sdcard/VirtuaTennis3/env.txt` (one `NAME=value` per line). **Empty it afterwards**: a leftover `LINDBERGH_KEYS` keeps pressing Enter at court selection and looks like the game auto-advancing. Menu script used for the Quest (frame:key):
```bash
K=""; for f in $(seq 700 120 1500); do K="$K$f:1,"; done; for f in $(seq 1550 90 3600); do K="$K$f:z,"; done
for f in 2100 2500 2900 3300; do K="$K$((f+45)):"$'\r'","; done
```
**Unattended runs: use `LINDBERGH_GAME_SHOT`.** It reads the game's own picture on the GPU, so it works even when the session never gets past READY. Add `LINDBERGH_FORCE_REPLAY=1` to reach the replay camera in about a minute. The helper script used for this (scratch, not in the repo) pushes `env.txt`, does the proximity override and wake retries, launches, waits, pulls `vt3.log` and `game_*/xrshot_*` files, then force-stops, undoes the override and empties `env.txt`. One menu-to-replay run takes ~2.5 minutes.

Blockers seen: the **Guardian boundary dialog** (logcat `GuardianDialogActivity`) keeps the session at READY (states `1 2` in the log) until someone confirms the boundary; don't turn Guardian off from adb, ask the person. A launch sometimes fails silently: check that `vt3.log` is new before reading it.

### 7.4 What was fixed, in order
1. **GL thread stalls (3-6 fps in menus).** ~640 synchronous waits per frame on `glCallList` and `glPush/PopClientAttrib`; queued as values in `gl_thread.c` (0 waits).
2. **Black 3D, only text visible.** `stereo.c` decides per draw whether it is world (stereo, perspective) or HUD, from the projection that `arb_env_projection()` reads out of `program.env[0..3]`. VT3's Cg programs keep `g_transform_mat` in **`program.local[0..3]`**, so every draw looked 2D. Profile switch `vr.camera_in_locals` reads the bound vertex program's locals instead (`DRAW_LOG` went from `persp 0` to `persp 1` on all 262 match draws).
3. **3 fps in a match, GPU-bound (~340 ms/frame).** `XR_PROF` put the time in the game's GPU work; `FRAMEMAP` showed single draws into a 128x128 target taking 36 ms (vertex program 135). The ARB translator copied Cg's 216-entry bone palette (`PARAM c[] = { program.local[0..3], {literal}, program.local[5..215] }`) into a **per-vertex local array** before indexing it with A0; Adreno spills that to scratch memory. Lists that are program.local (or program.env) at their own indices plus a few literals now index the uniform array directly, the literals written into that program's uploaded copy. 60 fps since; macOS unchanged.
4. **Black players.** Their fragment programs read a 1024x1024 depth texture (`DEPTH_COMPONENT32`, unit 0 or 1) through a plain `2D` target with `texture2DProj`, four taps summed as a soft shadow factor that multiplies all lighting. NVIDIA (and Apple) compare depth there; GLES leaves it undefined and the Quest returned 0. With profile `vr.depth_tex_shadow`, units whose bound 2D texture has a depth format (gl4es state, `gl4es_compare_units`) get a program variant (linked programs are keyed by that unit mask) that compares in the shader, as Let's Go Jungle's `SHADOW2D` path already did; `gl4es_mark_shadow` keeps the texture a shadow map after the runtime turns its own compare off. Only projective reads (`TXP`) of such a unit are shadow lookups: the depth of field reads the screen's depth texture with plain `TEX` and wants the depth itself (treating it as a shadow map blacked out the replay's world). The compare is filtered over 2x2 texels (`lg_pcf`, as a driver does with linear filtering) and the sampler is declared `highp` (a GLES sampler defaults to `lowp`).
5. **Close-ups and replays: players as silhouettes.** Not the shadows (`LINDBERGH_SHADOW_LIT=1` left them dark) but the **cube maps** - the players' ambient/environment light (`LINDBERGH_CUBE_GREY=1` lit them). Three gl4es bugs, all in `quest/gl4es.patch`:
   - `realize_textures` pushes a unit's sampler state (filters, wrap) to the driver only for the target enabled with `glEnable`; shaders never enable `GL_TEXTURE_CUBE_MAP`, so the driver kept the default mipmapped min filter on one-level cubes: incomplete. `gl4es_realize_cubes(units)` (called before each translated draw for the program's cube units) applies them and clamps `GL_TEXTURE_MAX_LEVEL` to the levels present.
   - Native DXT uploads set `GL_TEXTURE_MAX_LEVEL` on the face target (invalid) instead of `GL_TEXTURE_CUBE_MAP`.
   - **The driver's cube binding was 0 by draw time** while gl4es believed the cube bound (`LINDBERGH_CUBE_BIND_LOG`): gl4es binds a cube map "immediately" and never re-checks. `gl4es_realize_cubes` binds it again before the draw. This was the one that made the close-ups black.
   Dead ends, for the record: shadow bias (0.05 changed nothing), reprojection of the shadow pass (framebuffer 21 is already drawn with the game's own projection), 16-bit depth (gl4es stores multiview depth as `DEPTH24_STENCIL8`).
6. `stereo.c`: after a whole-screen copy of a drawn world, the colour bit of the next eye clear is dropped (VT3 clears before compositing its depth-of-field copy, and that composite is left out in stereo). In the working build, but not tested on its own.

---

## 8. Future: Immersive Mode (planned)

Today the match is drawn as a flat picture on a screen in front of the player (the 2D "theatre" path in `stereo.c` / `host_xr.c` `xo_draw_screen`). The goal is to make it feel like being in the game.

### 8.1 Depth: draw the world in 3D
- Stop treating VT3's camera as a zoom. `stereo.c` reads a lens of ~29 because `vr.camera_in_locals` hands it the **combined** MVP (projection x view x model), not the projection alone. Split it: per draw, the projection is the part constant across the frame's world draws; or find where the game builds `g_transform_mat` (the Cg parameter set through `cgGLSetMatrixParameterfc`/`cgSetMatrixParameter`) and take the projection and view there, before they are multiplied.
- With projection and view separate, render the world per eye with the headset's projection and the eye offset applied in view space (what `stereo.c` already does for hotd4's env-held camera), so the court has real depth; keep the HUD on a panel.
- Scale: a tennis court is 23.77 m; pick a world scale (profile `vr.scale`) so the court is life-size or a "table-top" miniature, both worth trying.

### 8.2 Camera control
- Phase 1, head-tracked: the game's camera stays the anchor; head pose adds rotation/translation on top (look around the stadium, lean over the net).
- Phase 2, free / chosen camera: replace the game's view matrix with one the player picks: behind own player (third person), first person at the player's eyes (needs the player's position: read from game memory or from the player's skinned-model root bone in the bone palette), umpire chair, broadcast. The game still renders by its own camera for culling, so a wider view may need culling turned off or the far player's draw forced.
- Comfort: the broadcast camera moves on its own; in VR that should be smoothed or snapped, with the option to lock it.

### 8.3 In-headset menu
A runtime menu (the XR overlay already draws a settings panel, `host_xr.c` `menu` / `xo_draw_panel`, opened from the controller) with:
- Display mode: **Flat screen** (today) / **Immersive 3D** / **Table-top**.
- Depth strength (IPD scale / world scale), screen distance and size for flat mode.
- Camera: Game camera / Head-tracked offset / Third person / First person / Umpire, plus recenter.
- Comfort: camera smoothing, vignette on camera cuts.
Settings persist through `xr_settings_save` like the existing ones; switches that need a program variant (depth on/off) can rebuild at the next frame.

### 8.4 Order of work
1. Fix the shadows (Section 7.4 #4).
2. Separate projection and view from VT3's MVP; get the court drawn in stereo with depth in the existing pipeline, fixed game camera.
3. Menu entries for flat / immersive / table-top and scale.
4. Head-tracked camera offset; then chosen cameras.
