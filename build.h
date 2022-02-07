#pragma once
#ifndef build_h
#define build_h

//#include <windows.h> // OutputDebugStringA
#include <string>
#include <unordered_set>
#include <unordered_map>
#include <iostream>

#define Set std::unordered_set

namespace Build {

    typedef std::string Name;

    typedef bool(*GenerationFunction)(const Name&);
    typedef Set<std::string>(*DependencyFunction)(const Name&);

    enum GenerationResult {
        GEN_NONE    = -1, // haven't tried to generate the file yet
        GEN_FAIL    =  0, // tried to generate the file but failed
        GEN_SUCCESS =  1  // successfully generated the file
    };

    // The main data for Build.  There is one Entry created to track each file involved in the build process.
    struct Entry {
        Name name;
        bool exists; // as a file on disk
        GenerationResult generationResult;
        GenerationFunction generationFunction; // FIXME at least the vararg part
        DependencyFunction dependencyFunction;
        time_t timestamp;
        bool isVenture;
        Set<Entry*> dependsOn;
        Set<Entry*> dependants;
    };

    struct UserCode {
        typedef GenerationFunction(*GetGenerationFunctionFunction)(const std::string& name);
        typedef DependencyFunction(*GetDependencyFunctionFunction)(const std::string& name);

        GetGenerationFunctionFunction getGenerationFunction;
        GetDependencyFunctionFunction getDependencyFunction;
    };

    void loadDebug(const char* arg, UserCode* userCode);

    // Main build loop.  Tries to generate target based on dependency rules and generation functions provided by user.
    void run(const std::string& target);

    // This is filename to struct mapping of all of the files that Build has encountered during run.  There is one Entry per file.  A file can be an existing file, a file that Build knows it needs to generate, or a file that Build might need to generate (a venture).
    // It is cleared before each run.
    typedef std::unordered_map<Name, Entry*> Map;
    Map ALL; 



    std::string getBase(const Name& name);
    bool debugEnabled(const char* category);
    time_t getFileModificationTime(const std::string& name);
    bool generate(Entry* e);
    Set<Name> determineDeps(const Name& target);



    void addIfMissing(const std::string& name);

    void _addDep(const std::string& name, Set<Entry*>& deps, const Set<Name>& rest, const char* debugRelation = "");

    void addDependsOn(const std::string& name, const Set<Name>& rest);

    void addDependants(const std::string& name, const Set<Name>& rest);

    void updateDepsRecursive(Entry* e);

    void add(const std::string& name);

    //std::string toString(time_t t);

    std::ostream& dumpDeps(std::ostream& s);

    bool allDepsExist(Entry* e);

    Set<Entry*> newerDeps(Entry* e);

    bool anyDepsNewer(Entry* e);

    void withdrawVenture(Entry* e);

    bool allDepVenturesResolved(Entry* e);

    bool shouldGenerate(Entry* e);

    bool fileExists(const std::string& name);

    // Everything in the Set<char*> is allocated on the heap!
    //Set<char*> findIncludes(const std::string& name);
    //void _findIncludes(const char* name, Set<char*>* incs);

    bool hasGenerationFunction(const std::string& name);

    void replaceExt(std::string& s, const char* find, const char* replace);
    Set<std::string> replaceExt(const Set<std::string>& in, const char* find, const char* replace);

}

std::ostream& operator<<(std::ostream& os, Build::GenerationResult x);

#define forc(IT, X) for (const auto& IT : X)
#define fora(IT, X) for (auto&& IT : X)
//todo - investigate auto&& vs modifying
//#define forc(IT, X) for (auto IT = cbegin(X); IT != cend(X); ++IT)
//#define fora(IT, X) for (auto IT = begin(X); IT != end(X); ++IT)


template <typename T>
std::ostream& operator<<(std::ostream& os, const Set<T>& x) {
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
        tprintf("[" CATEGORY "] " FMT, __VA_ARGS__); \
    } \
} while (0)

#endif // build_h
