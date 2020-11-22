our $VERSION = "6";
use strict;
use warnings FATAL => qw(uninitialized);
use File::Basename qw(basename);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin";
use Carp qw(confess);

use includes;
$includes::DIE_ON_MISSING = 0;

use constant NAME => basename($0);
use constant DEBUG => 1;

my $HDR_EXT = 'h'; # .hpp too? TODO .idl
my $OBJ_EXT = 'o'; # .obj too?
my @SRC_EXTS = qw/cpp c/;
my $SRC_EXT = 'SRC'; # generic marker b/c of list of possible exts
my $EXE_EXT = 'exe'; # TODO handle per platform?

my %SORT_ORDER = (HDR=>0, SRC=>1, OBJ=>2, EXE=>3);

my @GEN_QUEUE;
my @DEP_QUEUE;

#my %GENERATED;
my %EXISTS;

#my %GEN_DONE;
#my %DEP_DONE;

my $target = shift or die "Need target";

my $isExec = 0;
#if ($target =~ /^([\w\/]+)(\.exe)?$/) {
#    $isExec = 1;
#}

processDep($target);
my %depDone;
my %genDone;

#while (@DEP_QUEUE or @GEN_QUEUE) {
#    my @q;
#    @q = @DEP_QUEUE;
#    @DEP_QUEUE = ();
#    for my $x (@q) {
#        unless ($depDone{$x}) {
#            processDep($x);
#            $depDone{$x} = 1;
#        }
#    }
#    @q = @GEN_QUEUE;
#    @GEN_QUEUE = ();
#    for my $x (@q) {
#        unless ($genDone{$x}) {
#            processGen($x);
#            $genDone{$x} = 1;
#        }
#    }
#}

while (@DEP_QUEUE or @GEN_QUEUE) {
    # dep prio > gen prio
    if (@DEP_QUEUE == 0) {
        my $x = shift @GEN_QUEUE;
        unless ($genDone{$x}) {
            processGen($x);
            $genDone{$x} = 1;
        }
    } else {
        my $x = shift @DEP_QUEUE;
        unless ($depDone{$x}) {
            if (processDep($x)) {
                # setting this conditionally (along with returning 0 from processDep where appropriate) fixed the issue where GenIncGenSrc.h deps wouldn't be reprocessed. not 100% confident that the item's dependencies will be reprocessed though.  it's kind of weird to return 0 from processDep and assume that the target will be generated.  maybe I'm overthinking it though.
                $depDone{$x} = 1;
            }
        }
    }
}

print "loop done\n";

processGen($target);
exit;


# alt main loop to try in the future
# this would have to be done with changes to 'process' subs so that they would
# not enqueue anything.  this would do that instead.  not sure it would work,
# but if it did, control flow might be more clear (mostly here instead of subs)
#push @DEP_QUEUE, $target;
#while (@DEP_QUEUE or @GEN_QUEUE) {
#    # dep prio > gen prio
#    if (@DEP_QUEUE == 0) {
#        my $x = shift @GEN_QUEUE;
#        unless ($genDone{$x}) {
#            my $success = processGen($x);
#            if ($success) {
#                $genDone{$x} = 1;
#            } else {
#                die "Failed to generate $x"; # way more nuance to this depending on type
#            }
#        }
#    } else {
#        my $x = shift @DEP_QUEUE;
#        unless ($depDone{$x}) {
#            my $success = processDep($x);
#            if ($success) {
#                $depDone{$x} = 1;
#                $depState{$x} = 'done';
#            } else {
#                push @DEP_QUEUE, $x; # push instead of unshift
#
#            }
#        }
#    }
#}




# some wasted effort here because most places this is called already have 'exists' info, but don't pass it. so either those places don't need it or they could pass it here.  not sure it's worth adapting this sub to accept both types because it would probably just be more confusing. not like '-f' is a huge timesink (is it?)
sub enqueue {
    for (@_) {
        if (fileExists($_)) {
            enqueueDep($_);
        } else {
            enqueueDep($_); # enq_both: new 2020-Sep-07 17:54
            enqueueGen($_);
        }
    }
}

sub enqueueDep {
    printDebug("enqueueDep: @_\n");
    push @DEP_QUEUE, @_;
}

