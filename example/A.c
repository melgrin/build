#include <stdio.h>
#include "A.h"
#include "B.h"
void printA(A* a) {
	printf("A.x = %d, A.c.c = %c\n", a->x, a->c.c);
	B b;
	b.f = 123.456;
	printB(&b);
}
