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
    }
    return info.st_mtime;
}

bool generate_v2(Entry* e) {
    const Name name = e->name;
    bool success = false;
    success = (*e->recipe)(name); // TODO? varargs, for exe dep objs
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

Set<string> findIncludes(const string& name) {
    Set<string> incs;
    _findIncludes(name, &incs);
    return incs;
}

void _findIncludes(const string& name, Set<string>* incs) {
    Set<string> local;
    {
        ifstream in(name.c_str());
        if (!in) {
            printError("failed to open %s\n", name);
            return;
        }
        string line;
        regex pattern("#\\s*include\\s+[<\"](\\.+)[>\"]");
        smatch match;
        while (getline(in, line)) {
            if (regex_match(line, match, pattern)) {
                local.insert(match[1]);
            }
        }
    }
    For (it, local) {
        incs->insert(it);
        if (fileExists(it)) {
            _findIncludes(it, incs);
        }
    }
}

Set<Name> determineDeps2(const Name& target) {
    string base = getBase(target);
    Type type = getType(target);
    Set<Name> deps;
    if (type == OBJ) {
        string src = base + SRC_EXT;
        deps.insert(src);
        if (fileExists(src)) { // might be generated
            Set<string> incs = findIncludes(src);
            Forc (it, incs) { deps.insert(it); }
        }
    } else if (type == HDR) {
        // nothing now, maybe something for .idl
    } else if (type == SRC) {
        // nothing now, maybe something for .idl
    } else if (type == EXE) {
        deps.insert(base + OBJ_EXT); // maybe also want to search ALL
    } else {
        printError("script not done for % files yet (target = %)\n", type, target);
    }
    if (deps.size() > 0) {
        printDebug("detDeps","target: %\n", deps);
    }
    return deps;
}

bool _copy_gen(const string& name) {
    string from = "gen/" + name;
    string to = name;
    bool success = filesystem::copy_file(from, to);
    if (success) {
        printDebug("cmd", "copy(%, %)\n", from, to);
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
    }

    ostringstream cmd;
    cmd << "cl /nologo /c /Fo" << name << " " << src << " > /dev/null";
    printDebug("cmd","%\n", cmd.str());
    if (system(cmd.str().c_str())) {
        printError("generateObj: command failed: '%'\n", cmd.str());
    }
    return true;
}

bool generateExe(const string& name) { // FIXME doesn't mesh with typedef GenerationFunction args
    Set<Name> objs;
    Forc (it, ALL) {
        if (it.second->type == OBJ) {
            objs.insert(it.first);
        }
    }
    ostringstream cmd;
    cmd << "link /nologo /OUT:" << name;
    Forc (it, objs) { cmd << " " << it; }
    printDebug("cmd","%\n", cmd.str());
    if (system(cmd.str().c_str())) {
        printError("generateExe: command failed: '%'\n", cmd.str());
    }
    return true;
}

GenerationFunction determineGenFn(Type type) {
    if (type == HDR) { return &generateInc; }
    if (type == SRC) { return &generateSrc; }
    if (type == OBJ) { return &generateObj; }
    if (type == EXE) { return &generateExe; }
    printError("Don't know how to generate files of type %", type);
}

void addIfMissing(const string& name) {
    if (ALL.find(name) == ALL.end()) {
        printDebug("addIfMissing", "%\n", name);
        add(name);
    }
}

void _addDep(const string& name, Set<Entry*>& deps, const Set<Name>& rest) {
    addIfMissing(name);
    Set<Name> newlyAdded;
    Forc (it, rest) {
        if (ALL.find(it) != ALL.end()) {
            if (deps.insert(ALL[it]).second) {
                newlyAdded.insert(it);
            }
        }
    }
    if (newlyAdded.size() > 0) {
        printDebug("addDeps","% dependsOn += %\n", name, rest);
    }
    //return newlyAdded.size();
}

void addDependsOn(const string& name, const Set<Name>& rest) {
    addIfMissing(name);
    Forc (it, rest) { addIfMissing(it); }
    _addDep(name, ALL[name]->dependsOn, rest);
}

void addDependants(const string& name, const Set<Name>& rest) {
    addIfMissing(name);
    Forc (it, rest) { addIfMissing(it); }
    _addDep(name, ALL[name]->dependants, rest);
}

void updateDepsRecursive(Entry* e) {
    Set<Name> deps = determineDeps2(e->name);
    addDependsOn(e->name, deps);
    Forc (it, deps) { addDependants(it, Set<string>{e->name}); }
    Forc (it, deps) {
        updateDepsRecursive(ALL[it]);
    }
}

void add(const string& name) {
    assert(ALL.find(name) == ALL.end());
    //printDebug("add", "%\n", name);
    Entry* e = new Entry;
    e->name = name;
    e->type = getType(name);
    e->exists = fileExists(name);
    e->generationResult = NONE;
    e->recipe = determineGenFn(e->type);
    e->timestamp = e->exists ? getFileModificationTime(e->name) : 0;
    //e->dependsOn => {},
    //e->dependants => {},
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
        if (e->exists && e->timestamp == 0) { printError("% exists but has no timestamp\n", e->name); }
        s << e->name
          << "\n\texists: " << boolalpha << e->exists
          << "\n\tdependsOn:";
        Forc (d, e->dependsOn) { s << " " << d->name; }
        s << "\n\tdependants: ";
        Forc (d, e->dependants) { s << " " << d->name; }
        s << "\n\tgenerationResult: " << e->generationResult
          << "\n\ttimestamp: " << ctime(&e->timestamp)
          << "\n";
    }
    return s;
}

