#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
#include <string>
#include <sstream>
#include <regex>

// XXX multiply defined symbols...?
//#include "build.h"
#include "build.cpp"

using namespace std;

const char* EXT_HDR = ".h";
const char* EXT_OBJ = ".o";
const char* EXT_SRC = ".c";
const char* EXT_EXE = ".exe";
const char* EXT_ENUM = ".enum";

bool copyWholeFile(const string& source, const string& destination) {
    
    errno = 0;

    bool success = true;
    FILE* src = 0;
    FILE* dest = 0;
    void* buf = 0;

    src = fopen(source.c_str(), "rb");
    if (!src) {
        printDebug("copy","failed to open %: %\n", source, strerror(errno));
        success = false;
        goto end;
    }

    // This intentionally overwrites the old one if it exists.
    // Mainly this is to update the file time; filesystem::copy_file
    // was conveniently preserving the source's time, which defeats the
    // dependency age check.
    dest = fopen(destination.c_str(), "wb");
    if (!dest) {
        printDebug("copy","failed to open %: %\n", destination, strerror(errno));
        success = false;
        goto end;
    }

    if (fseek(src, 0, SEEK_END)) {
        printDebug("copy","% seek to end failed: %\n", source, strerror(errno));
        success = false;
        goto end;
    }
    const long int size = ftell(src);
    if (-1 == size) {
        printDebug("copy","% ftell failed: %\n", source, strerror(errno));
        success = false;
        goto end;
    }
    if (fseek(src, 0, SEEK_SET)) {
        printDebug("copy","% seek to beginning failed: %\n", source, strerror(errno));
        success = false;
        goto end;
    }

    buf = malloc(size);
    if (buf == 0) {
        printDebug("copy","failed to allocate %-byte file copy buffer", size);
        success = false;
        goto end;
    }

    size_t numRead = fread(buf, 1, size, src);
    if (numRead != size) {
        assert(!feof(src));
        assert(ferror(src));
        printDebug("copy","failed to read file %: %\n", source, strerror(errno));
        success = false;
        goto end;
    }

    size_t numWritten = fwrite(buf, 1, size, dest);
    if (numWritten != size) {
        assert(ferror(dest));
        printDebug("copy","failed to write to file %: %\n", destination, strerror(errno));
        success = false;
        goto end;
    }

    success = true;

end:
    if (src) fclose(src);
    if (dest) fclose(dest);
    if (buf) free(buf);
    return success;

    //error_code err;
    //bool success = filesystem::copy_file(from, to, err);
}

bool _copy_gen(const string& name) {
    string from = "gen/" + name;
    string to = name;
    bool success = copyWholeFile(from, to);
    if (success) {
        printDebug("cmd", "copy(%, %)\n", from, to);
    } else {
        if (Build::debugEnabled("cmd")) {
            Build::Map::const_iterator i = Build::ALL.find(name);
            // ventures are expected to fail sometimes
            if (i != Build::ALL.end() && !i->second->isVenture) {
                printDebug("cmd", "failed copy(%, %)\n", from, to);
            }
        }
    }
    return success;
}

void removeCharacter(char* s, char c) {
    char* x = s;
    do {
        while (*x == c) {
            ++x;
        }
    } while (*s++ = *x++);
}

bool endsWith(const std::string& s, const char* match) {
    const char* sub = s.c_str();
    sub += strlen(sub);
    sub -= strlen(match);
    return 0 == strcmp(sub, match);
}

void replaceExt(string& s, const char* find, const char* replace) {
    s.replace(s.rfind(find), strlen(find), replace);
}

Set<string> replaceExt(const Set<string>& in, const char* find, const char* replace) {
    Set<string> out;
    //todo - investigate auto&& vs modifying
    fora (i, in) {
        string s(i);
        replaceExt(s, find, replace);
        out.insert(s);
    }
    return out;
}

bool generateInc(const string& name) {
    return _copy_gen(name);
}

bool generateSrc(const string& name) {
    return _copy_gen(name);
}

