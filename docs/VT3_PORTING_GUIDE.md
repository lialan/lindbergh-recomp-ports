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

### ⚠️ `vt3.bin` (the old base) is truncated: Blake and Ancic are missing
**Resolved with Rev. C's data:** `Virtua Tennis 3 (SBKX) (Rev. C).zip` is a clean extracted `disk0/` tree with all of these files at full size. The working copy is that tree plus `vt3_Lindbergh_HD/_VGA/_FULLHD` from the old dump (`<workspace>/vt3/disk0`, archived as `<workspace>/Virtua Tennis 3 (SBKX) (merged).zip`; `game.conf`'s `find_game` picks it for `<workspace>/vt3`). Rev. C also replaces an 11th file the old dump had wrong: Ancic's base model `P_M_ANC_game_all01_base_AN.efo` was full-size but its contents differed. What follows is kept for anyone with the old dump.

**The build checks for this.** `games/vt3/game.conf` defines `check_game`. It looks for any 0-byte file in the tree, and for the 12 Blake/Ancic player models it compares sha256 against a complete Rev. C copy (Ancic's base model was full-size but wrong in the old dump). `scripts/build-macos.sh`, `quest/build.sh --with-game` and `quest/install.sh` call it when a game defines it. **They stop** with the list of bad files and a pointer to Rev. C, because otherwise the game crashes partway through a tournament, depending on who the player picks and the draw. `LINDBERGH_ALLOW_DAMAGED_GAME=1` builds anyway.
**10 player animation `.efo` files** under `disk0/vt3_Lindbergh/resource/model/player/` are 0 bytes: `P_M_BLA_game_all01_base_II` and `P_M_BLA_game_all_M1/M2/M3/M4SP_II` (James Blake), and `P_M_ANC_game_all01_M1/M1SP/M2/M3/M4_AN` (Mario Ancic).

This is not a 7-Zip bug, and `debugfs` cannot recover them (checked 2026-11-09). The image in `Virtua Tennis 3.7z` is **2,069,479,424 bytes**, but its ext2 superblock declares 512,000 blocks of 4 KB = **2,097,152,000 bytes**. The last ~27.7 MB are missing, and those files' blocks (e.g. 506186+) lie past the end. `debugfs dump` reports "short read". A complete dump of the game is needed. To check one:
```bash
/opt/homebrew/opt/e2fsprogs/sbin/dumpe2fs -h vt3.bin | grep -E 'Block (count|size)'   # count x size must equal the file size
find disk0 -size 0 -type f                                                                # must print nothing
```
The Redump disc image (`DVP-0005A ... [REDUMP].iso`, 1,811,709,952 bytes) does not help here. It is the encrypted install disc (no ISO9660 header, ~8 bits/byte entropy throughout), and this project does not decrypt game media. What's needed is a complete decrypted dump of an installed game.

With the truncated copy, **any match against James Blake crashes** (Section 4, the "third tournament" crash). Ancic's base model is intact, but his match animations are not.

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

> **Note (2026-11-09):** the three binaries above are not Sega's originals. Rev. C's `vt3_Lindbergh` (sha256 `0afba27d...`, from `Virtua Tennis 3 (SBKX) (Rev. C).zip`) is the original. Even "`_VGA`" differs from it in 13 bytes:
> - game ID `SBKX` -> `SBJJ`
> - `tennis::setError(long)` replaced by `mov eax,1; ret`
> - the widescreen test at `0x08175b03` changed from `je` to `jmp`
> - the serial ports changed from `/dev/ttyS*` to `/dev/tts/*`
>
> The original raises "Game Program Not Found" (`setError(-3)`) when the security dongle's challenge-response fails (`usrAdvSegaLogoLoop::exec`: `amDongleDecryptEx` on a table of encrypted blocks, compared with the expected plaintext). The runtime does not answer that challenge, so the port builds from `vt3_Lindbergh_HD` as before. The code layout is identical, so every address in this guide holds for both.

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
   - **The match is shown on a flat panel**, not as a 3D world (see Section 8).
   - The menu-to-court transition shows one tilted frame (world mode starting a frame early).
   - ~~**Crash at the start of the third tournament**~~: **game data, not code.** Road to the Championship round 2 (the third tournament) is against **James Blake**, whose base model is one of the empty files from the truncated image (Section 1). The game opens it at boot (`fopen ... -> ok`, 0 bytes read), and his scene entry is NULL when the match loads: guest `0x18` in `TScene::SceneDatabase::executeManager()` <- `Framework::execute()`. It reproduces on **macOS too**, in ~30 s with `scripts/vt3-repro.sh tournament3 mac <disk0>`. Round 0 (Henman) and round 1 (Hewitt) jumped to the same way play normally. **Fixed with Rev. C's data** (Section 1): on the merged tree, round 2 loads Blake at the French Cup (Stage 3) and plays (macOS, 2026-11-09).
   - ~~**Prize money counter is empty**~~ — **fixed 2026-11-09** (`quest/gl4es.patch`). On the result slate, each digit is a 32x512 strip scrolled by `program.local[7]` (`va_8 * local[6] + local[7]`, offsets -0.1 to -1), so the texture coordinate goes below 0 and relies on `GL_REPEAT`. VT3 sets its textures' wrap inside display lists with `glTexParameteri`. gl4es turns that into `glTexParameterfv` with a pointer to a float on its own stack, and **recorded the pointer, not the value, into the list**: every replay read a dead stack slot, mostly 0 (about 1,500 wraps of 0 per session). The repeat never arrived, so the rolled digits sampled the strip's empty edge. gl4es now copies the values into the list, and refuses a wrap that is no wrap mode, as a desktop driver does. Any texture parameter VT3 sets in a list was affected, so other textures may look different now. Reach the slate with `scripts/vt3-repro.sh prize` (1P wins every point from 40-0).
   - ~~**The two-player camera after a point: black background, players squashed**~~ — **fixed 2026-11-09** (`stereo.c`). After a point, `camera::initWinlose()` picks the split-screen camera when its first `getRandMT_U32() % 10` is 0 (singles), so about 1 point in 10. Each frame, the game clears **depth only** with a half-screen viewport (`0,0 680x768`, then `680,0 680x768`) and draws that player in the half. In the headset the pbuffer is the eyes, and `stereo.c` took any part-screen clear for the start of a "side pass" (another game's colour-cleared reflection passes). Both halves went into an offscreen buffer that's never shown. Now only a clear that includes colour starts a side pass, and a whole-screen clear still ends one. Reach the shot on every point with `LINDBERGH_VT3_SPLIT=1` (`scripts/vt3-repro.sh splitreplay`). **Still open:** the right pane shows a reddish, see-through band of crowd over part of the court near the middle, which macOS does not have (probably the screen blur/composite pass).
   - The end-of-game split ("GAME 1P 1-0") renders correctly on the Quest.
   - **The court logo shown in replays has a white pane behind it that does not rotate with the logo** - a quad drawn with a different transform than the logo (likely a 2D/HUD-classified pass beside a 3D one, `LINDBERGH_DRAW_LOG` on a replay frame shows which).
   - **The match is shown as a flat screen** in front of the player, not as a 3D world: `stereo.c` judges VT3's camera "zoomed" (lens ~29, from the combined MVP in program locals) and falls back to the flat picture. See Section 8 for where this should go.
   - **Opening frames of a match glitch** (play-testing 2026-11-09): for a few frames as the game begins, the camera showing the court glitches. Possibly the known tilted frame at the menu-to-court handover (above), or the court flyover (`usrAcEntranceLoop`) switching from flat to world. Capture with `LINDBERGH_GAME_SHOT=<first>,1` around the hand-over and `LINDBERGH_DRAW_LOG` on the bad frames.
   - **Split-screen point camera: the left pane's player shows as a shadow in the right pane** (2026-11-09, after the side-pass fix). Likely related to the reddish see-through band already noted there: the right pane draws over something left from the left pane (a shadow map, or the screen copy the composite reads). Reach it on every point with `scripts/vt3-repro.sh splitreplay`.
   - **Sky texture glitches when the camera looks from down the court up towards the sky** (2026-11-09). Not yet captured. Candidates: the sky dome drawn with the game's far plane against the headset's projection, or a wrap/clamp on the sky texture (texture parameters set in display lists only reach the driver since the gl4es list fix, so this may be new or old).
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

### Jumping to a broken section (`scripts/vt3-repro.sh`)
Not save states: a full snapshot would have to restore the GL driver's objects, the GL thread's queue and the sound voices, which live outside the guest. Instead the runtime sets the game's own state at the right moment (`hle_sega.c`, `vt3_jumps`). The match object is `g_pTennis` (`0x085061a4`) + `0x1c`. Its round is at `+0x0c` (setMatching picks that round's opponent from `+0xac`), and the current game's points are at `+0x06` / `+0x07` (0-3 = 0/15/30/40, zeroed by `match::init` and `calcGame`; `match::initGame` is dead code).

| Switch | Effect |
| --- | --- |
| `LINDBERGH_VT3_ROUND=N` | The run's first match is round N (0-based; written before the first `match::setMatching`). Round 0 Henman, 1 Hewitt, 2 Blake |
| `LINDBERGH_VT3_POINTS=a,b` | Every game starts at those points (`3,0` = 40-0) |
| `LINDBERGH_VT3_LOG=1` | Each matching, next round and new game, with the frame |
| `LINDBERGH_VT3_SPLIT=1` | Every point ends on the split-screen camera (normally 1 point in 10): the first `getRandMT_U32()` inside `camera::initWinlose` returns 0 |
| `LINDBERGH_VT3_WIN=1` | 1P wins every point (`match+0x61`, the point's winner, set to 0 before `match::calcPoint`). With `LINDBERGH_VT3_POINTS=3,0`, a match is won in two points |
| `LINDBERGH_VT3_PRIZE_TRACE=<frames>` | `LINDBERGH_TRACE_VP` starts that many frames after the result slate's first prize coin sound (`sound::playSe_prize_coin`) |

```bash
./scripts/vt3-repro.sh tournament3 mac <disk0>     # Blake crash, ~30 s
./scripts/vt3-repro.sh splitreplay quest           # the split-pane replay on the headset, frames pulled back
./scripts/vt3-repro.sh round1 mac <disk0> 90       # any round; any LINDBERGH_* in the environment rides along
```
The script drives the menus, runs for a set time, and leaves the log and frames in `$OUT` (default `/tmp/vt3-repro-<scene>`). On the Quest it writes `env.txt`, does the proximity override and wake, and afterwards force-stops the app, undoes the override and **empties `env.txt`**.

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
| `LINDBERGH_DRAW_LOG=<frame>[-<last>]` | Quest: each draw's classification (`persp`, `hud`, target), colour mask and stencil state in `stereo.c`, and each clear with its viewport and side-pass state (`[units] ... clear`) |
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
| `LINDBERGH_SHOT_BOTH=1` | Quest: `GAME_SHOT` / `XR_SHOT` also save the right eye (`game_<frame>_r.ppm`, `xrshot_<frame>_r.ppm`) |
| `LINDBERGH_ARB_LOCAL_LOG=<index>[:<program>]` | Each write of that program local (frame, thread, program, value), and what each draw of the program uploads for it, while a trace window is open |
| `LINDBERGH_TRACE_VP` (additions) | Also prints `local[6]`/`local[7]` and the draw's texture coordinate sources: generic attribute 8 (enabled, buffer, stride, first four values) and unit 0's classic texcoord array |

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

`scripts/vt3-repro.sh <scene> quest` does all of this, and repeats the proximity override and wake every 15 s while the run lasts (an unworn headset dozes off within a minute or two). It also checks that the game really started (its log appears within 40 s) and tries the launch up to 3 times: a launch into a sleeping or just-woken headset sometimes comes to nothing. Nobody has to wear the headset. `XR_SHOT` frames do need the session shown; `GAME_SHOT` does not.

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
7. **Court select looked skipped; menus as a tilted card.** VT3's menu panels are 3D, and `stereo.c` knew no VT3 menu states (`0 menu states of 0 found`: its list is House of the Dead 4's `Game<Name>` functions), so menus were drawn as world - a small tilted card, or black. VT3's screens are `usr...Loop` objects whose `exec()` runs once a frame (found with `LINDBERGH_HUD_LOG=1` against captures: `usrMenuCharLoop` character select, `usrAcselectLoop` mode select, `usrAcLoadLoop` Road to the Championship + versus card, `usrAcEntranceLoop` the court flyover, `usrAcGameLoop` play...). The profile now lists them (`vr.menu_states` / `vr.play_states`, full symbols; parents like `usrAcLoop` in neither), and `watch_states` takes a game's own list. Two more pieces were needed:
   - `menu_state()` allows 8 frames since a menu loop last ran (was 1): the GL thread asks a frame or two behind the game, and the frame flipped between flat and world every few frames. A play state still ends it at once.
   - Road to the Championship draws its panels, clears the colour, then copies the screen for a composite that stereo leaves out: on a flat frame, a colour clear of the screen after anything was drawn is dropped (`g_eye_draws`), so the panels stay. Menus lose the composite's depth-of-field blur; drawing the composite on flat frames gave black (the blur chain through the offscreen targets has never been checked on the Quest).

---

## 7.5 The headset settings panel on a lever cabinet (2026-11-09)

The left controller's menu button (or the other hand's upper button held for a second) opens the settings panel. On a lever cabinet (`game_profile.joystick`, VT3) it now:
- **Can be used:** while it is open, the right controller points at it with a beam (no gun model, sight or flash) and the trigger chooses. Before, lever mode skipped the aiming code, so the panel opened but nothing could be clicked.
- **Shows only rows that apply:** no sight, laser, crosshair, gun model, gun hand or dual wield.
- **Frame rate counter** (was "Show stats"): the frame rate readout, as before.
- **Arcade overlays: Shown / Hidden** (only for games that can hide them, `g_arcade_overlay_hooks`), saved as `overlays on|off` with the other settings and applied live. `LINDBERGH_ARCADE_OVERLAYS=0` hides them for a run (also on macOS). For VT3 (`hle_sega.c`):
  - `credit::draw` skipped: CREDIT(S), INSERT COIN(S), PRESS START BUTTON, TO START / TO CONTINUE.
  - `CCardSlotWindowManager::window_open`, `window_slot`, `window_slot_usecard` not called: the card reader's "card cannot be used" messages and icons at the top. Turning overlays back on brings these back with the next window the game opens.
  - The card information board (`ab_card_info`, a table of 3 `{font, text}` at `+0x14`): its texts ("CREDIT 0", "INSERT COIN(S)") pointed at an empty string, the originals put back when shown.
  - Not hidden: the character select's "insert your card into the slot" prompt (part of that screen).
  - Dead ends: `CCardSlotWindowManager::draw` is a stub; scaling the card board to zero with `AbHandle::setMatrix` did not hide it, and doing it every frame crashed.

