our $VERSION = "10";
use strict;
use warnings FATAL => qw(uninitialized);
use File::Basename qw(basename);
use File::Copy qw(copy);
use FindBin;
use Carp qw(confess);
use Time::HiRes;
use Getopt::Std;
use List::Util qw(all);

use lib "$FindBin::Bin";
use includes;
$includes::DIE_ON_MISSING = 0;

use Data::Dumper;
$Data::Dumper::Terse = 1;
$Data::Dumper::Indent = 2;
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
if ($opt_d) { @DEBUG_CATEGORIES = split(/[,\s]+/,$opt_d); }

my $BLAH_DEPTH = 0;
my %GEN_TIMES;

my %DEPS;
my %WHO_DEPENDS_ON;

my $target = shift or die "Need target";

my ($base0, $type0) = basetype($target);

printDebugC('phase', "begin compile dep gen phase\n");
my $compile_deps = {};
my $totalTime0 = [Time::HiRes::gettimeofday()];
my $compileDepsTime0 = $totalTime0;
if ($type0 eq 'EXE') {
    blah_v3("$base0.$OBJ_EXT", $compile_deps);
} else {
    blah_v3($target, $compile_deps);
}
my $compileDepsElapsed = Time::HiRes::tv_interval($compileDepsTime0, [Time::HiRes::gettimeofday()]);
printDebugC('phase', "end compile dep gen phase\n");
printDebugC('total', "compile_deps:\n".Dumper($compile_deps)."\n");

printGlobalDeps('deps');

my $link_deps = {};
my $linkDepsTime0 = [Time::HiRes::gettimeofday()];
if ($type0 eq 'EXE') {
    printDebugC('phase',"begin link dep gen phase\n");
    while (1) {

        # Every src (and yet-to-exist obj) that was created during the dependency generation process for main.o is a dependency for main.exe.
        my $doneE = 0;
        {
            my @srcs = uniq(
                depsHdrToSrc($compile_deps),
                depsHdrToSrc($link_deps));
            @srcs = grep {-f} @srcs;
            if (@srcs) {
                my @objs = map { base($_).'.'.$OBJ_EXT } @srcs;
                if (all { -f } @objs) {
                    printDebugC('link',"all obj for src already exists\n");
                    $doneE = 1;
                } else {
                    for (@objs) { blah_v3($_, $link_deps); }
                }
            } else {
                $doneE = 1;
            }
        }

        # For all dependencies that are hdrs with no matching src, try to generate the src.  if successful, the obj is needed for linking main.exe
        my $doneLDO = 0;
        {
            my @srcs = uniq(
                depsHdrToSrc($compile_deps),
                depsHdrToSrc($link_deps));
            #my @generatedSrcs = grep { tryGenerate($_) eq 'succeeded' } @srcs;
            my @generatedSrcs = grep { blah_v3($_)->{gen} eq 'succeeded' } @srcs;
            if (@generatedSrcs) {
                my @objs = map { base($_).'.'.$OBJ_EXT } @generatedSrcs;
                for (@objs) { blah_v3($_, $link_deps); }
            } else {
                $doneLDO = 1;
            }
        }
        if ($doneE and $doneLDO) { last; }
    }
    printDebugC('phase',"end link dep gen phase\n");

    printGlobalDeps('deps');
    printDebugC('total', "link_deps:\n".Dumper($link_deps)."\n");
    my @objs = ("$base0.$OBJ_EXT", grep /\.$OBJ_EXT$/, keys %$link_deps);
    generate($target, @objs);

}
my $linkDepsElapsed = Time::HiRes::tv_interval($linkDepsTime0, [Time::HiRes::gettimeofday()]);


my $totalElapsed = Time::HiRes::tv_interval($totalTime0, [Time::HiRes::gettimeofday()]);


printTimes($totalElapsed, $compileDepsElapsed, $linkDepsElapsed, $compile_deps, $link_deps);

