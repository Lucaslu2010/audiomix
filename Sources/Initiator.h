#ifndef AM_INITIATOR_H
#define AM_INITIATOR_H
#include "AVDTP.h"
typedef enum { AM_INT_IDLE, AM_INT_DISCOVER, AM_INT_CAPS, AM_INT_CONFIGURE,
    AM_INT_OPEN, AM_INT_MEDIA, AM_INT_START, AM_INT_STREAMING, AM_INT_FAILED } AMInitiatorPhase;
typedef enum { AM_INT_NONE, AM_INT_SEND, AM_INT_OPEN_MEDIA, AM_INT_STARTED, AM_INT_ERROR } AMInitiatorActionKind;
typedef struct { AMInitiatorActionKind kind; uint8_t bytes[32]; size_t length; const char *error; } AMInitiatorAction;
typedef struct {
    AMInitiatorPhase phase;
    uint8_t label, signal, sources[62], count, index;
    AMAVDTP session;
} AMInitiator;
AMInitiatorAction am_initiator_begin(AMInitiator *initiator);
AMInitiatorAction am_initiator_response(AMInitiator *initiator,const uint8_t *packet,size_t length);
AMInitiatorAction am_initiator_media_connected(AMInitiator *initiator);
#endif
