use strict;
use warnings FATAL => qw(uninitialized);
use File::Basename qw(basename);
use File::Copy qw(copy);
use FindBin;
use Carp qw(confess);
use Time::HiRes;
use Getopt::Std;
use List::Util qw(all max);

use lib "$FindBin::Bin";
use includes;
$includes::DIE_ON_MISSING = 0;

use Data::Dumper;
$Data::Dumper::Terse = 1;
$Data::Dumper::Indent = 1;
$Data::Dumper::Quotekeys = 0;
$Data::Dumper::Sortkeys = 1;

use constant NAME => basename($0);
use constant DEBUG => 1;

my $HDR_EXT = 'h'; # .hpp too? TODO .idl
my $OBJ_EXT = 'o'; # .obj too?
my @SRC_EXTS = qw/cpp c/;
my $SRC_EXT = 'SRC'; # generic marker b/c of list of possible exts
my $EXE_EXT = 'exe'; # TODO handle per platform?

#my %FAILED_GEN;

our ($opt_d);
getopts('d:') or die $!;
my @DEBUG_CATEGORIES_ENABLED;
my @DEBUG_CATEGORIES_DISABLED;
my $DEBUG_CATEGORY_WIDTH = 13;
if ($opt_d) {
    my @all = split(/[,\s]+/,$opt_d);
    for (@all) {
        if (/^-(.+)/) {
            push @DEBUG_CATEGORIES_DISABLED, $1;
        } else {
            push @DEBUG_CATEGORIES_ENABLED, $_;
        }
    }
    if ($opt_d !~ /all/) {
        $DEBUG_CATEGORY_WIDTH = max(map { length } @DEBUG_CATEGORIES_ENABLED);
    }
}

my $DEPTH_DEBUG = 0;

# struct Thing {
#     Name name;
#     List<Thing*> dependsOn;
#     List<Thing*> dependants;
#     bool exists; // as a file on disk
#     enum { NONE, FAIL, SUCCESS } generationResult;
# };
# Map<Name, Thing*> ALL;
my %ALL;

my %TIMERS; # stats

my $target = shift or die "Need target";
my ($base0, $type0) = basetype($target);
my $firstTarget;
if ($type0 eq 'EXE') {
    $firstTarget = "$base0.$OBJ_EXT";
    #would be nice to be able to do this off the bat
    #addDeps($target, 'dependsOn', $firstTarget);
    #addDeps($firstTarget, 'dependants', $target);
} else {
    $firstTarget = $target;
    addIfMissing($firstTarget);
}

updateDepsRecursive($firstTarget);

