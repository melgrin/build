#include "A.h"
#include "H.h"
#include "GenIncGen.h"
#include "GenIncGenSrc.h"
int main(int argc, char** argv) {
    printf("%s, xx compiled %s %s\n", argv[0], __DATE__, __TIME__);
    A a;
    a.x = 99;
    a.c.c = 'Z';
    printA(&a);
    H h;
    h.x = 55;
    printf("H = %d\n", h.x);
    printGenIncGenSrc();
    printNovelDepGen();
    return 0;
}
