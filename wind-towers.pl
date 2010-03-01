#!/usr/bin/perl -w
use strict;
use warnings;
use LWP::Simple;
use Data::Dumper;

# http://sd.ic.gc.ca/pls/engdoc_anon/web_search.licensee_name_results?output_format=2&selected_columns=TX_FREQ,RX_FREQ,LOCATION,COMPANY_NAME&col_in_fmt=COMMA_LIST&selected_column_group=NONE&extra_ascii=LINK_STATION&extra_xml=None&licensee_name=Globalive%20Wireless%20Management%20Corp.%20Attn%3A%20Ahmed%20Derini&admin_do=41&company_cd=90045300
# or shorter:
# http://sd.ic.gc.ca/pls/engdoc_anon/web_search.licensee_name_results?output_format=2&selected_columns=TX_FREQ,RX_FREQ,LOCATION&col_in_fmt=COMMA_LIST&selected_column_group=NONE&extra_ascii=LINK_STATION&admin_do=41&company_cd=90045300

my $ontario_search_url = 'http://sd.ic.gc.ca/pls/engdoc_anon/web_search.licensee_name_results?output_format=2&selected_columns=TX_FREQ,RX_FREQ,LOCATION&col_in_fmt=COMMA_LIST&selected_column_group=NONE&extra_ascii=LINK_STATION&admin_do=41&company_cd=90045300';

my $content   = retrieve_content( $ontario_search_url );
my $legend    = extract_legend( $content );
my $data_rows = extract_data( $legend, $content );

# Yes, the misspellings do exist in the source data.  Industry Canada needs to hire some geography students.
# Incorrect spellings left in ALL CAPS as in source data, to make them easier to remove later.
my %metro_areas = (
	ottawa => [qw(
		Ottawa Kanata Nepean Gatineau
		NEAPEAN GATINEQC GATINEQU
	)],

	gta   => [qw(
		Ajax Ancaster Aurora Brampton Burlington Courtice Downsview Etobicoke Georgetown Hamilton Markham Milton
	`	Mississauga Newmarket Oakville Oshawa Pickering Rexdale Scarborough Thornhill Toronto Vaughan Whitby
		TORONTON BURLIGNTON GEOGRETOWN BRULINGTON MAKRHAM TOROTNO
		),
		# Can't qw() these:
		'North York', 'Richmond Hill', 'RICMOND HILL'
	],
);

# Grab ottawa towers
my @ottawa_towers;
foreach my $row (@{$data_rows}) {

	my $where = $row->{Link_Station_Location} || '';

	# Hack... some stations have a coded location, so use their street address instead
	if( $where =~ /\d/ ) {
		($where) = $row->{Station_Location} =~ m/^(.*)\s+\(/;
	}

	next unless $where;
	$where =~ s/\s+(on|qc)$//i;

	next if grep { lc $where eq lc $_ } @{ $metro_areas{gta} };

	unless(grep { lc $where eq lc $_ } @{ $metro_areas{ottawa} } ) {
		warn "What to do with $where: " . Dumper($row);
		next;
	}

	push @ottawa_towers, $row;
}

# Dump tower locations in west-east order
my %seen_locations = ();
foreach my $row (sort { $b->{Longitude} <=> $a->{Longitude} } @ottawa_towers ) {

	# Hack reformatting
	$row->{Station_Location} =~ s/NEA?PEAN/Nepean/;
	$row->{Station_Location} =~ s/OTTAWA/Ottawa/;
	$row->{Station_Location} =~ s/^(.*?)\s+\((.*?)\)\s*(.*?)?$/$2, $1, $3/;

	# Stations may be licensed for multiple frequencies, but we don't care about that yet.
	next if $seen_locations{ $row->{Station_Location} }++;

	printf "% 40s %6dlat %6dlng, %dMHz, %dm AGL, %d dBW\n",
		$row->{Station_Location},
		$row->{Latitude},
		$row->{Longitude},
		$row->{Tx_Frequency},
		$row->{Tx_Antenna_Height_Above_Ground_Level},
		$row->{Tx_Power};
}

sub retrieve_content
{
	my ($url) = @_;

	# my $content = do { open(my $fh, "<raw_data.txt") or die "No data!";  local $/; <$fh> };
	my $content = get( $url );
	die "Couldn't fetch content" unless defined $content;

	# Convert from DOS-format.
	$content =~ s/\r\n/\n/g;

	return $content;
}

# Return legend as an arrayref of hashrefs.  Each hashref contains:
# 	name (from original legend, stripped of trailing spaces)
# 	units (if determinable from name)
# 	key (name stripped of unit information, whitespaces converted to _)
# 	start (column index to start extraction)
# 	end (column count)
sub extract_legend
{
	my ($content) = @_;

	my ($raw_legend) = $content =~ m/Field Position Legend(.*)/sm;
	my $legend = [];
	foreach my $line (split(/\n/, $raw_legend)) {

		# Lines are in the format of:
		# 	name    start - end
		# with the columns starting at 1.

		my ($name, $start, $end) = $line =~ m/(.*?)\s+(\d+) - (\d+)/;
		next unless $name;
		$name =~ s/\s+$//;

		# Pull off units
		my $units = undef;
		if( $name =~ m/\((.*?)\)$/ ) {
			$units = $1;
		}

		my $key = $name;
		$key =~ s/\(.*?\)//g;
		$key =~ s/\s+$//;
		$key =~ s/\s+/_/g;

		my $col = {
			key   => $key,
			units => $units,
			name  => $name,
			start => $start - 1,
			len   => $end - $start + 1,
		};
		push @$legend,$col;

	}

	return $legend;
}

# Return data as an arrayref of hashrefs, one per row.
sub extract_data
{
	my ($legend, $content) = @_;

	my $regex   = join('\s', map { "(.{$_->{len},$_->{len}})" } @$legend );
	my @key_ary = map { $_->{key} } @$legend;

	my ($data)   = $content =~ m/\[DATA\](.*)\[\/DATA\]/sm;
	my @rows;
	foreach my $line (split(/\n/,$data)) {
		my (@tmprow) = $line =~ /$regex/o;

		my %row;

		@tmprow = map { s/^\s+//; $_ } @tmprow;
		@row{@key_ary} = map { s/\s+$//; $_ } @tmprow;
		push @rows, \%row;
	}

	return \@rows;
}

