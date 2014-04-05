#!/usr/bin/env perl

=pod

=head1 NAME

CLdb_getLeaderRegion.pl -- getting leader region sequences

=head1 SYNOPSIS

CLdb_getLeaderRegion.pl [flags] > possible_leaders.fna

=head2 Required flags

=over

=item -database  <char>

CLdb database.

=back

=head2 options

=over

=item -location  <char>

Location file specifying known leader region locations.

=item -subtype  <char>

Refine query to specific a subtype(s) (>1 argument allowed).

=item -taxon_id  <char>

Refine query to specific a taxon_id(s) (>1 argument allowed).

=item -taxon_name  <char>

Refine query to specific a taxon_name(s) (>1 argument allowed).

=item -query  <char>

Extra sql to refine which sequences are returned.

=item -length  <int>

Max length of the potential leader region (bp). [1000]

=item -overlap  <bool>

Check for overlapping genes (& trim region if overlap)? [TRUE]

=item -cutoff  <int>

Gene length cutoff for counting gene as real in overlap assessment (bp). [150]

=item -repeat  <bool>

Use repeat degeneracies to determine which side contains the leader region 
(only works if DRs have been clustered)? [FALSE]

=item -verbose  <bool>

Verbose output

=item -help  <bool>

This help message

=back

=head2 For more information:

perldoc CLdb_getLeaderRegions.pl

=head1 DESCRIPTION

Get the suspected leader regions for CRISPR loci 
in the CRISPR database.

The leader region length will be truncated if any genes overlap in 
that region (unless -overlap used).

The default leader region length is 1000bp from the CRISPR array.

=head2 Selecting leader regions (-location)

Leader regions can be selected by providing a query such as 
"-sub I-A" for all leader regions adjacent to the I-A arrays.

Leader regions can also be specified using a location file ('-location' flag).
The file should have the following columns (no header; order matters!):

=over

=item locus_ID

=item taxon_name

=item taxon_id

=item scaffold ('CLDB_ONE_CHROMOSOME' if scaffold was not provided in loci.txt table)

=item region start (> region end if negative strand)

=item region end 

=back

=head2 '-repeat' flag

Leader regions can determined by direct repeat (DR) degeneracy,
which should occur at the trailer end.
For example: leader half has 1 cluster due to DR conservation,
while the trailer half has 3 clusters due to DR degeneracy). 
This is determined by the 'repeat_group' column in the 
Directrepeats table in the CRISPR database. Therefore, 
CLdb_groupArrayElements.pl has to be run on the database 
before running this script! 
Both end regions of a CRISPR array are written if a CRISPR
array has equal numbers of DR clusters on each half.

The number of repeat_groups on each side (5' & 3') of the
CRISPR array will be printed to STDERR (unless '-v').
The output values are: 'degeracies', locus_id', 
'5-prime_number_repeat_groups', '3-prime_number_repeat_groups'

=head2 Output
Leader regions in the output fasta are named as: 
"LocusID"|"start/end"|"scaffold"|"region_start"|"region_end"|"strand"

Leader region start & end are according to the + strand. 

=head2 Next step after getting potential leader regions

Align the leader regions (eg. mafft --adjustdirection).

Remove any leaders that don't align or split the 
alignment into >=2 files if multiple groups of sequences
align together but not globally.

Make sure that each locus_ID only has 1 leader region in the alignment!

Determine where the leader region ends (number of bp to 
trim off from the non-conserved end).

Load the leader region using CLdb_loadLeaders.pl


=head1 EXAMPLES

=head2 Leader regions for all loci

CLdb_getLeaderRegion.pl -d CLdb.sqlite > psbl_leaders.fna

=head2 Leader regions for just subtype I-B

CLdb_getLeaderRegions.pl -d CLdb.sqlite -sub I-B > psbl_leaders_I-B.fna

=head2 Leader regions specified in location file

CLdb_getLeaderRegions.pl -d CLdb.sqlite -loc locations.txt > psbl_leaders.fna

=head1 AUTHOR

Nick Youngblut <nyoungb2@illinois.edu>

=head1 AVAILABILITY

sharchaea.life.uiuc.edu:/home/git/CLdb/

=head1 COPYRIGHT

Copyright 2010, 2011
This software is licensed under the terms of the GPLv3

=cut


### modules
use strict;
use warnings;
use Pod::Usage;
use Data::Dumper;
use Getopt::Long;
use File::Spec;
use DBI;
use Bio::SeqIO;
use Set::IntervalTree;

# CLdb #
use FindBin;
use lib "$FindBin::RealBin/../lib";
use lib "$FindBin::RealBin/../lib/perl5/";
use CLdb::query qw/
	table_exists
	n_entries
	join_query_opts
	get_array_seq/;
