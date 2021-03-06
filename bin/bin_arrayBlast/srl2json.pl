#!/usr/bin/env perl

=pod

=head1 NAME

srl2json -- converting blast output binary serialization format to json format

=head1 SYNOPSIS

srl2json [flags] < blast_output.srl > blast_output.json

=head2 Required flags

NONE

=head2 Optional flags

=over

=item -v 	Verbose output. [FALSE]

=item -h	This help message

=back

=head2 For more information:

CLdb -- arrayBlast --perldoc -- srl2json

=head1 DESCRIPTION

Simple script for converting blast output in
a binary serialization format to json.

=head1 AUTHOR

Nick Youngblut <nyoungb2@illinois.edu>

=head1 AVAILABILITY

https://github.com/nyoungb2/CLdb

=head1 COPYRIGHT

Copyright 2010, 2011
This software is licensed under the terms of the GPLv3

=cut

#--- modules ---#
# core #
use strict;
use warnings;
use Pod::Usage;
use Data::Dumper;
use Getopt::Long;
use Sereal qw/ decode_sereal /;
use JSON;

# CLdb #
use FindBin;
use lib "$FindBin::RealBin/../../lib";

#--- parsing args ---#
pod2usage("$0: No files given.") if ((@ARGV == 0) && (-t STDIN));

my ($verbose, $database);
GetOptions(
	   "database=s" => \$database, # unused
	   "verbose" => \$verbose,
	   "help|?" => \&pod2usage # Help
	   );

#--- I/O error & defaults ---#


#--- MAIN ---#
my $srl;
$srl .= $_ while <>;
my $decoder = Sereal::Decoder->new();
print encode_json( $decoder->decode( $srl ) );


