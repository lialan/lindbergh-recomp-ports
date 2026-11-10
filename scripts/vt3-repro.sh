#!/usr/bin/env bash
# vt3-repro.sh - jump Virtua Tennis 3 straight to a known broken section.
#
#   ./scripts/vt3-repro.sh <scene> mac   /path/to/disk0 [seconds]
#   ./scripts/vt3-repro.sh <scene> quest                [seconds]
#
# Scenes:
#   tournament3   Road to the Championship starts at its third tournament
#                 (round 2): the scene-loader crash after two won tournaments
#   round<N>      ...at round N (0-based), e.g. round4
#   forty         every game starts at 40-0
#   splitreplay   every point ends on the split-screen camera (both players
#                 side by side; 1 point in 10 otherwise): broken on the Quest,
#                 black background and squashed players. Frames every 20
#   replay        every point is replayed: replay camera, court logo pane
#   prize         1P wins every point from 40-0, so the match is won in two points
#                 and the result slate's prize-money counter rolls (its
#                 digits vanish on the Quest). Frames every 20
#
# The menus are driven by script (coin, start, Z through the selects, Enter
# on court select); the jump itself is LINDBERGH_VT3_ROUND / _POINTS /
# LINDBERGH_FORCE_REPLAY in the runtime (hle_sega.c). Extra LINDBERGH_*
# switches in the environment are passed through (mac) or added to env.txt
# (quest), e.g. LINDBERGH_CXX_TRACE=1 or LINDBERGH_GAME_SHOT=3000,300.
#
# mac:   runs the OpenGL build for [seconds] (default 120), frames (every 300
#        from 1800 unless the scene says) and the log into $OUT (default /tmp/vt3-repro-<scene>).
# quest: writes env.txt, wakes the headset (proximity override), starts the
#        app, waits [seconds] (default 150), pulls vt3.log and game_*.ppm,
#        then stops the app, undoes the override and empties env.txt.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

SCENE="${1:-}"; WHERE="${2:-}"
[ -n "$SCENE" ] && [ -n "$WHERE" ] || usage
OUT="${OUT:-/tmp/vt3-repro-$SCENE}"

# the jump, as NAME=value lines; where frames are captured from, and how often
SHOT_FROM=1800 SHOT_EVERY=300
case "$SCENE" in
    tournament3) JUMP="LINDBERGH_VT3_ROUND=2" ;;
    round[0-9]*) JUMP="LINDBERGH_VT3_ROUND=${SCENE#round}" ;;
    forty)       JUMP="LINDBERGH_VT3_POINTS=3,0" ;;
    replay)      JUMP="LINDBERGH_FORCE_REPLAY=1" ;;
    prize)       JUMP="LINDBERGH_VT3_WIN=1
LINDBERGH_VT3_POINTS=3,0"; SHOT_FROM=1900 SHOT_EVERY=20 ;;
    splitreplay) JUMP="LINDBERGH_VT3_SPLIT=1"; SHOT_FROM=2400 SHOT_EVERY=20 ;;
    *)           die "unknown scene '$SCENE' (tournament3, round<N>, forty, replay, splitreplay, prize)" ;;
esac
JUMP="$JUMP
LINDBERGH_VT3_LOG=1
LINDBERGH_AUTOSTART=1"

# frame:key taps through the menus (the Quest needs extra starts first)
keys() {
    local k="" f
    if [ "$1" = quest ]; then for f in $(seq 700 120 1500); do k="$k$f:1,"; done; fi
    local from=1500; [ "$1" = quest ] && from=1550
    for f in $(seq $from 90 3600); do k="$k$f:z,"; done
    for f in 2000 2400 2800 3200; do k="$k$((f+45)):"$'\r'","; done
    printf '%s' "$k"
}

# LINDBERGH_* already in our environment, as NAME=value lines
passthrough() { env | grep '^LINDBERGH_' || true; }

mkdir -p "$OUT"
case "$WHERE" in
mac)
    GAME="${3:-}"; SECS="${4:-120}"
    [ -n "$GAME" ] || die "mac needs the game folder: $0 $SCENE mac /path/to/disk0"
    while IFS= read -r l; do [ -n "$l" ] && export "$l"; done <<<"$JUMP"
    export LINDBERGH_KEYS="$(keys mac)"
    export LINDBERGH_SHOT="${LINDBERGH_SHOT:-$OUT/f}" LINDBERGH_SHOT_EVERY="${LINDBERGH_SHOT_EVERY:-$SHOT_EVERY}" LINDBERGH_SHOT_FROM="${LINDBERGH_SHOT_FROM:-$SHOT_FROM}"
    echo "vt3-repro: $SCENE on macOS for ${SECS}s -> $OUT"
    "$ROOT/scripts/run-macos.sh" --opengl vt3 "$GAME" >"$OUT/vt3.log" 2>&1 &
    PID=$!
    for _ in $(seq "$SECS"); do kill -0 $PID 2>/dev/null || break; sleep 1; done
    if kill -0 $PID 2>/dev/null; then kill $PID; wait $PID 2>/dev/null || true; echo "vt3-repro: stopped after ${SECS}s"
    else wait $PID && rc=0 || rc=$?; echo "vt3-repro: the game exited ($rc) before ${SECS}s"; fi
    ;;
