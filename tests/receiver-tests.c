#include "AVDTP.h"
#include "Media.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const uint8_t codec[]={0x21,0x15,2,53}; // 44.1k, joint stereo, 16 blocks, 8 subbands, loudness.
static const uint8_t configuration[]={0x20,3,4,8,1,0,7,6,0,0,0x21,0x15,2,53};
static AMAVDTPReply command(AMAVDTP *s, uint8_t id) {
    uint8_t bytes[]={0x30,id,4}; return am_avdtp_command(s,bytes,sizeof(bytes));
}
static void test_protocol(void) {
    AMAVDTP s; am_avdtp_reset(&s);
    const uint8_t discover[]={0xa0,1};
    AMAVDTPReply r=am_avdtp_command(&s,discover,2);
    const uint8_t answer[]={0xa2,1,4,8};
    assert(r.length==4 && !memcmp(r.bytes,answer,4));
    r=command(&s,2); assert(r.length==12 && r.bytes[8]==0x3f);
    r=command(&s,7); assert(r.length==4 && r.bytes[3]==0x31);
    uint8_t invalid[sizeof(configuration)]; memcpy(invalid,configuration,sizeof(invalid));
    invalid[10]=0x31; // Multiple sample rates cannot be selected.
    r=am_avdtp_command(&s,invalid,sizeof(invalid));
    assert((r.bytes[0]&3)==3 && s.state==AM_IDLE);
    invalid[10]=0x81;
    r=am_avdtp_command(&s,invalid,sizeof(invalid)); assert((r.bytes[0]&3)==3);
    memcpy(invalid,configuration,sizeof(invalid)); invalid[5]=5; // Malformed media transport LOSC.
    r=am_avdtp_command(&s,invalid,sizeof(invalid)); assert((r.bytes[0]&3)==3);
    for(size_t i=2;i<sizeof(configuration);i++) {
        r=am_avdtp_command(&s,configuration,i);
        assert((r.bytes[0]&3)==3 && s.state==AM_IDLE);
    }
    r=am_avdtp_command(&s,configuration,sizeof(configuration));
    assert(r.configurationChanged && s.state==AM_CONFIGURED && !memcmp(s.sbc,codec,4));
    r=command(&s,4); assert(r.length==12 && !memcmp(r.bytes+8,codec,4));
    r=am_avdtp_command(&s,configuration,sizeof(configuration));
    assert((r.bytes[0]&3)==3 && r.bytes[3]==0x13);
    r=command(&s,6); assert((r.bytes[0]&3)==2 && s.state==AM_OPEN);
    r=command(&s,7); assert((r.bytes[0]&3)==3 && s.state==AM_OPEN);
    s.mediaConnected=true;
    r=command(&s,7); assert((r.bytes[0]&3)==2 && s.state==AM_STREAMING);
    uint8_t reconfigure[]={0x10,5,4,7,6,0,0,0x11,0x15,2,53};
    r=am_avdtp_command(&s,reconfigure,sizeof(reconfigure)); assert((r.bytes[0]&3)==3);
    r=command(&s,9); assert((r.bytes[0]&3)==2 && s.state==AM_OPEN);
    r=am_avdtp_command(&s,reconfigure,sizeof(reconfigure));
    assert(r.configurationChanged && am_sbc_rate(s.sbc)==48000);
    r=command(&s,8); assert(r.closeMedia && s.state==AM_IDLE && !s.mediaConnected);
    r=command(&s,10); assert(r.closeMedia && s.state==AM_IDLE);
    uint8_t unknown[]={0x50,0x3e}; r=am_avdtp_command(&s,unknown,2);
    assert(r.length==2 && r.bytes[0]==0x51);
    uint8_t wrongSEID[]={0,2,8}; r=am_avdtp_command(&s,wrongSEID,3);
    assert((r.bytes[0]&3)==3 && r.bytes[2]==0x12);
}
static void test_fragments(void) {
    AMAVDTPFragments f={0}; uint8_t out[1026];
    uint8_t first[]={0x24,2,3,4,8,1,0};
    uint8_t last[]={0x2c,7,6,0,0,0x21,0x15,2,53};
    assert(am_avdtp_reassemble(&f,first,sizeof(first),out,sizeof(out))==0);
    int n=am_avdtp_reassemble(&f,last,sizeof(last),out,sizeof(out));
    assert(n==(int)sizeof(configuration) && !memcmp(out,configuration,sizeof(configuration)));
    assert(am_avdtp_reassemble(&f,last,sizeof(last),out,sizeof(out))==-1);
    assert(am_avdtp_reassemble(&f,first,sizeof(first),out,sizeof(out))==0);
    last[0]=0x3c;
    assert(am_avdtp_reassemble(&f,last,sizeof(last),out,sizeof(out))==-1);
    first[1]=3; last[0]=0x2c;
    assert(am_avdtp_reassemble(&f,first,sizeof(first),out,sizeof(out))==0);
    assert(am_avdtp_reassemble(&f,last,sizeof(last),out,sizeof(out))==-1);
}
static void test_ring(void) {
    AMAudioRing r; am_ring_init(&r); atomic_store(&r.gainQ16,65536);
    int16_t in[1000*2],out[1000*2];
    for(unsigned i=0;i<2000;i++) in[i]=(int16_t)(i-1000);
    for(unsigned iteration=0;iteration<30;iteration++) {
        assert(am_ring_write(&r,in,1000,AM_RING_FRAMES)==1000);
        am_ring_render(&r,out,1000); assert(!memcmp(in,out,sizeof(in)));
    }
    assert(am_ring_write(&r,in,1000,500)==500);
    am_ring_render(&r,out,1000); assert(!memcmp(in,out,1000));
    for(unsigned i=1000;i<2000;i++) assert(out[i]==0);
    assert(atomic_load(&r.droppedFrames)==500 && atomic_load(&r.underrunFrames)==500);
}
static size_t encoded_frame(uint8_t *frame) {
    sbc_t encoder; assert(sbc_init_a2dp(&encoder,0,codec,4)==0);
    encoder.endian=SBC_LE; encoder.bitpool=32;
    int16_t pcm[256];
    for(unsigned i=0;i<256;i++) pcm[i]=(int16_t)((i%32)*500-8000);
    ssize_t written=0;
    assert(sbc_encode(&encoder,pcm,sizeof(pcm),frame,1024,&written)==sizeof(pcm));
    assert(written>0 && written<1024); sbc_finish(&encoder); return (size_t)written;
}
static void header(uint8_t *p, uint16_t seq) {
    memset(p,0,12); p[0]=0x80; p[1]=96;
    p[2]=(uint8_t)(seq>>8); p[3]=(uint8_t)seq; p[11]=1;
}
static void test_media(void) {
    uint8_t frame[1024],packet[2048]; size_t size=encoded_frame(frame);
    AMAudioRing ring; am_ring_init(&ring); AMMedia m;
    assert(am_media_init(&m,codec,&ring,60)==0);
    header(packet,65535); packet[12]=1; memcpy(packet+13,frame,size);
    assert(am_media_packet(&m,packet,size+13));
    assert(m.decodedFrames==128 && atomic_load(&ring.writeFrame)==128);
    assert(!am_media_packet(&m,packet,size+13)); // Duplicate.
    header(packet,0); assert(am_media_packet(&m,packet,size+13)); // Sequence wrap.
    header(packet,2); assert(am_media_packet(&m,packet,size+13)); assert(m.lostPackets==1);
    header(packet,3); packet[12]=2; // Claims two frames but supplies one.
    uint64_t before=m.decodedFrames;
    assert(!am_media_packet(&m,packet,size+13) && m.decodedFrames==before);
    // Header with CSRC, extension, and valid RTP padding.
    header(packet,4); packet[0]=0xb1; memset(packet+12,0,12);
    packet[18]=0; packet[19]=1; // Extension contains one word after its header.
    packet[24]=1; memcpy(packet+25,frame,size);
    memset(packet+25+size,0,4); packet[28+size]=4;
    assert(am_media_packet(&m,packet,size+29));
    // Reassemble one SBC frame over two consecutive packets.
    header(packet,5); packet[12]=0xc0; memcpy(packet+13,frame,size/2);
    assert(am_media_packet(&m,packet,13+size/2));
    header(packet,6); packet[12]=0xa0; memcpy(packet+13,frame+size/2,size-size/2);
    assert(am_media_packet(&m,packet,13+size-size/2));
    assert(m.fragmentLength==0 && m.decodedFrames==640);
    // Loss during a fragmented frame discards it.
    header(packet,7); packet[12]=0xc0; memcpy(packet+13,frame,size/2);
    assert(am_media_packet(&m,packet,13+size/2));
    header(packet,9); packet[12]=0xa0; memcpy(packet+13,frame+size/2,size-size/2);
    assert(!am_media_packet(&m,packet,13+size-size/2));
    int16_t pcm[1280]; am_ring_render(&ring,pcm,640);
    bool nonzero=false; for(unsigned i=0;i<1280;i++) nonzero|=pcm[i]!=0;
    assert(nonzero);
    am_media_finish(&m);
}
static void test_codec_matrix(void) {
    // Exercise every advertised single-choice SBC configuration, including mono
    // expansion and both sample rates, rather than only the likely iPad choice.
    for(unsigned rate=0;rate<2;rate++) for(unsigned mode=0;mode<4;mode++)
    for(unsigned blocks=0;blocks<4;blocks++) for(unsigned bands=0;bands<2;bands++)
    for(unsigned allocation=0;allocation<2;allocation++) {
        uint8_t c[]={
            (uint8_t)((rate ? 0x10 : 0x20)|(1u<<(3-mode))),
            (uint8_t)((1u<<(7-blocks))|(1u<<(3-bands))|(1u<<allocation)),2,53};
        sbc_t encoder; assert(sbc_init_a2dp(&encoder,0,c,4)==0);
        encoder.endian=SBC_LE; encoder.bitpool=32;
        int16_t input[256];
        for(unsigned i=0;i<256;i++) input[i]=(int16_t)(i*100-12800);
        uint8_t packet[1200]; header(packet,1); packet[12]=1;
        ssize_t written=0; size_t codeSize=sbc_get_codesize(&encoder);
        assert(codeSize<=sizeof(input));
        assert(sbc_encode(&encoder,input,codeSize,packet+13,sizeof(packet)-13,&written)==(ssize_t)codeSize);
        AMAudioRing ring; am_ring_init(&ring); AMMedia media;
        assert(am_media_init(&media,c,&ring,60)==0);
        assert(am_media_packet(&media,packet,(size_t)written+13));
        size_t frames=(4+blocks*4)*(bands ? 8 : 4);
        assert(media.decodedFrames==frames);
        int16_t output[256]; am_ring_render(&ring,output,frames);
        if(mode==0) for(size_t k=0;k<frames;k++) assert(output[2*k]==output[2*k+1]);
        header(packet,2); packet[15]=54; // Bitpool outside selected range.
        assert(!am_media_packet(&media,packet,(size_t)written+13));
        am_media_finish(&media); sbc_finish(&encoder);
    }
}
static uint32_t randomState=0x8356abdu;
static uint8_t random_byte(void) {
    randomState^=randomState<<13; randomState^=randomState>>17; randomState^=randomState<<5;
    return (uint8_t)randomState;
}
static void test_malformed_corpus(void) {
    AMAVDTP s={0}; AMAVDTPFragments f={0}; uint8_t packet[1100],out[1026];
    AMAudioRing ring; am_ring_init(&ring); AMMedia media;
    assert(am_media_init(&media,codec,&ring,60)==0);
    for(unsigned i=0;i<30000;i++) {
        size_t n=((size_t)random_byte()*4+random_byte())%sizeof(packet);
        for(size_t k=0;k<n;k++) packet[k]=random_byte();
        (void)am_avdtp_command(&s,packet,n);
        (void)am_avdtp_reassemble(&f,packet,n,out,sizeof(out));
        (void)am_media_packet(&media,packet,n);
        if(i%31==0) am_avdtp_reset(&s);
    }
    am_media_finish(&media);
}
int main(void) {
    test_protocol(); puts("PASS: SBC negotiation, stream lifecycle, invalid configurations");
    test_fragments(); puts("PASS: signaling fragment reassembly and invalid ordering");
    test_ring(); puts("PASS: bounded stereo queue, wraparound, overflow, silent underrun");
    test_media(); puts("PASS: encoded SBC → RTP → decoded PCM, fragmentation, loss, RTP headers");
    test_codec_matrix(); puts("PASS: all 128 advertised SBC configurations and mono-to-stereo output");
    test_malformed_corpus(); puts("PASS: 30,000 deterministic malformed inputs under sanitizers");
    return 0;
}
