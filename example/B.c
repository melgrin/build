#include <stdio.h>
#include "B.h"
#include "G.h"
void printB(B* x) {
	G g;
	g.x = 777;
	printf("B.f = %f, G.x = %d\n", x->f, g.x);
}
