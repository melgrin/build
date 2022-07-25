# build

A tool combining dependency lookup and dependency generation.

C++ only.

Test project!

### Description

At its core, this program is kind of like `make`.  Each file (target) has a list of dependencies and a function that will be used to generate the file when all the dependencies exist, or if any of the dependencies are newer than the target file.

The biggest difference is that this program performs more extensive dependency lookup and management.  You pass an `.exe` target, and it assumes there's a matching `.c` file with the main routine in it.  From there, it finds all the `.h` files recursively `#include`d by the main `.c` file.  If at any point an `#include`d `.h` file does not exist, it will still be added as a dependency, but with a "venture" flag set.  Ventures are the same as regular dependencies, but will be cleanly removed from a file's dependency list without raising an error if generation fails.

For every `.h` that's #included, it may or may not exist.  If it does not exist, it might be a file that needs to be generated, or it might be user error.  If there's a rule that can generate it, do so.  After it is generated, it must also be checked for #includes.  Repeat on those includes.

For every `.h` that exists, there might a corresponding `.c` file.  These are also added as ventures, so the rule of "generate if possible" applies here the same as it does with `.h` files.  

The original `.exe` target depends on every `.o` file that is generated from `.c` files.

`g++ -M` or `g++ -MM` options already do some of this.  But I wanted something that would reparse the includes in a file after the file was generated.  On a project I worked on, we commonly generated `.h` and `.c` files from `.idl` files, and those files in turn `#include`d other generated files.  Perhaps there's a way to do it with `g++ -MM` and `make`, but in my experience this approach becomes convoluted very quickly.

This is more of an experiment than a full solution.  I still need to figure out how I want to separate the core build logic from the user code, if at all.  The user is expected to write C++ code that provides dependency and generation functions custom to their project, much like what's in `build_c.cpp`.

You could say "no project should be so big or convoluted that it can't be rebuilt every time or easily handled by a few wildcard rules in make."  While I agree with this sentiment, I had a lot of time to think about how I would approach this problem while waiting for `make` to crawl through dozens of makefiles only to inevitably produce a link error.  So I gave it a go, and this is the result.  I'm far from 100% confident in it, as I've had limited opportunities to test it out.  C++20 has added "modules" which look like a promising alternative to `.h` files; hopefully I won't need this at all, and it will have just been an interesting side project.

### Example

1. `compile.bat`
2. `cd example`
3. `..\build_c main.exe`

Run with `-d all` for debug logs.  The `looptest*.txt` files that are generated in the local directory also give some insight into the inner workings of the program.

### Notes

- This was written on Windows.  For this to work as is, you will need to have MSVC compiler and linker (cl.exe and link.exe).  I run `...\Visual Studio\VC\Auxiliary\Build\vcvarsall.bat x64` to set up my environment.
- This started as a Perl project -- see `old/`.  When the project grew beyond a few hundred lines, I started to sorely miss typechecking and switched to C++, as usual.  It does still miraculously seem to work (`cd example; ..\old\build.pl main.exe`), though it is missing many critical logic updates and bug fixes that have since been added to the C++ version.
- In the example project, "generated" source code is just copied in from the "gen" subdirectory.  In reality it would be generated by some other utility, like an IDL to C++ compiler.
