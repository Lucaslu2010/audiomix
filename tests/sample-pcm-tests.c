#include "SamplePCM.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static CMSampleBufferRef make_sample(const AudioStreamBasicDescription *format,CMItemCount frames,
                                     const AudioBufferList *buffers) {
    CMAudioFormatDescriptionRef description=NULL; CMSampleBufferRef sample=NULL;
    assert(!CMAudioFormatDescriptionCreate(kCFAllocatorDefault,format,0,NULL,0,NULL,NULL,&description));
    CMSampleTimingInfo time={CMTimeMake(1,48000),kCMTimeZero,kCMTimeInvalid};
    assert(!CMSampleBufferCreate(kCFAllocatorDefault,NULL,true,NULL,NULL,description,frames,
        frames ? 1 : 0,frames ? &time : NULL,0,NULL,&sample));
    CFRelease(description);
    if(buffers) assert(!CMSampleBufferSetDataBufferFromAudioBufferList(sample,kCFAllocatorDefault,kCFAllocatorDefault,0,buffers));
    return sample;
}
static void interleaved(void) {
    AudioStreamBasicDescription f={48000,kAudioFormatLinearPCM,kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked,4,1,4,2,16,0};
    int16_t data[]={-32768,32767,0,16384,8192,-8192};
    AudioBufferList b={1,{{2,sizeof(data),data}}};
    CMSampleBufferRef sample=make_sample(&f,3,&b);
    float out[6]; AWSampleReadInfo info;
    assert(!aw_sample_read_stereo(sample,0,3,out,&info));
    assert(info.accessStatus==noErr && !info.usedCopy && info.requiredListBytes==offsetof(AudioBufferList,mBuffers)+sizeof(AudioBuffer));
    assert(out[0]==-1 && out[3]==0.5f && out[4]==0.25f);
    assert(!aw_sample_copy_stereo(sample,1,2,out) && out[0]==0 && out[1]==0.5f && out[2]==0.25f);
    assert(aw_sample_copy_stereo(sample,2,2,out)==kCMSampleBufferError_SampleIndexOutOfRange);
    CFRelease(sample);
}
static void planar(void) {
    AudioStreamBasicDescription f={48000,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked|kAudioFormatFlagIsNonInterleaved,4,1,4,2,32,0};
    float left[]={0.25f,NAN,-0.5f},right[]={-0.25f,0.75f,INFINITY};
    struct { UInt32 count; AudioBuffer buffers[2]; } b={2,{{1,sizeof(left),left},{1,sizeof(right),right}}};
    CMSampleBufferRef sample=make_sample(&f,3,(AudioBufferList *)&b);
    float out[6]; AWSampleReadInfo info;
    assert(!aw_sample_read_stereo(sample,0,3,out,&info));
    assert(info.accessStatus==noErr && !info.usedCopy && info.requiredListBytes==offsetof(AudioBufferList,mBuffers)+2*sizeof(AudioBuffer));
    assert(out[0]==0.25f && out[1]==-0.25f && out[2]==0 && out[3]==0.75f);
    assert(!aw_sample_copy_stereo(sample,1,2,out));
    assert(out[0]==0 && out[1]==0.75f && out[2]==-0.5f && out[3]==0);
    CFRelease(sample);
}
static void fragmented(void) {
    AudioStreamBasicDescription f={48000,kAudioFormatLinearPCM,kAudioFormatFlagIsSignedInteger|kAudioFormatFlagIsPacked,2,1,2,1,16,0};
    CMSampleBufferRef sample=make_sample(&f,4,NULL);
    uint8_t data[]={0,0x80,0,0,0,0x40,0,0x20};
    CMBlockBufferRef block=NULL; assert(!CMBlockBufferCreateEmpty(kCFAllocatorDefault,2,0,&block));
    assert(!CMBlockBufferAppendMemoryBlock(block,data,3,kCFAllocatorNull,NULL,0,3,0));
    assert(!CMBlockBufferAppendMemoryBlock(block,data+3,5,kCFAllocatorNull,NULL,0,5,0));
    assert(!CMSampleBufferSetDataBuffer(sample,block)); CFRelease(block);
    float out[8]; AWSampleReadInfo info;
    assert(!aw_sample_read_stereo(sample,0,4,out,&info));
    assert(out[0]==-1 && out[1]==-1 && out[4]==0.5f && out[6]==0.25f);
    assert(!aw_sample_copy_stereo(sample,2,2,out) && out[0]==0.5f && out[2]==0.25f);
    CFRelease(sample);
}
static void empty_and_missing(void) {
    AudioStreamBasicDescription f={48000,kAudioFormatLinearPCM,kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,8,1,8,2,32,0};
    CMSampleBufferRef empty=make_sample(&f,0,NULL); AWSampleReadInfo info; float out[2]={0.25f,0.25f};
    assert(!aw_sample_read_stereo(empty,0,0,NULL,&info));
    assert(aw_sample_read_stereo(empty,0,1,out,&info)==kCMSampleBufferError_SampleIndexOutOfRange);
    CFRelease(empty);
    CMSampleBufferRef missing=make_sample(&f,1,NULL);
    assert(aw_sample_read_stereo(missing,0,1,out,&info)!=noErr);
    assert(out[0]==0.25f && out[1]==0.25f);
    CFRelease(missing);
}
int main(void) {
    interleaved(); planar(); fragmented(); empty_and_missing();
    puts("PASS: real Core Media interleaved/planar/fragmented PCM, copy fallback, empty/missing data and ranges");
    return 0;
}