exit;

####


## for every known header file, there might be a matching src already existing (either generated earlier or typical file)
#sub existingHdrSrcPairs {
#    my $cinfo = shift;
#    my %srcs;
#    for (values %$cinfo) {
#        my $cdeps = $_->{deps_global};
#        if ($cdeps) {
#            for (map { base($_).'.c' } grep {/\.$HDR_EXT$/} keys %$cdeps) { # @src_ext_cheat
#                #if (-f) { $srcs{$_} = 1; }
#                $srcs{$_} = 1;
#            }
#        }
#    }
#    my @srcsE = grep {-f} keys %srcs;
#    printDebugC('link',"existingHdrSrcPairs: @srcsE\n");
#    return @srcsE;
#}

sub depsHdrToSrc {
    my $info = shift;
    my @srcs;
    for (values %$info) {
        my $deps = $_->{deps_global};
        if ($deps) {
            for (map { base($_).'.c' } grep {/\.$HDR_EXT$/} keys %$deps) { # @src_ext_cheat
                push @srcs, $_;
            }
        }
    }
    return uniq(@srcs);
}



sub blah_v3 {
    my $x = shift;
    my $total = shift || {};
    printDebugC('blah',"blah_v3($x)\n");
    $BLAH_DEPTH++;
    my @Deps = determineDeps($x);
    updateGlobalDeps($x, @Deps);
    my $i = 0;
    while (1) {
        # the recursive call to blah updates DEPS, so can't just use output from determineDeps from before this loop
        my @deps = keys %{$DEPS{$x}}; 
        my @deps2 = keys %{$total->{$x}->{deps_global}};
        #print "$x deps diff = (" . join(' ',arrayDiff(\@deps, \@deps2)) . "\n";
        print "$x deps diff = " . Dumper(arrayDiff(\@deps, \@deps2)) . "\n";
        my $all = 1;
        if (@deps) {
            my @done;
            my @notDone;
            for my $d (@deps) {
                if (not -f $d and not $FAILED_GEN{$d}) {
                    $all = 0;
                    push @notDone, $d;
                    my $info = blah_v3($d, $total);
                } else {
                    push @done, $d;
                }
            }
            printDebugC('blah',''.scalar(@done).'/'.scalar(@deps)." deps done for $x: done = (@done), notDone = (@notDone)\n");
        } else {
            printDebugC('blah',"no deps for $x\n");
        }
        if ($all) { last; }

        $i++;
    }

    my $genState = tryGenerate($x);

    if ($genState eq 'succeeded') {
        # not sure this is necessary, try using brain later to figure it out
        for my $f (keys %{$WHO_DEPENDS_ON{$x}}) {
            my @fDeps = determineDeps($f);
            my @newDeps = updateGlobalDeps($f, @fDeps);
            #print "$f (depends on $x): new deps = @newDeps\n";
            #todo? recursively update all WHO_DEPENDS_ON?
        }
    }

    my $infoOut = {
        target => $x,
        gen => $genState,
        deps_immediate => \@Deps, # aref
        deps_global => $DEPS{$x}, # href, v=depth
        depth => $BLAH_DEPTH
    };
    printDebugC('info',$x.': '.Dumper($infoOut)."\n");
    $total->{$x} = $infoOut;

    $BLAH_DEPTH--;
    return $infoOut;
}