use CLdb::utilities qw/
	file_exists 
	connect2db/;
use CLdb::seq qw/
	revcomp/;

### args/flags
pod2usage("$0: No files given.") if ((@ARGV == 0) && (-t STDIN));

my ($verbose, $database_file, $overlap_check, $degeneracy_bool, $degen_check, $loc_in);
my (@subtype, @taxon_id, @taxon_name);
my $extra_query = "";
my $length = 1000;				# max length of leader region
my $gene_len_cutoff = 150;		# bp minimum to be considered a real gene
GetOptions(
	   "database=s" => \$database_file,
	   "subtype=s{,}" => \@subtype,
	   "taxon_id=s{,}" => \@taxon_id,
	   "taxon_name=s{,}" => \@taxon_name,	   
	   "query=s" => \$extra_query, 
	   "length=i" => \$length,
	   "overlap" => \$overlap_check,			# check for gene overlap w/ leader region? [TRUE]
	   "cutoff=i" => \$gene_len_cutoff,	
	   "repeat" => \$degen_check,				# use degeneracies to determine leader side? [FALSE]
	   "location=s" => \$loc_in, 				# location table 
	   "verbose" => \$verbose,
	   "help|?" => \&pod2usage # Help
	   );


#--- I/O error & defaults ---#
file_exists($database_file, "database");
$database_file = File::Spec->rel2abs($database_file);
my $genbank_path = path_by_database($database_file);


#--- MAIN ---#
# connect 2 db #
my $dbh = connect2db($database_file);

# joining query options (for table join) #
my $join_sql = "";
$join_sql .= join_query_opts(\@subtype, "subtype");
$join_sql .= join_query_opts(\@taxon_id, "taxon_id");
$join_sql .= join_query_opts(\@taxon_name, "taxon_name");

## fasta dir path ##
my $db_path = get_database_path($database_file);
my $fasta_dir = make_fasta_dir($db_path);

# sequence in genbank or fasta? If genbank, make fasta of genome #
my ($subject_loci_r, $leader_tbl_r);
if($loc_in){		# by location table (defining leader start-end)
	$leader_tbl_r = load_loc($loc_in);
	$subject_loci_r = get_loci_fasta_genbank($dbh, $leader_tbl_r);
	}
else{				# by query 
	$subject_loci_r = get_loci_by_query($dbh, $join_sql);
	}	

# making fasta from genbank sequence if needed #
my $loci_update = genbank2fasta($subject_loci_r, $db_path, $fasta_dir);
update_loci($dbh, $leader_tbl_r) if $loci_update;



# getting array start-end from loci table #
my $array_se_r = get_array_se($dbh, $join_sql, $extra_query, $leader_tbl_r);

# determinig leader end of array based on DR degeneracy #
my $leader_loc_r = get_DR_seq($dbh, $array_se_r);

	
# writing out leader sequence if leader location provided #
if($loc_in){
	# getting fasta seq #
	get_locus_fasta($dbh, $leader_tbl_r);

	# writing selected leader seq #
	write_select_leader_seq($leader_loc_r, $fasta_dir, $genbank_path, $array_se_r);
	}
# else: writing out possible leader region #
else{
	## getting sequences from genbanks ##
	get_leader_seq($array_se_r, $leader_loc_r, $fasta_dir, $genbank_path, $length);
	}


# disconnect #
$dbh->disconnect();
exit;


### Subroutines
sub write_select_leader_seq{
	my ($leader_loc_r, $fasta_dir, $genbank_path, $array_se_r) = @_;
	
	# making fasta => scaffold => locus index #
	my %fasta_locus;
	foreach my $entry (@$leader_tbl_r){
		$fasta_locus{$$entry[6]}{$$entry[3]} = $entry;
		}

	foreach my $fasta (keys %fasta_locus){
		my $fasta_r = load_fasta("$fasta_dir/$fasta");
		
		foreach my $scaf (keys %{$fasta_locus{$fasta}}){
			die "ERROR: cannot find scaffold: '$scaf' in genome fasta!\n"
				unless exists $fasta_r->{$scaf};
			
			
			# pulling out leader region #
			my @l = @{$fasta_locus{$fasta}{$scaf}};			# each entry in location table 
			my $leader_seq;
			my $strand;
			if($l[4] <= $l[5]){		# start < end
				$strand = 1;
				# sanity checks #
				die "ERROR: leader start for LocusID: $l[0] is < 0!\n"
					if $l[4] < 0;
				die "ERROR: leader end for for LocusID: $l[0] is > scaffold length!\n"
					if $l[5] > length $fasta_r->{$scaf};
					
				$leader_seq = substr($fasta_r->{$scaf}, $l[4]-1, $l[5] - $l[4] + 1);
				}
			elsif($l[4] > $l[5]){		# start > end; - strand
				$strand = -1;
				# sanity checks #
				die "ERROR: leader start for LocusID: $l[0] is < 0!\n"
					if $l[5] < 0;
				die "ERROR: leader end for for LocusID: $l[0] is > scaffold length!\n"
					if $l[4] > length $fasta_r->{$scaf};

				my $scaf_seq_rev = revcomp($fasta_r->{$scaf});
				$leader_seq = substr($fasta_r->{$scaf}, $l[5]-1, $l[4] - $l[5] + 1);
				}

			# writing out sequence #
			print join("\n", 
				join("|", ">$l[0]", ${$leader_loc_r->{$l[0]}}[0], 
					@l[3..5], $strand),
					$leader_seq), "\n";
			}
		}
	}
	
