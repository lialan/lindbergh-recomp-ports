# The House of the Dead EX on macOS

Bring a readable game tree containing `elf/hodexRI.elf` and `fs/`:

```sh
./scripts/build-macos.sh hotdex /path/to/hotdex
./scripts/run-macos.sh hotdex /path/to/hotdex
```

The port uses the same shared runtime as the other games. It is currently
being brought up; a successful build alone does not establish playability.

## Source identity

The development copy was read from `/roms/lindbergh/hotdex` in the user's
Batocera v43 image. Its `game.sh` launches `hodexRI.elf` from `elf/`.
The unstripped executable's SHA-256 is
`6977e02f75de33c51579aa43ebbda104b05dc993f83cc98cac745b8d023d0d14`.
The VGA executable and operator-test executables are separate binaries.

No game files or generated C belong in this repository. The local source
tree is kept separately; the NAS image is unchanged.

## Controls

The intended controls follow HOTD4: mouse aim, left button fire, right
button/off-screen reload, `5`/`1` coin/start (`6`/`2` for player two), `T`/`S`
test/service and `M` mute. The pedal uses the rebindable Action button
(`Space`). Controls remain subject to gameplay validation during bring-up.
