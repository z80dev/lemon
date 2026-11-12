#ifndef PACKET_INTERNAL_H
#define PACKET_INTERNAL_H
#include "packet.h"
/* Private allocation helper: creates payload storage plus a sentinel byte. */
packet *packet_create(unsigned char kind, size_t length);
#endif
