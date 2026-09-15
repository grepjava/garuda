// Counts malloc, calloc, realloc and posix_memalign calls, for LD_PRELOAD.
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>
#include <stdatomic.h>

static atomic_long count;
static void *(*real_malloc)(size_t);
static void *(*real_calloc)(size_t, size_t);
static void *(*real_realloc)(void *, size_t);
static int (*real_posix_memalign)(void **, size_t, size_t);

// dlsym can call calloc before real_calloc is known; serve that from here.
static char bootstrap[4096];
static size_t bootstrap_used;

long probe_malloc_count(void) { return atomic_load(&count); }

void *malloc(size_t n) {
    if (!real_malloc) real_malloc = dlsym(RTLD_NEXT, "malloc");
    atomic_fetch_add(&count, 1);
    return real_malloc(n);
}

void *calloc(size_t k, size_t n) {
    if (!real_calloc) {
        size_t size = (k * n + 15) & ~(size_t)15;
        if (bootstrap_used + size <= sizeof bootstrap) {
            void *p = bootstrap + bootstrap_used;
            bootstrap_used += size;
            real_calloc = dlsym(RTLD_NEXT, "calloc");
            return p;
        }
        return NULL;
    }
    atomic_fetch_add(&count, 1);
    return real_calloc(k, n);
}

void *realloc(void *p, size_t n) {
    if (!real_realloc) real_realloc = dlsym(RTLD_NEXT, "realloc");
    atomic_fetch_add(&count, 1);
    return real_realloc(p, n);
}

// A bootstrap block handed out before real_calloc was known must never reach
// the real free.
static void (*real_free)(void *);

void free(void *p) {
    if ((char *)p >= bootstrap && (char *)p < bootstrap + sizeof bootstrap) return;
    if (!real_free) real_free = dlsym(RTLD_NEXT, "free");
    real_free(p);
}

int posix_memalign(void **out, size_t align, size_t n) {
    if (!real_posix_memalign) real_posix_memalign = dlsym(RTLD_NEXT, "posix_memalign");
    atomic_fetch_add(&count, 1);
    return real_posix_memalign(out, align, n);
}
