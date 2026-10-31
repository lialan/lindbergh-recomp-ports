/*
 * host.c - run recompiled The House of the Dead 4.
 *
 * There is very little to do here, and that is the point. The runtime maps the
 * game where it was linked and builds the stack the kernel would have; the
 * lifted code is the game. This just hands control over at the ELF's entry
 * point and gets out of the way.
 *
 * Everything the game reaches for that is not its own code - libc, OpenGL,
 * sound, the JVS I/O board - arrives as hle_call(), and the handlers live in
 * hle_*.c next to this file. A handler that is missing aborts naming itself,
 * so the way to work on this port is to run it and read what it asks for.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "xr_overlay.h"
#include "game_profile.h"
#include "lindbergh_rt.h"

/* The gun, at the two functions the game's gun code reads it through. Both
 * take the board's raw words and the game's stored calibration; a mouse needs
 * neither, so they answer from the pointer directly.
 *
 * GetAdjstGunPos(&x, &y, rawx, rawy, adjust, ...) -> on screen. The position
 * is a byte each, 0..255 across the whole screen. Register arguments: eax =
 * &x, edx = &y. The pointer outside the window is off the screen. */
static uint32_t g_gun_adjust[2];   /* each player's calibration, as GetAdjstGunPos gets it */
static void h_gun_pos(CPU *c)
{
    /* the stack: raw x, raw y, adjust, player - player 2's gun (dual
     * wielding) answers from the second pointer, not the first */
    uint32_t player = rd32(c->esp + 20);
    if (player < 2) g_gun_adjust[player] = rd32(c->esp + 16);
    int mx, my, w, h;
    if (player == 1) { if (!host_gun2_state(&mx, &my)) mx = my = -100000; }
    else host_mouse_state(&mx, &my, NULL);
    lindbergh_window_size(&w, &h);
    int on = mx >= 0 && my >= 0 && mx < w && my < h;
    /* the nearest of the 256 gun steps, first and last on the window's edges */
    long x = ((long)mx * 255 + (w - 1) / 2) / (w > 1 ? w - 1 : 1),
         y = ((long)my * 255 + (h - 1) / 2) / (h > 1 ? h - 1 : 1);
    wr8(c->eax, (uint8_t)(x < 0 ? 0 : x > 255 ? 255 : x));
    wr8(c->edx, (uint8_t)(y < 0 ? 0 : y > 255 ? 255 : y));
    c->eax = on;
}

/* The reload. A House of the Dead 4 gun has an accelerometer and the game
 * reloads when it is shaken. GetAdjstGunAccel(&a, &b, rawa, rawb, adjust)
 * gives the two axes as 0..1 past the calibrated dead zone, and anything over
 * zero is a shake. A mouse cannot shake, so the cabinet's reload input (the
 * right button held, or the pointer leaving the window, which is a single
 * frame) shakes the gun hard for a quarter of a second. Register arguments:
 * eax = &a, edx = &b. */
static void h_gun_accel(CPU *c)
{
    /* whose gun: its calibration sits 12 bytes past the same player's
     * position calibration (GetAdjstGunPos's, recorded above) */
    uint32_t adj = rd32(c->esp + 16);
    int pl = g_gun_adjust[1] && adj == g_gun_adjust[1] + 12;
    static unsigned left[2];
    if (host_cabinet_buttons() & (pl ? CAB_P2_RELOAD : CAB_P1_RELOAD)) left[pl] = 15;
    float v = left[pl] ? 1.0f : 0.0f;
    if (left[pl]) left[pl]--;
    uint32_t bits; memcpy(&bits, &v, 4);
    wr32(c->eax, bits);
    wr32(c->edx, bits);
}

/* GetSpriteResolution(&w, &h) -> screen ratio. The game lays its 2D out for
 * two monitors only: the cabinet's 1280x768 (ratio 2) and 640x480 (every
 * other shape, positions in 640x480 pixels). It then converts those with the
 * sprite resolution, which for a 16:9 monitor is the monitor's own 1280x720,
 * so the HUD came out at half size in the top-left. In a 16:9 mode the sprite
 * resolution is 640x480, matching the layout; the runtime then draws that
 * 4:3 layout at its own shape in the 16:9 frame (host_hud_widen). */
static void h_sprite_res(CPU *c)
{
    /* The camera asks too, for the 3D viewport: it gets the monitor's own
     * size, or the 3D would render at 640x480. The return address is just
     * below the stack pointer once the override is entered. */
    uint32_t ret = rd32(c->esp - 4);
    int w = 640, h = 480;
    if ((ret >= 0x08210c14 && ret < 0x082127c4) ||  /* CCamMgr::InitAllCamera */
        ret == 0x0807cda4 || ret == 0x0807ca19)      /* CSofdecMgr: the movies */
        lindbergh_window_size(&w, &h);
    wr32(c->eax, (uint32_t)w);
    wr32(c->edx, (uint32_t)h);
    c->eax = 5;                 /* 16:9 */
}

#ifdef __ANDROID__
/* In the headset the view is far wider than the cabinet's monitor, and the
 * head turns: the NN library's clip test (nnSetClipPlane builds its four
 * side planes from the projection's focal lengths) dropped scenery and
 * enemies still in view. While it builds them, the focal lengths are taken
 * LINDBERGH_CULL_WIDEN times shorter (default 4; 1 keeps the game's), so the
 * planes enclose a view that much wider; the projection itself is untouched. */
