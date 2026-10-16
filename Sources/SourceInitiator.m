#import "SourceInitiator.h"
#import "Initiator.h"
#include <mach/error.h>
#include <math.h>
@interface AMSDPQueryTarget : NSObject
@property(nonatomic,copy) void (^completion)(IOBluetoothDevice *,IOReturn);
@property(nonatomic) NSUInteger attempt;
@end
@implementation AMSDPQueryTarget
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if(self.completion) self.completion(device,status);
}
@end
@implementation AMSourceInitiator {
    CBCentralManager *_manager;
    IOBluetoothDevice *_device;
    IOBluetoothL2CAPChannel *_signaling,*_transport;
    IOBluetoothUserNotification *_disconnect;
    NSTimer *_timeout;
    AMInitiator _initiator;
    AMAVDTPFragments _responses,_commands;
    AMMedia _media;
    AMAudioOutput _output;
    BOOL _active,_openingMedia;
    BOOL _inspectOnly,_queryPending;
    NSUInteger _attempt;
    AMSDPQueryTarget *_queryTarget;
    NSMutableArray<AMSDPQueryTarget *> *_queryTargets;
    NSString *_stage;
}
- (instancetype)init {
    if((self=[super init])) { _queueMilliseconds=60; _stage=@"Outbound probe not started"; _queryTargets=[NSMutableArray array]; am_output_init(&_output); }
    return self;
}
- (BOOL)active { return _active; }
- (void)log:(NSString *)message {
    NSString *line=[@"Outbound: " stringByAppendingString:message];
    fprintf(stderr,"%s\n",line.UTF8String); if(self.logger) self.logger(line);
}
- (void)requestBluetoothAccess {
    if(!_manager) _manager=[[CBCentralManager alloc] initWithDelegate:self queue:dispatch_get_main_queue()];
}
- (void)startWithDevice:(IOBluetoothDevice *)device {
    [self beginWithDevice:device inspectOnly:NO];
}
- (void)inspectDevice:(IOBluetoothDevice *)device {
    [self beginWithDevice:device inspectOnly:YES];
}
- (void)beginWithDevice:(IOBluetoothDevice *)device inspectOnly:(BOOL)inspectOnly {
    [self stop];
    if(!device) { _stage=@"No source selected"; return; }
    _inspectOnly=inspectOnly;
    _device=device; _active=YES; _stage=@"Requesting outbound Bluetooth access";
    [self log:[NSString stringWithFormat:@"Selected source: %@; paired=%d",device.name ?: @"unnamed device",device.isPaired]];
    if(CBManager.authorization==CBManagerAuthorizationDenied || CBManager.authorization==CBManagerAuthorizationRestricted) {
        [self failed:@"Bluetooth permission denied/restricted"]; return;
    }
    [self requestBluetoothAccess];
    if(_manager.state==CBManagerStatePoweredOn) [self querySource];
}
- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    [self log:[NSString stringWithFormat:@"Bluetooth state=%ld authorization=%ld",(long)central.state,(long)CBManager.authorization]];
    if(!_active) return;
    if(central.state==CBManagerStatePoweredOn && !_queryPending && !_signaling) [self querySource];
    else if(central.state!=CBManagerStateUnknown && central.state!=CBManagerStateResetting && central.state!=CBManagerStatePoweredOn)
        [self failed:@"Bluetooth unavailable"];
}
- (void)querySource {
    if(_queryTargets.count) { [self failed:@"A previous system SDP query is still outstanding; no additional query started"]; return; }
    IOBluetoothSDPServiceRecord *cached=[_device getServiceRecordForUUID:[IOBluetoothSDPUUID uuid16:0x110a]];
    [self log:[NSString stringWithFormat:@"PRE-QUERY CACHE ONLY: timestamp=%@; Audio Source=%@; attributes=%@. Cache is not a fresh response or a working audio route.",
        _device.getLastServicesUpdate ?: @"none",cached ? @"present" : @"absent",cached.attributes ?: @{}]];
    _queryPending=YES; _stage=@"Querying selected source's SDP (unfiltered; Audio Source selected afterward)";
    [self log:_stage]; [self armTimeout];
    NSUInteger attempt=_attempt;
    __weak AMSourceInitiator *weakSelf=self;
    _queryTarget=[AMSDPQueryTarget new];
    _queryTarget.attempt=attempt;
    [_queryTargets addObject:_queryTarget];
    _queryTarget.completion=^(IOBluetoothDevice *device,IOReturn status) {
        dispatch_async(dispatch_get_main_queue(),^{ [weakSelf sourceQueryComplete:device status:status attempt:attempt]; });
    };
    // Use the unfiltered form, also used by Chromium's BluetoothSocketMac.
    // The UUID-filtered variant never completed during the live 0.9 phone test.
    IOReturn status=[_device performSDPQuery:_queryTarget];
    [self log:[NSString stringWithFormat:@"SDP query request: 0x%08x (%s)",(unsigned)status,mach_error_string(status)]];
    if(status) { [_queryTargets removeObject:_queryTarget]; [self failed:@"Could not start selected source's SDP query"]; }
}
- (void)sourceQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status attempt:(NSUInteger)attempt {
    NSIndexSet *completed=[_queryTargets indexesOfObjectsPassingTest:^BOOL(AMSDPQueryTarget *target,NSUInteger idx,BOOL *stop) {
        (void)idx; (void)stop; return target.attempt==attempt;
    }];
    [_queryTargets removeObjectsAtIndexes:completed];
    if(!_active || !_queryPending || attempt!=_attempt || device!=_device) {
        [self log:[NSString stringWithFormat:@"Late SDP completion ignored for session state: status=0x%08x; cache timestamp=%@",
            (unsigned)status,device.getLastServicesUpdate ?: @"none"]]; return;
    }
    _queryPending=NO; _queryTarget=nil; [_timeout invalidate]; _timeout=nil;
    [self log:[NSString stringWithFormat:@"SDP query completed: 0x%08x (%s); service-cache timestamp=%@",
        (unsigned)status,mach_error_string(status),device.getLastServicesUpdate ?: @"none"]];
    if(status) { [self failed:@"Selected source's SDP query failed; no audio connection attempted"]; return; }
    IOBluetoothSDPServiceRecord *source=[device getServiceRecordForUUID:[IOBluetoothSDPUUID uuid16:0x110a]];
    if(!source) { [self failed:@"Query completed without Audio Source service 0x110A; no audio connection attempted"]; return; }
    BluetoothL2CAPPSM psm=0;
    IOReturn readStatus=[source getL2CAPPSM:&psm];
    [self log:[NSString stringWithFormat:@"Audio Source: PSM=0x%04x (read status 0x%08x); attributes=%@",psm,(unsigned)readStatus,source.attributes]];
    if(readStatus || psm!=0x0019) { [self failed:@"Source does not advertise standard AVDTP PSM 0x0019; no audio connection attempted"]; return; }
    if(_inspectOnly) {
        [self stop]; _stage=@"SDP inspection complete: Audio Source advertises 0x0019. No audio connection attempted.";
        [self log:_stage]; return;
    }
    [self openSignaling];
}
- (void)armTimeout {
    [_timeout invalidate];
    __weak AMSourceInitiator *weakSelf=self;
    _timeout=[NSTimer scheduledTimerWithTimeInterval:12 repeats:NO block:^(NSTimer *timer) {
        (void)timer; AMSourceInitiator *source=weakSelf;
        if(source) [source failed:source->_queryPending ? @"Timed out waiting for the selected source's SDP query" :
            @"Timed out waiting for the selected source/AVDTP response"];
    }];
}
- (void)openSignaling {
    _stage=@"Opening Mac → source AVDTP signaling (0x0019)";
    [self log:_stage]; [self armTimeout];
    _disconnect=[_device registerForDisconnectNotification:self selector:@selector(disconnected:device:)];
    IOBluetoothL2CAPChannel *channel=nil;
    IOReturn status=[_device openL2CAPChannelAsync:&channel withPSM:0x0019 delegate:self];
    [self log:[NSString stringWithFormat:@"Signaling open request: 0x%08x (%s)",(unsigned)status,mach_error_string(status)]];
    if(status || !channel) { [self failed:@"Could not open an outgoing signaling channel"]; return; }
    _signaling=channel;
}
- (void)failed:(NSString *)reason {
    if(!_active) return;
    [self log:[@"FAILED: " stringByAppendingString:reason]];
    [self stop]; _stage=[@"Outbound FAILED: " stringByAppendingString:reason];
}
- (void)stop {
    _attempt++; _queryPending=NO; _queryTarget=nil;
    _active=NO; _openingMedia=NO;
    [_timeout invalidate]; _timeout=nil;
    [_disconnect unregister]; _disconnect=nil;
    am_output_stop(&_output); am_media_finish(&_media);
    IOBluetoothL2CAPChannel *media=_transport,*signaling=_signaling;
    _transport=nil; _signaling=nil;
    [media setDelegate:nil]; [media closeChannel];
    [signaling setDelegate:nil]; [signaling closeChannel];
    _device=nil; memset(&_initiator,0,sizeof(_initiator));
    memset(&_responses,0,sizeof(_responses)); memset(&_commands,0,sizeof(_commands));
    _stage=@"Outbound stopped";
}
- (void)disconnected:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self disconnected:notification device:device]; }); return;
    }
    if(notification!=_disconnect || device!=_device) return;
    (void)notification; (void)device;
    if(_active) [self failed:@"Selected source disconnected (public notification supplies no HCI reason)"];
}
- (void)performAction:(AMInitiatorAction)action {
    if(!_active) return;
    switch(action.kind) {
        case AM_INT_SEND: {
            _stage=[NSString stringWithFormat:@"Outbound: waiting for %@",@(am_signal_name(action.bytes[1]))];
            [self log:[NSString stringWithFormat:@"TX %@: %@",@(am_signal_name(action.bytes[1])),[NSData dataWithBytes:action.bytes length:action.length]]];
            IOReturn status=[_signaling writeSync:action.bytes length:(UInt16)action.length];
            if(status) [self failed:[NSString stringWithFormat:@"Signaling write failed: 0x%08x",(unsigned)status]];
            else [self armTimeout];
            break;
        }
        case AM_INT_OPEN_MEDIA: {
            _stage=@"Opening Mac → source media transport (0x0019)";
            [self log:_stage]; _openingMedia=YES; [self armTimeout];
            IOBluetoothL2CAPChannel *channel=nil;
            IOReturn status=[_device openL2CAPChannelAsync:&channel withPSM:0x0019 delegate:self];
            if(status || !channel) [self failed:[NSString stringWithFormat:@"Media open failed: 0x%08x",(unsigned)status]];
            else _transport=channel;
            break;
        }
        case AM_INT_STARTED:
            [_timeout invalidate]; _timeout=nil;
            _stage=@"Outbound: source accepted Start; waiting for audio packets";
            [self log:_stage]; break;
        case AM_INT_ERROR: [self failed:@(action.error)]; break;
        default: break;
    }
}
- (BOOL)prepareOutput {
    if(_media.initialized) return YES;
    if(am_media_init(&_media,_initiator.session.sbc,&_output.ring,self.queueMilliseconds)) return NO;
    OSStatus status=am_output_start(&_output,_media.rate,(__bridge CFStringRef)self.outputUID);
    if(status) { [self log:[NSString stringWithFormat:@"Audio output error: %d",(int)status]]; am_media_finish(&_media); return NO; }
    [self log:[NSString stringWithFormat:@"SBC playback prepared at %u Hz before Start",_media.rate]];
    return YES;
}
- (void)l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)channel status:(IOReturn)status {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self l2capChannelOpenComplete:channel status:status]; }); return;
    }
    if(!_active) return;
    if(channel!=_signaling && channel!=_transport) return;
    if(status) { [self failed:[NSString stringWithFormat:@"L2CAP open completion failed: 0x%08x (%s)",(unsigned)status,mach_error_string(status)]]; return; }
    if(_openingMedia) {
        _transport=channel; _openingMedia=NO;
        if(![self prepareOutput]) { [self failed:@"Could not prepare playback"]; return; }
        [self performAction:am_initiator_media_connected(&_initiator)];
    } else {
        _signaling=channel;
        [self log:@"Outgoing signaling channel established; sending Discover as Sink/Initiator"];
        [self performAction:am_initiator_begin(&_initiator)];
    }
}
- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)channel data:(void *)data length:(size_t)length {
    if(!NSThread.isMainThread) {
        NSData *packet=[NSData dataWithBytes:data length:length];
        dispatch_async(dispatch_get_main_queue(),^{ [self l2capChannelData:channel data:(void *)packet.bytes length:packet.length]; }); return;
    }
    if(!_active) return;
    if(channel==_transport) {
        if(!_media.initialized) return;
        uint64_t before=_media.decodedFrames;
        am_media_packet(&_media,data,length);
        if(!before && _media.decodedFrames) { _stage=@"Outbound: SBC PCM decoded; confirm audible playback"; [self log:_stage]; }
        return;
    }
    if(channel!=_signaling || !length) return;
    uint8_t *packet=data,complete[1026];
    BOOL response=(packet[0]&3)!=0;
    int size=am_avdtp_reassemble_message(response ? &_responses : &_commands,packet,length,complete,sizeof(complete));
    if(size<0) { [self failed:@"Malformed signaling fragmentation"]; return; }
    if(!size) return;
    [self log:[NSString stringWithFormat:@"RX %@: %@",@(am_signal_name(complete[1]&0x3f)),[NSData dataWithBytes:complete length:(NSUInteger)size]]];
    if(response) [self performAction:am_initiator_response(&_initiator,complete,(size_t)size)];
    else {
        if((complete[1]&0x3f)==7 && ![self prepareOutput]) { [self failed:@"Playback unavailable for source Start"]; return; }
        AMAVDTPReply reply=am_avdtp_command(&_initiator.session,complete,(size_t)size);
        if(reply.length && [_signaling writeSync:reply.bytes length:(UInt16)reply.length]) { [self failed:@"Could not reply to source command"]; return; }
        if(reply.closeMedia) [self failed:@"Source closed or aborted the stream"];
    }
}
- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)channel {
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ [self l2capChannelClosed:channel]; }); return;
    }
    if(_active && (channel==_signaling || channel==_transport)) [self failed:@"Outgoing AVDTP channel closed"];
}
- (void)setVolume:(double)volume {
    atomic_store(&_output.ring.gainQ16,(uint32_t)(fmax(0,fmin(1,volume))*65536));
}
- (NSString *)statistics {
    return [NSString stringWithFormat:@"%@\nPackets %llu · PCM frames %llu · lost %llu · invalid %llu",_stage,
        (unsigned long long)_media.packets,(unsigned long long)_media.decodedFrames,
        (unsigned long long)_media.lostPackets,(unsigned long long)_media.invalidPackets];
}
@end
