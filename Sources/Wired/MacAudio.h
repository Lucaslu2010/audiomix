#import <Foundation/Foundation.h>
#import "WiredCapture.h"
@interface AWMacAudio : NSObject
@property(nonatomic,copy) AWLogHandler logger;
@property(nonatomic,readonly) BOOL active;
@property(nonatomic,readonly,copy) NSString *statusText;
- (void)startOutputUID:(NSString *)uid;
- (void)setVolume:(float)volume;
- (void)stop;
- (void)checkHealth;
- (void)shutdownAndWait;
@end
