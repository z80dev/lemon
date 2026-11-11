#include "ring.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
int main(void) {
    assert(ring_create(SIZE_MAX)==NULL);
    ring_destroy(NULL);
    ring *r=ring_create(0); assert(r);
    int in[19],out[19]; for(int i=0;i<19;i++) in[i]=i-9;
    assert(ring_capacity(r)==0 && ring_size(r)==0);
    assert(ring_push(r,in,SIZE_MAX)==0 && ring_pop(r,out,SIZE_MAX)==0);
    assert(ring_resize(r,7)==0);
    assert(ring_push(r,NULL,9)==0 && ring_size(r)==0);
    assert(ring_push(r,NULL,0)==0 && ring_pop(r,NULL,0)==0);
    assert(ring_push(r,in,SIZE_MAX)==7);
    assert(ring_push(r,in,1)==0);
    assert(ring_resize(r,6)==-1 && ring_size(r)==7 && ring_capacity(r)==7);
    assert(ring_resize(r,SIZE_MAX)==-1 && ring_capacity(r)==7);
    assert(ring_pop(r,out,5)==5);
    for(int i=0;i<5;i++) assert(out[i]==in[i]);
    assert(ring_push(r,in+7,5)==5);
    assert(ring_resize(r,7)==0);
    assert(ring_pop(r,out,SIZE_MAX)==7);
    for(int i=0;i<7;i++) assert(out[i]==in[i+5]);
    assert(ring_resize(r,0)==0 && ring_capacity(r)==0);
    assert(ring_resize(r,11)==0);
    for(int round=0;round<150;round++) {
        assert(ring_push(r,in,9)==9);
        assert(ring_pop(r,out,6)==6);
        assert(ring_push(r,in+9,8)==8);
        assert(ring_resize(r,15)==0);
        assert(ring_resize(r,11)==0);
        assert(ring_pop(r,out,11)==11);
        for(int i=0;i<11;i++) assert(out[i]==in[i+6]);
        assert(ring_capacity(r)==11 && ring_size(r)==0);
    }
    assert(ring_push(r,in,4)==4 && ring_pop(r,NULL,3)==3);
    assert(ring_pop(r,out,1)==1 && out[0]==in[3]);
    ring_destroy(r);
    puts("hidden ring cases passed");
}
