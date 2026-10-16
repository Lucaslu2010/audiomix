#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "AudioPipe.h"
typedef void (^AWLogHandler)(NSString *message);
OSStatus AWEnableWiredCaptureDiscovery(void);
NSArray<NSDictionary *> *AWCaptureSources(BOOL includeOtherInputs);
NSArray<NSDictionary *> *AWOutputDevices(void);
@interface AWWiredCapture : NSObject <AVCaptureAudioDataOutputSampleBufferDelegate,AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic,copy) AWLogHandler logger;
@property(nonatomic,readonly) BOOL active;
@property(nonatomic,readonly,copy) NSString *statusText;
- (void)startDevice:(AVCaptureDevice *)device outputUID:(NSString *)outputUID
    queueMilliseconds:(unsigned)milliseconds compatibilityVideo:(BOOL)compatibilityVideo;
- (void)stop;
- (void)testOutputUID:(NSString *)outputUID;
- (void)shutdownAndWait;
- (void)setVolume:(float)volume;
- (NSString *)statistics;
@end
