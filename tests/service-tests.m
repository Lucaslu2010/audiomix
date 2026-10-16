#import <Foundation/Foundation.h>
#import "Service.h"
#include <assert.h>

static id normalizedValue(id value) {
    if([value isKindOfClass:IOBluetoothSDPUUID.class]) {
        IOBluetoothSDPUUID *uuid=value;
        return uuid.length==2 ? [uuid getUUIDWithLength:4] : uuid;
    }
    if([value isKindOfClass:NSDictionary.class] && value[@"DataElementType"]) {
        NSMutableDictionary *number=[value mutableCopy];
        number[@"DataElementSize"]=@4;
        return number;
    }
    if([value isKindOfClass:NSArray.class]) {
        NSMutableArray *result=[NSMutableArray array];
        for(id child in value) [result addObject:normalizedValue(child)];
        return result;
    }
    return value;
}
int main(void) {
    @autoreleasepool {
        NSDictionary *description=AMAudioSinkServiceDescription();
        IOBluetoothSDPServiceRecord *record=AMLocalServiceDescription(description);
        NSString *reason=nil;
        assert(AMValidateAudioSinkRecord(record,&reason));
        assert(reason==nil);
        assert([record matchesUUID16:0x110b]);
        NSDictionary *explicit=AMAudioSinkServiceDescriptionWithExplicitUUIDs();
        assert(!explicit[@"LocalAttributes"]);
        assert([explicit[@"0001 - ServiceClassIDList"][0] isKindOfClass:IOBluetoothSDPUUID.class]);
        IOBluetoothSDPServiceRecord *alternative=AMLocalServiceDescription(explicit);
        assert(AMValidateAudioSinkRecord(alternative,&reason));
        NSDictionary *compact=AMCompactAudioSinkServiceDescription(0x0019);
        IOBluetoothSDPServiceRecord *compactRecord=AMLocalServiceDescription(compact);
        assert(AMValidateAudioSinkRecord(compactRecord,&reason));
        assert(AMServiceRecordMatchesDescription(compactRecord,compact,&reason));
        NSMutableDictionary *normalized=[NSMutableDictionary dictionary];
        for(NSString *key in compact) normalized[key]=normalizedValue(compact[key]);
        IOBluetoothSDPServiceRecord *normalizedRecord=AMLocalServiceDescription(normalized);
        assert(AMServiceRecordMatchesDescription(normalizedRecord,compact,&reason));
        assert(AMServiceRecordHasRequestedIdentity(normalizedRecord,compact));
        // Semantic matching permits framework normalization, while constructing
        // a request still requires specification-compliant uint16 widths.
        assert(!AMValidateAudioSinkRecord(normalizedRecord,&reason));
        NSArray *candidates=AMAudioSinkPublicationCandidates();
        assert(candidates.count==3);
        for(NSDictionary *candidate in candidates) {
            NSDictionary *requested=candidate[@"record"];
            assert(AMValidateAudioSinkRecord(AMLocalServiceDescription(requested),&reason));
            assert(AMServiceRecordHasRequestedIdentity(AMLocalServiceDescription(requested),requested));
        }
        NSDictionary *experimental=AMExperimentalAudioSinkServiceDescription();
        IOBluetoothSDPServiceRecord *experimentalRecord=AMLocalServiceDescription(experimental);
        BluetoothL2CAPPSM experimentalPSM=0;
        assert([experimentalRecord getL2CAPPSM:&experimentalPSM]==kIOReturnSuccess);
        assert(experimentalPSM>=0x2001 && (experimentalPSM&0x0101)==1);
        assert(!AMValidateAudioSinkRecord(experimentalRecord,&reason));
        assert(AMValidateAudioSinkRecordForPSM(experimentalRecord,experimentalPSM,&reason));
        assert(!AMValidateAudioSinkRecordForPSM(experimentalRecord,0,&reason));
        assert(!AMValidateAudioSinkRecordForPSM(experimentalRecord,0x0101,&reason));
        assert(AMServiceRecordMatchesDescription(experimentalRecord,experimental,&reason));
        assert(!AMServiceRecordMatchesDescription(compactRecord,AMCompactAudioSinkServiceDescription(0x0019),&reason));
        assert([reason containsString:@"ServiceID"]);
        NSMutableDictionary *changed=[compact mutableCopy];
        changed[@"0004"]=@[
            @[[IOBluetoothSDPUUID uuid16:0x0100],@{@"DataElementType":@1,@"DataElementSize":@2,@"DataElementValue":@0}],
            @[[IOBluetoothSDPUUID uuid16:0x0019],@{@"DataElementType":@1,@"DataElementSize":@2,@"DataElementValue":@259}]];
        assert(!AMServiceRecordMatchesDescription(AMLocalServiceDescription(changed),compact,&reason));
        assert([reason containsString:@"0x0004"]);
        assert(!AMValidateAudioSinkRecord(AMLocalServiceDescription(changed),&reason));
        changed=[compact mutableCopy];
        [changed removeObjectForKey:@"0003"];
        assert(!AMServiceRecordHasRequestedIdentity(AMLocalServiceDescription(changed),compact));
        assert(!AMServiceRecordMatchesDescription(AMLocalServiceDescription(changed),compact,&reason));
        assert([reason containsString:@"ServiceID"]);
        NSArray *probes=AMServicePublicationProbes();
        assert(probes.count==6);
        NSMutableSet *identities=[NSMutableSet set];
        for(NSUInteger i=0;i<probes.count;i++) {
            NSDictionary *definition=probes[i][@"record"];
            assert(!definition[@"LocalAttributes"]);
            IOBluetoothSDPServiceRecord *control=AMLocalServiceDescription(definition);
            assert(control);
            assert(AMServiceRecordMatchesDescription(control,definition,&reason));
            NSString *identity=[[control getAttributeDataElement:3].getUUIDValue description];
            assert(identity && ![identities containsObject:identity]);
            [identities addObject:identity];
            if(i==0) {
                BluetoothRFCOMMChannelID channel=42;
                assert([control getRFCOMMChannelID:&channel]==kIOReturnSuccess);
                assert(channel==7);
            } else {
                BluetoothL2CAPPSM psm=42;
                assert([control getL2CAPPSM:&psm]==kIOReturnSuccess);
                if(i==1 || i==3) assert(psm>=0x2001 && (psm&0x0101)==1);
                else assert(psm==0x0019);
            }
            assert([control matchesUUID16:0x110b]==(i>=3));
            assert(AMValidateAudioSinkRecord(control,&reason)==(i==4 || i==5));
        }
        NSMutableDictionary *bad=[description mutableCopy];
        [bad removeObjectForKey:@"0006 - LanguageBaseAttributeIDList"];
        assert(!AMValidateAudioSinkRecord(AMLocalServiceDescription(bad),&reason));
        assert([reason containsString:@"language"]);
        bad=[description mutableCopy];
        bad[@"0001 - ServiceClassIDList"]=@[[IOBluetoothSDPUUID uuid16:0x110a]];
        assert(!AMValidateAudioSinkRecord(AMLocalServiceDescription(bad),&reason));
        assert([reason containsString:@"Audio Sink"]);
        bad=[description mutableCopy];
        bad[@"0004 - ProtocolDescriptorList"]=@[
            @[[IOBluetoothSDPUUID uuid16:0x0100],@25],
            @[[IOBluetoothSDPUUID uuid16:0x0019],@259]];
        assert(!AMValidateAudioSinkRecord(AMLocalServiceDescription(bad),&reason));
        assert([reason containsString:@"16-bit"]);
        assert(!AMValidateAudioSinkRecord(nil,&reason));
        puts("PASS: full/compact SDP, six explicit-port controls, unique identities, stale/missing identity rejection, zero-PSM rejection, profiles, malformed records");
        puts("No Bluetooth service was published; remote discovery still requires an iPad test.");
    }
    return 0;
}
