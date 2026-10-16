#import "Receiver.h"
#import "Service.h"
#include <mach/error.h>
static NSString *statusText(IOReturn status) {
    return [NSString stringWithFormat:@"0x%08x (%s)",(unsigned)status,mach_error_string(status)];
}
@implementation AMReceiver {
    CBCentralManager *_permissionManager;
    IOBluetoothSDPServiceRecord *_record;
    IOBluetoothUserNotification *_notification;
    IOBluetoothUserNotification *_connectionNotification;
    NSTimer *_classTimer;
    IOBluetoothL2CAPChannel *_signaling, *_mediaChannel;
    NSString *_peer;
    AMAVDTP _session;
    AMAVDTPFragments _fragments;
    AMMedia _media;
    AMAudioOutput _output;
    BOOL _pending, _listening, _changedClass, _cleanupFailed;
    BluetoothClassOfDevice _originalClass;
    unsigned _rejectedMedia;
    unsigned _incomingChannels, _connectionEvents;
    NSString *_stage;
    BluetoothL2CAPPSM _activePSM;
}
- (instancetype)init {
    self=[super init];
    if(self) { _queueMilliseconds=60; _stage=@"Not started"; am_output_init(&_output); }
    return self;
}
- (BOOL)listening { return _listening || _pending; }
- (void)log:(NSString *)message {
    fprintf(stderr,"%s\n",message.UTF8String);
    if(self.logger) self.logger(message);
}
- (void)start {
    // Retired after the user reported that connecting to the experimental sink
    // disconnected other iPad accessories. Do not publish additional variants
    // or run automatic publication controls against the system audio profile.
    _stage=@"Local receiver disabled: connection disruption under investigation";
    [self log:_stage];
    return;
}
- (void)startUnreleasedReceiver {
    if(self.listening) return;
    if(_cleanupFailed) { [self log:@"A previous transient service could not be removed. Quit and reopen this app before retrying."]; return; }
    _pending=YES;
    _stage=@"Requesting Bluetooth access";
    [self log:[NSString stringWithFormat:@"Bluetooth authorization=%ld (0=undetermined, 1=restricted, 2=denied, 3=allowed)",(long)CBManager.authorization]];
    if(CBManager.authorization==CBManagerAuthorizationDenied ||
       CBManager.authorization==CBManagerAuthorizationRestricted) {
        _pending=NO;
        _stage=@"Bluetooth permission denied";
        [self log:@"Bluetooth access is denied/restricted. Enable AudioMixBluetooth in System Settings → Privacy & Security → Bluetooth, then retry."];
        return;
    }
    if(!_permissionManager) {
        _permissionManager=[[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
    } else if(_permissionManager.state==CBManagerStatePoweredOn) {
        [self publish];
    } else {
        [self centralManagerDidUpdateState:_permissionManager];
    }
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self log:[NSString stringWithFormat:@"Bluetooth manager state=%ld (5=powered on)",(long)central.state]];
    if(_listening && central.state!=CBManagerStatePoweredOn) {
        [self log:@"Bluetooth became unavailable; stopping receiver."]; [self stop]; return;
    }
    if(!_pending) return;
    if(central.state==CBManagerStatePoweredOn) [self publish];
    else if(central.state!=CBManagerStateUnknown && central.state!=CBManagerStateResetting) {
        _pending=NO; _stage=@"Bluetooth unavailable";
        [self log:@"Bluetooth is not ready. Check permission and turn Bluetooth on, then retry."];
    }
}
- (void)publish {
    _pending=NO;
    [self log:[NSString stringWithFormat:@"Bluetooth authorization after readiness=%ld",(long)CBManager.authorization]];
    IOBluetoothHostController *controller=IOBluetoothHostController.defaultController;
    if(!controller) { _stage=@"No Classic Bluetooth controller"; [self log:@"No accessible Classic Bluetooth host controller."]; return; }
    [self log:[NSString stringWithFormat:@"Local controller: %@; macOS %@",controller.nameAsString,NSProcessInfo.processInfo.operatingSystemVersionString]];
    _stage=@"Publishing audio service";
    _notification=[IOBluetoothL2CAPChannel registerForChannelOpenNotifications:self
        selector:@selector(channelOpened:channel:) withPSM:0x0019
        direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
    [self log:_notification ? @"Pre-publication PSM 0x0019 notification subscription created (does not prove transport ownership)." :
        @"Pre-publication PSM 0x0019 notification subscription returned nil."];
    NSDictionary *description=nil;
    NSMutableArray *candidates=[AMAudioSinkPublicationCandidates() mutableCopy];
    if(self.allowExperimentalTransport) [candidates addObject:@{
        @"name":@"EXPERIMENT: custom dynamic port (iPad compatibility unverified)",
        @"record":AMExperimentalAudioSinkServiceDescription()}];
    for(NSDictionary *candidate in candidates) {
        NSDictionary *requested=candidate[@"record"];
        NSString *reason=nil;
        IOBluetoothSDPServiceRecord *local=AMLocalServiceDescription(requested);
        BluetoothL2CAPPSM requestedPSM=0;
        [local getL2CAPPSM:&requestedPSM];
        if((requestedPSM!=0x0019 && !self.allowExperimentalTransport) || !AMValidateAudioSinkRecordForPSM(local,requestedPSM,&reason)) {
            [self log:[@"Invalid local request: " stringByAppendingString:reason]]; continue;
        }
        [self log:[NSString stringWithFormat:@"SDP request [%@]: PSM=0x%04x, ServiceID=%@",candidate[@"name"],requestedPSM,requested[@"0003"]]];
        IOBluetoothSDPServiceRecord *record=[IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:requested];
        if(!record) { [self log:@"SDP candidate returned nil."]; continue; }
        BluetoothL2CAPPSM actual=0;
        IOReturn readStatus=[record getL2CAPPSM:&actual];
        [self log:[NSString stringWithFormat:@"SDP candidate PSM=0x%04x (%@); attributes: %@",actual,statusText(readStatus),record.attributes]];
        if(!AMServiceRecordHasRequestedIdentity(record,requested)) {
            [self log:@"SDP returned a different/unidentified record. Leaving it untouched; no ownership established."]; continue;
        }
        if(!readStatus && actual==requestedPSM && AMServiceRecordMatchesDescription(record,requested,&reason)) {
            _record=record; description=requested; _activePSM=actual; break;
        }
        [self log:[NSString stringWithFormat:@"Owned candidate rejected: %@",reason ?: @"standard PSM was not assigned"]];
        IOReturn removal=[record removeServiceRecord];
        [self log:[NSString stringWithFormat:@"Owned candidate cleanup: %@",statusText(removal)]];
        if(removal) { _cleanupFailed=YES; break; }
    }
    if(!_record) {
        [_notification unregister]; _notification=nil;
        _stage=@"FAILED: audio service was not published";
        [self log:@"SDP: no candidate provided our own verified audio service on 0x0019. Running publication controls; these do not receive audio."];
        [self diagnosePublication];
        [self log:@"No audio receiver is running. Permission/power state was logged above; nil has no public error code. Copy this complete log. Do not attempt iPad pairing until the audio service starts."];
        return;
    }
    BluetoothL2CAPPSM psm=0;
    IOReturn result=[_record getL2CAPPSM:&psm];
    [self log:[NSString stringWithFormat:@"SDP published; PSM=0x%04x, status=%@",psm,statusText(result)]];
    [self log:[NSString stringWithFormat:@"Returned audio attributes: %@",_record.attributes]];
    if(result || psm!=_activePSM || (psm!=0x0019 && !self.allowExperimentalTransport)) {
        [self log:@"The standard AVDTP transport is unavailable to this app. Stopping; an alternate PSM is not counted as success."];
        [self stop]; _stage=@"FAILED: standard AVDTP transport unavailable";
        [self diagnosePublication]; return;
    }
    NSString *reason=nil;
    if(!AMServiceRecordMatchesDescription(_record,description,&reason)) {
        [self log:[@"Published SDP record is invalid: " stringByAppendingString:reason]];
        [self stop]; _stage=@"FAILED: published audio descriptor invalid";
        [self diagnosePublication]; return;
    }
    BluetoothSDPServiceRecordHandle handle=0;
    IOReturn handleResult=[_record getServiceRecordHandle:&handle];
    [self log:[NSString stringWithFormat:@"Published SDP values verified locally: unique ServiceID, AudioSink=0x110B, A2DP=1.3, AVDTP=1.3, PSM=0x%04x, speaker feature; handle=0x%08x (%@). macOS normalizes returned widths; wire encoding/remote visibility still unverified.",psm,(unsigned)handle,statusText(handleResult)]];
    if(psm!=0x0019) { [_notification unregister]; _notification=nil; }
    if(!_notification) _notification=[IOBluetoothL2CAPChannel registerForChannelOpenNotifications:self
        selector:@selector(channelOpened:channel:) withPSM:psm
        direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
    if(!_notification) {
        [self log:@"Incoming L2CAP registration failed."]; [self stop];
        _stage=@"FAILED: incoming channel listener unavailable"; return;
    }
    if(self.useAudioDeviceClass) {
        _originalClass=controller.classOfDevice;
        result=[controller setClassOfDevice:0x240414 forTimeInterval:120];
        _changedClass=result==0;
        [self log:[NSString stringWithFormat:@"Audio-device class: requested=0x240414, readback=0x%06x, original=0x%06x; %@",(unsigned)controller.classOfDevice,(unsigned)_originalClass,statusText(result)]];
        if(_changedClass) {
            __weak AMReceiver *weakSelf=self;
            _classTimer=[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
                (void)timer; [weakSelf renewAudioClassIfExpired];
            }];
        }
    }
    _listening=YES; _stage=psm==0x0019 ? @"Waiting: no AVDTP channel received" :
        [NSString stringWithFormat:@"EXPERIMENT: listening on 0x%04x; iPad unverified",psm];
    _incomingChannels=0; _connectionEvents=0;
    _connectionNotification=[IOBluetoothDevice registerForConnectNotifications:self selector:@selector(basebandConnected:device:)];
    [self log:@"Listening. Open macOS Bluetooth settings to make the Mac discoverable, then pair/select the Mac on iPad. The iPad may show the Mac's normal name."];
    [self log:@"Stages to watch: signaling → SBC configured → media channel → Start → decoded PCM. Publication alone is not an audio pass."];
    if(psm!=0x0019) [self log:@"EXPERIMENT ONLY: standard AVDTP 0x0019 was unavailable. The owned custom-port service and notification subscription are active. iPad may ignore this port or custom-first class list; successful startup does not establish iPad audio support."];
}
- (void)diagnosePublication {
    if(_cleanupFailed) { [self log:@"Skipping controls after cleanup failure. Quit this app before retrying."]; return; }
    unsigned published=0, verified=0;
    [self log:@"SDP controls request nonzero ports and unique ServiceIDs. Non-nil objects alone are not usable registrations."];
    for(NSDictionary *probe in AMServicePublicationProbes()) {
        [self log:[NSString stringWithFormat:@"SDP control request [%@]: ServiceID=%@",probe[@"name"],probe[@"record"][@"0003"]]];
        IOBluetoothSDPServiceRecord *record=[IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:probe[@"record"]];
        NSString *name=probe[@"name"];
        if(!record) { [self log:[NSString stringWithFormat:@"SDP control [%@]: nil",name]]; continue; }
        published++;
        BluetoothSDPServiceRecordHandle handle=0;
        BluetoothL2CAPPSM psm=0;
        BluetoothRFCOMMChannelID channel=0;
        IOReturn handleStatus=[record getServiceRecordHandle:&handle];
        IOReturn psmStatus=[record getL2CAPPSM:&psm];
        IOReturn channelStatus=[record getRFCOMMChannelID:&channel];
        [self log:[NSString stringWithFormat:@"SDP control [%@]: published handle=0x%08x (%@); actual PSM=0x%04x (%@); RFCOMM=%u (%@)",
            name,(unsigned)handle,statusText(handleStatus),psm,statusText(psmStatus),channel,statusText(channelStatus)]];
        NSString *reason=nil;
        if(AMServiceRecordMatchesDescription(record,probe[@"record"],&reason)) {
            verified++;
            [self log:@"SDP control verification: requested identity and all attributes match locally. Remote visibility unverified."];
        } else [self log:[NSString stringWithFormat:@"SDP control verification FAILED: %@",reason]];
        [self log:[NSString stringWithFormat:@"SDP control returned attributes: %@",record.attributes]];
        if(!AMServiceRecordHasRequestedIdentity(record,probe[@"record"])) {
            [self log:@"Control cleanup skipped: returned record identity is not ours."]; continue;
        }
        IOReturn removal=[record removeServiceRecord];
        [self log:[NSString stringWithFormat:@"SDP control cleanup [%@]: %@",name,statusText(removal)]];
        if(removal) {
            _cleanupFailed=YES;
            [self log:@"Control cleanup failed; stopping further probes. Quit this app to release its transient services before retrying."];
            return;
        }
    }
    [self log:[NSString stringWithFormat:@"SDP controls: %u non-nil objects; %u matched requested identities and explicit ports. No control received audio.",published,verified]];
    if(!_cleanupFailed) {
        NSDictionary *requested=AMCompactAudioSinkServiceDescription(0x0019);
        IOBluetoothSDPServiceRecord *legacy=nil;
        IOReturn result=AMLegacyPublicationProbe(requested,&legacy);
        [self log:[NSString stringWithFormat:@"Legacy documented IOBluetoothAddServiceDict: %@; record=%@ (unsupported means symbol unavailable)",statusText(result),legacy ? @"non-nil" : @"nil"]];
        if(legacy) {
            [self log:[NSString stringWithFormat:@"Legacy returned attributes: %@",legacy.attributes]];
            if(AMServiceRecordHasRequestedIdentity(legacy,requested)) {
                IOReturn removal=[legacy removeServiceRecord];
                if(removal) _cleanupFailed=YES;
                [self log:[NSString stringWithFormat:@"Owned legacy cleanup: %@",statusText(removal)]];
            } else [self log:@"Legacy cleanup skipped: returned record identity is not ours."];
        }
    }
}
- (void)renewAudioClassIfExpired {
    if(!_listening || !_changedClass) return;
    IOBluetoothHostController *controller=IOBluetoothHostController.defaultController;
    if(!controller || (controller.classOfDevice&0x241ffc)==0x240414) return;
    // Renew only after the SDK's timed override has expired; avoid repeatedly
    // replacing an active override and overwriting the saved pre-test class.
    IOReturn result=[controller setClassOfDevice:0x240414 forTimeInterval:120];
    [self log:[NSString stringWithFormat:@"Renewed expired audio-device class: %@; readback=0x%06x",statusText(result),(unsigned)controller.classOfDevice]];
    if(result || (controller.classOfDevice&0x241ffc)!=0x240414) {
        [self log:@"Audio class renewal could not be verified; stopped renewal attempts. The listener remains active."];
        [_classTimer invalidate]; _classTimer=nil;
    }
}
- (void)basebandConnected:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self basebandConnected:notification device:device]; }); return;
    }
    (void)notification;
    if(!_listening) return;
    _connectionEvents++;
    [self log:[NSString stringWithFormat:@"Bluetooth link event: %@. This is not yet an A2DP audio connection.",device.name ?: @"unnamed device"]];
}
- (void)resetStream {
    am_output_stop(&_output);
    am_media_finish(&_media);
    _rejectedMedia=0;
}
- (void)closeMedia {
    [self resetStream];
    IOBluetoothL2CAPChannel *channel=_mediaChannel; _mediaChannel=nil;
    [channel setDelegate:nil]; [channel closeChannel];
    _session.mediaConnected=false;
}
- (void)stop {
    _pending=NO; _listening=NO;
    _activePSM=0;
    _stage=@"Stopped";
    [_classTimer invalidate]; _classTimer=nil;
    [_connectionNotification unregister]; _connectionNotification=nil;
    [_notification unregister]; _notification=nil;
    [self closeMedia];
    IOBluetoothL2CAPChannel *channel=_signaling; _signaling=nil;
    [channel setDelegate:nil]; [channel closeChannel];
    _peer=nil; am_avdtp_reset(&_session); memset(&_fragments,0,sizeof(_fragments));
    if(_record) {
        IOReturn result=[_record removeServiceRecord];
        if(result) _cleanupFailed=YES;
        [self log:[NSString stringWithFormat:@"SDP removal: %@",statusText(result)]]; _record=nil;
    }
    if(_changedClass) {
        IOReturn result=[IOBluetoothHostController.defaultController setClassOfDevice:_originalClass forTimeInterval:120];
        [self log:[NSString stringWithFormat:@"Restored original device class: %@",statusText(result)]];
        _changedClass=NO;
    }
}
- (void)channelOpened:(IOBluetoothUserNotification *)notification channel:(IOBluetoothL2CAPChannel *)channel {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self channelOpened:notification channel:channel]; }); return;
    }
    // IOBluetooth may replay pre-existing channels with a different notification.
    // Do not close or take delegates from unrelated/system-owned connections.
    if(!_listening || notification!=_notification) return;
    NSString *address=channel.device.addressString;
    if(_peer && ![_peer isEqualToString:address]) {
        [self log:@"Rejected additional device; this test supports one source."]; [channel closeChannel]; return;
    }
    _incomingChannels++;
    if(!_signaling) {
        _signaling=channel; _peer=address;
        _stage=@"Signaling channel received";
        am_avdtp_reset(&_session); memset(&_fragments,0,sizeof(_fragments));
        [self log:[NSString stringWithFormat:@"Incoming signaling channel from %@",channel.device.name ?: @"unnamed device"]];
    } else if(!_mediaChannel && _session.state==AM_OPEN) {
        _mediaChannel=channel; _session.mediaConnected=true;
        _stage=@"Media channel received; waiting for Start";
        [self log:@"Incoming media channel."];
    } else {
        [self log:@"Rejected unexpected additional channel."]; [channel closeChannel]; return;
    }
    IOReturn result=[channel setDelegate:self];
    [self log:[NSString stringWithFormat:@"Channel delegate: %@",statusText(result)]];
    if(result) {
        if(channel==_signaling) { _signaling=nil; _peer=nil; }
        else { _mediaChannel=nil; _session.mediaConnected=false; }
        [channel closeChannel];
    }
}
- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)channel status:(IOReturn)status {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self l2capChannelOpenComplete:channel status:status]; }); return;
    }
    if(channel!=_signaling && channel!=_mediaChannel) return;
    [self log:[NSString stringWithFormat:@"Channel open completed: %@",statusText(status)]];
    if(status) [self l2capChannelClosed:channel];
}
- (BOOL)preparePlayback {
    [self resetStream];
    if(am_media_init(&_media,_session.sbc,&_output.ring,self.queueMilliseconds)) {
        [self log:@"SBC decoder initialization failed."]; return NO;
    }
    OSStatus status=am_output_start(&_output,_media.rate,(__bridge CFStringRef)self.outputUID);
    if(status) {
        [self log:[NSString stringWithFormat:@"Audio output failed with status %d; select an available output and reconnect.",(int)status]];
        am_media_finish(&_media); return NO;
    }
    [self log:[NSString stringWithFormat:@"PCM output ready: %u Hz, stereo; app queue limit %u ms (no deliberate prefill).",_media.rate,self.queueMilliseconds]];
    return YES;
}
- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)channel data:(void *)data length:(size_t)length {
    if(!NSThread.isMainThread) {
        NSData *packet=[NSData dataWithBytes:data length:length];
        dispatch_async(dispatch_get_main_queue(),^{ [self l2capChannelData:channel data:(void *)packet.bytes length:packet.length]; }); return;
    }
    if(channel==_mediaChannel) {
        if(_session.state!=AM_STREAMING || !_media.initialized) return;
        uint64_t before=_media.decodedFrames;
        if(!am_media_packet(&_media,data,length)) {
            if(_rejectedMedia++<3) [self log:@"Rejected malformed, lost-fragment, duplicate, or unsupported media packet (see counters)."];
        } else if(!before && _media.decodedFrames) {
            _stage=@"SBC audio decoded; check audible playback";
            [self log:@"First SBC audio decoded to PCM. Check audible output; total latency is not measured."];
        }
        return;
    }
    if(channel!=_signaling) return;
    uint8_t command[1026];
    int n=am_avdtp_reassemble(&_fragments,data,length,command,sizeof(command));
    if(n<0) { [self log:@"Rejected malformed/oversized signaling fragments."]; return; }
    if(!n) return;
    AMAVDTP prior=_session;
    AMAVDTPReply reply=am_avdtp_command(&_session,command,(size_t)n);
    if(!reply.length) return;
    BOOL accepted=(reply.bytes[0]&3)==2;
    // Do not acknowledge START if playback cannot actually be initialized.
    if(accepted && command[1]==7 && ![self preparePlayback]) {
        _session=prior; reply.bytes[0]=(uint8_t)((reply.bytes[0]&0xf0)|3);
        reply.bytes[2]=4; reply.bytes[3]=0x31; reply.length=4;
        accepted=NO;
    }
    [self log:[NSString stringWithFormat:@"%s: %@; state=%s",am_signal_name(command[1]),accepted ? @"accept" : @"reject",am_stream_state(_session.state)]];
    NSData *rx=[NSData dataWithBytes:command length:MIN((size_t)n,(size_t)32)];
    NSData *tx=[NSData dataWithBytes:reply.bytes length:reply.length];
    [self log:[NSString stringWithFormat:@"AVDTP RX %@ → TX %@",rx,tx]];
    IOReturn result=[channel writeSync:reply.bytes length:(UInt16)reply.length];
    if(result) {
        [self log:[NSString stringWithFormat:@"Signaling write failed: %@",statusText(result)]];
        [channel closeChannel]; [self l2capChannelClosed:channel]; return;
    }
    if(reply.configurationChanged) {
        _stage=@"SBC configured; waiting for media/start";
        [self log:[NSString stringWithFormat:@"SBC selected: %u Hz, %u channel(s), bitpool %u–%u",am_sbc_rate(_session.sbc),am_sbc_channels(_session.sbc),_session.sbc[2],_session.sbc[3]]];
    }
    if(accepted && command[1]==9) [self resetStream];
    if(reply.closeMedia) [self closeMedia];
}
- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)channel {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self l2capChannelClosed:channel]; }); return;
    }
    if(channel==_signaling) {
        _signaling=nil; [self closeMedia]; _peer=nil;
        am_avdtp_reset(&_session); memset(&_fragments,0,sizeof(_fragments));
        [self log:@"Signaling disconnected. Ready for a new source connection."];
        _stage=@"Signaling disconnected; waiting for source";
    } else if(channel==_mediaChannel) {
        _mediaChannel=nil; [self resetStream]; am_avdtp_reset(&_session);
        [self log:@"Media disconnected. Stream reset; source may configure again."];
        _stage=@"Media disconnected";
    }
}
- (void)setVolume:(double)volume {
    volume=fmax(0,fmin(volume,1)); atomic_store(&_output.ring.gainQ16,(uint32_t)(volume*65536));
}
- (NSString *)statistics {
    uint64_t queued=atomic_load(&_output.ring.writeFrame)-atomic_load(&_output.ring.readFrame);
    double ms=_media.rate ? 1000.0*queued/_media.rate : 0;
    return [NSString stringWithFormat:@"%@ · %s · link events %u · channels %u\nPackets %llu · PCM frames %llu · lost %llu · invalid %llu\nApp queue %.1f ms · dropped frames %llu · silent-fill frames %llu · output error %d",
        _stage,am_stream_state(_session.state),_connectionEvents,_incomingChannels,(unsigned long long)_media.packets,
        (unsigned long long)_media.decodedFrames,(unsigned long long)_media.lostPackets,
        (unsigned long long)_media.invalidPackets,ms,
        (unsigned long long)atomic_load(&_output.ring.droppedFrames),
        (unsigned long long)atomic_load(&_output.ring.underrunFrames),atomic_load(&_output.callbackError)];
}
@end