#define NN_PROJ_X 0x0a767c80u           /* the projection's x and y scale, as nnSetClipPlane reads them */
#define NN_PROJ_Y 0x0a767c94u
extern void (*dispatch_lifted(uint32_t va))(CPU *);
static void (*g_clip_plane)(CPU *);
static float g_cull_widen = 4.0f;
static void h_clip_plane(CPU *c)
{
    uint32_t kx = rd32(NN_PROJ_X), ky = rd32(NN_PROJ_Y);
    float fx, fy;
    memcpy(&fx, &kx, 4); memcpy(&fy, &ky, 4);
    fx /= g_cull_widen; fy /= g_cull_widen;
    uint32_t wx, wy;
    memcpy(&wx, &fx, 4); memcpy(&wy, &fy, 4);
    wr32(NN_PROJ_X, wx); wr32(NN_PROJ_Y, wy);
    push32(c, 0xDEADBEEFu);             /* the return slot its ret pops */
    g_clip_plane(c);
    wr32(NN_PROJ_X, kx); wr32(NN_PROJ_Y, ky);
}
static void widen_culling(void)
{
    const char *v = getenv("LINDBERGH_CULL_WIDEN");
    if (v && *v) g_cull_widen = (float)atof(v);
    uint32_t va = guest_symbol("nnSetClipPlane");
    if (!(g_cull_widen > 1.0f) || !va || !(g_clip_plane = dispatch_lifted(va))) return;
    if (guest_override("nnSetClipPlane", h_clip_plane))
        fprintf(stderr, "[hotd4] clip test %.1fx wider than the camera, for the headset\n", g_cull_widen);
}
#endif

/* whether the HUD keeps to the screen's edges, or stays a centred 4:3 block */
static int hud_anchored(void) { return 1; }

/* What the runtime needs to know about this game (game_profile.h). */
static const LgGameProfile k_profile = {
    .title = "The House of the Dead 4",
    /* The monitor the game draws for. 16:9 is the board's 1360x768 mode - its
     * DIP switches have no 1280x720 one - and the game renders and aims for
     * 1360x768, so the frame is that size too and the window scales it.
     * LINDBERGH_WIDTH/HEIGHT pick another mode (1280x768 is the cabinet's). */
    .width = 1360, .height = 768,
    /* The gun goes straight to the game (h_gun_pos above), so the cabinet's
     * raw gun words carry the pointer as is too: no correction. */
    .aim = { 1, 0, 1, 0 },
    .vr = {
        .gun_model = XO_GUN_TP9,    /* a B&T TP9 in the player's hand */
        .title = "The House of the Dead 4 VR",
        /* In the headset the game draws its 640x480 mode, which the
         * runtime's stereo (stereo.c) scales to each eye; the screen in front
         * of you is 4:3 and the HUD sits on it as the game lays it out. */
        .width = 640, .height = 480,
        .scale = 1,
        .depth_read = LG_DEPTH_AUTO,
        /* GL on its own thread: in play the game thread is the limit (85-100%
         * of a core, the GPU 40-60% busy), a third of it the GL calls */
        .gl_thread = 1,
    },
};

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr,
            "usage: %s <hod4M.elf> [game args...]\n"
            "\n"
            "  hod4M.elf is The House of the Dead 4's executable, from a game tree you\n"
            "  can already read. None of it ships here - see the README.\n",
            argv[0]);
        return 2;
    }

    /* Before anything guest-shaped runs, so a fault in lifted code reports
     * the simulated machine rather than a C function name in a generated file. */
    guest_install_crash_handler();

    if (guest_load(argv[1], argc - 1, argv + 1) != 0)
        return 1;

    game_profile_apply(&k_profile);

    /* Give the imports bodies. Everything the toolkit ships is bound here;
     * anything this game needs beyond that gets bound on top, and whatever is
     * still missing aborts naming itself on first call. */
    hle_register_all();
    {
        int w, h;
        lindbergh_window_size(&w, &h);
        if (w * 768 == h * 1360 && guest_override("_Z19GetSpriteResolutionPjS_", h_sprite_res)) {
            fprintf(stderr, "[hotd4] 16:9: the 2D keeps its 4:3 layout\n");
            hud_widen_enable(0.75f, hud_anchored);
            /* the 2D is laid out in 640x480 pixels from the top left, and
             * drawn into the camera's w x h frame */
            hud_widen_layout(w / 640.0f, w / 640.0f - 1, h / 480.0f, 1 - h / 480.0f, w - 8);
        }
    }
    if (guest_override("_Z14GetAdjstGunPosPhS_ttP18GunAdjustValueTypei", h_gun_pos))
        fprintf(stderr, "[hotd4] aim: the gun is where the pointer is\n");
    if (guest_override("_Z16GetAdjstGunAccelPfS_ttP23GunAccelAdjustValueType", h_gun_accel))
        fprintf(stderr, "[hotd4] reload: the reload input shakes the gun\n");
#ifdef __ANDROID__
    widen_culling();
#endif

    CPU cpu;
    guest_init_cpu(&cpu);

    /* The guest never returns here: its exit path is the exit_group syscall,
     * which the runtime turns into the host's exit(). Reaching the line below
     * means the entry point returned, which a Linux _start does not do. */
    dispatch(&cpu, guest_entry());

    fprintf(stderr, "[host] the entry point returned - _start should not.\n");
    return 1;
}