my $iteration = 0;
while (1) {
    timerStart('compileDeps');
    printDebug('phase', "begin compile dep gen phase\n");

    $iteration++;
    printDebug('main',"iteration $iteration\n");
    my @new;
    # consider that if I do while each stuff might be added to the hash is that ok?
    for my $name (keys %ALL) {
        updateDepsRecursive($name); # NovelGen.h 0/0 deps exist, can't find NovelDepGen.h
        my $h = $ALL{$name};
        if (not $h->{exists} and allDepsExist($h)) {
            if (genUE($name)) { push @new, $name; }
        }
    }

    my $doneCD = 0;
    if (@new) {
        printDebug('compile','generated '.@new." new targets: @new\n");
        for my $i (@new) {
            updateDepsRecursive($i); # not sure this ever udpates anything
            for my $j (keys %{$ALL{$i}->{dependants}}) {
                updateDepsRecursive($j);
            }
        }
        #printDebug('deps',"deps after recursive:\n" . dumpDeps());
    } else {
        printDebug('compile',"no new targets generated, exiting loop\n");
        $doneCD = 1;
        last;
    }

    timerStop('compileDeps');
    printDebug('phase', "end compile dep gen phase\n");
    
    #printDebug('deps',"post-compile deps phase:\n" . dumpDeps());
    
    my $doneE;
    my $doneLDO;

    if ($type0 eq 'EXE') {
        $doneE = 0;
        timerStart('linkDeps');
        printDebug('phase',"begin link dep gen phase\n");

        # Every src (and yet-to-exist obj) that was created during the dependency generation process for main.o is a dependency for main.exe.
        #my $doneE = 0;
        {
            my @srcs = map { base($_).'.c' } grep {/\.$HDR_EXT$/} keys %ALL; # @src_ext_cheat

            @srcs = grep {-f} @srcs;

            #for (@srcs) { updateDepsRecursive($_); }

            printDebug('link',"existing srcs: @srcs\n");
            if (@srcs) {
                my @objs = map { base($_).'.'.$OBJ_EXT } @srcs;
                addIfMissing(@objs);
                for my $o (@objs) { updateDepsRecursive($o); }
                if (all { -f } @objs) {
                    printDebug('link',"all obj for src already exist: @objs\n");
                    $doneE = 1;
                } else {
                    for (@objs) {
                        #blah_v4($_);
                        my $h = $ALL{$_};
                        if (not $h->{exists} and allDepsExist($h)) {
                            if (genUE($_)) {
                                #updateDepsRecursive($_);
                            }
                        }
                    }
                }
            } else {
                $doneE = 1;
            }
        }

        # For all dependencies that are hdrs with no matching src, try to generate the src.  if successful, the obj is needed for linking main.exe
        #my $doneLDO = 0;
        {
            my @srcs = map { base($_).'.c' } grep {/\.$HDR_EXT$/} keys %ALL; # @src_ext_cheat
   
            #my @generatedSrcs = grep { blah_v4($_) eq 'succeeded' } @srcs;
            addIfMissing(@srcs);

            my @new;
            for (@srcs) {
                my $h = $ALL{$_};
                if (not $h->{exists}) {
                    if (genUE($_)) { push @new, $_; }
                }
            }

            if (@new) {
                printDebug('link','generated '.@new." new targets: @new\n");
                for my $i (@new) {
                    updateDepsRecursive($i); # not sure this ever udpates anything
                    for my $j (keys %{$ALL{$i}->{dependants}}) {
                        updateDepsRecursive($j);
                    }
                }
                #printDebug('deps',"deps after recursive:\n" . dumpDeps());
                my @objs = map { base($_).'.'.$OBJ_EXT } @new;
                addIfMissing(@objs);
                for my $o (@objs) { updateDepsRecursive($o); }
                my @new2;
                for (@objs) {
                    #blah_v4($_);
                    my $h = $ALL{$_};
                    if (not $h->{exists} and allDepsExist($h)) {
                        if (genUE($_)) { push @new2, $_; }
                    }
                }
                if (@new2) {
                    # new .o, do I care?  that won't cause a change in deps.
                } else {
                    $doneLDO = 1;
                }
            } else {
                printDebug('link',"no new targets generated\n");
                $doneLDO = 1;
            }

        }

        timerStop('linkDeps');
        printDebug('phase',"end link dep gen phase\n");
    
    } else {
        $doneE = 1;
        $doneLDO = 1;
    }

    if ($doneCD and $doneE and $doneLDO) {
        last;
    }

}

printDebug('deps',"deps final:\n" . dumpDeps());
generate($target, grep /\.$OBJ_EXT$/, keys %ALL);

timerStop('total');

printTimes_simple();

exit;

####

sub determineDeps {
    my $target = shift;
    my ($base, $type) = basetype($target);
    my @deps;
    if ($type eq 'OBJ') {
        my $src = "$base.c"; # @src_ext_cheat
        push @deps, $src;
        if (-f $src) { # might be generated
            my $incs = includes::find($src);
            push @deps, keys %$incs;
        }
    } elsif ($type eq 'HDR') {
        # push @deps - nothing now, maybe something for .idl
    } elsif ($type eq 'SRC') {
        # push @deps - nothing now, maybe something for .idl
    } elsif ($type eq 'EXE') {
        # It's different enough that I couldn't figure out a good way to do it here.
        confess("exe dependency logic handled at top of script instead");
        #push @deps, "$base.$OBJ_EXT";
    } else {
        die "script not done for $type files yet (target = $target)";
    }
    if (@deps) {
        printDebug('detDeps',"$target: @deps\n");
    }
    return @deps;
}

