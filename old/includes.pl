use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin";
use includes;

my $file = shift or die "Need file";
my $incsHRef = includes::find($file);
my @incs = sort keys $incsHRef;
print "$file includes " . scalar(@incs) . " files\n\t" . join("\n\t", @incs) . "\n";
