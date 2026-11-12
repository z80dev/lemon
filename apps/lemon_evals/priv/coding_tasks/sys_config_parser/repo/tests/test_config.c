#include "config.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
int main(void) {
    cfg c; cfg_init(&c); size_t line=99;
    const char *text="host=local\npath=one\\#two # comment\nmessage=\"say \\\"hi\\\"\"\nhost=remote\n";
    assert(cfg_parse(&c,text,strlen(text),&line)==0 && line==0);
    assert(c.count==3 && !strcmp(c.entries[0].key,"host"));
    assert(!strcmp(cfg_get(&c,"host"),"remote"));
    assert(!strcmp(cfg_get(&c,"path"),"one#two"));
    assert(!strcmp(cfg_get(&c,"message"),"say \"hi\""));
    const char *bad="new=entry\ninvalid line\n";
    assert(cfg_parse(&c,bad,strlen(bad),&line)==-1 && line==2);
    assert(c.count==3 && !strcmp(cfg_get(&c,"host"),"remote"));
    cfg_free(&c); cfg_free(&c);
    puts("config tests passed");
}
