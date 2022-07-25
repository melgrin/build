#pragma once
#ifndef build_h
#define build_h

//#include <windows.h> // OutputDebugStringA
#include <string>
#include <set>
#include <unordered_map>
#include <iostream>

namespace Build {

    typedef std::string Name;

    typedef bool(*GenerationFunction)(const Name&);
    typedef std::set<std::string>(*DependencyFunction)(const Name&);

    enum GenerationResult {
        GEN_NONE    = -1, // haven't tried to generate the file yet
        GEN_FAIL    =  0, // tried to generate the file but failed
        GEN_SUCCESS =  1  // successfully generated the file
    };

    // The main data for Build.  There is one Entry created to track each file involved in the build process.
    struct Entry {
        Name name;
        char cname[32];
        bool exists; // as a file on disk
        GenerationResult generationResult;
        GenerationFunction generationFunction; // FIXME at least the vararg part
        DependencyFunction dependencyFunction;
        time_t timestamp;
        bool isVenture;
        std::set<Entry*> dependsOn;
        std::set<Entry*> dependants;
    };

    struct UserCode {
        typedef GenerationFunction(*GetGenerationFunctionFunction)(const std::string& name);
        typedef DependencyFunction(*GetDependencyFunctionFunction)(const std::string& name);

        GetGenerationFunctionFunction getGenerationFunction;
        GetDependencyFunctionFunction getDependencyFunction;
    };

    void loadDebug(const char* arg);
    bool debugEnabled(const char* category);
    void debugEnableAll(bool val);
    void debugDisableAll(bool val);

    // Main build loop.  Tries to generate target based on dependency rules and generation functions provided by user.
    void run(const std::string& target, UserCode* userCode);

    // This is filename to struct mapping of all of the files that Build has encountered during 'run'.  There is one Entry per file.  A file can be an existing file, a file that Build knows it needs to generate, or a file that Build might need to generate (a venture).
    // It is cleared at the beginning of 'run'.
    typedef std::unordered_map<Name, Entry*> Map;



    std::string getBase(const Name& name);
    time_t getFileModificationTime(const std::string& name);
    bool generate(Entry* e);
    std::set<Name> determineDeps(const Name& target);



    Entry* addIfMissing(const std::string& name);

    void _addDep(const std::string& name, std::set<Entry*>& deps, const std::set<Name>& rest, const char* debugRelation = "");

    void addDependsOn(const std::string& name, const std::set<Name>& rest);

    void addDependants(const std::string& name, const std::set<Name>& rest);

    void updateDepsRecursive(Entry* e);

    Entry* add(const std::string& name);

    Entry* get(const std::string& name);
    Map const& getAll();
    int getIteration();

    //std::string toString(time_t t);

    std::ostream& dumpDeps(std::ostream& s);

    bool allDepsExist(Entry* e);

    std::set<Entry*> newerDeps(Entry* e);

    bool anyDepsNewer(Entry* e);

    void withdrawVenture(Entry* e);

    bool allDepVenturesResolved(Entry* e);

    bool shouldGenerate(Entry* e);

    bool fileExists(const std::string& name);

    bool hasGenerationFunction(const std::string& name);

    void printUsage();

#ifdef DEBUG
    char* debugTimestamp();
#endif

}

std::ostream& operator<<(std::ostream& os, Build::GenerationResult x);

#define forc(IT, X) for (const auto& IT : X)
#define fora(IT, X) for (auto&& IT : X)
//todo - investigate auto&& vs modifying
//#define forc(IT, X) for (auto IT = cbegin(X); IT != cend(X); ++IT)
//#define fora(IT, X) for (auto IT = begin(X); IT != end(X); ++IT)


template <typename T>
std::ostream& operator<<(std::ostream& os, const std::set<T>& x) {
    os << "{";
    forc (it, x) { os << " " << it; }
    os << " }";
    return os;
}

void tprintf(const char* format) {
    std::cout << format;
}

template<typename T, typename... Targs>
void tprintf(const char* format, T value, Targs... Fargs) {
    for (; *format != '\0'; format++) {
        if (*format == '%') {
            std::cout << value;
            tprintf(format+1, Fargs...); // recursive call
            return;
        }
        std::cout << *format;
    }
}

//void DEBUG_printf(const char* format, ...) {
//    static char buf[512];
//    va_list args;
//    va_start(args, format);
//    vsnprintf(buf, sizeof(buf), format, args);
//    va_end(args);
//    OutputDebugStringA(buf);
//}

#define printError(FMT, ...) do { \
    tprintf("Error: " FMT " (file %, line %)\n", __VA_ARGS__, __FILE__, __LINE__); \
    /*DEBUG_printf("Error: " FMT " (file %s, line %d)\n", __VA_ARGS__, __FILE__, __LINE__);*/ \
} while (0)

#define printDebug(CATEGORY, FMT, ...) do { \
    if (Build::debugEnabled(CATEGORY)) { \
        tprintf("[%][%][%] " FMT, Build::debugTimestamp(), Build::getIteration(), CATEGORY, __VA_ARGS__); \
    } \
} while (0)

#endif // build_h



