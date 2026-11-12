#include "packet_internal.h"
#include <stdlib.h>
packet *packet_create(unsigned char kind, size_t length) {
    packet *p = malloc(sizeof(*p));
    if (!p) return NULL;
    p->data = malloc(length + 1);
    if (!p->data) { free(p); return NULL; }
    p->kind = kind;
    p->length = length;
    p->data[length] = 0;
    return p;
}
void packet_free(packet *p) {
    if (p) { free(p->data); free(p); }
}
