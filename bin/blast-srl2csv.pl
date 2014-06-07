#!/usr/bin/env perl

=pod

=head1 NAME

blast-srl2csv.pl -- converting blast output in binary serialization format to blast '-outfmt 6' or '-outfmt 7'

=head1 SYNOPSIS

blast-srl2csv.pl [flags] < blast_output.srl > blast_output.txt

=head2 Required flags

NONE

=head2 Optional flags

=over

=item -outfmt

blast fields as in '-outfmt' for blast. 
Only '6' or '7' formats are supported. 
['7 qseqid sseqid pident length mismatch 
gapopen qstart qend sstart send evalue bitscore']

=item -sep

Field seperator. ['\t']

=item -v 	Verbose output. [FALSE]

=item -h	This help message

=back

=head2 For more information:

perldoc blast-srl2csv.pl

=head1 DESCRIPTION

Simple script for converting blast output in 
binary data serialization format (Sereal)
to blast tabular format: either
with comments '-outfmt 7' or without '-outfmt 6'

Currnently, only some of the possible output fields
are supported:

=head2 Supported fields:

qseqid
qlen
sseqid
sacc
slen
qstart
qend
sstart
send
qseq
sseq
evalue
bitscore
score
length
pident
mismatch
gapopen
gaps
frames
qframe
sframe

=head1 EXAMPLES

=head1 AUTHOR

Nick Youngblut <nyoungb2@illinois.edu>

=head1 AVAILABILITY

sharchaea.life.uiuc.edu:/home/git/CLdb/

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

# CLdb #
use FindBin;
use lib "$FindBin::RealBin/../lib";
use CLdb::arrayBlast::sereal qw/
				 parse_outfmt
				 classify_fields
				 blast_xml2txt
			       /;

#--- parsing args ---#
pod2usage("$0: No files given.") if ((@ARGV == 0) && (-t STDIN));

my ($verbose);
my $outfmt = join(" ", qw/7 qseqid sseqid pident length mismatch 
			  gapopen qstart qend sstart send evalue bitscore/); 
my $sep = "\t";
GetOptions(
	   "outfmt=s" => \$outfmt,
	   "verbose" => \$verbose,
	   "seperator=s" => \$sep,
	   "help|?" => \&pod2usage # Help
	   );

#--- I/O error & defaults ---#
die "ERROR: provide '-outfmt'\n"
  unless defined $outfmt;
my $fields_r = parse_outfmt($outfmt); 
classify_fields($fields_r); 


#--- MAIN ---#
# loading serealized blast output
my $srl;
$srl .= $_ while <>;
my $decoder = Sereal::Decoder->new();
my $blast_r =  $decoder->decode( $srl );


# making table
foreach my $blast_run (keys %$blast_r){
  blast_xml2txt( blast => $blast_r->{$blast_run}, 
		 fields => $fields_r,
		 sep => $sep);
}
