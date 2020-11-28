our $VERSION = "11";
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

my %FAILED_GEN;

our ($opt_d);
getopts('d:') or die $!;
my @DEBUG_CATEGORIES;
my $DEBUG_CATEGORY_WIDTH = 13;
if ($opt_d) {
    @DEBUG_CATEGORIES = split(/[,\s]+/,$opt_d);
    if ($opt_d !~ /all/) {
        $DEBUG_CATEGORY_WIDTH = max(map { length } @DEBUG_CATEGORIES);
    }
}

my $DEPTH_DEBUG = 0;
my %GEN_TIMES;

# struct Thing {
#     Name name;
#     List<Thing*> dependants;
#     List<Thing*> dependsOn;
# };
# Map<Name, Thing*> ALL;
my %ALL;

my %TIMERS;

my $target = shift or die "Need target";

my ($base0, $type0) = basetype($target);

printDebugC('phase', "begin compile dep gen phase\n");
timerStart('total','compileDeps');
my $firstTarget;
if ($type0 eq 'EXE') {
    $firstTarget = "$base0.$OBJ_EXT";
    #    addDeps($target, 'dependsOn', $firstTarget);
    #    addDeps($firstTarget, 'dependants', $target);
} else {
    $firstTarget = $target;
}
blah_v4($firstTarget);
timerStop('compileDeps');
printDebugC('phase', "end compile dep gen phase\n");
#printDebugC('total', "compile_deps:\n".Dumper($compile_deps)."\n");

#printGlobalDeps('deps');
#printDebugC('deps',"ALL{$firstTarget}:\n".Dumper($ALL{$firstTarget})."\n");
printDebugC('deps',"post-compile deps phase:\n" . dumpDeps());

# FIXME because I removed link_deps thing, I am missing knowledge of what's needed for exe.  None of the objs besides main.o are being built anymore.
if ($type0 eq 'EXE') {
    timerStart('linkDeps');
    printDebugC('phase',"begin link dep gen phase\n");
    while (1) {

        # Every src (and yet-to-exist obj) that was created during the dependency generation process for main.o is a dependency for main.exe.
        my $doneE = 0;
        {
            #my @srcs = uniq(
            #    depsHdrToSrc($compile_deps),
            #    depsHdrToSrc($link_deps));
            #my @srcs = depsHdrToSrc_global(\%DEPS);
            my @srcs = map { base($_).'.c' } grep {/\.$HDR_EXT$/} keys %ALL; # @src_ext_cheat

            #@srcs = grep {-f} @srcs;
            @srcs = grep { blah_v4($_) eq 'already_exists' } @srcs;

            printDebugC('link',"existing srcs: @srcs\n");
            if (@srcs) {
                my @objs = map { base($_).'.'.$OBJ_EXT } @srcs;
                if (all { -f } @objs) {
                    printDebugC('link',"all obj for src already exist: @objs\n");
                    $doneE = 1;
                } else {
                    for (@objs) { blah_v4($_); }
                }
            } else {
                $doneE = 1;
            }
        }

        # For all dependencies that are hdrs with no matching src, try to generate the src.  if successful, the obj is needed for linking main.exe
        my $doneLDO = 0;
        {
            my @srcs = map { base($_).'.c' } grep {/\.$HDR_EXT$/} keys %ALL; # @src_ext_cheat

            my @generatedSrcs = grep { blah_v4($_) eq 'succeeded' } @srcs;
            if (@generatedSrcs) {
                my @objs = map { base($_).'.'.$OBJ_EXT } @generatedSrcs;
                for (@objs) { blah_v4($_); }
            } else {
                $doneLDO = 1;
            }
        }
        if ($doneE and $doneLDO) { last; }
    }
    timerStop('linkDeps');
    printDebugC('phase',"end link dep gen phase\n");

    #printGlobalDeps('deps');
    #printDebugC('deps',"ALL{$firstTarget}\n".Dumper($ALL{$firstTarget})."\n");
    printDebugC('deps',"post-link deps phase:\n" . dumpDeps());
    #printDebugC('total', "link_deps:\n".Dumper($link_deps)."\n");
    generate($target, grep /\.$OBJ_EXT$/, keys %ALL);

}

timerStop('total');

printTimes_simple();

exit;

####

