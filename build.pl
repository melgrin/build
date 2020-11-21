use strict;
use warnings;
use File::Basename qw(basename);
use File::Copy qw(copy);
use lib "D:/dev/bld"; use includes;

use constant NAME => basename($0);
use constant DEBUG => 1;

my $HDR_EXT = 'h';
my $OBJ_EXT = 'o';
my @SRC_EXTS = qw/cpp c/;
my $SRC_EXT = 'SRC'; # generic marker b/c of list of possible exts

my %ALL_INCS;
my %ALL_SRCS;
my %ALL_OBJS;

$includes::DIE_ON_MISSING = 0;

my $target = shift or die "Need target";

# convert target to obj
# convert obj to src
# find incs from src
# if any incs do not exist on disk, need to generate them so add to some list
# if it's an exec
#     h -> c
#     if c exists on disk
#         find incs from c
#         if any incs do not exist on disk, add them to "need to generate" list
#         c -> o, add o to "need to generate"
#     elsif c does not exist on disk
#         check rules/makefiles/db to see if there's a way to make it
#         if there is, add it to the "need to generate" list
#         else die "No such file: $c";

# any time a thing from the "need to generate" list is generated, need to rerun the relevant steps above
#     h -> includes
#     c -> if exec
#              includes
#              push @gen, $c

# if I go only halfway and create makefiles instead of actually compiling, I can do it partially by assuming missing files have rules in independently-created makefiles.

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


doThing($obj);
$ALL_OBJS{$obj} = 1; # add after call because it's used to prevent infinite recursion

#print "$target\nALL_INCS\n\t" . join("\n\t", keys %ALL_INCS) . "\nALL_OBJS\n\t" . join("\n\t", keys %ALL_OBJS) . "\n";

print "$target\n";
print "\n";
print "ALL_INCS\n"; printStuff(\%ALL_INCS);
print "ALL_SRCS\n"; printStuff(\%ALL_SRCS);
print "ALL_OBJS\n\t" . join("\n\t", keys %ALL_OBJS);
print "\n";

print "\ntrying to generate missing files and account for their deps\n";
# if any incs are missing, try to create them
# if the create succeeds*, do the includes::find steps again (.o)
# if the create succeeds*, do the src-derived includes and obj dep steps again (exec)
# * "create succeeds" means that there was a rule to create it (and I guess that the commands used in the rule return success)
while (my ($inc, $exists) = each %ALL_INCS) {
    next if $exists;
    next unless generateInc($inc);
    $ALL_INCS{$inc} = 1;
    printDebug("$inc <gen> start\n");
    my $incsFromHdr = includes::find($inc);
    printDebug("$inc <gen> " . scalar(keys %$incsFromHdr) . " includes: " . join(' ', sort(keys %$incsFromHdr)) . "\n");
    mergeHashes(\%ALL_INCS, $incsFromHdr);
    if ($isExec) {
        my @srcs = srcsE(keys %$incsFromHdr);
        printDebug("$inc <gen> <isExec> " . scalar(@srcs) . " srcs: " . join(' ', sort(@srcs)) . "\n");
        # src-derived includes
        for my $s (@srcs) {
            mergeHashes(\%ALL_INCS, includes::find($s));
        }
        # src->obj deps
        my @objs = srcToObjsBlind(@srcs);
        printDebug("$inc <gen> <isExec> objs: @objs\n");
        # not totally sure I should just do the exact same thing here
        for (@objs) {
            if (not exists $ALL_OBJS{$_}) {
                $ALL_OBJS{$_} = 1;
                doThing($_);
            }
        }
    }
}

if ($isExec) {
    while (my ($src, $exists) = each %ALL_SRCS) {
        next if $exists;
        my $orig = $src;
        my $src = generateSrc($src);
        next unless $src;
        delete $ALL_SRCS{$orig};
        $ALL_SRCS{$src} = 1;
        #TODO this necessitates all the include steps above, which in turns means rerunning this block too! there is definitely at least a while loop that needs to go around this whole thing
        mergeHashes(\%ALL_INCS, includes::find($src));
        my @objs = srcToObjsBlind($src);
        die if @objs > 1;
        # same as above, I think this maybe should be pulled out like INCS and SRCS are here
        for (@objs) {
            if (not exists $ALL_OBJS{$_}) {
                $ALL_OBJS{$_} = 1;
                doThing($_);
            }
        }
    }
}

print "\n";
print "ALL_INCS\n"; printStuff(\%ALL_INCS);
print "ALL_SRCS\n"; printStuff(\%ALL_SRCS);
print "ALL_OBJS\n\t" . join("\n\t", keys %ALL_OBJS);
print "\n";

