our $VERSION = "9";
use strict;
use warnings FATAL => qw(uninitialized);
use File::Basename qw(basename);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin";
use Carp qw(confess);
use Time::HiRes;
use Getopt::Std;

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

my $target = shift or die "Need target";
my $BLAH_DEPTH = 0;
my %DEPS;
# so you know what targets need to have their dependencies reprocessed after you generate something (key = just generated)
my %WHO_DEPENDS_ON;

my $totalTime0 = [Time::HiRes::gettimeofday()];

my ($base0, $type0) = basetype($target);

printDebugC('phase', "begin compile dep gen phase\n");
my $compile_deps = {};
my $compileDepsTime0 = [Time::HiRes::gettimeofday()];
if ($type0 eq 'EXE') {
    blah_v3("$base0.$OBJ_EXT", $compile_deps);
} else {
    blah_v3($target, $compile_deps);
}
my $compileDepsElapsed = Time::HiRes::tv_interval($compileDepsTime0, [Time::HiRes::gettimeofday()]);
printDebugC('phase', "end compile dep gen phase\n");
printDebugC('total', "compile_deps:\n".Dumper($compile_deps)."\n");

printGlobalDeps('deps');


my %GEN_TIMES;

my $linkDepsTime0 = [Time::HiRes::gettimeofday()];
my $link_deps = {};
if ($type0 eq 'EXE') {
    printDebugC('phase',"begin link dep gen phase\n");
    while (1) {

        my $doneSAE = 0;
        my @srcAlreadyExists = srcAlreadyExists();

        if (@srcAlreadyExists) {

            my @objs = map { base($_).'.'.$OBJ_EXT } @srcAlreadyExists;
            my $allObjExists = 1;
            for (@objs) { unless (-f) { $allObjExists = 0; } }

            if ($allObjExists) {
                printDebugC('link',"all obj for src already exists\n");
                $doneSAE = 1;
            } else {
                for (@objs) { blah_v3($_, $link_deps); }
            }

        } else {
            $doneSAE = 1;
        }

        my $doneLDO = 0;
        my @linkDepObjs = linkDepObjs();
        if (@linkDepObjs) {
            for (@linkDepObjs) { blah_v3($_, $link_deps); }
        } else {
            $doneLDO = 1;
        }

        if ($doneSAE and $doneLDO) { last; }
    }
    printDebugC('phase',"end link dep gen phase\n");

    printGlobalDeps('deps');
    printDebugC('total', "link_deps:\n".Dumper($link_deps)."\n");
    my @objs = ("$base0.$OBJ_EXT", grep /\.$OBJ_EXT$/, keys %$link_deps);
    generate($target, @objs);

}
my $linkDepsElapsed = Time::HiRes::tv_interval($linkDepsTime0, [Time::HiRes::gettimeofday()]);

my $cdeO = $compileDepsElapsed;
my $ldeO = $linkDepsElapsed;

my $totalElapsed = Time::HiRes::tv_interval($totalTime0, [Time::HiRes::gettimeofday()]);

{
    my %genTotals;
    while (my ($f,$t) = each %GEN_TIMES) {
        my $type = type($f);
        if (exists $genTotals{$type}) {
            $genTotals{$type} += $t;
        } else {
            $genTotals{$type} = $t;
        }
    }

    for my $f (keys %$compile_deps) {
        if (exists $GEN_TIMES{$f}) {
            print "compileDE -= $GEN_TIMES{$f} ($f)\n";
            $compileDepsElapsed -= $GEN_TIMES{$f};
        } else {
            print "$f not in GEN_TIMES\n";
        }
    }

    for my $f (keys %$link_deps) {
        if (exists $GEN_TIMES{$f}) {
            print "linkDE -= $GEN_TIMES{$f} ($f)\n";
            $linkDepsElapsed -= $GEN_TIMES{$f};
        } else {
            print "$f not in GEN_TIMES\n";
        }
    }

    my $genTotal = 0;
    while (my ($type, $time) = each %genTotals) {
        printf "$type generation time: %.5f seconds\n", $time;
        $genTotal += $time;
    }

    printf "Generation time: %.5f seconds\n", $genTotal;
    printf "Compilation dependency logic time: %.5f seconds (%f)\n", $compileDepsElapsed, $cdeO;
    printf "Link dependency logic time: %.5f seconds (%f)\n", $linkDepsElapsed, $ldeO;
    printf "Total time: %.5f seconds (%.5f + %.5f + %.5f = %f)\n", $totalElapsed, $genTotal, $compileDepsElapsed, $linkDepsElapsed, ($genTotal+$compileDepsElapsed+$linkDepsElapsed);
}

