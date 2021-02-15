#include "build.h"
#include <string>
#include <sstream>
#include <assert.h>
#include <filesystem>
#include <fstream>
#include <regex>
#include <sys/stat.h>

Map ALL;

string getBase(const string& name) {
    return name.substr(0, name.find_last_of('.'));
}

Type getType(const string& name) {

    string::size_type pos = name.find_last_of('.');
    if (pos == string::npos) {
        return EXE;
    }

    string ext = name.substr(pos, string::npos);
    assert(ext.length() > 0);

    For (c, ext) { toupper(c); }

    if (strcmp(HDR_EXT, ext.c_str()) == 0) return HDR;
    if (strcmp(SRC_EXT, ext.c_str()) == 0) return SRC;
    if (strcmp(OBJ_EXT, ext.c_str()) == 0) return OBJ;
    if (strcmp(EXE_EXT, ext.c_str()) == 0) return EXE;

    printError("unknown file extension '%' from '%'\n", ext, name);
    exit(EXIT_FAILURE);
}

void split(vector<string>& out, const string& s, char delimiter) {
    size_t last = 0;
    size_t next = 0;
    while ((next = s.find(delimiter, last)) != string::npos) {
        out.push_back(s.substr(last, next-last));
        //cout << s.substr(last, next-last) << endl;
        last = next + 1;
    }
    out.push_back(s.substr(last));
    //cout << s.substr(last) << endl;
}

bool DEBUG_CATEGORIES_ALL_ENABLED;
Set<string> DEBUG_CATEGORIES_ENABLED;
Set<string> DEBUG_CATEGORIES_DISABLED;

void loadDebug(const char* arg) {
    //tprintf("loadDebug: %\n", arg);
    DEBUG_CATEGORIES_ALL_ENABLED = false;
    vector<string> pieces;
    split(pieces, arg, ',');
    Forc (it, pieces) {
        if (it[0] == '-') {
            DEBUG_CATEGORIES_DISABLED.insert(it.substr(1));
        } else if (strcmp(it.c_str(), "all") == 0) {
            DEBUG_CATEGORIES_ALL_ENABLED = true;
        } else {
            DEBUG_CATEGORIES_ENABLED.insert(it);
        }
    }

    /*
    tprintf("all = %\nenabled = %\ndisabled = %\n",
            DEBUG_CATEGORIES_ALL_ENABLED,
            DEBUG_CATEGORIES_ENABLED,
            DEBUG_CATEGORIES_DISABLED);
    */
}

bool debugEnabled(const char* category) {
    bool enabled = false;
#ifdef DEBUG
    bool _enabled = DEBUG_CATEGORIES_ALL_ENABLED || (DEBUG_CATEGORIES_ENABLED.find(category) != DEBUG_CATEGORIES_ENABLED.end());
    bool _disabled = (DEBUG_CATEGORIES_DISABLED.find(category) != DEBUG_CATEGORIES_DISABLED.end());
    enabled = _enabled && !_disabled;
#endif
    return enabled;
}

time_t getFileModificationTime(const string& name) {
    /* chrono::time_point<TrivialClock> */
    /*
    filesystem::file_time_type tmp = filesystem::last_write_time(name);
    time_t t = tmp::clock::to_time_t(tmp);
    return t;
    */
    
//#ifdef (_WIN32)
    struct stat info;
    if (stat(name.c_str(), &info) != 0) {
        printError("%: %\n", name, strerror(errno));
        exit(EXIT_FAILURE);
    }
    return info.st_mtime;
}

bool generate(Entry* e) {
    const Name name = e->name;
    bool success = false;
    success = (*e->generationFunction)(name);
    if (success) {
        printDebug("gen","generated %\n", name);
        bool exists = fileExists(name);
        assert(exists);
        e->exists = exists;
        e->generationResult = SUCCESS;
        e->timestamp = getFileModificationTime(name);
    } else {
        printDebug("genfail","failed to generate %\n", name);
        e->generationResult = FAIL;
    }
    return success;
}

bool fileExists(const string& name) {
    return filesystem::is_regular_file(name);
}

