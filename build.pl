our $VERSION = "4";

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

my %GENERATED;
my %EXISTS;

#my %GEN_DONE;
#my %DEP_DONE;

my $target = shift or die "Need target";

# convert target to obj
my $isExec;
my $obj;
if ($target =~ /^([\w\/]+)(\.exe)?$/) {
    $obj = "$1.$OBJ_EXT";
    $isExec = 1;
} elsif ($target =~ /^([\w\/]+)\.$OBJ_EXT$/) {
    $obj = "$1.$OBJ_EXT";
    $isExec = 0;
} else {
    die "Don't know what to do with target '$target'";
}

#enqueue($obj);
enqueueDep($obj);
my %genDone;
my %depDone;
while (@GEN_QUEUE or @DEP_QUEUE) {
    #my $x;
    #while ($x = shift @GEN_QUEUE) { processGen($x); }
    #while ($x = shift @DEP_QUEUE) { processDep($x); }

    my @q;

    @q = @GEN_QUEUE;
    @GEN_QUEUE = ();
    for my $x (@q) {
        unless ($genDone{$x}) {
            processGen($x);
            $genDone{$x} = 1;
        }
    }

    @q = @DEP_QUEUE;
    @DEP_QUEUE = ();
    for my $x (@q) {
        unless ($depDone{$x}) {
            processDep($x);
            $depDone{$x} = 1;
        }
    }
}

generateObj($obj) or die;


#print "$target\n";
#print "\n";
#print "ALL_INCS\n"; printStuff(\%ALL_INCS);
#print "ALL_SRCS\n"; printStuff(\%ALL_SRCS);
#print "ALL_OBJS\n\t" . join("\n\t", keys %ALL_OBJS);
#print "\n";

exit;

# some wasted effort here because most places this is called already have 'exists' info, but don't pass it. so either those places don't need it or they could pass it here.  not sure it's worth adapting this sub to accept both types because it would probably just be more confusing. not like '-f' is a huge timesink (is it?)
sub enqueue {
    for (@_) {
        if (-f) {
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
        if (-f $x or generateObj($x)) {
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
        my $incs = includes::find($x);
        enqueue(keys %$incs);
        my $obj;
        for my $e (@SRC_EXTS) {
            my $tmp = $x;
            if ($tmp =~ s/\.$e$/\.$OBJ_EXT/) {
                $obj = $tmp;
                last;
            }
        }
        enqueue($obj);
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
        $EXISTS{$x}{inc} = 1;
        return 1;
    }
    return 0;
}

sub generateSrc {
    if (my $x = _copy_gen(@_)) {
        $x =~ s/\..+$//;
        $EXISTS{$x}{src} = 1;
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

#sub generateSrc_handlesExts {
#    die unless @_ == 1;
#    my $file = shift;
#    unless ($file =~ s/\.$SRC_EXT$//) {
#        #die "Expected *.$SRC_EXT but got $file";
#        confess("Expected *.$SRC_EXT but got $file");
#    }
#    for my $ext (@SRC_EXTS) {
#        my $src = "$file.$ext";
#        if (copy("gen/$src", $src)) {
#            printInfo("generated $src\n");
#            return $src;
#        }
#    }
#    printDebug("failed to generate $file (@SRC_EXTS): $!\n");
#    return undef;
#}

sub generateObj {
    my $x = shift;
    $x =~ s/\.$OBJ_EXT$// or die "Doesn't have obj ext: '$x'";
    my $src = $GENERATED{$x}{src} or confess();
    #print "GENERATED\n" . Dumper(\%GENERATED) . "\n";
    #exit; #XXX

    my $cmd = "cl /nologo /c $src";
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
    if (-f $x) {
        $EXISTS{$x} = 1;
        return 1;
    } else {
        if (exists $EXISTS{$x}) { confess(); } # this should only have existant files in it
        return 0;
    }
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

# "blind" meaning just directly convert, don't check if it exists
#sub srcToObjsBlind {
#    my @objs;
#    for my $s (@_) {
#        my $o = $s;
#        for my $e (@SRC_EXTS) {
#            $o =~ s/\.$e$/\.$OBJ_EXT/;
#        }
#        push @objs, $o;
#    }
#    return @objs;
#}

# merge src into dest, modifying dest
#sub mergeHashes {
#    my ($dest, $src) = @_;
#    while (my ($k, $v) = each %$src) {
#        # being strict about this so I can tell if something weird is going on
#        # this is how you would do it if you didn't care about value overrides.  this syntax takes the values from the last hash in the list.
#        # %ALL_INCS = (%ALL_INCS, %$incsFromSrc);
#        if (exists $dest->{$k} and $dest->{$k} != $v) {
#            print STDERR "Error: mergeHashes: $k already exists in destination hash: dest = " . $dest->{$k} . ", src = $v\n";
#            exit;
#        }
#        $dest->{$k} = $v;
#    }
#}

#sub printDebugHA {
#    my $front = shift;
#    my $desc = shift;
#    printDebug("$front " . scalar(@_) . " $desc: " . join(' ',sort(@_)) . "\n");
#}

#sub printStuff {
#    my ($href) = @_;
#    while (my ($name, $exists) = each %$href) {
#        printf "\t%-15s", $name;
#        unless ($exists) { print " [missing]"; }
#        print "\n";
#    }
#}

