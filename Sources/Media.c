#include "Media.h"
#include "AVDTP.h"
#include <string.h>

void am_ring_init(AMAudioRing *r) {
    memset(r->samples,0,sizeof(r->samples));
    atomic_init(&r->readFrame,0); atomic_init(&r->writeFrame,0);
    atomic_init(&r->underrunFrames,0); atomic_init(&r->droppedFrames,0);
    atomic_init(&r->gainQ16,32768); // Start at 50% amplitude.
}
size_t am_ring_write(AMAudioRing *r, const int16_t *p, size_t n, unsigned maxQueued) {
    uint64_t w=atomic_load_explicit(&r->writeFrame,memory_order_relaxed);
    uint64_t rd=atomic_load_explicit(&r->readFrame,memory_order_acquire);
    uint64_t queued=w-rd;
    if(maxQueued>AM_RING_FRAMES) maxQueued=AM_RING_FRAMES;
    size_t room=queued<maxQueued ? maxQueued-(size_t)queued : 0;
    size_t count=n<room ? n : room;
    for(size_t i=0;i<count;i++) {
        size_t index=(size_t)((w+i)%AM_RING_FRAMES)*2;
        r->samples[index]=p[2*i]; r->samples[index+1]=p[2*i+1];
    }
    atomic_store_explicit(&r->writeFrame,w+count,memory_order_release);
    atomic_fetch_add_explicit(&r->droppedFrames,n-count,memory_order_relaxed);
    return count;
}
void am_ring_render(AMAudioRing *r, int16_t *p, size_t n) {
    uint64_t rd=atomic_load_explicit(&r->readFrame,memory_order_relaxed);
    uint64_t w=atomic_load_explicit(&r->writeFrame,memory_order_acquire);
    size_t count=(size_t)(w-rd); if(count>n) count=n;
    uint32_t gain=atomic_load_explicit(&r->gainQ16,memory_order_relaxed);
    if(gain>65536) gain=65536;
    for(size_t i=0;i<count;i++) {
        size_t index=(size_t)((rd+i)%AM_RING_FRAMES)*2;
        p[2*i]=(int16_t)((int64_t)r->samples[index]*gain/65536);
        p[2*i+1]=(int16_t)((int64_t)r->samples[index+1]*gain/65536);
    }
    memset(p+2*count,0,(n-count)*2*sizeof(int16_t));
    atomic_store_explicit(&r->readFrame,rd+count,memory_order_release);
    atomic_fetch_add_explicit(&r->underrunFrames,n-count,memory_order_relaxed);
}
int am_media_init(AMMedia *m, const uint8_t c[4], AMAudioRing *ring, unsigned ms) {
    memset(m,0,sizeof(*m));
    int error=sbc_init_a2dp(&m->decoder,0,c,4);
    if(error) return error;
    m->initialized=true; m->decoder.endian=SBC_LE; m->ring=ring;
    memcpy(m->configuration,c,4);
    m->rate=am_sbc_rate(c); m->channels=am_sbc_channels(c);
    m->queueFrames=(unsigned)((uint64_t)m->rate*ms/1000);
    if(m->queueFrames>AM_RING_FRAMES) m->queueFrames=AM_RING_FRAMES;
    if(m->queueFrames<256) m->queueFrames=256;
    return 0;
}
void am_media_finish(AMMedia *m) {
    if(m->initialized) sbc_finish(&m->decoder);
    memset(m,0,sizeof(*m));
}
static bool decode(AMMedia *m, const uint8_t *p, size_t n, unsigned expectedFrames) {
    unsigned frames=0;
    // Decode a complete packet transactionally so a truncated last frame cannot
    // leave the first frames of a malformed packet in the playback queue.
    int16_t stereo[15*128*2]; size_t outputFrames=0;
    while(n && frames<15) {
        if(n<4 || p[0]!=0x9c) return false;
        unsigned freq=p[1]>>6, mode=(p[1]>>2)&3;
        unsigned rate=freq==2 ? 44100 : freq==3 ? 48000 : 0;
        unsigned channels=mode==0 ? 1 : 2;
        unsigned blocks=(p[1]>>4)&3, bands=p[1]&1, allocation=(p[1]>>1)&1;
        // A frame must honor all negotiated parameters, including bitpool range.
        const uint8_t *c=m->configuration;
        if(rate!=m->rate || channels!=m->channels ||
           !(c[0]&(1u<<(3-mode))) || !(c[1]&(1u<<(7-blocks))) ||
           !(c[1]&(1u<<(3-bands))) || !(c[1]&(1u<<allocation)) ||
           p[2]<c[2] || p[2]>c[3]) return false;
        int16_t pcm[128*2]; size_t written=0;
        ssize_t consumed=sbc_decode(&m->decoder,p,n,pcm,sizeof(pcm),&written);
        if(consumed<=0 || (size_t)consumed>n || !written || written%(channels*2)) return false;
        size_t samples=written/(channels*2);
        if(samples>128 || outputFrames+samples>15*128) return false;
        for(size_t i=0;i<samples;i++) {
            stereo[(outputFrames+i)*2]=pcm[i*channels];
            stereo[(outputFrames+i)*2+1]=pcm[i*channels+(channels==1 ? 0 : 1)];
        }
        outputFrames+=samples; p+=consumed; n-=(size_t)consumed; frames++;
    }
    if(n || frames!=expectedFrames) return false;
    am_ring_write(m->ring,stereo,outputFrames,m->queueFrames);
    m->decodedFrames+=outputFrames;
    return true;
}
bool am_media_packet(AMMedia *m, const uint8_t *p, size_t n) {
    if(!m->initialized || !p || n<13) goto bad;
    if((p[0]>>6)!=2) goto bad;
    size_t header=12+(p[0]&15)*4;
    if(header>=n) goto bad;
    if(p[0]&0x10) {
        if(n-header<4) goto bad;
        size_t words=((size_t)p[header+2]<<8)|p[header+3];
        if(words>(n-header-4)/4) goto bad;
        header+=4+words*4;
    }
    if(p[0]&0x20) {
        size_t padding=p[n-1];
        if(!padding || padding>n-header) goto bad;
        n-=padding;
    }
    if(header>=n) goto bad;
    uint16_t seq=(uint16_t)((p[2]<<8)|p[3]);
    uint32_t ssrc=((uint32_t)p[8]<<24)|((uint32_t)p[9]<<16)|((uint32_t)p[10]<<8)|p[11];
    if(m->haveSSRC && m->ssrc!=ssrc) goto bad;
    if(m->haveSequence) {
        uint16_t delta=(uint16_t)(seq-m->sequence);
        if(delta==0 || delta>32767) goto bad;
        if(delta!=1) { m->lostPackets+=delta-1; m->fragmentLength=0; }
    }
    m->sequence=seq; m->haveSequence=true; m->ssrc=ssrc; m->haveSSRC=true; m->packets++;
    uint8_t sbc=p[header++];
    if(sbc&0x10) goto bad;
    p+=header; n-=header;
    if(!(sbc&0x80)) {
        m->fragmentLength=0;
        if((sbc&0x60) || !(sbc&15) || !decode(m,p,n,sbc&15)) goto bad;
        return true;
    }
    // SBC fragmentation spans consecutive RTP packets and exactly one codec frame.
    if(sbc&0x40) m->fragmentLength=0;
    else if(!m->fragmentLength) goto bad;
    if(!n || n>sizeof(m->fragment)-m->fragmentLength) goto bad;
    memcpy(m->fragment+m->fragmentLength,p,n); m->fragmentLength+=n;
    if(sbc&0x20) {
        size_t length=m->fragmentLength; m->fragmentLength=0;
        if(!decode(m,m->fragment,length,1)) goto bad;
    }
    return true;
bad:
    m->invalidPackets++; m->fragmentLength=0; return false;
}