bool generateObj(const string& name) {
    string src = Build::getBase(name) + EXT_SRC;
    // This should not happen if the src doesn't exist.  If the src was a venture it should have failed generation and have been withdrawn already, along with its associated dependants.
    bool exists = Build::fileExists(src);
    assert(exists);
    if (!exists) {
        printError("src for obj % does not exist", name);
        //Build::Map::iterator i = Build::ALL.find(name);
        //if (i != Build::ALL.end()) {
        //    Build::Entry* e = i->second;
        //    int bp = 0;
        //}
        return false;
    }

    ostringstream cmd;
    cmd << "cl /nologo /c /Fo" << name << " " << src;
    printDebug("cmd","%\n", cmd.str());
    tprintf("cl: "); // cl always prints the filename, so at least present it with some context...
    if (system(cmd.str().c_str())) {
        printError("generateObj: command failed: '%'", cmd.str());
        return false;
    }
    return true;
}

bool generateExe(const string& name) {
    Build::Entry* e = Build::ALL[name]; // todo? avoid grabbing from global?
    ostringstream cmd;
    cmd << "link /nologo /OUT:" << name;
    forc (it, e->dependsOn) { cmd << " " << it->name; }
    printDebug("cmd","%\n", cmd.str());
    if (system(cmd.str().c_str())) {
        printError("generateExe: command failed: '%'", cmd.str());
        return false;
    }
    return true;
}

bool hasGenerationFunction(const string& name) {
    return endsWith(name, EXT_HDR)
        || endsWith(name, EXT_SRC)
        || endsWith(name, EXT_OBJ)
        || endsWith(name, EXT_EXE)
        ;
}

// the char*s in the incs set are newly allocated by this function
void _findIncludes(const char* name, Set<char*>* incs) {
    Set<char*> local;
    {
        FILE* fp = fopen(name, "r");
        if (!fp) {
            printError("failed to open %: %", name, strerror(errno));
            return;
        }

        // can't do this without extra logic for handling failure to get library headers, like stdio.h
        //regex pattern("#\\s*include\\s+[<\"](.+)[>\"]\\s*\n");

        // at least for now, assume that files we want to look at are double-quoted,
        // and files we don't want to look at are angle-bracketed
        regex pattern("#\\s*include\\s+\"(.+)\"\\s*\n");

        char buf[128];
        while (1) {
            fgets(buf, sizeof(buf), fp);
            if (feof(fp)) break;
            if (ferror(fp)) {
                printError("fgets failed");
            } else {
                match_results<const char*> matches;
                //printDebug("findIncsLine", "%", buf);
                if (regex_match(buf, matches, pattern)) {
                    //printDebug("findIncsMatch", "% includes %\n", name, match[1]);
                    // there are no match_results/regex_match overloads that allow non-const,
                    // and apparently unordered_set::find can't handle const char* when it contains just char*
                    // and char* match = const_cast<char*>(matches[1].str().c_str()) was returning an empty string
                    // so just copy it back out into buf so it's actually usable
                    strncpy(buf, matches[1].str().c_str(), sizeof(buf)); 
                    if (local.find(buf) == local.end()) {
                        size_t n = strlen(buf) + 1; // + 1 for null
                        char* s = (char*) malloc(n); // leak
                        memcpy(s, buf, n);
                        bool added = local.insert(s).second;
                        assert(added);
                    }
                }
            }
        }

        fclose(fp);
    }
    printDebug("findIncludes", "% += %\n", name, local);
    fora (it, local) {
        incs->insert(it);
        if (Build::fileExists(it)) {
            _findIncludes(it, incs);
        }
    }
}

Set<char*> findIncludes(const string& name) {
    Set<char*> incs;
    _findIncludes(name.c_str(), &incs);
    /*if (incs.size() > 0) {*/ printDebug("findIncs", "% includes %\n", name, incs); //}
    return incs;
}

