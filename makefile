build_cpp build_cpp.exe: build_cpp.cpp build.cpp build.h
	cl /Z7 /EHsc /nologo /std:c++17 /DDEBUG $<

clean:
	rm -f *.obj *.pdb *.exe *.ilk
