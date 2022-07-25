#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
#include <string>
#include <sstream>
#include <regex>

#include "build.cpp"

#define ARRAY_LENGTH(X) (sizeof(X)/sizeof((X)[0]))

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
            Build::Entry* e = Build::get(name);
            // ventures are expected to fail sometimes
            if (e && !e->isVenture) {
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

set<string> replaceExt(const set<string>& in, const char* find, const char* replace) {
    set<string> out;
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
    Build::Entry* e = Build::get(name);
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

void _findIncludes(const string& filename, set<string>* incs, const regex& pattern, match_results<const char*>& matches, int* depth, set<string>* seen, const char* debugRootFile, int serial, char* lineTextBuf, size_t lineTextLen) {

    if (seen->find(filename) == seen->end()) {
        seen->insert(filename);
        printDebug("seen", "[serial %] first time seeing % (under %)\n", serial, filename, debugRootFile);
    } else {
        printDebug("seen", "[serial %] have already seen % (under %), not searching it for includes\n", serial, filename, debugRootFile);
        return;
    }

    static const int MAX_DEPTH = 1000;
    (*depth) += 1;
    if (*depth > MAX_DEPTH) {
        printError("runaway recursion in 'findIncludes' function - nested more than % times - serial % - seen has % entries: %", MAX_DEPTH, serial, seen->size(), *seen);
        exit(EXIT_FAILURE);
    }

    set<string> local;
    if (FILE* fp = fopen(filename.c_str(), "r")) {
        int status;
        unsigned int lineNumber = 0;
        while (1) {
            ++lineNumber;
            fgets(lineTextBuf, lineTextLen, fp);
            if (feof(fp)) break;
            if (ferror(fp)) {
                printError("fgets failed on line % of file %", lineNumber, filename);
            } else {

                if (regex_match(lineTextBuf, matches, pattern)) {
                    assert(matches.size() > 1); // full + capture group
                    string s = matches[1].str();
                    printDebug("regex_match", "matched on line % of file %: include file = %, full line text = %\n", lineNumber, filename, s, lineTextBuf);
                    bool added = local.insert(s).second;
                    if (!added) {
                        printDebug("test", "[serial %] % was not inserted for % (depth %, base = %)\n", serial, s, filename, *depth, debugRootFile);
                    }
                }
            }
        }

        fclose(fp);
       
        printDebug("findIncludes", "% += %\n", filename, local);
        fora (s, local) {
            incs->insert(s); // TODO if it's already in the map, do I need to check it again?  or I guess 'seen' covers that more completely anyway
            if (/*!contains(*seen, s)*/ seen->find(s) == seen->end() && // XXX do I need this twice?  see entry of this function
                Build::fileExists(s)) {
                   
                _findIncludes(s, incs, pattern, matches, depth, seen, debugRootFile, serial,
                    //matches, matchesLen,
                    lineTextBuf  , lineTextLen);
            }
        }

    } else {
        printError("failed to open %: %", filename, strerror(errno));
    }
   
    (*depth) -= 1;
}

void findIncludes(const string& filename, set<string>* incs) {
    static int serial = 0;
    ++serial;

    const regex pattern("^\\s*#\\s*include\\s*\"(.+)\"\\s*\n$");
    match_results<const char*> matches;
    char lineTextBuf[256];
    int depth = 0;
    set<string> seen;

    _findIncludes(filename, incs, pattern, matches, &depth, &seen, filename.c_str(), serial, lineTextBuf, ARRAY_LENGTH(lineTextBuf));

    printDebug("findIncs", "[serial %] % includes %\n", serial, filename, *incs);
}

Build::GenerationFunction determineGenerationFunction(const string& name) {
    Build::GenerationFunction fn;
    if (endsWith(name, EXT_HDR)) {
        //TODO not all .h can be generated in this example - look for 'Gen' in name
        fn = &generateInc;
    } else if (endsWith(name, EXT_SRC)) {
        //TODO not all .c can be generated in this example - look for 'Gen' in name
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

set<string> determineDepsForObj(const string& target) {
    string base = Build::getBase(target);
    set<string> deps;
    string src = base + EXT_SRC;
    deps.insert(src);
    // Is this the right spot to have this?
    if (Build::fileExists(src)) { // might be generated
        set<string> incs;
        findIncludes(src, &incs);
        forc (it, incs) { deps.insert(it); }
    }
    return deps;
}

set<string> determineDepsForSrc(const string& target) {
    // nothing now, maybe something for .idl
    set<string> deps;
    return deps;
}

set<string> determineDepsForHdr(const string& target) {
    // nothing now, maybe something for .idl
    set<string> deps;
    return deps;
}

static void makeEntryString(set<string>* out, Build::Map const& in) {
    out->clear();
    static const char genstring[] = {'?', '!', '.'};
    char buf[128];
    for (Build::Map::const_iterator i = in.begin(); i != in.end(); ++i) {
        snprintf(buf, sizeof buf, "%-20s  %c  %c", i->first.c_str(), genstring[i->second->generationResult+1], i->second->isVenture?'v':' ');
        out->insert(string(buf));
    }
}

static void writeToFile(int iteration, int loop, const char* detail, const set<string>& s) {
    static int serial = 0;
    ++serial;
    char filename[64];
    snprintf(filename, sizeof filename, "looptest_%d_%d_%d_%s.txt", serial, iteration, loop, detail);
    FILE* file = fopen(filename, "w");
    if (file) {
        fprintf(file, "%s\n", filename);
        for (set<string>::const_iterator i = s.begin(); i != s.end(); ++i) {
            fprintf(file, "%s\n", i->c_str());
        }
        fprintf(file, "%llu entries\n", s.size());
        fclose(file);
    }
}

set<string> determineDepsForExe(const string& target) {
    string base = Build::getBase(target);
    set<string> deps;
    deps.insert(base + EXT_OBJ);

    // Just saying that an exe depends on all known objects.

    set<string> allObjs;
    forc (it, Build::getAll()) {
        char* _disp = 0;
        // a user-defined file type enum (OBJ, SRC, EXE) that's stored in the Entry might help here
        if (endsWith(it.first, EXT_OBJ)) {
            // do not (re)add previously-failed ventures to exe deps
            if (it.second->isVenture) {
                if (it.second->generationResult != Build::GEN_FAIL) {
                    allObjs.insert(it.first);
                    _disp = "non-failed venture";
                } else {
                    printDebug("venture", "ignoring previously-failed venture %\n", it.first);
                    _disp = "previously-failed venture";
                }
            } else {
                allObjs.insert(it.first);
                _disp = "regular object (not a venture)";
            }
        }

        //if (_disp) { printDebug("extra", "% -- %\n", _disp, it.first.c_str()); }
    }

    Build::addDependsOn(target, allObjs);
    forc (i, allObjs) { Build::addDependants(i, set<string>{target}); }

    {
        set<string> sBefore;
        set<string> sAfter;
        makeEntryString(&sBefore, Build::getAll());
        size_t nBefore = Build::getAll().size();
        size_t nAfter;
        int loop = 0;
        while (1) {
            if (loop++ > 1000) {
                printError("runaway looptest");
                break;
            }
           
            set<string> existing;
            set<string> ventures;
           
            forc (it, Build::getAll()) {
                if (endsWith(it.first, EXT_HDR)) {
                    
                    string name = it.first;
                    replaceExt(name, EXT_HDR, EXT_SRC); // genChain->next
                    bool exists = Build::fileExists(name);
                    if (exists) {
                        printDebug("exedeps", "% already exists - adding to known existing list\n", name);
                        existing.insert(name);
                    } else if (hasGenerationFunction(name)) {
                        printDebug("exedeps", "% does not exist, but it has a generation function - adding to venture list\n", name);
                        ventures.insert(name);
                    } else {
                        printDebug("exedeps", "% does not exist and does not have a generation function - ignoring\n", name);
                    }
                }
            }

            set<string> objs = replaceExt(existing, EXT_SRC, EXT_OBJ);
            printDebug("existing", "adding % objs that have existing srcs: %\n", objs.size(), objs);
            forc (it, objs) {
                Build::addIfMissing(it);
                deps.insert(it);
            }

            printDebug("venture", "adding % src ventures: %\n", ventures.size(), ventures);
            forc (it, ventures) {
                if (!Build::get(it)) {
                    Build::Entry* e = Build::add(it);
                    e->isVenture = true;
                }
            }
            objs = replaceExt(ventures, EXT_SRC, EXT_OBJ);
            printDebug("venture", "adding % obj ventures: %\n", objs.size(), objs);
            forc (it, objs) {
                if (!Build::get(it)) {
                    Build::Entry* e = Build::add(it);
                    e->isVenture = true;
                }
                // todo? adding these venture objs to 'deps' causes premature exe generation attempt
            }

            nAfter = Build::getAll().size();
            printDebug("looptest", "target %, loop %, nBefore = %, nAfter = %\n", target, loop, nBefore, nAfter);
            if (nBefore == nAfter) {
                break;
            } else {
                nBefore = nAfter;

                makeEntryString(&sAfter, Build::getAll());
                writeToFile(Build::getIteration(), loop, "before", sBefore);
                writeToFile(Build::getIteration(), loop, "after", sAfter);
                makeEntryString(&sBefore, Build::getAll());
            }
        }
    }

    return deps;
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
        char* arg = argv[i];
        if (arg && strlen(arg) > 1 && arg[0] == '-' && arg[1] == 'd') {
            if (i < argc-1) {
                ++i;
                Build::loadDebug(argv[i]);
            } else {
                printError("option '-d' needs an argument");
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
            // only to catch exceptions potentially thrown by C++ stdlib
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

