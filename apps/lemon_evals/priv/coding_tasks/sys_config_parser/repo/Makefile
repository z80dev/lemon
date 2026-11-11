CC = gcc
CFLAGS = -std=c99 -Wall -Wextra -Werror -O2
.PHONY: all test clean
all: config_dump
config_dump: config_dump.c config.c config.h
	$(CC) $(CFLAGS) -I. config_dump.c config.c -o $@
test_config: tests/test_config.c config.c config.h
	$(CC) $(CFLAGS) -I. tests/test_config.c config.c -o $@
test: test_config
	./test_config
clean:
	rm -f config_dump test_config *.o
