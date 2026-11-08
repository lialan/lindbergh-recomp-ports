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

### 3.4 JVS Input Mapping (8-Way Joystick + 3 Shot Buttons)

In `lindberghrecomp/src/runtime/hle_sega.c`, Sega JVS switch bytes for Virtua Tennis 3:
- **Byte 0 (`byte == 0`):**
  - `0x80`: **Start** (`CAB_P1_START`)
  - `0x40`: **Service** (`CAB_SERVICE`)
  - `0x20`: **Up** (`CAB_P1_UP`)
  - `0x10`: **Down** (`CAB_P1_DOWN`)
  - `0x08`: **Left** (`CAB_P1_LEFT`)
  - `0x04`: **Right** (`CAB_P1_RIGHT`)
  - `0x02`: **Button 1 (Topspin / Normal Shot / Confirm)** (`CAB_P1_TRIGGER`)
  - `0x01`: **Button 2 (Lob / Cancel)** (`CAB_P1_RELOAD`)
- **Byte 1 (`byte == 1`):**
  - `0x80`: **Button 3 (Slice / Drop Shot)** (`CAB_P1_ACTION`)
  - `0x40`: **Button 4** (`CAB_P1_FIREMODE`)

Buttons 1, 2, and 3 match the default Lindbergh cabinet bit layout out of the box. Only the 4 directional bits (`0x20`, `0x10`, `0x08`, `0x04`) need to be mapped to keyboard Arrow/WASD keys and Quest thumbstick axes.

---

## 4. Current Status & Verification

1. **Extraction:**
   - Both `Virtua Tennis 3.7z` and `House of the Dead 4.7z` are extracted under `<workspace>/`.
2. **Lifted Code & Compilation:**
   - `vt3_Lindbergh_HD` lifted into 52 translation units (`recomp_funcs_0000.c` .. `recomp_funcs_0051.c`) with 368 imports.
   - `libCg.so` lifted via `solib.py` into 33 translation units (`recomp_solib_funcs_0000.c` .. `recomp_solib_funcs_0032.c`) and `recomp_solib.h` (13,153 functions).
   - `build-mac/vt3` compiles and links cleanly (`[119/119] Linking C executable vt3`).
3. **Runtime & HLE Additions (100% Bound — `0 of 387 imports have no body`!):**
   - `hle_libc.c`: Added `unsetenv`, `creat`, `getc`, `log10f`, `raise`, `cfsetspeed`, `finite`, `isinf`, `isnan`, `_setjmp`, `longjmp`, `__write`, `fputs_unlocked`, `ferror_unlocked`.
   - `hle_glx_posix.c`: Added `XGetErrorText`.
   - `hle_cg.c` / `hle.c`: Added `cgGLGetLatestProfile`, `cgGLIsProfileSupported`, `cgGLSetOptimalOptions`.
   - `hle_cxx.c`: Added `_ZNSs9_M_mutateEjjj`, `_ZNKSs4findEPKcjj`, `_ZNKSs4findEcj`, `_ZNKSs5rfindEPKcjj`, `_ZNKSs7compareEPKc`, `_ZNSt8ios_baseC2Ev`, `_ZNSt8ios_baseD2Ev`, `_ZNSt6localeC1Ev`, `_ZNSt6localeD1Ev`, `_ZNSt9basic_iosIcSt11char_traitsIcEE4initEPSt15basic_streambufIcS1_E`, `_ZNSt9basic_iosIcSt11char_traitsIcEE5clearESt12_Ios_Iostate`, `_ZNKSt9basic_iosIcSt11char_traitsIcEE5widenEc`, `_ZNSt15basic_stringbufIcSt11char_traitsIcESaIcEE17_M_stringbuf_initESt13_Ios_Openmode`, `_ZNSt13basic_filebufIcSt11char_traitsIcEEC1Ev`, `_ZNSt13basic_filebufIcSt11char_traitsIcEE4openEPKcSt13_Ios_Openmode`, `_ZNSt13basic_filebufIcSt11char_traitsIcEE5closeEv`, `_ZNSt12__basic_fileIcED1Ev`, `_ZNSi5seekgElSt12_Ios_Seekdir`, `_ZNSi5tellgEv`, `_ZNSi4readEPci`, `_ZSt7getlineIcSt11char_traitsIcESaIcEERSt13basic_istreamIT_T0_ES7_RSbIS4_S5_T1_ES4_`, `_ZSt20__throw_length_errorPKc`, `_ZSt20__throw_out_of_rangePKc`.
   - `disasm32.py`: Added GCC `push ebp; mov ebp, esp` (`55 89 E5`) and 128-byte chunking in `disassemble_at`.
   - `solib.py`: Enabled `find_functions` fallback for stripped `.so` binaries.
   - `games/vt3/game.conf`: Set `SOLIBS="lib/libCg.so"`.

---

## 5. Pass-Off Instructions for Next Agent

To continue the project:
1. **Run macOS Binary:**
   ```bash
   cd <workspace>/lindbergh-recomp-ports
   ./scripts/run-macos.sh --opengl vt3 <workspace>/vt3/extracted/disk0
   ```
2. **Wire 8-Way Controls:**
   - In `lindberghrecomp/src/runtime/cabinet_buttons.h`:
     Define `CAB_P1_UP (1u << 20)`, `CAB_P1_DOWN (1u << 21)`, `CAB_P1_LEFT (1u << 22)`, `CAB_P1_RIGHT (1u << 23)`.
   - In `lindberghrecomp/src/runtime/hle_sega.c` (`jvs_switch_byte`):
     Map `CAB_P1_UP` -> `0x20`, `CAB_P1_DOWN` -> `0x10`, `CAB_P1_LEFT` -> `0x08`, `CAB_P1_RIGHT` -> `0x04` when `byte == 0`.
   - In `host_sdl.c`: map Arrow keys / WASD and Gamepad D-pad to these flags.
   - In `xr_actions.c`: map Quest left thumbstick to these flags.
3. **Build Quest 3 APK:**
   - Copy `games/hotd4/src/android_main.c` -> `games/vt3/src/android_main.c`.
   - Create `quest/vt3/` build directory using `quest/hotd4/` as the template.
   - Run `./quest/build.sh vt3` and install with `./quest/install.sh vt3 <workspace>/vt3/extracted/disk0`.
