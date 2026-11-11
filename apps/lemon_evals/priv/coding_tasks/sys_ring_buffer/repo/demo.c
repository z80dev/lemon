#include "ring.h"
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) {
    ring *r=ring_create((size_t)(argc-1));
    if(!r) return 1;
    for(int i=1;i<argc;i++) { int v=atoi(argv[i]); ring_push(r,&v,1); }
    int v, first=1;
    while(ring_pop(r,&v,1)) { printf("%s%d",first?"":" ",v); first=0; }
    putchar('\n'); ring_destroy(r); return 0;
}
