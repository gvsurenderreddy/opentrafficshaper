# OpenTrafficShaper webserver module: statistics page
# Copyright (C) 2007-2013, AllWorldIT
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package opentrafficshaper::plugins::webserver::pages::statistics;

use strict;
use warnings;


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
);


use DateTime;
use HTML::Entities;
use HTTP::Status qw( :constants );
use JSON;

use opentrafficshaper::logger;
use opentrafficshaper::plugins;
use opentrafficshaper::utils qw(
	parseURIQuery
);

use opentrafficshaper::plugins::configmanager qw(
	getLimit

	getInterfaceGroup
	getInterface

	isTrafficClassValid
	getTrafficClassName
);

use opentrafficshaper::plugins::statistics::statistics;



# Graphs by limit
sub bylimit
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Header
	my $content = <<EOF;
		<div id="header">
			<h2>Limit Stats View</h2>
		</div>
EOF

	my $limit;

	# Check request
	if ($request->method eq "GET") {
		# Parse GET data
		my $queryParams = parseURIQuery($request);
		# We need our LID
		if (!defined($queryParams->{'lid'})) {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">No LID in Query String</p></td>
				</tr>
EOF
			goto END;
		}
		# Check if we get some data back when pulling the limit from the backend
		if (!defined($limit = getLimit($queryParams->{'lid'}->{'value'}))) {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">No Results</p></td>
				</tr>
EOF
			goto END;
		}
	}

	my $name = (defined($limit->{'FriendlyName'}) && $limit->{'FriendlyName'} ne "") ? $limit->{'FriendlyName'} : $limit->{'Username'};
	my $usernameEncoded = encode_entities($name);


	# Build content
	$content = <<EOF;
		<h4 style="color:#8f8f8f;">Latest Data For: $usernameEncoded</h4>
		<br/>
		<div id="flotCanvas" class="flotCanvas" style="width: 1000px; height: 400px"></div>
EOF

	#$content .= statistics::do_test();
#	$content .= opentrafficshaper::plugins::statistics::do_test();

	# Files loaded at end of HTML document
	my @javascripts = (
		'/static/flot/jquery.flot.min.js',
		'/static/flot/jquery.flot.time.min.js',
		'/static/awit-flot/functions.js',
#		'/static/awit-flot/jquery.flot.websockets.js'
	);

	# Build our data path using the URI module to make sure its nice and clean
	my $dataPath = sprintf('/statistics/jsondata?limit=%s',$limit->{'ID'});

	# String put in <script> </script> tags after the above files are loaded
	my $javascript = _getJavascript($dataPath);

END:

	return (HTTP_OK,$content,{ 'javascripts' => \@javascripts, 'javascript' => $javascript });
}



# Graphs by class
sub byclass
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Header
	my $content = <<EOF;
		<div id="header">
			<h2>Class Stats View</h2>
		</div>
EOF

	my $interface;
	my $cid;

	# Check if its a GET request...
	if ($request->method eq "GET") {
		# Parse GET data
		my $queryParams = parseURIQuery($request);
		# Grab the interface name
		if (!defined($queryParams->{'interface'})) {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">No interface in Query String</p></td>
				</tr>
EOF
			goto END;
		}
		# Check if we get some data back when pulling the interface from the backend
		if (!defined($interface = getInterface($queryParams->{'interface'}->{'value'}))) {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">No Interface Results</p></td>
				</tr>
EOF
			goto END;
		}
		# Grab the class
		if (!defined($queryParams->{'class'})) {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">No class in Query String</p></td>
				</tr>
EOF
			goto END;
		}
		# Check if our traffic class is valid
		if (!defined($cid = isTrafficClassValid($queryParams->{'class'}->{'value'})) && $queryParams->{'class'}->{'value'} ne "0") {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">No Class Results</p></td>
				</tr>
EOF
			goto END;
		}
	}

	my $interfaceNameEncoded = encode_entities($interface->{'name'});

	my $classNameEncoded;
	if ($cid) {
		$classNameEncoded = encode_entities(getTrafficClassName($cid));
	} else {
		$classNameEncoded = $interfaceNameEncoded;
	}


	# Build content
	$content = <<EOF;
			<h4 style="color:#8f8f8f;">Latest Data For: $classNameEncoded on $interfaceNameEncoded</h4>
			<br/>
			<div id="flotCanvas" class="flotCanvas" style="width: 1000px; height: 400px"></div>
