/* ---------------------------------------------------------------------------
 * The topic bus: messages one shard publishes and every shard hears.
 *
 * Shards are processes, and a message published by the one a request landed
 * on has to reach subscribers held by all of them: the event streams and
 * WebSockets of a chat room are spread across shards by the kernel, not by
 * room. So messages go into a ring in a shared region, and each shard reads
 * the ring from where it last stopped.
 *
 * The ring keeps what it has room for, not only what nobody has read yet. A
 * message stays readable, by its number, until newer ones have overwritten
 * it, which is what lets a client that reconnects with the last number it
 * saw -- an event stream's Last-Event-ID -- be sent what it missed, whichever
 * shard it reconnects to.
 *
 * Numbers rise by one per message and start, when the first shard attaches,
 * at the time in microseconds since the epoch. A restarted server so starts
 * above every number the one before it gave out, and a number from before
 * the restart is simply older than anything kept.
 *
 * No lock is held across processes. One writer at a time claims the ring by
 * a compare-and-swap that puts its process ID in the claim word, holds it for
 * the copy of one message, and gives it back. A claim whose process no longer
 * exists is taken over, and whatever that writer left half-written is
 * written over; readers never see it, because a message is readable only
 * once the writer has counted it.
 *
 * Readers take no claim. A reader copies a message out and then checks that
 * the writer has not since reached around the ring to the bytes it copied;
 * if it has, the message is gone, and the copy is thrown away.
 *
 * Each reading process holds a slot with a wake word. It arms the word before
 * it sleeps on it, and a publisher disarms every armed word and wakes whoever
 * sleeps there -- a futex on Linux, os_sync on Darwin -- so a burst of
 * messages costs one wake per shard rather than one per message. A reader
 * checks the ring once more after arming, so a message published between
 * its last read and the arming is not slept through. Nothing about this
 * needs a descriptor, so it holds for shards that are forked and for shards
 * that are started afresh alike.
 * ------------------------------------------------------------------------- */
#ifndef GARUDA_BUS_H
#define GARUDA_BUS_H

#include <stddef.h>
#include <stdint.h>

typedef struct gb_bus gb_bus;

/* The bytes a region needs for a ring of `ring_bytes` (rounded up to a power
 * of two, 64 KiB at the least) and `slots` reading processes. */
size_t gb_bus_region_size(uint64_t ring_bytes, uint32_t slots);

/* The ring in `region`, laid out by whichever process attaches first; every
 * process passes the same `ring_bytes` and `slots`. NULL when the region is
 * too small. */
gb_bus *gb_bus_attach(void *region, size_t region_bytes, uint64_t ring_bytes, uint32_t slots);
void gb_bus_detach(gb_bus *bus);

/* The largest message the ring takes, topic, event name and data together. */
uint32_t gb_bus_max_message(const gb_bus *bus);

/* Publishes a message and returns its number, or 0 when it is larger than
 * gb_bus_max_message. Every armed slot is woken. */
uint64_t gb_bus_publish(gb_bus *bus,
                        const uint8_t *topic, uint32_t topic_len,
                        const uint8_t *event, uint32_t event_len,
                        const uint8_t *data, uint32_t data_len);

/* The number the next message will be given. Every message below it has
 * been published. */
uint64_t gb_bus_next(const gb_bus *bus);

/* The lowest number that may still be readable. A message below it is gone;
 * one at or above it may be gone by the time it is read. */
uint64_t gb_bus_oldest(const gb_bus *bus);

/* A message copied out of the ring. The buffer holds the topic, then the
 * event name, then the data; the lengths say where each ends. */
typedef struct gb_bus_message {
    uint64_t sequence;
    uint32_t topic_len;
    uint32_t event_len;
    uint32_t data_len;
} gb_bus_message;

/* Copies message `sequence` into `buffer`, which holds `capacity` bytes.
 * Returns 1 with `out` filled in; 0 when it has not been published yet; -1
 * when it is gone; -2 when `capacity` is too small, with `out->data_len` set
 * to the room needed, topic and event name included. A buffer of
 * gb_bus_max_message bytes is always large enough. */
int gb_bus_read(const gb_bus *bus, uint64_t sequence, uint8_t *buffer, uint32_t capacity,
                gb_bus_message *out);

/* Takes a slot for this process to be woken through: a free one, or one whose
 * process has gone. -1 when every slot is held. */
int gb_bus_claim_slot(gb_bus *bus);
void gb_bus_release_slot(gb_bus *bus, int slot);

/* Arms `slot` for a wake at the next publish. Returns 1 when a message at or
 * above `cursor` has already been published, which the caller should read
 * now rather than sleep on. */
int gb_bus_arm(gb_bus *bus, int slot, uint64_t cursor);

/* Sleeps while `slot` stays armed, for at most `timeout_ns`. */
void gb_bus_wait(gb_bus *bus, int slot, uint64_t timeout_ns);

/* Disarms `slot` and wakes whoever sleeps on it, as a publish would. */
void gb_bus_poke(gb_bus *bus, int slot);

/* Starts a detached thread running `body(context)`. Returns 0, or -1. */
int gb_thread_start(void (*body)(void *), void *context);

/* For tests: leaves the ring as a writer in process `pid` would that died
 * part-way through a message -- claimed, its bytes half written. */
void gb_bus_test_abandon(gb_bus *bus, int32_t pid);

#endif
