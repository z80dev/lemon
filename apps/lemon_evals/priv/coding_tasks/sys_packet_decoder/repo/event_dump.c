#include "packet.h"
#include <stdio.h>
static void print_event(packet *p, void *user) {
    (void)user;
    printf("%u:%zu:", (unsigned)p->kind, p->length);
    for (size_t i=0;i<p->length;i++) printf("%02x", (unsigned)p->data[i]);
    putchar('\n');
    packet_free(p);
}
int main(void) {
    decoder *d=decoder_create(65535,print_event,NULL);
    if (!d) return 2;
    unsigned char buf[64]; size_t n;
    int result=0;
    while ((n=fread(buf,1,sizeof(buf),stdin)) != 0) {
        if (decoder_feed(d,buf,n)) { result=1; break; }
    }
    if (ferror(stdin) || decoder_finish(d)) result=1;
    decoder_destroy(d);
    return result;
}
