#!/usr/bin/env perl

### modules
use strict;
use warnings;
use Pod::Usage;
use Data::Dumper;
use Getopt::Long;
use File::Spec;
use DBI;

### args/flags
pod2usage("$0: No files given.") if ((@ARGV == 0) && (-t STDIN));


my ($verbose, $database_file, $spacer_bool, $by_group, $leader_bool);
my (@subtype, @taxon_id, @taxon_name);
my $extra_query = "";
GetOptions(
	   "database=s" => \$database_file,
	   "repeat" => \$spacer_bool,			 # spacers or repeats?
	   "subtype=s{,}" => \@subtype,
	   "taxon_id=s{,}" => \@taxon_id,
	   "taxon_name=s{,}" => \@taxon_name,
	   "group" => \$by_group,
	   "leader" => \$leader_bool,
	   "query=s" => \$extra_query, 
	   "verbose" => \$verbose,
	   "help|?" => \&pod2usage # Help
	   );

### I/O error & defaults
die " ERROR: provide a database file name!\n"
	unless $database_file;
die " ERROR: cannot find database file!\n"
	unless -e $database_file;

### MAIN
# connect 2 db #
my %attr = (RaiseError => 0, PrintError=>0, AutoCommit=>0);
my $dbh = DBI->connect("dbi:SQLite:dbname=$database_file", '','', \%attr) 
	or die " Can't connect to $database_file!\n";

# joining query options (for table join) #
my $join_sql = "";
$join_sql .= join_query_opts(\@subtype, "subtype");
$join_sql .= join_query_opts(\@taxon_id, "taxon_id");
$join_sql .= join_query_opts(\@taxon_name, "taxon_name");

# getting arrays of interest from database #
my $arrays_r;
if($leader_bool){
		#$arrays_r = get_arrays_join_flip_test($dbh, $spacer_bool, $extra_query, $join_sql);
	$arrays_r = get_arrays_join_flip($dbh, $spacer_bool, $extra_query, $join_sql);
	}
else{
	$arrays_r = get_arrays_join($dbh, $spacer_bool, $extra_query, $join_sql);
	}

# writing fasta #
write_arrays_fasta($arrays_r, $spacer_bool);


# disconnect #
$dbh->disconnect();
exit;


### Subroutines
sub write_arrays_fasta{
# writing arrays as fasta
	my ($arrays_r, $spacer_bool) = @_;
	
	foreach my $locus_id (keys %$arrays_r){
		foreach my $x_id (keys %{$arrays_r->{$locus_id}}){
			if($by_group){				
				if($spacer_bool){
					print join("\n", ">DR_Group.$x_id", $arrays_r->{$locus_id}{$x_id}), "\n";
					}
				else{
					print join("\n", ">Spacer_Group.$x_id", $arrays_r->{$locus_id}{$x_id}), "\n";
					}
				}
			else{
				print join("\n", ">cli.$locus_id\__$x_id", $arrays_r->{$locus_id}{$x_id}), "\n";
				}
			}
		}
	}

sub get_arrays_join_flip_test{
	my ($dbh, $spacer_bool, $extra_query, $join_sql) = @_;
	
	my ($table, $label) = qw/spacers spacer/;
	($table, $label) = qw/DRs DR/ if $spacer_bool;

	my $query = "SELECT
$table.Locus_ID, 
$table.$label\_group, 
$table.$label\_sequence,
loci.array_end,
leaders.leader_end
FROM loci, leaders, $table
WHERE loci.locus_id = $table.locus_id
AND loci.locus_id = leaders.locus_id
AND leaders.locus_id IS NOT NULL
GROUP BY $table.$label\_group, $table.$label\_sequence
ORDER BY $table.$label\_group
";	

	$query =~ s/\n/ /g;
		#print Dumper $query;
	
	# query db #
	my $ret = $dbh->selectall_arrayref($query);
	die " ERROR: no matching entries!\n"
		unless $$ret[0];
	
	# making fasta #
	my %arrays;
	foreach my $row (@$ret){
		# rev-comp if leader end > array end #
		$$row[2] = revcomp($$row[2]) if $$row[4] > $$row[3];
		
		#print join("\t", @$row), "\n";
		}
		exit;
	#	print Dumper %arrays; exit;

	}

sub get_arrays_join_flip{
	my ($dbh, $spacer_bool, $extra_query, $join_sql) = @_;
	
	my ($table, $label) = qw/spacers spacer/;
	($table, $label) = qw/DRs DR/ if $spacer_bool;

	my $query = "SELECT
$table.Locus_ID, 
$table.$label\_group, 
$table.$label\_sequence,
loci.array_end,
leaders.leader_end
FROM loci, leaders, $table
WHERE loci.locus_id = $table.locus_id
AND loci.locus_id = leaders.locus_id
AND leaders.locus_id IS NOT NULL
";	

	$query .= "GROUP BY $table.$label\_group" if $by_group;
	$query =~ s/\n/ /g;
		#print Dumper $query;
	
	# query db #
	my $ret = $dbh->selectall_arrayref($query);
	die " ERROR: no matching entries!\n"
		unless $$ret[0];
	
	# making fasta #
	my %arrays;
	foreach my $row (@$ret){
		# rev-comp if leader end > array end #
		$$row[2] = revcomp($$row[2]) if $$row[4] > $$row[3];
		
		# loading fasta #
		die " ERROR: not spacer/repeat group found!\n\tWas CLdb_groupArrayElements.pl run?\n"
			unless $$row[1]; 
		$arrays{$$row[0]}{$$row[1]} = $$row[2];
		}
	
	#	print Dumper %arrays; exit;
	return \%arrays;
	}
	
