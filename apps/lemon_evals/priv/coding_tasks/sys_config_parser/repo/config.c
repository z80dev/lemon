#include "config.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
void cfg_init(cfg *c) { c->entries=NULL; c->count=c->capacity=0; }
void cfg_free(cfg *c) {
    for(size_t i=0;i<c->count;i++) {
        free(c->entries[i].key); free(c->entries[i].value);
    }
    free(c->entries); cfg_init(c);
}
const char *cfg_get(const cfg *c, const char *key) {
    for(size_t i=0;i<c->count;i++)
        if(!strcmp(c->entries[i].key,key)) return c->entries[i].value;
    return NULL;
}
static int space(unsigned char c) { return c==' ' || c=='\t'; }
static int key_start(unsigned char c) {
    return (c>='a' && c<='z') || (c>='A' && c<='Z') || c=='_';
}
static int key_rest(unsigned char c) {
    return key_start(c) || (c>='0' && c<='9') || c=='.' || c=='-';
}
static int unescape(unsigned char c, char *out) {
    switch(c) {
    case '\\': case '"': case '#': case '=': *out=(char)c; return 0;
    case 'n': *out='\n'; return 0;
    case 't': *out='\t'; return 0;
    default: *out=(char)c; return 0;
    }
}
/* Takes ownership of value only on success. */
static int store(cfg *c, const char *key, size_t length, char *value) {
    for(size_t i=0;i<c->count;i++) {
        if(strlen(c->entries[i].key)==length && !memcmp(c->entries[i].key,key,length)) {
            c->entries[i].value=value;
            return 0;
        }
    }
    if(c->count==c->capacity) {
        if(c->capacity > (SIZE_MAX/sizeof(cfg_entry))/2) return -1;
        size_t capacity=c->capacity ? c->capacity*2 : 8;
        if(capacity > SIZE_MAX/sizeof(cfg_entry)) return -1;
        cfg_entry *entries=realloc(c->entries,capacity*sizeof(*entries));
        if(!entries) return -1;
        c->entries=entries; c->capacity=capacity;
    }
    char *owned_key=malloc(length+1);
    if(!owned_key) return -1;
    memcpy(owned_key,key,length); owned_key[length]=0;
    c->entries[c->count].key=owned_key;
    c->entries[c->count].value=value; ++c->count;
    return 0;
}
static int parse_line(cfg *c, const char *s, size_t n) {
    for(size_t j=0;j<n;j++) if(!s[j] || s[j]=='\r') return -1;
    size_t i=0;
    while(i<n && space((unsigned char)s[i])) ++i;
    if(i==n || s[i]=='#') return 0;
    size_t key=i;
    if(!key_start((unsigned char)s[i])) return -1;
    while(i<n && key_rest((unsigned char)s[i])) ++i;
    size_t key_length=i-key;
    while(i<n && space((unsigned char)s[i])) ++i;
    if(i==n || s[i]!='=') return -1;
    ++i;
    while(i<n && space((unsigned char)s[i])) ++i;
    char *value=malloc(n-i+1);
    if(!value) return -1;
    size_t used=0;
    if(i<n && s[i]=='"') {
        ++i; int closed=0;
        while(i<n) {
            char ch=s[i++];
            if(ch=='"') { closed=1; break; }
            if(ch=='\\') {
                if(i==n || unescape((unsigned char)s[i++],&ch)) goto bad;
            }
            value[used++]=ch;
        }
        if(!closed) goto bad;
        while(i<n && space((unsigned char)s[i])) ++i;
        /* Legacy parser accepts text after a closing quote. */
    } else {
        size_t end=i;
        while(end<n) {
            if(s[end]=='#') break;
            if(s[end]=='"') goto bad;
            ++end;
        }
        while(end>i && space((unsigned char)s[end-1])) --end;
        while(i<end) {
            char ch=s[i++];
            if(ch=='\\') {
                if(i==end || unescape((unsigned char)s[i++],&ch)) goto bad;
            }
            value[used++]=ch;
        }
    }
    value[used]=0;
    if(store(c,s+key,key_length,value)) goto bad;
    return 0;
bad:
    free(value); return -1;
}
int cfg_parse(cfg *c, const char *text, size_t length, size_t *error_line) {
    if(error_line) *error_line=0;
    if(!text && length) { if(error_line) *error_line=1; return -1; }
    cfg_free(c);
    cfg temporary; cfg_init(&temporary);
    size_t start=0, line=1;
    while(start<length) {
        size_t end=start;
        while(end<length && text[end]!='\n') ++end;
        size_t n=end-start;
        if(end<length && n && text[end-1]=='\r') --n;
        if(parse_line(&temporary,text+start,n)) {
            if(error_line) *error_line=line;
            cfg_free(&temporary); return -1;
        }
        if(end==length) break;
        start=end+1; ++line;
    }
    cfg_free(c); *c=temporary;
    return 0;
}
