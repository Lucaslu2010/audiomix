#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>

NSDictionary *AMAudioSinkServiceDescription(void);
NSDictionary *AMAudioSinkServiceDescriptionWithExplicitUUIDs(void);
NSDictionary *AMCompactAudioSinkServiceDescription(uint16_t psm);
NSArray<NSDictionary *> *AMAudioSinkPublicationCandidates(void);
NSDictionary *AMExperimentalAudioSinkServiceDescription(void);
// Ordered transient controls. These are diagnostics, never playback services.
NSArray<NSDictionary *> *AMServicePublicationProbes(void);
IOBluetoothSDPServiceRecord *AMLocalServiceDescription(NSDictionary *description);
BOOL AMValidateAudioSinkRecord(IOBluetoothSDPServiceRecord *record, NSString **reason);
BOOL AMValidateAudioSinkRecordForPSM(IOBluetoothSDPServiceRecord *record, uint16_t psm, NSString **reason);
BOOL AMServiceRecordMatchesDescription(IOBluetoothSDPServiceRecord *record,
    NSDictionary *description, NSString **reason);
BOOL AMServiceRecordHasRequestedIdentity(IOBluetoothSDPServiceRecord *record, NSDictionary *description);
// Optional legacy public API, absent from current SDK declarations. Returns
// unsupported if it is not exported; never uses guessed private symbols.
IOReturn AMLegacyPublicationProbe(NSDictionary *description, IOBluetoothSDPServiceRecord **record);
