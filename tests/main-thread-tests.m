// Regression for the sampled connection-callback → AppKit deadlock. No windows,
// Bluetooth connections, or device queries are created by this test.
#import <Foundation/Foundation.h>
#import "Receiver.h"
#import "SourceInitiator.h"
#import "Service.h"
@interface AMSourceInitiator (InspectionRegression)
- (void)querySource;
@end
@interface NSObject (SDPCompletion)
- (void)sdpQueryComplete:(IOBluetoothDevice *)device status:(IOReturn)status;
@end
// NSObject mock deliberately avoids constructing a real Bluetooth device.
@interface TestSourceDevice : NSObject
@property(nonatomic,strong) id target;
@property(nonatomic,strong) IOBluetoothSDPServiceRecord *record;
@end
@implementation TestSourceDevice
- (IOReturn)performSDPQuery:(id)target {
    self.target=target; return kIOReturnSuccess;
}
- (NSDate *)getLastServicesUpdate { return NSDate.date; }
- (IOBluetoothSDPServiceRecord *)getServiceRecordForUUID:(IOBluetoothSDPUUID *)uuid { (void)uuid; return self.record; }
- (IOReturn)openL2CAPChannelAsync:(IOBluetoothL2CAPChannel **)channel withPSM:(BluetoothL2CAPPSM)psm delegate:(id)delegate {
    (void)channel; (void)psm; (void)delegate;
    NSCAssert(NO,@"Inspection must never request an audio channel"); return kIOReturnError;
}
@end
@interface AMReceiver (ThreadRegression)
- (void)basebandConnected:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device;
@end
@interface NSObject (AppLogRegression)
- (void)append:(NSString *)message;
@end
@interface TestLogView : NSObject
@property(nonatomic,copy) NSString *string;
@property(nonatomic) BOOL updated;
- (void)scrollRangeToVisible:(NSRange)range;
@end
@implementation TestLogView
- (void)setString:(NSString *)value { NSCAssert(NSThread.isMainThread,@"UI write occurred off main thread"); _string=[value copy]; }
- (void)scrollRangeToVisible:(NSRange)range { (void)range; NSCAssert(NSThread.isMainThread,@"UI scroll occurred off main thread"); self.updated=YES; }
@end
static void pumpUntil(BOOL (^done)(void)) {
    CFAbsoluteTime end=CFAbsoluteTimeGetCurrent()+3;
    while(!done() && CFAbsoluteTimeGetCurrent()<end) CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.01,true);
    NSCAssert(done(),@"Main-thread delivery timed out");
}
int main(void) {
    @autoreleasepool {
        NSObject *delegate=[NSClassFromString(@"AppDelegate") new];
        NSCAssert(delegate,@"Application delegate missing");
        TestLogView *view=[TestLogView new];
        [delegate setValue:view forKey:@"log"];
        NSMutableString *transcript=[NSMutableString string];
        [delegate setValue:transcript forKey:@"transcript"];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{ [delegate append:@"background log regression"]; });
        pumpUntil(^BOOL { return view.updated; });
        NSCAssert([transcript containsString:@"background log regression"],@"Lost log message");
        AMReceiver *receiver=[AMReceiver new];
        [receiver setValue:@YES forKey:@"listening"];
        __block BOOL received=NO;
        receiver.logger=^(NSString *message) {
            NSCAssert(NSThread.isMainThread,@"Bluetooth callback state/logging occurred off main thread");
            NSCAssert([message containsString:@"Bluetooth link event"],@"Unexpected callback log"); received=YES;
        };
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{ [receiver basebandConnected:nil device:nil]; });
        pumpUntil(^BOOL { return received; });
        NSCAssert([[receiver valueForKey:@"connectionEvents"] unsignedIntValue]==1,@"Lost or duplicated event");
        [receiver setValue:@NO forKey:@"listening"];
        puts("PASS: background connection notification and app logging marshal to main without invoking UI off-thread");

        AMReceiver *disabled=[AMReceiver new];
        [disabled start];
        NSCAssert(!disabled.listening && [[disabled statistics] containsString:@"disabled"],@"Retired receiver must not start");
        NSCAssert(![disabled valueForKey:@"permissionManager"] && ![disabled valueForKey:@"record"],@"Retired receiver touched Bluetooth");

        NSMutableDictionary *description=[AMCompactAudioSinkServiceDescription(0x0019) mutableCopy];
        description[@"0001"]=@[[IOBluetoothSDPUUID uuid16:0x110a]];
        TestSourceDevice *device=[TestSourceDevice new]; device.record=AMLocalServiceDescription(description);
        AMSourceInitiator *inspection=[AMSourceInitiator new];
        [inspection setValue:device forKey:@"device"];
        [inspection setValue:@YES forKey:@"active"];
        [inspection setValue:@YES forKey:@"inspectOnly"];
        [inspection querySource];
        id oldTarget=device.target;
        [oldTarget sdpQueryComplete:(IOBluetoothDevice *)device status:0];
        pumpUntil(^BOOL { return !inspection.active; });
        NSCAssert([[inspection statistics] containsString:@"inspection complete"],@"Inspection did not report source");
        // A callback from a stopped attempt must not terminate a later attempt.
        [inspection setValue:device forKey:@"device"]; [inspection setValue:@YES forKey:@"active"];
        [inspection querySource];
        [oldTarget sdpQueryComplete:(IOBluetoothDevice *)device status:kIOReturnError];
        CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.03,true);
        NSCAssert(inspection.active,@"Stale SDP callback affected the new attempt");
        [inspection l2capChannelOpenComplete:(IOBluetoothL2CAPChannel *)[NSObject new] status:kIOReturnError];
        NSCAssert(inspection.active,@"Unowned channel completion affected inspection");
        device.record=nil;
        [device.target sdpQueryComplete:(IOBluetoothDevice *)device status:0];
        pumpUntil(^BOOL { return !inspection.active; });
        NSCAssert([[inspection statistics] containsString:@"without Audio Source"],@"Missing source not rejected");
        puts("PASS: retired listener stays inactive; source inspection requests no audio channels; stale query/channel callbacks ignored");
    }
    return 0;
}
