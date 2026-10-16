#import "WiredCapture.h"
#import "SamplePCM.h"
#import <CoreMediaIO/CoreMediaIO.h>
#include <math.h>

OSStatus AWEnableWiredCaptureDiscovery(void) {
    CMIOObjectPropertyAddress a={kCMIOHardwarePropertyAllowScreenCaptureDevices,kCMIOObjectPropertyScopeGlobal,kCMIOObjectPropertyElementMain};
    UInt32 yes=1,no=0;
    OSStatus status=CMIOObjectSetPropertyData(kCMIOObjectSystemObject,&a,0,NULL,sizeof(yes),&yes);
    a.mSelector=kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices;
    OSStatus wireless=CMIOObjectSetPropertyData(kCMIOObjectSystemObject,&a,0,NULL,sizeof(no),&no);
    return status ? status : wireless;
}
NSArray<NSDictionary *> *AWCaptureSources(BOOL other) {
    NSMutableArray *items=[NSMutableArray array];
    // The compatibility enumeration includes wired iOS screen/muxed devices
    // which have had discovery regressions in modern device-type-only lists.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<AVCaptureDevice *> *devices=AVCaptureDevice.devices;
#pragma clang diagnostic pop
    for(AVCaptureDevice *d in devices) {
        BOOL mux=[d hasMediaType:AVMediaTypeMuxed],audio=[d hasMediaType:AVMediaTypeAudio];
        if(!audio && !mux) continue;
        BOOL usb=d.transportType==kAudioDeviceTransportTypeUSB;
        BOOL continuity=[d.deviceType isEqualToString:AVCaptureDeviceTypeContinuityCamera];
        NSString *model=d.modelID.lowercaseString;
        BOOL ios=[model containsString:@"ios"] || [model containsString:@"iphone"] || [model containsString:@"ipad"];
        // A phone model ID does not prove USB transport or playback audio:
        // Continuity microphones can also report an iPhone model ID.
        BOOL screenCandidate=ios && mux && !continuity;
        if(!other && !usb && !screenCandidate) continue;
        NSString *route=usb ? (mux ? @"USB screen/audio" : @"USB audio input") :
            screenCandidate ? @"iOS screen/audio — transport unverified" :
            ios || continuity ? @"iOS input — may be a Continuity microphone" : @"other audio input";
        [items addObject:@{@"device":d,@"name":[NSString stringWithFormat:@"%@ — %@",d.localizedName,route],
            @"rank":@(usb ? (mux ? 1 : 0) : screenCandidate ? 2 : 3),@"wired":@(usb)}];
    }
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        NSComparisonResult result=[a[@"rank"] compare:b[@"rank"]];
        return result==NSOrderedSame ? [a[@"name"] localizedStandardCompare:b[@"name"]] : result;
    }];
    return items;
}
NSArray<NSDictionary *> *AWOutputDevices(void) {
    AudioObjectPropertyAddress a={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&a,0,NULL,&size)) return @[];
    AudioDeviceID *devices=malloc(size); if(!devices) return @[];
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,0,NULL,&size,devices)) { free(devices); return @[]; }
    NSMutableArray *result=[NSMutableArray array];
    for(unsigned i=0;i<size/sizeof(AudioDeviceID);i++) {
        AudioObjectPropertyAddress s={kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
        UInt32 bytes=0;
        if(AudioObjectGetPropertyDataSize(devices[i],&s,0,NULL,&bytes) || !bytes) continue;
        CFStringRef name=NULL,uid=NULL; bytes=sizeof(name);
        AudioObjectPropertyAddress n={kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        if(AudioObjectGetPropertyData(devices[i],&n,0,NULL,&bytes,&name) || !name) continue;
        n.mSelector=kAudioDevicePropertyDeviceUID; bytes=sizeof(uid);
        if(!AudioObjectGetPropertyData(devices[i],&n,0,NULL,&bytes,&uid) && uid &&
           ![(__bridge NSString *)uid hasPrefix:@"local.audiomix.mac-volume."])
            [result addObject:@{@"id":@(devices[i]),@"name":(__bridge NSString *)name,@"uid":(__bridge NSString *)uid}];
        CFRelease(name); if(uid) CFRelease(uid);
    }
    free(devices); return result;
}
@implementation AWWiredCapture {
    dispatch_queue_t _sessionQueue,_audioQueue;
    AVCaptureSession *_session;
    AVCaptureAudioDataOutput *_audio;
    AVCaptureVideoDataOutput *_video;
    AVCaptureDevice *_device;
    AVCaptureOutput *_callbackAudio,*_callbackVideo;
    AWOutput _output;
    _Atomic bool _active,_accepting,_failureQueued;
    _Atomic uint64_t _chunks,_frames,_videoFrames,_invalid,_emptyBuffers,_copyChunks;
    _Atomic uint64_t _captureGeneration;
    _Atomic float _peak;
    BOOL _outputStarted;
    BOOL _formatLogged;
    NSString *_outputUID;
    unsigned _queueMilliseconds;
    uint64_t _lastRenderedFrames,_lastOutputProgressNanoseconds;
    NSUInteger _generation;
    NSString *_stage;
    id _runtimeObserver,_disconnectObserver;
}
- (instancetype)init {
    if((self=[super init])) {
        _sessionQueue=dispatch_queue_create("local.audiomix.wired.session",DISPATCH_QUEUE_SERIAL);
        dispatch_queue_attr_t attr=dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INTERACTIVE,0);
        _audioQueue=dispatch_queue_create("local.audiomix.wired.audio",attr);
        aw_output_init(&_output);
        atomic_init(&_active,false); atomic_init(&_accepting,false); atomic_init(&_failureQueued,false);
        atomic_init(&_chunks,0); atomic_init(&_frames,0); atomic_init(&_videoFrames,0); atomic_init(&_invalid,0); atomic_init(&_peak,0);
        atomic_init(&_emptyBuffers,0); atomic_init(&_copyChunks,0);
        atomic_init(&_captureGeneration,0);
        _stage=@"Stopped";
        __weak AWWiredCapture *weakSelf=self;
        _runtimeObserver=[NSNotificationCenter.defaultCenter addObserverForName:AVCaptureSessionRuntimeErrorNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            AWWiredCapture *self=weakSelf; if(!self) return;
            dispatch_async(self->_sessionQueue,^{
                if(n.object==self->_session && atomic_load(&self->_active)) {
                    NSError *error=n.userInfo[AVCaptureSessionErrorKey];
                    [self fail:[NSString stringWithFormat:@"Capture error: %@",error.localizedDescription ?: @"unknown error"]];
                }
            });
        }];
        _disconnectObserver=[NSNotificationCenter.defaultCenter addObserverForName:AVCaptureDeviceWasDisconnectedNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            AWWiredCapture *self=weakSelf; if(!self) return;
            dispatch_async(self->_sessionQueue,^{ if(n.object==self->_device && atomic_load(&self->_active)) [self fail:@"Selected capture device disconnected"]; });
        }];
    }
    return self;
}
- (BOOL)active { return atomic_load(&_active); }
- (NSString *)statusText { return _stage; }
- (void)log:(NSString *)message {
    fprintf(stderr,"%s\n",message.UTF8String);
    dispatch_async(dispatch_get_main_queue(),^{ if(self.logger) self.logger(message); });
}
- (void)stage:(NSString *)message {
    [self log:message]; dispatch_async(dispatch_get_main_queue(),^{ self->_stage=message; });
}
- (void)stopCore {
    atomic_store(&_active,false); atomic_store(&_accepting,false); _generation++;
    [_audio setSampleBufferDelegate:nil queue:NULL]; [_video setSampleBufferDelegate:nil queue:NULL];
    [_session stopRunning];
    dispatch_sync(_audioQueue,^{ aw_output_stop(&self->_output); self->_outputStarted=NO; self->_callbackAudio=nil; self->_callbackVideo=nil; });
    _session=nil; _audio=nil; _video=nil; _device=nil;
}
- (void)stop { dispatch_async(_sessionQueue,^{ [self stopCore]; [self stage:@"Stopped"]; }); }
- (void)testOutputUID:(NSString *)outputUID {
    dispatch_async(_sessionQueue,^{
        [self stopCore]; atomic_store(&self->_active,true);
        NSUInteger generation=self->_generation;
        __block OSStatus status=0;
        dispatch_sync(self->_audioQueue,^{
            status=aw_output_configure_uid(&self->_output,(__bridge CFStringRef)outputUID,48000);
            if(!status) { atomic_store(&self->_output.testTone,true); status=aw_output_start(&self->_output); }
        });
        [self logOutputSetup];
        if(status) { [self fail:[self outputFailure:@"Output test failed" status:status]]; return; }
        [self stage:@"Playing a quiet one-second output test. No input capture is running."];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),self->_sessionQueue,^{
            if(generation!=self->_generation || !self.active) return;
            [self stopCore];
            [self stage:[NSString stringWithFormat:@"Output test finished: %llu frames rendered. Confirm audibility; USB capture was not tested.",
                (unsigned long long)atomic_load(&self->_output.renderedFrames)]];
        });
    });
}
- (void)logOutputSetup {
    [self log:[NSString stringWithFormat:@"Output setup: device=%u (%@), step=%s; hardware %.0f Hz/%u ch/flags=0x%x, device rate=%.0f Hz, buffer=%u, maximum slice=%u",
        (unsigned)_output.deviceID,[NSString stringWithUTF8String:_output.deviceName] ?: @"unknown",_output.setupStep ?: "unknown",
        _output.hardwareFormat.mSampleRate,(unsigned)_output.hardwareFormat.mChannelsPerFrame,
        (unsigned)_output.hardwareFormat.mFormatFlags,_output.deviceSampleRate,
        (unsigned)_output.deviceBufferFrames,(unsigned)_output.maximumFramesPerSlice]];
}
- (NSString *)outputFailure:(NSString *)message status:(OSStatus)status {
    NSString *meaning=status==kAudioUnitErr_InvalidPropertyValue ? @" (invalid property value)" : @"";
    return [NSString stringWithFormat:@"%@: %d%@ at %s; device=%u (%@). Reconnect the intended output and Refresh if it is unavailable.",
        message,(int)status,meaning,_output.setupStep ?: "unknown",(unsigned)_output.deviceID,[NSString stringWithUTF8String:_output.deviceName] ?: @"unknown"];
}
- (void)shutdownAndWait {
    dispatch_sync(_sessionQueue,^{ [self stopCore]; });
    [NSNotificationCenter.defaultCenter removeObserver:_runtimeObserver];
    [NSNotificationCenter.defaultCenter removeObserver:_disconnectObserver];
}
- (void)fail:(NSString *)message { [self stopCore]; [self stage:[@"FAILED: " stringByAppendingString:message]]; }
- (void)startDevice:(AVCaptureDevice *)device outputUID:(NSString *)outputUID queueMilliseconds:(unsigned)milliseconds compatibilityVideo:(BOOL)compat {
    dispatch_async(_sessionQueue,^{
        [self stopCore]; if(!device) { [self stage:@"Choose an input first"]; return; }
        self->_device=device; self->_outputUID=[outputUID copy]; self->_queueMilliseconds=milliseconds;
        atomic_store(&self->_active,true); atomic_store(&self->_failureQueued,false);
        NSUInteger generation=self->_generation;
        [self stage:@"Requesting capture access"];
        [self log:[NSString stringWithFormat:@"Selected input: %@; model=%@; transport=0x%08x; audio=%d muxed=%d video=%d",
            device.localizedName,device.modelID,(unsigned)device.transportType,[device hasMediaType:AVMediaTypeAudio],
            [device hasMediaType:AVMediaTypeMuxed],[device hasMediaType:AVMediaTypeVideo]]];
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL audioAllowed) {
            dispatch_async(self->_sessionQueue,^{
                if(generation!=self->_generation || !self.active) return;
                if(!audioAllowed) { [self fail:@"Microphone/capture access denied. Enable AudioMix Wired Test in Privacy & Security → Microphone."]; return; }
                BOOL needsCamera=[device hasMediaType:AVMediaTypeVideo] || [device hasMediaType:AVMediaTypeMuxed];
                if(!needsCamera) { [self configureDevice:device compatibilityVideo:compat generation:generation]; return; }
                [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL videoAllowed) {
                    dispatch_async(self->_sessionQueue,^{
                        if(generation!=self->_generation || !self.active) return;
                        if(videoAllowed) [self configureDevice:device compatibilityVideo:compat generation:generation];
                        else [self fail:@"Camera-class capture access denied. macOS classifies the USB screen/audio input as a capture device."];
                    });
                }];
            });
        }];
    });
}
- (void)configureDevice:(AVCaptureDevice *)device compatibilityVideo:(BOOL)compat generation:(NSUInteger)generation {
    if(generation!=_generation || !self.active) return;
    if(!device.connected) { [self fail:@"Selected source is no longer connected. Refresh after reconnecting USB."]; return; }
    NSError *error=nil;
    AVCaptureDeviceInput *input=[AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if(!input) { [self fail:error.localizedDescription ?: @"Could not create capture input"]; return; }
    _session=[AVCaptureSession new]; _audio=[AVCaptureAudioDataOutput new];
    [_session beginConfiguration];
    @try {
        if(![_session canAddInput:input] || ![_session canAddOutput:_audio]) {
            [_session commitConfiguration]; [self fail:@"Source cannot be connected to an audio data output"]; return;
        }
        [_session addInput:input];
        _audio.audioSettings=@{AVFormatIDKey:@(kAudioFormatLinearPCM),AVLinearPCMBitDepthKey:@32,
            AVLinearPCMIsFloatKey:@YES,AVLinearPCMIsNonInterleaved:@NO,AVNumberOfChannelsKey:@2};
        [_session addOutput:_audio]; [_audio setSampleBufferDelegate:self queue:_audioQueue];
        for(AVCaptureInputPort *port in input.ports) [self log:[@"Capture input port: " stringByAppendingString:port.mediaType]];
        if(compat) {
            _video=[AVCaptureVideoDataOutput new]; _video.alwaysDiscardsLateVideoFrames=YES;
            if(![_session canAddOutput:_video]) {
                [_session commitConfiguration]; [self fail:@"Compatibility video output is unavailable for this source"]; return;
            }
            [_session addOutput:_video]; [_video setSampleBufferDelegate:self queue:_audioQueue];
            [self log:@"Compatibility mode: video samples will be discarded; no preview or recording. This is not a video-free transport."];
        }
        [_session commitConfiguration];
    } @catch(NSException *exception) {
        @try { [_session commitConfiguration]; } @catch(NSException *ignored) { (void)ignored; }
        [self fail:exception.reason ?: @"Capture configuration exception"]; return;
    }
    if(![_audio connectionWithMediaType:AVMediaTypeAudio]) {
        [self fail:@"No audio connection exposed. Try enabling the device in Audio MIDI Setup, or explicit screen-stream compatibility mode."]; return;
    }
    dispatch_sync(_audioQueue,^{
        self->_callbackAudio=self->_audio; self->_callbackVideo=self->_video;
        atomic_store(&self->_output.ring.readFrame,0); atomic_store(&self->_output.ring.writeFrame,0);
        atomic_store(&self->_output.ring.underrunFrames,0); atomic_store(&self->_output.ring.droppedFrames,0);
        atomic_store(&self->_output.ring.staleFrames,0);
        atomic_store(&self->_output.ring.maxAgeNanoseconds,(uint64_t)self->_queueMilliseconds*NSEC_PER_MSEC);
        atomic_store(&self->_output.sampleRate,0); atomic_store(&self->_chunks,0); atomic_store(&self->_frames,0);
        atomic_store(&self->_videoFrames,0); atomic_store(&self->_invalid,0); atomic_store(&self->_peak,0);
        atomic_store(&self->_emptyBuffers,0); atomic_store(&self->_copyChunks,0); self->_formatLogged=NO;
    });
    atomic_store(&_captureGeneration,generation);
    atomic_store(&_accepting,true);
    [self stage:compat ? @"Starting USB capture with discarded video" : @"Starting audio-only capture (no video output)"];
    [self stage:@"Capture session starting; waiting for audio samples"];
    [_session startRunning];
    if(!_session.running) { [self fail:@"Capture session did not start"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,8*NSEC_PER_SEC),_sessionQueue,^{
        if(generation==self->_generation && self.active && !atomic_load(&self->_chunks))
            [self log:@"No audio buffers after 8 seconds. Play sound on the device; check USB trust/Audio MIDI Enable. Compatibility mode is an explicit next test, not enabled automatically."];
    });
}
- (void)captureFailure:(NSString *)message {
    if(atomic_exchange(&_failureQueued,true)) return;
    uint64_t generation=atomic_load(&_captureGeneration);
    atomic_store(&_accepting,false);
    dispatch_async(_sessionQueue,^{ if(generation==self->_generation && self.active) [self fail:message]; });
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    (void)output; (void)connection;
    if(!atomic_load(&_accepting) || (output!=_callbackAudio && output!=_callbackVideo)) return;
    if(!CMSampleBufferIsValid(sample)) { atomic_fetch_add(&_invalid,1); return; }
    CMFormatDescriptionRef description=CMSampleBufferGetFormatDescription(sample);
    if(!description) return;
    if(CMFormatDescriptionGetMediaType(description)==kCMMediaType_Video) { atomic_fetch_add(&_videoFrames,1); return; }
    CMItemCount sampleCount=CMSampleBufferGetNumSamples(sample);
    if(!sampleCount) {
        if(!atomic_fetch_add(&_emptyBuffers,1)) [self log:@"Ignoring an empty capture stream-event buffer; waiting for PCM samples."];
        return;
    }
    const AudioStreamBasicDescription *format=CMAudioFormatDescriptionGetStreamBasicDescription(description);
    if(sampleCount<0 || !format || !CMSampleBufferDataIsReady(sample)) { atomic_fetch_add(&_invalid,1); return; }
    CMBlockBufferRef block=CMSampleBufferGetDataBuffer(sample);
    size_t dataBytes=block ? CMBlockBufferGetDataLength(block) : 0;
    if(!_formatLogged) {
        _formatLogged=YES;
        [self log:[NSString stringWithFormat:@"First audio buffer: format=0x%08x rate=%.0f channels=%u bits=%u flags=0x%x bytes/frame=%u frames=%lld data=%zu bytes",
            (unsigned)format->mFormatID,format->mSampleRate,(unsigned)format->mChannelsPerFrame,(unsigned)format->mBitsPerChannel,
            (unsigned)format->mFormatFlags,(unsigned)format->mBytesPerFrame,(long long)sampleCount,dataBytes]];
    }
    OSStatus status=noErr;
    size_t frames=(size_t)sampleCount;
    uint64_t received=aw_monotonic_nanoseconds();
    BOOL first=!_outputStarted;
    if(!first) {
        uint64_t rendered=atomic_load(&self->_output.renderedFrames);
        if(rendered!=_lastRenderedFrames) { _lastRenderedFrames=rendered; _lastOutputProgressNanoseconds=received; }
        else if(received-_lastOutputProgressNanoseconds>NSEC_PER_SEC) {
            [self captureFailure:@"Selected output stopped rendering for over one second. Reconnect/reselect the output and restart."]; return;
        }
    }
    if(first) {
        status=aw_output_configure_uid(&_output,(__bridge CFStringRef)_outputUID,format->mSampleRate);
        [self logOutputSetup];
        if(status) {
            [self captureFailure:[self outputFailure:@"Output initialization failed" status:status]]; return;
        }
        atomic_store(&_output.ring.maxQueuedFrames,(unsigned)(format->mSampleRate*_queueMilliseconds/1000));
        [self log:[NSString stringWithFormat:@"PCM %.0f Hz, %u channel(s), %u bits, flags=0x%x; output device buffer=%u frames at %.0f Hz, device latency=%u, safety=%u frames. These are not end-to-end latency.",
            format->mSampleRate,(unsigned)format->mChannelsPerFrame,(unsigned)format->mBitsPerChannel,(unsigned)format->mFormatFlags,
            (unsigned)_output.deviceBufferFrames,_output.deviceSampleRate,(unsigned)_output.deviceLatencyFrames,(unsigned)_output.safetyFrames]];
    } else if((unsigned)format->mSampleRate!=atomic_load(&_output.sampleRate)) {
        [self captureFailure:@"Capture sample rate changed; stop and restart with the new format"]; return;
    }
    float stereo[1024*2],peak=0;
    for(size_t offset=0;offset<frames;) {
        size_t count=MIN(frames-offset,(size_t)1024);
        AWSampleReadInfo info={0};
        status=aw_sample_read_stereo(sample,offset,count,stereo,&info);
        if(status) {
            [self captureFailure:[NSString stringWithFormat:@"PCM read failed: status=%d (0x%08x), retained-access=%d, list bytes=%zu, copy=%d; format=0x%08x channels=%u bits=%u stride=%u frames=%zu data=%zu",
                (int)status,(unsigned)status,(int)info.accessStatus,info.requiredListBytes,info.usedCopy,
                (unsigned)format->mFormatID,(unsigned)format->mChannelsPerFrame,(unsigned)format->mBitsPerChannel,
                (unsigned)format->mBytesPerFrame,frames,dataBytes]]; return;
        }
        if(info.usedCopy && !atomic_fetch_add(&_copyChunks,1))
            [self log:[NSString stringWithFormat:@"Using PCM-copy fallback: retained-access=%d, requested AudioBufferList bytes=%zu. PCM extraction succeeded.",(int)info.accessStatus,info.requiredListBytes]];
        for(size_t i=0;i<count*2;i++) peak=fmaxf(peak,fabsf(stereo[i]));
        aw_ring_write_at(&_output.ring,stereo,count,received); offset+=count;
    }
    atomic_store(&_peak,peak); atomic_fetch_add(&_chunks,1); atomic_fetch_add(&_frames,frames);
    if(first) {
        status=aw_output_start(&_output);
        if(status) { [self captureFailure:[self outputFailure:@"Output start failed" status:status]]; return; }
        _lastRenderedFrames=atomic_load(&_output.renderedFrames); _lastOutputProgressNanoseconds=aw_monotonic_nanoseconds();
        _outputStarted=YES; [self stage:@"Audio PCM received → selected output running. Confirm audible playback."];
    }
}
- (void)setVolume:(float)volume { atomic_store(&_output.ring.gain,fmaxf(0,fminf(1,volume))); }
- (NSString *)statistics {
    uint64_t w=atomic_load(&_output.ring.writeFrame),r=atomic_load(&_output.ring.readFrame);
    unsigned rate=atomic_load(&_output.sampleRate); double queued=w>=r && rate ? (w-r)*1000./rate : 0;
    float peak=atomic_load(&_peak);
    return [NSString stringWithFormat:@"%@\nAudio chunks %llu · frames %llu · rendered %llu · video %llu · peak %.1f dBFS\nApp queue %.1f ms · dropped %llu (stale %llu) · silent-fill %llu · invalid %llu · empty %llu · copies %llu · output error %d",
        _stage,(unsigned long long)atomic_load(&_chunks),(unsigned long long)atomic_load(&_frames),
        (unsigned long long)atomic_load(&_output.renderedFrames),
        (unsigned long long)atomic_load(&_videoFrames),peak>0 ? 20*log10f(peak) : -120.,queued,
        (unsigned long long)atomic_load(&_output.ring.droppedFrames),(unsigned long long)atomic_load(&_output.ring.staleFrames),
        (unsigned long long)atomic_load(&_output.ring.underrunFrames),
        (unsigned long long)atomic_load(&_invalid),(unsigned long long)atomic_load(&_emptyBuffers),
        (unsigned long long)atomic_load(&_copyChunks),(int)atomic_load(&_output.callbackError)];
}
@end