sub enqueueGen {
    printDebug("enqueueGen: @_\n");
    push @GEN_QUEUE, @_;
    @GEN_QUEUE = sort {
        my (undef, $aType) = basetype($a);
        my (undef, $bType) = basetype($b);
        #print "a = $a, aType = " . ($aType?$aType:'undef')
        #  . ", b = $b, bType = " . ($bType?$bType:'undef')
        #  . "\n";
        $SORT_ORDER{$aType} <=> $SORT_ORDER{$bType}
    } @GEN_QUEUE;
}

sub processGen {
    my $x = shift;
    printDebug("processGen: $x\n");
    if (isHdr($x)) {
        if (fileExists($x) or generateInc($x)) {
            enqueueDep($x);
        } else {
            printError("does not exist: $x\n");
        }
    } elsif (isSrc($x)) { # this only matches on actual src exts, not on .SRC
        if (fileExists($x) or generateSrc($x)) {
            enqueueDep($x);
        }
        # not an error if doesn't exist, at least for now.
        # probably will just wait for linker error.
        # not sure there's a way to know which headers are
        # standalone and which have src pairs.
    } elsif ($x =~ /(.+)\.$SRC_EXT$/) {
        my $base = $1;
        # maybe it already exists
        # don't need to gen if so
        for my $e (@SRC_EXTS) {
            my $tmp = "$base.$e";
            if (fileExists($tmp)) {
                enqueueDep($tmp);
                return;
            }
        }
        # didn't exist, try to gen
        for my $e (@SRC_EXTS) {
            my $tmp = "$base.$e";
            if (generateSrc($tmp)) {
                enqueueDep($tmp);
            }
        }
    } elsif (isObj($x)) {
        if (fileExists($x) or generateObj($x)) {
            enqueueDep($x);
        } else {
            printError("does not exist: $x\n");
        }
    } elsif (isExe($x)) {
        generateExe($x);
    } else {
        printError("processGen: don't know what to do with '$x'\n");
    }
}

sub processDep {
    my $x = shift;
    printDebug("processDep: $x\n");
    if (isHdr($x)) {
        unless (fileExists($x)) {
            enqueueGen($x);
            return 0;
        }
        my $incs = includes::find($x);
        enqueue(keys %$incs);
        if ($isExec) {
            my $srcsDirect = srcsE($HDR_EXT, $x);
            my $srcsInc = srcsE($HDR_EXT, keys %$incs);
            my %srcs = (%$srcsDirect, %$srcsInc);
            while (my ($name, $exists) = each %srcs) {
                #if ($exists) { enqueueDep($name); }
                #else { enqueueGen($name); }
                #enq_both
                enqueue($name);
            }
        }
    } elsif (isSrc($x)) { # shouldn't be a need to handle .SRC, as the actual file should have already been generated at this point
        unless (fileExists($x)) {
            enqueueGen($x);
            return 0; # this is a case where this will work ok because gen queues src for dep after it creates it, but might be more obvious if it were already in the dep queue and just was also added to the gen queue.
        }
        my $incs = includes::find($x);
        enqueue(keys %$incs);
        if ($isExec) { # not sure, just getting rid of it for obj initial target
            my $obj;
            for my $e (@SRC_EXTS) {
                my $tmp = $x;
                if ($tmp =~ s/\.$e$/\.$OBJ_EXT/) {
                    $obj = $tmp;
                    last;
                }
            }
            enqueue($obj);
        }
    } elsif ($x =~ /(.+)\.$SRC_EXT$/) {
        my $base = $1;
        for my $e (@SRC_EXTS) {
            my $tmp = "$base.$e";
            if (fileExists($tmp)) {
                enqueueDep($tmp); # reenqueue with actual name #TODO make sure it's removed from dep queue. it is right now because everything is, but if conditionally removing depending on what happens here, this should return "success"
                return 1;
            }
        }
        enqueueGen($x);
    } elsif (isObj($x)) {
        my $src = $x =~ s/\.$OBJ_EXT$/\.$SRC_EXT/r;
        enqueue($src);
    } elsif (isExe($x)) {
        $isExec = 1;
        my ($base, undef) = basetype($x);
        my $obj = "$base.$OBJ_EXT";
        enqueue($obj);
    } else {
        printError("processDep: don't know what to do with '$x'\n");
    }
    return 1;
}

