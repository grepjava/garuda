// Counts heap allocations made on each thread of the test process, so a test
// can say that a path allocates nothing.
//
// On glibc the definitions below take the place of the C library's for the
// whole test executable, the Swift runtime included, and forward to the
// library's own entry points. Elsewhere nothing is replaced and the count
// reads -1: a test that needs it skips.

#include "CAllocationCounter.h"

// Before the test: __GLIBC__ is defined by the C library's own headers.
#include <errno.h>
#include <stddef.h>

#if defined(__linux__) && defined(__GLIBC__)

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void *__libc_memalign(size_t, size_t);

// Initial-exec: reading it must not allocate, as a lazily made TLS block would.
static __thread long allocations __attribute__((tls_model("initial-exec")));

void *malloc(size_t n) {
    allocations++;
    return __libc_malloc(n);
}

void *calloc(size_t k, size_t n) {
    allocations++;
    return __libc_calloc(k, n);
}

void *realloc(void *p, size_t n) {
    allocations++;
    return __libc_realloc(p, n);
}

void *memalign(size_t alignment, size_t n) {
    allocations++;
    return __libc_memalign(alignment, n);
}

void *aligned_alloc(size_t alignment, size_t n) {
    allocations++;
    return __libc_memalign(alignment, n);
}

int posix_memalign(void **out, size_t alignment, size_t n) {
    if (alignment < sizeof(void *) || (alignment & (alignment - 1)) != 0) return EINVAL;
    allocations++;
    void *p = __libc_memalign(alignment, n);
    if (p == NULL) return ENOMEM;
    *out = p;
    return 0;
}

long garuda_test_allocations(void) {
    return allocations;
}
#else
long garuda_test_allocations(void) {
    return -1;
}
#endif
