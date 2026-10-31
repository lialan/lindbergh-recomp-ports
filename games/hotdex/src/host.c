/* The House of the Dead EX, using the shared Lindbergh runtime. */
#include <stdio.h>
#include <string.h>
#include "game_profile.h"
#include "lindbergh_rt.h"

/* EX exposes a cdecl entry followed by a register-argument body (the symbol
 * ending in '.'). Internal calls use the body directly. Both receive the
 * original argument slots, with player in slot 5 and calibration in slot 4. */
static uint32_t gun_adjust[2];
static void gun_pos(CPU *c, uint32_t px, uint32_t py)
{
    unsigned player = A32(5);
    if (player < 2) gun_adjust[player] = A32(4);
    int x, y, w, h;
    if (player == 1) { if (!host_gun2_state(&x, &y)) x = y = -100000; }
    else host_mouse_state(&x, &y, NULL);
    lindbergh_window_size(&w, &h);
    int on = x >= 0 && y >= 0 && x < w && y < h;
    long gx = ((long)x * 255 + (w - 1) / 2) / (w > 1 ? w - 1 : 1);
    long gy = ((long)y * 255 + (h - 1) / 2) / (h > 1 ? h - 1 : 1);
    wr8(px, (uint8_t)(gx < 0 ? 0 : gx > 255 ? 255 : gx));
    wr8(py, (uint8_t)(gy < 0 ? 0 : gy > 255 ? 255 : gy));
    RET(on);
}
static void h_gun_pos(CPU *c) { gun_pos(c, A32(0), A32(1)); }
static void h_gun_pos_reg(CPU *c) { gun_pos(c, c->eax, c->edx); }

static void gun_accel(CPU *c, uint32_t px, uint32_t py)
{
    unsigned player = gun_adjust[1] && A32(4) == gun_adjust[1] + 12;
    static unsigned left[2];
    if (host_cabinet_buttons() & (player ? CAB_P2_RELOAD : CAB_P1_RELOAD)) left[player] = 15;
    float v = left[player] ? 1.0f : 0.0f;
    if (left[player]) left[player]--;
    uint32_t bits; memcpy(&bits, &v, 4);
    wr32(px, bits); wr32(py, bits);
}
static void h_gun_accel(CPU *c) { gun_accel(c, A32(0), A32(1)); }
static void h_gun_accel_reg(CPU *c) { gun_accel(c, c->eax, c->edx); }

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
    guest_override("_Z14GetAdjstGunPosPhS_ttP18GunAdjustValueTypei", h_gun_pos);
    guest_override("_Z14GetAdjstGunPosPhS_ttP18GunAdjustValueTypei.", h_gun_pos_reg);
    guest_override("_Z16GetAdjstGunAccelPfS_ttP23GunAccelAdjustValueType", h_gun_accel);
    guest_override("_Z16GetAdjstGunAccelPfS_ttP23GunAccelAdjustValueType.", h_gun_accel_reg);
    CPU cpu;
    guest_init_cpu(&cpu);
    dispatch(&cpu, guest_entry());
    fprintf(stderr, "[host] the entry point returned - _start should not.\n");
    return 1;
}
