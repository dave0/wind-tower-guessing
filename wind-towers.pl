#!/usr/bin/perl -w
use strict;
use warnings;
use LWP::Simple;
use Data::Dumper;
use Getopt::Long;
use Parse::SpectrumDirect::RadioFrequency;
use POSIX qw( EXIT_SUCCESS );

# This script uses Parse::SpectrumDirect::RadioFrequency to parse Industry
# Canada "Spectrum Direct" information for Wind Mobile towers.  Currently, it
# will spit out Ottawa tower locations to stdout.
#
# Note that as far as I know, these are NOT the handset-servicing towers, nor
# are they all of Wind's towers.  These are the locations of licensed
# frequencies typically used for point-to-point backhaul.  Wind also has
# licenses for non-location-specific 39GHz spectrum:
# 	http://sd.ic.gc.ca/pls/engdoc_anon/speclic_browser$licence.QueryViewByKey?P_LIC_NO=5089668&Z_CHK=32695
# which is possibly (note: I know nothing about the wireless industry I haven't
# read on the internet) going to be used to connect their handset-servicing
# towers to the wireless backbone implemented by the towers shown in the list
# retrieved by this tool.
#

# URI for text version of results obtained by searching:
# 	http://sd.ic.gc.ca/pls/engdoc_anon/web_search.licensee_name_input
# for "Globalive Wireless" and choosing the appropriate result.

my @valid_formats = qw( text kml dumper );
my $output_format = 'text';
my $show_dups = 0;
GetOptions(
	'output=s' => \$output_format,
	'showduplicates' => \$show_dups,
);

if( !$output_format || ! grep { $output_format eq $_ } @valid_formats ) {
	die qq{$output_format is not a valid output format};
}

my $wind_company_cd = '90045300';
my %admin_areas = (
	ontario => 41,
	quebec  => 51,
);

