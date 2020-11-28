our $VERSION = "8";
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

my %ATTEMPTED_GEN;

my %FAILED_GEN;

my $target = shift or die "Need target";
my $EXE_TARGET;
my $BLAH_DEPTH = 0;
my %COMPILE_DEPS;
# so you know what targets need to have their dependencies reprocessed after you generate something (key = just generated)
my %COMPILE_WHO_DEPENDS_ON;

my %LINK_DEPS;
my %LINK_WHO_DEPENDS_ON;

my %DONT_KNOW;

blah_v3($target);

print "\n";
printGlobalDeps_iter();

#TODO for every src that exists, pass it to blah_v2 to try to generate it
# if it succeeds (need to add return value to blah_v2), pass the obj to blah_v2 to try to compile it
while (1) {

    my $doneSAE = 0;
    my @srcAlreadyExists = linkDepObjs('already');
    
    if (@srcAlreadyExists) {

        my $allObjExists = 1;
        for (@srcAlreadyExists) {
            my $obj = base($_) . ".$OBJ_EXT";
            unless (-f $obj) { $allObjExists = 0; }
        }

        if ($allObjExists) {
            printDebug("all obj for src already exists\n");
            $doneSAE = 1;
        } else {
            for (@srcAlreadyExists) {
                my $obj = base($_) . ".$OBJ_EXT";
                blah_v3($obj);
            }
        }
    } else {
        $doneSAE = 1;
    }

    my $doneLDO = 0;
    my @linkDepObjs = linkDepObjs();
    if (@linkDepObjs) {
        for (@linkDepObjs) {
            blah_v3($_);
        }
    } else {
        $doneLDO = 1;
    }

    if ($doneSAE and $doneLDO) {
        last;
    }
}

printGlobalDeps_iter();

#generateExe($target);



exit;

####

