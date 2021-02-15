#ifndef build_h
#define build_h

#include <string>
#include <unordered_set>
#include <unordered_map>
#include <iostream>

using namespace std;

void build(const string& target);

// only works for C programs on Windows, sorry
const char* HDR_EXT = ".h";
const char* OBJ_EXT = ".o";
const char* SRC_EXT = ".c";
const char* EXE_EXT = ".exe";

//typedef unordered_set Set;
//template <typename T> using Set = unordered_set<T>;
#define Set unordered_set

#define Forc(IT, X) for (const auto& IT : X)
#define For(IT, X) for (auto&& IT : X)
//todo - investigate auto&& vs modifying
//#define Forc(IT, X) for (auto IT = cbegin(X); IT != cend(X); ++IT)
//#define For(IT, X) for (auto IT = begin(X); IT != end(X); ++IT)

template <typename T>
ostream& operator<<(ostream& os, const Set<T>& x) {
    os << "{";
    Forc (it, x) { os << " " << it; }
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

#define printError(FMT, ...) tprintf("Error at line %: " FMT, __LINE__, __VA_ARGS__)

#define printDebug(CATEGORY, FMT, ...) do { if (debugEnabled(CATEGORY)) { tprintf("[" CATEGORY "] " FMT, __VA_ARGS__); } } while (0)

typedef string Name;

enum Type {
    HDR,
    SRC,
    OBJ,
    EXE
};

enum GenerationResult {
    NONE = -1,
    FAIL = 0,
    SUCCESS = 1
};

//typedef function<bool(const string&)> GenerationFunction;
typedef bool(*GenerationFunction)(const string&);

struct Entry {
    Name name;
    Type type;
    bool exists; // as a file on disk
    GenerationResult generationResult;
    GenerationFunction generationFunction; // FIXME at least the vararg part
    time_t timestamp;
    bool isVenture;
    Set<Entry*> dependsOn;
    Set<Entry*> dependants;
};

//bool operator==(const Entry& lhs, const Entry& rhs);

typedef unordered_map<Name, Entry*> Map;

string getBase(const string& name);
Type getType(const string& name);
bool debugEnabled(const char* category);
time_t getFileModificationTime(const string& name);
bool generate(Entry* e);
Set<Name> determineDeps(const Name& target);

bool copyWholeFile(const string& source, const string& destination);

// specific to my example
// I just have the "generate-able" files in a subdirectory
bool _copy_gen(const string& name);

bool generateInc(const string& name);
bool generateSrc(const string& name);
bool generateObj(const string& name);
bool generateExe(const string& name);

GenerationFunction determineGenerationFunction(Type type);

void addIfMissing(const string& name);

void _addDep(const string& name, Set<Entry*>& deps, const Set<Name>& rest, const char* debugRelation = "");

void addDependsOn(const string& name, const Set<Name>& rest);

void addDependants(const string& name, const Set<Name>& rest);

void updateDepsRecursive(Entry* e);

void add(const string& name);

//string toString(time_t t);

ostream& dumpDeps(ostream& s);

bool allDepsExist(Entry* e);

Set<Entry*> newerDeps(Entry* e);

bool anyDepsNewer(Entry* e);

void withdrawVenture(Entry* e);

bool shouldGenerate(Entry* e);

bool fileExists(const string& name);

// Everything in the Set<char*> is allocated on the heap!
Set<char*> findIncludes(const string& name);
void _findIncludes(const char* name, Set<char*>* incs);

bool hasGenerationFunction(const string& name);

void replaceExt(string& s, const char* find, const char* replace);
Set<string> replaceExt(const Set<string>& in, const char* find, const char* replace);

ostream& operator<<(ostream& os, Type x);
ostream& operator<<(ostream& os, GenerationResult x);

#endif // build_h
