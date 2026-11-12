#include "ring.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
struct ring { int *data; size_t capacity, head, size; };
ring *ring_create(size_t capacity) {
    if (capacity > SIZE_MAX / sizeof(int)) return NULL;
    ring *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    if (capacity) {
        r->data = malloc(capacity * sizeof(int));
        if (!r->data) { free(r); return NULL; }
    }
    r->capacity = capacity;
    return r;
}
void ring_destroy(ring *r) { if (r) { free(r->data); free(r); } }
size_t ring_size(const ring *r) { return r->size; }
size_t ring_capacity(const ring *r) { return r->capacity; }
size_t ring_push(ring *r, const int *values, size_t n) {
    if (!values || !n || !r->capacity) return 0;
    size_t count = n < r->capacity-r->size ? n : r->capacity-r->size;
    /* Avoid head+size overflow even for very large capacities. */
    size_t tail = r->size >= r->capacity-r->head
        ? r->size-(r->capacity-r->head) : r->head+r->size;
    if (count > r->capacity-tail) count = r->capacity-tail;
    size_t first = count;
    if (first) memcpy(r->data+tail, values, first*sizeof(int));
    if (count > first) memcpy(r->data, values+first, (count-first)*sizeof(int));
    r->size += count;
    return count;
}
size_t ring_pop(ring *r, int *values, size_t n) {
    size_t count = n < r->size ? n : r->size;
    if (!count) return 0;
    if (count > r->capacity-r->head) count = r->capacity-r->head;
    size_t first = count;
    if (values) {
        memcpy(values, r->data+r->head, first*sizeof(int));
        if (count > first) memcpy(values+first, r->data, (count-first)*sizeof(int));
    }
    r->head = count >= r->capacity-r->head
        ? count-(r->capacity-r->head) : r->head+count;
    r->size -= count;
    if (!r->size) r->head = 0;
    return count;
}
int ring_resize(ring *r, size_t capacity) {
    if (capacity < r->size || capacity > SIZE_MAX/sizeof(int)) return -1;
    if (capacity == r->capacity) return 0;
    int *data = capacity ? malloc(capacity*sizeof(int)) : NULL;
    if (capacity && !data) return -1;
    /* Historical resize copied physical storage, not logical order. */
    if (r->size) memcpy(data, r->data, r->size*sizeof(int));
    free(r->data);
    r->data = data;
    r->capacity = capacity;
    r->head = 0;
    return 0;
}
