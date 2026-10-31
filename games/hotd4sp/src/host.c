/*
 * host.c - run recompiled The House of the Dead 4 Special.
 *
 * The same engine as The House of the Dead 4, rebuilt with gcc and shipped
 * stripped: tools bounds finds its functions, and names.txt names the few the
 * runtime looks up. Everything else works as games/hotd4/src/host.c does.
 */

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xr_overlay.h"
#include "game_profile.h"
#include "lindbergh_rt.h"
#include "stereo.h"

/* The gun, where the game reads it: GetAdjstGunPos(&x, &y, rawx, rawy,
 * adjust, ...) turns the board's raw words into a byte each, 0..255 across
 * the screen, through the stored calibration. A mouse needs no calibration,
 * so this answers from the pointer, as games/hotd4 does. Register arguments:
 * eax = &x, edx = &y. Outside the window the gun is off the screen. */
static void h_gun_pos(CPU *c)
{
    /* the stack: raw x, raw y, adjust, player - player 2's gun (dual
     * wielding) answers from the second pointer, not the first */
    uint32_t player = rd32(c->esp + 20);
    int mx, my, w, h;
    if (player == 1) { if (!host_gun2_state(&mx, &my)) mx = my = -100000; }
    else host_mouse_state(&mx, &my, NULL);
    lindbergh_window_size(&w, &h);
    int on = mx >= 0 && my >= 0 && mx < w && my < h;
    long x = ((long)mx * 255 + (w - 1) / 2) / (w > 1 ? w - 1 : 1),
         y = ((long)my * 255 + (h - 1) / 2) / (h > 1 ? h - 1 : 1);
    wr8(c->eax, (uint8_t)(x < 0 ? 0 : x > 255 ? 255 : x));
    wr8(c->edx, (uint8_t)(y < 0 ? 0 : y > 255 ? 255 : y));
    c->eax = on;
}

/* The keychip's second check. Starting a game, the Special has the keychip
 * decrypt a 1 KB block of its own (0x084BA7E0) under a fresh random IV and
 * compares the result with the plaintext it carries (0x084BABE0); a match is
 * a licensed board, anything else is "Error 15 - Game Program Not Found". The
 * cryptography lives in the keychip, so for that one request this answers
 * what a genuine one would, and fails anything else as no keychip does.
 * Arguments: iv, iv, in, out, length. */
#define KEY_CHALLENGE  0x084ba7e0u
#define KEY_EXPECTED   0x084babe0u
#define KEY_CRYPT      0x08363fd7u      /* the keychip library's block decrypt */
static void h_key_crypt(CPU *c)
{
    if (A32(2) == KEY_CHALLENGE && A32(4) == 0x400) {
        memcpy(APTR(3), GP(KEY_EXPECTED), 0x400);
        RET(0);
        return;
    }
    RET(-5);
}

/* LINDBERGH_GOD=1: the player takes no damage, for test runs that must reach
 * a later scene. CPlayer::CanDamagePlayer() - matched against the original
 * game's, the same code with the player's fields moved - answers no. */
#define CAN_DAMAGE_PLAYER 0x080c18d4u
static void h_no_damage(CPU *c) { RET(0); }

/* In the headset the shot leaves the gun, not the head. The game aims its
 * shot along a ray from its camera through the gun's point on the screen -
 * CPlayer::GetTarget(), matched against the original game's, fills the
 * player's ray: the camera's position (this+0x274) and the direction in the
 * world (+0x284) and the camera's space (+0x294). Player 1's is put on the
 * gun's own ray, turned into the world by the game's camera, so the shot -
 * and the splash where it lands - follows the laser at every distance. */