sub get_locus_fasta{
# adding fasta to each entry #
	my ($dbh, $leader_tbl_r) = @_;
	
	foreach my $entry (@$leader_tbl_r){
		my $cmd = "SELECT fasta_file FROM loci WHERE locus_id = '$$entry[0]'";
		
		my $ret = $dbh->selectall_arrayref($cmd);
		die "ERROR: no matched for locusID: $$entry[0]!\n"
			unless defined $ret;
		
		push @$entry, $$ret[0][0];
		}
	 
		#print Dumper $leader_tbl_r; exit;
	}

sub get_leader_seq{
# getting leader seqs from genbanks #
	my ($array_se_r, $leader_loc_r, $fasta_dir, $genbank_path, $length) = @_;

	# making fasta => scaffold => locus index #
	my (%fasta_locus, %fasta_genbank);
	foreach my $array (keys %$array_se_r){
		push @{$fasta_locus{${$array_se_r->{$array}}[3]}{${$array_se_r->{$array}}[5]}}, $array;
		$fasta_genbank{${$array_se_r->{$array}}[3]} = ${$array_se_r->{$array}}[4];
		}

	# getting all leader regions for each fasta #
	foreach my $fasta (keys %fasta_locus){
		# loading fasta #
		my $fasta_r = load_fasta("$fasta_dir/$fasta");
		
		# loading genbank #
		my $seqio = Bio::SeqIO->new(-format => "genbank", 
								-file => "$genbank_path/$fasta_genbank{$fasta}");
		
		#print Dumper %fasta_locus; exit;
		#print Dumper $fasta_r; exit;
							
		# just by scaffold #
		while (my $seq = $seqio->next_seq){
			my $scaf = $seq->display_id;
			die " ERROR: cannot find scaffold '$scaf' in '$fasta_dir/$fasta'!\n"
				unless exists $fasta_r->{$scaf};
			#die " ERROR: cannot find scaffold: '$scaf' in '$fasta_dir/$fasta'!\n"
			#	unless exists $fasta_locus{$fasta}{$scaf};			# not sure if needed
			next unless exists $fasta_locus{$fasta}{$scaf};
				
			
			foreach my $locus (@{$fasta_locus{$fasta}{$scaf}}){				
				# sanity check #
				die " ERROR: cannot find $locus in array start-end hash!\n"
					unless exists $array_se_r->{$locus};
				
				# leader start-end #
				my $array_start = ${$array_se_r->{$locus}}[1];
				my $array_end = ${$array_se_r->{$locus}}[2];
				
				# both sides of array if needed #
				foreach my $loc (@{$leader_loc_r->{$locus}}){	
					my ($leader_start, $leader_end);
					if($loc eq "start"){
						$leader_start = $array_start - $length;
						$leader_end = $array_start; 						
						}
					elsif($loc eq "end"){
						$leader_start = $array_end;
						$leader_end = $array_end + $length;					
						}
					else{ die " LOGIC ERROR: $!\n"; }
					
					# no negative (or zero) values (due to $length extending beyond scaffold) #
					$leader_start = 1 if $leader_start < 1;
					$leader_end = 1 if $leader_end < 1;
	
					# leader start & end must be < total scaffold length #
					my $scaf_len = length $fasta_r->{$scaf};
					$leader_start = $scaf_len if $leader_start > $scaf_len;
					$leader_end = $scaf_len if $leader_end > $scaf_len;
					
					# checking for gene overlap; truncating leader region if overlap #
					($leader_start, $leader_end) = check_gene_overlap($seq, $leader_start, $leader_end, $loc, $locus)
						unless $overlap_check;
					
					# skipping if leader length is < 10 bp #
					if(abs($leader_end - $leader_start) < 10){
						print STDERR "WARNING: Skipping leader region: '", 
							join(",", "LocusID:$locus", $loc, "start:$leader_start", "end:$leader_end"),
							"' due to short length (<10bp)!\n";
						next;
						}
						
					# parsing seq from fasta #
					my $leader_seq = substr($fasta_r->{$scaf}, $leader_start -1, $leader_end - $leader_start);
					
					# strand #
					my $strand = ${$array_se_r->{$locus}}[6];
					if($strand == -1){
						$leader_seq = revcomp($leader_seq);
						}
					
					# writing out sequence #
					print join("\n", 
						join("|", ">$locus", $loc, $scaf, $leader_start, $leader_end, $strand),
						$leader_seq), "\n";
					}
				}
			}
		}
	}

