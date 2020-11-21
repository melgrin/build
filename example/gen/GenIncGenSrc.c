#include "GenIncGenSrc.h"
#include "NovelGen.h"
#include <stdio.h>
void printGenIncGenSrc() {
    NovelGen g;
    g.x = 5775;
    printf("GenIncGenSrc: NovelGen = %d\n", g.x);
    printNovel();
    printNovelDepGen();
}
