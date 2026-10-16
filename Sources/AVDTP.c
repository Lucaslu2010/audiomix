#include "AVDTP.h"
#include <string.h>

enum { BAD_LENGTH=0x11, BAD_SEID=0x12, SEP_IN_USE=0x13,
       BAD_CATEGORY=0x17, BAD_CAPABILITIES=0x1a, BAD_MEDIA_TRANSPORT=0x23,
       UNSUPPORTED_CONFIGURATION=0x29, BAD_STATE=0x31 };
static const uint8_t capabilities[] = {1,0, 7,6,0,0, 0x3f,0xff,2,53};

void am_avdtp_reset(AMAVDTP *s) { memset(s,0,sizeof(*s)); }
unsigned am_sbc_rate(const uint8_t c[4]) { return (c[0]&0xf0)==0x20 ? 44100 : 48000; }
unsigned am_sbc_channels(const uint8_t c[4]) { return (c[0]&0x0f)==8 ? 1 : 2; }
const char *am_stream_state(AMStreamState s) {
    switch(s) {case AM_IDLE:return "Idle";case AM_CONFIGURED:return "Configured";
        case AM_OPEN:return "Open";case AM_STREAMING:return "Streaming";}
    return "Unknown";
}
const char *am_signal_name(uint8_t s) {
    switch(s) {case 1:return "Discover";case 2:return "GetCapabilities";
        case 3:return "SetConfiguration";case 4:return "GetConfiguration";
        case 5:return "Reconfigure";case 6:return "Open";case 7:return "Start";
        case 8:return "Close";case 9:return "Suspend";case 10:return "Abort";
        case 12:return "GetAllCapabilities"; default:return "Unsupported";}
}
static bool one_bit(uint8_t x) { return x && !(x & (x-1)); }
static bool valid_seid(uint8_t x) { return x == (1<<2); }
static bool valid_sbc(const uint8_t *c) {
    return one_bit(c[0]&0xf0) && !(c[0]&0xc0) && one_bit(c[0]&0x0f) &&
        one_bit(c[1]&0xf0) && one_bit(c[1]&0x0c) && one_bit(c[1]&3) &&
        c[2]>=2 && c[3]<=53 && c[2]<=c[3];
}
static AMAVDTPReply reject(AMAVDTPReply r, uint8_t error, int category) {
    r.bytes[0] = (uint8_t)((r.bytes[0]&0xf0)|3);
    if (category>=0) r.bytes[r.length++]=(uint8_t)category;
    r.bytes[r.length++]=error;
    return r;
}
static uint8_t read_configuration(const uint8_t *p, size_t n, bool reconfigure,
                                   uint8_t codec[4], uint8_t *badCategory) {
    bool transport=false, media=false;
    while(n) {
        if(n<2) { *badCategory=p[0]; return BAD_LENGTH; }
        uint8_t category=p[0], size=p[1];
        *badCategory=category;
        if((size_t)size+2>n) return BAD_LENGTH;
        if(category==1) {
            if(reconfigure || transport) return BAD_CATEGORY;
            if(size) return BAD_MEDIA_TRANSPORT;
            transport=true;
        } else if(category==7) {
            if(media) return BAD_CAPABILITIES;
            if(size!=6 || p[2]!=0 || p[3]!=0 || !valid_sbc(p+4))
                return UNSUPPORTED_CONFIGURATION;
            memcpy(codec,p+4,4);
            media=true;
        } else return BAD_CATEGORY;
        p+=size+2; n-=size+2;
    }
    if(!media || (!transport && !reconfigure)) {
        *badCategory=media ? 1 : 7;
        return BAD_CAPABILITIES;
    }
    return 0;
}
AMAVDTPReply am_avdtp_command(AMAVDTP *s, const uint8_t *p, size_t n) {
    AMAVDTPReply r={0};
    if(!p || n<2 || (p[0]&0x0f)) return r;
    uint8_t signal=p[1]&0x3f;
    r.bytes[0]=(uint8_t)((p[0]&0xf0)|2); r.bytes[1]=signal; r.length=2;
    if(p[1]&0xc0) return reject(r,1,-1);
    p+=2; n-=2;
    if(signal==1) {
        if(n) return reject(r,BAD_LENGTH,-1);
        r.bytes[2]=(uint8_t)(4|(s->state!=AM_IDLE ? 2 : 0));
        r.bytes[3]=8; r.length=4; return r;
    }
    if(signal==2 || signal==12) {
        if(n!=1) return reject(r,BAD_LENGTH,-1);
        if(!valid_seid(p[0])) return reject(r,BAD_SEID,-1);
        memcpy(r.bytes+2,capabilities,sizeof(capabilities));
        r.length+=sizeof(capabilities); return r;
    }
    if(signal==3 || signal==5) {
        bool reconfigure=signal==5;
        size_t prefix=reconfigure ? 1 : 2;
        if(n<prefix) return reject(r,BAD_LENGTH,0);
        if(!valid_seid(p[0])) return reject(r,BAD_SEID,0);
        if(reconfigure ? s->state!=AM_OPEN : s->state!=AM_IDLE)
            return reject(r,reconfigure ? BAD_STATE : SEP_IN_USE,0);
        if(!reconfigure && ((p[1]&3) || (p[1]>>2)==0 || (p[1]>>2)>62))
            return reject(r,BAD_SEID,0);
        uint8_t codec[4]={0}, category=0;
        uint8_t error=read_configuration(p+prefix,n-prefix,reconfigure,codec,&category);
        if(error) return reject(r,error,category);
        memcpy(s->sbc,codec,4);
        if(!reconfigure) { s->sourceSEID=p[1]>>2; s->state=AM_CONFIGURED; }
        r.configurationChanged=true; return r;
    }
    if(signal==4 || (signal>=6 && signal<=10)) {
        if(n!=1) return reject(r,BAD_LENGTH,(signal==7 || signal==9) ? 0 : -1);
        int failedSEID=(signal==7 || signal==9) ? p[0] : -1;
        if(!valid_seid(p[0])) return reject(r,BAD_SEID,failedSEID);
        switch(signal) {
            case 4:
                if(s->state==AM_IDLE) return reject(r,BAD_STATE,-1);
                memcpy(r.bytes+2,capabilities,sizeof(capabilities));
                memcpy(r.bytes+8,s->sbc,4); r.length+=sizeof(capabilities); return r;
            case 6:
                if(s->state!=AM_CONFIGURED) return reject(r,BAD_STATE,-1);
                s->state=AM_OPEN; return r;
            case 7:
                if(s->state!=AM_OPEN || !s->mediaConnected) return reject(r,BAD_STATE,failedSEID);
                s->state=AM_STREAMING; return r;
            case 9:
                if(s->state!=AM_STREAMING) return reject(r,BAD_STATE,failedSEID);
                s->state=AM_OPEN; return r;
            case 8:
                if(s->state!=AM_OPEN && s->state!=AM_STREAMING) return reject(r,BAD_STATE,-1);
                break;
            default: break;
        }
        am_avdtp_reset(s); r.closeMedia=true; return r;
    }
    r.bytes[0]=(uint8_t)((r.bytes[0]&0xf0)|1); // General Reject: unsupported signal.
    return r;
}