sub check_gene_overlap{
# checking to see if and genes overlap w/ leader region #
# if yes, truncating leader region #
	my ($seq, $region_start, $region_end, $leader_loc, $locus) = @_;
		
	# making an interval tree #
	my $itree = Set::IntervalTree->new();
	for my $feat ($seq->get_SeqFeatures){
		next if $feat->primary_tag eq "source";

		my $start = $feat->location->start;
		my $end = $feat->location->end;
	
		# filtering out short genes #
		my @tags = grep(/translation/, $feat->get_all_tags);
		my $gene_length = 0;
		if(@tags){
			my @tmp = $feat->get_tag_values("translation"); 	# amino acid 
			$gene_length = (length $tmp[0]) * 3;
			}
		else{ 
			$gene_length = length $feat->entire_seq->seq;		# nucleotide
			}
		next if $gene_length < $gene_len_cutoff;			# excluding short genes (probably not real) 		
		
		# loading tree #
		if($start <= $end){			# all on + strand
			$itree->insert($feat, $start - 1,  $end + 1);
			}
		else{
			$itree->insert($feat, $end - 1,  $start + 1);		
			}
		}
		
	# debuggin itree #	
		#print_itree($itree, $region_start, $region_end);
		
	my $overlap_pos = 0;
	if($leader_loc eq "start"){		# checking for 1st overlap from 3' - 5' end # 
		for (my $i=$region_end; $i>=$region_start; $i--){
			$overlap_pos = check_pos($itree, $i);
			last if $overlap_pos;
			}
		}
	elsif($leader_loc eq "end"){	# checking for 1st overlap from 5' - 3' end;
		for (my $i=$region_start; $i<=$region_end; $i++){
			$overlap_pos = check_pos($itree, $i);
			last if $overlap_pos;
			}
		}
	
	sub check_pos{
		my ($itree, $i) = @_;
		my $res = $itree->fetch($i, $i);
		return $i if $$res[0];
		}
		
	# altering start-end #
	if($overlap_pos){
		print STDERR "WARNING: Gene(s) overlap the potential leader region in array of Locus: '$locus'. Truncating\n" unless $verbose;
		
		if($leader_loc eq "start"){
			$region_start = $overlap_pos;
			}
		elsif($leader_loc eq "end"){
			$region_end = $overlap_pos;
			}
		die " LOGIC ERROR: region start is > region end! $!\n"
			if $region_start > $region_end;
		}

	# sanity checks #
	die " ERROR: For locus$locus, start and/or end is negative!: start=$region_start; end=$region_end\n"
		unless $region_start >= 0 && $region_end >= 0;

	return $region_start, $region_end;
	}

sub get_DR_seq{
# determining potential leader regions based on dr degeneracy: if $degen_check 
# if no $degen_check; start-end could be on either side
	my ($dbh, $array_se_r) = @_;

        my $cmd = "SELECT a.DR_id, a.DR_start, a.DR_end, b.Cluster_ID 
				FROM DRs a, DR_clusters b
				WHERE a.Locus_id = b.Locus_id
				AND a.DR_id = b.DR_id
				AND b.Cutoff = 1
				AND a.locus_ID = ?";	
       	  
	$cmd =~ s/\s+/ /g;
	my $sql = $dbh->prepare($cmd);
	
	my %leader_loc;	
	foreach my $locus (keys %$array_se_r){		# each CRISPR locus
		
	        if($degen_check){
		  $sql->execute($locus);
		  my $ret = $sql->fetchall_arrayref();
		
		  die " ERROR: no direct repeats found for locus_ID: $locus!\n"
			unless $$ret[0];
		  die " ERROR: no 'repeat_group' entries found!\n Run CLdb_groupArrayElements.pl before this script!\n\n"
			unless defined $$ret[0][3];
		
		  $leader_loc{$locus} = determine_leader($ret, $array_se_r->{$locus}, $locus);
		}
		else{
		  $leader_loc{$locus} = ["start", "end"];
		}
	      }
	
	       #print Dumper %leader_loc; exit;
	return \%leader_loc;
	}

