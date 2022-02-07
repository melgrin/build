#include "build.h"
#include <string>
#include <sstream>
#include <assert.h>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>

using namespace std;

static void split(vector<string>& out, const string& s, char delimiter) {
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


namespace Build {

UserCode* USER_CODE;

string getBase(const string& name) {
    return name.substr(0, name.find_last_of('.'));
}

bool DEBUG_CATEGORIES_ALL_ENABLED;
Set<string> DEBUG_CATEGORIES_ENABLED;
Set<string> DEBUG_CATEGORIES_DISABLED;

void loadDebug(const char* arg) {
    //tprintf("loadDebug: %\n", arg);
    DEBUG_CATEGORIES_ALL_ENABLED = false;
    vector<string> pieces;
    split(pieces, arg, ',');
    forc (it, pieces) {
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
    
    struct stat info;
    if (stat(name.c_str(), &info) != 0) {
        printError("%: %", name, strerror(errno));
        exit(EXIT_FAILURE);
    }
    return info.st_mtime;
}

bool generate(Entry* e) {
    const Name name = e->name;
    bool success = (*e->generationFunction)(name);
    if (success) {
        printDebug("gen","generated %\n", name);
        bool exists = fileExists(name);
        assert(exists);
        e->exists = exists;
        e->generationResult = GEN_SUCCESS;
        e->timestamp = getFileModificationTime(name);
    } else {
        printDebug("genfail","failed to generate %\n", name);
        e->generationResult = GEN_FAIL;
    }
    return success;
}

bool fileExists(const string& name) {
    return filesystem::is_regular_file(name);
}

void addIfMissing(const string& name) {
    if (ALL.find(name) == ALL.end()) {
        printDebug("addIfMissing", "%\n", name);
        add(name);
    }
}

void _addDep(const string& name, Set<Entry*>& deps, const Set<Name>& rest, const char* debugRelation) {
    Set<Name> newlyAdded;
    forc (it, rest) {
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
    forc (it, rest) { addIfMissing(it); }
    _addDep(name, ALL[name]->dependsOn, rest, "dependsOn");
}

void addDependants(const string& name, const Set<Name>& rest) {
    addIfMissing(name);
    forc (it, rest) { addIfMissing(it); }
    _addDep(name, ALL[name]->dependants, rest, "dependants");
}

void updateDepsRecursive(Entry* e) {
    Set<string> deps = (*e->dependencyFunction)(e->name);
    addDependsOn(e->name, deps);
    forc (it, deps) { addDependants(it, Set<string>{e->name}); }
    forc (it, deps) { updateDepsRecursive(ALL[it]); }
}

void add(const string& name) {
    assert(ALL.find(name) == ALL.end());
    //printDebug("add", "%\n", name);
    Entry* e = new Entry;
    e->name = name;
    e->exists = fileExists(name);
    e->generationResult = GEN_NONE;
    e->generationFunction = (*USER_CODE->getGenerationFunction)(e->name);
    e->dependencyFunction = (*USER_CODE->getDependencyFunction)(e->name);
    e->timestamp = e->exists ? getFileModificationTime(e->name) : 0;
    e->isVenture = false;
    e->dependsOn = {};
    e->dependants = {};
    assert(e->generationFunction != 0);
    assert(e->dependencyFunction != 0);
    ALL[name] = e;
    updateDepsRecursive(e);
}

//string toString(time_t t) {
//    // ctime: Www Mmm dd hh:mm:ss yyyy
//    char buf[30];
//    strftime(buf, sizeof(buf), "%a %b %d %H:%M:%S %Y %Z"
//}

ostream& dumpDeps(ostream& s) {
    forc (it, ALL) {
        const Entry* e = it.second;
        if (e->exists && e->timestamp == 0) {
            printError("% exists but has no timestamp", e->name);
            exit(EXIT_FAILURE);
        }
        s << e->name
          << "\n\texists: " << boolalpha << e->exists
          << "\n\tdependsOn:";
        forc (d, e->dependsOn) { s << " " << d->name; }
        s << "\n\tdependants:";
        forc (d, e->dependants) { s << " " << d->name; }
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
    forc (it, e->dependsOn) {
        if (it->isVenture == true && it->generationResult == GEN_FAIL) { continue; }
        else if (it->exists) { yes.insert(it->name); }
        else { no.insert(it->name); }
    }
    ostringstream debug;
    if (no.size() > 0) { debug << "no = " << no << " "; }
    if (yes.size() > 0) { debug << "yes = " << yes << " "; }
    if (yes.size() == 0 && no.size() == 0) { debug << "(none)"; }
    printDebug("allDepsExist", "%: %\n", e->name, debug.str());
    //return no.size() == 0;
#endif

    forc (it, e->dependsOn) {
        if (it->isVenture == true && it->generationResult == GEN_FAIL) { continue; }
        if (!it->exists) { return false; }
    }
    return true;
}

Set<Entry*> newerDeps(Entry* e) {
    if (!e->exists) {
        printError("Unable to determine if % is newer than its dependencies because it does not exist.", e->name);
        exit(EXIT_FAILURE);
    }

    Set<Entry*> newer;
    forc (it, e->dependsOn) {
        if (it->exists) {
            if (it->timestamp > e->timestamp) {
                newer.insert(it);
            }
        }
    }

#ifdef DEBUG
    if (newer.size() > 0) {
        Set<string> names;
        forc (it, newer) { names.insert(it->name); }
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
    assert(e->generationResult == GEN_FAIL);
    fora (i, e->dependants) {
        if (i->isVenture) {
            printDebug("venture", "propagating failed venture % to dependant venture %\n", e->name, i->name);
            i->generationResult = GEN_FAIL;
            withdrawVenture(i);
        } else {
            printDebug("venture", "withdrawing % from % dependencies\n", e->name, i->name);
            i->dependsOn.erase(e);
        }
    }
}

bool allDepVenturesResolved(Entry* e) {
    forc (it, e->dependsOn) {
        if (it->isVenture && it->generationResult == GEN_NONE) return false;
    }
    return true;
}

bool shouldGenerate(Entry* e) {

#ifdef DEBUG
    ostringstream debug;
    if (e->generationResult == GEN_FAIL) {
        debug << "previously failed generation";
    } else if (e->exists) {
        bool depsNewer = anyDepsNewer(e);
        bool venturesResolved = allDepVenturesResolved(e);
        debug << "already exists"
              << ", anyDepsNewer = " << (depsNewer?"true":"false")
              << ", allDepVenturesResolved = " << (venturesResolved?"true":"false");
    } else {
        debug << "doesn't exist, ";
        if (!allDepsExist(e)) { debug << "not "; }
        debug << "all deps exist";
    }
#endif

    bool result = e->generationResult != GEN_FAIL /* == NONE ?*/
        && ((e->exists && anyDepsNewer(e) && allDepVenturesResolved(e)
        ||  (!e->exists && allDepsExist(e))));
    printDebug("shouldGenerate", "%: % (%)\n", e->name, result?"true":"false", debug.str());
    return result;
}

void run(const string& target, UserCode* userCode) {
    USER_CODE = userCode;
    assert(USER_CODE != 0);

    fora (it, ALL) { delete it.second; }
    ALL.clear();

    add(target);

    while (1) {

        forc (it, ALL) {
            updateDepsRecursive(it.second);
        }

        bool done = false;
        {
            Set<Entry*> newlyGenerated;
            bool withdrewAnyVentures = false;
            fora (it, ALL) {
                Entry* e = it.second;
                if (shouldGenerate(e)) {
                    if (generate(e)) {
                        newlyGenerated.insert(e);
                    } else if (e->isVenture) {
                        withdrawVenture(e);
                        // need to loop back and retry now that generation won't be denied due to dependencies that didn't exist that were just withdrawn
                        withdrewAnyVentures = true;
                    }
                }
            }

            if (newlyGenerated.size() > 0) {
                if (debugEnabled("run")) {
                    Set<string> names;
                    forc (i, newlyGenerated) { names.insert(i->name); }
                    printDebug("run", "generated % new target%: %\n", newlyGenerated.size(), newlyGenerated.size()==1?"":"s", names);
                }
                forc (i, newlyGenerated) {
                    forc (j, i->dependants) {
                        updateDepsRecursive(j);
                    }
                }
            } else if (!withdrewAnyVentures) {
                printDebug("run", "no new targets generated, no ventures withdrawn\n");
                done = true;
            }
        }

        if (done) break;
    }

    if (debugEnabled("dump")) dumpDeps(cout);
}

} // namespace Build

ostream& operator<<(ostream& os, Build::GenerationResult x) {
    switch (x) {
        case Build::GEN_NONE   : os << "GEN_NONE"   ; break;
        case Build::GEN_FAIL   : os << "GEN_FAIL"   ; break;
        case Build::GEN_SUCCESS: os << "GEN_SUCCESS"; break;
        default:
            os << "(unknown Build::GenerationResult " << static_cast<int>(x) << ")";
            break;
    }
    return os;
}
