CC = gcc
CFLAGS = -std=c99 -Wall -Wextra -Werror -O2
LIB = ring.c
.PHONY: all test clean print-lib
all: ring_demo
ring_demo: demo.c $(LIB) ring.h
	$(CC) $(CFLAGS) -I. demo.c $(LIB) -o $@
test_ring: tests/test_ring.c $(LIB) ring.h
	$(CC) $(CFLAGS) -I. tests/test_ring.c $(LIB) -o $@
test: test_ring
	./test_ring
clean:
	rm -f ring_demo test_ring *.o
print-lib:
	@printf '%s\n' $(LIB)
