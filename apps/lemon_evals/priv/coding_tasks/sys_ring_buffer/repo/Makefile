CC = gcc
CFLAGS = -std=c99 -Wall -Wextra -Werror -O2
.PHONY: all test clean
all: ring_demo
ring_demo: demo.c ring.c ring.h
	$(CC) $(CFLAGS) -I. demo.c ring.c -o $@
test_ring: tests/test_ring.c ring.c ring.h
	$(CC) $(CFLAGS) -I. tests/test_ring.c ring.c -o $@
test: test_ring
	./test_ring
clean:
	rm -f ring_demo test_ring *.o
