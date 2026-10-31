/* The House of the Dead EX, using the shared Lindbergh runtime. */
#include <stdio.h>
#include "game_profile.h"
#include "lindbergh_rt.h"

static const LgGameProfile k_profile = {
    .title = "The House of the Dead EX",
    .width = 640, .height = 480,
    .pace_fps = 60,
    .sysdata_region = 1,
};

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <hodexRI.elf> [game args...]\n", argv[0]);
        return 2;
    }
    guest_install_crash_handler();
    if (guest_load(argv[1], argc - 1, argv + 1) != 0) return 1;
    game_profile_apply(&k_profile);
    hle_register_all();
    CPU cpu;
    guest_init_cpu(&cpu);
    dispatch(&cpu, guest_entry());
    fprintf(stderr, "[host] the entry point returned - _start should not.\n");
    return 1;
}
