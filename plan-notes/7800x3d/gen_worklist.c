#include <stdio.h>
#include "Mlucas.h"
static int isprime(uint64 n){
    if(n<2) return 0;
    if(n%2==0) return n==2;
    for(uint64 d=3; d*d<=n; d+=2) if(n%d==0) return 0;
    return 1;
}
int main(int argc,char**argv){
    double margin = argc>1 ? atof(argv[1]) : 0.95;
    uint32 nrad, rvec[16]; long long tot=0; int lens=0;
    printf("# kblocks nradsets pmax_rec p_test odd_part\n");
    for(uint32 k=1; k<=524288; k++){
        if(get_fft_radices(k,0,&nrad,rvec,16) != 0) continue;
        int n=0; for(int rs=0; rs<20 && get_fft_radices(k,rs,&nrad,rvec,16)==0; rs++) n++;
        if(!n) continue;
        uint64 pmax = given_N_get_maxP((uint64)k<<10);
        uint64 p = (uint64)(pmax*margin); if(!(p&1)) p--;
        while(p>3 && !isprime(p)) p-=2;
        uint32 odd=k; while(odd%2==0) odd/=2;
        printf("%u %d %llu %llu %u\n", k, n,(unsigned long long)pmax,(unsigned long long)p, odd);
        lens++; tot+=n;
    }
    fprintf(stderr,"lengths=%d radixsets=%lld margin=%.2f\n",lens,tot,margin);
    return 0;
}