Build::GenerationFunction determineGenerationFunction(const string& name) {
    Build::GenerationFunction fn;
    if (endsWith(name, EXT_HDR)) {
        fn = &generateInc;
    } else if (endsWith(name, EXT_SRC)) {
        fn = &generateSrc;
    } else if (endsWith(name, EXT_OBJ)) {
        fn = &generateObj;
    } else if (endsWith(name, EXT_EXE)) {
        fn = &generateExe;
    } else {
        printError("Don't know how to generate file '%'", name);
        exit(EXIT_FAILURE);
        //fn = 0;
    }
    return fn;
}

Set<string> determineDepsForObj(const string& target) {
    string base = Build::getBase(target);
    Set<string> deps;
    string src = base + EXT_SRC;
    deps.insert(src);
    // Is this the right spot to have this?
    if (Build::fileExists(src)) { // might be generated
        Set<char*> incs = findIncludes(src);
        forc (it, incs) { deps.insert(it); }
    }
    return deps;
}

Set<string> determineDepsForSrc(const string& target) {
    // nothing now, maybe something for .idl
    Set<string> deps;
    return deps;
}

Set<string> determineDepsForHdr(const string& target) {
    // nothing now, maybe something for .idl
    Set<string> deps;
    return deps;
}

Set<string> determineDepsForExe(const string& target) {
    string base = Build::getBase(target);
    Set<string> deps;
    deps.insert(base + EXT_OBJ);

    // Just saying that an exe depends on all known objects.  To make it equivalent to the original logic in main build loop, would just need to add "if (BUILD->target0 == target) {" (where target0 is the top-level original target passed to build (like type0))

    // This could be optimized to not look through everything in ALL (user hook when a new Build::Entry is added to ALL)

    //if (type0 == TYPE_EXE) {
    Set<string> allObjs;
    forc (it, Build::ALL) {
        // might want to add file extension into the entry, though won't work for exes.  maybe ask user code to provide an integer for the type when adding it.  then the user doesn't have to strcmp every time later like this.
        if (endsWith(it.first, EXT_OBJ)) {
            // do not (re)add previously-failed ventures to exe deps
            if (it.second->isVenture) {
                if (it.second->generationResult != Build::GEN_FAIL) {
                    allObjs.insert(it.first);
                } else {
                    printDebug("venture", "ignoring previously-failed venture %\n", it.first);
                }
            } else {
                allObjs.insert(it.first);
            }
        }
    }

    Build::addDependsOn(target, allObjs);
    forc (i, allObjs) { Build::addDependants(i, Set<string>{target}); }

    forc (i, allObjs) {
        Build::Entry* e = Build::ALL[i];
        if (e->isVenture) {
            // XXX 2022-01-21 - kind of confused about this
            fora (d, e->dependsOn) {
                d->isVenture = true;
            }
        }
    }

    // ventures
    {
        Set<string> existing;
        Set<string> ventures;
        forc (it, Build::ALL) {
            if (endsWith(it.first, EXT_HDR)) {
                string name = it.first;
                replaceExt(name, EXT_HDR, EXT_SRC); // genChain->next
                if (Build::ALL.find(name) == Build::ALL.end()) {
                    bool exists = Build::fileExists(name);
                    if (exists) {
                        printDebug("existing", "% is not known but already exists\n", name);
                        existing.insert(name);
                    } else if (hasGenerationFunction(name)) {
                        printDebug("ld", "% is not known and does not exist, but it has a generation function\n", name);
                        ventures.insert(name);
                    } else {
                        printDebug("ld", "% is not known and does not exist and does not have a generation function\n", name);
                    }
                }
            }
        }

        if (existing.size() > 0) {
            Set<string> objs = replaceExt(existing, EXT_SRC, EXT_OBJ);
            printDebug("existing", "adding % objs that have existing srcs: %\n", objs.size(), objs);
            forc (it, objs) { Build::add(it); }
        }
        if (ventures.size() > 0) {
            printDebug("venture", "adding % src venture%: %\n", ventures.size(), ventures.size()==1?"":"s", ventures);
            forc (it, ventures) { Build::add(it); }
            forc (it, ventures) { Build::ALL[it]->isVenture = true; }
            Set<string> objs = replaceExt(ventures, EXT_SRC, EXT_OBJ);
            printDebug("venture", "adding % obj venture%: %\n", objs.size(), objs.size()==1?"":"s", objs);
            forc (it, objs) { Build::add(it); }
            forc (it, objs) { Build::ALL[it]->isVenture = true; }
        }
        //if (existing.size() == 0 && ventures.size() == 0) {
        //    printDebug("ld", "done\n");
        //    doneLD = true;
        //}
    }


    return deps; // XXX seems like I should be adding more of the above to this, instead of going to ALL directly
}