sub get_array_se{
# getting the array start-end from loci table #
	my ($dbh, $join_sql, $extra_query, $leader_tbl) = @_;
	
	my $cmd = "SELECT Locus_ID, array_start, array_end, fasta_file, genbank_file, scaffold
FROM loci
WHERE (array_start is not null or array_end is not null)
AND (array_start != '' or array_end != '')";

	# if select loci #
	$cmd .= " AND locus_ID = ?" if defined $leader_tbl;

	# extra options #
	$cmd .= " $join_sql" if defined $join_sql;
	$cmd .= " $extra_query" if defined $extra_query;

	# querying db #
	my %array_se;
	if(defined $leader_tbl){ 
		my $sth = $dbh->prepare($cmd);
		foreach my $x (@$leader_tbl){
			#$sth->bind_param(1, $$x[0] );
			$sth->execute($$x[0]);
						
			# parsing entries #
			my $ret_cnt=0;
			foreach my $row ( $sth->fetchrow_arrayref() ){				
				$ret_cnt++;
				## moving array start-end to + strand (for i-tree) ##
				my $strand = 1;
				if($$row[1] > $$row[2]){
					$strand = -1;
					($$row[2], $$row[1]) = ($$row[1], $$row[2]);
					}
				$array_se{$$row[0]} = [@$row, $strand];
				}
				
			die "ERROR: no matching entries for locusID: '$$x[0]'!\n" unless $ret_cnt;
			}
		}
	else{ 
		my $ret = $dbh->selectall_arrayref($cmd);

		die "ERROR: no matching entries!\n" unless $ret;

		# parsing entries #
		foreach my $row (@$ret){
			# moving array start-end to + strand #
			my $strand = 1;
			if($$row[1] > $$row[2]){
				$strand = -1;
				($$row[2], $$row[1]) = ($$row[1], $$row[2]);
				}
			push @$row, $strand;
			$array_se{$$row[0]} = $row;
			}
		}
	
		#print Dumper %array_se; exit;
	return \%array_se; 
	}

sub genbank2fasta{
# getting fasta from genbank unless -e fasta #
	my ($leader_tbl_r, $db_path, $fasta_dir) = @_;
	
	my $update_cnt = 0;
	foreach my $loci (@$leader_tbl_r){
		if(! $$loci[3]){		# if no fasta file
			print STDERR " WARNING: no fasta for taxon_name->$$loci[0] taxon_id->$$loci[1]! Trying to extract sequence from genbank...\n";
			$$loci[3] = genbank2fasta_extract($$loci[2], $db_path, $fasta_dir);
			$update_cnt++;
			}
		elsif($$loci[3] && ! -e "$fasta_dir/$$loci[3]"){
			print STDERR " WARNING: cannot find $$loci[3]! Trying to extract sequence from genbank...\n";
			$$loci[3] = genbank2fasta_extract($$loci[2], $db_path, $fasta_dir);
			$update_cnt++;
			}
		}
	return $update_cnt;		# if >0; update loci tbl
	}
	
sub genbank2fasta_extract{
	my ($genbank_file, $db_path, $fasta_dir) = @_;

	# making fasta dir if not present #
	mkdir $fasta_dir unless -d $fasta_dir;
	
	# checking for existence of fasta #
	my @parts = File::Spec->splitpath($genbank_file);
	$parts[2] =~ s/\.[^.]+$|$/.fasta/;
	my $fasta_out = "$fasta_dir/$parts[2]";
	if(-e $fasta_out){
		print STDERR "\t'$fasta_out' does exist, but not in loci table. Adding to loci table.\n";
		return $parts[2]; 
		}

	# sanity check #
	die " ERROR: cannot find $genbank_file!\n"
		unless -e "$db_path/genbank/$genbank_file";
	
	# I/O #
	my $seqio = Bio::SeqIO->new(-file => "$db_path/genbank/$genbank_file", -format => "genbank");
	open OUT, ">$fasta_out" or die $!;
	
	# writing fasta #
	my $seq_cnt = 0;
	while(my $seqo = $seqio->next_seq){
		$seq_cnt++;
	
		# seqID #
		my $scafID = $seqo->display_id;
		print OUT join("\n", ">$scafID", $seqo->seq), "\n";
		}
	close OUT;
	
	# if genome seq found and fasta written, return fasta #
	if($seq_cnt == 0){
		print STDERR "\tWARNING: no genome sequnece found in Genbank file: $genbank_file!\nSkipping BLAST!\n";
		unlink $fasta_out;
		return 0;
		}
	else{ 
		print STDERR "\tFasta file extracted from $genbank_file, written: $fasta_out\n";
		return $parts[2]; 			# just fasta name
		}
	}

