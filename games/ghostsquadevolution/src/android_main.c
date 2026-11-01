/*
 * android_main.c - start Ghost Squad Evolution on Meta Quest.
 *
 * SDL's Java side calls SDL_main. The game tree is not in the APK: it is
 * copied to the headset (quest/install.sh), and the game runs from it just
 * as it does from vsg_l on a desktop. Looked for in turn:
 *
 *   /sdcard/Android/data/<package>/files/vsg_l   (the app's own folder)
 *   /sdcard/GhostSquadEvolution/vsg_l            (needs all-files access,
 *                                                 which install.sh grants)
 *
 * An APK built with the game inside (quest/build.sh --with-game) carries it
 * as assets: on the first start, and after an update with different files,
 * it is unpacked into the app's own folder, and played from there.
 *
 * Everything the runtime prints goes to logcat (tag "gse") and to gse.log
 * beside vsg_l. env.txt in vsg_l or beside it, one NAME=value per line, sets
 * runtime options (LINDBERGH_MUTE=1 and the like) without rebuilding.
 */

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <sys/stat.h>

#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <android/log.h>
#include <jni.h>
#include <SDL.h>

int game_main(int argc, char **argv);   /* host.c's main, renamed for Android */

static FILE *g_log;

static void *log_pump(void *arg)
{
    FILE *in = fdopen((int)(intptr_t)arg, "r");
    char line[2048];
    while (in && fgets(line, sizeof line, in)) {
        __android_log_write(ANDROID_LOG_INFO, "gse", line);
        if (g_log) { fputs(line, g_log); fflush(g_log); }
    }
    return NULL;
}

static void log_to_logcat(void)
{
    int fd[2];
    if (pipe(fd)) return;
    setvbuf(stderr, NULL, _IOLBF, 0);
    setvbuf(stdout, NULL, _IOLBF, 0);
    dup2(fd[1], 2);
    dup2(fd[1], 1);
    pthread_t t;
    pthread_create(&t, NULL, log_pump, (void *)(intptr_t)fd[0]);
    pthread_detach(t);
}

static void load_env(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) return;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        char *eq = strchr(line, '=');
        if (!eq || line[0] == '#') continue;
        *eq = 0;
        setenv(line, eq + 1, 1);
        fprintf(stderr, "[android] %s=%s\n", line, eq + 1);
    }
    fclose(f);
}

/* ---- the game inside the APK ----
 * assets/vsg_l/...      the files
 * assets/vsg_l.files    their paths, one per line (assets cannot list folders)
 * assets/vsg_l.id       what this set is; vsg_l/.bundle-id records what was
 *                       unpacked, so it is done once per set */
static char *asset_text(AAssetManager *am, const char *name)
{
    AAsset *a = AAssetManager_open(am, name, AASSET_MODE_BUFFER);
    if (!a) return NULL;
    off_t n = AAsset_getLength(a);
    char *s = malloc((size_t)n + 1);
    if (s) { memcpy(s, AAsset_getBuffer(a), (size_t)n); s[n] = 0; }
    AAsset_close(a);
    return s;
}

static int make_dirs(char *path)          /* every folder above path */
{
    for (char *p = path + 1; *p; p++)
        if (*p == '/') { *p = 0; mkdir(path, 0755); *p = '/'; }
    return 1;
}