sub blah_v4 {
    my $x = shift;
    printDebugC('blah',"blah_v4($x)\n");
    $DEPTH_DEBUG++;
    my @Deps = determineDeps($x);
    addDeps($x, 'dependsOn', @Deps);
    for (@Deps) { addDeps($_, 'dependants', $x); }

    while (1) {
        my $all = 1;
        my @deps = keys %{$ALL{$x}->{dependsOn}};
        if (@deps) {
            my @done;
            my @notDone;
            for (@deps) {
                if (not -f $_ and not $FAILED_GEN{$_}) {
                    $all = 0;
                    push @notDone, $_; #TODO move out - for (@notDone) { blah($_); }
                    blah_v4($_);
                } else {
                    push @done, $_;
                }
            }
            printDebugC('blah',@done.'/'.@deps." deps done for $x: done = (@done), notDone = (@notDone)\n");
        } else {
            printDebugC('blah',"no deps for $x\n");
        }
        if ($all) { last; }
    }

    my $genState = tryGenerate($x);

    if ($genState eq 'succeeded' or $genState eq 'already_exists') {
        # Reprocess the dependencies for everything that depends on the target that was just generated.  (Because since it was just generated, there might be previously-unseen #includes in it, for example.)
        for my $f (keys %{$ALL{$x}->{dependants}}) {
            my @fDeps = determineDeps($f);
            # don't think I need this - GenIncGen.h doesn't have Gen.h as a dependant, despite revealing Gen.h to main.o (which is covered in the line after this)
            #addDeps($x, 'dependants', @fDeps);
            addDeps($f, 'dependsOn', @fDeps);
        }
    }

    $DEPTH_DEBUG--;
    return $genState;
}

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
    printDebugC('detDeps',"$target: @deps\n");
    return @deps;
}

# Never used this, moving to v12 to try it out
# Basically should be a replacement for part of blah_v4 because that function is doing both deps and gen, which I think is limiting dependency discovery on reruns of the script before a clean.
sub determineDepsRecursive {
    $DEPTH_DEBUG++;
    my $x = shift;
    my @deps = determineDeps($x);
    my @known = keys %{$ALL{$x}->{dependsOn}};
    my $diff = arrayDiff(\@known, \@deps);
    #    if (%$diff) {
    #        my @new;
    #        while (my ($val, $which) = each %$diff) {
    #            if ($which eq 'b') {
    #                push @new, $val;
    #            } else {
    #                confess("which = ".($which?$which:'undef') ." for val = $val after array diff between known (@known) and deps (@deps)");
    #            }
    #        }
    #        printDebugC('detDepsR', "$x: new = (@new), all = (@deps)\n");
    #        if (@new) {
    #            addDeps($x, 'dependsOn', @Deps);
    #            for (@new) { addDeps($_, 'dependants', $x); }
    #        }
    #    }
    addDeps($x, 'dependsOn', @deps);
    for (@deps) { addDeps($_, 'dependants', $x); }
    for (@deps) { determineDepsRecursive($_); }
    $DEPTH_DEBUG--;
}

sub tryGenerate {
    my $x = shift;
    my $genState;
    if (-f $x) {
        $genState = 'already_exists';
    } elsif ($FAILED_GEN{$x}) {
        $genState = 'failed_previously';
    } elsif (generate($x)) {
        $genState = 'succeeded';
    } else {
        $genState = 'failed';
    }
    printDebugC('tryGen',"$x: $genState\n");
    return $genState;
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
        printDebugC('gen',"generated $x\n");
        $GEN_TIMES{$x} = Time::HiRes::tv_interval($time0, [Time::HiRes::gettimeofday()]);
    } else {
        printDebugC('gen',"failed to generate $x\n");
        $FAILED_GEN{$x} = 1;
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

    my $cmd = "cl /nologo /c /Fo$x $src > NUL";
    printDebugC('cmd',"$cmd\n");
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
    printDebugC('cmd',"$cmd\n");
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
        my $pad = '';
        for (1..$DEPTH_DEBUG) { $pad .= '- '; }
        print STDOUT '['.NAME."][debug] $pad@_";
    }
}

