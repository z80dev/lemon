#include "config.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
static void print_value(const char *value) {
    putchar('"');
    for(const unsigned char *p=(const unsigned char *)value;*p;p++) {
        switch(*p) {
        case '\\': fputs("\\\\",stdout); break;
        case '"': fputs("\\\"",stdout); break;
        case '\n': fputs("\\n",stdout); break;
        case '\t': fputs("\\t",stdout); break;
        default: putchar(*p); break;
        }
    }
    putchar('"');
}
int main(void) {
    size_t capacity=1024,length=0;
    char *input=malloc(capacity);
    if(!input) return 2;
    int ch;
    while((ch=getchar())!=EOF) {
        if(length==capacity) {
            if(capacity>SIZE_MAX/2) { free(input); return 2; }
            size_t next=capacity*2;
            char *grown=realloc(input,next);
            if(!grown) { free(input); return 2; }
            input=grown; capacity=next;
        }
        input[length++]=(char)ch;
    }
    if(ferror(stdin)) { free(input); return 2; }
    cfg c; cfg_init(&c); size_t line;
    int result=cfg_parse(&c,input,length,&line);
    free(input);
    if(result) { fprintf(stderr,"line %zu: invalid configuration\n",line); cfg_free(&c); return 1; }
    for(size_t i=0;i<c.count;i++) {
        printf("%s=",c.entries[i].key); print_value(c.entries[i].value); putchar('\n');
    }
    cfg_free(&c); return 0;
}