Set<char*> findIncludes(const string& name) {
    Set<char*> incs;
    _findIncludes(name.c_str(), &incs);
    /*if (incs.size() > 0) {*/ printDebug("findIncs", "% includes %\n", name, incs); //}
    return incs;
}

// the char*s in the incs set are newly allocated by this function
void _findIncludes(const char* name, Set<char*>* incs) {
    Set<char*> local;
    {
        FILE* fp = fopen(name, "r");
        if (!fp) {
            printError("failed to open %: %\n", name, strerror(errno));
            return;
        }

        // can't do this without extra logic for handling failure to get library headers, like stdio.h
        //regex pattern("#\\s*include\\s+[<\"](.+)[>\"]\\s*\n");
        regex pattern("#\\s*include\\s+\"(.+)\"\\s*\n");

        char buf[128];
        while (1) {
            fgets(buf, sizeof(buf), fp);
            if (feof(fp)) break;
            if (ferror(fp)) {
                printError("fgets failed");
            } else {
                smatch match;
                string tmp(buf); // XXX there's a CharT* overload for regex_match according to tbe documentation, but it doesn't compile (?)
                //printDebug("findIncsLine", "%", buf);
                if (regex_match(tmp, match, pattern)) {
                    //printDebug("findIncsMatch", "% includes %\n", name, match[1]);
                    strncpy(buf, match[1].str().c_str(), sizeof(buf)); // some const& compiler errors I don't understsand is going on with this, so just copy out
                    if (local.find(buf) == local.end()) {
                        size_t n = strlen(buf) + 1; // + 1 for null
                        char* s = (char*) malloc(n); // XXX leak
                        memcpy(s, buf, n);
                        bool added = local.insert(s).second;
                        assert(added);
                    }
                }
            }
        }

        fclose(fp);

        /*
        string line;
        const size_t len = 128;
        char debug[len];
        while (getline(in, line)) {
            strncpy(debug, line.c_str(), len);
            debug[len-1] = '\0';
            if (regex_match(line, match, pattern)) {
                local.insert(match[1]);
            }
        }
        */
    }
    printDebug("findIncludes", "% += %\n", name, local);
    For (it, local) {
        incs->insert(it);
        if (fileExists(it)) {
            _findIncludes(it, incs);
        }
    }
}

Set<Name> determineDeps(const Name& target) {
    string base = getBase(target);
    Type type = getType(target);
    Set<Name> deps;
    if (type == OBJ) {
        string src = base + SRC_EXT;
        deps.insert(src);
        if (fileExists(src)) { // might be generated
            Set<char*> incs = findIncludes(src);
            Forc (it, incs) { deps.insert(it); }
        }
    } else if (type == HDR) {
        // nothing now, maybe something for .idl
    } else if (type == SRC) {
        // nothing now, maybe something for .idl
    } else if (type == EXE) {
        deps.insert(base + OBJ_EXT); // maybe also want to search ALL
    } else {
        printError("incomplete for % files (target = %)\n", type, target);
        exit(EXIT_FAILURE);
    }
    if (deps.size() > 0) {
        printDebug("detDeps","%: %\n", target, deps);
    }
    return deps;
}

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
        printDebug("cmd", "failed copy(%, %)\n", from, to);
    }
    return success;
}

bool generateInc(const string& name) {
    return _copy_gen(name);
}

bool generateSrc(const string& name) {
    return _copy_gen(name);
}

bool generateObj(const string& name) {
    string src = getBase(name) + SRC_EXT;
    if (!fileExists(src)) {
        printError("src for obj % does not exist\n", name);
        return false;
    }

    ostringstream cmd;
    //cmd << "cl /nologo /c /Fo" << name << " " << src << " > /dev/null";
    cmd << "cl /nologo /c /Fo" << name << " " << src;
    printDebug("cmd","%\n", cmd.str());
    if (system(cmd.str().c_str())) {
        printError("generateObj: command failed: '%'\n", cmd.str());
        return false;
    }
    return true;
}

bool generateExe(const string& name) {
    Entry* e = ALL[name]; // todo? avoid grabbing from global?
    ostringstream cmd;
    cmd << "link /nologo /OUT:" << name;
    Forc (it, e->dependsOn) { cmd << " " << it->name; }
    printDebug("cmd","%\n", cmd.str());
    if (system(cmd.str().c_str())) {
        printError("generateExe: command failed: '%'\n", cmd.str());
        return false;
    }
    return true;
}

