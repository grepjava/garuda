/* The topic bus. See garuda_bus.h. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "garuda_bus.h"

#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <process.h>
#include <windows.h>
#else
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>
#endif

#if defined(__linux__)
#include <linux/futex.h>
#include <sys/syscall.h>
#elif defined(__APPLE__) && __has_include(<os/os_sync_wait_on_address.h>)
#include <os/os_sync_wait_on_address.h>
#include <os/clock.h>
#define GB_OS_SYNC 1
#endif

/* A message's description, in front of its bytes in the ring. */
struct record {
    uint64_t sequence;
    uint32_t topic_len;
    uint32_t event_len;
    uint32_t data_len;
    uint32_t unused;
};

struct slot {
    /* 0 when free, or the holding process's ID. */
    _Atomic uint64_t pid;
    /* 1 while the holder sleeps, or is about to, waiting for a publish. */
    _Atomic uint32_t armed;
    uint32_t unused;
};

struct header {
    /* 0 untouched, 1 being laid out, 2 ready. */
    _Atomic uint32_t state;
    uint32_t slot_count;
    /* 0 when free; otherwise the claiming process's ID shifted left, and 1. */
    _Atomic uint64_t claim;
    /* The number the next message will be given. A message is readable once
     * this has passed it. */
    _Atomic uint64_t next;
    /* The highest byte position a writer has claimed: every byte below it may
     * have been written, and a byte at position p is gone once this passes
     * p + capacity. Never falls, not even when a writer that died is taken
     * over and its bytes written again. */
    _Atomic uint64_t high;
    /* The lowest number that may still be readable. */
    _Atomic uint64_t oldest;
    /* Where the next message goes. Only the claim holder reads or moves it. */
    uint64_t tail;
    uint64_t capacity;
    uint64_t index_mask;
    uint32_t max_message;
    uint32_t unused;
};

/* Where a message starts, found by its number. */
struct index_entry {
    _Atomic uint64_t sequence;
    _Atomic uint64_t position;
};

struct gb_bus {
    struct header *header;
    struct slot *slots;
    struct index_entry *index;
    uint8_t *bytes;
};

#define RECORD_SIZE sizeof(struct record)
#define ALIGN(n) (((n) + 63) & ~(uint64_t)63)
/* Room in the index for a message of this many bytes on average. */
#define AVERAGE_RECORD 128

static uint64_t ring_capacity(uint64_t ring_bytes) {
    uint64_t capacity = UINT64_C(1) << 16;
    while (capacity < ring_bytes && capacity < (UINT64_C(1) << 40)) capacity <<= 1;
    return capacity;
}

static uint64_t index_entries(uint64_t capacity) {
    uint64_t entries = 1024;
    while (entries < capacity / AVERAGE_RECORD) entries <<= 1;
    return entries;
}

size_t gb_bus_region_size(uint64_t ring_bytes, uint32_t slots) {
    uint64_t capacity = ring_capacity(ring_bytes);
    return ALIGN(sizeof(struct header)) + ALIGN(slots * sizeof(struct slot))
        + index_entries(capacity) * sizeof(struct index_entry) + capacity;
}