EOF

	# Files loaded at end of HTML document
	my @javascripts = (
		'/static/flot/jquery.flot.min.js',
		'/static/flot/jquery.flot.time.min.js',
		'/static/awit-flot/functions.js',
	);

	# Build our data path using the URI module to make sure its nice and clean
	my $dataPath = '/statistics/jsondata?counter=ConfigManager:TotalLimits&interface-group=eth4,eth5';


	# String put in <script> </script> tags after the above files are loaded
	my $javascript = _getJavascript($dataPath);

END:

	return (HTTP_OK,$content,{ 'javascripts' => \@javascripts, 'javascript' => $javascript });
}



# Return data in json format
#
# Supported URLs:
#
#	limit=<limit-id>
#
#	class=<interface-group-id>:<class-id>,...
#	- must return both tx and rx sides
#
#	interface-group=<interface-group>,...
#	- must retun both tx and rx sides
#
#	counter=<counter>,...
#
#	max=<max number of entries to return, default 100>
#
#	key=<data key to return>
sub jsondata
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Parse GET data
	my $queryParams = parseURIQuery($request);

	my $jsonData = [ ];

	# Process limits
	if (defined($queryParams->{'limit'})) {
		# Lets get unique limits as keys
		my %limits;
		foreach my $lid (@{$queryParams->{'limit'}->{'values'}}) {
			$limits{$lid} = 1;
		}

		# Then loop through the unique keys
		foreach my $lid (keys %limits) {
			# Grab limit
			my $limit = getLimit($lid);
			if (!defined($limit)) {
				$globals->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Got request for non-existent limit ID '$lid'");
				next;
			}

			# Pull in stats data
			my $sid = opentrafficshaper::plugins::statistics::getSIDFromLID($limit->{'ID'});
			my $statsData = opentrafficshaper::plugins::statistics::getStatsBySID($sid);

			# First stage, pull in the data items we want
			my $rawData;
			foreach my $timestamp (sort keys %{$statsData}) {
				foreach my $direction (keys %{$statsData->{$timestamp}}) {
					foreach my $stat ('cir','limit','pps','rate') {
						# Flow of traffic is always in tx direction
						push(  @{$rawData->{"$direction.$stat"}->{'data'}} , [ $timestamp , $statsData->{$timestamp}->{$direction}->{$stat} ] );
					}
				}
			}

			# JSON stuff we looking for
			foreach my $direction ('tx','rx') {
				foreach my $stat ('cir','limit','rate') {
					# Make it looks nice:  Tx Rate
					my $label = uc($direction) . " " . ucfirst($stat);
					# And set it as the label
					$rawData->{"$direction.$stat"}->{'label'} = $label;
					# Push the data to return...
					if (defined($rawData->{"$direction.$stat"}->{'data'})) {
							push(@{$jsonData},$rawData->{"$direction.$stat"});
					}
				}
			}
		}
	}

	# Process classes
	if (defined($queryParams->{'class'})) {
		# Lets get unique counters as keys
		my %classes;
		foreach my $rawClass (@{$queryParams->{'class'}->{'values'}}) {
			$classes{$rawClass} = 1;
		}
		# Then loop through the unique keys
		foreach my $rawClass (keys %classes) {
			# Split off based on :
			my ($rawInterfaceGroup,$rawClass) = split(/:/,$rawClass);

			# Get more sane values...
			my $interfaceGroup = getInterfaceGroup($rawInterfaceGroup);
			if (!defined($interfaceGroup)) {
				$globals->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Got request for non-existent interface group '$rawInterfaceGroup'");
				next;
			}
			my $class = isTrafficClassValid($rawClass);
			if (!defined($class)) {
				$globals->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Got request for non-existent traffic class '$rawClass'");
				next;
			}

			# Second stage - add labels
			foreach my $direction ('tx','rx') {
				my $rawData;

				# Pull in stats data
				my $sid = opentrafficshaper::plugins::statistics::getSIDFromCID($interfaceGroup->{"${direction}iface"},$class);
				my $statsData = opentrafficshaper::plugins::statistics::getStatsBySID($sid);

				# First stage, pull in the data items we want
				foreach my $timestamp (sort keys %{$statsData}) {
					foreach my $stat ('cir','limit','pps','rate') {
						# Flow of traffic is always in tx direction
						push(  @{$rawData->{"$direction.$stat"}->{'data'}} , [ $timestamp , $statsData->{$timestamp}->{"tx"}->{$stat} ] );
					}
				}
				# Second state, add labels
				foreach my $stat ('cir','limit','pps','rate') {
					# Make it looks nice:  Tx Rate
					my $label = uc($direction) . " " . ucfirst($stat);
					# And set it as the label
					$rawData->{"$direction.$stat"}->{'label'} = $label;
				}

				# JSON stuff we looking for
				foreach my $stat ('cir','limit','rate') {
					if (defined($rawData->{"$direction.$stat"}->{'data'})) {
							push(@{$jsonData},$rawData->{"$direction.$stat"});
					}
				}
			}
		}
	}

	# Process interface groups
	if (defined($queryParams->{'interface-group'})) {
		# Lets get unique counters as keys
		my %interfaceGroups;
		foreach my $group (@{$queryParams->{'interface-group'}->{'values'}}) {
			$interfaceGroups{$group} = 1;
		}
		# Then loop through the unique keys
		foreach my $group (keys %interfaceGroups) {
			my $interfaceGroup = getInterfaceGroup($group);
			if (!defined($interfaceGroup)) {
				next;
			}

			# Second stage - add labels
			foreach my $direction ('tx','rx') {
				my $rawData;

				# Pull in stats data
				my $sid = opentrafficshaper::plugins::statistics::getSIDFromCID($interfaceGroup->{"${direction}iface"},0);
				my $statsData = opentrafficshaper::plugins::statistics::getStatsBySID($sid);

				# First stage, pull in the data items we want
				foreach my $timestamp (sort keys %{$statsData}) {
					foreach my $stat ('cir','limit','pps','rate') {
						# Flow of traffic is always in tx direction
						push(  @{$rawData->{"$direction.$stat"}->{'data'}} , [ $timestamp , $statsData->{$timestamp}->{"tx"}->{$stat} ] );
					}
				}
				# Second state, add labels
				foreach my $stat ('cir','limit','pps','rate') {
					# Make it looks nice:  Tx Rate
					my $label = uc($direction) . " " . ucfirst($stat);
					# And set it as the label
					$rawData->{"$direction.$stat"}->{'label'} = $label;
				}

				# JSON stuff we looking for
				foreach my $stat ('cir','limit','rate') {
					if (defined($rawData->{"$direction.$stat"}->{'data'})) {
							push(@{$jsonData},$rawData->{"$direction.$stat"});
					}
				}
			}
		}
	}

	# If we need to return a counter, lets see what there is we can return...
	if (defined($queryParams->{'counter'})) {
		# Lets get unique counters as keys
		my %counters;
		foreach my $counter (@{$queryParams->{'counter'}->{'values'}}) {
			$counters{$counter} = 1;
		}
		# Then loop through the unique keys
		foreach my $counter (keys %counters) {
			# Grab the SID
			if (my $sid = opentrafficshaper::plugins::statistics::getSIDFromCounter($counter)) {
				my $rawData;

				# Grab stats
				my $statsData = opentrafficshaper::plugins::statistics::getStatsBasicBySID($sid);

				# First stage refinement
				foreach my $timestamp (sort keys %{$statsData}) {
					# Flow of traffic is always in tx direction
					push(  @{$rawData->{'data'}} , [ $timestamp , $statsData->{$timestamp}->{'counter'} ] );
				}

				# We need to give it a funky name ...
				$rawData->{'label'} = "Unknown";
				if ($counter eq "ConfigManager:TotalLimits") {
					$rawData->{'label'} = "Total Limits";
				}

				# Push it onto our data stack...
				push(@{$jsonData},$rawData);

			} else {
				return (HTTP_OK,{ 'error' => 'Invalid Counter' },{ 'type' => 'json' });
			}
		}
	}

	return (HTTP_OK,$jsonData,{ 'type' => 'json' });
}


# Return javascript for the graph
sub _getJavascript
{
	my $graphData = shift;

	# Build our data path using the URI module to make sure its nice and clean
	my $dataPath = URI->new($graphData);
	my $dataPathStr = $dataPath->as_string();

	my $javascript =<<EOF;
	awit_flot_draw_graph({
		url: '$dataPathStr',
		yaxes: [
			{
				labels: ['Total Limits'],
				position: 'right',
				tickDecimals: 0,
				min: 0	
			}
		]
	});
EOF

	return $javascript;
}


1;
