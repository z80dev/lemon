#include "packet.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
static int calls;
static void receive(packet *p, void *user) {
    assert(user==&calls);
    assert(p->kind==1 && p->length==3);
    assert(memcmp(p->data,"cat",3)==0 && p->data[3]==0);
    ++calls; packet_free(p);
}
int main(void) {
    unsigned char wire[]={0xD3,1,0,3,'c','a','t'};
    decoder *d=decoder_create(10,receive,&calls); assert(d);
    for(size_t i=0;i<sizeof(wire);i++) assert(decoder_feed(d,wire+i,1)==0);
    assert(decoder_finish(d)==0 && calls==1);
    assert(decoder_feed(d,wire,2)==0);
    assert(decoder_finish(d)==-1);
    decoder_reset(d);
    assert(decoder_feed(d,wire,sizeof(wire))==0 && calls==2);
    decoder_destroy(d);
    puts("packet tests passed");
}