static uint64_t now_us(void) {
#if defined(_WIN32)
    FILETIME ft;
    GetSystemTimeAsFileTime(&ft);
    uint64_t t = ((uint64_t)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
    return t / 10 - UINT64_C(11644473600000000);
#else
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
#endif
}

static uint64_t self_pid(void) {
#if defined(_WIN32)
    return (uint64_t)_getpid();
#else
    return (uint64_t)getpid();
#endif
}

static void yield(void) {
#if defined(_WIN32)
    SwitchToThread();
#else
    sched_yield();
#endif
}

static int process_gone(uint64_t pid) {
#if defined(_WIN32)
    if (pid > UINT32_MAX) return 1;
    HANDLE h = OpenProcess(SYNCHRONIZE, FALSE, (DWORD)pid);
    if (h == NULL) return GetLastError() == ERROR_INVALID_PARAMETER;
    int gone = WaitForSingleObject(h, 0) == WAIT_OBJECT_0;
    CloseHandle(h);
    return gone;
#else
    return kill((pid_t)pid, 0) != 0 && errno == ESRCH;
#endif
}

gb_bus *gb_bus_attach(void *region, size_t region_bytes, uint64_t ring_bytes, uint32_t slots) {
    if (region == NULL || slots == 0 || region_bytes < gb_bus_region_size(ring_bytes, slots)) return NULL;
    uint64_t capacity = ring_capacity(ring_bytes);
    uint64_t entries = index_entries(capacity);
    gb_bus *bus = calloc(1, sizeof *bus);
    if (bus == NULL) return NULL;
    uint8_t *base = region;
    bus->header = (struct header *)base;
    bus->slots = (struct slot *)(base + ALIGN(sizeof(struct header)));
    bus->index = (struct index_entry *)(base + ALIGN(sizeof(struct header)) + ALIGN(slots * sizeof(struct slot)));
    bus->bytes = (uint8_t *)(bus->index + entries);

    struct header *h = bus->header;
    uint32_t expected = 0;
    if (atomic_compare_exchange_strong(&h->state, &expected, 1)) {
        /* The region is zero already: the index's numbers are all below the
         * first, so none is mistaken for a message. */
        uint64_t first = now_us();
        h->slot_count = slots;
        h->capacity = capacity;
        h->index_mask = entries - 1;
        /* A message may take up to a quarter of the ring, so a burst of the
         * largest ones still leaves the last few readable. */
        uint64_t max = capacity / 4 - RECORD_SIZE;
        h->max_message = max > (UINT64_C(1) << 30) ? (UINT32_C(1) << 30) : (uint32_t)max;
        atomic_store(&h->oldest, first);
        atomic_store(&h->next, first);
        atomic_store(&h->state, 2);
    }
    while (atomic_load(&h->state) != 2) yield();
    return bus;
}

void gb_bus_detach(gb_bus *bus) {
    free(bus);
}

uint32_t gb_bus_max_message(const gb_bus *bus) {
    return bus->header->max_message;
}

static void copy_in(gb_bus *bus, uint64_t position, const uint8_t *from, size_t n) {
    uint64_t capacity = bus->header->capacity;
    while (n > 0) {
        uint64_t at = position & (capacity - 1);
        size_t run = capacity - at;
        if (run > n) run = n;
        memcpy(bus->bytes + at, from, run);
        from += run;
        position += run;
        n -= run;
    }
}

static void copy_out(const gb_bus *bus, uint64_t position, uint8_t *to, size_t n) {
    uint64_t capacity = bus->header->capacity;
    while (n > 0) {
        uint64_t at = position & (capacity - 1);
        size_t run = capacity - at;
        if (run > n) run = n;
        memcpy(to, bus->bytes + at, run);
        to += run;
        position += run;
        n -= run;
    }
}

static void take_claim(gb_bus *bus) {
    struct header *h = bus->header;
    uint64_t mine = (self_pid() << 1) | 1;
    unsigned spins = 0;
    for (;;) {
        uint64_t seen = atomic_load(&h->claim);
        if (seen == 0) {
            if (atomic_compare_exchange_weak(&h->claim, &seen, mine)) return;
            continue;
        }
        /* Another writer, copying one message. Held for microseconds, unless
         * its process died holding it. Only a claim still held after a while
         * is worth the system call that asks. */
        if (++spins % 256 == 0 && seen != mine && process_gone(seen >> 1)) {
            if (atomic_compare_exchange_strong(&h->claim, &seen, mine)) return;
        }
        if (spins % 16 == 0) yield();
    }
}

static void give_claim(gb_bus *bus) {
    atomic_store(&bus->header->claim, 0);
}

/* Whether the bytes starting at `position` have been written over. */
static int overwritten(const gb_bus *bus, uint64_t position) {
    return atomic_load(&bus->header->high) > position + bus->header->capacity;
}

static void wake_word(_Atomic uint32_t *word) {
#if defined(__linux__)
    syscall(SYS_futex, (uint32_t *)word, FUTEX_WAKE, 1, NULL, NULL, 0);
#elif defined(GB_OS_SYNC)
    if (__builtin_available(macOS 14.4, *)) {
        os_sync_wake_by_address_any((void *)word, sizeof(uint32_t), OS_SYNC_WAKE_BY_ADDRESS_SHARED);
    }
#else
    (void)word;
#endif
}

uint64_t gb_bus_publish(gb_bus *bus,
                        const uint8_t *topic, uint32_t topic_len,
                        const uint8_t *event, uint32_t event_len,
                        const uint8_t *data, uint32_t data_len) {
    struct header *h = bus->header;
    uint64_t body = (uint64_t)topic_len + event_len + data_len;
    if (body > h->max_message) return 0;
    uint64_t size = (RECORD_SIZE + body + 7) & ~(uint64_t)7;

    take_claim(bus);
    uint64_t sequence = atomic_load(&h->next);
    uint64_t position = h->tail;
    if (atomic_load(&h->high) < position + size) atomic_store(&h->high, position + size);

    /* Messages this one pushes out of reach, by their bytes or by their
     * place in the index. */
    uint64_t oldest = atomic_load(&h->oldest);
    while (oldest < sequence) {
        struct index_entry *e = &bus->index[oldest & h->index_mask];
        if (atomic_load(&e->sequence) == oldest
            && oldest + h->index_mask >= sequence
            && !overwritten(bus, atomic_load(&e->position))) break;
        oldest++;
    }
    atomic_store(&h->oldest, oldest);

    struct record rec = { sequence, topic_len, event_len, data_len, 0 };
    copy_in(bus, position, (const uint8_t *)&rec, RECORD_SIZE);
    uint64_t at = position + RECORD_SIZE;
    if (topic_len) copy_in(bus, at, topic, topic_len);
    at += topic_len;
    if (event_len) copy_in(bus, at, event, event_len);
    at += event_len;
    if (data_len) copy_in(bus, at, data, data_len);

    /* The bytes first, then the index -- position before number -- so a
     * reader that finds the number finds a message behind it. */
    struct index_entry *e = &bus->index[sequence & h->index_mask];
    atomic_store(&e->position, position);
    atomic_store(&e->sequence, sequence);
    h->tail = position + size;
    atomic_store(&h->next, sequence + 1);
    give_claim(bus);

    for (uint32_t i = 0; i < h->slot_count; i++) {
        struct slot *s = &bus->slots[i];
        if (atomic_load_explicit(&s->armed, memory_order_relaxed) == 0) continue;
        if (atomic_exchange(&s->armed, 0) == 0) continue;
        wake_word(&s->armed);
    }
    return sequence;
}

uint64_t gb_bus_next(const gb_bus *bus) {
    return atomic_load(&bus->header->next);
}

uint64_t gb_bus_oldest(const gb_bus *bus) {
    return atomic_load(&bus->header->oldest);
}

int gb_bus_read(const gb_bus *bus, uint64_t sequence, uint8_t *buffer, uint32_t capacity,
                gb_bus_message *out) {
    struct header *h = bus->header;
    if (sequence >= atomic_load(&h->next)) return 0;
    if (sequence < atomic_load(&h->oldest)) return -1;

    struct index_entry *e = &bus->index[sequence & h->index_mask];
    uint64_t before = atomic_load(&e->sequence);
    uint64_t position = atomic_load(&e->position);
    if (before != sequence || atomic_load(&e->sequence) != sequence) return -1;

    struct record rec;
    copy_out(bus, position, (uint8_t *)&rec, RECORD_SIZE);
    if (overwritten(bus, position) || rec.sequence != sequence) return -1;

    uint64_t body = (uint64_t)rec.topic_len + rec.event_len + rec.data_len;
    if (body > h->max_message) return -1;
    out->sequence = sequence;
    out->topic_len = rec.topic_len;
    out->event_len = rec.event_len;
    if (body > capacity) {
        out->data_len = (uint32_t)body;
        return -2;
    }
    out->data_len = rec.data_len;
    copy_out(bus, position + RECORD_SIZE, buffer, body);
    /* Written over while it was copied: what was copied is not the message. */
    if (overwritten(bus, position)) return -1;
    return 1;
}

int gb_bus_claim_slot(gb_bus *bus) {
    uint64_t mine = self_pid();
    for (uint32_t i = 0; i < bus->header->slot_count; i++) {
        struct slot *s = &bus->slots[i];
        uint64_t seen = atomic_load(&s->pid);
        if (seen == 0 || (seen != mine && process_gone(seen))) {
            if (atomic_compare_exchange_strong(&s->pid, &seen, mine)) {
                atomic_store(&s->armed, 0);
                return (int)i;
            }
        }
    }
    return -1;
}

void gb_bus_release_slot(gb_bus *bus, int slot) {
    if (slot < 0 || (uint32_t)slot >= bus->header->slot_count) return;
    atomic_store(&bus->slots[slot].armed, 0);
    atomic_store(&bus->slots[slot].pid, 0);
}

int gb_bus_arm(gb_bus *bus, int slot, uint64_t cursor) {
    atomic_store(&bus->slots[slot].armed, 1);
    return atomic_load(&bus->header->next) > cursor;
}

void gb_bus_wait(gb_bus *bus, int slot, uint64_t timeout_ns) {
    _Atomic uint32_t *word = &bus->slots[slot].armed;
    if (atomic_load(word) != 1) return;
#if defined(__linux__)
    struct timespec ts = { (time_t)(timeout_ns / 1000000000u), (long)(timeout_ns % 1000000000u) };
    syscall(SYS_futex, (uint32_t *)word, FUTEX_WAIT, 1, &ts, NULL, 0);
#elif defined(GB_OS_SYNC)
    if (__builtin_available(macOS 14.4, *)) {
        os_sync_wait_on_address_with_timeout((void *)word, 1, sizeof(uint32_t),
                                             OS_SYNC_WAIT_ON_ADDRESS_SHARED,
                                             OS_CLOCK_MACH_ABSOLUTE_TIME, timeout_ns);
        return;
    }
    struct timespec ts = { 0, 1000000 };
    nanosleep(&ts, NULL);
#elif defined(_WIN32)
    /* One process on Windows: a short sleep stands in for a wake. */
    (void)timeout_ns;
    Sleep(1);
#else
    struct timespec ts = { 0, timeout_ns < 1000000 ? (long)timeout_ns : 1000000 };
    nanosleep(&ts, NULL);
#endif
}

void gb_bus_poke(gb_bus *bus, int slot) {
    _Atomic uint32_t *word = &bus->slots[slot].armed;
    atomic_store(word, 0);
    wake_word(word);
}

#if defined(_WIN32)
struct start { void (*body)(void *); void *context; };

static unsigned __stdcall thread_main(void *p) {
    struct start s = *(struct start *)p;
    free(p);
    s.body(s.context);
    return 0;
}

int gb_thread_start(void (*body)(void *), void *context) {
    struct start *s = malloc(sizeof *s);
    if (s == NULL) return -1;
    s->body = body;
    s->context = context;
    uintptr_t t = _beginthreadex(NULL, 0, thread_main, s, 0, NULL);
    if (t == 0) { free(s); return -1; }
    CloseHandle((HANDLE)t);
    return 0;
}
#else
struct start { void (*body)(void *); void *context; };

static void *thread_main(void *p) {
    struct start s = *(struct start *)p;
    free(p);
    s.body(s.context);
    return NULL;
}

int gb_thread_start(void (*body)(void *), void *context) {
    struct start *s = malloc(sizeof *s);
    if (s == NULL) return -1;
    s->body = body;
    s->context = context;
    pthread_t thread;
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int rc = pthread_create(&thread, &attr, thread_main, s);
    pthread_attr_destroy(&attr);
    if (rc != 0) { free(s); return -1; }
    return 0;
}
#endif

void gb_bus_test_abandon(gb_bus *bus, int32_t pid) {
    struct header *h = bus->header;
    take_claim(bus);
    uint64_t sequence = atomic_load(&h->next);
    uint64_t size = (RECORD_SIZE + 512 + 7) & ~(uint64_t)7;
    uint64_t position = h->tail;
    if (atomic_load(&h->high) < position + size) atomic_store(&h->high, position + size);
    struct record rec = { sequence, 0, 0, 512, 0 };
    copy_in(bus, position, (const uint8_t *)&rec, RECORD_SIZE);
    struct index_entry *e = &bus->index[sequence & h->index_mask];
    atomic_store(&e->position, position);
    atomic_store(&e->sequence, sequence);
    atomic_store(&h->claim, ((uint64_t)(uint32_t)pid << 1) | 1);
}