GenerationFunction determineGenerationFunction(Type type) {
    if (type == HDR) { return &generateInc; }
    if (type == SRC) { return &generateSrc; }
    if (type == OBJ) { return &generateObj; }
    if (type == EXE) { return &generateExe; }
    printError("Don't know how to generate files of type %\n", type);
    exit(EXIT_FAILURE);
}

void addIfMissing(const string& name) {
    if (ALL.find(name) == ALL.end()) {
        printDebug("addIfMissing", "%\n", name);
        add(name);
    }
}

void _addDep(const string& name, Set<Entry*>& deps, const Set<Name>& rest, const char* debugRelation) {
    Set<Name> newlyAdded;
    Forc (it, rest) {
        assert(ALL.find(it) != ALL.end());
        if (deps.insert(ALL[it]).second) {
            newlyAdded.insert(it);
        }
    }
    if (newlyAdded.size() > 0) {
        printDebug("addDeps","% % += %\n", name, debugRelation, rest);
    }
    //return newlyAdded.size();
}

void addDependsOn(const string& name, const Set<Name>& rest) {
    addIfMissing(name);
    Forc (it, rest) { addIfMissing(it); }
    _addDep(name, ALL[name]->dependsOn, rest, "dependsOn");
}

void addDependants(const string& name, const Set<Name>& rest) {
    addIfMissing(name);
    Forc (it, rest) { addIfMissing(it); }
    _addDep(name, ALL[name]->dependants, rest, "dependants");
}

void updateDepsRecursive(Entry* e) {
    Set<Name> deps = determineDeps(e->name);
    addDependsOn(e->name, deps);
    Forc (it, deps) { addDependants(it, Set<string>{e->name}); }
    Forc (it, deps) { updateDepsRecursive(ALL[it]); }
}

void add(const string& name) {
    assert(ALL.find(name) == ALL.end());
    //printDebug("add", "%\n", name);
    Entry* e = new Entry;
    e->name = name;
    e->type = getType(name);
    e->exists = fileExists(name);
    e->generationResult = NONE;
    e->generationFunction = determineGenerationFunction(e->type);
    e->timestamp = e->exists ? getFileModificationTime(e->name) : 0;
    e->isVenture = false;
    e->dependsOn = {};
    e->dependants = {};
    ALL[name] = e;
    updateDepsRecursive(e);
}

//string toString(time_t t) {
//    // ctime: Www Mmm dd hh:mm:ss yyyy
//    char buf[30];
//    strftime(buf, sizeof(buf), "%a %b %d %H:%M:%S %Y %Z"
//}

ostream& dumpDeps(ostream& s) {
    Forc (it, ALL) {
        const Entry* e = it.second;
        if (e->exists && e->timestamp == 0) {
            printError("% exists but has no timestamp\n", e->name);
            exit(EXIT_FAILURE);
        }
        s << e->name
          << "\n\texists: " << boolalpha << e->exists
          << "\n\tdependsOn:";
        Forc (d, e->dependsOn) { s << " " << d->name; }
        s << "\n\tdependants:";
        Forc (d, e->dependants) { s << " " << d->name; }
        s << "\n\tgenerationResult: " << e->generationResult
          << "\n\ttimestamp: " << ctime(&e->timestamp)
          << "\tisVenture: " << boolalpha << e->isVenture
          << "\n";
    }
    return s;
}

bool allDepsExist(Entry* e) {
#ifdef DEBUG
    Set<string> yes;
    Set<string> no;
    Forc (it, e->dependsOn) {
        if (it->isVenture == true && it->generationResult == FAIL) { continue; }
        else if (it->exists) { yes.insert(it->name); }
        else { no.insert(it->name); }
    }
    ostringstream debug;
    if (no.size() > 0) { debug << "no = " << no << " "; }
    if (yes.size() > 0) { debug << "yes = " << yes << " "; }
    if (yes.size() == 0 && no.size() == 0) { debug << "(none)"; }
    printDebug("allDepsExist", "%: %\n", e->name, debug.str());
    return no.size() == 0;
#else
    Forc (it, e->dependsOn) {
        if (!it->exists) { return false; }
    }
    return true;
#endif

}

