#!/usr/bin/env perl

### modules
use strict;
use warnings;
use Pod::Usage;
use Data::Dumper;
use Getopt::Long;
use File::Spec;

### args/flags
#pod2usage("$0: No files given.") if ((@ARGV == 0) && (-t STDIN));

my ($verbose, $replace);
GetOptions(
	   "replace" => \$replace,
	   "verbose" => \$verbose,
	   "help|?" => \&pod2usage # Help
	   );

### I/O error & defaults
$ARGV[0] = "CLdb.sqlite" unless $ARGV[0];

### MAIN
my $sql = get_sql();
make_db($sql, $ARGV[0]);

### Subroutines
sub make_db{
	my ($sql, $db_name) = @_;
	if(-e $db_name){
		if($replace){ unlink $db_name; }
		else{ die " ERROR: $db_name already exists! Use '-r' to replace\n"; }
		}
			
	open PIPE, "| sqlite3 $db_name" or die $!;
	print PIPE $sql; 
	close PIPE;
	
	print STDERR "...sqlite3 database tables created\n";
	}

sub get_sql{
	my $sql = <<HERE;
/* creating tables */
BEGIN TRANSACTION;

DROP TABLE IF EXISTS Loci;

CREATE TABLE Loci (
Locus_ID	INTEGER	PRIMARY KEY,
Taxon_ID	TEXT	NOT NULL,
Taxon_Name	TEXT	NOT NULL,
Subtype	TEXT,
Locus_Start	INTEGER	NOT NULL,
Locus_End	INTEGER	NOT NULL,
Operon_Start	INTEGER,
Operon_End	INTEGER,
CRISPR_Array_Start	INTEGER,
CRISPR_Array_End	INTEGER,
Operon_Status	TEXT	NOT NULL,
CRISPR_Array_Status	TEXT	NOT NULL,
Genbank	TEXT	NOT NULL,
Array_File	TEXT	NOT NULL,
Scaffold_count	INTEGER,
File_Creation_Date	TEXT,
Author	TEXT	NOT NULL
);


DROP TABLE IF EXISTS Spacers;

CREATE TABLE Spacers (
Locus_ID	INTEGER	NOT NULL,
Spacer_ID	TEXT	NOT NULL,
Spacer_Start	INTEGER	NOT NULL,
Spacer_End	INTEGER	NOT NULL,
Spacer_Sequence	TEXT	NOT NULL,
Spacer_Group	TEXT,
UNIQUE (Locus_ID, Spacer_ID)
ON CONFLICT REPLACE
);


DROP TABLE IF EXISTS DirectRepeats;

CREATE TABLE DirectRepeats (
Locus_ID	INTEGER	NOT NULL,
Repeat_ID	INTEGER	NOT NULL,
Repeat_Start	INTEGER	NOT NULL,
Repeat_End	INTEGER	NOT NULL,
Repeat_Sequence	TEXT	NOT NULL,
Repeat_Group	INTEGER,
UNIQUE (LOCUS_ID, Repeat_ID)
ON CONFLICT REPLACE
);


DROP TABLE IF EXISTS DirectRepeatConsensus;

CREATE TABLE DirectRepeatConsensus (
Locus_ID	INTEGER	NOT NULL,
Consensus_Sequence_IUPAC	TEXT	NOT NULL,
Consensus_Sequence_Threshold	TEXT	NOT NULL,
UNIQUE (Locus_ID)
ON CONFLICT REPLACE
);


DROP TABLE IF EXISTS LeaderSeqs;

CREATE TABLE LeaderSeqs (
Locus_ID	INTEGER	NOT NULL,
Leader_Start	INTEGER	NOT NULL,
Leader_End	INTEGER	NOT NULL,
Leader_Sequence	TEXT	NOT NULL,
Leader_Group	TEXT,
UNIQUE (Locus_ID)
ON CONFLICT REPLACE
);


DROP TABLE IF EXISTS Genes;

CREATE TABLE Genes (
Locus_ID	INTEGER	NOT NULL,
Gene_ID	TEXT	NOT NULL,
Gene_Start	INTEGER	NOT NULL,
Gene_End	INTEGER	NOT NULL,
Gene_Length__AA	INTEGER	NOT NULL,
In_Operon	TEXT	NOT NULL,
Gene_Alias	TEXT,
UNIQUE (Locus_ID, Gene_ID)
ON CONFLICT REPLACE
);


DROP TABLE IF EXISTS Draft;

CREATE TABLE Draft (
Locus_ID	INTEGER,
Scaffold_name	TEXT	NOT NULL,
Locus_Start	INTEGER	NOT NULL,
Locus_End	INTEGER	NOT NULL,
Operon_Start	INTEGER,
Operon_End	INTEGER,
CRISPR_Array_Start	INTEGER,
CRISPR_Array_End	INTEGER,
Genbank	TEXT	NOT NULL,
UNIQUE (Locus_ID)
ON CONFLICT REPLACE
);

COMMIT;

HERE

	return $sql;
	}

__END__

=pod

=head1 NAME

CLdb_makeDB.pl -- Initial DB construction

=head1 SYNOPSIS

CLdb_makeDB.pl [options] [DATABASE_name]

=head2 options

=over

=item -r 	Replace existing database.

=item -h	This help message

=back

=head2 For more information:

perldoc CLdb_makeDB.pl

=head1 DESCRIPTION

Make all of the CRISPR_db tables.

=head1 EXAMPLES

=head2 Naming database 'CRISPR_db1'

CLdb_makeDB.pl CRISPR_db1

=head1 AUTHOR

Nick Youngblut <nyoungb2@illinois.edu>

=head1 AVAILABILITY

sharchaea.life.uiuc.edu:/home/git/CLdb/

=head1 COPYRIGHT

Copyright 2010, 2011
This software is licensed under the terms of the GPLv3

=cut