Build::DependencyFunction determineDependencyFunction(const string& name) {
    Build::DependencyFunction fn;
    if (endsWith(name, EXT_HDR)) {
        fn = &determineDepsForHdr;
    } else if (endsWith(name, EXT_SRC)) {
        fn = &determineDepsForSrc;
    } else if (endsWith(name, EXT_OBJ)) {
        fn = &determineDepsForObj;
    } else if (endsWith(name, EXT_EXE)) {
        fn = &determineDepsForExe;
    } else {
        printError("Don't have a dependency determination function for file '%'", name);
        exit(EXIT_FAILURE);
        //fn = 0;
    }
    return fn;
}

int main(int argc, char** argv) {
    
    int i;
    for (i = 1; i < argc; ++i) {
        if (argv[i][0] == '-') {
            if (argv[i][1] == 'd') {
                ++i;
                Build::loadDebug(argv[i]);
            }
        } else {
            break;
        }
    }
    
    Build::UserCode userCode;
    userCode.getGenerationFunction = &determineGenerationFunction;
    userCode.getDependencyFunction = &determineDependencyFunction;

    for (; i < argc; ++i) {
        try {
            Build::run(argv[i], &userCode);
        } catch (const exception& e) {
            printError("caught exception during % generation: %",
                    argv[i], e.what());
        }
    }
    return 0;
}

/*
   %.h: %.enum; genEnum %^
*/
/*
    MyEnum:A=7,B=12,C=-1
*/
/*
 Test1 : A=7, B   =1   2, C=-1
   Test2 : D=7, E =45   2, F=-100
*/
/*
bool generateEnumHeader(const string& filename) {

    string source = filename;
    replaceExt(source, EXT_HDR, EXT_ENUM);

    string includeGuard = filename;
    replaceExt(includeGuard, EXT_HDR, "_h");

    FILE* fp;

    fp = fopen(source.c_str(), "r");
    if (!fp) {
        printError("failed to open %: %", source, strerror(errno));
        return false;
    }

    // this feels dumb
    char line[1024] = {0};
    char name[128] = {0};
    // this should probably be significantly larger than the line buffer
    char out[1024] = {0};
    char* o = out;

    while (1) {
        fgets(line, sizeof(line), fp);
        if (feof(fp)) break;
        if (ferror(fp)) {
            printError("fgets failed while reading %: %", source, strerror(errno));
            fclose(fp);
            return false;
        }

        removeCharacter(line, ' ');
        removeCharacter(line, '\n');
        removeCharacter(line, '\t');
        
        size_t span = strcspn(line, ":");
        memcpy(name, line, span);
        name[span+1] = '\0';

        char* body = line;
        body += span+1;

        sprintf(o, "enum %s { %s };\n", name, body);

        o += strlen(out);
    }

    fclose(fp);

    fp = fopen(filename.c_str(), "w");
    if (!fp) {
        printError("failed to open %: %", filename, strerror(errno));
        return false;
    }

    fprintf(fp,
        "#ifndef %s\n"
        "#define %s\n"
        "\n%s\n"
        "#endif // %s\n"
        "\n",
        includeGuard.c_str(),
        includeGuard.c_str(),
        out,
        includeGuard.c_str());

    fclose(fp);

    return true;
}
*/

/*
int main() {

    try {
        generateEnumHeader("Test.h"); // this is unintuitive - how will I know which header files are from enums? Similar to the issue of %C.h being TAO client or just a filename that happens to end with a capital C.
    } catch (const std::exception& e) {
        std::cerr << e.what() << std::endl;
        return 1;
    }

    return 0;
}
*/

