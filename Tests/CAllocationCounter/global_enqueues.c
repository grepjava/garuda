// Counts jobs the Swift runtime sends to its global executor from a thread
// running a worker: a handler task should never need that executor, and one
// that does waits for a thread of the global pool.

#include "CAllocationCounter.h"

#include <stdatomic.h>
#include <stdio.h>
#include <execinfo.h>
#include <unistd.h>

typedef void (*original_enqueue)(void *job);
typedef void (*enqueue_hook)(void *job, original_enqueue original);

#if defined(__APPLE__)
extern enqueue_hook swift_task_enqueueGlobal_hook __attribute__((weak_import));
#else
extern enqueue_hook swift_task_enqueueGlobal_hook __attribute__((weak));
#endif
extern void *av_worker_current(void);

static atomic_long from_workers = 0;
static atomic_int backtraced = 0;

static void hook(void *job, original_enqueue original) {
    if (av_worker_current() != NULL) {
        atomic_fetch_add(&from_workers, 1);
        if (atomic_exchange(&backtraced, 1) == 0) {
            void *frames[48];
            int count = backtrace(frames, 48);
            fputs("[global enqueue from a worker thread]\n", stderr);
            backtrace_symbols_fd(frames, count, 2);
        }
    }
    original(job);
}

void garuda_test_watch_global_enqueues(void) {
    if (&swift_task_enqueueGlobal_hook == NULL) return;
    swift_task_enqueueGlobal_hook = hook;
}

long garuda_test_global_enqueues_from_workers(void) {
    return atomic_load(&from_workers);
}
