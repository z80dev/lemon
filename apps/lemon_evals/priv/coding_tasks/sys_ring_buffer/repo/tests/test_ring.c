#include "ring.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    ring *r = ring_create(5);
    int in[] = {10,20,30,40,50,60}, out[6];
    assert(r);
    assert(ring_push(r,in,4)==4);
    assert(ring_pop(r,out,3)==3 && out[0]==10 && out[2]==30);
    assert(ring_push(r,in+4,2)==2); /* crosses the physical end */
    assert(ring_resize(r,3)==0);
    assert(ring_pop(r,out,6)==3);
    assert(out[0]==40 && out[1]==50 && out[2]==60);
    ring_destroy(r);
    puts("ring tests passed");
}