Set<Entry*> newerDeps(Entry* e) {
    if (!e->exists) {
        printError("Unable to determine if % is newer than its dependencies because it does not exist.", e->name);
        exit(EXIT_FAILURE);
    }

    Set<Entry*> newer;
    Forc (it, e->dependsOn) {
        if (it->exists) {
            if (it->timestamp > e->timestamp) {
                newer.insert(it);
            }
        }
    }

#ifdef DEBUG
    if (newer.size() > 0) {
        Set<string> names;
        Forc (it, newer) { names.insert(it->name); }
        printDebug("newer", "% %/% deps are newer: %\n",
                e->name, newer.size(), e->dependsOn.size(), names);
    }
#endif

    return newer;
}

bool anyDepsNewer(Entry* e) {
    Set<Entry*> newer = newerDeps(e);
    return newer.size() > 0;
}

void withdrawVenture(Entry* e) {
    assert(e->generationResult == FAIL);
    For (i, e->dependants) {
        if (i->isVenture) {
            printDebug("venture", "propagating failed venture % to dependant venture %\n", e->name, i->name);
            i->generationResult = FAIL;
            withdrawVenture(i);
        } else {
            printDebug("venture", "withdrawing % from % dependencies\n", e->name, i->name);
            i->dependsOn.erase(e);
        }
    }
}

bool shouldGenerate(Entry* e) {
#ifdef DEBUG
    ostringstream debug;
    bool result;
    if (e->generationResult == FAIL) {
        result = false;
        debug << "previously failed generation";
    } else if (e->exists) {
        result = anyDepsNewer(e);
        debug << "already exists ";
        if (result) debug << "but some deps are newer";
        else debug << "and no deps are newer";
    } else {
        result = allDepsExist(e);
        if (!result) { debug << "not "; }
        debug << "all deps exist";
    }
    printDebug("shouldGenerate", "%: % (%)\n", e->name, result?"true":"false", debug.str());
    return result;
#else
    return e->generationResult != FAIL /* == NONE ?*/
        && ((!e->exists && allDepsExist(e))
        ||  (e->exists && anyDepsNewer(e)));
#endif
}

bool hasGenerationFunction(const string& name) {
    // XXX This is very incomplete.  Basically this should be similar to how 'make' looks up a recipe for a target, but I don't have anything like that yet.
    //     So instead, it's hardcoded to be what I know are generateable files just based on my example.
    bool result = (name.find("Gen") != string::npos
    && (name.rfind(HDR_EXT) == name.length() - strlen(HDR_EXT)
    ||  name.rfind(SRC_EXT) == name.length() - strlen(SRC_EXT)));
    printDebug("hasGenFn", "%: %\n", name, result?"true":"false");
    return result;
}

void replaceExt(string& s, const char* find, const char* replace) {
    s.replace(s.rfind(find), strlen(find), replace);
}

Set<string> replaceExt(const Set<string>& in, const char* find, const char* replace) {
    Set<string> out;
    //todo - investigate auto&& vs modifying
    For (i, in) {
        string s(i);
        replaceExt(s, find, replace);
        out.insert(s);
    }
    return out;
}
//void replaceExt(string& s, const char* find, const char* replace) {
//    s.replace(s.rfind(find), strlen(find), replace);
//}

