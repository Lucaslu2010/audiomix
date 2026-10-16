#ifndef AW_MAC_VOLUME_RENDER_H
#define AW_MAC_VOLUME_RENDER_H
#include <CoreAudio/CoreAudio.h>
#include <stdatomic.h>
#include <stdbool.h>
typedef struct {
    _Atomic bool enabled;
    _Atomic float gain, peak;
    _Atomic uint64_t callbacks, frames, invalidBuffers, lastCallbackNanoseconds;
    UInt32 firstTapBuffer, tapBufferCount;
} AWMacRender;
void aw_mac_render_init(AWMacRender *render);
// HAL IOProc buffers are native Float32, interleaved within each stream.
// Only the explicitly selected tap buffers are read; hardware inputs are ignored.
bool aw_mac_render(AWMacRender *render,const AudioBufferList *input,AudioBufferList *output);
#endif
