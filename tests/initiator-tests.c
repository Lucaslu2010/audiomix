#include "Initiator.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static AMInitiatorAction accept(AMInitiator *s,const uint8_t *payload,size_t length) {
    uint8_t packet[512]={(uint8_t)((s->label<<4)|2),s->signal};
    assert(length<=sizeof(packet)-2); if(length) memcpy(packet+2,payload,length);
    return am_initiator_response(s,packet,length+2);
}
static void lifecycle(void) {
    AMInitiator s;
    AMInitiatorAction action=am_initiator_begin(&s);
    assert(action.kind==AM_INT_SEND && action.bytes[1]==1 && action.length==2);
    uint8_t endpoints[]={4,8, 8,0, 14,0}; // sink, free source SEID2, occupied source
    action=accept(&s,endpoints,sizeof(endpoints));
    assert(action.kind==AM_INT_SEND && action.bytes[1]==2 && action.bytes[2]==8 && s.count==1);
    uint8_t caps[]={1,0,7,6,0,0,0xff,0xff,2,250};
    action=accept(&s,caps,sizeof(caps));
    assert(action.kind==AM_INT_SEND && action.bytes[1]==3 && action.length==14);
    assert(action.bytes[2]==8 && action.bytes[3]==4);
    assert(action.bytes[10]==0x11 && action.bytes[11]==0x15 && action.bytes[12]==2 && action.bytes[13]==53);
    uint8_t stale[]={0x02,3};
    assert(am_initiator_response(&s,stale,sizeof(stale)).kind==AM_INT_NONE);
    action=accept(&s,NULL,0);
    assert(action.bytes[1]==6 && s.session.state==AM_CONFIGURED);
    action=accept(&s,NULL,0);
    assert(action.kind==AM_INT_OPEN_MEDIA && s.session.state==AM_OPEN);
    action=am_initiator_media_connected(&s);
    assert(action.bytes[1]==7 && action.bytes[2]==8 && s.session.mediaConnected);
    action=accept(&s,NULL,0);
    assert(action.kind==AM_INT_STARTED && s.phase==AM_INT_STREAMING && s.session.state==AM_STREAMING);
}
static void negotiation_failures(void) {
    AMInitiator s; am_initiator_begin(&s);
    uint8_t endpoints[]={4,0,8,0};
    accept(&s,endpoints,sizeof(endpoints));
    uint8_t bad[]={1,0,7,6,0,0,0x3f,0xff,54,100};
    AMInitiatorAction a=accept(&s,bad,sizeof(bad));
    assert(a.bytes[1]==2 && a.bytes[2]==8 && s.index==1);
    uint8_t mono[]={1,0,7,6,0,0,0x28,0x8a,2,31};
    a=accept(&s,mono,sizeof(mono));
    assert(a.bytes[1]==3 && a.bytes[10]==0x28 && a.bytes[11]==0x8a && a.bytes[13]==31);
    uint8_t rejection[]={(uint8_t)((s.label<<4)|3),3,7,0x29};
    assert(am_initiator_response(&s,rejection,sizeof(rejection)).kind==AM_INT_ERROR);
    am_initiator_begin(&s);
    uint8_t malformed[]={4};
    assert(accept(&s,malformed,sizeof(malformed)).kind==AM_INT_ERROR);
    am_initiator_begin(&s);
    assert(accept(&s,NULL,0).kind==AM_INT_ERROR);
    am_initiator_begin(&s); accept(&s,endpoints,2);
    uint8_t truncated[]={1,0,7,6,0,0};
    assert(accept(&s,truncated,sizeof(truncated)).kind==AM_INT_ERROR);
    am_initiator_begin(&s);
    assert(am_initiator_media_connected(&s).kind==AM_INT_ERROR);
}
static void response_fragments(void) {
    AMAVDTPFragments fragments={0}; uint8_t out[64];
    uint8_t first[]={0x26,2,1,4},last[]={0x2e,0};
    assert(am_avdtp_reassemble_message(&fragments,first,sizeof(first),out,sizeof(out))==0);
    assert(am_avdtp_reassemble_message(&fragments,last,sizeof(last),out,sizeof(out))==4);
    assert(out[0]==0x22 && out[1]==1 && out[2]==4 && out[3]==0);
    assert(am_avdtp_reassemble_message(&fragments,first,sizeof(first),out,sizeof(out))==0);
    last[0]=0x2f; // Message type must match across the fragments.
    assert(am_avdtp_reassemble_message(&fragments,last,sizeof(last),out,sizeof(out))==-1);
}
static void malformed_inputs(void) {
    uint32_t random=0xabcdef01; uint8_t packet[128];
    for(unsigned i=0;i<30000;i++) {
        AMInitiator s; am_initiator_begin(&s);
        uint8_t endpoints[]={4,0,8,0};
        if(i&1) accept(&s,endpoints,sizeof(endpoints));
        for(unsigned j=0;j<sizeof(packet);j++) { random=random*1664525u+1013904223u; packet[j]=(uint8_t)(random>>24); }
        size_t length=random%sizeof(packet);
        if(length>=2) { packet[0]=(uint8_t)((s.label<<4)|2); packet[1]=s.signal; }
        am_initiator_response(&s,packet,length);
    }
}
int main(void) {
    lifecycle(); negotiation_failures(); response_fragments(); malformed_inputs();
    puts("PASS: sink-initiated Discover → SBC configuration → Open → outgoing media → Start, endpoint fallback, malformed replies, response fragmentation, 30,000 malformed inputs");
    return 0;
}
