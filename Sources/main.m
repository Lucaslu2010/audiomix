#import <AppKit/AppKit.h>
#import <CoreAudio/CoreAudio.h>
#import "Receiver.h"
#import "SourceInitiator.h"

static NSArray<NSDictionary *> *outputDevices(void) {
    AudioObjectPropertyAddress address={kAudioHardwarePropertyDevices,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=0;
    if(AudioObjectGetPropertyDataSize(kAudioObjectSystemObject,&address,0,NULL,&size)) return @[];
    AudioDeviceID *ids=calloc(1,size);
    if(!ids) return @[];
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,0,NULL,&size,ids)) { free(ids); return @[]; }
    NSMutableArray *devices=[NSMutableArray array];
    for(unsigned i=0;i<size/sizeof(AudioDeviceID);i++) {
        AudioObjectPropertyAddress streams={kAudioDevicePropertyStreams,kAudioObjectPropertyScopeOutput,kAudioObjectPropertyElementMain};
        UInt32 streamSize=0;
        if(AudioObjectGetPropertyDataSize(ids[i],&streams,0,NULL,&streamSize) || !streamSize) continue;
        CFStringRef name=NULL,uid=NULL; UInt32 stringSize=sizeof(CFStringRef);
        AudioObjectPropertyAddress a={kAudioObjectPropertyName,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        OSStatus nameStatus=AudioObjectGetPropertyData(ids[i],&a,0,NULL,&stringSize,&name);
        a.mSelector=kAudioDevicePropertyDeviceUID; stringSize=sizeof(CFStringRef);
        OSStatus uidStatus=AudioObjectGetPropertyData(ids[i],&a,0,NULL,&stringSize,&uid);
        NSString *n=CFBridgingRelease(name), *u=CFBridgingRelease(uid);
        if(!nameStatus && !uidStatus && n && u) [devices addObject:@{@"name":n,@"uid":u}];
    }
    free(ids); return devices;
}
@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end
@implementation AppDelegate {
    NSWindow *_window;
    NSButton *_start, *_refresh, *_classCheckbox, *_experimentalCheckbox;
    NSPopUpButton *_outputs, *_queue;
    NSTextView *_log;
    NSTextField *_stats;
    AMReceiver *_receiver;
    AMSourceInitiator *_outbound;
    NSPopUpButton *_sources;
    NSButton *_sourcesRefresh,*_sourceConnect;
    BOOL _showOutbound;
    NSMutableString *_transcript;
    NSTimer *_timer;
}
- (NSTextField *)label:(NSString *)text frame:(NSRect)frame bold:(BOOL)bold {
    NSTextField *label=[NSTextField labelWithString:text]; label.frame=frame;
    label.font=bold ? [NSFont boldSystemFontOfSize:15] : [NSFont systemFontOfSize:13];
    label.lineBreakMode=NSLineBreakByWordWrapping; label.maximumNumberOfLines=0;
    [_window.contentView addSubview:label]; return label;
}
- (NSButton *)button:(NSString *)title action:(SEL)action frame:(NSRect)frame {
    NSButton *button=[NSButton buttonWithTitle:title target:self action:action];
    button.frame=frame; [_window.contentView addSubview:button]; return button;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    _receiver=[AMReceiver new]; _outbound=[AMSourceInitiator new]; _transcript=[NSMutableString string];
    _window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,800,690)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.title=@"AudioMix — Bluetooth Receiver Test"; _window.delegate=self;
    [_window center];
    [self label:@"Experimental iPad → Mac Bluetooth audio" frame:NSMakeRect(20,607,760,25) bold:YES];
    [self label:@"Uses this Mac’s built-in Bluetooth. Select AirPods or speakers below. First test reception; end-to-end latency is not measured by this app."
        frame:NSMakeRect(20,554,760,43) bold:NO];
    [self label:@"Output" frame:NSMakeRect(20,519,60,23) bold:NO];
    _outputs=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(80,516,555,28) pullsDown:NO];
    [_window.contentView addSubview:_outputs];
    _refresh=[self button:@"Refresh" action:@selector(refreshOutputs:) frame:NSMakeRect(650,516,125,28)];
    [self label:@"App queue limit" frame:NSMakeRect(20,480,120,24) bold:NO];
    _queue=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(145,478,100,28) pullsDown:NO];
    for(NSNumber *n in @[@20,@40,@60,@80]) {
        [_queue addItemWithTitle:[NSString stringWithFormat:@"%@ ms",n]];
        _queue.lastItem.representedObject=n;
    }
    [_queue selectItemAtIndex:2]; [_window.contentView addSubview:_queue];
    [self label:@"Volume" frame:NSMakeRect(285,480,65,24) bold:NO];
    NSSlider *slider=[NSSlider sliderWithValue:0.5 minValue:0 maxValue:1 target:self action:@selector(volume:)];
    slider.frame=NSMakeRect(353,479,300,25); [_window.contentView addSubview:slider];
    _classCheckbox=[NSButton checkboxWithTitle:@"Maintain temporary audio-device identity"
        target:nil action:nil]; _classCheckbox.frame=NSMakeRect(20,444,345,26);
    _classCheckbox.state=NSControlStateValueOff; _classCheckbox.enabled=NO; [_window.contentView addSubview:_classCheckbox];
    _experimentalCheckbox=[NSButton checkboxWithTitle:@"Experimental: allow custom Bluetooth port" target:nil action:nil];
    _experimentalCheckbox.frame=NSMakeRect(380,444,400,26);
    [_window.contentView addSubview:_experimentalCheckbox];
    _experimentalCheckbox.title=@"Custom-port route retired"; _experimentalCheckbox.enabled=NO;
    _start=[self button:@"Receiver disabled" action:@selector(toggle:) frame:NSMakeRect(20,402,170,32)];
    _start.enabled=NO;
    [self button:@"Bluetooth Settings" action:@selector(settings:) frame:NSMakeRect(205,402,180,32)];
    [self button:@"Copy Test Log" action:@selector(copyLog:) frame:NSMakeRect(400,402,180,32)];
    [self button:@"Save Test Log…" action:@selector(saveLog:) frame:NSMakeRect(605,402,170,32)];
    _stats=[self label:@"Stopped" frame:NSMakeRect(20,318,760,74) bold:NO];
    _stats.font=[NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
    NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(20,66,760,244)];
    scroll.hasVerticalScroller=YES; scroll.borderType=NSBezelBorder;
    _log=[[NSTextView alloc] initWithFrame:scroll.contentView.bounds];
    _log.editable=NO; _log.font=[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    _log.autoresizingMask=NSViewWidthSizable; scroll.documentView=_log;
    [_window.contentView addSubview:scroll];
    [self label:@"Inspect source queries the selected phone’s Bluetooth services. It does not advertise an audio sink or open audio channels. Local receiver tests are disabled after accessory disconnections were reported."
        frame:NSMakeRect(20,12,760,44) bold:NO];
    // Make one additional row for a separately initiated receiver connection.
    for(NSView *view in _window.contentView.subviews) if(view.frame.origin.y>=402) {
        NSRect frame=view.frame; frame.origin.y+=40; view.frame=frame;
    }
    _sources=[[NSPopUpButton alloc] initWithFrame:NSMakeRect(20,402,470,30) pullsDown:NO];
    [_sources addItemWithTitle:@"Choose iPad from recent Bluetooth devices"];
    [_window.contentView addSubview:_sources];
    _sourcesRefresh=[self button:@"Devices" action:@selector(refreshSources:) frame:NSMakeRect(500,402,95,30)];
    _sourceConnect=[self button:@"Inspect source" action:@selector(connectSource:) frame:NSMakeRect(605,402,170,30)];
    __weak AppDelegate *weakSelf=self;
    _receiver.logger=^(NSString *message) { [weakSelf append:message]; };
    _outbound.logger=_receiver.logger;
    [self refreshOutputs:nil];
    [self append:[NSString stringWithFormat:@"AudioMix Bluetooth Test %@ · %@",[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"development",NSProcessInfo.processInfo.operatingSystemVersionString]];
    [self append:@"Ready for service inspection. Receiver publication is disabled after reported accessory disconnections; no audio route is established."];
    _timer=[NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    NSMenu *bar=[NSMenu new]; NSMenuItem *appItem=[NSMenuItem new]; [bar addItem:appItem];
    NSMenu *menu=[NSMenu new];
    [menu addItemWithTitle:@"Quit AudioMix Bluetooth Test" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu=menu;
    NSMenuItem *editItem=[NSMenuItem new]; editItem.title=@"Edit"; [bar addItem:editItem];
    NSMenu *edit=[NSMenu new];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu=edit; NSApp.mainMenu=bar;
    [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
}
- (void)append:(NSString *)message {
    if(!NSThread.isMainThread) {
        NSString *copy=[message copy];
        dispatch_async(dispatch_get_main_queue(),^{ [self append:copy]; }); return;
    }
    NSString *line=[NSString stringWithFormat:@"[%@] %@\n",[NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle],message];
    [_transcript appendString:line];
    // Keep logs bounded even if a remote device sends many signaling commands.
    if(_transcript.length>128000) [_transcript deleteCharactersInRange:NSMakeRange(0,_transcript.length-96000)];
    _log.string=_transcript; [_log scrollRangeToVisible:NSMakeRange(_log.string.length,0)];
}
- (void)refreshOutputs:(id)sender {
    (void)sender;
    NSString *selected=_outputs.selectedItem.representedObject;
    [_outputs removeAllItems]; [_outputs addItemWithTitle:@"System default output"];
    for(NSDictionary *device in outputDevices()) {
        [_outputs addItemWithTitle:device[@"name"]]; _outputs.lastItem.representedObject=device[@"uid"];
        if([selected isEqualToString:device[@"uid"]]) [_outputs selectItem:_outputs.lastItem];
    }
}
- (void)toggle:(id)sender {
    (void)sender;
    _showOutbound=NO;
    if(_receiver.listening) { [_receiver stop]; [self append:@"Receiver stopped."]; }
    else {
        _receiver.outputUID=_outputs.selectedItem.representedObject;
        _receiver.queueMilliseconds=[_queue.selectedItem.representedObject unsignedIntValue];
        _receiver.useAudioDeviceClass=_classCheckbox.state==NSControlStateValueOn;
        _receiver.allowExperimentalTransport=_experimentalCheckbox.state==NSControlStateValueOn;
        [self append:[NSString stringWithFormat:@"Selected output: %@",_outputs.titleOfSelectedItem]];
        [_receiver start];
    }
    [self tick:nil];
}
- (void)refreshSources:(id)sender {
    (void)sender;
    if(CBManager.authorization!=CBManagerAuthorizationAllowedAlways) {
        [_outbound requestBluetoothAccess];
        [self append:@"Allow the Bluetooth prompt, then click Devices again to list recent sources."]; return;
    }
    NSString *selected=[_sources.selectedItem.representedObject addressString];
    [_sources removeAllItems]; [_sources addItemWithTitle:@"Choose an iPad / phone source"];
    NSMutableSet *addresses=[NSMutableSet set];
    NSArray *devices=[( [IOBluetoothDevice recentDevices:0] ?: @[] ) arrayByAddingObjectsFromArray:IOBluetoothDevice.pairedDevices ?: @[]];
    for(IOBluetoothDevice *device in devices) {
        if(!device.addressString.length || [addresses containsObject:device.addressString]) continue;
        [addresses addObject:device.addressString];
        [_sources addItemWithTitle:device.name ?: device.addressString];
        _sources.lastItem.representedObject=device;
        if([selected isEqualToString:device.addressString]) [_sources selectItem:_sources.lastItem];
    }
    [self append:[NSString stringWithFormat:@"Listed %lu recent/paired Bluetooth devices. Choose the phone, then Inspect source.",(unsigned long)addresses.count]];
}
- (void)connectSource:(id)sender {
    (void)sender; _showOutbound=YES;
    if(_outbound.active) { [_outbound stop]; [self append:@"Outbound source connection stopped."]; }
    else {
        IOBluetoothDevice *device=_sources.selectedItem.representedObject;
        if(!device) { [self append:@"Click Devices and choose the iPad before connecting."]; return; }
        [_receiver stop];
        _outbound.outputUID=_outputs.selectedItem.representedObject;
        _outbound.queueMilliseconds=[_queue.selectedItem.representedObject unsignedIntValue];
        [self append:@"Inspecting selected source's SDP. No local service publication, device-class change, or AVDTP channel request."];
        [_outbound inspectDevice:device];
    }
    [self tick:nil];
}
- (void)volume:(NSSlider *)sender { [_receiver setVolume:sender.doubleValue]; [_outbound setVolume:sender.doubleValue]; }
- (NSString *)currentStatistics { return _showOutbound ? [_outbound statistics] : [_receiver statistics]; }
- (void)tick:(NSTimer *)timer {
    (void)timer; BOOL running=_receiver.listening || _outbound.active;
    _start.title=@"Receiver disabled"; _start.enabled=NO;
    _sourceConnect.title=_outbound.active ? @"Stop inspection" : @"Inspect source";
    _sources.enabled=!_outbound.active; _sourcesRefresh.enabled=!_outbound.active;
    _outputs.enabled=!running; _refresh.enabled=!running; _queue.enabled=!running;
    _classCheckbox.enabled=NO; _experimentalCheckbox.enabled=NO;
    _stats.stringValue=[self currentStatistics];
}
- (void)settings:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Bluetooth"]];
}
- (void)saveLog:(id)sender {
    (void)sender;
    NSSavePanel *panel=[NSSavePanel savePanel]; panel.nameFieldStringValue=@"AudioMix-Bluetooth-Test.log";
    if([panel runModal]==NSModalResponseOK) {
        NSString *contents=[_transcript stringByAppendingFormat:@"\n%@\n",[self currentStatistics]];
        NSError *error=nil;
        if(![contents writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error])
            [self append:[NSString stringWithFormat:@"Could not save log: %@",error.localizedDescription]];
    }
}
- (void)copyLog:(id)sender {
    (void)sender;
    NSString *contents=[_transcript stringByAppendingFormat:@"\n%@\n",[self currentStatistics]];
    NSPasteboard *pasteboard=NSPasteboard.generalPasteboard;
    [pasteboard clearContents]; [pasteboard setString:contents forType:NSPasteboardTypeString];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification; [_timer invalidate]; [_receiver stop]; [_outbound stop];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app=NSApplication.sharedApplication;
        AppDelegate *delegate=[AppDelegate new]; app.delegate=delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular]; [app run];
    }
    return 0;
}