sub updateDepsRecursive {
    $DEPTH_DEBUG++;
    my $x = shift;

    my @deps = determineDeps($x);

    addDeps($x, 'dependsOn', @deps);
    for (@deps) { addDeps($_, 'dependants', $x); }

    for (@deps) { updateDepsRecursive($_); }

    $DEPTH_DEBUG--;
}

sub generate {
    my $x = shift;
    my (undef, $type) = basetype($x);
    my $r;
    my $time0 = [Time::HiRes::gettimeofday()];
    if    ($type eq 'HDR') { $r = generateInc($x, @_); }
    elsif ($type eq 'SRC') { $r = generateSrc($x, @_); }
    elsif ($type eq 'OBJ') { $r = generateObj($x, @_); }
    elsif ($type eq 'EXE') { $r = generateExe($x, @_); }
    else { die "Don't know how to generate '$x'"; }
    if ($r) {
        printDebug('gen',"generated $x\n");
    } else {
        printDebug('gen',"failed to generate $x\n");
        #$FAILED_GEN{$x} = 1;
    }
    return $r;
}

sub generateInc {
    return _copy_gen(@_);
}

sub generateSrc {
    return _copy_gen(@_);
}

sub _copy_gen {
    die unless scalar(@_) == 1;
    my $file = shift;
    return copy("gen/$file", $file);
}

sub generateObj {
    my $x = shift;
    my ($base, undef) = basetype($x);
    unless ($base) { confess(); }
    my $src;
    for my $e (@SRC_EXTS) {
        my $s = "$base.$e";
        if (-f $s) {
            $src = $s;
            last;
        }
    }
    unless ($src) { confess("src for $x does not exist"); }

    my $cmd = "cl /nologo /c /Fo$x $src";
    printDebug('cmd',"$cmd\n");
    if (system($cmd)) {
        printError("generateObj: command failed: '$cmd'\n");
        confess();
        #exit; # return 0 ?
    }
    return 1;
}

sub generateExe {
    my $x = shift;
    my $cmd = "link /nologo /OUT:$x @_";
    printDebug('cmd',"$cmd\n");
    if (system($cmd)) {
        printError("generateExe: command failed: '$cmd'\n");
        confess();
        #exit; # return 0 ?
    }
    return 1;
}

sub basetype {
    my $x = shift;
    if ($x !~ /\./) {
        return ($x, 'EXE');
    }
    unless ($x =~ /(.+)\.(.+)$/) { # FIXME isn't this going to break when $x includes the directory?
        confess("failed to determine basetype for '$x'");
    }
    my $base = $1;
    my $ext = $2;
    my $type;
    if ($ext eq $HDR_EXT) {
        $type = 'HDR';
    } elsif ($ext eq $OBJ_EXT) {
        $type = 'OBJ';
    } elsif ($ext eq $SRC_EXT) {
        $type = 'SRC';
    } elsif (grep {$ext eq $_} @SRC_EXTS) {
        $type = 'SRC';
    } elsif ($ext eq $EXE_EXT) {
        $type = 'EXE';
    }
    return ($base, $type);
}

sub base {
    my ($base, undef) = basetype($_[0]);
    return $base;
}

sub type {
    my (undef, $type) = basetype($_[0]);
    return $type;
}

sub printError {
    print STDERR 'ERROR ['.NAME."] @_";
}

sub printInfo {
    print STDOUT '['.NAME."][info] @_";
}

sub printDebug {
    if (DEBUG) {
        my $cat = shift;
        if (grep { /^($cat|all)$/i } @DEBUG_CATEGORIES_ENABLED
        and not grep { /^$cat$/ } @DEBUG_CATEGORIES_DISABLED) {
            my $pad = '';
            for (1..$DEPTH_DEBUG) { $pad .= '- '; }
            printf STDOUT '[%s][debug][%-*s] %s%s',
                NAME, $DEBUG_CATEGORY_WIDTH, $cat, $pad, @_;
        }
    }
}

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