sub get_loci_fasta_genbank{
# querying CLdb for fasta & genbank files for each taxon #
	my ($dbh, $leader_tbl_r) = @_;
	
	# querying for taxon_names #
	## sql ##
	my $q = "SELECT 
taxon_name, taxon_id, genbank_file, fasta_file 
FROM loci 
WHERE taxon_name = ? OR taxon_id = ?";
	$q =~ s/\n/ /g;
	my $sql = $dbh->prepare($q);
	
	## querying db ##
	my @ret;
	foreach my $row (@$leader_tbl_r){
		$sql->execute(@$row[1..2]);
		my $res = $sql->fetchrow_arrayref();
		push @ret, [@$res]; 
		}
	
	die " ERROR: no matches found to query!\n"
		unless @ret;

		#print Dumper @ret; exit;
	return \@ret;
	}
	
sub get_loci_by_query{
# querying CLdb for fasta & genbank files for each taxon #
	my ($dbh, $join_sql) = @_;
	
	my $q = "SELECT taxon_name, taxon_id, genbank_file, fasta_file
FROM loci
WHERE locus_id=locus_id 
$join_sql 
GROUP BY taxon_name, taxon_id";
	
	my $res = $dbh->selectall_arrayref($q);
	die " ERROR: no matches found to query!\n"
		unless @$res;

		#print Dumper @$res; exit;
	return $res;
	}

sub update_loci{
# updating loci w/ fasta file info for newly written fasta #
	my ($dbh, $leader_tbl_r) = @_;
	
	# status#
	print STDERR "...updating Loci table with newly made fasta files\n";
	
	# sql #
	my $q = "UPDATE loci SET fasta_file=? WHERE genbank_file=?";
	my $sth = $dbh->prepare($q);
	
	foreach my $row (@$leader_tbl_r){
		next unless $$row[3]; 						# if no fasta_file; skipping
		my @parts = File::Spec->splitpath($$row[3]);

		$sth->bind_param(1, $parts[2]);				# fasta_file (just file name)
		$sth->bind_param(2, $$row[2]);				# genbank_file
		$sth->execute( );
		
		if($DBI::err){
			print STDERR "ERROR: $DBI::errstr in: ", join("\t", @$row), "\n";
			}
		}
	$dbh->commit();
	
	print STDERR "...updates committed!\n";
	}

sub load_loc{
# loading locations of leaders #
	my ($loc_in) = @_;
	my @loc;
	open IN, $loc_in or die $!;
	while(<IN>){
		chomp;
		next if /^\s*$/;
		my @line = split /\t/;
		die " ERROR! line$. does not have >=6 columns: '", join("\t", @line), "'\n"
			unless scalar @line >= 5;
		push(@loc, [split /\t/]);
		}
		#print Dumper @loc; exit;
	return \@loc;
	}
	
sub load_fasta{
# loading fasta file as a hash #
	my $fasta_in = shift;
	open IN, $fasta_in or die $!;
	my (%fasta, $tmpkey);
	while(<IN>){
		chomp;
 		s/#.+//;
 		next if  /^\s*$/;	
 		if(/>.+/){
 			s/^>//;
 			$fasta{$_} = "";
 			$tmpkey = $_;	# changing key
 			}
 		else{$fasta{$tmpkey} .= $_; }
		}
	close IN;
		#print Dumper %fasta; exit;
	return \%fasta;
	} #end load_fasta
	
sub path_by_database{
	my ($database_file) = @_;
	my @parts = File::Spec->splitpath($database_file);
	return join("/", $parts[1], "genbank");
	}
	
sub print_itree{
	my ($itree, $start, $end) = @_;
	
	for my $i ($start..$end){
		my $res = $itree->fetch($i, $i);
		
		print join("\t", "pos:$i", join("::", @$res)), "\n";
		}
	#exit;
	}	

sub determine_leader{
# determing leader region #
	my ($ret, $array_r, $locus) = @_;
	
	# getting halfway point in array #
	my $array_half = ($$array_r[1] +  $$array_r[2]) / 2;
	
	# counting groups for each half of the array #
	my %group_cnt;
	foreach my $DR (@$ret){		# each direct repeat
		# $DR = (repeat, start, end, group_ID)
		if($$DR[1] < $array_half && $$DR[2] < $array_half){
			$group_cnt{1}{$$DR[3]} = 1;		
			}
		elsif($$DR[1] > $array_half && $$DR[2] > $array_half){
			$group_cnt{2}{$$DR[3]} = 1;
			}
		}
	my $first_cnt = scalar keys %{$group_cnt{1}};		# number of groups in 1st half
	my $second_cnt = scalar keys %{$group_cnt{2}};		# number of groups in 2nd half

	# writing degeneracy report to STDERR #
	print STDERR join("\t", "degeneracies", "$locus", $first_cnt, $second_cnt), "\n"
			unless $verbose;
	
	# getting leader end based on number of degeneracies #
	## leader end should have less than trailer ##
	## therefore, the side w/ the most groups is the trailer end ##
 	## based on + strand positioning ##
	if($first_cnt < $second_cnt){		# > degeneracy at end, leader at start
		return ["start"];		
		}
	elsif($first_cnt > $second_cnt){	# > degeneracy at start, leader at end
		return ["end"];		
		}
	else{
		print STDERR " WARNING: for $locus, could not use direct repeat degeneracy determine leader region end! Writing both.\n";
		return ["start", "end"];
		}
	}
	
