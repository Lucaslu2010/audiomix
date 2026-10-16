#import "DeviceVolumePanel.h"
@interface AWDeviceVolumeRow : NSView
@property(nonatomic,copy) NSString *sourceID;
@property(nonatomic,strong) NSTextField *nameLabel,*detailLabel,*percentage;
@property(nonatomic,strong) NSSlider *slider;
@property(nonatomic,strong) NSButton *muteButton,*toggleButton;
@end
@implementation AWDeviceVolumeRow
@end
@implementation AWDeviceVolumePanel {
    NSTextField *_outputLabel;
    NSScrollView *_scroll;
    NSView *_document;
    NSArray<NSString *> *_sourceIDs;
    NSMutableDictionary<NSString *,AWDeviceVolumeRow *> *_rows;
}
static NSTextField *label(NSString *text,NSRect frame) {
    NSTextField *field=[NSTextField labelWithString:text]; field.frame=frame; return field;
}
- (instancetype)init {
    NSPanel *panel=[[NSPanel alloc] initWithContentRect:NSMakeRect(0,0,700,410)
        styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    if((self=[super initWithWindow:panel])) {
        panel.title=@"Device volumes"; panel.releasedWhenClosed=NO; panel.hidesOnDeactivate=NO;
        panel.minSize=NSMakeSize(620,300); [panel center];
        NSView *content=panel.contentView;
        NSTextField *title=label(@"Device volumes",NSMakeRect(22,365,500,26));
        title.font=[NSFont boldSystemFontOfSize:20]; title.autoresizingMask=NSViewMinYMargin;
        [content addSubview:title];
        _outputLabel=label(@"Output",NSMakeRect(22,336,650,22));
        _outputLabel.textColor=NSColor.secondaryLabelColor;
        _outputLabel.autoresizingMask=NSViewMinYMargin|NSViewWidthSizable; [content addSubview:_outputLabel];
        NSButton *refresh=[NSButton buttonWithTitle:@"Refresh devices" target:self action:@selector(refresh:)];
        refresh.frame=NSMakeRect(530,363,150,30); refresh.autoresizingMask=NSViewMinXMargin|NSViewMinYMargin;
        [content addSubview:refresh];
        _scroll=[[NSScrollView alloc] initWithFrame:NSMakeRect(18,48,664,278)];
        _scroll.hasVerticalScroller=YES; _scroll.drawsBackground=NO;
        _scroll.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
        _document=[[NSView alloc] initWithFrame:NSMakeRect(0,0,644,278)];
        _document.autoresizingMask=NSViewWidthSizable; _scroll.documentView=_document; [content addSubview:_scroll];
        NSTextField *foot=label(@"Volume changes apply only to that source. Closing this panel keeps audio playing.",NSMakeRect(22,12,650,26));
        foot.font=[NSFont systemFontOfSize:11]; foot.textColor=NSColor.secondaryLabelColor;
        foot.autoresizingMask=NSViewWidthSizable; [content addSubview:foot];
        _rows=[NSMutableDictionary dictionary];
    }
    return self;
}
- (void)refresh:(id)sender { (void)sender; if(self.refreshSources) self.refreshSources(); }
- (void)volume:(NSSlider *)slider {
    AWDeviceVolumeRow *row=(AWDeviceVolumeRow *)slider.superview;
    row.percentage.stringValue=[NSString stringWithFormat:@"%.0f%%",slider.doubleValue*100];
    if(self.volumeChanged) self.volumeChanged(row.sourceID,(float)slider.doubleValue);
}
- (void)mute:(NSButton *)button {
    AWDeviceVolumeRow *row=(AWDeviceVolumeRow *)button.superview;
    if(self.muteChanged) self.muteChanged(row.sourceID,button.state==NSControlStateValueOn);
}
- (void)toggle:(NSButton *)button {
    AWDeviceVolumeRow *row=(AWDeviceVolumeRow *)button.superview;
    if(self.toggleSource) self.toggleSource(row.sourceID);
}
- (AWDeviceVolumeRow *)createRow:(NSString *)sourceID {
    AWDeviceVolumeRow *row=[[AWDeviceVolumeRow alloc] initWithFrame:NSMakeRect(0,0,644,112)];
    row.sourceID=sourceID; row.autoresizingMask=NSViewWidthSizable;
    row.nameLabel=label(@"",NSMakeRect(10,80,480,24)); row.nameLabel.font=[NSFont boldSystemFontOfSize:14];
    row.nameLabel.lineBreakMode=NSLineBreakByTruncatingTail; row.nameLabel.autoresizingMask=NSViewWidthSizable;
    [row addSubview:row.nameLabel];
    row.detailLabel=label(@"",NSMakeRect(10,56,620,21)); row.detailLabel.font=[NSFont systemFontOfSize:11];
    row.detailLabel.textColor=NSColor.secondaryLabelColor; row.detailLabel.lineBreakMode=NSLineBreakByTruncatingTail;
    row.detailLabel.autoresizingMask=NSViewWidthSizable; [row addSubview:row.detailLabel];
    row.slider=[NSSlider sliderWithValue:0 minValue:0 maxValue:1 target:self action:@selector(volume:)];
    row.slider.continuous=YES; row.slider.frame=NSMakeRect(10,20,390,25);
    row.slider.autoresizingMask=NSViewWidthSizable; [row addSubview:row.slider];
    row.percentage=label(@"",NSMakeRect(405,22,60,22)); row.percentage.alignment=NSTextAlignmentRight;
    row.percentage.font=[NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    row.percentage.autoresizingMask=NSViewMinXMargin; [row addSubview:row.percentage];
    row.muteButton=[NSButton checkboxWithTitle:@"Mute" target:self action:@selector(mute:)];
    row.muteButton.frame=NSMakeRect(480,19,75,27); row.muteButton.autoresizingMask=NSViewMinXMargin;
    [row addSubview:row.muteButton];
    row.toggleButton=[NSButton buttonWithTitle:@"Play" target:self action:@selector(toggle:)];
    row.toggleButton.frame=NSMakeRect(553,77,83,30); row.toggleButton.autoresizingMask=NSViewMinXMargin;
    [row addSubview:row.toggleButton];
    NSBox *line=[[NSBox alloc] initWithFrame:NSMakeRect(10,0,624,1)]; line.boxType=NSBoxSeparator;
    line.autoresizingMask=NSViewWidthSizable; [row addSubview:line];
    return row;
}
- (void)updateSources:(NSArray<NSDictionary *> *)sources outputName:(NSString *)outputName {
    _outputLabel.stringValue=[@"Output: " stringByAppendingString:outputName ?: @"System default"];
    NSArray *ids=[sources valueForKey:@"id"];
    if(![_sourceIDs isEqual:ids]) {
        _sourceIDs=[ids copy];
        for(NSView *view in _document.subviews.copy) [view removeFromSuperview];
        [_rows removeAllObjects];
        for(NSUInteger i=0;i<sources.count;i++) {
            AWDeviceVolumeRow *row=[self createRow:ids[i]];
            _rows[ids[i]]=row; [_document addSubview:row];
        }
    }
    CGFloat height=MAX(_scroll.contentView.bounds.size.height,sources.count*112.);
    BOOL layoutChanged=_document.frame.size.height!=height || _document.frame.size.width!=_scroll.contentView.bounds.size.width;
    _document.frame=NSMakeRect(0,0,_scroll.contentView.bounds.size.width,height);
    for(NSUInteger i=0;i<ids.count;i++) _rows[ids[i]].frame=NSMakeRect(0,height-(i+1)*112.,_document.bounds.size.width,112);
    if(layoutChanged) [_document scrollPoint:NSMakePoint(0,height)];
    for(NSDictionary *source in sources) {
        AWDeviceVolumeRow *row=_rows[source[@"id"]];
        row.nameLabel.stringValue=source[@"name"]; row.detailLabel.stringValue=source[@"detail"];
        row.detailLabel.toolTip=source[@"detail"]; row.nameLabel.toolTip=source[@"name"];
        row.slider.doubleValue=[source[@"gain"] doubleValue];
        row.slider.accessibilityLabel=[source[@"name"] stringByAppendingString:@" volume"];
        row.percentage.stringValue=[NSString stringWithFormat:@"%.0f%%",row.slider.doubleValue*100];
        row.muteButton.state=[source[@"muted"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
        row.muteButton.accessibilityLabel=[source[@"name"] stringByAppendingString:@" mute"];
        row.toggleButton.title=source[@"button"]; row.toggleButton.enabled=[source[@"canToggle"] boolValue];
        row.toggleButton.accessibilityLabel=[NSString stringWithFormat:@"%@ %@",source[@"button"],source[@"name"]];
    }
}
@end