sub updateGlobalDeps {
    my $target = shift;
    return unless @_;
    my @newdeps;
    my @newwho;
    for (@_) {
        # "unless exists" and iteration/depth value is just for debug purposes, to see in which iteration something was discovered
        unless (exists $DEPS{$target}->{$_}) {
            push @newdeps, $_;
            $DEPS{$target}->{$_} = $BLAH_DEPTH;
        }
        unless (exists $WHO_DEPENDS_ON{$_}->{$target}) {
            push @newwho, $_;
            $WHO_DEPENDS_ON{$_}->{$target} = $BLAH_DEPTH;
        }
    }
    printDebugC('updateGlobalDeps',"$target += @newdeps (@newwho)\n");
    return @newdeps;
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
        die "exe dependency logic handled at top of script instead";
        #push @deps, "$base.$OBJ_EXT";
    } else {
        die "script not done for $type files yet (target = $target)";
    }
    printDebugC('determineDeps',"processDependencies($target) = @deps\n");
    return @deps;
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

    my $cmd = "cl /nologo /c /Fo$x $src";
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
    unless ($x =~ /(.+)\.(.+)$/) {
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

sub printGlobalDeps {
    my $cat = shift || 'deps';
    printDebugC($cat,formatDepHash('DEPS',\%DEPS));
    printDebugC($cat,formatDepHash('WHO_DEPENDS_ON', \%WHO_DEPENDS_ON));
}

sub formatDepHash {
    my ($cat, $name, $href) = @_;
    my $text = '';
    $text .= $name;
    for my $k (keys %{$href}) {
        my @s;
        for my $f (sort keys %{$href->{$k}}) {
            my $i = $href->{$k}->{$f};
            push @s, "$f($i)";
        }
        $text .= "\n\t$k: (" . join(', ',@s) . ')';
    }
    $text .= "\n";
    return $text;
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
        for (1..$BLAH_DEPTH) { $pad .= '- '; }
        print STDOUT '['.NAME."][debug] $pad@_";
    }
}

sub printDebugC {
    if (DEBUG) {
        my $cat = shift;
        if (grep { /^($cat|all)$/i } @DEBUG_CATEGORIES) {
            my $pad = '';
            for (1..$BLAH_DEPTH) { $pad .= '- '; }
            #print STDOUT '['.NAME."][debug][$cat] $pad@_";
            printf STDOUT '[%s][debug][%-8s] %s%s', NAME, $cat, $pad, @_;
        }
    }
}

sub arrayEq {
    my ($a, $b) = @_;
    if (not defined $a and not defined $b) { return 1; }
    elsif (not defined $a or not defined $b) { return 0; }
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
    my @d;
    my %d;
    for my $i (@$a) { unless (grep {$i eq $_} @$b) { push @d, $i; $d{$i} = 'a'; } }
    for my $i (@$b) { unless (grep {$i eq $_} @$a) { push @d, $i; $d{$i} = 'b'; } }
    #return @d;
    return \%d;
}

