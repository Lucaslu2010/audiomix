#include "Initiator.h"
#include <string.h>
static AMInitiatorAction fail(AMInitiator *s,const char *message) {
    s->phase=AM_INT_FAILED;
    return (AMInitiatorAction){.kind=AM_INT_ERROR,.error=message};
}
static AMInitiatorAction command(AMInitiator *s,AMInitiatorPhase phase,uint8_t signal,const uint8_t *payload,size_t length) {
    AMInitiatorAction action={.kind=AM_INT_SEND,.length=length+2};
    s->phase=phase; s->label=(s->label+1)&15; s->signal=signal;
    action.bytes[0]=(uint8_t)(s->label<<4); action.bytes[1]=signal;
    if(length) memcpy(action.bytes+2,payload,length);
    return action;
}
AMInitiatorAction am_initiator_begin(AMInitiator *s) {
    memset(s,0,sizeof(*s));
    return command(s,AM_INT_DISCOVER,1,NULL,0);
}
static AMInitiatorAction capabilities(AMInitiator *s) {
    if(s->index>=s->count) return fail(s,"No available audio source supports our SBC configuration");
    uint8_t source=(uint8_t)(s->sources[s->index]<<2);
    return command(s,AM_INT_CAPS,2,&source,1);
}
static uint8_t preferred(uint8_t available,const uint8_t *order,size_t length) {
    for(size_t i=0;i<length;i++) if(available&order[i]) return order[i];
    return 0;
}
static bool choose_sbc(const uint8_t *packet,size_t length,uint8_t result[4]) {
    bool transport=false,codec=false;
    while(length) {
        if(length<2 || (size_t)packet[1]+2>length) return false;
        uint8_t category=packet[0],size=packet[1];
        if(category==1) { if(size || transport) return false; transport=true; }
        if(category==7) {
            if(size<2) return false;
            if(packet[2]==0 && packet[3]==0) {
                if(size!=6 || codec) return false;
                static const uint8_t rates[]={0x10,0x20},modes[]={1,2,4,8};
                static const uint8_t blocks[]={0x10,0x20,0x40,0x80},bands[]={4,8},allocation[]={1,2};
                uint8_t rate=preferred(packet[4],rates,sizeof(rates));
                uint8_t mode=preferred(packet[4],modes,sizeof(modes));
                uint8_t block=preferred(packet[5],blocks,sizeof(blocks));
                uint8_t band=preferred(packet[5],bands,sizeof(bands));
                uint8_t alloc=preferred(packet[5],allocation,sizeof(allocation));
                unsigned minimum=packet[6]<2 ? 2 : packet[6],maximum=packet[7]>53 ? 53 : packet[7];
                if(!rate || !mode || !block || !band || !alloc || minimum>maximum) return false;
                result[0]=rate|mode; result[1]=block|band|alloc;
                result[2]=(uint8_t)minimum; result[3]=(uint8_t)maximum; codec=true;
            }
        }
        packet+=size+2; length-=size+2;
    }
    return transport && codec;
}
AMInitiatorAction am_initiator_response(AMInitiator *s,const uint8_t *p,size_t n) {
    AMInitiatorAction none={0};
    if(!p || n<2 || (p[0]&0x0c) || (p[0]&3)==0) return none;
    if((p[0]>>4)!=s->label || (p[1]&0x3f)!=s->signal) return none;
    if(s->phase==AM_INT_IDLE || s->phase>=AM_INT_STREAMING) return none;
    if((p[1]&0xc0) || (p[0]&3)!=2) {
        if(s->phase==AM_INT_CAPS || s->phase==AM_INT_CONFIGURE) { s->index++; return capabilities(s); }
        return fail(s,"Remote source rejected an AVDTP command (see response bytes)");
    }
    const uint8_t *payload=p+2; size_t length=n-2;
    switch(s->phase) {
        case AM_INT_DISCOVER:
            if(length%2) return fail(s,"Malformed endpoint discovery response");
            for(size_t i=0;i<length;i+=2) {
                uint8_t seid=payload[i]>>2;
                if(seid && seid<=62 && !(payload[i]&3) && payload[i+1]==0 && s->count<62) {
                    bool duplicate=false;
                    for(unsigned j=0;j<s->count;j++) if(s->sources[j]==seid) duplicate=true;
                    if(!duplicate) s->sources[s->count++]=seid;
                }
            }
            return capabilities(s);
        case AM_INT_CAPS: {
            uint8_t codec[4]={0};
            if(!choose_sbc(payload,length,codec)) { s->index++; return capabilities(s); }
            uint8_t config[]={0,4,1,0,7,6,0,0,0,0,0,0};
            config[0]=(uint8_t)(s->sources[s->index]<<2); memcpy(config+8,codec,4);
            memcpy(s->session.sbc,codec,4); s->session.sourceSEID=s->sources[s->index];
            return command(s,AM_INT_CONFIGURE,3,config,sizeof(config));
        }
        case AM_INT_CONFIGURE: {
            if(length) return fail(s,"Malformed SetConfiguration response");
            s->session.state=AM_CONFIGURED;
            uint8_t source=(uint8_t)(s->session.sourceSEID<<2);
            return command(s,AM_INT_OPEN,6,&source,1);
        }
        case AM_INT_OPEN:
            if(length) return fail(s,"Malformed Open response");
            s->session.state=AM_OPEN; s->phase=AM_INT_MEDIA;
            return (AMInitiatorAction){.kind=AM_INT_OPEN_MEDIA};
        case AM_INT_START:
            if(length) return fail(s,"Malformed Start response");
            s->session.state=AM_STREAMING; s->phase=AM_INT_STREAMING;
            return (AMInitiatorAction){.kind=AM_INT_STARTED};
        default: return none;
    }
}
AMInitiatorAction am_initiator_media_connected(AMInitiator *s) {
    if(s->phase!=AM_INT_MEDIA) return fail(s,"Media channel opened in the wrong phase");
    s->session.mediaConnected=true;
    uint8_t source=(uint8_t)(s->session.sourceSEID<<2);
    return command(s,AM_INT_START,7,&source,1);
}
