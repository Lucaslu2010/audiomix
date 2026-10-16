#import <AppKit/AppKit.h>
#import "WiredCapture.h"
#import "MacAudio.h"
#import "DeviceVolumePanel.h"
#include <math.h>

static NSString *const AWMacSourceID=@"host:mac";

@interface WiredApp : NSObject <NSApplicationDelegate,NSWindowDelegate>
@end
@implementation WiredApp {
    NSWindow *_window;
    NSPopUpButton *_sources,*_outputs,*_queue;
    NSButton *_start,*_refresh,*_other,*_compat,*_testOutput,*_probe;
    NSTextView *_log;
    NSTextField *_statistics;
    NSMutableString *_transcript;
    AWWiredCapture *_capture;
    AWWiredCapture *_testCapture;
    NSMutableDictionary<NSString *,AWWiredCapture *> *_captures;
    NSMutableDictionary<NSString *,NSNumber *> *_gains,*_muted;
    NSArray<NSDictionary *> *_availableSources;
    AWMacAudio *_macAudio;
    AWDeviceVolumePanel *_volumePanel;
    NSTimer *_timer;
    dispatch_queue_t _discovery;
    BOOL _refreshing,_probing;
    NSLock *_probeLock;
    NSTask *_probeTask;
    BOOL _shuttingDown;
    id _connected,_disconnected;
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame bold:(BOOL)bold {
    NSTextField *field=[NSTextField labelWithString:text]; field.frame=frame;
    field.font=bold ? [NSFont boldSystemFontOfSize:16] : [NSFont systemFontOfSize:13];
    field.lineBreakMode=NSLineBreakByWordWrapping; field.maximumNumberOfLines=0;
    [_window.contentView addSubview:field]; return field;
}
- (NSButton *)button:(NSString *)text action:(SEL)action frame:(NSRect)frame {
    NSButton *button=[NSButton buttonWithTitle:text target:self action:action]; button.frame=frame;
    [_window.contentView addSubview:button]; return button;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _transcript=[NSMutableString string]; _testCapture=[AWWiredCapture new]; _capture=_testCapture; _probeLock=[NSLock new];
    _captures=[NSMutableDictionary dictionary]; _macAudio=[AWMacAudio new];
    _gains=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"DeviceGains"] mutableCopy] ?: [NSMutableDictionary dictionary];
    _muted=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"DeviceMutes"] mutableCopy] ?: [NSMutableDictionary dictionary];
    _availableSources=@[];
    _discovery=dispatch_queue_create("local.audiomix.wired.discovery",DISPATCH_QUEUE_SERIAL);
    _window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,820,650)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.title=@"AudioMix — Wired Audio Test"; _window.delegate=self; [_window center];
    [self label:@"iPad / iPhone → USB → Mac audio" frame:NSMakeRect(20,595,780,28) bold:YES];
    [self label:@"Connect a data-capable USB cable, unlock the device, and trust this Mac. Choose an input and output. Audio-only capture is the default."
        frame:NSMakeRect(20,548,780,42) bold:NO];
    [self label:@"Input" frame:NSMakeRect(20,508,55,25) bold:NO];
    _sources=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(78,505,565,30) pullsDown:NO];
    [_sources addItemWithTitle:@"Connect USB, then Refresh"];
    _sources.target=self; _sources.action=@selector(sourceSelected:);
    [_window.contentView addSubview:_sources];
    _refresh=[self button:@"Refresh" action:@selector(refresh:) frame:NSMakeRect(660,505,140,30)];
    [self label:@"Output" frame:NSMakeRect(20,468,55,25) bold:NO];
    _outputs=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(78,465,722,30) pullsDown:NO];
    [_outputs addItemWithTitle:@"System default at Start"]; _outputs.lastItem.representedObject=@{};
    [_window.contentView addSubview:_outputs];
    _other=[NSButton checkboxWithTitle:@"Show other audio inputs" target:self action:@selector(refresh:)];
    _other.frame=NSMakeRect(20,428,230,26); [_window.contentView addSubview:_other];
    _compat=[NSButton checkboxWithTitle:@"Compatibility: activate screen stream and discard video" target:nil action:nil];
    _compat.frame=NSMakeRect(265,428,535,26); [_window.contentView addSubview:_compat];
    _start=[self button:@"Start audio" action:@selector(toggle:) frame:NSMakeRect(20,380,145,32)];
    [self button:@"Audio MIDI Setup" action:@selector(audioMIDI:) frame:NSMakeRect(180,380,155,32)];
    [self button:@"Capture access" action:@selector(authorize:) frame:NSMakeRect(350,380,145,32)];
    [self button:@"Device volumes…" action:@selector(deviceVolumes:) frame:NSMakeRect(515,380,285,32)];
    [self label:@"Maximum app queue" frame:NSMakeRect(20,343,150,25) bold:NO];
    _queue=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(170,340,100,28) pullsDown:NO];
    for(NSNumber *milliseconds in @[@5,@10,@20,@40,@80]) {
        [_queue addItemWithTitle:[NSString stringWithFormat:@"%@ ms",milliseconds]]; _queue.lastItem.representedObject=milliseconds;
    }
    [_queue selectItemAtIndex:3]; [_window.contentView addSubview:_queue];
    _testOutput=[self button:@"Test output" action:@selector(testOutput:) frame:NSMakeRect(300,340,125,30)];
    _probe=[self button:@"USB capabilities" action:@selector(probeUSB:) frame:NSMakeRect(440,340,145,30)];
    [self button:@"Save log…" action:@selector(save:) frame:NSMakeRect(675,340,125,30)];
    _statistics=[self label:@"Stopped" frame:NSMakeRect(20,248,780,80) bold:NO];
    _statistics.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(20,65,780,175)];
    scroll.hasVerticalScroller=YES; scroll.borderType=NSBezelBorder;
    _log=[[NSTextView alloc] initWithFrame:scroll.contentView.bounds]; _log.editable=NO;
    _log.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _log.autoresizingMask=NSViewWidthSizable; scroll.documentView=_log; [_window.contentView addSubview:scroll];
    [self label:@"If no USB audio input appears, open Audio MIDI Setup and Enable the iPad/iPhone, then Refresh. AirPods add output latency. Queue statistics are not game-to-ear delay."
        frame:NSMakeRect(20,10,780,47) bold:NO];
    __weak WiredApp *weakSelf=self;
    _testCapture.logger=^(NSString *message) { [weakSelf append:message]; };
    _macAudio.logger=^(NSString *message) { [weakSelf append:message]; };
    [_macAudio setVolume:[self effectiveGain:AWMacSourceID]];
    _timer=[NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    void (^changed)(NSNotification *)=^(NSNotification *n) { (void)n; [weakSelf refresh:nil]; };
    _connected=[NSNotificationCenter.defaultCenter addObserverForName:AVCaptureDeviceWasConnectedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:changed];
    _disconnected=[NSNotificationCenter.defaultCenter addObserverForName:AVCaptureDeviceWasDisconnectedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:changed];
    NSMenu *bar=[NSMenu new]; NSMenuItem *root=[NSMenuItem new]; [bar addItem:root]; NSMenu *menu=[NSMenu new];
    NSMenuItem *volumes=[menu addItemWithTitle:@"Device volumes…" action:@selector(deviceVolumes:) keyEquivalent:@"d"]; volumes.target=self;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit AudioMix Wired Test" action:@selector(terminate:) keyEquivalent:@"q"]; root.submenu=menu;
    NSApp.mainMenu=bar;
    [self append:@"AudioMix Wired Test 0.7 — independent device volumes, native USB input and optional Mac audio control."];
    [self append:@"No Bluetooth receiver, recording, or video output is started. Choose the intended USB source before Start."];
    [self append:@"The queue cap also expires PCM by age since Mac receipt. It is not a measured game-to-ear latency. Small caps may cause dropouts."];
    [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; [self refresh:nil];
}
- (void)append:(NSString *)message {
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{ [self append:message]; }); return; }
    NSString *time=[NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle];
    [_transcript appendFormat:@"[%@] %@\n",time,message];
    if(_transcript.length>128000) [_transcript deleteCharactersInRange:NSMakeRange(0,_transcript.length-96000)];
    _log.string=_transcript; [_log scrollRangeToVisible:NSMakeRange(_log.string.length,0)];
}
- (void)refresh:(id)sender {
    (void)sender; if(_refreshing || _probing) return;
    _refreshing=YES; _refresh.enabled=NO;
    AVCaptureDevice *selectedDevice=_sources.selectedItem.representedObject;
    NSString *selected=selectedDevice.uniqueID;
    NSDictionary *output=_outputs.selectedItem.representedObject;
    BOOL other=_other.state==NSControlStateValueOn;
    dispatch_async(_discovery,^{
        OSStatus discovery=AWEnableWiredCaptureDiscovery();
        NSArray *sources=AWCaptureSources(other),*outputs=AWOutputDevices();
        dispatch_async(dispatch_get_main_queue(),^{
            self->_availableSources=sources;
            [self->_sources removeAllItems]; [self->_sources addItemWithTitle:@"Choose a USB audio source"];
            for(NSDictionary *source in sources) {
                [self->_sources addItemWithTitle:source[@"name"]]; self->_sources.lastItem.representedObject=source[@"device"];
                AVCaptureDevice *device=source[@"device"];
                if([selected isEqualToString:device.uniqueID]) [self->_sources selectItem:self->_sources.lastItem];
            }
            [self->_outputs removeAllItems]; [self->_outputs addItemWithTitle:@"System default at Start"]; self->_outputs.lastItem.representedObject=@{};
            BOOL found=NO;
            for(NSDictionary *device in outputs) {
                [self->_outputs addItemWithTitle:device[@"name"]]; self->_outputs.lastItem.representedObject=device;
                if([output[@"uid"] isEqual:device[@"uid"]]) { [self->_outputs selectItem:self->_outputs.lastItem]; found=YES; }
            }
            if(output[@"uid"] && !found) {
                [self->_outputs addItemWithTitle:[@"Unavailable — " stringByAppendingString:output[@"name"]]];
                self->_outputs.lastItem.representedObject=output;
                [self->_outputs selectItem:self->_outputs.lastItem];
            }
            self->_refreshing=NO; [self tick:nil];
            [self append:[NSString stringWithFormat:@"Discovery status=%d; %lu input(s), %lu output(s). Wired sources sort first; no input is opened automatically.",(int)discovery,(unsigned long)sources.count,(unsigned long)outputs.count]];
            for(NSDictionary *source in sources) {
                AVCaptureDevice *device=source[@"device"];
                [self append:[NSString stringWithFormat:@"Available input: %@; type=%@; model=%@; transport=0x%08x; audio=%d muxed=%d video=%d",
                    source[@"name"],device.deviceType,device.modelID,(unsigned)device.transportType,
                    [device hasMediaType:AVMediaTypeAudio],[device hasMediaType:AVMediaTypeMuxed],[device hasMediaType:AVMediaTypeVideo]]];
            }
        });
    });
}
- (void)toggle:(id)sender {
    (void)sender;
    if(_refreshing) return;
    AVCaptureDevice *device=_sources.selectedItem.representedObject;
    if(!device) { [self append:@"Choose the intended source. For IDAM, Enable it in Audio MIDI Setup first."]; return; }
    [self toggleDevice:device];
}
- (void)sourceSelected:(id)sender { (void)sender; [self tick:nil]; }
- (BOOL)anyActive {
    if(_testCapture.active || _macAudio.active) return YES;
    for(AWWiredCapture *capture in _captures.allValues) if(capture.active) return YES;
    return NO;
}
- (float)gain:(NSString *)sourceID {
    id value=_gains[sourceID]; float gain=[value respondsToSelector:@selector(floatValue)] ? [value floatValue] :
        ([sourceID isEqual:AWMacSourceID] ? 1.f : 0.35f);
    return isfinite(gain) ? fmaxf(0,fminf(1,gain)) : 0;
}
- (float)effectiveGain:(NSString *)sourceID { return [_muted[sourceID] boolValue] ? 0 : [self gain:sourceID]; }
- (void)applyVolume:(NSString *)sourceID {
    float gain=[self effectiveGain:sourceID];
    if([sourceID isEqual:AWMacSourceID]) [_macAudio setVolume:gain];
    else [_captures[sourceID] setVolume:gain];
    [NSUserDefaults.standardUserDefaults setObject:_gains forKey:@"DeviceGains"];
    [NSUserDefaults.standardUserDefaults setObject:_muted forKey:@"DeviceMutes"];
    [self updateVolumePanel];
}
- (void)toggleDevice:(AVCaptureDevice *)device {
    for(NSMenuItem *item in _sources.itemArray) {
        AVCaptureDevice *candidate=item.representedObject;
        if([candidate.uniqueID isEqual:device.uniqueID]) { [_sources selectItem:item]; break; }
    }
    AWWiredCapture *capture=_captures[device.uniqueID];
    if(capture.active) { [capture stop]; return; }
    if(!device.connected || _probing || _refreshing || _testCapture.active) return;
    if(!capture) {
        capture=[AWWiredCapture new]; _captures[device.uniqueID]=capture;
        __weak WiredApp *weakSelf=self; NSString *name=device.localizedName;
        capture.logger=^(NSString *message) { [weakSelf append:[NSString stringWithFormat:@"[%@] %@",name,message]]; };
    }
    [capture setVolume:[self effectiveGain:device.uniqueID]];
    [self append:[NSString stringWithFormat:@"Output: %@; source: %@; compatibility video=%d",_outputs.titleOfSelectedItem,device.localizedName,_compat.state==NSControlStateValueOn]];
    NSDictionary *output=_outputs.selectedItem.representedObject;
    [capture startDevice:device outputUID:output[@"uid"] queueMilliseconds:[_queue.selectedItem.representedObject unsignedIntValue]
        compatibilityVideo:_compat.state==NSControlStateValueOn];
    [self tick:nil];
}
- (void)deviceVolumes:(id)sender {
    (void)sender;
    if(!_volumePanel) {
        _volumePanel=[AWDeviceVolumePanel new]; __weak WiredApp *weakSelf=self;
        _volumePanel.volumeChanged=^(NSString *sourceID,float gain) {
            WiredApp *self=weakSelf; if(!self) return; self->_gains[sourceID]=@(gain); [self applyVolume:sourceID];
        };
        _volumePanel.muteChanged=^(NSString *sourceID,BOOL muted) {
            WiredApp *self=weakSelf; if(!self) return; self->_muted[sourceID]=@(muted); [self applyVolume:sourceID];
        };
        _volumePanel.toggleSource=^(NSString *sourceID) {
            WiredApp *self=weakSelf; if(!self) return;
            if([sourceID isEqual:AWMacSourceID]) {
                if(self->_macAudio.active) [self->_macAudio stop];
                else if(!self->_probing && !self->_refreshing && !self->_testCapture.active) {
                    NSDictionary *output=self->_outputs.selectedItem.representedObject;
                    [self->_macAudio startOutputUID:output[@"uid"]];
                }
            } else for(NSDictionary *source in self->_availableSources) {
                AVCaptureDevice *device=source[@"device"];
                if([device.uniqueID isEqual:sourceID]) { [self toggleDevice:device]; break; }
            }
            [self updateVolumePanel];
        };
        _volumePanel.refreshSources=^{ [weakSelf refresh:nil]; };
    }
    [self updateVolumePanel]; [_volumePanel showWindow:nil]; [_volumePanel.window makeKeyAndOrderFront:nil];
}
- (void)updateVolumePanel {
    if(!_volumePanel) return;
    NSMutableArray *rows=[NSMutableArray arrayWithObject:@{@"id":AWMacSourceID,@"name":@"This Mac",
        @"detail":_macAudio.statusText,@"gain":@([self gain:AWMacSourceID]),@"muted":@([_muted[AWMacSourceID] boolValue]),
        @"button":_macAudio.active ? @"Disable" : @"Enable",@"canToggle":@(_macAudio.active || (!_probing && !_refreshing && !_testCapture.active))}];
    for(NSDictionary *source in _availableSources) {
        AVCaptureDevice *device=source[@"device"]; if(!device.connected) continue;
        AWWiredCapture *capture=_captures[device.uniqueID];
        NSString *route=[device hasMediaType:AVMediaTypeMuxed] ? @"Screen/audio input" : @"USB audio input";
        NSString *detail=[NSString stringWithFormat:@"%@ · %@",route,capture ? capture.statusText : @"Connected · press Play to include this source"];
        [rows addObject:@{@"id":device.uniqueID,@"name":device.localizedName,@"detail":detail,
            @"gain":@([self gain:device.uniqueID]),@"muted":@([_muted[device.uniqueID] boolValue]),
            @"button":capture.active ? @"Stop" : @"Play",@"canToggle":@(capture.active || (!_probing && !_refreshing && !_testCapture.active))}];
    }
    [_volumePanel updateSources:rows outputName:_outputs.titleOfSelectedItem];
}
- (void)testOutput:(id)sender {
    (void)sender; if([self anyActive] || _refreshing) return;
    [self append:[NSString stringWithFormat:@"Testing output: %@",_outputs.titleOfSelectedItem]];
    NSDictionary *output=_outputs.selectedItem.representedObject;
    [_testCapture testOutputUID:output[@"uid"]];
}
- (void)authorize:(id)sender {
    (void)sender;
    [self append:@"Requesting microphone and camera-class capture access. USB screen/audio devices may require both; this button does not start capture."];
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL audio) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL video) {
            dispatch_async(dispatch_get_main_queue(),^{
                [self append:[NSString stringWithFormat:@"Capture authorization: microphone=%d camera=%d",audio,video]]; [self refresh:nil];
            });
        }];
    }];
}
- (NSString *)runProbe:(NSString *)path arguments:(NSArray<NSString *> *)arguments status:(int *)status {
    NSTask *task=[NSTask new]; task.executableURL=[NSURL fileURLWithPath:path]; task.arguments=arguments;
    NSPipe *pipe=[NSPipe pipe]; task.standardOutput=pipe; task.standardError=pipe;
    NSError *error=nil;
    [_probeLock lock];
    if(_shuttingDown) { [_probeLock unlock]; *status=-1; return @"Probe cancelled"; }
    BOOL launched=[task launchAndReturnError:&error];
    if(launched) _probeTask=task;
    [_probeLock unlock];
    if(!launched) { *status=-1; return error.localizedDescription; }
    NSData *data=[pipe.fileHandleForReading readDataToEndOfFile]; [task waitUntilExit];
    [_probeLock lock]; if(_probeTask==task) _probeTask=nil; [_probeLock unlock];
    *status=task.terminationStatus;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"Probe returned non-text output";
}
- (void)probeUSB:(id)sender {
    (void)sender; if([self anyActive] || _refreshing || _probing) return;
    NSString *path=[NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"AudioMixCoreDeviceProbe"];
    if(![NSFileManager.defaultManager isExecutableFileAtPath:path]) {
        [self append:@"Optional CoreDevice probe is not bundled. Build it with tools/build-coredevice-probe.sh and rebuild this app. USB audio does not need it."]; return;
    }
    _probing=YES; [self tick:nil];
    [self append:@"Reading local USB inventory, then capabilities if exactly one device is connected. No pairing, capture, developer-image installation or media startup is performed."];
    dispatch_async(_discovery,^{
        int status=0; NSString *inventory=[self runProbe:path arguments:@[@"--list"] status:&status];
        NSMutableString *result=[NSMutableString stringWithFormat:@"USB inventory (exit %d):\n%@",status,inventory];
        NSDictionary *json=status ? nil : [NSJSONSerialization JSONObjectWithData:[inventory dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if([json isKindOfClass:NSDictionary.class] && [json[@"usb_device_count"] isEqual:@1]) {
            NSString *capabilities=[self runProbe:path arguments:@[@"--usb",@"0"] status:&status];
            [result appendFormat:@"\nCoreDevice capabilities (exit %d):\n%@",status,capabilities];
        }
        dispatch_async(dispatch_get_main_queue(),^{ self->_probing=NO; [self append:result]; [self tick:nil]; });
    });
}
- (void)audioMIDI:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:@"/System/Applications/Utilities/Audio MIDI Setup.app"]];
}
- (void)save:(id)sender {
    (void)sender; NSSavePanel *panel=[NSSavePanel savePanel]; panel.nameFieldStringValue=@"AudioMix-Wired-Test.log";
    if([panel runModal]==NSModalResponseOK) {
        NSError *error=nil;
        NSString *text=[_transcript stringByAppendingFormat:@"\n%@\n",[_capture statistics]];
        if(![text writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error]) [self append:error.localizedDescription];
    }
}
- (void)tick:(NSTimer *)timer {
    (void)timer;
    AVCaptureDevice *device=_sources.selectedItem.representedObject;
    _capture=_captures[device.uniqueID ?: @""] ?: _testCapture;
    BOOL active=device && _captures[device.uniqueID].active,any=[self anyActive];
    _start.title=active ? @"Stop audio" : @"Start audio"; _start.enabled=!_refreshing && !_probing;
    _sources.enabled=!_refreshing; _outputs.enabled=!any && !_refreshing;
    _refresh.enabled=!_refreshing && !_probing; _other.enabled=!_refreshing;
    _compat.enabled=!any; _queue.enabled=!any; _statistics.stringValue=[_capture statistics];
    _testOutput.enabled=!any && !_refreshing && !_probing;
    _probe.enabled=!any && !_refreshing && !_probing;
    [_macAudio checkHealth];
    if(_volumePanel.window.visible) [self updateVolumePanel];
}
- (void)windowWillClose:(NSNotification *)notification { if(notification.object==_window) [NSApp terminate:nil]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [_probeLock lock]; _shuttingDown=YES; if(_probeTask.running) [_probeTask terminate]; [_probeLock unlock];
    [_timer invalidate]; [_testCapture shutdownAndWait];
    for(AWWiredCapture *capture in _captures.allValues) [capture shutdownAndWait];
    [_macAudio shutdownAndWait];
    [NSNotificationCenter.defaultCenter removeObserver:_connected]; [NSNotificationCenter.defaultCenter removeObserver:_disconnected];
}
@end
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        if(argc==2 && !strcmp(argv[1],"--inventory")) {
            OSStatus status=AWEnableWiredCaptureDiscovery();
            NSMutableArray *inputs=[NSMutableArray array];
            for(NSDictionary *source in AWCaptureSources(YES)) {
                AVCaptureDevice *device=source[@"device"];
                [inputs addObject:@{@"name":source[@"name"],@"type":device.deviceType ?: @"",
                    @"model":device.modelID ?: @"",@"transport":@((unsigned)device.transportType),
                    @"usbTransport":source[@"wired"],@"audio":@([device hasMediaType:AVMediaTypeAudio]),
                    @"muxed":@([device hasMediaType:AVMediaTypeMuxed]),@"video":@([device hasMediaType:AVMediaTypeVideo])}];
            }
            NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"discoveryStatus":@(status),@"inputs":inputs,
                @"outputCount":@(AWOutputDevices().count),@"captureStarted":@NO} options:NSJSONWritingPrettyPrinted error:nil];
            if(!json) return 1;
            fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout); return 0;
        }
        if(argc!=1) { fprintf(stderr,"Usage: AudioMixWired [--inventory]\n"); return 2; }
        NSApplication *app=NSApplication.sharedApplication; WiredApp *delegate=[WiredApp new];
        app.delegate=delegate; [app setActivationPolicy:NSApplicationActivationPolicyRegular]; [app run];
    }
    return 0;
}
