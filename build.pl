our $VERSION = "7";
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

my %ATTEMPTED_GEN;

my %EXISTS;

my $target = shift or die "Need target";

my $isExec = 0;

my $blah_depth = 0;


# v7
while (0) {
    # for each target
    # if the target does not exist
    #   if all of its dependencies exist
    #     generate it or die
    #   else
    #     mark each missing dependency as "need to generate" (add them as targets)
    # else (the target has been generated)
    #   if it has not been processed for dependencies
    #       process it for dependencies
    #
    #
}

my %DEPENDENCIES;
# so you know what targets need to have their dependencies reprocessed after you generate something (key = just generated)
my %WHO_DEPENDS_ON;

my $ITERATION = 0;


blah_v2($target);

exit;

updateGlobalDeps($target, processDependencies($target));

printGlobalDeps_iter();

#my $done = 0;
#while (not $done) {
#    $ITERATION++;
#    print "\niteration $ITERATION\n";
#    $done = 1;
#    for my $dep (keys %{$DEPENDENCIES{$target}}) {
#        if (not -f $dep) {
#            $done = 0;
#            generate($dep) or die "failed to generate $dep" . ($!?": $!":'');
#            for my $f (keys %{$WHO_DEPENDS_ON{$dep}}) {
#                updateGlobalDeps($f, processDependencies($f));
#            }
#        }
#    }
#}

#my $done = 0;
while (not allDepsExist($target)) {
    $ITERATION++;
    print "\niteration $ITERATION\n";
    #$done = 1;
    for my $dep (keys %{$DEPENDENCIES{$target}}) {

        if (not -f $dep) {
            updateGlobalDeps($dep);
            if (allDepsExist($dep)) {
                generate($dep) or die "failed to generate $dep" . ($!?": $!":'');
                for my $f (keys %{$WHO_DEPENDS_ON{$dep}}) {
                    updateGlobalDeps($f);
                }
            }
        }

        #if (not -f $dep) {
        #    generate($dep) or die "failed to generate $dep" . ($!?": $!":'');
        #    for my $f (keys %{$WHO_DEPENDS_ON{$dep}}) {
        #        updateGlobalDeps($f, processDependencies($f));
        #    }
        #}

        #updateGlobalDeps($dep, processDependencies($dep));
        #if (allDepsExist($dep)) {
        #    generate($dep) or die "failed to generate $dep" . ($!?": $!":'');
        #    for my $f (keys %{$WHO_DEPENDS_ON{$dep}}) {
        #        updateGlobalDeps($f, processDependencies($f));
        #    }
        #} else {
        #    $done = 0;
        #}
    }

    #updateGlobalDeps($target, processDependencies($target));
}


printGlobalDeps_iter();

generate($target) or die "failed to generate $target" . ($!?": $!":'');

exit;

####

sub allDepsExist {
    my $x = shift;
    if (DEBUG) { # just because it would otherwise be very simple
        my @exist;
        my @dontExist;
        for (keys %{$DEPENDENCIES{$x}}) {
            if (-f) { push @exist, $_; }
            else { push @dontExist, $_; }
        }
        
        my $allExist = (@dontExist == 0);
        printDebug("allDepsExist($x): " . ($allExist?'true':'false') . ": exist = (@exist), dontExist = (@dontExist)\n");
        return $allExist;
    } else {
        for (keys %{$DEPENDENCIES{$x}}) {
            unless (-f) {
                return 0;
            }
        }
        return 1;
    }
}

sub updateGlobalDeps {
    my $target = shift;
    my @deps = @_ ? @_ : processDependencies($target);
    my @newdeps;
    for (@deps) {
        # "unless exists" and $ITERATION is just for debug purposes, to see in which iteration something was discovered
        unless (exists $DEPENDENCIES{$target}->{$_}) {
            push @newdeps, $_;
            $DEPENDENCIES{$target}->{$_} = $ITERATION;
        }
        unless (exists $WHO_DEPENDS_ON{$_}->{$target}) {
            $WHO_DEPENDS_ON{$_}->{$target} = $ITERATION;
        }
    }
    printDebug("updateGlobalDeps($target) += @newdeps\n");
}

