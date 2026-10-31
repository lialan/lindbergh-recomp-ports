# HOTD4 Windows PC VR experiment

This branch builds HOTD4 as a Windows x64 executable using the shared runtime
and OpenXR host. It uses desktop OpenGL 4.3 compatibility, a Win32/WGL OpenXR
graphics binding, and stereo replay. The active OpenXR runtime must expose
`XR_KHR_opengl_enable`. This first experiment keeps the existing Oculus Touch
controller bindings; other controller profiles have not been added.

Status: cross-compiled and linked on macOS, with the transitive DLL imports
resolved. The shared macOS runtime self-test passes and the modified Android
VR sources pass a syntax compile with the Android NDK. Windows execution and
headset gameplay have **not** been validated. The Windows CI job is added but
has not been run remotely.

## Build on Windows

Use an [MSYS2](https://www.msys2.org/) **MINGW64** shell and install:

```sh
pacman -S --needed mingw-w64-x86_64-gcc mingw-w64-x86_64-cmake \
  mingw-w64-x86_64-ninja mingw-w64-x86_64-python \
  mingw-w64-x86_64-python-capstone mingw-w64-x86_64-python-pyelftools \
  mingw-w64-x86_64-SDL2 mingw-w64-x86_64-glew \
  mingw-w64-x86_64-openal mingw-w64-x86_64-openxr-sdk mingw-w64-x86_64-zlib
git submodule update --init --recursive
./scripts/build-windows.sh '/c/Games/House of the Dead 4'
```

The build lifts the supplied `elf/hod4M.elf`, generates typed GL thunks from
GLEW's declarations, and packages `build-win64/hotd4-pcvr/`. That folder holds
HOTD4, the runtime self-test, dependent DLLs, an ELF hash and launcher. Game
data stays in your original game folder. This is a local development bundle.
Use GNU C through MinGW-w64; the old Win32/MSVC backend is a separate path.

On macOS/Linux, install an `x86_64-w64-mingw32-gcc` cross compiler, extract the
corresponding Windows dependencies into a mingw64 prefix, and use:

```sh
WIN64_DEPS=/path/to/mingw64 PYTHON=/path/to/venv/bin/python \
  ./scripts/build-windows.sh '/path/to/House of the Dead 4'
```

The script accepts `--reuse-generated` as its second argument when an existing
HOTD4 lift matches the supplied ELF hash. Windows packages are available from
the [official MSYS2 repository](https://repo.msys2.org/mingw/mingw64/).

## Run on the PC

Connect the headset through your PC VR software and select its OpenXR runtime.
Copy `hotd4-pcvr` to the PC. From PowerShell in that folder:

```powershell
.\lindbergh_rt_selftest.exe
.\run-hotd4-windows.ps1 -GameDirectory 'C:\Games\House of the Dead 4'
```

Keep the game's `elf`, `fs` and `drv` directories together. The launcher checks
the ELF hash, sets the working directory to `elf`, and writes `hotd4.log` next
to the executable. `vr.cfg`, `lindbergh.ini` and the cabinet save remain in the
game's `elf` folder. Runtime options can be set through PowerShell environment
variables, for example `$env:LINDBERGH_MUTE = '0'`.

Controls follow the [HOTD4 Quest port](QUEST.md#controls): trigger fires, grip
reloads, thumbstick click starts, and the left menu button opens settings.
Headset recentering is provided by the active PC VR runtime. Resolution and
refresh settings remain requests subject to that runtime's capabilities. Windows VR starts with sound enabled;
existing settings and `LINDBERGH_MUTE` take precedence.

## First hardware validation

Run the self-test before launching the game. Check the intro and menus, stereo
depth and head tracking, then start a stage and verify gun aim, reload, recoil,
sound, and the settings panel. Also check transitions, reflections and HUD
placement: the PC build uses stereo replay rather than Quest's multiview path.
Check window close, headset sleep/resume and the in-game reset. Keep
`hotd4.log` with the headset and active runtime name when reporting results.

The local test ELF has SHA-256
`72fdd45830acd9317ec1e4f97de35a270c94746068fdaf827381c91bb47aa296`.
