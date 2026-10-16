#include "MacVolumeRender.h"
#include "AudioPipe.h"
#include <math.h>
#include <string.h>

void aw_mac_render_init(AWMacRender *r) {
    memset(r,0,sizeof(*r));
    atomic_init(&r->enabled,false); atomic_init(&r->gain,1); atomic_init(&r->peak,0);
    atomic_init(&r->callbacks,0); atomic_init(&r->frames,0);
    atomic_init(&r->invalidBuffers,0); atomic_init(&r->lastCallbackNanoseconds,0);
}
static void silence(AudioBufferList *output) {
    if(output) for(UInt32 i=0;i<output->mNumberBuffers;i++)
        if(output->mBuffers[i].mData) memset(output->mBuffers[i].mData,0,output->mBuffers[i].mDataByteSize);
}
bool aw_mac_render(AWMacRender *r,const AudioBufferList *input,AudioBufferList *output) {
    if(!atomic_load_explicit(&r->enabled,memory_order_relaxed)) { silence(output); return true; }
    atomic_fetch_add_explicit(&r->callbacks,1,memory_order_relaxed);
    atomic_store_explicit(&r->lastCallbackNanoseconds,aw_monotonic_nanoseconds(),memory_order_relaxed);
    if(!input || !output || !r->tapBufferCount || r->tapBufferCount>2 ||
       r->firstTapBuffer>input->mNumberBuffers || r->tapBufferCount>input->mNumberBuffers-r->firstTapBuffer ||
       !output->mNumberBuffers || output->mNumberBuffers>2) goto invalid;
    const AudioBuffer *left=NULL,*right=NULL;
    unsigned leftChannel=0,rightChannel=0,totalInput=0,totalOutput=0;
    size_t frames=0;
    for(UInt32 i=0;i<output->mNumberBuffers;i++) {
        const AudioBuffer *b=&output->mBuffers[i];
        if(!b->mData || !b->mNumberChannels || b->mNumberChannels>2 ||
           b->mDataByteSize%(sizeof(float)*b->mNumberChannels)) goto invalid;
        size_t count=b->mDataByteSize/(sizeof(float)*b->mNumberChannels);
        if(i && count!=frames) goto invalid;
        frames=count; totalOutput+=b->mNumberChannels;
    }
    if(!frames || totalOutput>2) goto invalid;
    for(UInt32 i=0;i<r->tapBufferCount;i++) {
        const AudioBuffer *b=&input->mBuffers[r->firstTapBuffer+i];
        if(!b->mData || !b->mNumberChannels || b->mNumberChannels>2 ||
           frames>b->mDataByteSize/(sizeof(float)*b->mNumberChannels)) goto invalid;
        for(UInt32 ch=0;ch<b->mNumberChannels;ch++) {
            if(totalInput==0) { left=b; leftChannel=ch; }
            if(totalInput==1) { right=b; rightChannel=ch; }
            totalInput++;
        }
    }
    if(!totalInput || totalInput>2) goto invalid;
    if(!right) { right=left; rightChannel=leftChannel; }
    float gain=atomic_load_explicit(&r->gain,memory_order_relaxed),peak=0;
    if(!isfinite(gain)) gain=0;
    gain=fmaxf(0,fminf(1,gain));
    for(size_t frame=0;frame<frames;frame++) {
        float l=((const float *)left->mData)[frame*left->mNumberChannels+leftChannel];
        float rr=((const float *)right->mData)[frame*right->mNumberChannels+rightChannel];
        if(!isfinite(l)) l=0; if(!isfinite(rr)) rr=0;
        peak=fmaxf(peak,fmaxf(fabsf(l),fabsf(rr)));
        float stereo[2]={fmaxf(-1,fminf(1,l*gain)),fmaxf(-1,fminf(1,rr*gain))};
        unsigned channel=0;
        for(UInt32 i=0;i<output->mNumberBuffers;i++) {
            AudioBuffer *b=&output->mBuffers[i];
            for(UInt32 ch=0;ch<b->mNumberChannels;ch++,channel++)
                ((float *)b->mData)[frame*b->mNumberChannels+ch]=totalOutput==1 ? (stereo[0]+stereo[1])*0.5f : stereo[channel];
        }
    }
    atomic_store_explicit(&r->peak,peak,memory_order_relaxed);
    atomic_fetch_add_explicit(&r->frames,frames,memory_order_relaxed);
    return true;
invalid:
    silence(output); atomic_fetch_add_explicit(&r->invalidBuffers,1,memory_order_relaxed); return false;
}