sub pos_strand_se{
	my ($start, $end) = @_;
	if($start > $end){ return $end, $start; }
	else{ return $start, $end; }
	}

sub make_leader_dir{
# making a directory for leader region output #
	my ($leader_path, $database_file) = @_;
	
	unless ($leader_path){
		my @parts = File::Spec->splitpath($database_file);
		$leader_path = join("/", $parts[1], "leader");
		}
	mkdir $leader_path unless -d $leader_path;
	return $leader_path;
	}

sub make_fasta_dir{
	my $db_path = shift;
	
	my $dir = join("/", $db_path, "fasta");
	mkdir $dir unless -d $dir;

	return $dir;
	}

sub get_database_path{
	my $database_file = shift;
	$database_file = File::Spec->rel2abs($database_file);
	my @parts = File::Spec->splitpath($database_file);
	return $parts[1];
	}

sub check_gene_overlap_OLD{
# checking to see if and genes overlap w/ leader region #
# if yes, truncating leader region #
	my ($seq, $region_start, $region_end, $leader_loc, $locus) = @_;
	
	# making an interval tree #
	my $itree = Set::IntervalTree->new();
	for my $feat ($seq->get_SeqFeatures){
		next if $feat->primary_tag eq "source";

		my $start = $feat->location->start;
		my $end = $feat->location->end;
		if($start <= $end){
			$itree->insert($feat, $start - 1,  $end + 1);
			}
		else{
			$itree->insert($feat, $end - 1,  $start + 1);		
			}
		}
		
	# debuggin itree #	
	#	print_itree($itree, 500);
	
	# checking for overlap #
	my $trans = 0; my $last;
	for my $i ($region_start..$region_end){
		my $res = $itree->fetch($i, $i);
		if(! $last){
			if($$res[0]){ $last = 2; }			# gene-leader overlap at start
			else{ $last = 1; } 					# gene-leader overlap at end 
			}
		elsif($$res[0] && $last == 1){		# hitting overlap after no previous overlap (leader at end)
			$trans = $i;
			die " LOGIC ERROR: gene overlap at the wrong end of the leader region for cli.$locus!\n"
				unless $leader_loc eq "end"; 
			last;
			}
		elsif( ! $$res[0] && $last ==2 ){	# no more overlap after previous overlap (leader at start)
			$trans = $i - 1;
			die " LOGIC ERROR: gene overlap at the wrong end of the leader region for cli.$locus!\n"
				unless $leader_loc eq "start"; 
			last;
			}
		elsif($$res[0]){
			$last = 2;
			}
		elsif(! $$res[0]){
			$last = 1;
			}
		else{ die $!; }
		}	
		
	# altering start / stop #
	$trans -= $region_start if $trans;			# making index local to region (instead of genome)
	if($trans){
		print STDERR "WARNING: Gene(s) overlap the leader in cli.$locus array. Truncating\n" unless $verbose;
		
		if($leader_loc eq "start"){				# gene overlaps at 5' end
			$region_start += $trans;			
			}
		elsif($leader_loc eq "end"){			# gene overlaps at the 3' end
			$region_end -= $trans;
			}
		}
	return $seq, $region_start, $region_end;
	}
	
