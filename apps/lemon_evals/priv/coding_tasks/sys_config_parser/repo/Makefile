CC = gcc
CFLAGS = -std=c99 -Wall -Wextra -Werror -O2
LIB = config.c
.PHONY: all test clean print-lib
all: config_dump
config_dump: config_dump.c $(LIB) config.h
	$(CC) $(CFLAGS) -I. config_dump.c $(LIB) -o $@
test_config: tests/test_config.c $(LIB) config.h
	$(CC) $(CFLAGS) -I. tests/test_config.c $(LIB) -o $@
test: test_config
	./test_config
clean:
	rm -f config_dump test_config *.o
print-lib:
	@printf '%s\n' $(LIB)