sub linkDepObjs {
    my $opt = shift;
    #XXX
    # all the headers should be created at this point
    my @hdrs;
    for my $i (keys %COMPILE_DEPS) {
        for my $j (keys %{$COMPILE_DEPS{$i}}) {
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

    print "linkDepObjs\n\t"      . join("\n\t",keys %linkDepObjs)      . "\n";
    print "srcGenFailed\n\t"     . join("\n\t",keys %srcGenFailed)     . "\n";
    print "srcAlreadyExists\n\t" . join("\n\t",keys %srcAlreadyExists) . "\n";
    #print "objAlreadyExists\n\t" . join("\n\t",@objAlreadyExists) . "\n";
    #print "objDoesNotExist\n\t"  . join("\n\t",@objDoesNotExist)  . "\n";

    if ($opt and $opt eq 'already') {
        return keys %srcAlreadyExists;
    }
    return keys %linkDepObjs;
}

sub blah_v3 {
    my $x = shift;
    printDebug("blah_v3($x)\n");
    $BLAH_DEPTH++;
    updateGlobalDeps($x);
    while (1) {
        my @deps = keys %{$COMPILE_DEPS{$x}};
        my %attempted;
        my $all = 1;
        for (@deps) {
            if (not -f and not $FAILED_GEN{$_}) {
                $all = 0;
                print "Boop\n";
                blah_v3($_);
            }
        }
        if ($all) {
            printDebug("all deps done for $x\n");
            last;
        }
    }

    if (not -f $x) {
        if ($FAILED_GEN{$x}) {
            printDebug("gen already failed for $x\n");
        } else {
            if (generate($x)) {
                # not sure this is necessary, try using brain later to figure it out
                for my $f (keys %{$COMPILE_WHO_DEPENDS_ON{$x}}) {
                    updateGlobalDeps($f);
                    # recursively update all COMPILE_WHO_DEPENDS_ON?
                }
            } else {
                #printDebug("generation failed: $x\n");
            }
        }
    } else {
        printDebug("already exists: $x\n");
    }
    $BLAH_DEPTH--;
}

sub blah_v2 {
    my $x = shift;
    $BLAH_DEPTH++;
    print "\n";
    printDebug("enter blah_v2($x) depth = $BLAH_DEPTH\n");
    updateGlobalDeps($x);

    while (1) {
        my @deps = keys %{$COMPILE_DEPS{$x}};
        my $allAccountedFor = 1;
        for (@deps) {

            if ($ATTEMPTED_GEN{$_} and type($_) eq 'SRC') {
                $ATTEMPTED_GEN{$x} = 1; # trying to back out the src/obj guess from link exe deps.  morale is low.
            }

            unless (-f or $ATTEMPTED_GEN{$_}) {
                $allAccountedFor = 0;
                blah_v2($_);
            }
        }
        if ($allAccountedFor) {
            last;
        }
    }

    if (not -f $x and not $ATTEMPTED_GEN{$x}) {
        if (generate($x)) {
            # not sure this is necessary, try using brain later to figure it out
            for my $f (keys %{$COMPILE_WHO_DEPENDS_ON{$x}}) {
                updateGlobalDeps($f);
                # should this recursively update all COMPILE_WHO_DEPENDS_ON? seems like it should, but exe is getting correct updates anyway.
            }
        } else {
            #TODO? if WHO is only execs and this is src, just move on (like remove it from deps I guess?)
            # trying this instead
            $ATTEMPTED_GEN{$x} = 1;
        }
    } else {
        if (-f $x) {
            printDebug("already exists: $x\n");
        } elsif ($ATTEMPTED_GEN{$x}) {
            printDebug("already failed gen: $x\n");
        }
    }
    printDebug("exit blah_v2($x)\n");
    $BLAH_DEPTH--;
}

sub updateGlobalDeps {
    my $target = shift;
    my @deps = @_ ? @_ : _processDeps($target);
    my @newdeps;
    for (@deps) {
        # "unless exists" and iteration/depth value is just for debug purposes, to see in which iteration something was discovered
        unless (exists $COMPILE_DEPS{$target}->{$_}) {
            push @newdeps, $_;
            $COMPILE_DEPS{$target}->{$_} = $BLAH_DEPTH;
        }
        unless (exists $COMPILE_WHO_DEPENDS_ON{$_}->{$target}) {
            $COMPILE_WHO_DEPENDS_ON{$_}->{$target} = $BLAH_DEPTH;
        }
    }
    printDebug("updateGlobalDeps($target) += @newdeps\n");
}

# back to compile and link (isExec) split logic
# then I think should try to compile everything (and find deps using this)
# after that look through link deps.  if generation there succeeds, add it back to compile-style deps.  if it fails, not an error (though linking may fail, we'll see), remove from link deps. and remove anything downstream from it, if so (like .c->.h) - not too sure I will need to do this
# @deps is for compilation
# LINK global hashes are for linking.  yes global state.  too bad!
sub _processDeps {
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

        if ($EXE_TARGET) {
            #dup? push @deps, "$base.c"; # @src_ext_cheat
        }

    } elsif ($type eq 'HDR') {

        # push @deps - nothing now, maybe something for .idl

        if ($EXE_TARGET) {
            for (keys %{includes::find($target)}) {
                #my $obj = base($target) . ".$OBJ_EXT";
                #setLinkDep($EXE_TARGET, $obj);
                # the obj link dep is accounted for in SRC case of this sub
                my $src = base($_) . ".c"; # @src_ext_cheat
                setLinkDep($EXE_TARGET, $src);
            }
        }

    } elsif ($type eq 'SRC') {

        # push @deps - nothing now, maybe something for .idl

        if ($EXE_TARGET) {
            for (keys %{includes::find($target)}) {
                my $src = base($_) . ".c"; # @src_ext_cheat
                setLinkDep($EXE_TARGET, $src);
            }
            my $obj = "$base.$OBJ_EXT";
            setLinkDep($EXE_TARGET, $obj);
        }

    } elsif ($type eq 'EXE') {

        push @deps, "$base.$OBJ_EXT";

        $EXE_TARGET = $target;

    } else {
        die "script not done for $type files yet (target = $target)";
    }
    printDebug("processDependencies($target) = @deps\n");
    return @deps;

}

sub setLinkDep {
    my ($dependsOn, $dependedUpon) = @_;
    $LINK_DEPS{$dependsOn}->{$dependedUpon} = $BLAH_DEPTH;
    $LINK_WHO_DEPENDS_ON{$dependedUpon}->{$dependsOn} = $BLAH_DEPTH;
}




sub generate {
    my $x = shift;
    #printDebug("generate($x)\n");
    my (undef, $type) = basetype($x);
    my $r;
    if ($type eq 'HDR') {
        $r = generateInc($x);
    } elsif ($type eq 'SRC') {
        $r =  generateSrc($x);
    } elsif ($type eq 'OBJ') {
        $r =  generateObj($x);
    } elsif ($type eq 'EXE') {
        $r =  generateExe($x);
    } else {
        die "Don't know how to generate '$x'";
    }
    if ($r) {
        printDebug("generated $x\n");
    } else {
        printDebug("failed to generate $x\n");
        $FAILED_GEN{$x} = 1;
    }
    return $r;
}

sub generateInc {
    if (my $x = _copy_gen(@_)) {
        $x =~ s/\..+$//;
        #$EXISTS{$x}->{HDR} = 'generated';
        return 1;
    }
    return 0;
}

sub generateSrc {
    if (my $x = _copy_gen(@_)) {
        $x =~ s/\..+$//;
        #$EXISTS{$x}->{SRC} = 'generated';
        return 1;
    }
    return 0;
}

sub _copy_gen {
    die unless scalar(@_) == 1;
    my $file = shift;
    if (copy("gen/$file", $file)) {
        #printInfo("generated $file\n");
        return 1;
    } else {
        # whether this is an error depends on context, so let caller handle it
        #printDebug("don't know how to generate $file\n");
        if (exists $DONT_KNOW{$file}) {
            if ($DONT_KNOW{$file} > 3) {
                #_helpPrintHash_v2('COMPILE_WHO_DEPENDS_ON', \%COMPILE_WHO_DEPENDS_ON);
                confess("$DONT_KNOW{$file}x don't knows for $file\nCOMPILE_WHO_DEPENDS_ON{$file}:\n\t" . join("\n\t",keys %{$COMPILE_WHO_DEPENDS_ON{$file}}));
            }
            $DONT_KNOW{$file}++
        } else {
            $DONT_KNOW{$file} = 1;
        }
        return 0;
    }
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
    printDebug("$cmd\n");
    if (system($cmd)) {
        printError("generateObj: command failed: '$cmd'\n");
        confess();
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
        printGlobalDeps_iter();
        confess();
        #exit; # return 0 ?
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

sub printGlobalDep_prev {
    for (keys %COMPILE_DEPS) {
        print "COMPILE_DEPS{$_}\n\t" . join("\n\t",keys %{$COMPILE_DEPS{$_}}) . "\n";
    }
    for (keys %COMPILE_WHO_DEPENDS_ON) {
        print "COMPILE_WHO_DEPENDS_ON{$_}\n\t" . join("\n\t",keys %{$COMPILE_WHO_DEPENDS_ON{$_}}) . "\n";
    }
}

sub printGlobalDeps_iter {
    _helpPrintHash_v2('COMPILE_DEPS', \%COMPILE_DEPS);
    _helpPrintHash_v2('COMPILE_WHO_DEPENDS_ON', \%COMPILE_WHO_DEPENDS_ON);
    _helpPrintHash_v2('LINK_DEPS', \%LINK_DEPS);
    _helpPrintHash_v2('LINK_WHO_DEPENDS_ON', \%LINK_WHO_DEPENDS_ON);
}

sub _helpPrintHash {
    my ($name, $href) = @_;
    for my $k (keys %{$href}) {
        my @s;
        while (my ($f,$i) = each %{$href->{$k}}) {
            push @s, "$i $f";
        }
        print $name . "{$k}\n\t" . join("\n\t",@s) . "\n";
    }
}

sub _helpPrintHash_v2 {
    my ($name, $href) = @_;
    print "$name";
    for my $k (keys %{$href}) {
        my @s;
        for my $f (sort keys %{$href->{$k}}) {
            my $i = $href->{$k}->{$f};
            push @s, "$f($i)";
        }
        print "\n\t$k: (" . join(', ',@s) . ')';
    }
    print "\n";
}

#sub grepIncludes {
#    my $file = shift;
#    my $in;
#    unless (open($in, "<$file")) {
#        printError("grepIncludes: $!: $file\n");
#        return ();
#    }
#    my @incs;
#    while (<$in>) {
#        if (/^\s*#\s*include\s+"(.+)"/) {
#            push @incs, $1;
#        }
#    }
#    close $in;
#    return @incs;
#}

sub printError {
    print STDERR 'ERROR ['.NAME."] @_";
}

sub printInfo {
    print STDOUT '['.NAME."][info] @_";
}

sub printDebug {
    #if (DEBUG) { print STDOUT '['.NAME."][debug] @_"; }
    my $pad = '';
    for (1..$BLAH_DEPTH) {
        $pad .= '- ';
    }
    if (DEBUG) { print STDOUT '['.NAME."][debug] $pad@_"; }
}

#sub allDepsExist {
#    my $x = shift;
#    if (DEBUG) { # just because it would otherwise be very simple
#        my @exist;
#        my @dontExist;
#        for (keys %{$COMPILE_DEPS{$x}}) {
#            if (-f) { push @exist, $_; }
#            else { push @dontExist, $_; }
#        }
#        
#        my $allExist = (@dontExist == 0);
#        printDebug("allDepsExist($x): " . ($allExist?'true':'false') . ": exist = (@exist), dontExist = (@dontExist)\n");
#        return $allExist;
#    } else {
#        for (keys %{$COMPILE_DEPS{$x}}) {
#            unless (-f) {
#                return 0;
#            }
#        }
#        return 1;
#    }
#}

#sub allDepsAccountedFor {
#    my $x = shift;
#    if (DEBUG) {
#        my @exist;
#        my @attempted;
#        my @rest;
#        for (keys %{$COMPILE_DEPS{$x}}) {
#            # for now to see if this ever happens
#            if (-f and $ATTEMPTED_GEN{$_}) { die "allDepsAccountedFor: $_ both exists and attempted"; }
#            if (-f) { push @exist, $_; }
#            elsif ($ATTEMPTED_GEN{$_}) { push @attempted, $_; }
#            else { push @rest, $_; }
#        }
#        
#        my $all = (@rest == 0);
#        printDebug("allDepsAccountedFor($x): " . ($all?'true':'false') . ": exists = (@exist), attempted = (@attempted), rest = (@rest)\n");
#        return $all;
#    } else {
#        for (keys %{$COMPILE_DEPS{$x}}) {
#            unless (-f or $ATTEMPTED_GEN{$_}) {
#                return 0;
#            }
#        }
#        return 1;
#    }
#}

#sub toSrc {
#    return base(shift) . ".c";
#}

