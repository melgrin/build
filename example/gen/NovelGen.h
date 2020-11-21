#ifndef NovelGen_h
#define NovelGen_h
#include "NovelDepGen.h"
typedef struct { int x; } NovelGen;
void printNovel() {
    NovelDepGen x;
    x.x = 99;
    printf("NovelGen: NovelDepGen = %d\n", x.x);
}
#endif
