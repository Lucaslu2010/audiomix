#ifndef AM_AVDTP_H
#define AM_AVDTP_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum { AM_IDLE, AM_CONFIGURED, AM_OPEN, AM_STREAMING } AMStreamState;
typedef struct {
    AMStreamState state;
    bool mediaConnected;
    uint8_t sourceSEID;
    uint8_t sbc[4];
} AMAVDTP;
typedef struct {
    uint8_t bytes[32];
    size_t length;
    bool configurationChanged;
    bool closeMedia;
} AMAVDTPReply;

void am_avdtp_reset(AMAVDTP *session);
AMAVDTPReply am_avdtp_command(AMAVDTP *session, const uint8_t *data, size_t length);
unsigned am_sbc_rate(const uint8_t configuration[4]);
unsigned am_sbc_channels(const uint8_t configuration[4]);
const char *am_stream_state(AMStreamState state);
const char *am_signal_name(uint8_t signal);

typedef struct {
    uint8_t bytes[1024];
    size_t length;
    unsigned remaining;
    uint8_t label, signal;
} AMAVDTPFragments;
// Returns a complete, normalized single-packet command; zero while incomplete;
// -1 on malformed/oversized fragments. Non-command messages are ignored.
int am_avdtp_reassemble(AMAVDTPFragments *fragments, const uint8_t *data,
                        size_t length, uint8_t *complete, size_t capacity);
// Same bounded reassembly, preserving message type for initiator responses.
int am_avdtp_reassemble_message(AMAVDTPFragments *fragments, const uint8_t *data,
                        size_t length, uint8_t *complete, size_t capacity);
#endif
