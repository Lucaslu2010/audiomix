#include "MacVolumeRender.h"
#include "AudioPipe.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>

typedef struct { UInt32 count; AudioBuffer buffers[3]; } ThreeBuffers;
static void closeTo(float actual,float expected) { assert(fabsf(actual-expected)<0.00001f); }
int main(void) {
    AWMacRender mac; aw_mac_render_init(&mac);
    mac.firstTapBuffer=1; mac.tapBufferCount=1; atomic_store(&mac.enabled,true);
    float mic[4]={0.99f,0.99f,0.99f,0.99f},music[4]={0.8f,-0.4f,0.2f,0.6f},result[4]={0};
    ThreeBuffers in={2,{{1,sizeof(mic),mic},{2,sizeof(music),music}}};
    AudioBufferList out={1,{{2,sizeof(result),result}}};
    atomic_store(&mac.gain,0.5f);
    assert(aw_mac_render(&mac,(AudioBufferList *)&in,&out));
    closeTo(result[0],0.4f); closeTo(result[1],-0.2f); closeTo(result[2],0.1f); closeTo(result[3],0.3f);
    assert(atomic_load(&mac.frames)==2); closeTo(atomic_load(&mac.peak),0.8f);

    // Separate source gains remain independent; mute preserves source samples.
    static AWRing ipad; aw_ring_init(&ipad); atomic_store(&ipad.gain,0.25f);
    aw_ring_write(&ipad,music,2); atomic_store(&mac.gain,0);
    assert(aw_mac_render(&mac,(AudioBufferList *)&in,&out));
    for(unsigned i=0;i<4;i++) closeTo(result[i],0);
    aw_ring_render(&ipad,result,2); closeTo(result[0],0.2f); closeTo(result[1],-0.1f);
    closeTo(music[0],0.8f); closeTo(mic[0],0.99f);

    // Planar tap channels after a disabled hardware-input buffer, planar output.
    float left[2]={0.3f,0.7f},right[2]={-0.5f,-0.9f},ol[2]={0},orr[2]={0};
    in=(ThreeBuffers){3,{{1,0,NULL},{1,sizeof(left),left},{1,sizeof(right),right}}};
    ThreeBuffers planarOut={2,{{1,sizeof(ol),ol},{1,sizeof(orr),orr}}};
    mac.tapBufferCount=2; atomic_store(&mac.gain,1);
    assert(aw_mac_render(&mac,(AudioBufferList *)&in,(AudioBufferList *)&planarOut));
    closeTo(ol[0],0.3f); closeTo(orr[1],-0.9f);
    float mono[2]={0}; out=(AudioBufferList){1,{{1,sizeof(mono),mono}}};
    assert(aw_mac_render(&mac,(AudioBufferList *)&in,&out)); closeTo(mono[0],-0.1f);

    // A malformed/short tap must silence every output buffer without reading it.
    in.buffers[2].mDataByteSize=sizeof(float); ol[0]=1; orr[0]=1;
    assert(!aw_mac_render(&mac,(AudioBufferList *)&in,(AudioBufferList *)&planarOut));
    closeTo(ol[0],0); closeTo(orr[0],0); assert(atomic_load(&mac.invalidBuffers)==1);
    in.buffers[2].mDataByteSize=sizeof(right); left[0]=NAN; right[0]=INFINITY; left[1]=4;
    assert(aw_mac_render(&mac,(AudioBufferList *)&in,(AudioBufferList *)&planarOut));
    closeTo(ol[0],0); closeTo(orr[0],0); closeTo(ol[1],1);
    atomic_store(&mac.gain,NAN);
    assert(aw_mac_render(&mac,(AudioBufferList *)&in,(AudioBufferList *)&planarOut)); closeTo(ol[1],0);
    atomic_store(&mac.enabled,false); ol[0]=1;
    assert(aw_mac_render(&mac,NULL,(AudioBufferList *)&planarOut)); closeTo(ol[0],0);
    puts("PASS: independent Mac/USB gains, mute, excluded hardware inputs, stereo/planar/mono routing and malformed/non-finite tap buffers");
    return 0;
}