sub printTimes {
    my ($totalElapsed, $compileDepsElapsed, $linkDepsElapsed, $cdeps, $ldeps) = @_;

    # originals, to check my work
    my $cdeO = $compileDepsElapsed;
    my $ldeO = $linkDepsElapsed;

    my %genTotals;
    while (my ($f,$t) = each %GEN_TIMES) {
        my $type = type($f);
        if (exists $genTotals{$type}) {
            $genTotals{$type} += $t;
        } else {
            $genTotals{$type} = $t;
        }
    }

    for my $f (keys %$cdeps) {
        if (exists $GEN_TIMES{$f}) {
            #print "compileDE -= $GEN_TIMES{$f} ($f)\n";
            $compileDepsElapsed -= $GEN_TIMES{$f};
        }
    }

    for my $f (keys %$ldeps) {
        if (exists $GEN_TIMES{$f}) {
            #print "linkDE -= $GEN_TIMES{$f} ($f)\n";
            $linkDepsElapsed -= $GEN_TIMES{$f};
        }
    }

    my $genTotal = 0;
    while (my ($type, $time) = each %genTotals) {
        #printf "$type generation time: %.5f seconds\n", $time;
        $genTotal += $time;
    }

    # FIXME my math is off, total time doesn't line up. I think the amount I'm reducing the DepsElapsed vars is not/double counting something.

    #printf "Generation time: %.5f seconds\n", $genTotal;
    #printf "Compilation dependency logic time: %.5f seconds (%f)\n", $compileDepsElapsed, $cdeO;
    #printf "Link dependency logic time: %.5f seconds (%f)\n", $linkDepsElapsed, $ldeO;
    #printf "Total time: %.5f seconds (%.5f + %.5f + %.5f = %f)\n", $totalElapsed, $genTotal, $compileDepsElapsed, $linkDepsElapsed, ($genTotal+$compileDepsElapsed+$linkDepsElapsed);

    printf "Total time: %.5f seconds\n", $totalElapsed;
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

#sub srcAlreadyExists_global {
#    my @allHdrs;
#    for my $i (keys %DEPS) {
#        for my $j (keys %{$DEPS{$i}}) {
#            if ($j =~ /\.$HDR_EXT$/) {
#                unless (-f $j) { die "$j should already exist as part of compile gen"; }
#                push @allHdrs, $j;
#            }
#        }
#    }
#    my %exists;
#    for (@allHdrs) {
#        my $src = base($_) . '.' . 'c'; # @src_ext_cheat
#        if (-f $src) {
#            $exists{$src} = 1;
#        }
#    }
#
#    printDebugC('link','srcAlreadyExists: ' . join(' ', keys %exists) . "\n");
#    return keys %exists;
#}
#
#sub tryToGenerateMissingSrcs {
#    my $info = shift;
#    my @srcs = depsHdrToSrc($info);
#    my @generatedSrcs;
#    for my $x (@srcs) {
#        my $genState = tryGenerate($x);
#        if ($genState eq 'succeeded') {
#            #push @generatedSrcs, base($x).'.'.$OBJ_EXT;
#            push @generatedSrcs, $x;
#        }
#    }
#    printDebugC('link','tryToGenerateMissingSrcs: generated '
#        . (@generatedSrcs?join(' ',@generatedSrcs):'0 srcs') . "\n");
#    return @generatedSrcs;
#}
#
#sub linkDepObjs {
#    # all the headers should be created at this point
#    my @hdrs;
#    for my $i (keys %DEPS) {
#        for my $j (keys %{$DEPS{$i}}) {
#            if ($j =~ /\.$HDR_EXT$/) {
#                unless (-f $j) { die "$j should already exist as part of compile gen"; }
#                push @hdrs, $j;
#            }
#        }
#    }
#    my %tryToGenSrc;
#    for (@hdrs) {
#        my $src = base($_) . '.' . 'c'; # @src_ext_cheat
#        $tryToGenSrc{$src} = 1;
#    }
#    my %linkDepObjs;
#    my %srcGenFailed;
#    my %srcAlreadyExists;
#    for (keys %tryToGenSrc) {
#        if (-f) {
#            $srcAlreadyExists{$_} = 1;
#        } else {
#            if ($FAILED_GEN{$_}) {
#                $srcGenFailed{$_} = 1;
#            } elsif (generate($_)) { # if I'm feeling fancy, maybe generate should be replaced with 'blah'??
#                my $obj = base($_) . ".$OBJ_EXT";
#                $linkDepObjs{$obj} = 1;
#            } else {
#                $srcGenFailed{$_} = 1;
#            }
#        }
#    }
#    #my @objAlreadyExists;
#    #my @objDoesNotExist;
#
#    printDebugC('link','linkDepObjs: ' . join(' ', keys %linkDepObjs) . "\n");
#    printDebugC('link','srcGenFailed: ' . join(' ', keys %srcGenFailed) . "\n");
#    #printDebugC('link',"srcAlreadyExists\n\t" . join("\n\t",keys %srcAlreadyExists) . "\n");
#    #print "objAlreadyExists\n\t" . join("\n\t",@objAlreadyExists) . "\n";
#    #print "objDoesNotExist\n\t"  . join("\n\t",@objDoesNotExist)  . "\n";
#
#    return keys %linkDepObjs;
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