#define GET_TARGET        0x0806a306u
#define GET_CAM_MATRIX    0x0818ddc0u   /* CamCtrlMgr_GetCamMatrix(KfMatrixNNGL *) - eax */
#define MATRIX_NO_MOVE    0x082f4640u   /* KfUnitMatrixTranslation(KfMatrixNNGL *) */
#define INVERT_MATRIX     0x0833305cu   /* nnInvertMatrix(out, in) */
#define CALC_POINT        0x082f4e0au   /* KfCalcPoint(out, matrix, in) */
void L_0806A306(CPU *c);
static uint32_t g_shot_buf;             /* guest memory: a matrix and two vectors */
static void h_get_target(CPU *c)
{
    uint32_t ret = rd32(c->esp - 4);          /* dispatch took the return address off */
    uint32_t self = c->eax;
    push32(c, ret);
    L_0806A306(c);
    uint32_t ok = c->eax;
    float go[3], gd[3];
    uint32_t pos = A32(3), dir = A32(4), cdir = A32(7);
    unsigned player = rd8(self + 0x34);      /* each player fires from their own gun (dual wielding) */
    int have = player < 2 && stereo_gun_ray((int)player, go, gd);
    if (player == 0) {   /* LINDBERGH_TEST_RAY=ox,oy,oz,dx,dy,dz: a fixed ray, camera space (testing off the headset) */
        const char *t = getenv("LINDBERGH_TEST_RAY");
        if (t && sscanf(t, "%f,%f,%f,%f,%f,%f", &go[0], &go[1], &go[2], &gd[0], &gd[1], &gd[2]) == 6) have = 1;
    }
    static int dbg = -1;
    if (dbg < 0) dbg = getenv("LINDBERGH_AIM_LOG") != NULL;
    if (dbg) { static unsigned k; if (++k % 120 == 1) fprintf(stderr, "[hotd4sp] GetTarget: player %u, ok %u, ray %d\n", rd8(self + 0x34), ok, have); }
    if (!ok || !pos || !dir || !have) { c->eax = ok; return; }
    if (!g_shot_buf) g_shot_buf = H2G(guest_alloc(64 + 32, 16));
    uint32_t m = g_shot_buf, vin = m + 64, vout = m + 80;
    /* the camera's turn into the world, as GetTarget makes it */
    c->eax = m;
    if (!guest_call(c, GET_CAM_MATRIX, NULL, 0)) { c->eax = ok; return; }
    { uint32_t a[1] = { m }; guest_call(c, MATRIX_NO_MOVE, a, 1); }
    { uint32_t a[2] = { m, m }; guest_call(c, INVERT_MATRIX, a, 2); }
    float n = sqrtf(gd[0] * gd[0] + gd[1] * gd[1] + gd[2] * gd[2]);
    if (!(n > 0)) { c->eax = ok; return; }
    for (int i = 0; i < 3; i++) gd[i] /= n;
    float wo[3], wd[3];
    const float *in[2] = { go, gd };
    float *out[2] = { wo, wd };
    for (int k = 0; k < 2; k++) {
        float *v = (float *)GP(vin);
        v[0] = in[k][0]; v[1] = in[k][1]; v[2] = in[k][2]; v[3] = 1;
        uint32_t a[3] = { vout, m, vin };
        guest_call(c, CALC_POINT, a, 3);
        memcpy(out[k], GP(vout), 12);
    }
    float *p = (float *)GP(pos), *d = (float *)GP(dir);
    for (int i = 0; i < 3; i++) { p[i] += wo[i]; d[i] = wd[i]; }
    if (cdir) { float *cd = (float *)GP(cdir); cd[0] = gd[0]; cd[1] = gd[1]; cd[2] = gd[2]; }
    static int log = -1;
    if (log < 0) { const char *v = getenv("LINDBERGH_AIM_LOG"); log = v && *v == '1'; }
    if (log) { static unsigned k; if (++k % 60 == 1)
        fprintf(stderr, "[hotd4sp] shot from the gun: camera-space o %.2f %.2f %.2f d %.3f %.3f %.3f -> world d %.3f %.3f %.3f\n",
                go[0], go[1], go[2], gd[0], gd[1], gd[2], wd[0], wd[1], wd[2]); }
    c->eax = ok;
}

/* What the runtime needs to know about this game (game_profile.h). */
static const LgGameProfile k_profile = {
    .title = "The House of the Dead 4 Special",
    .width = 1360, .height = 768,
    .aim = { 1, 0, 1, 0 },
    /* the seats: turned, shaken and blown at by a board on the first serial port */
    .ride_board = "/dev/ttyS0",
    /* its language follows the region in the EEPROM's system data */
    .sysdata_region = 1,
    /* a shake of the gun (its reload) is the second switch byte's bit 6 */
    .reload_switch = { 1, 0x40 },
    .vr = {
        .gun_model = XO_GUN_TP9,    /* a B&T TP9 in the player's hand */
        .title = "The House of the Dead 4 Special VR",
        /* its path choice tests the gun against 1024x768: at 640x480 a shot
         * on the right box lands between the two */
        .width = 1024, .height = 768,
        .scale = 1,
        .depth_read = LG_DEPTH_AUTO,
        .gl_thread = 1,         /* the street: 32-37 fps with the GL on the game's thread, 56-58 without */
        .hud_head_locked = 1,   /* the life bar and prompts where the eye expects them, wherever it looks */
        /* its shots leave the gun (h_get_target), so its screen point only places
         * its 2D - the hit's splash among it: where the laser crosses the HUD */
        .aim_on_hud = 1,
        /* its 2D - HUD, subtitles, the path choice's boxes - is quads hung
         * before a 45-degree, 4:3 camera of its own (the world's is 1.954) */
        .hud_lens = 1.8107f,
    },
};

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
            "usage: %s <hod4M.elf> [game args...]\n"
            "\n"
            "  hod4M.elf is The House of the Dead 4 Special's executable, from a game\n"
            "  tree you can already read. None of it ships here - see the README.\n",
            argv[0]);
        return 2;
    }

    guest_install_crash_handler();
    if (guest_load(argv[1], argc - 1, argv + 1) != 0)
        return 1;
    game_profile_apply(&k_profile);
    hle_register_all();
    guest_override_va("keychip decrypt", KEY_CRYPT, h_key_crypt);
    {
        const char *g = getenv("LINDBERGH_GOD");
        if (g && *g == '1' && guest_override_va("CPlayer::CanDamagePlayer", CAN_DAMAGE_PLAYER, h_no_damage))
            fprintf(stderr, "[hotd4sp] the player takes no damage (LINDBERGH_GOD)\n");
    }
    {   /* the headset's; LINDBERGH_SHOT_FROM_GUN=0 from the head, as the game has it, =1 off it too */
        const char *v = getenv("LINDBERGH_SHOT_FROM_GUN");
#ifdef __ANDROID__
        int on = !(v && *v == '0');
#else
        int on = v && *v == '1';
#endif
        if (on && guest_override_va("CPlayer::GetTarget", GET_TARGET, h_get_target))
            fprintf(stderr, "[hotd4sp] the shot leaves the gun\n");
    }
    if (guest_override("_Z14GetAdjstGunPosPhS_ttP18GunAdjustValueTypei", h_gun_pos))
        fprintf(stderr, "[hotd4sp] aim: the gun is where the pointer is\n");

    CPU cpu;
    guest_init_cpu(&cpu);
    dispatch(&cpu, guest_entry());

    fprintf(stderr, "[host] the entry point returned - _start should not.\n");
    return 1;
}