sub doThing {
    my $obj = shift;
    printDebug("$obj start\n");

    # convert obj to src
    my $src;
    for (@SRC_EXTS) {
        my $s = $obj =~ s/\.$OBJ_EXT$/\.$_/r;
        if (-f $s) {
            $src = $s;
            last;
        }
    }
    unless ($src) { die "Target obj '$obj' has no matching src on disk"; }
    printDebug("$obj src: $src\n");

    # find incs from src
    my $incs = includes::find($src);
    printDebug("$obj " . scalar(keys %$incs) . " includes: " . join(' ', sort(keys %$incs)) . "\n");
    %ALL_INCS = (%ALL_INCS, %$incs); # might want a more strict merge
    #while (my ($name, $exists) = each %$incs) {
    #    $ALL_INCS{$name} = $exists;
    #}

    # if it's an exec
    if ($isExec) {
        # h -> c
        #my @srcs;
        #for (keys %$incs) {
        #    my $base = $_ =~ s/\.$HDR_EXT$//r;
        #    my $srcExists = 0;
        #    for (@SRC_EXTS) {
        #        my $s = "$base.$_";
        #        # if c exists on disk
        #        if (-f $s) {
        #            $srcExists = 1;
        #            push @srcs, $s;
        #            $ALL_SRCS{$s} = 1;
        #            last; # for @SRC_EXTS
        #        }
        #    }
        #    # .SRC because I'm accepting both .c and .cpp as src for .h
        #    unless ($srcExists) {
        #        $ALL_SRCS{"$base.SRC"} = 0;
        #    }
        #}
        my @srcs = srcsE(keys %$incs);

        printDebug("$obj <isExec> " . scalar(@srcs) . " srcs: @srcs\n");

        # find incs from c
        for my $s (@srcs) {
            mergeHashes(\%ALL_INCS, includes::find($s));
        }
        # c -> o, add o to "need to generate"
        my @objs = srcToObjsBlind(@srcs);
        #for my $s (@srcs) {
        #    my $o = $s;
        #    for my $e (@SRC_EXTS) {
        #        $o =~ s/\.$e$/\.$OBJ_EXT/;
        #    }
        #    push @objs, $o;
        #}

        printDebug("$obj <isExec> objs: @objs\n");

        for (@objs) {
            if (not exists $ALL_OBJS{$_}) {
                $ALL_OBJS{$_} = 1;
                doThing($_);
            }
        }
    }
}

sub printStuff {
    my ($href) = @_;
    while (my ($name, $exists) = each %$href) {
        printf "\t%-15s", $name;
        unless ($exists) { print " [missing]"; }
        print "\n";
    }
}

sub generateInc {
    die unless scalar(@_) == 1;
    my $file = shift;
    if (copy("gen/$file", $file)) {
        printInfo("generated $file\n");
        return 1;
    } else {
        # whether this is an error depends on context, so let caller handle it
        printDebug("failed to generate $file: $!\n");
        return 0;
    }
}

sub generateSrc {
    die unless @_ == 1;
    my $file = shift;
    unless ($file =~ s/\.$SRC_EXT$//) {
        die "Expected *.$SRC_EXT but got $file";
    }
    for my $ext (@SRC_EXTS) {
        my $src = "$file.$ext";
        if (copy("gen/$src", $src)) {
            printInfo("generated $src\n");
            return $src;
        }
    }
    printDebug("failed to generate $file (@SRC_EXTS): $!\n");
    return undef;
}

#sub generateHeader {
#    my ($file) = @_;
#    my $base = $file;
#    $base =~ s/^.*\///;
#    $base =~ s/\.$HDR_EXT$//;
#    my $out;
#    if (open ($out, ">$file")) {
#        print $out "#ifndef ${base}_h\n#define ${base}_h\ntypedef struct { int x; } $base;\n#endif\n";
#        close $out;
#        print '['.NAME."] generated $file\n");
#        return 1;
#    } else {
#        return 0;
#    }
#}

# not doing this for now, not sure how I want to handle it
# Like I will need to rebuild everything, right?  If it doesn't exist, there needs to be a rule to make it.  I guess.  But what if it's just a plain header?  Need to revisit this once I have other stuff more nailed down,
#     elsif c does not exist on disk
#         check rules/makefiles/db to see if there's a way to make it
#         if there is, add it to the "need to generate" list
#         else die "No such file: $c";


sub srcE {
    my ($inc) = @_;
    my $base = $inc =~ s/\.$HDR_EXT$//r;
    my $srcExists = 0;
    for my $ext (@SRC_EXTS) {
        my $src = "$base.$ext";
        if (-f $src) {
            return $src;
        }
    }
    return undef;
}

sub srcsE {
    my @srcs;
    for my $inc (@_) {
        my $base = $inc;
        unless ($base =~ s/\.$HDR_EXT$//) {
            die "Expected *.$HDR_EXT but got $inc";
        }
        my $srcExists = 0;
        for my $ext (@SRC_EXTS) {
            my $src= "$base.$ext";
            if (-f $src) {
                $srcExists = 1;
                push @srcs, $src;
                $ALL_SRCS{$src} = 1;
                last;
            }
        }
        # .SRC because I'm accepting both .c and .cpp as src for .h
        unless ($srcExists) {
            $ALL_SRCS{"$base.$SRC_EXT"} = 0;
        }
    }
    return @srcs;
}

sub srcToObjsBlind {
    my @objs;
    for my $s (@_) {
        my $o = $s;
        for my $e (@SRC_EXTS) {
            $o =~ s/\.$e$/\.$OBJ_EXT/;
        }
        push @objs, $o;
    }
    return @objs;
}

# merge src hash ref into dest hash ref
sub mergeHashes {
    my ($dest, $src) = @_;
    while (my ($k, $v) = each %$src) {
        # being strict about this so I can tell if something weird is going on
        # this is how you would do it if you didn't care about value overrides.  this syntax takes the values from the last hash in the list.
        # %ALL_INCS = (%ALL_INCS, %$incsFromSrc);
        if (exists $dest->{$k} and $dest->{$k} != $v) {
            print STDERR "Error: mergeHashes: $k already exists in destination hash: dest = " . $dest->{$k} . ", src = $v\n";
            exit;
        }
        $dest->{$k} = $v;
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


