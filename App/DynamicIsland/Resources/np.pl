#!/usr/bin/perl
# Perl route for the Now Playing spike. /usr/bin/perl is an Apple platform
# binary, which is what MediaRemote's client check looks for. This script only
# loads our own NowPlayingBridge dylib and calls np_run(); all logic lives there.
use strict;
use warnings;
use DynaLoader;

my $lib = $ENV{NP_LIB} or die "NP_LIB is not set\n";
my $handle = DynaLoader::dl_load_file($lib, 0)
    or die "dl_load_file failed: " . (DynaLoader::dl_error() // 'unknown') . "\n";
my $sym = DynaLoader::dl_find_symbol($handle, "np_run")
    or die "np_run not found: " . (DynaLoader::dl_error() // 'unknown') . "\n";
DynaLoader::dl_install_xsub("main::np_run", $sym);
main::np_run();