void build(const string& target) {
        For (it, ALL) { delete it.second; }
        ALL.clear();

        Type type0 = getType(target);

        add(target);

        while (1) {

            Forc (it, ALL) {
                updateDepsRecursive(it.second);
            }

            if (type0 == EXE) {
                Set<string> allObjs;
                Forc (it, ALL) {
                    if (it.second->type == OBJ) {
                        // do not (re)add previously-failed ventures to exe deps
                        if (it.second->isVenture) {
                            if (it.second->generationResult != FAIL) {
                                allObjs.insert(it.first);
                            } else {
                                printDebug("venture", "ignoring previously-failed venture %\n", it.first);
                            }
                        } else {
                            allObjs.insert(it.first);
                        }
                    }
                }
                // maybe there should be overloads of these that take Entry*?
                // (to make it easier to propagate information like isVenture)
                addDependsOn(target, allObjs);
                Forc (it, allObjs) { addDependants(it, Set<string>{target}); }

                Forc (i, allObjs) {
                    Entry* o = ALL[i]; // why am I doing strings?
                    if (o->isVenture) {
                        For (j, o->dependsOn) {
                            j->isVenture = true;
                        }
                    }
                }
            }

            //// compile dependencies

            bool doneCD = false;
            {
                Set<Entry*> newlyGenerated;
                For (it, ALL) {
                    Entry* e = it.second;
                    if (shouldGenerate(e)) {
                        if (generate(e)) {
                            newlyGenerated.insert(e);
                        } else if (e->isVenture) {
                            withdrawVenture(e);
                        }
                    }
                }

                if (newlyGenerated.size() > 0) {
                    if (debugEnabled("cd")) {
                        Set<string> names;
                        Forc (i, newlyGenerated) { names.insert(i->name); }
                        printDebug("cd", "generated % new target%: %\n", newlyGenerated.size(), newlyGenerated.size()==1?"":"s", names);
                    }
                    Forc (i, newlyGenerated) {
                        Forc (j, i->dependants) {
                            updateDepsRecursive(j);
                        }
                    }
                } else {
                    printDebug("cd", "no new targets generated\n");
                    doneCD = true;
                }
            }

            //// link dependencies

            bool doneLD = false;
            if (type0 == EXE) {
                
                Set<Name> existing;
                Set<Name> ventures;
                Forc (it, ALL) {
                    if (it.second->type == HDR) {
                        Name name = it.first;
                        //name.replace(name.rfind(HDR_EXT), strlen(HDR_EXT), SRC_EXT);
                        replaceExt(name, HDR_EXT, SRC_EXT);
#ifdef DEBUG
                        Map::iterator isrc = ALL.find(name);
                        bool known = ALL.end() != isrc;
                        if (!known) {
                            bool exists = fileExists(name);
                            if (exists) {
                                printDebug("ld", "% is not known but already exists\n", name);
                                existing.insert(name);
                            } else {
                                if (hasGenerationFunction(name)) {
                                    printDebug("ld", "% is not known and does not exist, but it has a generation function\n", name);
                                    ventures.insert(name);
                                } else {
                                    printDebug("ld", "% is not known and does not exist and does not have a generation function\n", name);
                                }
                            }
                        /*} else {
                            Entry* e = isrc->second;
                            if (!e->exists) {
                                if (e->generationFunction) {
                                    printDebug("ld", "% is known to not exist, but there's a generation function for it\n", name);
                                    knownSrcs.insert(name);
                                } else {
                                    // Need to decide where to make this an error.  Either here or later when it tries to use the generation function.
                                    printDebug("ld", "WARNING! want to add % because it's not known and doesn't exist, but there's no generation function for it.\n", name);
                                }
                            } else {
                                printDebug("ld", "% is already known to exist\n", name);
                            }
                        */
                        }
#else
#error This no longer mirrors the debug version - need to add recipe/generationFunction detection.
                        if (ALL.end() == ALL.find(name) && fileExists(name)) {
                            srcs.insert(name);
                        }
#endif
                    }
                }
                //if (knownSrcs.size() > 0) { printDebug("ld","!!!!!! known srcs = %\n", knownSrcs); }
                if (existing.size() > 0) {
                    Set<string> objs = replaceExt(existing, SRC_EXT, OBJ_EXT);
                    printDebug("ld", "adding % objs that have existing srcs: %\n", objs.size(), objs);
                    Forc (it, objs) { add(it); }
                }
                if (ventures.size() > 0) {
                    Set<string> objs = replaceExt(ventures, SRC_EXT, OBJ_EXT);
                    printDebug("venture", "adding % venture%: %\n", objs.size(), objs.size()==1?"":"s", objs);
                    Forc (it, objs) { add(it); }
                    Forc (it, objs) { ALL[it]->isVenture = true; }
                    /*
                    Set<string> objs;
                    Forc (it, srcs) {
                        string obj = it;
                        obj.replace(obj.rfind(SRC_EXT), strlen(SRC_EXT), OBJ_EXT);
                        objs.insert(obj);
                    }
                    printDebug("venture", "adding % ventures: %\n", objs.size(), objs);
                    Forc (it, objs) {
                        add(it);
                        ALL[it]->isVenture = true;
                    }
                    */
                }
                if (existing.size() == 0 && ventures.size() == 0) {
                    printDebug("ld", "done\n");
                    doneLD = true;
                }

            } else {
                doneLD = true;
            }

            if (doneCD && doneLD) { break; }
        }

        if (debugEnabled("dump")) dumpDeps(cout);
}

