#debug: build.cpp build.h
#	cl /Z7 /EHsc /nologo /std:c++17 /DDEBUG $<
#
#release: build.cpp build.h
#	cl /EHsc /nologo /std:c++17 $<

build build.exe: build.cpp build.h
	cl /Z7 /EHsc /nologo /std:c++17 $(DEBUG) $<

clean:
	rm -f *.obj *.pdb *.exe *.ilk
