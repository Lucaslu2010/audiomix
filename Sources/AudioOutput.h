#ifndef AM_AUDIO_OUTPUT_H
#define AM_AUDIO_OUTPUT_H
#include <AudioToolbox/AudioToolbox.h>
#include "Media.h"
typedef struct {
    AudioQueueRef queue;
    AMAudioRing ring;
    unsigned sampleRate;
    _Atomic int callbackError;
} AMAudioOutput;
void am_output_init(AMAudioOutput *output);
OSStatus am_output_start(AMAudioOutput *output, unsigned rate, CFStringRef deviceUID);
void am_output_stop(AMAudioOutput *output);
#endif