sub printDebugC {
    if (DEBUG) {
        my $cat = shift;
        if (grep { /^($cat|all)$/i } @DEBUG_CATEGORIES) {
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
    createIfMissing($x);
    createIfMissing(@_);
    my @new;
    for (@_) {
        unless (exists $ALL{$x}->{$key}->{$_}) {
            $ALL{$x}->{$key}->{$_} = $ALL{$_};
            push @new, $_;
        }
    }
    printDebugC('new',"$x $key += @new\n");
}

sub createIfMissing {
    for (@_) {
        if (not exists $ALL{$_}) {
            $ALL{$_} = {
                name => $_,
                dependsOn => {},
                dependants => {}
            };
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
        $TIMERS{$_}->{elapsed} = $elapsed;
    }
    return timerGet(@_);
}

sub timerGet {
    my @elapsed = map { $TIMERS{$_}->{elapsed} } @_;
    return @elapsed==1 ? @elapsed : $elapsed[0];
}

sub dumpDeps {
    my $s = '';
    for my $i (keys %ALL) {
        $s .= $i
            . "\n\tdependsOn: "
            . join(' ',keys $ALL{$i}->{dependsOn})
            . "\n\tdependants: "
            . join(' ',keys $ALL{$i}->{dependants})
            . "\n";
    }
    return $s;
}

#sub printTimes {
#    my ($totalElapsed, $compileDepsElapsed, $linkDepsElapsed, $cdeps, $ldeps) = @_;
#
#    # originals, to check my work
#    my $cdeO = $compileDepsElapsed;
#    my $ldeO = $linkDepsElapsed;
#
#    my %genTotals;
#    while (my ($f,$t) = each %GEN_TIMES) {
#        my $type = type($f);
#        if (exists $genTotals{$type}) {
#            $genTotals{$type} += $t;
#        } else {
#            $genTotals{$type} = $t;
#        }
#    }
#
#    for my $f (keys %$cdeps) {
#        if (exists $GEN_TIMES{$f}) {
#            #print "compileDE -= $GEN_TIMES{$f} ($f)\n";
#            $compileDepsElapsed -= $GEN_TIMES{$f};
#        }
#    }
#
#    for my $f (keys %$ldeps) {
#        if (exists $GEN_TIMES{$f}) {
#            #print "linkDE -= $GEN_TIMES{$f} ($f)\n";
#            $linkDepsElapsed -= $GEN_TIMES{$f};
#        }
#    }
#
#    my $genTotal = 0;
#    while (my ($type, $time) = each %genTotals) {
#        #printf "$type generation time: %.5f seconds\n", $time;
#        $genTotal += $time;
#    }
#
#    # FIXME my math is off, total time doesn't line up. I think the amount I'm reducing the DepsElapsed vars is not/double counting something.
#
#    #printf "Generation time: %.5f seconds\n", $genTotal;
#    #printf "Compilation dependency logic time: %.5f seconds (%f)\n", $compileDepsElapsed, $cdeO;
#    #printf "Link dependency logic time: %.5f seconds (%f)\n", $linkDepsElapsed, $ldeO;
#    #printf "Total time: %.5f seconds (%.5f + %.5f + %.5f = %f)\n", $totalElapsed, $genTotal, $compileDepsElapsed, $linkDepsElapsed, ($genTotal+$compileDepsElapsed+$linkDepsElapsed);
#
#    printf "Total time: %.5f seconds\n", $totalElapsed;
#}

# It took me too long to write this, now I don't remember what I was going to use it for.
#sub mergeHashes {
#    my ($dest, $src, $mode) = @_;
#    while (my ($sk, $sv) = each %$src) {
#        if (exists $dest->{$sk}) {
#            if ($mode =~ /passive/i) {
#                next;
#            } elsif ($mode =~ /(replace|overwrite|override)/i) {
#                $dest->{$sk} = $sv;
#            } elsif ($mode =~ /die.*exist/i) {
#                confess("$sk already exists in dest: dest = $dest->{$sk}, src = $sv");
#            }
#        } else {
#            $dest->{$sk} = $sv;
#        }
#    }
#}


#sub someLoop {
#    while (1) {
#        @deps = determineDependencies($x);
#        @new = arrayContainsAll(keys %{$ALL{$x}->{dependsOn}}, \@deps);
#        if (@new) {
#            
#        } else {
#            print "All deps for $x already known\n";
#            $doneDeps = 1;
#        }
#    }
#}


