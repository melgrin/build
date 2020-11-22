our $VERSION = "4.5";

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

my @GEN_QUEUE;
my @DEP_QUEUE;

#my %GENERATED;
my %EXISTS;

#my %GEN_DONE;
#my %DEP_DONE;

my $target = shift or die "Need target";

my $isExec = 0;
if ($target =~ /^([\w\/]+)(\.exe)?$/) {
    $isExec = 1;
}

processDep($target);
my %depDone;
my %genDone;
while (@DEP_QUEUE or @GEN_QUEUE) {
    my @q;
    @q = @DEP_QUEUE;
    @DEP_QUEUE = ();
    for my $x (@q) {
        unless ($depDone{$x}) {
            processDep($x);
            $depDone{$x} = 1;
        }
    }
    @q = @GEN_QUEUE;
    @GEN_QUEUE = ();
    for my $x (@q) {
        unless ($genDone{$x}) {
            processGen($x);
            $genDone{$x} = 1;
        }
    }
}
processGen($target);
exit;

# some wasted effort here because most places this is called already have 'exists' info, but don't pass it. so either those places don't need it or they could pass it here.  not sure it's worth adapting this sub to accept both types because it would probably just be more confusing. not like '-f' is a huge timesink (is it?)
sub enqueue {
    for (@_) {
        if (fileExists($_)) {
            enqueueDep($_);
        } else {
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
            if (-f $tmp) {
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
            return;
        }
        my $incs = includes::find($x);
        enqueue(keys %$incs);
        if ($isExec) {
            my $srcsDirect = srcsE($HDR_EXT, $x);
            my $srcsInc = srcsE($HDR_EXT, keys %$incs);
            my %srcs = (%$srcsDirect, %$srcsInc);
            while (my ($name, $exists) = each %srcs) {
                if ($exists) { enqueueDep($name); }
                else { enqueueGen($name); }
            }
        }
    } elsif (isSrc($x)) { # shouldn't be a need to handle .SRC, as the actual file should have already been generated at this point
        unless (fileExists($x)) {
            enqueueGen($x);
            return;
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
    } elsif (isObj($x)) {
        my $src = $x =~ s/\.$OBJ_EXT$/\.$SRC_EXT/r;
        enqueue($src);
    } else {
        printError("processDep: don't know what to do with '$x'\n");
    }
}

sub isHdr {
    my $x = shift;
    return ($x =~ /\.$HDR_EXT$/);
}

sub isSrc {
    my $x = shift;
    for my $e (@SRC_EXTS) {
        if ($x =~ /\.$e$/) {
            return 1;
        }
    }
    return 0;
}

sub isObj {
    my $x = shift;
    return ($x =~ /\.$OBJ_EXT$/);
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
    my $base = $x =~ s/\.$OBJ_EXT$//r or die "Doesn't have obj ext: '$x'";
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
        exit; # return 0 ?
    }
    return 1;
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
            if (-f $s) {
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
        $EXISTS{$base}->{$type} = 'alreadyExisted';
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


