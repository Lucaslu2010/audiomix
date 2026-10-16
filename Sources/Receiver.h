#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#import "AVDTP.h"
#import "AudioOutput.h"

typedef void (^AMLogHandler)(NSString *message);
@interface AMReceiver : NSObject <CBCentralManagerDelegate, IOBluetoothL2CAPChannelDelegate>
@property(nonatomic, copy) AMLogHandler logger;
@property(nonatomic, copy) NSString *outputUID;
@property(nonatomic) unsigned queueMilliseconds;
@property(nonatomic) BOOL useAudioDeviceClass;
@property(nonatomic) BOOL allowExperimentalTransport;
@property(nonatomic, readonly) BOOL listening;
- (void)start;
- (void)stop;
- (void)setVolume:(double)volume;
- (NSString *)statistics;
@end
