/*
 * host.c - run recompiled Virtua Tennis 3.
 */

#include <stdio.h>
#include <stdlib.h>

#include "game_profile.h"
#include "lindbergh_rt.h"

/* The game's screens are usr...Loop objects whose exec() runs once a frame
 * (a parent - usrMenuLoop, usrAcLoop, usrAdvLoop - runs its current child, so
 * the parents are in neither list). A menu's frame is shown flat, as the
 * arcade drew it: its panels are 3D and, drawn from the eyes as world, came
 * out as a tilted card or black (Road to the Championship, the versus card -
 * usrAcLoadLoop - which made court selection look skipped). Found with
 * LINDBERGH_HUD_LOG=1 against frame captures. */
static const char *const k_menu_states[] = {
    "_ZN15usrMenuCharLoop4execEv",          /* character select */
    "_ZN15usrAcselectLoop4execEv",          /* mode select */
    "_ZN13usrAcLoadLoop4execEv",            /* Road to the Championship, the versus card, loading */
    "_ZN15usrMainmenuLoop4execEv", "_ZN15usrVsselectLoop4execEv", "_ZN17usrVspositionLoop4execEv",
    "_ZN17usrSoloselectLoop4execEv", "_ZN17usrChMsSelectLoop4execEv",
    "_ZN17usrAcContinueLoop4execEv", "_ZN18usrAcNameentryLoop4execEv", "_ZN16usrNameEntryLoop4execEv",
    "_ZN16usrAcRankingLoop4execEv", "_ZN14usrAcStatsLoop4execEv",
    "_ZN15usrChResultLoop4execEv", "_ZN20usrChTotalResultLoop4execEv",
    "_ZN13usrOptionLoop4execEv", "_ZN19usrSoundSettingLoop4execEv", "_ZN16usrHowtoplayLoop4execEv",
    "_ZN15usrItemGearLoop4execEv", "_ZN16usrItemMedalLoop4execEv", "_ZN20usrItemPlaystyleLoop4execEv",
    "_ZN16usrGearcolorLoop4execEv", "_ZN15usrCardEditLoop4execEv",
    "_ZN15usrAdvTitleLoop4execEv", "_ZN17usrAdvRankingLoop4execEv", "_ZN21usrAdvRankingLoadLoop4execEv",
    NULL,
};
static const char *const k_play_states[] = {
    "_ZN17usrAcEntranceLoop4execEv",        /* the court flyover */
    "_ZN17usrAcGameinitLoop4execEv", "_ZN14usrAcStartLoop4execEv", "_ZN13usrAcGameLoop4execEv",
    "_ZN14usrAcJudgeLoop4execEv", "_ZN13usrAcPassLoop4execEv", "_ZN16usrAcWinloseLoop4execEv",
    "_ZN15usrAcReplayLoop4execEv", "_ZN18usrAcChangeendLoop4execEv", "_ZN21usrAcGamesetmatchLoop4execEv",
    "_ZN18usrAdvDemoplayLoop4execEv", "_ZN14usrChIntroLoop4execEv",
    NULL,
};

static const LgGameProfile k_profile = {
    .title = "Virtua Tennis 3",
    .width = 1360, .height = 768,
    .pace_fps = 60,
    .joystick = 1,
    .glx_sgix_pbuffer = 1,
    .vr = {
        .title = "Virtua Tennis 3 VR",
        .width = 1360, .height = 768,
        .scale = 1,
        .camera_in_constants = 1,
        .camera_in_locals = 1,      /* Cg's g_transform_mat: program.local[0..3] */
        .depth_tex_shadow = 1,      /* the players' shadow map, unit 0 */
        .depth_read = LG_DEPTH_AUTO,
        .gl_thread = 1,
        .menu_states = k_menu_states,
        .play_states = k_play_states,
    },
};

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
            "usage: %s <vt3_Lindbergh_HD> [game args...]\n"
            "\n"
            "  vt3_Lindbergh_HD is Virtua Tennis 3's executable, from a game tree you\n"
            "  can already read. None of it ships here - see the README.\n",
            argv[0]);
        return 2;
    }

    guest_install_crash_handler();

    if (guest_load(argv[1], argc - 1, argv + 1) != 0)
        return 1;

    /* The cabinet's launch script points TEA_DIR at disk0/, one level above
     * vt3_Lindbergh/ where the executable runs and where ../shader/ lives. */
    if (!getenv("TEA_DIR")) setenv("TEA_DIR", "..", 1);

    game_profile_apply(&k_profile);
    hle_register_all();

    CPU cpu;
    guest_init_cpu(&cpu);

    dispatch(&cpu, guest_entry());

    fprintf(stderr, "[host] the entry point returned - _start should not.\n");
    return 1;
}
