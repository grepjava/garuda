#ifndef GARUDA_ALLOCATION_COUNTER_H
#define GARUDA_ALLOCATION_COUNTER_H

/// Heap allocations made so far on the calling thread, or -1 where they are
/// not counted.
long garuda_test_allocations(void);

/// Watches the Swift runtime's global executor: from here on, every job sent
/// to it from a thread that is running a worker is counted, and the first one's
/// backtrace is written to stderr.
void garuda_test_watch_global_enqueues(void);
/// Jobs sent to the global executor from a worker's thread since watching began.
long garuda_test_global_enqueues_from_workers(void);

#endif
