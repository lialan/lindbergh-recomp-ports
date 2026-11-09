/*
 * host.c - run recompiled Virtua Tennis 3.
 */

#include <stdio.h>
#include <stdlib.h>

#include "game_profile.h"
#include "lindbergh_rt.h"

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
