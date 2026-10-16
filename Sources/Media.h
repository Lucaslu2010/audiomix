#ifndef AM_MEDIA_H
#define AM_MEDIA_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdatomic.h>
#include "sbc.h"

#define AM_RING_FRAMES 4096u
typedef struct {
    int16_t samples[AM_RING_FRAMES*2];
    _Atomic uint64_t readFrame, writeFrame, underrunFrames, droppedFrames;
    _Atomic uint32_t gainQ16;
} AMAudioRing;
void am_ring_init(AMAudioRing *ring);
size_t am_ring_write(AMAudioRing *ring, const int16_t *stereo, size_t frames,
                     unsigned maximumQueuedFrames);
void am_ring_render(AMAudioRing *ring, int16_t *stereo, size_t frames);

typedef struct {
    sbc_t decoder;
    bool initialized, haveSequence, haveSSRC;
    uint16_t sequence;
    uint32_t ssrc;
    uint8_t fragment[2048], configuration[4];
    size_t fragmentLength;
    uint64_t packets, lostPackets, invalidPackets, decodedFrames;
    unsigned rate, channels, queueFrames;
    AMAudioRing *ring;
} AMMedia;
int am_media_init(AMMedia *media, const uint8_t configuration[4], AMAudioRing *ring,
                  unsigned queueMilliseconds);
void am_media_finish(AMMedia *media);
bool am_media_packet(AMMedia *media, const uint8_t *packet, size_t length);
#endif
