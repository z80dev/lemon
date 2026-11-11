#include "packet.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef struct { packet *events[20]; size_t count; } collector;
static void keep(packet *p, void *arg) {
    collector *c=arg; assert(c->count<20);
    assert(p && p->data && p->data[p->length]==0);
    c->events[c->count++]=p;
}
static void release(collector *c) {
    for(size_t i=0;i<c->count;i++) packet_free(c->events[i]);
    c->count=0;
}
static void immediate(packet *p, void *arg) {
    size_t *count=arg; ++*count; packet_free(p);
}
static void sticky(decoder *d, collector *c) {
    unsigned char ping[]={0xD3,3,0,0}; size_t before=c->count;
    assert(decoder_feed(d,NULL,0)==-1);
    assert(decoder_feed(d,ping,4)==-1);
    assert(decoder_finish(d)==-1 && c->count==before);
}
int main(void) {
    collector c={0};
    assert(!decoder_create(65536,keep,&c));
    assert(!decoder_create(10,NULL,&c));
    decoder_destroy(NULL); packet_free(NULL);
    unsigned char wire[]={0xD3,1,0,3,'a','b','c',0xD3,2,0,3,0,255,7,
                          0xD3,3,0,0,0xD3,1,0,0,0xD3,2,0,0};
    for(size_t split=0;split<=sizeof(wire);split++) {
        decoder *d=decoder_create(3,keep,&c); assert(d);
        assert(decoder_finish(d)==0 && decoder_feed(d,NULL,0)==0);
        assert(decoder_feed(d,wire,split)==0);
        assert(decoder_feed(d,wire+split,sizeof(wire)-split)==0);
        assert(c.count==5 && decoder_finish(d)==0);
        decoder_reset(d); decoder_destroy(d);
        assert(c.events[0]->kind==1 && c.events[0]->length==3);
        assert(!memcmp(c.events[0]->data,"abc",3));
        assert(c.events[1]->kind==2 && c.events[1]->data[0]==0 && c.events[1]->data[1]==255);
        assert(c.events[2]->kind==3 && !c.events[2]->length);
        assert(!c.events[3]->length && !c.events[4]->length);
        release(&c);
    }
    decoder *d=decoder_create(3,keep,&c); assert(d);
    unsigned char mutable[]={0xD3,1,0,3,'x','y','z'};
    for(size_t i=0;i<sizeof(mutable);i++) {
        assert(decoder_feed(d,mutable+i,1)==0);
        mutable[i]=0;
        if(i<sizeof(mutable)-1) assert(c.count==0);
    }
    assert(c.count==1 && !memcmp(c.events[0]->data,"xyz",3));
    assert(decoder_finish(d)==0);
    unsigned char ping[]={0xD3,3,0,0};
    assert(decoder_feed(d,ping,4)==0 && c.count==2); release(&c);
    const unsigned char bad[][4]={{0,1,0,0},{0xD3,0,0,0},{0xD3,4,0,0},
                                 {0xD3,2,0,4},{0xD3,3,0,1}};
    for(size_t i=0;i<sizeof(bad)/sizeof(bad[0]);i++) {
        decoder_reset(d);
        assert(decoder_feed(d,bad[i],3)==0 && c.count==0);
        assert(decoder_feed(d,bad[i]+3,1)==-1 && c.count==0);
        sticky(d,&c);
    }
    decoder_reset(d);
    unsigned char textnul[]={0xD3,1,0,3,'a',0,'b'};
    assert(decoder_feed(d,textnul,6)==0 && c.count==0);
    assert(decoder_feed(d,textnul+6,1)==-1 && c.count==0); sticky(d,&c);
    unsigned char one[]={0xD3,1,0,3,'a','b','c'};
    for(size_t n=1;n<sizeof(one);n++) {
        decoder_reset(d); assert(decoder_feed(d,one,n)==0 && c.count==0);
        assert(decoder_finish(d)==-1); sticky(d,&c);
        decoder_reset(d); assert(decoder_feed(d,ping,4)==0 && c.count==1); release(&c);
    }
    decoder_reset(d); assert(decoder_feed(d,NULL,1)==-1); sticky(d,&c);
    decoder_reset(d);
    unsigned char mixed[]={0xD3,3,0,0,0xD3,9,0,0,0xD3,3,0,0};
    assert(decoder_feed(d,mixed,sizeof(mixed))==-1 && c.count==1); sticky(d,&c); release(&c);
    decoder_reset(d); assert(decoder_feed(d,one,5)==0);
    decoder_reset(d); assert(decoder_feed(d,ping,4)==0); release(&c);
    assert(decoder_feed(d,one,5)==0); decoder_destroy(d);
    d=decoder_create(0,keep,&c); assert(d);
    assert(decoder_feed(d,ping,4)==0 && c.count==1); release(&c);
    assert(decoder_feed(d,one,4)==-1); decoder_destroy(d);
    size_t calls=0; d=decoder_create(65535,immediate,&calls); assert(d);
    unsigned char *large=malloc(65539); assert(large);
    large[0]=0xD3; large[1]=2; large[2]=255; large[3]=255;
    for(size_t i=4;i<65539;i++) large[i]=(unsigned char)i;
    for(size_t i=0;i<65539;i++) assert(decoder_feed(d,large+i,1)==0);
    assert(calls==1 && decoder_finish(d)==0);
    for(int i=0;i<200;i++) assert(decoder_feed(d,ping,4)==0);
    assert(calls==201); free(large); decoder_destroy(d);
    puts("hidden packet cases passed");
}
