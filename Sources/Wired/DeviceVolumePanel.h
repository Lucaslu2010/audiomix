#import <AppKit/AppKit.h>
@interface AWDeviceVolumePanel : NSWindowController
@property(nonatomic,copy) void (^volumeChanged)(NSString *sourceID,float gain);
@property(nonatomic,copy) void (^muteChanged)(NSString *sourceID,BOOL muted);
@property(nonatomic,copy) void (^toggleSource)(NSString *sourceID);
@property(nonatomic,copy) void (^refreshSources)(void);
- (void)updateSources:(NSArray<NSDictionary *> *)sources outputName:(NSString *)outputName;
@end
