#include "AudioPipe.h"
#include <assert.h>
#include <math.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void pcm_tests(void) {
    AudioStreamBasicDescription f={.mFormatID=kAudioFormatLinearPCM,.mFormatFlags=kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked,
        .mBitsPerChannel=16,.mChannelsPerFrame=1,.mBytesPerFrame=2};
    int16_t mono[]={-32768,0,16384,32767};
    AudioBufferList b={.mNumberBuffers=1,.mBuffers={{1,sizeof(mono),mono}}};
    float output[16];
    assert(aw_pcm_decode(&f,&b,0,4,output));
    assert(output[0]==-1 && output[1]==-1 && output[4]==0.5f && output[5]==0.5f);
    assert(!aw_pcm_decode(&f,&b,3,2,output));
    uint8_t big[]={0x40,0x00,0x80,0x00}; b.mBuffers[0].mData=big; b.mBuffers[0].mDataByteSize=4;
    f.mFormatFlags|=kAudioFormatFlagIsBigEndian;
    assert(aw_pcm_decode(&f,&b,0,2,output) && output[0]==0.5f && output[2]==-1);
    float left[]={0.25f,NAN,-0.5f},right[]={-0.25f,0.75f,INFINITY};
    struct { UInt32 count; AudioBuffer buffers[2]; } planar={2,{{1,sizeof(left),left},{1,sizeof(right),right}}};
    f.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked|kAudioFormatFlagIsNonInterleaved;
    f.mBitsPerChannel=32; f.mChannelsPerFrame=2; f.mBytesPerFrame=4;
    assert(aw_pcm_decode(&f,(AudioBufferList *)&planar,0,3,output));
    assert(output[0]==0.25f && output[1]==-0.25f && output[2]==0 && output[3]==0.75f && output[5]==0);
    planar.buffers[1].mDataByteSize=4;
    assert(!aw_pcm_decode(&f,(AudioBufferList *)&planar,0,3,output));
    f.mFormatID=kAudioFormatMPEG4AAC; assert(!aw_pcm_decode(&f,(AudioBufferList *)&planar,0,1,output));
    puts("PASS: mono/stereo PCM, planar channels, endianness, non-finite samples and truncated buffers");
}
static void queue_tests(void) {
    AWRing ring; aw_ring_init(&ring); atomic_store(&ring.gain,0.5f);
    float in[]={0.2f,-0.2f,0.4f,-0.4f,0.6f,-0.6f,0.8f,-0.8f},out[16];
    atomic_store(&ring.maxQueuedFrames,2);
    assert(aw_ring_write(&ring,in,4)==4); aw_ring_render(&ring,out,4);
    assert(fabsf(out[0]-0.3f)<0.00001f && fabsf(out[2]-0.4f)<0.00001f && out[4]==0);
    assert(atomic_load(&ring.droppedFrames)==2 && atomic_load(&ring.underrunFrames)==2);
    float *large=calloc((AW_CAPACITY+20)*2,sizeof(float)); assert(large);
    atomic_store(&ring.maxQueuedFrames,AW_CAPACITY);
    assert(aw_ring_write(&ring,large,AW_CAPACITY+20)==AW_CAPACITY);
    float *rendered=calloc(AW_CAPACITY*2,sizeof(float)); assert(rendered);
    aw_ring_render(&ring,rendered,AW_CAPACITY);
    assert(atomic_load(&ring.writeFrame)==atomic_load(&ring.readFrame));
    float excessive[]={4,-4,NAN,INFINITY}; atomic_store(&ring.gain,1);
    aw_ring_write(&ring,excessive,2); aw_ring_render(&ring,out,2);
    assert(out[0]==1 && out[1]==-1 && out[2]==0 && out[3]==0);
    free(large); free(rendered);
    puts("PASS: queue limit drops old audio, wraparound/overflow, volume, clipping and silent underrun");
}
static void output_stall_test(void) {
    AWRing ring; aw_ring_init(&ring); atomic_store(&ring.gain,1);
    atomic_store(&ring.maxQueuedFrames,AW_CAPACITY);
    atomic_store(&ring.maxAgeNanoseconds,40000000);
    float *old=calloc(AW_CAPACITY*2,sizeof(float)); assert(old);
    for(unsigned i=0;i<AW_CAPACITY*2;i++) old[i]=0.8f;
    assert(aw_ring_write_at(&ring,old,AW_CAPACITY,100000000)==AW_CAPACITY);
    float fresh[]={0.1f,-0.1f,0.2f,-0.2f},out[8];
    assert(aw_ring_write_at(&ring,fresh,2,190000000)==0);
    // A full ring contains no recent samples after the output has stalled.
    // Resuming must produce silence, rather than replaying the old tail.
    aw_ring_render_at(&ring,out,2,200000000);
    assert(out[0]==0 && out[1]==0 && out[2]==0 && out[3]==0);
    assert(atomic_load(&ring.staleFrames)==AW_CAPACITY);
    assert(aw_ring_write_at(&ring,fresh,2,200000001)==2);
    aw_ring_render_at(&ring,out,2,200000002);
    assert(out[0]==0.1f && out[1]==-0.1f && out[2]==0.2f);
    aw_ring_write_at(&ring,fresh,2,210000000);
    aw_ring_write_at(&ring,fresh,2,260000000);
    aw_ring_render_at(&ring,out,2,270000000);
    assert(out[0]==0.1f && atomic_load(&ring.staleFrames)==AW_CAPACITY+2);
    free(old);
    puts("PASS: output-stall recovery discards expired PCM and resumes with fresh audio");
}
enum { TOTAL=140000 };
static AWRing concurrentRing;
static float value(size_t frame) { return (float)(frame%128)/256.f; }
static void *produce(void *unused) {
    (void)unused;
    for(size_t frame=0;frame<TOTAL;) {
        float block[14]; size_t count=TOTAL-frame<7 ? TOTAL-frame : 7;
        for(size_t i=0;i<count;i++) { block[i*2]=value(frame+i); block[i*2+1]=-value(frame+i); }
        size_t written=aw_ring_write(&concurrentRing,block,count); frame+=written;
        if(!written) sched_yield();
    }
    return NULL;
}
static void concurrency_test(void) {
    aw_ring_init(&concurrentRing); atomic_store(&concurrentRing.gain,1); atomic_store(&concurrentRing.maxQueuedFrames,AW_CAPACITY);
    pthread_t thread; assert(!pthread_create(&thread,NULL,produce,NULL));
    for(size_t frame=0;frame<TOTAL;) {
        uint64_t w=atomic_load_explicit(&concurrentRing.writeFrame,memory_order_acquire);
        uint64_t r=atomic_load_explicit(&concurrentRing.readFrame,memory_order_relaxed);
        size_t count=TOTAL-frame<7 ? TOTAL-frame : 7;
        if(w-r<count) { sched_yield(); continue; }
        float block[14]; aw_ring_render(&concurrentRing,block,count);
        for(size_t i=0;i<count;i++) assert(block[i*2]==value(frame+i) && block[i*2+1]==-value(frame+i));
        frame+=count;
    }
    pthread_join(thread,NULL); puts("PASS: simultaneous capture/output preserves 140,000 ordered stereo frames");
}
static void malformed_test(void) {
    uint8_t bytes[64]={0}; float output[128];
    struct { UInt32 count; AudioBuffer buffers[2]; } b={0};
    uint32_t random=13;
    for(unsigned i=0;i<30000;i++) {
        random=random*1664525u+1013904223u;
        AudioStreamBasicDescription f={.mFormatID=(random&1) ? kAudioFormatLinearPCM : 0,
            .mFormatFlags=(random>>2)&63,.mBitsPerChannel=(random>>9)&127,
            .mChannelsPerFrame=(random>>16)&3,.mBytesPerFrame=(random>>18)&15};
        b.count=(random>>22)&3;
        b.buffers[0]=(AudioBuffer){1,(random>>24)&63,bytes};
        b.buffers[1]=(AudioBuffer){1,(random>>25)&63,bytes};
        aw_pcm_decode(&f,(AudioBufferList *)&b,(random>>6)&15,(random>>11)&31,output);
    }
    puts("PASS: 30,000 malformed PCM descriptions under address/undefined-behavior sanitizers");
}
int main(void) { pcm_tests(); queue_tests(); output_stall_test(); concurrency_test(); malformed_test(); return 0; }
