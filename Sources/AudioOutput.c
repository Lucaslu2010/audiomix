#include "AudioOutput.h"
#include <string.h>

enum { OUTPUT_FRAMES=256, OUTPUT_BUFFERS=3 };
static void render(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    AMAudioOutput *o=context;
    am_ring_render(&o->ring,buffer->mAudioData,OUTPUT_FRAMES);
    buffer->mAudioDataByteSize=OUTPUT_FRAMES*2*sizeof(int16_t);
    OSStatus status=AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
    if(status) atomic_store_explicit(&o->callbackError,status,memory_order_relaxed);
}
void am_output_init(AMAudioOutput *o) {
    memset(o,0,sizeof(*o)); am_ring_init(&o->ring); atomic_init(&o->callbackError,0);
}
void am_output_stop(AMAudioOutput *o) {
    if(o->queue) {
        AudioQueueStop(o->queue,true);
        AudioQueueDispose(o->queue,true);
        o->queue=NULL;
    }
    o->sampleRate=0;
}
OSStatus am_output_start(AMAudioOutput *o, unsigned rate, CFStringRef uid) {
    am_output_stop(o);
    uint32_t gain=atomic_load(&o->ring.gainQ16);
    am_ring_init(&o->ring); atomic_store(&o->ring.gainQ16,gain);
    atomic_store(&o->callbackError,0);
    AudioStreamBasicDescription format={0};
    format.mSampleRate=rate; format.mFormatID=kAudioFormatLinearPCM;
    format.mFormatFlags=kLinearPCMFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked;
    format.mBytesPerPacket=4; format.mFramesPerPacket=1; format.mBytesPerFrame=4;
    format.mChannelsPerFrame=2; format.mBitsPerChannel=16;
    OSStatus status=AudioQueueNewOutput(&format,render,o,NULL,NULL,0,&o->queue);
    if(status) return status;
    if(uid) {
        status=AudioQueueSetProperty(o->queue,kAudioQueueProperty_CurrentDevice,&uid,sizeof(uid));
        if(status) goto fail;
    }
    for(unsigned i=0;i<OUTPUT_BUFFERS;i++) {
        AudioQueueBufferRef buffer=NULL;
        status=AudioQueueAllocateBuffer(o->queue,OUTPUT_FRAMES*4,&buffer);
        if(status) goto fail;
        memset(buffer->mAudioData,0,OUTPUT_FRAMES*4);
        buffer->mAudioDataByteSize=OUTPUT_FRAMES*4;
        status=AudioQueueEnqueueBuffer(o->queue,buffer,0,NULL);
        if(status) goto fail;
    }
    status=AudioQueueStart(o->queue,NULL);
    if(status) goto fail;
    o->sampleRate=rate;
    return 0;
fail:
    am_output_stop(o); return status;
}