sub isHdr {
    return ($_[0] =~ /\.$HDR_EXT$/);
}

sub isSrc {
    for my $e (@SRC_EXTS) {
        if ($_[0] =~ /\.$e$/) {
            return 1;
        }
    }
    return 0;
}

sub isObj {
    return ($_[0] =~ /\.$OBJ_EXT$/);
}

sub isExe {
    return ($_[0] =~ /^([\w\/]+)(\.$EXE_EXT)?$/);
}

sub generateInc {
    if (my $x = _copy_gen(@_)) {
        $x =~ s/\..+$//;
        $EXISTS{$x}->{HDR} = 'generated';
        return 1;
    }
    return 0;
}

sub generateSrc {
    if (my $x = _copy_gen(@_)) {
        $x =~ s/\..+$//;
        $EXISTS{$x}->{SRC} = 'generated';
        return 1;
    }
    return 0;
}

sub _copy_gen {
    die unless scalar(@_) == 1;
    my $file = shift;
    if (copy("gen/$file", $file)) {
        printInfo("generated $file\n");
        return 1;
    } else {
        # whether this is an error depends on context, so let caller handle it
        printDebug("don't know how to generate $file\n");
        return 0;
    }
}

sub generateObj {
    my $x = shift;
    my ($base, undef) = basetype($x);
    unless ($base) { confess(); }
    my $src;
    for my $e (@SRC_EXTS) {
        my $tmp = "$base.$e";
        if (fileExists($tmp)) {
            $src = $tmp;
            last;
        }
    }
    unless ($src) { confess(); }

    my $cmd = "cl /nologo /c /Fo$x $src";
    printDebug("$cmd\n");
    if (system($cmd)) {
        printError("generateObj: command failed: '$cmd'\n");
        confess(getQueueInfo());
        #exit; # return 0 ?
    }
    return 1;
}

sub generateExe {
    my $x = shift;
    #TODO so here is where we see one issue of not keeping a dependency tree in memory.  how do I know which objs to use for linking?  obviously I can *.o and hope for the best, but what if they're in different directories, or what if two objs have conflicting definitions because they're not part of the same program?
    my $cmd = "link /nologo /OUT:$x *.$OBJ_EXT";
    printDebug("$cmd\n");
    if (system($cmd)) {
        printError("generateExe: command failed: '$cmd'\n");
        confess(getQueueInfo());
        #exit; # return 0 ?
    }
}

sub getQueueInfo {
    my $s = "DEP_QUEUE:\n\t".join("\n\t",@DEP_QUEUE)
        . "\nGEN_QUEUE:\n\t".join("\n\t",@GEN_QUEUE);
    return $s;
}

sub srcsE {
    my $inExt = shift;
    my %srcs;
    for my $x (@_) {
        my $base = $x;
        unless ($base =~ s/\.$inExt$//) {
            die "Expected *.$inExt but got $x";
        }
        my $srcExists = 0;
        my $src = undef;
        for my $ext (@SRC_EXTS) {
            my $s = "$base.$ext";
            if (fileExists($s)) {
                $src = $s;
                last;
            }
        }
        if ($src) {
            $srcs{$src} = 1;
        } else {
            $srcs{"$base.$SRC_EXT"} = 0;
        }

    }
    return \%srcs;
}

sub fileExists {
    my $x = shift;
    my ($base, $type) = basetype($x);
    if (-f $x) {
        if (not exists $EXISTS{$base}->{$type}) {
            $EXISTS{$base}->{$type} = 'alreadyExisted';
        }
        return 1;
    } else {
        #doesn't work with placeholder 'SRC' ofc #if (exists $EXISTS{$base}{$type}) { confess(); } # this should only have existant files in it
        return 0;
    }
}

sub basetype {
    my $x = shift;
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
    }
    return ($base, $type);
}

sub printError {
    print STDERR 'ERROR ['.NAME."] @_";
}

sub printInfo {
    print STDOUT '['.NAME."][info] @_";
}

sub printDebug {
    if (DEBUG) { print STDOUT '['.NAME."][debug] @_"; }
}


