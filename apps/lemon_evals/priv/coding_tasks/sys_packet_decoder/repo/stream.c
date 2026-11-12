#include "packet_internal.h"
#include <stdlib.h>
#include <string.h>
struct decoder {
    size_t limit;
    packet_callback callback;
    void *user;
    unsigned char header[4];
    size_t header_used, payload_used;
    packet *pending;
    int failed;
};
static int fail(decoder *d) {
    packet_free(d->pending);
    d->pending = NULL;
    d->failed = 1;
    return -1;
}
decoder *decoder_create(size_t limit, packet_callback callback, void *user) {
    if (limit > 65535 || !callback) return NULL;
    decoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->limit = limit; d->callback = callback; d->user = user;
    return d;
}
static void deliver(decoder *d) {
    packet *p = d->pending;
    d->pending = NULL;
    d->header_used = d->payload_used = 0;
    d->callback(p, d->user);
    packet_free(p);
}
int decoder_feed(decoder *d, const unsigned char *data, size_t size) {
    if (d->failed) return -1;
    if (size && !data) return fail(d);
    while (size) {
        if (!d->pending) {
            size_t take = 4 - d->header_used;
            if (take > size) take = size;
            memcpy(d->header, data, take);
            d->header_used += take; data += take; size -= take;
            if (d->header_used < 4) continue;
            unsigned char kind = d->header[1];
            size_t length = ((size_t)d->header[2] << 8) | d->header[3];
            if (d->header[0] != 0xD3 || kind < 1 || kind > 3 ||
                length > d->limit) return fail(d);
            d->pending = packet_create(kind, length);
            if (!d->pending) return fail(d);
            if (!length) deliver(d);
        } else {
            size_t take = d->pending->length - d->payload_used;
            if (take > size) take = size;
            memcpy(d->pending->data + d->payload_used, data, take);
            d->payload_used += take; data += take; size -= take;
            if (d->payload_used == d->pending->length) {
                /* Payload bytes are currently accepted without kind-specific checks. */
                deliver(d);
            }
        }
    }
    return 0;
}
int decoder_finish(decoder *d) {
    if (d->failed) return -1;
    if (d->pending) return fail(d);
    return 0;
}
void decoder_reset(decoder *d) {
    packet_free(d->pending); d->pending = NULL;
    d->header_used = d->payload_used = 0; d->failed = 0;
}
void decoder_destroy(decoder *d) {
    if (d) { packet_free(d->pending); free(d); }
}