sub revcomp{
	# reverse complements DNA #
	my $seq = shift;
	$seq = reverse($seq);
	$seq =~ tr/[a-z]/[A-Z]/;
	$seq =~ tr/ACGTNBVDHKMRYSW\.-/TGCANVBHDMKYRSW\.-/;
	return $seq;
	}
	
sub get_arrays_join{
	my ($dbh, $spacer_bool, $extra_query, $join_sql) = @_;
	
	# make query #
	my $query;
	if($spacer_bool){		# direct repeat
		if($by_group){
			$query = "SELECT DRs.Locus_ID, DRs.DR_group, DRs.DR_sequence FROM DRs, loci WHERE loci.locus_id = DRs.locus_id $join_sql GROUP BY DRs.DR_group";
			}
		else{
			$query = "SELECT DRs.Locus_ID, DRs.DR_ID, DRs.DR_sequence FROM DRs, loci WHERE DRs.locus_id = loci.locus_id $join_sql";
			}
		}
	else{					# spacer
		if($by_group){
			$query = "SELECT spacers.Locus_ID, spacers.Spacer_group, spacers.spacer_sequence FROM spacers, loci WHERE spacers.locus_id = loci.locus_id $join_sql GROUP BY spacers.spacer_group";
			}
		else{
			$query = "SELECT spacers.Locus_ID, spacers.spacer_ID, spacers.spacer_sequence FROM spacers, loci WHERE spacers.locus_id = loci.locus_id $join_sql";
			}
		}
	$query = join(" ", $query, $extra_query);
	
	# status #
	print STDERR "$query\n" if $verbose;

	# query db #
	my $ret = $dbh->selectall_arrayref($query);
	die " ERROR: no matching entries!\n"
		unless $$ret[0];
	
	my %arrays;
	foreach my $row (@$ret){
		die " ERROR: not spacer/repeat group found!\n\tWas CLdb_groupArrayElements.pl run?\n"
			unless $$row[1]; 
		$arrays{$$row[0]}{$$row[1]} = $$row[2];
		}
	
	#	print Dumper %arrays; exit;
	return \%arrays;
	}
	
sub join_query_opts{
# joining query options for selecting loci #
	my ($vals_r, $cat) = @_;

	return "" unless @$vals_r;	
	
	map{ s/"*(.+)"*/"$1"/ } @$vals_r;
	return join("", " AND loci.$cat IN (", join(", ", @$vals_r), ")");
	}


sub check_for_loci_table{
	my ($table_list_r) = @_;
	die " ERROR: loci table not found in database!\n"
		unless grep(/^loci$/i, @$table_list_r);
	if($leader_bool){
		die " ERROR: leaders table not found in database!\n"
			unless grep(/^leaders$/i, @$table_list_r);
		}
	}

sub list_tables{
	my $all = $dbh->selectall_hashref("SELECT tbl_name FROM sqlite_master", 'tbl_name');
	return [keys %$all];
	}


__END__

=pod

=head1 NAME

CLdb_array2fasta.pl -- write CRISPR array spacers or direct repeats to fasta

=head1 SYNOPSIS

CLdb_array2fasta.pl [flags] > array.fasta

=head2 Required flags

=over

=item -database  <char>

CLdb database.

=back

=head2 Optional flags

=over

=item -repeat  <bool>

Get direct repeats instead of spacers. [FALSE]

=item -subtype  <char>

Refine query to specific a subtype(s) (>1 argument allowed).

=item -taxon_id  <char>

Refine query to specific a taxon_id(s) (>1 argument allowed).

=item -taxon_name  <char>

Refine query to specific a taxon_name(s) (>1 argument allowed).

=item -group  <bool>

Get array elements de-replicated by group (ie. all unique sequences). [FALSE]

=item -query  <char>

Extra sql to refine which sequences are returned.

=item -leader  <bool>

Orient sequence to leader (leader always on 5' end)? Only sequences 
from loci with identified leaders will be written! [FALSE]

=item -v 	Verbose output. [FALSE]

=item -h	This help message

=back

=head2 For more information:

perldoc CLdb_array2fasta.pl

=head1 DESCRIPTION

Get spacer or direct repeat sequences from the CRISPR database
and write them to a fasta.

By default, all spacers or direct repeats (if '-r') will be written.
The '-q' flag can be used to refine the query to certain sequences (see examples).

For spacer blasting, use '-leader' to avoid using sequence
from the wrong strand (i.e. leader on 3' end instead of 5').
Important for downstream analysis of spacer blast hits!

=head1 EXAMPLES

=head2 Write all spacers to a fasta:

CLdb_array2fasta.pl -d CLdb.sqlite 

=head2 Write all direct repeats to a fasta:

CLdb_array2fasta.pl -d CLdb.sqlite -r

=head2 Write all unique spacers

CLdb_array2fasta.pl -d CLdb.sqlite -g

=head2 Write all unique spacers oriented by the leader location

CLdb_array2fasta.pl -d CLdb.sqlite -g -l

=head2 Refine spacer sequence query:

CLdb_array2fasta.pl -d CLdb.sqlite -q "AND loci.Locus_ID=1" 

=head2 Refine spacer query to a specific subtype & 2 taxon_id's

CLdb_array2fasta.pl -d CLdb.sqlite -sub I-B -taxon_id 6666666.4038 6666666.40489

=head1 AUTHOR

Nick Youngblut <nyoungb2@illinois.edu>

=head1 AVAILABILITY

sharchaea.life.uiuc.edu:/home/git/CLdb/

=head1 COPYRIGHT

Copyright 2010, 2011
This software is licensed under the terms of the GPLv3

=cut

