#include "build.h"
#include <string>
#include <sstream>
#include <assert.h>
#include <filesystem>
#include <fstream>
#include <sys/stat.h>
#if _WIN32
#include <windows.h>
#endif

using namespace std;
static Build::Map ALL;
static int ITERATION;

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
bool DEBUG_CATEGORIES_ALL_DISABLED;
set<string> DEBUG_CATEGORIES_ENABLED;
set<string> DEBUG_CATEGORIES_DISABLED;

void loadDebug(const char* arg) {
    //tprintf("loadDebug: %\n", arg);
    DEBUG_CATEGORIES_ALL_ENABLED = false;
    vector<string> pieces;
    split(pieces, arg, ',');
    forc (it, pieces) {
        if (it[0] == '-') {
            if (strcmp(it.c_str(), "all") == 0) {
                DEBUG_CATEGORIES_ALL_DISABLED = true;
            } else {
                DEBUG_CATEGORIES_DISABLED.insert(it.substr(1));
            }
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
    bool _disabled = DEBUG_CATEGORIES_ALL_DISABLED || (DEBUG_CATEGORIES_DISABLED.find(category) != DEBUG_CATEGORIES_DISABLED.end());
    enabled = _enabled && !_disabled;
#endif
    return enabled;
}

void debugEnableAll(bool val) {
    DEBUG_CATEGORIES_ALL_ENABLED = val;
}

void debugDisableAll(bool val) {
    DEBUG_CATEGORIES_ALL_DISABLED = val;
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
    /* alternative, if std::filesystem is unavailable
    struct stat info;
    int result = stat(name.c_str(), &info);
    return result == 0; // maybe want errno != ENOENT (No such file or directory)
    */
}

Entry* addIfMissing(const string& name) {
    Entry* e;
    Map::iterator i = ALL.find(name);
    if (i == ALL.end()) {
        printDebug("addIfMissing", "% added\n", name);
        e = add(name);
    } else {
        printDebug("addIfMissing", "% already present\n", name);
        e = i->second;
    }
    return e;
}

void _addDep(const string& name, set<Entry*>& deps, const set<Name>& rest, const char* debugRelation) {
    set<Name> newlyAdded;
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

void addDependsOn(const string& name, const set<Name>& rest) {
    addIfMissing(name);
    forc (it, rest) { addIfMissing(it); }
    _addDep(name, ALL[name]->dependsOn, rest, "dependsOn");
}

void addDependants(const string& name, const set<Name>& rest) {
    addIfMissing(name);
    forc (it, rest) { addIfMissing(it); }
    _addDep(name, ALL[name]->dependants, rest, "dependants");
}

void updateDepsRecursive(Entry* e) {
    set<string> deps = (*e->dependencyFunction)(e->name);
    addDependsOn(e->name, deps);
    forc (it, deps) { addDependants(it, set<string>{e->name}); }
    forc (it, deps) { updateDepsRecursive(ALL[it]); }
}

Entry* add(const string& name) {
    if (ALL.find(name) != ALL.end()) {
        printError("tried to add duplicate - %", name);
        exit(EXIT_FAILURE);
    }
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
    strncpy(e->cname, name.c_str(), sizeof e->cname); // because I can't figure out where in the depths of std::basic_string the actual data is
    assert(e->generationFunction != 0);
    assert(e->dependencyFunction != 0);
    ALL[name] = e;
    printDebug("add", "%\n", name);
    updateDepsRecursive(e);
    return e;
}

Entry* get(const std::string& name) {
    Map::iterator it = ALL.find(name);
    Entry* e;
    if (it == ALL.end()) { e = 0; }
    else { e = it->second; }
    return e;
}

Map const& getAll() {
    return ALL;
}

int getIteration() {
    return ITERATION;
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
    set<string> yes;
    set<string> no;
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

set<Entry*> newerDeps(Entry* e) {
    if (!e->exists) {
        printError("Unable to determine if % is newer than its dependencies because it does not exist.", e->name);
        exit(EXIT_FAILURE);
    }

    set<Entry*> newer;
    forc (it, e->dependsOn) {
        if (it->exists) {
            if (it->timestamp > e->timestamp) {
                newer.insert(it);
            }
        }
    }

#ifdef DEBUG
    if (newer.size() > 0) {
        set<string> names;
        forc (it, newer) { names.insert(it->name); }
        printDebug("newer", "% %/% deps are newer: %\n",
                e->name, newer.size(), e->dependsOn.size(), names);
    }
#endif

    return newer;
}

bool anyDepsNewer(Entry* e) {
    set<Entry*> newer = newerDeps(e);
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
    debugDisableAll(true);
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
    debugDisableAll(false);
#endif

    bool result = e->generationResult != GEN_FAIL /* == NONE ?*/
        && ((e->exists && anyDepsNewer(e) && allDepVenturesResolved(e)
        ||  (!e->exists && allDepsExist(e))));
    printDebug("shouldGenerate", "%: % (%)\n", e->name, result?"true":"false", debug.str());
    return result;
}

void printUsage() {
    std::cout
        << "build [-h] [-d category] <target>\n"
        << "  -h  Print this help message.\n"
        << "  -d  Specify a debug logging category.\n"
        << "      Use '-d all' to see all categories.\n"
        << "      Use '-d all,-X' to see all categories except for 'X'.\n"
        ;
}

#ifdef DEBUG
char* debugTimestamp() { // This is not thread safe because it uses a static char buffer
    // 11:22:33.123456
    static const size_t N = 16;
    static char buf[N];
    char* result = "";
#if _WIN32
    SYSTEMTIME st;
    GetSystemTime(&st);
    snprintf(buf, N, "%02d:%02d:%02d.%03d", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
    result = buf;
#else
    struct timeval tv;
    if (0 == gettimeofday(&tv, 0)) {
        const tm* timestruct = localtime(&tv.tv_sec);
        char* p = buf;
        //size_t n = strftime(p, N, "%F %H:%M:%S", timestruct); // 2022-04-27 18:13:32
        size_t n = strftime(p, N, "%H:%M:%S", timestruct);
        if (n != 0 && n < N) {
            p += n;
            snprintf(p, N - n, ".%06u", tv.tv_usec);
            buf[N-1] = 0;
            //printf("%s\n", buf);
        }
        result = buf;
    }
#endif
    return result;
}
#endif

void run(const string& target, UserCode* userCode) {

    printDebug("run", "running build for target %\n", target);

    USER_CODE = userCode;
    assert(USER_CODE != 0);

    fora (it, ALL) { delete it.second; }
    ALL.clear();
    ITERATION = 0;

    add(target);

    while (1) {

        ++ITERATION;
        printDebug("iteration", "starting iteration %\n", ITERATION);

        size_t total = ALL.size();

        forc (it, ALL) {
            updateDepsRecursive(it.second);
        }

        bool done = false;
        {
            set<Entry*> newlyGenerated;
            size_t numVenturesWithdrawn = 0;
            fora (it, ALL) {
                Entry* e = it.second;
                if (shouldGenerate(e)) {
                    if (generate(e)) {
                        newlyGenerated.insert(e);
                    } else if (e->isVenture) {
                        withdrawVenture(e);
                        // need to loop back and retry now that generation won't be denied due to dependencies that didn't exist that were just withdrawn
                        ++numVenturesWithdrawn;
                    }
                }
            }

            size_t numGenerated = newlyGenerated.size();

            if (numGenerated > 0) {
                if (debugEnabled("run")) {
                    set<string> names;
                    forc (i, newlyGenerated) { names.insert(i->name); }
                    printDebug("run", "generated % new target%: %\n", numGenerated, numGenerated==1?"":"s", names);
                }
                forc (i, newlyGenerated) {
                    forc (j, i->dependants) {
                        updateDepsRecursive(j);
                    }
                }
            }

            assert(total <= ALL.size()); // nothing should ever be removed from ALL, until next 'run'
            size_t numAdded = ALL.size() - total;

            printDebug("run", "iteration %: % generated, % discovered, % ventures withdrawn\n", ITERATION, numGenerated, numAdded, numVenturesWithdrawn);

            if (numGenerated == 0 /*&& numAdded == 0*/ && numVenturesWithdrawn == 0) {
                done = true;
                printDebug("run", "done after % iteration%, total target count = %\n", ITERATION, ITERATION==1?"":"s", ALL.size());
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