sub printGlobalDeps {
    for (keys %DEPENDENCIES) {
        print "DEPENDENCIES{$_}\n\t" . join("\n\t",keys %{$DEPENDENCIES{$_}}) . "\n";
    }
    for (keys %WHO_DEPENDS_ON) {
        print "WHO_DEPENDS_ON{$_}\n\t" . join("\n\t",keys %{$WHO_DEPENDS_ON{$_}}) . "\n";
    }
}

sub printGlobalDeps_iter {
    _helpPrintHash('DEPENDENCIES', \%DEPENDENCIES);
    _helpPrintHash('WHO_DEPENDS_ON', \%WHO_DEPENDS_ON);
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

sub processDependencies {
    my $target = shift;
    my ($base, $type) = basetype($target);
    my @deps;
    if ($type eq 'OBJ') {
        my $src = "$base.c"; # XXX src ext cheat
        push @deps, $src;
        #my @incs = grepIncludes($src);
        if (-f $src) { # might be generated
            my $incs = includes::find($src);
            push @deps, keys %$incs;
        }
    } elsif ($type eq 'HDR' or $type eq 'SRC') {
        # do these ever depend on anything? I guess once I get to .idl or corba stuff then it could. special gen rules. that is a ways off.
    } elsif ($type eq 'EXE') {
        my $obj = "$base.$OBJ_EXT";
        push @deps, $obj;
        my $src = "$base.c"; # XXX src ext cheat
        if (-f $src) { # might be generated
            my $incs = includes::find($src);
            for (keys %$incs) {
                # XXX XXX how do I remember the srcs that maybe exist and make them obj deps of the exe without requiring it or looping forever?
                my ($base2, undef) = basetype($_);
                push @deps, "$base2.$OBJ_EXT"; # FIXME a "soft" dependency, not sure how to handle it
            }
        }
    } else {
        die "script not done for $type files yet (target = $target)";
    }
    printDebug("processDependencies($target) = @deps\n");
    return @deps;
}

sub blah {
    my $x = shift;
    $blah_depth++;
    print "\n";
    printDebug("blah($x) depth = $blah_depth\n");
    updateGlobalDeps($x);
    if (not -f $x and allDepsExist($x)) {
        if (generate($x)) {
            # not sure this is necessary, try using brain later to figure it out
            for my $f (keys %{$WHO_DEPENDS_ON{$x}}) {
                updateGlobalDeps($f);
                # should this recursively update all WHO_DEPENDS_ON? seems like it should, but exe is getting correct updates anyway.
            }
        } elsif (not isExe($x)) {
            # was die, reducing for now to see how it goes
            # fail to make src is not really an issue for exe
            # was trying to account for that with isExe but really need to know why I'm generating it (is parent exe, kind of)
            print "Failed to generate $x";
        }
    } else {
        for (keys %{$DEPENDENCIES{$x}}) {
            blah($_); # TODO when this is done, should be able to generate $x
        }
    }
    $blah_depth--;
}

sub blah_v2 {
    my $x = shift;
    $blah_depth++;
    print "\n";
    printDebug("enter blah_v2($x) depth = $blah_depth\n");
    updateGlobalDeps($x);
    #while (not allDepsExist($x)) {

    #while (not allDepsAccountedFor($x)) {
    #    for (keys %{$DEPENDENCIES{$x}}) {
    #        blah_v2($_); # TODO when this is done, should be able to generate $x
    #    }
    #}

    while (1) {
        #my @notAccountedFor = depsNotAccountedFor($x);
        #if (@notAccountedFor) {
        #    for (@notAccountedFor) {
        #        if ($ATTEMPTED_GEN{$_}) {
        #            $ATTEMPTED_GEN{$x} = 1; # trying to back out the src/obj guess from link exe deps.  morale is low.
        #        } else {
        #            blah_v2($_);
        #        }
        #    }
        #} else {
        #    last;
        #}

        my @deps = keys %{$DEPENDENCIES{$x}};
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
            for my $f (keys %{$WHO_DEPENDS_ON{$x}}) {
                updateGlobalDeps($f);
                # should this recursively update all WHO_DEPENDS_ON? seems like it should, but exe is getting correct updates anyway.
            }
        } else {
            #TODO I tried more generic stuff above, but I think it failed.  want to try something more specific like this
            # if WHO is only execs and this is src, just move on (like remove it from deps I guess?)
            # actually going to try to just mark it as "attempted" generically because that might save some something or something
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
    $blah_depth--;
}

sub depsNotAccountedFor {
    my $x = shift;
    my @exist;
    my @attempted;
    my @rest;
    for (keys %{$DEPENDENCIES{$x}}) {
        # for now to see if this ever happens
        if (-f and $ATTEMPTED_GEN{$_}) { die "allDepsAccountedFor: $_ both exists and attempted"; }
        if (-f) { push @exist, $_; }
        elsif ($ATTEMPTED_GEN{$_}) { push @attempted, $_; }
        else { push @rest, $_; }
    }
    printDebug("depsNotAccountedFor($x): @rest (exists = (@exist), attempted = (@attempted))\n");
    return @rest;
}

sub allDepsAccountedFor {
    my $x = shift;
    if (DEBUG) {
        my @exist;
        my @attempted;
        my @rest;
        for (keys %{$DEPENDENCIES{$x}}) {
            # for now to see if this ever happens
            if (-f and $ATTEMPTED_GEN{$_}) { die "allDepsAccountedFor: $_ both exists and attempted"; }
            if (-f) { push @exist, $_; }
            elsif ($ATTEMPTED_GEN{$_}) { push @attempted, $_; }
            else { push @rest, $_; }
        }
        
        my $all = (@rest == 0);
        printDebug("allDepsAccountedFor($x): " . ($all?'true':'false') . ": exists = (@exist), attempted = (@attempted), rest = (@rest)\n");
        return $all;
    } else {
        for (keys %{$DEPENDENCIES{$x}}) {
            unless (-f or $ATTEMPTED_GEN{$_}) {
                return 0;
            }
        }
        return 1;
    }
}

sub processDependencies_forLinking {
    my $target = shift;
    printDebug("processDependencies($target)\n");
    my ($base, $type) = basetype($target);
    my @deps;
    if ($type eq 'OBJ') {
        my $src = "$base.c"; # XXX src ext cheat
        push @deps, $src;
        #my @incs = grepIncludes($src);
        if (-f $src) { # might be generated
            my $incs = includes::find($src);
            push @deps, keys %$incs;
        }
    } elsif ($type eq 'HDR' or $type eq 'SRC') {
        # do these ever depend on anything? I guess once I get to .idl or corba stuff then it could. special gen rules. that is a ways off.
    } elsif ($type eq 'EXE') {
        my $obj = "$base.$OBJ_EXT";
        push @deps, $obj;
        my $src = "$base.c"; # XXX src ext cheat
        #push @linkdeps, $src;
        if (-f $src) { # might be generated
            my $incs = includes::find($src);
            for (keys %$incs) {
                # XXX XXX how do I remember the srcs that maybe exist and make them obj deps of the exe without requiring it or looping forever?
                my ($base2, undef) = basetype($_);
                push @deps, "$base2.$OBJ_EXT"; # FIXME a "soft" dependency, not sure how to handle it
            }
        }
    } else {
        die "script not done for $type files yet (target = $target)";
    }
    return @deps;
}

sub generate {
    my $x = shift;
    #printDebug("generate($x)\n");
    my (undef, $type) = basetype($x);
    if ($type eq 'HDR') {
        return generateInc($x);
    } elsif ($type eq 'SRC') {
        return generateSrc($x);
    } elsif ($type eq 'OBJ') {
        return generateObj($x);
    } elsif ($type eq 'EXE') {
        return generateExe($x);
    } else {
        die "Don't know how to generate '$x'";
    }
}



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
    unless ($src) { confess("ATTEMPTED_GEN:\n\t".join("\n\t",keys %ATTEMPTED_GEN)); }

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
    } elsif ($ext eq $EXE_EXT) {
        $type = 'EXE';
    }
    return ($base, $type);
}

sub type {
    my (undef, $type) = basetype($_[0]);
    return $type;
}

sub grepIncludes {
    my $file = shift;
    my $in;
    unless (open($in, "<$file")) {
        printError("grepIncludes: $!: $file\n");
        return ();
    }
    my @incs;
    while (<$in>) {
        if (/^\s*#\s*include\s+"(.+)"/) {
            push @incs, $1;
        }
    }
    close $in;
    return @incs;
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