The panel is now 20 rows (`XM_ROWS`, `XM_H` 824).

## 8. Immersive Mode (world mode working, 2026-11-09)

**Status:** `LINDBERGH_VT3_IMMERSIVE=1` (in `env.txt`) draws the match as a 3D stadium in front of the player at the broadcast camera's angle, pushed back in depth (HOTD4-style world mode). Confirmed in the headset. Default is still the flat screen.

### 8.0 What the camera turned out to be
- **Two cameras per frame**, read with a wrap of `_sRender::setProjectCameraMatrix` (`hle_sega.c`, immersive only), which leaves the current scene manager's projection at `+0x5c` (4x4, row-major) and view at `+0x2c` (3x4):
  - **Broadcast camera** (set 3x a frame, first): lens 3.20261 / 5.67128, near 1, far 3000, pitched ~19 deg, ~345 units back; its view moves every frame. **Every match draw** goes through it with a rigid model matrix at real court positions (court at the origin, net posts x +-60, players z ~+-117) or a flattened one (ground shadows).
  - **Pixel camera** (set ~9x a frame): lens 1.45455 / 2.57576, near 800, far 1050, no turn, 989.092 back - exactly 1360x768 at its screen plane. HUD, scoreboards, sprites.
  - The "n 800 / f 1050 slab" seen earlier was the pixel camera, never the court.
