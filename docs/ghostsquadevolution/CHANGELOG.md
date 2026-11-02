# Changelog

All notable changes to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[SemVer](https://semver.org/). Nothing has been tagged yet. Everything so far
is under Unreleased, taken from the commits.

## [Unreleased]

### Added
- A native macOS (arm64) build, in this fork's `macos-port` branch. It uses an
  SDL2 window and the system OpenGL. The game's own sound libraries are
  lifted and play through OpenAL. The mouse is the gun, including reload and
  the fire-mode selector, and a menu bar covers controls, aim, sound and
  language. It starts muted. It runs at 60 fps through boot, attract and play.
- `scripts/build-macos.sh` lifts a user's own game folder and builds it in one
  step, and `scripts/run-macos.sh` starts it from that folder. The README has a
  macOS quick start, and CI builds the self-check on macOS too.
- `.gitignore` also refuses `vsg`, `vsg_l/` and disc archives (`.7z`, `.zip`,
  `.rar`).
- The host (`games/ghostsquadevolution/src/host.c`) and the build: lift the
  ELF, link it against lindberghrecomp, run it from the game's directory.
- The game boots past its own heap manager and GLUT setup into its boot
  sequence. It renders at 640x480, takes a coin and start, and reaches the SEGA
  warning screen. Input (coin, start, trigger, gun) reaches the game.
- `CHANGELOG.md`, `ROADMAP.md`, `CONTRIBUTING.md`, CI that builds and runs the
  toolkit's self-check on every push and PR, and a netlab recipe.

### Fixed
- Voice lines play. The game names each voice file with `%C` (a wide
  character), which the runtime's printf did not handle, so every voice file
  failed to open; the game then queried the failed voice's null handle and
  crashed about 5.5 minutes into a mission (on the Quest and anywhere else).
- On Quest 3 (Vulkan), GPU time per frame in a scripted Mission 2 fell from
  18.2 to 13.6 ms (median) with no quality change, and missions no longer
  open with 200-280 ms stalls while each new render target rebuilt every
  pipeline. Details in `docs/VULKAN_PERFORMANCE.md`.

### Changed
- The toolkit is pinned to lindberghrecomp `d65e3b4` (lindberghrecomp#1, #2).
  The game still lifts (6,033 functions, 298 imports) and builds against it.
- The README follows the house layout: a Getting Started from a clean machine,
  Usage, Building from source, License and Contributors.

### Known
- The process dies with a fail-fast (`0xC0000409`) a few hundred frames after
  the warning screen. See the README for what has been ruled out.