exit;

####

sub srcAlreadyExists {
    my @allHdrs;
    for my $i (keys %DEPS) {
        for my $j (keys %{$DEPS{$i}}) {
            if ($j =~ /\.$HDR_EXT$/) {
                unless (-f $j) { die "$j should already exist as part of compile gen"; }
                push @allHdrs, $j;
            }
        }
    }
    my %exists;
    for (@allHdrs) {
        my $src = base($_) . '.' . 'c'; # @src_ext_cheat
        if (-f $src) {
            $exists{$_} = 1;
        }
    }

    printDebugC('link',"srcAlreadyExists\n\t" . join("\n\t",keys %exists) . "\n");
    return keys %exists;
}

sub linkDepObjs {
    #XXX
    # all the headers should be created at this point
    my @hdrs;
    for my $i (keys %DEPS) {
        for my $j (keys %{$DEPS{$i}}) {
            if ($j =~ /\.$HDR_EXT$/) {
                unless (-f $j) { die "$j should already exist as part of compile gen"; }
                push @hdrs, $j;
            }
        }
    }
    my %tryToGenSrc;
    for (@hdrs) {
        my $src = base($_) . '.' . 'c'; # @src_ext_cheat
        $tryToGenSrc{$src} = 1;
    }
    my %linkDepObjs;
    my %srcGenFailed;
    my %srcAlreadyExists;
    for (keys %tryToGenSrc) {
        if (-f) {
            $srcAlreadyExists{$_} = 1;
        } else {
            if ($FAILED_GEN{$_}) {
                $srcGenFailed{$_} = 1;
            } elsif (generate($_)) { # if I'm feeling fancy, maybe generate should be replaced with 'blah'??
                my $obj = base($_) . ".$OBJ_EXT";
                $linkDepObjs{$obj} = 1;
            } else {
                $srcGenFailed{$_} = 1;
            }
        }
    }
    #my @objAlreadyExists;
    #my @objDoesNotExist;

    printDebugC('link',"linkDepObjs\n\t"      . join("\n\t",keys %linkDepObjs)      . "\n");
    printDebugC('link',"srcGenFailed\n\t"     . join("\n\t",keys %srcGenFailed)     . "\n");
    printDebugC('link',"srcAlreadyExists\n\t" . join("\n\t",keys %srcAlreadyExists) . "\n");
    #print "objAlreadyExists\n\t" . join("\n\t",@objAlreadyExists) . "\n";
    #print "objDoesNotExist\n\t"  . join("\n\t",@objDoesNotExist)  . "\n";

    return keys %linkDepObjs;
}

