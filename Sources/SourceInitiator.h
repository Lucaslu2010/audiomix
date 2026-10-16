#import "Receiver.h"
@interface AMSourceInitiator : NSObject <CBCentralManagerDelegate, IOBluetoothL2CAPChannelDelegate>
@property(nonatomic,copy) AMLogHandler logger;
@property(nonatomic,copy) NSString *outputUID;
@property(nonatomic) unsigned queueMilliseconds;
@property(nonatomic,readonly) BOOL active;
- (void)requestBluetoothAccess;
- (void)startWithDevice:(IOBluetoothDevice *)device;
- (void)inspectDevice:(IOBluetoothDevice *)device;
- (void)stop;
- (void)setVolume:(double)volume;
- (NSString *)statistics;
@end