sub get_leader_seq_OLD{
# getting leader seqs from genbanks #
	my ($array_se_r, $leader_loc_r, $genbank_path, $length) = @_;

	# getting all leader regions for each genbank #
	my %genbank_loci_index;
	foreach my $locus (keys %$array_se_r){
		push(@{$genbank_loci_index{ ${$array_se_r->{$locus}}[3] }}, $locus);
		}

	# output of genbank regions #
	my $out = Bio::SeqIO->new(-format => "fasta", -fh => \*STDOUT);
	
	# opening genbanks & getting sequences #
	foreach my $genbank_file (keys %genbank_loci_index){
		
		# loadign genbank #
		my $seqio = Bio::SeqIO->new(-format => "genbank", 
								-file => "$genbank_path/$genbank_file");
		while( my $seqo = $seqio->next_seq ){
			# checking for sequence in genbank file; if not provided, die #
			unless($seqo->seq){ 
				print STDERR " ERROR: no genomic sequence found in $genbank_file! Cannot extract the leader sequence from the genome!\n";
				next;
				}
			foreach my $locus (@{$genbank_loci_index{ $genbank_file }} ){
				foreach my $loc (@{$leader_loc_r->{$locus}}){		# if both ends, must get both
					
					# only comparing on the same scaffold (or just 1 scaffold)
					my $leader_scaf = ${$array_se_r->{$locus}}[4];
					next unless $leader_scaf eq "CLDB__ONE_CHROMOSOME" ||
						$leader_scaf eq $seqo->display_id;
					
					# determining leader region start-end
					my $leader_start;
					my $leader_end;
					my $array_start = ${$array_se_r->{$locus}}[1];
					my $array_end = ${$array_se_r->{$locus}}[2];
					
					if($loc eq "start" ){
						$leader_start = $array_start - $length;
						$leader_end = $array_start; 
						}
					elsif($loc eq "end"){		# if "end"
						$leader_start = $array_end;
						$leader_end = $array_end + $length;
						}
					else{ die " LOGIC ERROR: $!\n"; }
					
					# no negative (or zero) values (due to $length extending beyond scaffold) #
					$leader_start = 1 if $leader_start < 1;
					$leader_end = 1 if $leader_end < 1;
					
					# leader start & end must be < total scaffold length #
					my $scaf_len = length $seqo->seq;
					$leader_start = $scaf_len if $leader_start > $scaf_len;
					$leader_end = $scaf_len if $leader_end > $scaf_len;
					
					# checking for gene overlap #
					($seqo, $leader_start, $leader_end) = check_gene_overlap($seqo, $leader_start, $leader_end, $loc, $locus)
						unless $overlap_check;
					
					# parsing seq from genbank #
					my $leader_seqo = $seqo->trunc($leader_start, $leader_end);					
					$leader_seqo->display_id("cli.$locus\___$loc\___$leader_scaf\___$leader_start\___$leader_end");
					$leader_seqo->desc(" $loc\___$leader_scaf\___$leader_start\___$leader_end");
					$leader_seqo->desc("");
									
					$out->write_seq($leader_seqo);
					}
				}
			}
		}
	}
	
sub revcomp_OLD{
	# reverse complements DNA #
	my $seq = shift;
	$seq = reverse($seq);
	$seq =~ tr/[a-z]/[A-Z]/;
	$seq =~ tr/ACGTNBVDHKMRYSW\.-/TGCANVBHDMKYRSW\.-/;
	return $seq;
	}
	
sub join_query_opts_OLD{
# joining query options for selecting loci #
	my ($vals_r, $cat) = @_;

	return "" unless @$vals_r;	
	
	map{ s/"*(.+)"*/"$1"/ } @$vals_r;
	return join("", " AND $cat IN (", join(", ", @$vals_r), ")");
	}
	
sub get_select_array_se_OLD{
# getting arrays that start w/in 500 bp of leader #
	my ($dbh, $leader_tbl_r) = @_;
	
	# querying for taxon_names #
	## sql ##
	my $q = "SELECT
Locus_ID, array_start, array_end, fasta_file, genbank_file, scaffold, 
FROM loci
WHERE (array_start is not null OR array_end is not null)
AND (taxon_name = ? OR taxon_id = ?)
AND scaffold = ?
ORDER BY min_dist
";

	$q =~ s/\n/ /g;
	my $sql = $dbh->prepare($q);
	
	## querying db ##
	my %ret;
	foreach my $row (@$leader_tbl_r){
		my @tmp = @$row;
		@tmp[3..4] = ($$row[4], $$row[3]) if $$row[3] > $$row[4]; 	# flipping start-end to + strand
	
		$sql->execute(@tmp[3..4,0..2]);
		
		my @res;
		while(my $i = $sql->fetchrow_arrayref()){
			# moving array start-end to + strand # 
			my $strand = 1;
			if($$i[1] > $$i[2]){
				$strand = -1;
				($$i[2], $$i[1]) = ($$i[1], $$i[2]);
				}
			my @tmp = @$i;
			push @tmp, $strand;
			push @res, \@tmp;
			}
		die " ERROR: no matching entries!\n" unless @res;
		
		print STDERR "...Distance to closest array for specified leader region: '", join(",", @$row), "' = $res[0][6] bp (cli.$res[0][0])\n";
		print STDERR " WARNING!!! Closest distance is >500bp!" if $res[0][6] > 500;
		
		$ret{$res[0][0]} = [@{$res[0]}];
		}

		#print Dumper %ret; exit;
	return \%ret;
	}
