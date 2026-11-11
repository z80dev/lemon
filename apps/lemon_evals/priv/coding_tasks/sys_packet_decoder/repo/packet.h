#ifndef PACKET_H
#define PACKET_H
#include <stddef.h>
typedef struct packet {
    unsigned char kind;
    size_t length;
    unsigned char *data;
} packet;
typedef struct decoder decoder;
typedef void (*packet_callback)(packet *event, void *user);
decoder *decoder_create(size_t max_payload, packet_callback callback, void *user);
int decoder_feed(decoder *d, const unsigned char *data, size_t size);
int decoder_finish(decoder *d);
void decoder_reset(decoder *d);
void decoder_destroy(decoder *d);
void packet_free(packet *event);
#endif
