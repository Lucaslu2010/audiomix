#include "SamplePCM.h"
#include <limits.h>

static OSStatus validate(CMSampleBufferRef sample,size_t offset,size_t frames,float *out,
                         const AudioStreamBasicDescription **format) {
    if(!sample || (!out && frames) || frames>AW_SAMPLE_CHUNK_FRAMES || offset>INT32_MAX)
        return kAudio_ParamError;
    CMFormatDescriptionRef description=CMSampleBufferGetFormatDescription(sample);
    if(!description || CMFormatDescriptionGetMediaType(description)!=kCMMediaType_Audio)
        return kCMSampleBufferError_InvalidMediaTypeForOperation;
    *format=CMAudioFormatDescriptionGetStreamBasicDescription(description);
    const AudioStreamBasicDescription *f=*format;
    if(!f || f->mFormatID!=kAudioFormatLinearPCM || !f->mChannelsPerFrame || f->mChannelsPerFrame>2 ||
       !f->mBytesPerFrame || f->mBytesPerFrame>16)
        return kAudioFormatUnsupportedDataFormatError;
    CMItemCount count=CMSampleBufferGetNumSamples(sample);
    if(count<0 || offset>(size_t)count || frames>(size_t)count-offset)
        return kCMSampleBufferError_SampleIndexOutOfRange;
    if(frames && !CMSampleBufferDataIsReady(sample)) return kCMSampleBufferError_BufferNotReady;
    return noErr;
}
OSStatus aw_sample_copy_stereo(CMSampleBufferRef sample,size_t offset,size_t frames,float *out) {
    const AudioStreamBasicDescription *format=NULL;
    OSStatus status=validate(sample,offset,frames,out,&format);
    if(status || !frames) return status;
    bool planar=(format->mFormatFlags&kAudioFormatFlagIsNonInterleaved)!=0;
    // Bounded scratch on the capture queue, never on the output render callback.
    _Alignas(16) uint8_t scratch[2][AW_SAMPLE_CHUNK_FRAMES*16];
    struct { UInt32 count; AudioBuffer buffers[2]; } storage={0};
    storage.count=planar ? format->mChannelsPerFrame : 1;
    for(UInt32 i=0;i<storage.count;i++)
        storage.buffers[i]=(AudioBuffer){planar ? 1 : format->mChannelsPerFrame,
            (UInt32)(frames*format->mBytesPerFrame),scratch[i]};
    status=CMSampleBufferCopyPCMDataIntoAudioBufferList(sample,(int32_t)offset,(int32_t)frames,(AudioBufferList *)&storage);
    if(status) return status;
    return aw_pcm_decode(format,(AudioBufferList *)&storage,0,frames,out) ? noErr : kAudioFormatUnsupportedDataFormatError;
}
OSStatus aw_sample_read_stereo(CMSampleBufferRef sample,size_t offset,size_t frames,float *out,AWSampleReadInfo *info) {
    AWSampleReadInfo local={0}; if(!info) info=&local; *info=(AWSampleReadInfo){0};
    const AudioStreamBasicDescription *format=NULL;
    OSStatus status=validate(sample,offset,frames,out,&format);
    if(status || !frames) return status;
    struct { UInt32 count; AudioBuffer buffers[2]; } storage={0};
    CMBlockBufferRef retained=NULL;
    UInt32 bufferCount=(format->mFormatFlags&kAudioFormatFlagIsNonInterleaved) ? format->mChannelsPerFrame : 1;
    // Core Media rejects the oversized two-buffer list for interleaved PCM on
    // the tested macOS runtime, even though its required list has one buffer.
    size_t listBytes=offsetof(AudioBufferList,mBuffers)+bufferCount*sizeof(AudioBuffer);
    info->accessStatus=CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,&info->requiredListBytes,
        (AudioBufferList *)&storage,listBytes,kCFAllocatorDefault,kCFAllocatorDefault,0,&retained);
    if(!info->accessStatus) {
        bool decoded=aw_pcm_decode(format,(AudioBufferList *)&storage,offset,frames,out);
        if(retained) CFRelease(retained);
        return decoded ? noErr : kAudioFormatUnsupportedDataFormatError;
    }
    if(retained) CFRelease(retained);
    info->usedCopy=true;
    return aw_sample_copy_stereo(sample,offset,frames,out);
}