sub printTimes_simple {
    my @names = keys %TIMERS;
    my @labels = map { "$_ time" } keys %TIMERS;
    my $max = max(map { length } @labels);
    for (0..@names-1) {
        printf("%-*s : %.5f\n", $max, $labels[$_], $TIMERS{$names[$_]}->{elapsed});
    }
}

# I don't have List::Util 1.45
# Returns unique values from the list, preserving order.
sub uniq {
    my @u;
    my %seen;
    for (@_) {
        unless (exists $seen{$_}) {
            $seen{$_} = 1;
            push @u, $_;
        }
    }
    return @u;
}

sub assertUniq {
    my @u = uniq(@_);
    unless (scalar(@u) == scalar(@_)) {
        confess("assertUniq failed: "
            . "full = " . scalar(@_) . " (@_), "
            . "uniq = " . scalar(@u) . " (@u)");
    }
}

sub addDeps {
    my $x = shift;
    my $key = shift;
    addIfMissing($x);
    addIfMissing(@_);
    my @new;
    for (@_) {
        unless (exists $ALL{$x}->{$key}->{$_}) {
            $ALL{$x}->{$key}->{$_} = $ALL{$_};
            push @new, $_;
        }
    }
    if (@new) {
        printDebug('new',"$x $key += @new\n");
    }
}

sub addIfMissing {
    for (@_) {
        if (not exists $ALL{$_}) {
            $ALL{$_} = {
                name => $_,
                exists => -f $_ ? 1 : 0,
                dependsOn => {},
                dependants => {},
                generationResult => ''
            };
            #printDebug('addIfMissing',"creating new entry for $_: " . Dumper($ALL{$_}) . "\n");
        }
    }
}

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
        #$TIMERS{$_}->{elapsed} = $elapsed;
        $TIMERS{$_}->{elapsed} += $elapsed;
    }
    return timerGet(@_);
}

sub timerGet {
    my @elapsed = map { $TIMERS{$_}->{elapsed} } @_;
    return @elapsed==1 ? @elapsed : $elapsed[0];
}

sub dumpDeps {
    my @names = @_ ? @_ : keys %ALL;
    my $s = '';
    for my $i (@names) {
        my $e = $ALL{$i}->{exists};
        if (not defined $e) { confess($i); }
        $s .= $i
            . "\n\texists: "
            . $ALL{$i}->{exists}
            . "\n\tdependsOn: "
            . join(' ',keys %{$ALL{$i}->{dependsOn}})
            . "\n\tdependants: "
            . join(' ',keys %{$ALL{$i}->{dependants}})
            . "\n\tgenerationResult: "
            . $ALL{$i}->{generationResult}
            . "\n";
    }
    return $s;
}

sub allDepsExist {
    my $h = shift;

    # can do this on one line:
    #return all {/1/} map { $_->{exists} } values %{$h->{dependsOn}};
    # but I want some debug

    my @y;
    my @n;
    for (values %{$h->{dependsOn}}) {
        if ($_->{exists}) {
            push @y, $_->{name};
        } else {
            push @n, $_->{name};
        }
    }
    my $s = $h->{name}.': '.@y.'/'.(@y+@n).' deps exist';
    if (@y) { $s .= ", yes = @y"; }
    if (@n) { $s .= ", no = @n"; }
    printDebug('allDepsExist', "$s\n");

    return @n==0;
}

sub genUE {
    my $name = shift;
    my $r = generate($name);
    if ($r) {
        my $e = -f $name ? 1 : 0;
        unless ($e) { confess("generate returned true but -f returned false ($name)"); }
        $ALL{$name}->{exists} = $e;
        $ALL{$name}->{generationResult} = 'success';
    } else {
        $ALL{$name}->{generationResult} = 'fail';
    }
    return $r;
}

