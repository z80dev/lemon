#ifndef CONFIG_H
#define CONFIG_H
#include <stddef.h>
typedef struct { char *key; char *value; } cfg_entry;
typedef struct { cfg_entry *entries; size_t count, capacity; } cfg;
void cfg_init(cfg *c);
void cfg_free(cfg *c);
const char *cfg_get(const cfg *c, const char *key);
int cfg_parse(cfg *c, const char *text, size_t length, size_t *error_line);
#endif
