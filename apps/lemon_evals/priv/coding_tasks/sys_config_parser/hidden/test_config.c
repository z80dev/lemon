#include "config.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static void expect(const cfg *c, const char *key, const char *value) {
    const char *actual=cfg_get(c,key); assert(actual && !strcmp(actual,value));
}
static void reject(cfg *c, const char *text, size_t length, size_t expected) {
    size_t line=999;
    assert(cfg_parse(c,text,length,&line)==-1 && line==expected);
    assert(c->count==1); expect(c,"stable","kept");
}
int main(void) {
    cfg c; cfg_init(&c); size_t line=999;
    assert(cfg_parse(&c,NULL,0,&line)==0 && line==0 && c.count==0);
    assert(!cfg_get(&c,"absent"));
    const char *doc="# defaults\r\nhost = \"api#east\" # x\r\n"
        "path = one\\=two\\#three\\\\four\nquote = \"say \\\"hi\\\"\"\n"
        "spaced = \t x y \t # ignored\nempty =\nempty2=\"\"\n"
        "line = \"a\\nb\\tc\"\ntrim = \\tX\\t\nhost=last\n"
        "UPPER=yes\nupper=no\nraw= a=b=c\n"
        "_a.b-c9 = \\\"edge\\\"\n";
    char *owned=malloc(strlen(doc)); assert(owned); memcpy(owned,doc,strlen(doc));
    assert(cfg_parse(&c,owned,strlen(doc),&line)==0 && line==0);
    memset(owned,'?',strlen(doc)); free(owned);
    assert(c.count==12 && !strcmp(c.entries[0].key,"host"));
    expect(&c,"host","last"); expect(&c,"path","one=two#three\\four");
    expect(&c,"quote","say \"hi\""); expect(&c,"spaced","x y");
    expect(&c,"empty",""); expect(&c,"empty2","");
    expect(&c,"line","a\nb\tc"); expect(&c,"trim","\tX\t");
    expect(&c,"UPPER","yes"); expect(&c,"upper","no");
    expect(&c,"raw","a=b=c"); expect(&c,"_a.b-c9","\"edge\"");
    assert(!cfg_get(&c,"Host"));
    const char *extra="a=\"  x\t \"\nb=left#ignored \\\"\\q\nc=\\#\\=\\\\\\\"\\n\\t\nd=\"a=\\#b\"\n";
    assert(cfg_parse(&c,extra,strlen(extra),NULL)==0 && c.count==4);
    expect(&c,"a","  x\t "); expect(&c,"b","left");
    expect(&c,"c","#=\\\"\n\t"); expect(&c,"d","a=#b");
    assert(!cfg_get(&c,"host"));
    const char nonascii[]={'x','=','"',(char)0x80,(char)0xff,'"'};
    assert(cfg_parse(&c,nonascii,sizeof(nonascii),NULL)==0);
    assert((unsigned char)cfg_get(&c,"x")[0]==0x80 && (unsigned char)cfg_get(&c,"x")[1]==0xff);
    const char no_terminator[]={'x','=','o','k'};
    assert(cfg_parse(&c,no_terminator,sizeof(no_terminator),NULL)==0); expect(&c,"x","ok");
    const char *stable="stable=kept";
    assert(cfg_parse(&c,stable,strlen(stable),NULL)==0);
    const char *bad[]={"missing", "=empty", "1key=x", "a b=x", "\"key\"=x",
        "x=raw\"quote", "x=\"unterminated", "x=\"ok\"junk", "x=\\q", "x=\\",
        "x=\"\\q\"", "x=\"dangling\\", "x=y\r", "#comment\r", "x=one\vtwo\ninvalid", "x=ok\n=bad"};
    for(size_t i=0;i<sizeof(bad)/sizeof(bad[0]);i++)
        reject(&c,bad[i],strlen(bad[i]),i>=14?2:1);
    reject(&c,NULL,3,1);
    const char nul[]={'#','x',0,'y','\n'}; reject(&c,nul,sizeof(nul),1);
    const char nul2[]={'a','=','x','\n','b','=','"',0,'"'}; reject(&c,nul2,sizeof(nul2),2);
    const char cr[]="a=ok\r\nb=bad\rc=bad\n"; reject(&c,cr,sizeof(cr)-1,2);
    const char *multi="# good\r\n\r\na=ok\r\nq=\\z\r\n";
    reject(&c,multi,strlen(multi),4);
    assert(cfg_parse(&c,"a=x\nb=2\na=y\na=z",strlen("a=x\nb=2\na=y\na=z"),NULL)==0);
    assert(c.count==2 && !strcmp(c.entries[0].key,"a")); expect(&c,"a","z");
    /* Exercise growth, replacements, and long values without fixed line buffers. */
    size_t capacity=60000; char *large=malloc(capacity); assert(large); size_t used=0;
    for(int i=0;i<80;i++) used+=(size_t)snprintf(large+used,capacity-used,"key%d=value%d\n",i,i);
    used+=(size_t)snprintf(large+used,capacity-used,"long=\"");
    memset(large+used,'v',20000); used+=20000; large[used++]='"'; large[used++]='\n';
    for(int i=0;i<100;i++) used+=(size_t)snprintf(large+used,capacity-used,"key1=last%d\n",i);
    assert(cfg_parse(&c,large,used,NULL)==0 && c.count==81);
    assert(strlen(cfg_get(&c,"long"))==20000); expect(&c,"key1","last99"); free(large);
    assert(cfg_parse(&c," \t\n#comment \\\"\\q\r\n",strlen(" \t\n#comment \\\"\\q\r\n"),&line)==0 && line==0 && !c.count);
    assert(cfg_parse(&c,"",0,NULL)==0); cfg_free(&c); cfg_free(&c);
    puts("hidden config cases passed");
}
