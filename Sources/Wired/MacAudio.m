#import "MacAudio.h"
#import "MacVolumeRender.h"
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#include <unistd.h>
#include <math.h>

static OSStatus macIO(AudioObjectID device,const AudioTimeStamp *now,const AudioBufferList *input,
    const AudioTimeStamp *inputTime,AudioBufferList *output,const AudioTimeStamp *outputTime,void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    aw_mac_render(context,input,output); return noErr;
}
static OSStatus property(AudioObjectID object,AudioObjectPropertySelector selector,AudioObjectPropertyScope scope,void *value,UInt32 size) {
    AudioObjectPropertyAddress a={selector,scope,kAudioObjectPropertyElementMain};
    return AudioObjectGetPropertyData(object,&a,0,NULL,&size,value);
}
static NSArray<NSNumber *> *streams(AudioDeviceID device,AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress a={kAudioDevicePropertyStreams,scope,kAudioObjectPropertyElementMain};
    UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(device,&a,0,NULL,&size) || !size || size>4096) return @[];
    AudioStreamID ids[1024];
    if(AudioObjectGetPropertyData(device,&a,0,NULL,&size,ids)) return @[];
    NSMutableArray *result=[NSMutableArray array];
    for(UInt32 i=0;i<size/sizeof(AudioStreamID);i++) [result addObject:@(ids[i])];
    return result;
}
static NSString *stringProperty(AudioObjectID device,AudioObjectPropertySelector selector) {
    CFStringRef value=NULL;
    if(property(device,selector,kAudioObjectPropertyScopeGlobal,&value,sizeof(value)) || !value) return nil;
    return CFBridgingRelease(value);
}
static BOOL floatStream(AudioStreamID stream,AudioStreamBasicDescription *f) {
    if(property(stream,kAudioStreamPropertyVirtualFormat,kAudioObjectPropertyScopeGlobal,f,sizeof(*f))) return NO;
    return f->mFormatID==kAudioFormatLinearPCM && (f->mFormatFlags&kAudioFormatFlagIsFloat) &&
        !(f->mFormatFlags&(kAudioFormatFlagIsBigEndian|kAudioFormatFlagIsNonInterleaved)) &&
        f->mBitsPerChannel==32 && f->mChannelsPerFrame>0 && f->mChannelsPerFrame<=2 &&
        f->mBytesPerFrame==sizeof(float)*f->mChannelsPerFrame;
}
@implementation AWMacAudio {
    dispatch_queue_t _queue;
    _Atomic bool _active;
    AWMacRender _render;
    AudioObjectID _tap;
    AudioDeviceID _aggregate,_device;
    AudioDeviceIOProcID _io;
    NSString *_statusText;
    uint64_t _startedAt;
    BOOL _confirmed;
    AudioObjectPropertyListenerBlock _deviceListener;
}
- (instancetype)init {
    if((self=[super init])) {
        _queue=dispatch_queue_create("local.audiomix.mac-volume",DISPATCH_QUEUE_SERIAL);
        atomic_init(&_active,false); aw_mac_render_init(&_render);
        _statusText=@"Enable to adjust Mac audio on the selected output.";
    }
    return self;
}
- (BOOL)active { return atomic_load(&_active); }
- (NSString *)statusText { return _statusText; }
- (void)status:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(),^{ self->_statusText=text; if(self.logger) self.logger([@"Mac audio: " stringByAppendingString:text]); });
}
- (void)stopCore {
    atomic_store(&_render.enabled,false);
    if(_deviceListener && _device) {
        AudioObjectPropertyAddress a={kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        AudioObjectRemovePropertyListenerBlock(_device,&a,_queue,_deviceListener); _deviceListener=nil;
    }
    if(_io) { AudioDeviceStop(_aggregate,_io); AudioDeviceDestroyIOProcID(_aggregate,_io); _io=NULL; }
    if(_aggregate) { AudioHardwareDestroyAggregateDevice(_aggregate); _aggregate=0; }
    if(_tap) {
        if(@available(macOS 14.2,*)) AudioHardwareDestroyProcessTap(_tap);
        _tap=0;
    }
    _device=0; atomic_store(&_active,false);
}
- (void)fail:(NSString *)step status:(OSStatus)status {
    [self stopCore];
    [self status:[NSString stringWithFormat:@"Could not enable (%@, %d). Check System Audio Recording permission and the selected output.",step,(int)status]];
}
- (void)startOutputUID:(NSString *)uid {
    if(atomic_exchange(&_active,true)) return;
    _statusText=@"Enabling Mac audio control…";
    dispatch_async(_queue,^{
        if(@available(macOS 14.2,*)) [self startCore:uid];
        else { atomic_store(&self->_active,false); [self status:@"Mac audio control requires macOS 14.2 or later."]; }
    });
}
- (void)startCore:(NSString *)uid API_AVAILABLE(macos(14.2)) {
    OSStatus status=0; const char *step="resolve output";
    AudioObjectPropertyAddress a={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=sizeof(_device);
    if(uid) { CFStringRef value=(__bridge CFStringRef)uid; status=AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(value),&value,&size,&_device); }
    else status=property(kAudioObjectSystemObject,kAudioHardwarePropertyDefaultOutputDevice,kAudioObjectPropertyScopeGlobal,&_device,sizeof(_device));
    if(status || !_device) goto fail;
    uid=stringProperty(_device,kAudioDevicePropertyDeviceUID);
    if(!uid) { status=kAudioHardwareBadDeviceError; goto fail; }
    {
        // Exclusion is mandatory: every USB stream is rendered by this process.
        // Including ourselves would turn the iPad path into a feedback loop.
        step="exclude AudioMix from the tap";
        pid_t pid=getpid(); AudioObjectID process=0; size=sizeof(process);
        a.mSelector=kAudioHardwarePropertyTranslatePIDToProcessObject;
        status=AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(pid),&pid,&size,&process);
        if(status || !process) goto fail;
        NSArray *outputStreams=streams(_device,kAudioObjectPropertyScopeOutput);
        AudioStreamBasicDescription hardware={0};
        if(outputStreams.count!=1 || !floatStream([outputStreams.firstObject unsignedIntValue],&hardware)) {
            step="requires a mono/stereo Float32 output stream"; status=kAudioDeviceUnsupportedFormatError; goto fail;
        }
        CATapDescription *tap=[[CATapDescription alloc] initExcludingProcesses:@[@(process)] andDeviceUID:uid withStream:0];
        tap.name=@"AudioMix Mac volume"; tap.privateTap=YES; tap.muteBehavior=CATapMutedWhenTapped;
        step="create system audio tap";
        status=AudioHardwareCreateProcessTap(tap,&_tap); if(status) goto fail;
        AudioStreamBasicDescription format={0};
        status=property(_tap,kAudioTapPropertyFormat,kAudioObjectPropertyScopeGlobal,&format,sizeof(format));
        if(status || format.mChannelsPerFrame<1 || format.mChannelsPerFrame>2) { step="read tap format"; goto fail; }
        NSDictionary *description=@{
            @kAudioAggregateDeviceNameKey:@"AudioMix Mac volume",
            @kAudioAggregateDeviceUIDKey:[@"local.audiomix.mac-volume." stringByAppendingString:NSUUID.UUID.UUIDString],
            @kAudioAggregateDeviceIsPrivateKey:@YES, @kAudioAggregateDeviceIsStackedKey:@NO,
            @kAudioAggregateDeviceTapAutoStartKey:@YES, @kAudioAggregateDeviceMainSubDeviceKey:uid,
            @kAudioAggregateDeviceSubDeviceListKey:@[@{@kAudioSubDeviceUIDKey:uid}],
            @kAudioAggregateDeviceTapListKey:@[@{@kAudioSubTapUIDKey:tap.UUID.UUIDString,
                @kAudioSubTapDriftCompensationKey:@YES,
                @kAudioSubTapDriftCompensationQualityKey:@(kAudioAggregateDriftCompensationHighQuality)}]
        };
        step="create private playback aggregate";
        status=AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description,&_aggregate); if(status) goto fail;
        UInt32 alive=0;
        for(unsigned attempt=0;attempt<30;attempt++) {
            status=property(_aggregate,kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,&alive,sizeof(alive));
            if(!status && alive) break;
            [NSThread sleepForTimeInterval:0.05];
        }
        if(status || !alive) { step="wait for playback aggregate"; goto fail; }
        NSArray<NSNumber *> *inputs=streams(_aggregate,kAudioObjectPropertyScopeInput);
        unsigned channels=0; NSUInteger first=inputs.count;
        while(first && channels<format.mChannelsPerFrame) {
            AudioStreamBasicDescription f={0};
            if(!floatStream([inputs[--first] unsignedIntValue],&f) || f.mSampleRate!=hardware.mSampleRate) break;
            channels+=f.mChannelsPerFrame;
        }
        if(channels!=format.mChannelsPerFrame || inputs.count-first>2) {
            step="identify tap input streams"; status=kAudioDeviceUnsupportedFormatError; goto fail;
        }
        _render.firstTapBuffer=(UInt32)first; _render.tapBufferCount=(UInt32)(inputs.count-first);
        atomic_store(&_render.callbacks,0); atomic_store(&_render.frames,0); atomic_store(&_render.invalidBuffers,0);
        atomic_store(&_render.lastCallbackNanoseconds,0); atomic_store(&_render.peak,0);
        step="create playback callback";
        status=AudioDeviceCreateIOProcID(_aggregate,macIO,&_render,&_io); if(status) goto fail;
        // A duplex headset may contribute microphone streams. Explicitly disable
        // them for our IOProc before starting; only the trailing tap may be read.
        if(first) {
            step="disable hardware microphone streams";
            a=(AudioObjectPropertyAddress){kAudioDevicePropertyIOProcStreamUsage,kAudioObjectPropertyScopeInput,kAudioObjectPropertyElementMain};
            size=(UInt32)(offsetof(AudioHardwareIOProcStreamUsage,mStreamIsOn)+inputs.count*sizeof(UInt32));
            AudioHardwareIOProcStreamUsage *usage=calloc(1,size);
            if(!usage) { status=memFullErr; goto fail; }
            usage->mIOProc=(void *)_io;
            status=AudioObjectGetPropertyData(_aggregate,&a,0,NULL,&size,usage);
            if(!status && usage->mNumberStreams==inputs.count) {
                for(UInt32 i=0;i<usage->mNumberStreams;i++) usage->mStreamIsOn[i]=i>=first;
                status=AudioObjectSetPropertyData(_aggregate,&a,0,NULL,size,usage);
            } else if(!status) status=kAudioHardwareIllegalOperationError;
            free(usage); if(status) goto fail;
        }
        _startedAt=aw_monotonic_nanoseconds(); _confirmed=NO; atomic_store(&_render.enabled,true);
        step="start Mac audio control (allow System Audio Recording when prompted)";
        status=AudioDeviceStart(_aggregate,_io); if(status) goto fail;
        __weak AWMacAudio *weakSelf=self;
        _deviceListener=^(UInt32 count,const AudioObjectPropertyAddress *addresses) {
            (void)count; (void)addresses; AWMacAudio *self=weakSelf; if(!self || !self.active) return;
            UInt32 live=0;
            if(property(self->_device,kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,&live,sizeof(live)) || !live) {
                [self stopCore]; [self status:@"Output disconnected. Reconnect it and enable Mac audio control again."];
            }
        };
        a=(AudioObjectPropertyAddress){kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        AudioObjectAddPropertyListenerBlock(_device,&a,_queue,_deviceListener);
        [self status:[NSString stringWithFormat:@"Controlling Mac audio on %@",stringProperty(_device,kAudioObjectPropertyName) ?: @"selected output"]];
        return;
    }
fail:
    [self fail:[NSString stringWithUTF8String:step] status:status ?: kAudioHardwareBadDeviceError];
}
- (void)setVolume:(float)volume { atomic_store(&_render.gain,isfinite(volume) ? fmaxf(0,fminf(1,volume)) : 0); }
- (void)stop { dispatch_async(_queue,^{ [self stopCore]; [self status:@"Mac audio control off. Mac playback uses its normal volume."]; }); }
- (void)checkHealth {
    if(!self.active) return;
    dispatch_async(_queue,^{
        if(!self.active || !atomic_load(&self->_render.enabled)) return;
        uint64_t last=atomic_load(&self->_render.lastCallbackNanoseconds);
        if(!self->_confirmed && atomic_load(&self->_render.frames)) {
            self->_confirmed=YES;
            NSString *message=[NSString stringWithFormat:@"Mac volume gain stage received and rendered %llu frames; AudioMix output is excluded from capture.",
                (unsigned long long)atomic_load(&self->_render.frames)];
            dispatch_async(dispatch_get_main_queue(),^{ if(self.logger) self.logger(message); });
        }
        if(atomic_load(&self->_render.invalidBuffers) || aw_monotonic_nanoseconds()-(last ?: self->_startedAt)>5*NSEC_PER_SEC) {
            [self stopCore]; [self status:@"Playback stopped; Mac audio control released. Check audio permission/output and enable again."];
        }
    });
}
- (void)shutdownAndWait { dispatch_sync(_queue,^{ [self stopCore]; }); }
@end
