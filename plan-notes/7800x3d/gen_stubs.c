#include "Mlucas.h"
#include <stdlib.h>
char cbuf[STR_MAX_LEN*3], g_cstr[STR_MAX_LEN];
uint64 PMIN=0, PMAX=0;
uint32 trailz32(uint32 x){ return x ? (uint32)__builtin_ctz(x) : 32; }
uint32 leadz32(uint32 x){ return x ? (uint32)__builtin_clz(x) : 32; }
__attribute__((__noreturn__)) void ABORT(const char*a,const char*f,long l,const char*fn,const char*s){
    fprintf(stderr,"ABORT %s:%ld %s: %s\n",f,l,fn,s?s:a); exit(2);
}
