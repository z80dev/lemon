#ifndef RING_H
#define RING_H
#include <stddef.h>
typedef struct ring ring;
ring *ring_create(size_t capacity);
void ring_destroy(ring *r);
size_t ring_size(const ring *r);
size_t ring_capacity(const ring *r);
size_t ring_push(ring *r, const int *values, size_t n);
size_t ring_pop(ring *r, int *values, size_t n);
int ring_resize(ring *r, size_t capacity);
#endif
