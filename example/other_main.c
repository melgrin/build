#include "GenIncGenSrc.h"
#include "C.h"
#include "GenIncGen2.h"

int main() {
    C c;
    c.c = 'X';
    printC(&c);
    printGenIncGenSrc();
    GenIncGen2 g2;
    g2.y = 45;
    Gen g;
    g.x = 77;
    return 0;
}