int main(int argc, char** argv) {
    
    int i;
    for (i = 1; i < argc; ++i) {
        if (argv[i][0] == '-') {
            if (argv[i][1] == 'd') {
                ++i;
                loadDebug(argv[i]);
            }
        } else {
            break;
        }
    }

    for (; i < argc; ++i) {
        try {
            build(argv[i]);
        } catch (const exception& e) {
            printError("caught exception during % generation: %\n",
                    argv[i], e.what());
        }
    }
    return 0;
}

ostream& operator<<(ostream& os, Type x) {
    switch (x) {
        case HDR: os << "HDR"; break;
        case SRC: os << "SRC"; break;
        case OBJ: os << "OBJ"; break;
        case EXE: os << "EXE"; break;
        default:
            os << "(unknown Type " << static_cast<int>(x) << ")";
            break;
    }
    return os;
}

ostream& operator<<(ostream& os, GenerationResult x) {
    switch (x) {
        case NONE: os << "NONE"; break;
        case FAIL: os << "FAIL"; break;
        case SUCCESS: os << "SUCCESS"; break;
        default:
            os << "(unknown GenerationResult " << static_cast<int>(x) << ")";
            break;
    }
    return os;
}

/*
sub newerDepsRecursive {
    my $href = shift;
    my @newer = newerDeps($href);
    for (values %{$href->{dependsOn}}) {
        push @newer, newerDepsRecursive($_);
    }
    return @newer;
}
*/

/*
# needed for exe linking, because otherwise it only looks at .o files
sub anyDepsNewerRecursive {
    my $href = shift;
    if (anyDepsNewer($href)) {
        return 1;
    }
    for (values %{$href->{dependsOn}}) {
        if (anyDepsNewerRecursive($_)) {
            return 1;
        }
    }
    return 0;
}
*/

/*
sub arrayEq {
    my ($a, $b) = @_;
    if (not defined $a and not defined $b) { return 1; }
    if (not defined $a or not defined $b) { return 0; }
    if (scalar(@$a) != scalar(@$b)) { return 0; }
    my @A = sort @$a;
    my @B = sort @$b;
    for (1..@A-1) {
        if ($A[$_] ne $B[$_]) {
            return 0;
        }
    }
    return 1;
}

sub arrayDiff {
    my ($a, $b) = @_;
    if (not defined $a and not defined $b) { return undef; }
    elsif (not defined $a) { return $b; }
    elsif (not defined $b) { return $a; }
    my %d;
    for my $i (@$a) { unless (grep {$i eq $_} @$b) { $d{$i} = 'a'; } }
    for my $i (@$b) { unless (grep {$i eq $_} @$a) { $d{$i} = 'b'; } }
    return \%d;
}
*/

/*
sub timerStart {
    my $time = [Time::HiRes::gettimeofday()];
    for (@_) {
        $TIMERS{$_}->{start} = $time;
    }
}

sub timerStop {
    my $time = [Time::HiRes::gettimeofday()];
    for (@_) {
        my $elapsed = Time::HiRes::tv_interval($TIMERS{$_}->{start}, $time);
        $TIMERS{$_}->{end} = $time;
        $TIMERS{$_}->{elapsed} += $elapsed;
    }
    return timerGet(@_);
}

sub timerGet {
    my @elapsed = map { $TIMERS{$_}->{elapsed} } @_;
    return @elapsed==1 ? @elapsed : $elapsed[0];
}

sub printTimes {
    my @names = keys %TIMERS;
    my @labels = map { "$_ time" } keys %TIMERS;
    my $max = max(map { length } @labels);
    for (0..@names-1) {
        printf("%-*s : %.5f\n", $max, $labels[$_], $TIMERS{$names[$_]}->{elapsed});
    }
}
*/
