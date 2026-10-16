#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#include <signal.h>
#include <errno.h>

static volatile sig_atomic_t interrupted = 0;
static void stopProbe(int value) { (void)value; interrupted = 1; }

static NSData *uuid16(uint16_t value) {
    uint8_t bytes[] = { (uint8_t)(value >> 8), (uint8_t)value };
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}

static NSDictionary *uint16Element(uint16_t value) {
    return @{ @"DataElementType": @1, @"DataElementSize": @2,
              @"DataElementValue": @(value) };
}

static NSDictionary *sinkDescription(void) {
    return @{
        @"0001 - ServiceClassIDList": @[uuid16(0x110b)],
        @"0004 - ProtocolDescriptorList": @[
            @[uuid16(0x0100), uint16Element(0x0019)],
            @[uuid16(0x0019), uint16Element(0x0103)]
        ],
        @"0005 - BrowseGroupList": @[uuid16(0x1002)],
        @"0009 - BluetoothProfileDescriptorList": @[
            @[uuid16(0x110d), uint16Element(0x0103)]
        ],
        @"0100 - ServiceName": @"AudioMix Bluetooth Probe",
        @"0311 - SupportedFeatures": uint16Element(0x0001),
        @"LocalAttributes": @{ @"Persistent": @NO }
    };
}

@interface Probe : NSObject <IOBluetoothL2CAPChannelDelegate>
@property(nonatomic, strong) IOBluetoothSDPServiceRecord *record;
@property(nonatomic, strong) IOBluetoothUserNotification *notification;
@property(nonatomic, strong) NSMutableArray<IOBluetoothL2CAPChannel *> *channels;
@property(nonatomic) NSUInteger receivedChannels;
@property(nonatomic) NSUInteger receivedPackets;
- (int)start;
- (void)stop;
@end

@implementation Probe
- (int)start {
    self.channels = [NSMutableArray array];
    self.record = [IOBluetoothSDPServiceRecord publishedServiceRecordWithDictionary:sinkDescription()];
    if (!self.record) {
        fprintf(stderr, "FAIL: could not publish service; check Bluetooth availability and permission.\n");
        return 1;
    }
    BluetoothL2CAPPSM actualPSM = 0;
    IOReturn result = [self.record getL2CAPPSM:&actualPSM];
    if (result != kIOReturnSuccess) {
        fprintf(stderr, "FAIL: getL2CAPPSM returned 0x%08x\n", (unsigned)result);
        return 1;
    }
    fprintf(stderr, "Published service; requested PSM=0x0019, actual PSM=0x%04x\n", actualPSM);
    if (actualPSM != 0x0019) {
        fprintf(stderr, "INCONCLUSIVE: standard AVDTP PSM unavailable; refusing a misleading alternate-port test.\n");
        return 3;
    }
    self.notification = [IOBluetoothL2CAPChannel
        registerForChannelOpenNotifications:self selector:@selector(channelOpened:channel:)
        withPSM:actualPSM direction:kIOBluetoothUserNotificationChannelDirectionIncoming];
    if (!self.notification) {
        fprintf(stderr, "FAIL: incoming channel registration returned nil.\n");
        return 1;
    }
    fprintf(stderr, "Listening for incoming attempts. No audio negotiation or playback is implemented.\n");
    return 0;
}

- (void)channelOpened:(IOBluetoothUserNotification *)notification
              channel:(IOBluetoothL2CAPChannel *)channel {
    (void)notification;
    self.receivedChannels += 1;
    [self.channels addObject:channel];
    IOReturn result = [channel setDelegate:self];
    fprintf(stderr, "Incoming channel on PSM 0x%04x; setDelegate=0x%08x\n",
            channel.PSM, (unsigned)result);
    if (result != kIOReturnSuccess) {
        [channel closeChannel];
        [self.channels removeObject:channel];
    }
}

- (void)l2capChannelData:(IOBluetoothL2CAPChannel *)channel data:(void *)data length:(size_t)length {
    (void)channel; (void)data;
    self.receivedPackets += 1;
    if (self.receivedPackets <= 20) {
        fprintf(stderr, "Received %zu bytes (not decoded or answered).\n", length);
    }
}

- (void)l2capChannelClosed:(IOBluetoothL2CAPChannel *)channel {
    [self.channels removeObject:channel];
    fprintf(stderr, "Incoming channel closed.\n");
}

- (void)stop {
    [self.notification unregister];
    self.notification = nil;
    for (IOBluetoothL2CAPChannel *channel in [self.channels copy]) {
        [channel setDelegate:nil];
        [channel closeChannel];
    }
    [self.channels removeAllObjects];
    if (self.record) {
        IOReturn result = [self.record removeServiceRecord];
        fprintf(stderr, "Service removal=0x%08x\n", (unsigned)result);
        self.record = nil;
    }
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--validate") == 0) {
            NSMutableDictionary *attributes = [NSMutableDictionary dictionary];
            NSDictionary *description = sinkDescription();
            for (NSString *key in description) {
                if ([key isEqualToString:@"LocalAttributes"]) continue;
                unsigned identifier = 0;
                [[NSScanner scannerWithString:key] scanHexInt:&identifier];
                IOBluetoothSDPDataElement *element =
                    [IOBluetoothSDPDataElement withElementValue:description[key]];
                if (!element) {
                    fprintf(stderr, "FAIL: invalid element %s\n", key.UTF8String);
                    return 1;
                }
                attributes[@(identifier)] = element;
            }
            IOBluetoothSDPServiceRecord *record =
                [IOBluetoothSDPServiceRecord withServiceDictionary:attributes device:nil];
            BluetoothL2CAPPSM psm = 0;
            if (!record || [record getL2CAPPSM:&psm] != kIOReturnSuccess || psm != 0x0019 ||
                ![record matchesUUID16:0x110b]) {
                fprintf(stderr, "FAIL: SDK could not decode the intended Audio Sink descriptor.\n");
                return 1;
            }
            puts("PASS: local SDP descriptor decodes as Audio Sink, PSM 0x0019.");
            puts("No service published; hardware reception and playback remain untested.");
            return 0;
        }
        if (argc != 3 || strcmp(argv[1], "--listen") != 0) {
            fprintf(stderr, "Usage: AudioMixProbe --validate | --listen SECONDS (1–300)\n");
            return 2;
        }
        char *end = NULL;
        errno = 0;
        long seconds = strtol(argv[2], &end, 10);
        if (errno || end == argv[2] || *end != '\0' || seconds < 1 || seconds > 300) {
            fprintf(stderr, "Duration must be an integer from 1 to 300 seconds.\n");
            return 2;
        }
        signal(SIGINT, stopProbe);
        signal(SIGTERM, stopProbe);
        Probe *probe = [Probe new];
        int result = [probe start];
        if (result == 0) {
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
            while (!interrupted && [deadline timeIntervalSinceNow] > 0) {
                @autoreleasepool {
                    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
                }
            }
            fprintf(stderr, "Probe ended: %lu channel(s), %lu packet(s). This is not an audio pass.\n",
                    (unsigned long)probe.receivedChannels, (unsigned long)probe.receivedPackets);
        }
        [probe stop];
        return result;
    }
}