sub blah_v3 {
    my $x = shift;
    my $total = shift || {};
    printDebugC('blah',"blah_v3($x)\n");
    $BLAH_DEPTH++;
    my @Deps = processDeps($x);
    updateGlobalDeps($x, @Deps);
    my %rDeps;
    my $i = 0;
    while (1) {
        # the recursive call to blah updates DEPS, so can't just use output from processDeps from before this loop
        my @deps = keys %{$DEPS{$x}}; 
        my $all = 1;
        if (@deps) {
            my @done;
            my @notDone;
            for my $d (@deps) {
                unless (exists $rDeps{$d}) { $rDeps{$d} = $i; }
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

    my $genState = '';
    if (-f $x) {
        $genState = 'already_exists';
    } elsif ($FAILED_GEN{$x}) {
        $genState = 'failed_previously';
    } elsif (generate($x)) {
        $genState = 'succeeded';
    } else {
        $genState = 'failed';
    }
    printDebugC('blah',"$x: generation $genState\n");

    if ($genState eq 'succeeded') {
        # not sure this is necessary, try using brain later to figure it out
        for my $f (keys %{$WHO_DEPENDS_ON{$x}}) {
            my @fDeps = processDeps($f);
            updateGlobalDeps($f, @fDeps);
            # recursively update all WHO_DEPENDS_ON?
        }
        #if ($IN_LINK_PHASE) {
        #    # mark who deps?
        #}
    }

    my $infoOut = {
        target => $x,
        gen => $genState,
        deps_immediate => \@Deps, # aref
        deps_post_recursion => \%rDeps, # href, v=iteration
        deps_global => $DEPS{$x}, # href, v=depth
        depth => $BLAH_DEPTH
    };
    #print "deps_post_recursion: $x: ". Dumper(\%rDeps) . "\n";
    printDebugC('info',$x.': '.Dumper($infoOut)."\n");

    $total->{$x} = $infoOut;
    if (not arrayEq( # don't need both, probably
            [keys %{$infoOut->{deps_post_recursion}}],
            [keys %{$infoOut->{deps_global}}])) {
        confess(Dumper($infoOut));
    }

    $BLAH_DEPTH--;

    return $infoOut;
}

sub updateGlobalDeps {
    my $target = shift;
    return unless @_;
    my @newdeps;
    for (@_) {
        # "unless exists" and iteration/depth value is just for debug purposes, to see in which iteration something was discovered
        unless (exists $DEPS{$target}->{$_}) {
            push @newdeps, $_;
            $DEPS{$target}->{$_} = $BLAH_DEPTH;
        }
        unless (exists $WHO_DEPENDS_ON{$_}->{$target}) {
            $WHO_DEPENDS_ON{$_}->{$target} = $BLAH_DEPTH;
        }
    }
    printDebugC('update',"$target += @newdeps\n");
}

sub processDeps {
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

        #if ($EXE_TARGET) {
        #    #dup? push @deps, "$base.c"; # @src_ext_cheat
        #}

    } elsif ($type eq 'HDR') {

        # push @deps - nothing now, maybe something for .idl

        #if ($EXE_TARGET) {
        #    for (keys %{includes::find($target)}) {
        #        #my $obj = base($target) . ".$OBJ_EXT";
        #        #setLinkDep($EXE_TARGET, $obj);
        #        # the obj link dep is accounted for in SRC case of this sub
        #        my $src = base($_) . ".c"; # @src_ext_cheat
        #        setLinkDep($EXE_TARGET, $src);
        #    }
        #}

    } elsif ($type eq 'SRC') {

        # push @deps - nothing now, maybe something for .idl

        #if ($EXE_TARGET) {
        #    for (keys %{includes::find($target)}) {
        #        my $src = base($_) . ".c"; # @src_ext_cheat
        #        setLinkDep($EXE_TARGET, $src);
        #    }
        #    my $obj = "$base.$OBJ_EXT";
        #    setLinkDep($EXE_TARGET, $obj);
        #}

    } elsif ($type eq 'EXE') {

        die "disallowing for now.  putting logic in top of main to detect exe and handle differently.  otherwise this will cause exe to try to be generated when main.o is done.  to prevent, would have to go back down the rabbit hole of tracking exe deps in this sub.";

        push @deps, "$base.$OBJ_EXT";

        #$EXE_TARGET = $target;

    } else {
        die "script not done for $type files yet (target = $target)";
    }
    printDebugC('processDeps',"processDependencies($target) = @deps\n");
    return @deps;

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
    _helpPrintHash($cat,'DEPS', \%DEPS);
    _helpPrintHash($cat,'WHO_DEPENDS_ON', \%WHO_DEPENDS_ON);
}

sub _helpPrintHash {
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
    printDebugC($cat, $text);
}

sub printError {
    print STDERR 'ERROR ['.NAME."] @_";
}

sub printInfo {
    print STDOUT '['.NAME."][info] @_";
}

sub printDebug {

    #if (DEBUG) { print STDOUT '['.NAME."][debug] @_"; }

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