my @data_rows;
my $parser =  Parse::SpectrumDirect::RadioFrequency->new();
while( my ($name, $area) = each %admin_areas ) {
	warn "Fetching data for $name";

	my $url = 'http://sd.ic.gc.ca/pls/engdoc_anon/web_search.licensee_name_results?output_format=2&selected_columns=TX_FREQ,RX_FREQ,LOCATION&col_in_fmt=COMMA_LIST&selected_column_group=NONE&extra_ascii=LINK_STATION'
		. "&admin_do=$area"
		. "&company_cd=$wind_company_cd";

	# my $content = do { open(my $fh, "<raw_data.txt") or die "No data!";  local $/; <$fh> };
	my $content = get( $url );
	unless( defined $content ) {
		warn qq{Couldn't fetch content for $name; skipping};
	}

	# Convert from DOS-format.
	$content =~ s/\r\n/\n/g;

	if( $parser->parse( $content ) ) {
		push (@data_rows, @{$parser->get_stations()});
	}
}

# Yes, the misspellings do exist in the source data.  Industry Canada needs to hire some geography students.
# Incorrect spellings left in ALL CAPS as in source data, to make them easier to remove later.
my %metro_areas = (
	ottawa => [qw(
		Ottawa Kanata Nepean Gatineau
		NEAPEAN GATINEQC GATINEQU
	)],

	gta   => [qw(
		Ajax Ancaster Aurora Brampton Burlington Courtice Downsview Etobicoke Georgetown Hamilton Markham Milton
		Mississauga Newmarket Oakville Oshawa Pickering Rexdale Scarborough Thornhill Toronto Vaughan Whitby
		TORONTON BURLIGNTON GEOGRETOWN BRULINGTON MAKRHAM TOROTNO
		),
		# Can't qw() these:
		'North York', 'Richmond Hill', 'RICMOND HILL'
	],
);

# Grab ottawa towers
my @ottawa_towers;
foreach my $row (@data_rows) {

	my $where = guess_metro_area( $row );
	next unless $where;

	next if grep { lc $where eq lc $_ } @{ $metro_areas{gta} };

	unless(grep { lc $where eq lc $_ } @{ $metro_areas{ottawa} } ) {
		warn "What to do with $where: " . Dumper($row);
		next;
	}

	push @ottawa_towers, $row;
}

# Clean up rows
foreach my $row (@ottawa_towers ) {

	# Hack reformatting
	$row->{Station_Location} =~ s/NEA?PEAN/Nepean/;
	$row->{Station_Location} =~ s/OTTAWA/Ottawa/;
	$row->{Station_Location} =~ s/^(.*?)\s+\((.*?)\)\s*(.*?)?$/$2, $1, $3/;
	$row->{Station_Location} =~ s/,\s+$/, ON/;

	# Make a completely wild-ass guess about the range of these towers.
	#
	# modified Friis Transmission Equation from
	# http://www.moxa.com/newsletter/connection/2008/03/Figure_out_transmission_distance_from_wireless_device_specs.htm
	#
	# Conversions:
	# 	dBm = dBW + 30

	my $p_t = $row->{Tx_Power} + 30;   # Tx Power, in dBm
	my $g_t = $row->{Tx_Antenna_Gain}; # Tx antenna gain, in dBi

	# We don't know the recipient's rx sensitivity or gain, so we assume
	# it's as good as this tower's.  Not quite correct, but it may do for
	# now.
	my $p_r = $row->{Unfaded_Received_Signal_Level} + 30; # Rx sensitivity in dBm (ummm.... but, it's not transmitting to itself, now, is it)
	my $g_r = $row->{Rx_Antenna_Gain}; # Rx gain in dBi (again, not sending to self)

	$row->{Range} = ( 10**(($p_t + $g_t + $g_r - $p_r) / 20)) / (41.88 * $row->{Tx_Frequency}) if $row->{Tx_Frequency};
}

my $render = \&{"render_$output_format"};
if( ! defined $render ) {
	die qq{Can't find renderer for $output_format};
}

$render->( \@ottawa_towers );
exit(EXIT_SUCCESS);

sub render_dumper
{
	my ($towers) = @_;
	print Dumper $towers;
}

sub render_text
{
	my ($towers) = @_;

	my %seen_locations = ();
	foreach my $row (sort { $a->{Longitude} <=> $b->{Longitude} } @$towers ) {
		next if (!$show_dups && $seen_locations{ $row->{Station_Location} }++);

		printf "% 40s %2.4flat %2.4flng, %dMHz, %dm AGL, %d dBW, range %.2f km\n",
			$row->{Station_Location},
			$row->{Latitude},
			$row->{Longitude},
			$row->{Tx_Frequency},
			$row->{Tx_Antenna_Height_Above_Ground_Level},
			$row->{Tx_Power},
			$row->{Range};
	}
}

sub render_kml
{
	my ($towers) = @_;

	require Geo::GoogleEarth::Document;
	my $kml = Geo::GoogleEarth::Document->new();

	my %seen_locations = ();
	foreach my $row (sort { $a->{Longitude} <=> $b->{Longitude} } @ottawa_towers ) {
		next if (!$show_dups && $seen_locations{ $row->{Station_Location} }++);

		$kml->Placemark(
			name => $row->{Station_Location},
			lat  => $row->{Latitude},
			lon  => $row->{Longitude},
		);
	}

	print $kml->render();
}

sub guess_metro_area
{
	my ($station) = @_;

	# Special cases first
	if( $station->{Link_Station_Location} && $station->{Station_Location} =~ /^gatineau/i ) {
		return 'Gatineau';
	}

	my $where = $station->{Link_Station_Location} || '';

	# Hack... some stations have a coded location, so use their street address instead
	if( $where =~ /\d/ && $station->{Station_Location} ) {
		($where) = $station->{Station_Location} =~ m/^(.*)\s+\(/;
	}

	$where =~ s/,?\s+(on|qc)$//i;

	return $where;
}