bool allDepsExist(Entry* e) {
#ifdef DEBUG
    Set<string> yes;
    Set<string> no;
    Forc (it, e->dependsOn) {
        if (it->exists) { yes.insert(it->name); }
        else { no.insert(it->name); }
    }
    ostringstream debug;
    if (yes.size() > 0) { debug << ", yes = " << yes; }
    if (no.size() > 0) { debug << ", no = " << no; }
    printDebug("allDepsExist", "%: %\n", e->name, debug.str());
    return no.size() == 0;
#else
    Forc (it, e->dependsOn) {
        if (!it->exists) { return false; }
    }
    return true;
#endif

}

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

Set<Entry*> newerDeps(Entry* e) {
    if (!e->exists) {
        printError("Unable to determine if % is newer than its dependencies because it does not exist.", e->name);
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

bool shouldGenerate(Entry* e) {
    return ((!e->exists && allDepsExist(e))
        ||  ( e->exists && anyDepsNewer(e)));
}

void _main(const string& target) {
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
                        allObjs.insert(it.first);
                    }
                }
                addDependsOn(target, allObjs);
                Forc (it, allObjs) { addDependants(it, Set<string>{target}); }
            }
    
            bool doneCD = false;
            {
                Set<Entry*> newlyGenerated;
                For (it, ALL) {
                    Entry* e = it.second;
                    if (shouldGenerate(e)) {
                        if (generate_v2(e)) {
                            newlyGenerated.insert(e);
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
    
            bool done2 = false;
            if (type0 == EXE) {
                
                Set<Name> srcs;
                Forc (it, ALL) {
                    if (it.second->type == HDR) {
                        Name name = it.first;
                        name.replace(name.find_last_of(HDR_EXT), strlen(HDR_EXT), SRC_EXT); // XXX surely this will just work
                        if (ALL.end() == ALL.find(name) && fileExists(name)) {
                            srcs.insert(name);
                        }
                    }
                }
                if (srcs.size() > 0) {
                    Forc (it, srcs) { add(it); }
                } else {
                    done2 = true;
                }
    
            } else {
                done2 = true;
            }
    
            if (doneCD && done2) { break; }
        }
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
            _main(argv[i]);
        } catch (const exception& e) {
            fprintf(stderr, "Error: caught exception during %s generation: %s\n",
                    argv[i], e.what());
        }
    }
    return 0;
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
