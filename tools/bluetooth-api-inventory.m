// Read-only runtime metadata inspection. No Bluetooth connections, settings,
// private selectors, or device commands are invoked by this program.
#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <IOBluetooth/IOBluetooth.h>
#import <objc/runtime.h>

static BOOL contains(NSString *value,NSString *term) {
    return [value rangeOfString:term options:NSCaseInsensitiveSearch].location!=NSNotFound;
}
int main(void) {
    @autoreleasepool {
        // Reference public classes so the frameworks are linked and loaded.
        printf("Loaded public frameworks: %s, %s\n",class_getName(CBManager.class),class_getName(IOBluetoothDevice.class));
        unsigned count=0;
        Class *classes=objc_copyClassList(&count);
        NSMutableArray<NSString *> *lines=[NSMutableArray array];
        for(unsigned i=0;i<count;i++) {
            Class cls=classes[i];
            NSString *name=NSStringFromClass(cls);
            if(!([name hasPrefix:@"CB"] || [name hasPrefix:@"BT"] || [name hasPrefix:@"IOBluetooth"])) continue;
            for(unsigned kind=0;kind<2;kind++) {
                unsigned methodCount=0;
                Method *methods=class_copyMethodList(kind ? object_getClass(cls) : cls,&methodCount);
                for(unsigned j=0;j<methodCount;j++) {
                    NSString *selector=NSStringFromSelector(method_getName(methods[j]));
                    BOOL relevant=NO;
                    for(NSString *term in @[@"audio",@"a2dp",@"avdtp",@"psm",@"sink",@"classic",@"l2cap",@"service"])
                        if(contains(selector,term) || contains(name,term)) { relevant=YES; break; }
                    if(relevant) [lines addObject:[NSString stringWithFormat:@"%@ %c %@",name,kind ? '+' : '-',selector]];
                }
                free(methods);
            }
        }
        free(classes);
        [lines sortUsingSelector:@selector(compare:)];
        for(NSString *line in lines) puts(line.UTF8String);
    }
    return 0;
}
