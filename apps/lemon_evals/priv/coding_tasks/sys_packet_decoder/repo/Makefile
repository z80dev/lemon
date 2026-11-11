CC = gcc
CFLAGS = -std=c99 -Wall -Wextra -Werror -O2
LIB = packet.c stream.c
HEADERS = packet.h packet_internal.h
.PHONY: all test clean
all: event_dump
event_dump: event_dump.c $(LIB) $(HEADERS)
	$(CC) $(CFLAGS) -I. event_dump.c $(LIB) -o $@
test_packet: tests/test_packet.c $(LIB) $(HEADERS)
	$(CC) $(CFLAGS) -I. tests/test_packet.c $(LIB) -o $@
test: test_packet
	./test_packet
clean:
	rm -f event_dump test_packet *.o
