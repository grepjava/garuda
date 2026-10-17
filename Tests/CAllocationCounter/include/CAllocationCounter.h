#ifndef GARUDA_ALLOCATION_COUNTER_H
#define GARUDA_ALLOCATION_COUNTER_H

/// Heap allocations made so far on the calling thread, or -1 where they are
/// not counted.
long garuda_test_allocations(void);

#endif
