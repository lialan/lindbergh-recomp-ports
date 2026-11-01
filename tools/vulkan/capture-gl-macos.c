/* Development-only reference capture. This library is never linked into the
 * Vulkan runtime. It records successful shader links, exact sources, and the
 * game's attribute bindings for the offline SPIR-V build tool.
 *
 * cc -dynamiclib -framework OpenGL capture-gl-macos.c -o capture.dylib
 * LINDBERGH_SHADER_CAPTURE=/absolute/output/dir \
 * DYLD_INSERT_LIBRARIES=/absolute/capture.dylib ./hotd4 hod4M.elf
 *
 * Captured sources are game-derived data; keep output in an ignored build directory.
 */
#define GL_SILENCE_DEPRECATION 1
#include <OpenGL/gl.h>
#include <OpenGL/glext.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned capture_serial;
static struct { GLuint program; char vertex[96], fragment[96]; } pending[1024];

static int shader_source(const char *dir, GLuint shader, const char *filename)
{
    GLint size = 0;
    glGetShaderiv(shader, GL_SHADER_SOURCE_LENGTH, &size);
    if (size <= 0) return 0;
    char *source = malloc((size_t)size);
    if (!source) return 0;
    GLsizei length = 0;
    glGetShaderSource(shader, size, &length, source);
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", dir, filename);
    FILE *out = fopen(path, "wb");
    int ok = out && fwrite(source, 1, (size_t)length, out) == (size_t)length;
    if (out) fclose(out);
    free(source);
    return ok;
}

static void capture_link(GLuint program)
{
    glLinkProgram(program);
    const char *dir = getenv("LINDBERGH_SHADER_CAPTURE");
    if (!dir || !*dir) return;
    // A missing destination must not silently produce an empty capture.
    struct stat info;
    if ((mkdir(dir, 0755) && errno != EEXIST) || stat(dir, &info) || !S_ISDIR(info.st_mode)) {
        fprintf(stderr, "[shader-capture] invalid output directory: %s\n", dir);
        abort();
    }
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    GLuint attached[16], vertex = 0, fragment = 0;
    GLsizei count = 0;
    glGetAttachedShaders(program, 16, &count, attached);
    for (GLsizei i = 0; i < count; i++) {
        GLint type = 0;
        glGetShaderiv(attached[i], GL_SHADER_TYPE, &type);
        if (type == GL_VERTEX_SHADER) vertex = attached[i];
        if (type == GL_FRAGMENT_SHADER) fragment = attached[i];
    }
    if (!vertex || !fragment) return;
    pthread_mutex_lock(&lock);
    unsigned original = 0;
    while (original < 1024 && pending[original].program && pending[original].program != program) ++original;
    if (!linked) {
        char log[4096] = "";
        glGetProgramInfoLog(program, sizeof log, NULL, log);
        /* Preserve the actual source identity before the existing HLE's
         * missing-varying repair. No reverse reconstruction of source edits. */
        if (strstr(log, "not written by vertex shader") && original < 1024) {
            pending[original].program = program;
            const unsigned serial = ++capture_serial;
            snprintf(pending[original].vertex, 96, "original_vs_p%u_l%u.glsl", program, serial);
            snprintf(pending[original].fragment, 96, "original_fs_p%u_l%u.glsl", program, serial);
            shader_source(dir, vertex, pending[original].vertex);
            shader_source(dir, fragment, pending[original].fragment);
        }
        goto done;
    }
    /* A shader object can be edited and relinked into several programs. Each
     * successful link needs its own immutable source snapshot. */
    const unsigned serial = ++capture_serial;
    char vs_file[96], fs_file[96];
    snprintf(vs_file, sizeof vs_file, "vs_p%u_s%u_l%u.glsl", program, vertex, serial);
    snprintf(fs_file, sizeof fs_file, "fs_p%u_s%u_l%u.glsl", program, fragment, serial);
    if (!shader_source(dir, vertex, vs_file) || !shader_source(dir, fragment, fs_file)) goto done;
    char path[4096];
    snprintf(path, sizeof path, "%s/programs.jsonl", dir);
    FILE *out = fopen(path, "a");
    if (!out) goto done;
    fprintf(out, "{\"program\":%u,\"vertex\":\"%s\",\"fragment\":\"%s\",\"attributes\":[", program, vs_file, fs_file);
    GLint attributes = 0;
    glGetProgramiv(program, GL_ACTIVE_ATTRIBUTES, &attributes);
    for (GLint i = 0; i < attributes; i++) {
        GLchar name[256]; GLsizei length = 0; GLint size = 0; GLenum type = 0;
        glGetActiveAttrib(program, (GLuint)i, sizeof name, &length, &size, &type, name);
        /* GL identifiers contain no JSON metacharacters. */
        fprintf(out, "%s{\"name\":\"%s\",\"location\":%d,\"size\":%d,\"type\":%u}",
                i ? "," : "", name, glGetAttribLocation(program, name), size, type);
    }
    fputs("]", out);
    if (original < 1024 && pending[original].program == program) {
        fprintf(out, ",\"original_vertex\":\"%s\",\"original_fragment\":\"%s\"",
                pending[original].vertex, pending[original].fragment);
        pending[original].program = 0;
    }
    fputs("}\n", out);
    fclose(out);
done:
    pthread_mutex_unlock(&lock);
}

__attribute__((used)) static const struct {
    const void *replacement, *original;
} interpose_link __attribute__((section("__DATA,__interpose"))) = {
    (const void *)capture_link, (const void *)glLinkProgram
};
