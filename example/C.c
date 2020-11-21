#include <stdio.h>
#include "C.h"
#include "Gen.h"
#include "OtherGen.h"
void printC(C* x) {
	Gen g;
	g.x = 45;
	printf("C.x = %c, Gen = %d\n", x->c, g.x);
}