- **Root cause of the misplaced court:** the match shaders build the position by rows (`DP4 result.position.x, R0, c[0]` - `program.local[0..3]` are the matrix's **rows**), the HUD ones by columns (MUL/MAD). `arb_env_projection` read every draw by columns, so match draws were taken apart transposed. Fix: `position_by_rows()` marks such programs (`pos_kind` 3) and their locals are read transposed (only for `vr.camera_in_locals`, i.e. VT3).
- Tried and **turned off** (`LINDBERGH_VT3_GAME_CAM`, test only): handing every draw the broadcast camera's exact projection (=2), and sending pixel-camera draws to the HUD (=1). Both blacked out the whole picture on the Quest (render targets and full-screen layers took them too).
- Also under immersive: scene culling off (`_sCamera::isVisible` -> true; costs fps, ~37 seen), a wider eye depth range in `stereo.c`, and the stereoscopic-screen experiment (`LINDBERGH_STEREO_DEPTH`, `u_eyex`).
- Diagnostics: `LINDBERGH_MVP_DUMP=<frame>` logs every draw's `program.local[0..3]` (`[mvp]`) and every camera set (`[cam]`) around that frame; solve `M = inv(P*V) * MVP` offline to see which camera a draw used.

- **Closer camera:** the world-mode viewpoint is moved in along the broadcast camera's view by `LINDBERGH_VT3_DOLLY` game units (default 200 of its ~345 from the court; a unit is ~0.1 m), `stereo.c` `effective_projection` (`out * T(0,0,+d)`). The narrow lens (~20 deg down) made the stadium a small model far off.
- **Shadows in world mode:** ground shadows are drawn with a flattened model matrix, which the lens read takes apart wrong (their depth off, so the eyes and the dolly put them metres from the feet). A draw made through the broadcast projection exactly - row 3 + A x row 4 of its matrix = (0 0 0 B) - now gets that projection, shadows included (`arbprog.c`; `LINDBERGH_VT3_GAME_CAM=3` turns it off).
- **Replays switch:** headset menu **Replays On/Off** (`vr.cfg` `replays on|off`, `LINDBERGH_REPLAYS=0` for a run). Off, a wrap of `replay::isReplay_point` answers no; the match goes straight on (checked on the Quest, `forty` scene).

- **Step back:** after the dolly the viewpoint steps back level with the ground (`LINDBERGH_VT3_BACK`, default 60 game units), along the camera's forward with the world's up taken out (up read from the game's view in the hook), so the player stands behind the court at the same height.
- **Player shadows still off the feet in world mode (open).** Flat mode is fine. In world mode the players' silhouette shadows sit metres from the feet and slide with the head, **even with dolly and step back at 0**, so it is not the camera move. Ruled out, 2026-11-10:
  - the shadow map (texture 40, light-matrix texcoords from object space; `LINDBERGH_SHADOW_LIT=1` leaves the silhouette);
  - screen copies (none during play) and a deferred mask (no draws to fb 19/20 during play);
  - the projection: every match draw passes the broadcast-camera test (`[envp]` lines with `LINDBERGH_MVP_DUMP`), read either way round; prop shadows (flattened model matrices) lie on y ~ 0.05 and are fine.
  - Players are skinned on the CPU: program 228's constants are exactly P*V (no model matrix), vertices arrive in world space. The silhouettes most likely come the same way, flattened on the CPU, probably nudged toward the game camera (invisible from it, off from any other viewpoint). Next: read their vertex data (the client arrays at the draw) and see which plane they lie on.
- Diagnostics added: `LINDBERGH_MVP_DUMP_ALL=1` (every local, the bone palette), `LINDBERGH_TXP_LOG=1` (each fragment program's projective reads and their textures).
- **Shadow hunt, 2026-11-10 (second pass).** What two-eye captures at frame 4200 (`forty` scene) show and what was tried:
  - World mode: the near player has **no shadow at his feet**; a sharp silhouette of the same shape and direction lies several metres up-court; his shirt has dark self-shadow blotches. Flat mode and `LINDBERGH_VT3_SAMECAM=1` (world mode, eyes = the game camera exactly) are both correct, so it is the eye transform, not the world-mode code around it.
  - Not it: scene culling (`LINDBERGH_VT3_CULL=1` keeps it, still off), the eyes' near plane (`LINDBERGH_VT3_NEAR=1`, the game's own, still off), the stereoscopic-screen shift (flat only), the shadow-map pass's class (framebuffer 21's 12 draws are `pass`, identity reprojection).
  - Skipping the offscreen passes (`LINDBERGH_SKIP_DRAWS=offscreen`) removes the silhouette, so it is a shadow-map read. But every reader's shadow coordinates are world-fixed: `texcoord[6]` = locals 8, 9, 15 or 225, 11 x the skinned world position (vertex programs 141, 165, 185 read in the dump), independent of the camera.
  - Planar shadows are a separate thing: vertex program 141 / fragment 114 (GPU-skinned, flattened by locals 0..3, flat colour) under stencil NOTEQUAL 1 / REPLACE; their vertices land on y = -0.01 through the broadcast camera's inverse, i.e. right. Skipping fragment 114 blanks the whole match (it trips the scene detection), so it can't be isolated that way.
  - Open contradiction: world-fixed lookups into a map drawn untouched, yet the result moves with the eyes. Next: read texture 40 back (or draw it on the panel) in flat vs world mode to see whether the map itself differs; check whether gl4es multiview rewrites the fb 21 draws (`u_reproj[gl_ViewID_OVR]`, a multiview program drawing into a plain target).
  - **Third pass (corrects the above).** The player's foot shadow is the **planar shadow**, not the shadow map: in flat mode with the shadow-map pass skipped (`LINDBERGH_SKIP_DRAWS=offscreen`) it is still there. It is vertex program 141 / fragment 114 (GPU-skinned, bones in locals 9+), blended, depth test off, stencil NOTEQUAL 1 / REPLACE, back faces culled; program 137 / 114 is only the racket and ball shadows (small flat meshes). The up-court "silhouette" is in the same place in every frame wherever the player is, so it is not the player's shadow.
  - Factored against the broadcast camera (`inv(P*V) * locals 0..3`, with `[cam]` and `[vmat]` from the same frame), program 141's matrix is a plain affine world transform: the player's position, flattened along the light onto y ~ 0.08. Nothing camera-relative, so it should land at the feet in world mode too, and the shadow-map pass is identity-reprojected as it should be (all 732 framebuffer-21 draws over 60 frames, read inside the draw).
  - Yet in world mode the planar shadows do not show. Not the stencil (`LINDBERGH_NO_STENCIL=1`), culling, the near plane; raster state (depth, blend enable, colour mask, scissor, viewport, cull) is identical flat vs world. Painting fragment 114 green (`LINDBERGH_FP_SOLID=1 LINDBERGH_FP_ONLY=114 LINDBERGH_ARB_NOCACHE=1`) shows nothing, but the blend is likely a darkening multiply, so that proves little. Next: log the blend function and the shadow colour (`texcoord[6]` source in program 141), and look at the eye buffer right after the shadow draws (`LINDBERGH_FRAMEMAP`), to see whether they rasterise and something later covers them.
  - Pitfalls found: a dump taken before `exec` reads the previous draw's class (now taken inside the draw, `stereo_draw_dump` from `arb_before_draw`); index ranges read back through gl4es are unreliable (the dump reads the whole vertex buffer); the near player changes ends between runs, so compare positions only within one run; small `GAME_SHOT` frames are 516x552.
  - Tools added: `LINDBERGH_VERT_DUMP=<frame>` (each draw's positions taken back to the world through the broadcast camera, with programs, stencil and texture; reads attribute 0 and buffers), `LINDBERGH_SKIP_FP=<id,...>`, `LINDBERGH_VT3_SAMECAM=1|2` (eyes = game camera / the eye's lens with no head pose), `LINDBERGH_VT3_CULL=1`, `LINDBERGH_VT3_NEAR=<k>` (default 0.05), `LINDBERGH_NO_STENCIL=1`; `[vmat]` lines with `LINDBERGH_VERT_DUMP=<a>-<b>` (locals 0..3, 8, 9, 11, 15, 225, depth/blend/mask/scissor/cull state, the class and both views' reprojection).

### 8.0.1 Open in immersive mode
- Sky is black (not drawn or outside the depth range); scoreboards float in the scene at court level instead of a HUD panel; one black frame at a camera change; culling should be widened to the headset's view instead of off; stadium scale/distance not tuned; panel switch flat / world (Mario Galaxy recomp style) not built yet.


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
