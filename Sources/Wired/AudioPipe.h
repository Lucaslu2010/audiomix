#ifndef AW_AUDIO_PIPE_H
#define AW_AUDIO_PIPE_H
#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#define AW_CAPACITY 16384u
typedef struct {
    float samples[AW_CAPACITY * 2];
    uint64_t receivedNanoseconds[AW_CAPACITY];
    _Atomic uint64_t readFrame, writeFrame, underrunFrames, droppedFrames;
    _Atomic uint64_t maxAgeNanoseconds, staleFrames;
    _Atomic unsigned maxQueuedFrames;
    _Atomic float gain;
} AWRing;
void aw_ring_init(AWRing *ring);
size_t aw_ring_write(AWRing *ring,const float *stereo,size_t frames);
void aw_ring_render(AWRing *ring,float *stereo,size_t frames);
// Explicit monotonic times make output-stall behavior testable without sleeps.
size_t aw_ring_write_at(AWRing *ring,const float *stereo,size_t frames,uint64_t now);
void aw_ring_render_at(AWRing *ring,float *stereo,size_t frames,uint64_t now);
uint64_t aw_monotonic_nanoseconds(void);
// Decode mono/stereo, interleaved/planar PCM to finite stereo float samples.
bool aw_pcm_decode(const AudioStreamBasicDescription *format,const AudioBufferList *buffers,
                   size_t offset,size_t frames,float *stereo);
typedef struct {
    AWRing ring;
    AudioUnit unit;
    _Atomic OSStatus callbackError;
    _Atomic unsigned sampleRate;
    _Atomic uint64_t renderedFrames;
    _Atomic bool testTone;
    double tonePhase;
    UInt32 deviceBufferFrames, deviceLatencyFrames, safetyFrames;
    Float64 deviceSampleRate;
    // Setup diagnostics are written only while the output is stopped.
    const char *setupStep;
    AudioDeviceID deviceID;
    char deviceName[256];
    AudioStreamBasicDescription hardwareFormat;
    UInt32 maximumFramesPerSlice;
} AWOutput;
void aw_output_init(AWOutput *output);
OSStatus aw_output_configure(AWOutput *output,AudioDeviceID device,double sampleRate);
// Resolve the persistent UID immediately before setup. NULL follows the default
// at setup time; a missing explicit device fails instead of changing outputs.
OSStatus aw_output_configure_uid(AWOutput *output,CFStringRef deviceUID,double sampleRate);
OSStatus aw_output_start(AWOutput *output);
void aw_output_stop(AWOutput *output);
#endif