quest)
    SECS="${3:-150}"
    . "$ROOT/games/vt3/game.conf"
    adb get-state >/dev/null 2>&1 || die "no headset over adb (plugged in, USB debugging allowed?)"
    { printf '%s\n' "$JUMP"; printf 'LINDBERGH_KEYS=%s\n' "$(keys quest)"
      printf 'LINDBERGH_GAME_SHOT=%s\n' "${LINDBERGH_GAME_SHOT:-$SHOT_FROM,$SHOT_EVERY}"
      passthrough | grep -v '^LINDBERGH_GAME_SHOT=' || true; } >"$OUT/env.txt"
    cleanup() {
        adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
        adb shell am broadcast -a com.oculus.vrpowermanager.automation_disable >/dev/null 2>&1 || true
        adb shell "printf '' > $HEADSET_DIR/env.txt" >/dev/null 2>&1 || true   # a leftover KEYS presses Enter forever
    }
    trap cleanup EXIT
    adb push "$OUT/env.txt" "$HEADSET_DIR/env.txt" >/dev/null
    adb shell "rm -f $HEADSET_DIR/$LOG $HEADSET_DIR/vt3_Lindbergh/game_*.ppm $HEADSET_DIR/vt3_Lindbergh/xrshot_*.ppm"
    # Nobody needs to wear the headset: the proximity sensor is told it is
    # worn and the display woken. A launch into a sleeping or just-woken
    # headset can still come to nothing (no log is written), so the start is
    # checked and tried again, up to 3 times.
    wake() {
        local _
        for _ in $(seq 30); do
            adb shell dumpsys power | grep -q 'mWakefulness=Awake' && return 0
            adb shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null
            adb shell input keyevent KEYCODE_WAKEUP; sleep 1
        done
        return 1
    }
    started=
    for try in 1 2 3; do
        wake || die "the headset would not wake (dumpsys power: not Awake) - press its power button once, then retry"
        adb shell am force-stop "$PKG" >/dev/null 2>&1 || true
        adb logcat -c >/dev/null 2>&1 || true
        adb shell am start -n "$PKG/$ACTIVITY" >/dev/null
        for _ in $(seq 20); do
            adb shell "test -s $HEADSET_DIR/$LOG" && { started=1; break; }
            sleep 2
        done
        [ -n "$started" ] && break
        if adb logcat -d 2>/dev/null | grep -q GuardianDialogActivity; then
            echo "vt3-repro: a Guardian boundary prompt is up - it needs someone to confirm it in the headset" >&2
        fi
        echo "vt3-repro: launch $try came to nothing (no $LOG after 40 s), trying again" >&2
    done
    [ -n "$started" ] || die "the game did not start after 3 launches (Guardian prompt, or the headset asleep) - see adb logcat"
    echo "vt3-repro: $SCENE on the headset for ${SECS}s -> $OUT"
    # an unworn headset dozes off within a minute or two even told it is
    # worn, and the session stops being shown (black frames): told again
    # every 15 s while the run lasts
    for _ in $(seq $(( (SECS + 14) / 15 ))); do
        adb shell am broadcast -a com.oculus.vrpowermanager.prox_close >/dev/null 2>&1 || true
        adb shell dumpsys power | grep -q 'mWakefulness=Awake' || adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
        sleep 15
    done
    adb pull "$HEADSET_DIR/$LOG" "$OUT/vt3.log" >/dev/null 2>&1 || echo "vt3-repro: no $LOG - the launch may have failed (Guardian prompt?)"
    for f in $(adb shell "ls $HEADSET_DIR/vt3_Lindbergh/ 2>/dev/null" | tr -d '\r' | grep -E '^(game|xrshot)_.*\.ppm$' || true); do
        adb pull "$HEADSET_DIR/vt3_Lindbergh/$f" "$OUT/" >/dev/null
    done
    ;;
*) usage ;;
esac

echo "--- $OUT/vt3.log: jumps, rounds, crashes"
grep -E '\[vt3\]|Virtua Tennis 3:|SIGSEGV|crash|fault' "$OUT/vt3.log" | tail -25 || true
echo "--- frames: $(ls "$OUT" | grep -cE '\.(ppm|png)$' || true) in $OUT"
