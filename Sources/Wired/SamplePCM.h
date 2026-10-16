#ifndef AW_SAMPLE_PCM_H
#define AW_SAMPLE_PCM_H
#include <CoreMedia/CoreMedia.h>
#include "AudioPipe.h"
#define AW_SAMPLE_CHUNK_FRAMES 1024u
typedef struct {
    OSStatus accessStatus;
    size_t requiredListBytes;
    bool usedCopy;
} AWSampleReadInfo;
// Capture-queue helpers. The sample remains owned by the caller throughout.
OSStatus aw_sample_copy_stereo(CMSampleBufferRef sample,size_t offset,size_t frames,float *stereo);
OSStatus aw_sample_read_stereo(CMSampleBufferRef sample,size_t offset,size_t frames,float *stereo,AWSampleReadInfo *info);
#endif
