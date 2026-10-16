#import "Service.h"
#include <dlfcn.h>

static NSData *uuid16(uint16_t value) {
    uint8_t bytes[]={(uint8_t)(value>>8),(uint8_t)value};
    return [NSData dataWithBytes:bytes length:2];
}
static NSDictionary *uint16Element(uint16_t value) {
    return @{@"DataElementType":@1,@"DataElementSize":@2,@"DataElementValue":@(value)};
}
NSDictionary *AMAudioSinkServiceDescription(void) {
    return @{
        @"0001 - ServiceClassIDList":@[uuid16(0x110b)],
        @"0004 - ProtocolDescriptorList":@[
            @[uuid16(0x0100),uint16Element(0x0019)],
            @[uuid16(0x0019),uint16Element(0x0103)]],
        @"0005 - BrowseGroupList":@[uuid16(0x1002)],
        // English, UTF-8 (IANA MIBenum 106), primary-language attribute base.
        @"0006 - LanguageBaseAttributeIDList":@[
            uint16Element(0x656e),uint16Element(106),uint16Element(0x0100)],
        @"0009 - BluetoothProfileDescriptorList":@[@[uuid16(0x110d),uint16Element(0x0103)]],
        @"0100 - ServiceName":@"AudioMix Bluetooth Audio",
        @"0311 - SupportedFeatures":uint16Element(2),
        @"LocalAttributes":@{@"Persistent":@NO}
    };
}
static id explicitUUIDs(id value) {
    if([value isKindOfClass:NSData.class])
        return [IOBluetoothSDPUUID uuidWithData:value];
    if([value isKindOfClass:NSArray.class]) {
        NSMutableArray *result=[NSMutableArray array];
        for(id child in value) [result addObject:explicitUUIDs(child)];
        return result;
    }
    return value;
}
NSDictionary *AMAudioSinkServiceDescriptionWithExplicitUUIDs(void) {
    NSMutableDictionary *result=[AMAudioSinkServiceDescription() mutableCopy];
    // Both representations are documented. Match the explicit UUID form used
    // by Chromium's native Classic Bluetooth service registration as a second
    // path through Apple's dictionary conversion. Omitted LocalAttributes uses
    // Apple's documented transient default.
    [result removeObjectForKey:@"LocalAttributes"];
    for(NSString *key in result.allKeys) result[key]=explicitUUIDs(result[key]);
    return result;
}
static IOBluetoothSDPUUID *freshUUID(void) {
    uuid_t bytes;
    [NSUUID.UUID getUUIDBytes:bytes];
    return [IOBluetoothSDPUUID uuidWithBytes:bytes length:sizeof(bytes)];
}
static NSDictionary *canonicalDescription(NSDictionary *description) {
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(NSString *key in description) {
        if([key isEqualToString:@"LocalAttributes"]) continue;
        unsigned identifier=0;
        if(![[NSScanner scannerWithString:key] scanHexInt:&identifier]) return nil;
        result[[NSString stringWithFormat:@"%04x",identifier]]=description[key];
    }
    // SDP ServiceID identifies this specific service instance without changing
    // its standard Audio Sink service class. Detect stale/rewritten responses.
    result[@"0003"]=freshUUID();
    return result;
}
NSDictionary *AMCompactAudioSinkServiceDescription(uint16_t psm) {
    NSMutableDictionary *compact=[AMAudioSinkServiceDescriptionWithExplicitUUIDs() mutableCopy];
    [compact removeObjectsForKeys:@[@"0005 - BrowseGroupList",
        @"0006 - LanguageBaseAttributeIDList",@"0100 - ServiceName"]];
    compact[@"0004 - ProtocolDescriptorList"]=@[
        @[[IOBluetoothSDPUUID uuid16:0x0100],uint16Element(psm)],
        @[[IOBluetoothSDPUUID uuid16:0x0019],uint16Element(0x0103)]];
    return canonicalDescription(compact);
}
NSArray<NSDictionary *> *AMAudioSinkPublicationCandidates(void) {
    NSMutableDictionary *customFirst=[AMCompactAudioSinkServiceDescription(0x0019) mutableCopy];
    customFirst[@"0001"]=@[freshUUID(),[IOBluetoothSDPUUID uuid16:0x110b]];
    NSMutableDictionary *sinkFirst=[AMCompactAudioSinkServiceDescription(0x0019) mutableCopy];
    sinkFirst[@"0001"]=@[[IOBluetoothSDPUUID uuid16:0x110b],freshUUID()];
    return @[
        @{@"name":@"standard Audio Sink",@"record":AMCompactAudioSinkServiceDescription(0x0019)},
        @{@"name":@"custom class then Audio Sink",@"record":customFirst},
        @{@"name":@"Audio Sink then custom class",@"record":sinkFirst}];
}
static uint16_t freshDynamicPSM(void) {
    return (uint16_t)((0x2001+2*arc4random_uniform(0x5000))&~0x0100);
}
NSDictionary *AMExperimentalAudioSinkServiceDescription(void) {
    NSMutableDictionary *record=[AMCompactAudioSinkServiceDescription(freshDynamicPSM()) mutableCopy];
    record[@"0001"]=@[freshUUID(),[IOBluetoothSDPUUID uuid16:0x110b]];
    return record;
}
NSArray<NSDictionary *> *AMServicePublicationProbes(void) {
    NSDictionary *(^l2cap)(uint16_t)=^NSDictionary *(uint16_t psm) {
        return canonicalDescription(@{@"0001":@[freshUUID()],@"0004":@[
            @[[IOBluetoothSDPUUID uuid16:0x0100],uint16Element(psm)]]});
    };
    uint16_t dynamicPSM=freshDynamicPSM();
    NSMutableDictionary *customAudio=[AMCompactAudioSinkServiceDescription(dynamicPSM) mutableCopy];
    customAudio[@"0001"]=@[freshUUID(),[IOBluetoothSDPUUID uuid16:0x110b]];
    return @[
        @{@"name":@"custom RFCOMM / requested channel 7",@"record":canonicalDescription(@{
            @"0001":@[freshUUID()],@"0004":@[
                @[[IOBluetoothSDPUUID uuid16:0x0100]],
                @[[IOBluetoothSDPUUID uuid16:0x0003],
                    @{@"DataElementType":@1,@"DataElementSize":@1,@"DataElementValue":@7}]]})},
        @{@"name":@"custom L2CAP / fresh dynamic PSM",@"record":l2cap(dynamicPSM)},
        @{@"name":@"custom L2CAP / requested PSM 0x0019",@"record":l2cap(0x0019)},
        @{@"name":@"custom-first A2DP / fresh dynamic PSM (diagnostic only)",@"record":customAudio},
        @{@"name":@"compact A2DP / requested PSM 0x0019",@"record":AMCompactAudioSinkServiceDescription(0x0019)},
        @{@"name":@"named A2DP / requested PSM 0x0019",@"record":canonicalDescription(AMAudioSinkServiceDescriptionWithExplicitUUIDs())}
    ];
}
IOReturn AMLegacyPublicationProbe(NSDictionary *description,IOBluetoothSDPServiceRecord **record) {
    if(record) *record=nil;
    // Signature from Apple's archived Bluetooth guide and Chromium's pre-2016
    // implementation. No direct dependency on a removed SDK declaration.
    typedef IOReturn (*AddService)(CFDictionaryRef,IOBluetoothSDPServiceRecordRef *);
    AddService add=(AddService)dlsym(RTLD_DEFAULT,"IOBluetoothAddServiceDict");
    if(!add) return kIOReturnUnsupported;
    IOBluetoothSDPServiceRecordRef reference=NULL;
    IOReturn status=add((__bridge CFDictionaryRef)description,&reference);
    if(reference) {
        IOBluetoothSDPServiceRecord *object=[IOBluetoothSDPServiceRecord withSDPServiceRecordRef:reference];
        if(record) *record=object;
        CFRelease(reference);
    }
    return status;
}
IOBluetoothSDPServiceRecord *AMLocalServiceDescription(NSDictionary *description) {
    NSMutableDictionary *attributes=[NSMutableDictionary dictionary];
    for(NSString *key in description) {
        if([key isEqualToString:@"LocalAttributes"]) continue;
        unsigned identifier=0;
        if(![[NSScanner scannerWithString:key] scanHexInt:&identifier]) return nil;
        IOBluetoothSDPDataElement *element=[IOBluetoothSDPDataElement withElementValue:description[key]];
        if(!element) return nil;
        attributes[@(identifier)]=element;
    }
    return [IOBluetoothSDPServiceRecord withServiceDictionary:attributes device:nil];
}
static BOOL uuidIs(IOBluetoothSDPDataElement *element,uint16_t uuid) {
    return [[element getUUIDValue] isEqualToUUID:[IOBluetoothSDPUUID uuid16:uuid]];
}
static BOOL uint16Is(IOBluetoothSDPDataElement *element,uint16_t value) {
    return element && element.getTypeDescriptor==1 && element.getSize==2 &&
        element.getNumberValue.unsignedIntValue==value;
}
BOOL AMValidateAudioSinkRecord(IOBluetoothSDPServiceRecord *r,NSString **reason) {
    return AMValidateAudioSinkRecordForPSM(r,0x0019,reason);
}
BOOL AMValidateAudioSinkRecordForPSM(IOBluetoothSDPServiceRecord *r,uint16_t psm,NSString **reason) {
    NSString *error=nil;
    NSArray *classes=[[r getAttributeDataElement:1] getArrayValue];
    NSArray *protocols=[[r getAttributeDataElement:4] getArrayValue];
    NSArray *profileList=[[r getAttributeDataElement:9] getArrayValue];
    NSArray *language=[[r getAttributeDataElement:6] getArrayValue];
    if(psm!=0x0019 && (psm<0x1001 || (psm&0x0101)!=1)) error=@"Invalid experimental dynamic PSM";
    else if(!r) error=@"No SDP record";
    else if(![r matchesUUID16:0x110b] || classes.count<1 || classes.count>2 ||
        !(uuidIs(classes[0],0x110b) || (classes.count==2 && uuidIs(classes[1],0x110b)))) error=@"Audio Sink UUID 0x110B missing";
    else if(protocols.count!=2) error=@"Expected L2CAP and AVDTP protocol descriptors";
    else {
        NSArray *l2cap=[protocols[0] getArrayValue], *avdtp=[protocols[1] getArrayValue];
        if(l2cap.count!=2 || !uuidIs(l2cap[0],0x0100) || !uint16Is(l2cap[1],psm))
            error=[NSString stringWithFormat:@"L2CAP protocol descriptor does not specify 16-bit PSM 0x%04x",psm];
        else if(avdtp.count!=2 || !uuidIs(avdtp[0],0x0019) || !uint16Is(avdtp[1],0x0103))
            error=@"AVDTP 1.3 descriptor missing";
        else if(profileList.count!=1) error=@"A2DP profile descriptor missing";
        else {
            NSArray *profile=[profileList[0] getArrayValue];
            if(profile.count!=2 || !uuidIs(profile[0],0x110d) || !uint16Is(profile[1],0x0103))
                error=@"A2DP 1.3 profile descriptor missing";
        }
    }
    // Name/language metadata is optional in a compact playback record. When
    // supplied, validate it; transport, profile and feature checks remain strict.
    if(!error && [r getAttributeDataElement:6] && (language.count!=3 || !uint16Is(language[0],0x656e) ||
        !uint16Is(language[1],106) || !uint16Is(language[2],0x0100))) error=@"Service-name language descriptor missing";
    if(!error && [r getAttributeDataElement:0x0100] &&
        (![[r getAttributeDataElement:0x0100] getStringValue].length || language.count!=3)) error=@"Service name/language metadata invalid";
    if(!error && !uint16Is([r getAttributeDataElement:0x0311],2)) error=@"Speaker sink feature missing";
    if(reason) *reason=error;
    return error==nil;
}
static BOOL sameElement(IOBluetoothSDPDataElement *left,IOBluetoothSDPDataElement *right) {
    // bluetoothd's returned objects normalize UUID16→UUID32, uint16→uint32,
    // changing parent sequence sizes too. Compare semantic values recursively;
    // the request's wire widths are validated separately before publication.
    if(!left || !right || left.getTypeDescriptor!=right.getTypeDescriptor) return NO;
    if(left.getTypeDescriptor==3) return [[left getUUIDValue] isEqualToUUID:[right getUUIDValue]];
    if(left.getTypeDescriptor==6 || left.getTypeDescriptor==7) {
        NSArray *a=left.getArrayValue,*b=right.getArrayValue;
        if(a.count!=b.count) return NO;
        for(NSUInteger i=0;i<a.count;i++) if(!sameElement(a[i],b[i])) return NO;
        return YES;
    }
    return [left.getValue isEqual:right.getValue];
}
BOOL AMServiceRecordHasRequestedIdentity(IOBluetoothSDPServiceRecord *record,NSDictionary *description) {
    IOBluetoothSDPServiceRecord *expected=AMLocalServiceDescription(description);
    return sameElement([expected getAttributeDataElement:3],[record getAttributeDataElement:3]);
}
BOOL AMServiceRecordMatchesDescription(IOBluetoothSDPServiceRecord *record,NSDictionary *description,NSString **reason) {
    IOBluetoothSDPServiceRecord *expected=AMLocalServiceDescription(description);
    if(!record || !expected) { if(reason) *reason=@"Missing/invalid service record"; return NO; }
    // Check identity before other attributes to make stale-record results clear.
    if([expected getAttributeDataElement:3] && !sameElement([expected getAttributeDataElement:3],[record getAttributeDataElement:3])) {
        if(reason) *reason=@"ServiceID (0x0003) differs or is missing: returned record identity not verified";
        return NO;
    }
    for(NSNumber *key in expected.attributes) {
        if(!sameElement([expected getAttributeDataElement:key.unsignedShortValue],[record getAttributeDataElement:key.unsignedShortValue])) {
            if(reason) *reason=[NSString stringWithFormat:@"Attribute 0x%04x differs or is missing",key.unsignedShortValue];
            return NO;
        }
    }
    if(reason) *reason=nil;
    return YES;
}