int am_avdtp_reassemble(AMAVDTPFragments *f, const uint8_t *p, size_t n,
                        uint8_t *out, size_t cap) {
    if(!p || !n) return -1;
    if(p[0]&3) return 0;
    return am_avdtp_reassemble_message(f,p,n,out,cap);
}
int am_avdtp_reassemble_message(AMAVDTPFragments *f, const uint8_t *p, size_t n,
                        uint8_t *out, size_t cap) {
    if(!p || !n || cap<2) return -1;
    uint8_t kind=(p[0]>>2)&3, label=p[0]&0xf3;
    if(kind==0) {
        memset(f,0,sizeof(*f));
        if(n<2 || n>cap) return -1;
        memcpy(out,p,n); return (int)n;
    }
    if(kind==1) {
        memset(f,0,sizeof(*f));
        if(n<3 || p[1]<2 || n-3>sizeof(f->bytes)) return -1;
        f->label=label; f->signal=p[2]; f->remaining=p[1]-1;
        memcpy(f->bytes,p+3,n-3); f->length=n-3; return 0;
    }
    if(!f->remaining || label!=f->label ||
       n-1>sizeof(f->bytes)-f->length ||
       (kind==3)!=(f->remaining==1)) {
        memset(f,0,sizeof(*f)); return -1;
    }
    memcpy(f->bytes+f->length,p+1,n-1); f->length+=n-1; f->remaining--;
    if(f->remaining) return 0;
    if(f->length+2>cap) { memset(f,0,sizeof(*f)); return -1; }
    out[0]=f->label; out[1]=f->signal; memcpy(out+2,f->bytes,f->length);
    int result=(int)f->length+2; memset(f,0,sizeof(*f)); return result;
}
