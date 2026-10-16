#include "AudioPipe.h"
#include <math.h>
#include <string.h>
#include <time.h>

uint64_t aw_monotonic_nanoseconds(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }

void aw_ring_init(AWRing *r) {
    atomic_init(&r->readFrame,0); atomic_init(&r->writeFrame,0);
    atomic_init(&r->underrunFrames,0); atomic_init(&r->droppedFrames,0);
    atomic_init(&r->maxAgeNanoseconds,0); atomic_init(&r->staleFrames,0);
    atomic_init(&r->maxQueuedFrames,1920); atomic_init(&r->gain,0.35f);
}
size_t aw_ring_write(AWRing *r,const float *data,size_t frames) {
    return aw_ring_write_at(r,data,frames,aw_monotonic_nanoseconds());
}
size_t aw_ring_write_at(AWRing *r,const float *data,size_t frames,uint64_t now) {
    uint64_t w=atomic_load_explicit(&r->writeFrame,memory_order_relaxed);
    uint64_t rd=atomic_load_explicit(&r->readFrame,memory_order_acquire);
    size_t freeFrames=AW_CAPACITY-(size_t)(w-rd);
    size_t count=frames<freeFrames ? frames : freeFrames;
    for(size_t i=0;i<count;i++) {
        size_t slot=(size_t)((w+i)%AW_CAPACITY)*2;
        r->samples[slot]=data[i*2]; r->samples[slot+1]=data[i*2+1];
        r->receivedNanoseconds[(w+i)%AW_CAPACITY]=now;
    }
    atomic_store_explicit(&r->writeFrame,w+count,memory_order_release);
    atomic_fetch_add_explicit(&r->droppedFrames,frames-count,memory_order_relaxed);
    return count;
}
void aw_ring_render(AWRing *r,float *data,size_t frames) {
    aw_ring_render_at(r,data,frames,aw_monotonic_nanoseconds());
}
void aw_ring_render_at(AWRing *r,float *data,size_t frames,uint64_t now) {
    uint64_t rd=atomic_load_explicit(&r->readFrame,memory_order_relaxed);
    uint64_t w=atomic_load_explicit(&r->writeFrame,memory_order_acquire);
    size_t available=(size_t)(w-rd);
    uint64_t maxAge=atomic_load_explicit(&r->maxAgeNanoseconds,memory_order_relaxed);
    size_t stale=0;
    if(maxAge && now>maxAge) {
        uint64_t cutoff=now-maxAge;
        // Age is measured since Mac receipt. It does not include device capture
        // or output buffering. Only the consumer ever advances readFrame.
        while(stale<available && r->receivedNanoseconds[(rd+stale)%AW_CAPACITY]<cutoff) stale++;
        rd+=stale; available-=stale;
        atomic_fetch_add_explicit(&r->droppedFrames,stale,memory_order_relaxed);
        atomic_fetch_add_explicit(&r->staleFrames,stale,memory_order_relaxed);
    }
    unsigned limit=atomic_load_explicit(&r->maxQueuedFrames,memory_order_relaxed);
    if(available>limit) {
        size_t drop=available-limit; rd+=drop; available-=drop;
        atomic_fetch_add_explicit(&r->droppedFrames,drop,memory_order_relaxed);
    }
    size_t count=frames<available ? frames : available;
    float gain=atomic_load_explicit(&r->gain,memory_order_relaxed);
    if(!isfinite(gain)) gain=0;
    for(size_t i=0;i<count;i++) for(size_t ch=0;ch<2;ch++) {
        float value=r->samples[((rd+i)%AW_CAPACITY)*2+ch]*gain;
        data[i*2+ch]=isfinite(value) ? fmaxf(-1,fminf(1,value)) : 0;
    }
    memset(data+count*2,0,(frames-count)*2*sizeof(float));
    atomic_store_explicit(&r->readFrame,rd+count,memory_order_release);
    atomic_fetch_add_explicit(&r->underrunFrames,frames-count,memory_order_relaxed);
}
bool aw_pcm_decode(const AudioStreamBasicDescription *f,const AudioBufferList *b,
                   size_t offset,size_t frames,float *out) {
    if(!f || !b || !out || f->mFormatID!=kAudioFormatLinearPCM ||
       !f->mChannelsPerFrame || f->mChannelsPerFrame>2) return false;
    bool planar=(f->mFormatFlags&kAudioFormatFlagIsNonInterleaved)!=0;
    bool floating=(f->mFormatFlags&kAudioFormatFlagIsFloat)!=0;
    bool big=(f->mFormatFlags&kAudioFormatFlagIsBigEndian)!=0;
    unsigned bytes=f->mBitsPerChannel/8,channels=f->mChannelsPerFrame;
    if((floating && bytes!=4 && bytes!=8) || (!floating && (bytes!=2 && bytes!=4)) ||
       (!floating && !(f->mFormatFlags&kAudioFormatFlagIsSignedInteger)) ||
       f->mBitsPerChannel%8 || !f->mBytesPerFrame ||
       f->mBytesPerFrame<bytes*(planar ? 1 : channels) ||
       b->mNumberBuffers!=(planar ? channels : 1)) return false;
    for(unsigned i=0;i<b->mNumberBuffers;i++) {
        size_t capacity=b->mBuffers[i].mDataByteSize/f->mBytesPerFrame;
        if(!b->mBuffers[i].mData || offset>capacity || frames>capacity-offset) return false;
    }
    for(size_t i=0;i<frames;i++) for(unsigned ch=0;ch<2;ch++) {
        unsigned source=channels==1 ? 0 : ch;
        const uint8_t *p=(const uint8_t *)b->mBuffers[planar ? source : 0].mData+
            (offset+i)*f->mBytesPerFrame+(planar ? 0 : source*bytes);
        float value;
        if(bytes==2) {
            uint16_t bits; memcpy(&bits,p,2); if(big) bits=__builtin_bswap16(bits);
            value=(float)(int16_t)bits/32768.f;
        } else if(bytes==4) {
            uint32_t bits; memcpy(&bits,p,4); if(big) bits=__builtin_bswap32(bits);
            if(floating) memcpy(&value,&bits,4); else value=(float)(int32_t)bits/2147483648.f;
        } else {
            uint64_t bits; double d; memcpy(&bits,p,8); if(big) bits=__builtin_bswap64(bits);
            memcpy(&d,&bits,8); value=(float)d;
        }
        out[i*2+ch]=isfinite(value) ? value : 0;
    }
    return true;
}
static OSStatus render(void *context,AudioUnitRenderActionFlags *flags,
                       const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *data) {
    (void)flags; (void)time; (void)bus; AWOutput *o=context;
    if(data && data->mNumberBuffers==1 && data->mBuffers[0].mData &&
       data->mBuffers[0].mDataByteSize>=frames*2*sizeof(float)) {
        if(atomic_load_explicit(&o->testTone,memory_order_relaxed)) {
            float *samples=data->mBuffers[0].mData;
            float gain=atomic_load_explicit(&o->ring.gain,memory_order_relaxed);
            double step=440.*6.283185307179586/atomic_load(&o->sampleRate);
            for(UInt32 i=0;i<frames;i++) {
                float value=(float)(sin(o->tonePhase)*0.05*gain);
                samples[i*2]=value; samples[i*2+1]=value;
                o->tonePhase+=step; if(o->tonePhase>=6.283185307179586) o->tonePhase-=6.283185307179586;
            }
        } else aw_ring_render(&o->ring,data->mBuffers[0].mData,frames);
        atomic_fetch_add_explicit(&o->renderedFrames,frames,memory_order_relaxed); return noErr;
    }
    if(data) for(UInt32 i=0;i<data->mNumberBuffers;i++)
        if(data->mBuffers[i].mData) memset(data->mBuffers[i].mData,0,data->mBuffers[i].mDataByteSize);
    atomic_store(&o->callbackError,kAudio_ParamError); return kAudio_ParamError;
}
void aw_output_init(AWOutput *o) {
    memset(o,0,sizeof(*o)); aw_ring_init(&o->ring);
    atomic_init(&o->callbackError,0); atomic_init(&o->sampleRate,0);
    atomic_init(&o->renderedFrames,0); atomic_init(&o->testTone,false);
}
void aw_output_stop(AWOutput *o) {
    if(o->unit) { AudioOutputUnitStop(o->unit); AudioUnitUninitialize(o->unit); AudioComponentInstanceDispose(o->unit); o->unit=NULL; }
}
static void readDevice(AudioDeviceID device,AudioObjectPropertySelector selector,void *value,UInt32 bytes) {
    AudioObjectPropertyAddress a={selector,selector==kAudioDevicePropertyBufferFrameSize ? kAudioObjectPropertyScopeGlobal :
        kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
    AudioObjectGetPropertyData(device,&a,0,NULL,&bytes,value);
}
OSStatus aw_output_configure(AWOutput *o,AudioDeviceID device,double rate) {
    aw_output_stop(o);
    atomic_store(&o->testTone,false); atomic_store(&o->renderedFrames,0); o->tonePhase=0;
    o->setupStep="validate sample rate"; o->deviceID=device; o->deviceName[0]=0;
    o->deviceBufferFrames=0; o->deviceLatencyFrames=0; o->safetyFrames=0; o->deviceSampleRate=0;
    o->maximumFramesPerSlice=0; memset(&o->hardwareFormat,0,sizeof(o->hardwareFormat));
    if(!isfinite(rate) || rate<8000 || rate>192000) return kAudio_ParamError;
    OSStatus status;
    if(!device) {
        o->setupStep="resolve system default output";
        AudioObjectPropertyAddress a={kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        UInt32 size=sizeof(device);
        status=AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,&device);
        if(status || !device) return status ? status : kAudioHardwareBadDeviceError;
    }
    o->deviceID=device; o->setupStep="validate output device is alive";
    AudioObjectPropertyAddress alive={kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 value=0,size=sizeof(value);
    status=AudioObjectGetPropertyData(device,&alive,0,NULL,&size,&value);
    if(status || !value) return status ? status : kAudioHardwareBadDeviceError;
    o->setupStep="validate output streams";
    AudioObjectPropertyAddress streams={kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
    size=0;
    status=AudioObjectGetPropertyDataSize(device,&streams,0,NULL,&size);
    if(status || !size) return status ? status : kAudioHardwareBadDeviceError;
    AudioObjectPropertyAddress name={kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    CFStringRef deviceName=NULL; size=sizeof(deviceName);
    if(!AudioObjectGetPropertyData(device,&name,0,NULL,&size,&deviceName) && deviceName) {
        CFStringGetCString(deviceName,o->deviceName,sizeof(o->deviceName),kCFStringEncodingUTF8); CFRelease(deviceName);
    }
    readDevice(device,kAudioDevicePropertyBufferFrameSize,&o->deviceBufferFrames,sizeof(UInt32));
    readDevice(device,kAudioDevicePropertyLatency,&o->deviceLatencyFrames,sizeof(UInt32));
    readDevice(device,kAudioDevicePropertySafetyOffset,&o->safetyFrames,sizeof(UInt32));
    AudioObjectPropertyAddress a={kAudioDevicePropertyNominalSampleRate,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    size=sizeof(o->deviceSampleRate); AudioObjectGetPropertyData(device,&a,0,NULL,&size,&o->deviceSampleRate);
    o->setupStep="find AUHAL component";
    AudioComponentDescription d={kAudioUnitType_Output,kAudioUnitSubType_HALOutput,kAudioUnitManufacturer_Apple,0,0};
    AudioComponent component=AudioComponentFindNext(NULL,&d);
    if(!component) return kAudioUnitErr_InvalidProperty;
    o->setupStep="create AUHAL instance";
    status=AudioComponentInstanceNew(component,&o->unit); if(status) return status;
    UInt32 enabled=1,disabled=0;
    o->setupStep="enable output I/O (output bus 0)";
    status=AudioUnitSetProperty(o->unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Output,0,&enabled,sizeof(enabled)); if(status) goto fail;
    o->setupStep="disable input I/O (input bus 1)";
    status=AudioUnitSetProperty(o->unit,kAudioOutputUnitProperty_EnableIO,kAudioUnitScope_Input,1,&disabled,sizeof(disabled)); if(status) goto fail;
    o->setupStep="bind selected device (CurrentDevice)";
    status=AudioUnitSetProperty(o->unit,kAudioOutputUnitProperty_CurrentDevice,kAudioUnitScope_Global,0,&device,sizeof(device)); if(status) goto fail;
    size=sizeof(o->hardwareFormat);
    AudioUnitGetProperty(o->unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Output,0,&o->hardwareFormat,&size);
    AudioStreamBasicDescription f={.mSampleRate=rate,.mFormatID=kAudioFormatLinearPCM,
        .mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,.mBytesPerPacket=8,
        .mFramesPerPacket=1,.mBytesPerFrame=8,.mChannelsPerFrame=2,.mBitsPerChannel=32};
    o->setupStep="set stereo float client stream format";
    status=AudioUnitSetProperty(o->unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,0,&f,sizeof(f)); if(status) goto fail;
    AURenderCallbackStruct callback={render,o};
    o->setupStep="install render callback";
    status=AudioUnitSetProperty(o->unit,kAudioUnitProperty_SetRenderCallback,kAudioUnitScope_Input,0,&callback,sizeof(callback)); if(status) goto fail;
    UInt32 maximum=4096;
    o->setupStep="set MaximumFramesPerSlice=4096";
    status=AudioUnitSetProperty(o->unit,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&maximum,sizeof(maximum)); if(status) goto fail;
    o->setupStep="initialize AUHAL";
    status=AudioUnitInitialize(o->unit); if(status) goto fail;
    size=sizeof(o->maximumFramesPerSlice);
    AudioUnitGetProperty(o->unit,kAudioUnitProperty_MaximumFramesPerSlice,kAudioUnitScope_Global,0,&o->maximumFramesPerSlice,&size);
    o->setupStep="configured";
    atomic_store(&o->sampleRate,(unsigned)rate); atomic_store(&o->callbackError,0); return noErr;
fail: aw_output_stop(o); return status;
}
OSStatus aw_output_start(AWOutput *o) {
    o->setupStep="start AUHAL";
    OSStatus status=o->unit ? AudioOutputUnitStart(o->unit) : kAudio_ParamError;
    if(!status) o->setupStep="running";
    return status;
}
OSStatus aw_output_configure_uid(AWOutput *o,CFStringRef uid,double rate) {
    AudioDeviceID device=kAudioObjectUnknown;
    if(uid) {
        AudioObjectPropertyAddress a={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        UInt32 size=sizeof(device);
        OSStatus status=AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(uid),&uid,&size,&device);
        if(status || device==kAudioObjectUnknown) {
            aw_output_stop(o);
            o->setupStep="resolve selected output UID (device unavailable; reconnect and Refresh)";
            o->deviceID=0; o->deviceName[0]=0;
            o->deviceSampleRate=0; o->deviceBufferFrames=0; o->maximumFramesPerSlice=0;
            o->deviceLatencyFrames=0; o->safetyFrames=0;
            atomic_store(&o->renderedFrames,0); atomic_store(&o->callbackError,0);
            memset(&o->hardwareFormat,0,sizeof(o->hardwareFormat));
            return status ? status : kAudioHardwareBadDeviceError;
        }
    }
    return aw_output_configure(o,device,rate);
}
