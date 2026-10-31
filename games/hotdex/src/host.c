/* The House of the Dead EX, using the shared Lindbergh runtime. */
#include <stdio.h>
#include <string.h>
#include "game_profile.h"
#include "lindbergh_rt.h"

/* Normal gameplay reads the pointer through CInputJvs::GetPosition,
 * not the operator menu's GetAdjstGunPos helper. The original returns
 * floats in the cabinet's 1360x768 coordinate system. Replace calibration
 * and four-frame smoothing here, leaving trigger/pedal edges in the game. */
static void h_gun_position(CPU *c)
{
    unsigned player = A32(1) & 0xff;
    if (player >= 2 || !A32(2)) return;
    int x, y, w, h;
    if (player == 1) { if (!host_gun2_state(&x, &y)) x = y = -100000; }
    else host_mouse_state(&x, &y, NULL);
    if (host_cabinet_buttons() & (player ? CAB_P2_RELOAD : CAB_P1_RELOAD)) x = y = -100000;
    lindbergh_window_size(&w, &h);
    float position[2] = { x * (1360.0f / (w > 0 ? w : 1360)),
                          y * (768.0f / (h > 0 ? h : 768)) };
    memcpy(APTR(2), position, sizeof position);
}

static const LgGameProfile k_profile = {
    .title = "The House of the Dead EX",
    .width = 1360, .height = 768,
    .pace_fps = 60,
    .sysdata_region = 1,
    /* InputGetJvs: both pedals are on the first JVS player's byte 0.
     * The game maintains their press/held/release states itself. */
    .action_switch = {{0, 0, 0x08}, {0, 0, 0x04}},
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
    if (!guest_override("_ZN9CInputJvs11GetPositionEaP12KfVectorNNGL", h_gun_position)) {
        fprintf(stderr, "[hotdex] missing gun input entry point; unsupported executable\n");
        return 1;
    }
    CPU cpu;
    guest_init_cpu(&cpu);
    dispatch(&cpu, guest_entry());
    fprintf(stderr, "[host] the entry point returned - _start should not.\n");
    return 1;
}
