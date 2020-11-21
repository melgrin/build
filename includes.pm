use strict;
use warnings;
use Data::Dumper;
use Carp qw(confess);

package includes;

use constant DEBUG => 0;

# for a make/build system, might want to just note it's missing so it can (attempt to) be generated
# but by default, die if an included file is missing (because we want to go search that for includes too)
our $DIE_ON_MISSING = 1;

sub find {
    my ($file) = @_;
    my %incs = ();
    _find($file, \%incs);
	#return sort keys %incs;
	return \%incs;
}

sub _find {
    my ($file, $href) = @_;
    printDebug("searching for includes in $file\n");
    open (my $in, "<$file") or Carp::confess("$!: $file");
    my @incs;
    while (<$in>) {
        #if (/^\s*#\s*include\s+[<"](.+)[>"]/) {
        if (/^\s*#\s*include\s+"(.+)"/) { # workaround for sys includes
            printDebug("$file includes $1\n");
            push @incs, $1;
        }
    }
    close $in;
	if (DEBUG and not @incs) { printDebug("no includes in $file\n"); }
    # doing this after file parsing to avoid recursively opening lots of files
    for (@incs) {
        if (not exists $href->{$_}) {
			if (not -f $_ and not $DIE_ON_MISSING) {
				printDebug("file does not exist: $_\n");
				$href->{$_} = 0;
			} else {
				$href->{$_} = 1;
				_find($_, $href);
			}
        }
    }
}

sub printDebug {
    if (DEBUG) { print STDOUT '['.__PACKAGE__."][debug] @_"; }
}

1;