static void unpack_game(const char *base)
{
    JNIEnv *env = (JNIEnv *)SDL_AndroidGetJNIEnv();
    jobject activity = (jobject)SDL_AndroidGetActivity();
    if (!env || !activity) return;
    jclass cls = (*env)->GetObjectClass(env, activity);
    jmethodID get = (*env)->GetMethodID(env, cls, "getAssets", "()Landroid/content/res/AssetManager;");
    jobject jam = (*env)->CallObjectMethod(env, activity, get);
    AAssetManager *am = jam ? AAssetManager_fromJava(env, jam) : NULL;
    if (!am) return;
    char *id = asset_text(am, "vsg_l.id");
    if (!id) return;                        /* an APK without the game */
    char stamp[1024];
    snprintf(stamp, sizeof stamp, "%s/vsg_l/.bundle-id", base);
    char *have = NULL;
    FILE *f = fopen(stamp, "r");
    if (f) {
        have = calloc(1, 256);
        if (have && !fgets(have, 255, f)) have[0] = 0;
        fclose(f);
    }
    if (have && !strcmp(have, id)) { free(have); free(id); return; }
    free(have);
    char *list = asset_text(am, "vsg_l.files");
    if (!list) { free(id); return; }
    fprintf(stderr, "[android] unpacking the game into %s/vsg_l (first start)\n", base);
    unsigned files = 0, failed = 0;
    unsigned long long bytes = 0;
    static char buf[1 << 20];
    for (char *line = strtok(list, "\n"); line; line = strtok(NULL, "\n")) {
        if (!*line || strstr(line, "..")) continue;
        char src[1024], dst[1024], tmp[1040];
        snprintf(src, sizeof src, "vsg_l/%s", line);
        snprintf(dst, sizeof dst, "%s/vsg_l/%s", base, line);
        snprintf(tmp, sizeof tmp, "%s.part", dst);
        make_dirs(dst);
        AAsset *a = AAssetManager_open(am, src, AASSET_MODE_STREAMING);
        FILE *o = a ? fopen(tmp, "wb") : NULL;
        int ok = a && o;
        for (int n; ok && (n = AAsset_read(a, buf, sizeof buf)) > 0; ) {
            if (fwrite(buf, 1, (size_t)n, o) != (size_t)n) ok = 0;
            bytes += (unsigned)n;
        }
        if (o && fclose(o)) ok = 0;
        if (a) AAsset_close(a);
        if (ok && rename(tmp, dst) == 0) files++;
        else { failed++; remove(tmp); fprintf(stderr, "[android] could not unpack %s\n", line); }
        if (files % 200 == 0) fprintf(stderr, "[android] %u files, %llu MB\n", files, bytes >> 20);
    }
    free(list);
    if (!failed && (f = fopen(stamp, "w"))) { fputs(id, f); fclose(f); }
    fprintf(stderr, "[android] unpacked %u files (%llu MB), %u failed\n", files, bytes >> 20, failed);
    free(id);
}

static void *run_game(void *arg)
{
    static char *argv[] = { "ghostsquadevolution", "vsg", NULL };
    *(int *)arg = game_main(2, argv);
    return NULL;
}

int SDL_main(int argc, char **argv)
{
    /* --private-game <dir>: a diagnostic run from an app-private copy (quest/run_vulkan_xr.py) */
    const char *diagnostic = NULL;
    if (argc == 3 && strcmp(argv[1], "--private-game") == 0) diagnostic = argv[2];
    const char *own = diagnostic ? diagnostic : SDL_AndroidGetExternalStoragePath();
    if (own) {
        char logpath[1024];
        snprintf(logpath, sizeof logpath, "%s/gse.log", own);
        g_log = fopen(logpath, "w");
        log_to_logcat();
        if (!diagnostic) unpack_game(own);
    }
    const char *bases[2] = { own, diagnostic ? NULL : "/sdcard/GhostSquadEvolution" };
    char dir[1024] = "";
    const char *base = NULL;
    for (int i = 0; i < 2 && !base; i++) {
        if (!bases[i]) continue;
        snprintf(dir, sizeof dir, "%s/vsg_l/vsg", bases[i]);
        if (access(dir, R_OK) == 0) base = bases[i];
    }
    if (!own) log_to_logcat();
    if (base && base != own) {             /* the log goes beside the game */
        char logpath[1024];
        snprintf(logpath, sizeof logpath, "%s/gse.log", base);
        FILE *l = fopen(logpath, "w");
        if (l) g_log = l;                   /* the pump thread may hold the old one: left open */
    }
    if (!base) {
        fprintf(stderr, "[android] no game found: copy the game's vsg_l folder to %s/vsg_l with quest/install.sh "
                        "(and allow the app all-files access)\n", bases[1]);
        return 1;
    }
    snprintf(dir, sizeof dir, "%s/vsg_l", base);
    fprintf(stderr, "[android] game directory %s\n", dir);
    if (chdir(dir) != 0) {
        fprintf(stderr, "[android] cannot enter it: %s\n", strerror(errno));
        return 1;
    }
    load_env("env.txt");
    load_env("../env.txt");     /* beside vsg_l: the one adb can write to in the app's own folder */
    {   /* gl4es keeps the programs it builds here, as arbprog.c does its own */
        char cache[1024];
        snprintf(cache, sizeof cache, "%s/shadercache", base);
        setenv("LIBGL_PROGRAM_CACHE", cache, 0);
    }

    /* Every guest call is a host call: the game's main thread needs the
     * same deep stack the desktop build links with. */
    pthread_attr_t a;
    pthread_attr_init(&a);
    pthread_attr_setstacksize(&a, 256u << 20);
    pthread_t t;
    int rc = 1;
    if (pthread_create(&t, &a, run_game, &rc) != 0) {
        fprintf(stderr, "[android] cannot start the game thread\n");
        return 1;
    }
    pthread_join(t, NULL);
    return rc;
}
