# OpenTrafficShaper webserver module: statistics page
# Copyright (C) 2007-2014, AllWorldIT
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
use HTTP::Status qw(
	:constants
);
use JSON;
use URI::Escape qw(
	uri_escape
);

use awitpt::util qw(
	parseURIQuery
);
use opentrafficshaper::logger;
use opentrafficshaper::plugins;
use opentrafficshaper::plugins::configmanager qw(
	getPoolByName

	getInterfaceGroup
	getInterfaceGroups
	getInterface

	getTrafficClass
	getAllTrafficClasses

	isTrafficClassIDValid
);

use opentrafficshaper::plugins::statistics::statistics;



# Graphs by pool
sub byPool
{
	my ($kernel,$system,$client_session_id,$request) = @_;


	# Header
	my $content = <<EOF;
		<div id="header">
			<h2>Pool Stats View</h2>
		</div>
EOF

	my $pool;

	# Check request
	if ($request->method eq "GET") {
		# Parse GET data
		my $queryParams = parseURIQuery($request);
		# We need our PID
		if (!defined($queryParams->{'pool'})) {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">No "pool" in Query String</p></td>
				</tr>
EOF
			goto END;
		}

		# Check we have an interface group ID and pool name
		my ($interfaceGroupID,$poolName) = split(/:/,$queryParams->{'pool'}->{'value'});
		if (!defined($interfaceGroupID) || !defined($poolName)) {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">Format of "pool" option is invalid, use InterfaceID:PoolName</p></td>
				</tr>
EOF
			goto END;
		}

		# Check if we get some data back when pulling in the pool from the backend
		if (!defined($pool = getPoolByName($interfaceGroupID,$poolName))) {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">No Results</p></td>
				</tr>
EOF
			goto END;
		}
	}

	my $name = (defined($pool->{'FriendlyName'}) && $pool->{'FriendlyName'} ne "") ? $pool->{'FriendlyName'} :
			$pool->{'Name'};
	my $nameEncoded = encode_entities($name);

	my $canvasName = "flotCanvas";

	# Build content
	$content = <<EOF;
		<h4 style="color:#8f8f8f;">Latest Data For: $nameEncoded</h4>
		<br/>
		<div id="$canvasName" class="flotCanvas" style="width: 1000px; height: 400px"></div>
EOF

	# Files loaded at end of HTML document
	my @javascripts = (
		'/static/flot/jquery.flot.min.js',
		'/static/flot/jquery.flot.time.min.js',
		'/static/js/flot-functions.js',
		'/static/awit-flot-toolkit/js/jquery.flot.awitds.js'
	);

	# Path to the json data, just use "data" as the tag
	my $dataPath = sprintf('/statistics/jsondata?pool=%s:%s:%s',"tag1",$pool->{'InterfaceGroupID'},$pool->{'Name'});

	# String put in <script> </script> tags after the above files are loaded
	my $javascript = _getJavascript($canvasName,$dataPath);

END:

	return (HTTP_OK,$content,{ 'javascripts' => \@javascripts, 'javascript' => $javascript });
}



# Graphs by class
sub byClass
{
	my ($kernel,$system,$client_session_id,$request) = @_;


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
		if (!defined($cid = isTrafficClassIDValid($queryParams->{'class'}->{'value'})) &&
				$queryParams->{'class'}->{'value'} ne "0"
		) {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">No Class Results</p></td>
				</tr>
EOF
			goto END;
		}
	}

	my $trafficClass = getTrafficClass($cid);

	my $interfaceNameEncoded = encode_entities($interface->{'Name'});

	my $trafficClassNameEncoded;
	if ($cid) {
		$trafficClassNameEncoded = encode_entities($trafficClass->{'Name'});
	} else {
		$trafficClassNameEncoded = $interfaceNameEncoded;
	}

	my $canvasName = "flotCanvas";

	# Build content
	$content = <<EOF;
			<h4 style="color:#8f8f8f;">Latest Data For: $trafficClassNameEncoded on $interfaceNameEncoded</h4>
			<br/>
			<div id="flotCanvas" class="flotCanvas" style="width: 1000px; height: 400px"></div>
EOF

	# Files loaded at end of HTML document
	my @javascripts = (
		'/static/flot/jquery.flot.min.js',
		'/static/flot/jquery.flot.time.min.js',
		'/static/js/flot-functions.js',
		'/static/awit-flot-toolkit/js/jquery.flot.awitds.js'
	);

	# Build our data path using the URI module to make sure its nice and clean
	my $dataPath = '/statistics/jsondata?counter=ConfigManager:TotalLimits&interface-group=eth4,eth5';


	# String put in <script> </script> tags after the above files are loaded
	my $javascript = _getJavascript($canvasName,$dataPath);

END:

	return (HTTP_OK,$content,{ 'javascripts' => \@javascripts, 'javascript' => $javascript });
}



# Dashboard display
sub _dashboard
{
	my ($kernel,$system,$client_session_id,$request) = @_;


	# Header
	my $content = <<EOF;
		<div id="header">
			<h2>Dashboard View</h2>
		</div>
EOF

	# Left and right graphs are added to the main graph list
	my @graphs = ();
	# Left and right graphs
	my @leftGraphs = ();
	my @rightGraphs = ();

	# Build list of graphs for the left hand side
	my @interfaceGroups = sort(getInterfaceGroups());
	my @trafficClasses = sort(getAllTrafficClasses());

	foreach my $interfaceGroupID (@interfaceGroups) {
		my $interfaceGroup = getInterfaceGroup($interfaceGroupID);

		foreach my $trafficClassID (@trafficClasses) {
			my $trafficClass = getTrafficClass($trafficClassID);

			push(@leftGraphs,{
				'Type' => 'graph',
				'Title' => sprintf("%s: %s",$interfaceGroup->{'Name'},$trafficClass->{'Name'}),
				'Datasources' => [
					sprintf('class=%s:%s',$interfaceGroupID,$trafficClassID),
					sprintf('counter=configmanager.classpools.%s',$trafficClassID)
				],
				'XIdentifiers' => [
					{ 'Name' => 'tx.cir', 'Label' => "TX Cir" },
					{ 'Name' => 'tx.limit', 'Label' => "TX Limit" },
					{ 'Name' => 'tx.rate', 'Label' => "TX Rate" },
					{ 'Name' => 'rx.cir', 'Label' => "RX Cir" },
					{ 'Name' => 'rx.limit', 'Label' => "RX Limit" },
					{ 'Name' => 'rx.rate', 'Label' => "RX Rate" }
				],
				'YIdentifiers' => [
					{ 'Name' => sprintf('configmanager.classpools.%s',$trafficClassID), 'Label' => "Pool Count" },
				]
			});
		}
	}

	# Pool distribution
	my @datasources = ();
	my @xidentifiers = ();
	foreach my $trafficClassID (@trafficClasses) {
		my $trafficClass = getTrafficClass($trafficClassID);

		push(@datasources,sprintf('counter=configmanager.classpools.%s',$trafficClassID));
		push(@xidentifiers,{
				'Name' => sprintf('configmanager.classpools.%s',$trafficClassID),
				'Label' => $trafficClass->{'Name'}
		});
	}
	push(@rightGraphs,{
		'Type' => 'pie',
		'Title' => "Pool Distribution",
		'Datasources' => \@datasources,
		'XIdentifiers' => \@xidentifiers
	});


	# Loop while we have graphs to output
	my $graphCounter = 0;
	while (@leftGraphs || @rightGraphs) {
		# Layout Begin
		$content .= <<EOF;
			<div class="row">
EOF
		# LHS - Begin
		$content .= <<EOF;
				<div class="col-xs-8">
EOF
		# Loop with 2 sets of normal graphs per row
		for (my $row = 0; $row < 2; $row++) {
			# LHS - Begin Row
			$content .= <<EOF;
					<div class="row">
						<div class="col-xs-6">
EOF
			# Graph 1
			if (defined(my $graph = shift(@leftGraphs))) {
				# Assign this graph a tag
				$graph->{'Tag'} = "tag".$graphCounter++;

				$content .= <<EOF;
							<h4 style="color:#8f8f8f;">$graph->{'Title'}</h4>
							<div id="$graph->{'Tag'}" class="flotCanvas"
									style="width: 520px; height: 150px; border: 1px dashed black">
							</div>
EOF
				push(@graphs,$graph);
			}
			# LHS - Spacer
			$content .= <<EOF;
						</div>
						<div class="col-xs-6">
EOF
			# Graph 2
			if (defined(my $graph = shift(@leftGraphs))) {
				# Assign this graph a tag
				$graph->{'Tag'} = "tag".$graphCounter++;

				$content .= <<EOF;
							<h4 style="color:#8f8f8f;">$graph->{'Title'}</h4>
							<div id="$graph->{'Tag'}" class="flotCanvas"
									style="width: 520px; height: 150px; border: 1px dashed black">
							</div>
EOF
				push(@graphs,$graph);
			}
			# LHS - End Row
			$content .= <<EOF;
						</div>
					</div>
EOF
		}
		# LHS - End
		$content .= <<EOF;
			</div>
EOF

		# RHS - Begin Row
		$content .= <<EOF;
				<div class="col-xs-4">
EOF
		# Graph
		if (defined(my $graph = shift(@rightGraphs))) {
			# Assign this graph a tag
			$graph->{'Tag'} = "tag".$graphCounter++;

			$content .= <<EOF;
					<h4 style="color:#8f8f8f;">$graph->{'Title'}</h4>
					<div id="$graph->{'Tag'}" class="flotCanvas"
							style="width: 520px; height: 340px; border: 1px dashed black">
					</div>
EOF
			push(@graphs,$graph);
		}
		# RHS - End Row
		$content .= <<EOF;
				</div>
EOF

		# Layout End
		$content .= <<EOF;
			</div>
EOF
	}


	# Files loaded at end of HTML document
	my @javascripts = (
		'/static/flot/jquery.flot.min.js',
		'/static/flot/jquery.flot.time.min.js',
		'/static/flot/jquery.flot.pie.min.js',
		'/static/js/flot-functions.js',
		'/static/awit-flot-toolkit/js/jquery.flot.awitds.js'
	);
	my @stylesheets = (
		'/static/awit-flot-toolkit/css/awit-flot-toolkit.css'
	);

	my $javascript = "";

	foreach my $graph (@graphs) {
		my $encodedCanvasName = encode_entities($graph->{'Tag'});

		# Items we going to need...
		my @datasources = ();
		my $axesIdentifiers = { 'X' => [ ], 'Y' => [ ] };
		my @axesStrList;
		# Loop with and build the JS for our datasources
		foreach my $datasource (@{$graph->{'Datasources'}}) {
			my $encodedDatasource = encode_entities($datasource);

			push(@datasources,"{ 'function': 'subscribe', args: ['$encodedCanvasName','$encodedDatasource'] }");
		}
		# Loop with axes and build our axes structure
		foreach my $axis (keys %{$axesIdentifiers}) {
			foreach my $identifier (@{$graph->{"${axis}Identifiers"}}) {
				my $encodedName = encode_entities($identifier->{'Name'});
				my $encodedLabel = encode_entities($identifier->{'Label'});
				push(@{$axesIdentifiers->{$axis}},"'$encodedName': { label: '$encodedLabel' }");
			}
			push(@axesStrList,
					sprintf("%saxis: { '%s': { %s } }",lc($axis),$encodedCanvasName,join(',',@{$axesIdentifiers->{$axis}}))
			);
		}
		# Build final JS
		my $datasourceStr = join(',',@datasources);
		my $axesStr = join(',',@axesStrList);

		$javascript .=<<EOF;
			awit_flot_draw_$graph->{'Type'}({
				id: '$encodedCanvasName',
				awitds: {
					sources: [
						{
							type: 'websocket',
							uri: 'ws://ots-devel:8088/statistics/graphdata',
							shared: true,
							// Websocket specific
							onconnect: [
								$datasourceStr
							]
						}
					],
					$axesStr
				}
			});
EOF
	}

END:

	return (HTTP_OK,$content,{
			'javascripts' => \@javascripts,
			'javascript' => $javascript,
			'stylesheets' => \@stylesheets
	});
}



# Return data in json format
#
# Supported URLs:
#
#	pool=<tag>:<interface-group-id>:<pool-name>
#
#	class=<tag>:<interface-group-id>:<class-id>,...
#
#	interface-group=<tag>:<interface-group>,...
#
#	counter=<tag>:<counter>,...
#
#	max=<max number of entries to return, default 100>
#
#	key=<data key to return>
sub jsondata
{
	my ($kernel,$system,$client_session_id,$request) = @_;


	# Parse GET data
	my $queryParams = parseURIQuery($request);

	my $rawData = { };

	# Process pools
	if (defined($queryParams->{'pool'})) {
		# Simple de-dupication
		my %poolSpecs;
		foreach my $poolSpec (@{$queryParams->{'pool'}->{'values'}}) {
			$poolSpecs{$poolSpec} = 1;
		}

		# Then loop through the unique keys
		foreach my $poolSpec (keys %poolSpecs) {
			# Check we have a tag, interface group ID and pool name
			my ($tag,$rawInterfaceGroupID,$rawPoolName) = split(/:/,$poolSpec);
			if (!defined($tag)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Invalid format for pool specification '%s'",
						$poolSpec
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Invalid format for pool specification '$poolSpec'"},
						{ 'type' => 'json' });
			}
			if (!defined($rawInterfaceGroupID)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has an invalid interface group ID '%s'",
						$tag,
						$poolSpec
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has invalid interface group ID '$rawPoolName'"},
						{ 'type' => 'json' });
			}
			# Check if we can grab the interface group
			my $interfaceGroup = getInterfaceGroup($rawInterfaceGroupID);
			if (!defined($interfaceGroup)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has an invalid interface group ID '%s'",
						$tag,
						$rawInterfaceGroupID
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has an invalid interface group ID ".
						"'$rawInterfaceGroupID'"},
						{ 'type' => 'json' });
			}

			if (!defined($rawPoolName)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has an invalid pool name '%s'",
						$tag,
						$poolSpec
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has an invalid pool name '$rawPoolName'"},
						{ 'type' => 'json' });
			}
			# Grab pool
			my $pool = getPoolByName($rawInterfaceGroupID,$rawPoolName);
			if (!defined($pool)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has an invalid pool name '%s'",
						$tag,
						$rawPoolName
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has an invalid pool name '$rawPoolName'"},
						{ 'type' => 'json' });
			}

			# Grab SID
			my $sid = opentrafficshaper::plugins::statistics::getSIDFromPID($pool->{'ID'});
			if (!defined($sid)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' stats data cannot be found for pool ".
						"'%s'",
						$tag,
						$rawPoolName
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' stats data cannot be found for pool '$rawPoolName'"},
						{ 'type' => 'json' });
			}

			# Pull in stats data
			my $statsData = opentrafficshaper::plugins::statistics::getStatsBySID($sid);

			# Loop with timestamps
			foreach my $timestamp (sort keys %{$statsData}) {
				# Grab the stat
				my $tstat = $statsData->{$timestamp};
				# Loop with its keys
				foreach my $item (keys $tstat) {
					# Add the keys to the data to return
					push(@{$rawData->{$tag}->{$item}->{'data'}},[
							$timestamp,
							$tstat->{$item}
					]);
				}
			}
		}
	}

	# Process classes
	if (defined($queryParams->{'class'})) {
		# Simple de-dupication
		my %trafficClassIDSpecs;
		foreach my $rawClassID (@{$queryParams->{'class'}->{'values'}}) {
			$trafficClassIDSpecs{$rawClassID} = 1;
		}
		# Then loop through the unique keys
		foreach my $trafficClassIDSpec (keys %trafficClassIDSpecs) {
			# Check we have a tag, interface group ID and class
			my ($tag,$rawInterfaceGroupID,$rawClassID) = split(/:/,$trafficClassIDSpec);
			if (!defined($tag)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Invalid format for class ID specification '%s'",
						$trafficClassIDSpec
				);
				return (HTTP_OK,{
							'status' => 'fail',
							'message' => "Invalid format for class ID specification '$trafficClassIDSpec'"
						},
						{ 'type' => 'json' }
				);
			}
			if (!defined($rawInterfaceGroupID)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has an invalid interface group ID '%s'",
						$tag,
						$trafficClassIDSpec
				);
				return (HTTP_OK,{
						'status' => 'fail',
						'message' => "Tag '$tag' has an invalid interface group ID '$trafficClassIDSpec'"
					},
					{ 'type' => 'json' }
				);
			}
			if (!defined($rawClassID)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has an invalid class ID '%s'",
						$tag,
						$trafficClassIDSpec
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has an invalid class ID '$trafficClassIDSpec'"},
						{ 'type' => 'json' });
			}

			# Get more sane values...
			my $interfaceGroup = getInterfaceGroup($rawInterfaceGroupID);
			if (!defined($interfaceGroup)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has a non-existent interface group ID ".
						"'%s'",
						$tag,
						$rawInterfaceGroupID
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has a non-existent interface group ID ".
						"'$rawInterfaceGroupID'"},
						{ 'type' => 'json' });
			}
			my $trafficClassID = isTrafficClassIDValid($rawClassID);
			if (!defined($trafficClassID)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has a non-existent class ID '%s'",
						$tag,
						$rawClassID
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has a non-existent class ID '$rawClassID'"},
						{ 'type' => 'json' });
			}

			# Grab data for each direction associated with a class ID on an inteface group
			foreach my $direction ('tx','rx') {
				# Grab stats ID
				my $sid = opentrafficshaper::plugins::statistics::getSIDFromCID($interfaceGroup->{"${direction}Interface"},
						$trafficClassID);
				if (!defined($sid)) {
					$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' stats data cannot be found for ".
							"class ID '%s'",
							$tag,
							$trafficClassID
					);
					return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' stats data cannot be found for class ID "
							."'$trafficClassID'"},
							{ 'type' => 'json' });
				}
				# Pull in stats data, override direction used
				my $statsData = opentrafficshaper::plugins::statistics::getStatsBySID($sid,{
						'direction' => lc($direction)
				});

				# Loop with timestamps
				foreach my $timestamp (sort keys %{$statsData}) {
					# Grab the stat
					my $tstat = $statsData->{$timestamp};
					# Loop with its keys
					foreach my $item (keys $tstat) {
						# Add the keys to the data to return
						push(@{$rawData->{$tag}->{$item}->{'data'}},[
								$timestamp,
								$tstat->{$item}
						]);
					}
				}
			}
		}
	}

	# Process interface groups
	if (defined($queryParams->{'interface-group'})) {
		# Simple de-dupication
		my %interfaceGroupIDSpecs;
		foreach my $rawInterfaceGroupID (@{$queryParams->{'interface-group'}->{'values'}}) {
			$interfaceGroupIDSpecs{$rawInterfaceGroupID} = 1;
		}
		# Then loop through the unique keys
		foreach my $interfaceGroupIDSpec (keys %interfaceGroupIDSpecs) {
			# Check we have a tag, interface group ID and class
			my ($tag,$rawInterfaceGroupID) = split(/:/,$interfaceGroupIDSpec);
			if (!defined($tag)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Invalid format for interface group ".
						"specification '%s'",
						$interfaceGroupIDSpec
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Invalid format for interface group specification ".
						"'$interfaceGroupIDSpec'"},
						{ 'type' => 'json' });
			}
			if (!defined($rawInterfaceGroupID)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has an invalid interface group ID '%s'",
						$tag,
						$interfaceGroupIDSpec
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has an invalid interface group ID ".
						"'$interfaceGroupIDSpec'"},
						{ 'type' => 'json' });
			}

			my $interfaceGroupID = getInterfaceGroup($rawInterfaceGroupID);
			if (!defined($interfaceGroupID)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has a non-existent interface group ID ".
						"'%s'",
						$tag,
						$rawInterfaceGroupID
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has a non-existent interface group ID ".
						"'$rawInterfaceGroupID'"},
						{ 'type' => 'json' });
			}

			# Loop with both directions
			foreach my $direction ('Tx','Rx') {
				# Grab stats ID
				my $sid = opentrafficshaper::plugins::statistics::getSIDFromCID($interfaceGroupID->{"${direction}Interface"},0);
				if (!defined($sid)) {
					$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' stats data cannot be found for ".
							"interface group ID '%s'",
							$tag,
							$rawInterfaceGroupID
					);
					return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' stats data cannot be found for interface group ".
							"ID '$rawInterfaceGroupID'"},
							{ 'type' => 'json' });
				}

				# Pull in stats data, override direction used
				my $statsData = opentrafficshaper::plugins::statistics::getStatsBySID($sid,{
						'direction' => lc($direction)
				});

				# Loop with timestamps
				foreach my $timestamp (sort keys %{$statsData}) {
					# Grab the stat
					my $tstat = $statsData->{$timestamp};
					# Loop with its keys
					foreach my $item (keys $tstat) {
						# Add the keys to the data to return
						push(@{$rawData->{$tag}->{$item}->{'data'}},[
								$timestamp,
								$tstat->{$item}
						]);
					}
				}
			}
		}
	}

	# If we need to return a counter, lets see what there is we can return...
	if (defined($queryParams->{'counter'})) {
		# Lets get unique counters as keys
		my %counterSpecs;
		foreach my $rawCounterSpec (@{$queryParams->{'counter'}->{'values'}}) {
			$counterSpecs{$rawCounterSpec} = 1;
		}
		# Then loop through the unique keys
		foreach my $counterSpec (keys %counterSpecs) {
			# Check we have a tag and counter
			my ($tag,$rawCounter) = split(/:/,$counterSpec);
			if (!defined($tag)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Invalid format for counter specification '%s'",
						$counterSpec
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Invalid format for counter specification '$counterSpec'"},
						{ 'type' => 'json' });
			}
			if (!defined($rawCounter)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has an invalid interface group ID '%s'",
						$tag,
						$counterSpec
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has an invalid interface group ID ".
						"'$counterSpec'"},
						{ 'type' => 'json' });
			}
			# Grab the SID
			my $sid = opentrafficshaper::plugins::statistics::getSIDFromCounter($rawCounter);
			if (!defined($sid)) {
				$system->{'logger'}->log(LOG_INFO,"[WEBSERVER/PAGES/STATISTICS] Tag '%s' has a non-existent counter '%s'",
						$tag,
						$counterSpec
				);
				return (HTTP_OK,{'status' => 'fail', 'message' => "Tag '$tag' has a non-existent counter ".
						"'$counterSpec'"},
						{ 'type' => 'json' });
			}
			# Pull in stats data
			my $statsData = opentrafficshaper::plugins::statistics::getStatsBasicBySID($sid,{ 'Name' => $rawCounter });

			# Loop with timestamps
			foreach my $timestamp (sort keys %{$statsData}) {
				# Grab the stat
				my $tstat = $statsData->{$timestamp};
				# Loop with its keys
				foreach my $item (keys $tstat) {
					# Add the keys to the data to return
					push(@{$rawData->{$tag}->{$item}->{'data'}},[
							$timestamp,
							$tstat->{$item}
					]);
				}
			}
		}
	}

	return (HTTP_OK,{'status' => 'success', 'data' => $rawData},{ 'type' => 'json' });
}



# Return javascript for the graph
sub _getJavascript
{
	my ($canvasName,$dataPath) = @_;


	# Encode canvasname
	my $encodedCanvasName = encode_entities($canvasName);
	# Build our data path using the URI module to make sure its nice and clean
	my $dataPathURI = URI->new($dataPath);
	my $dataPathStr = $dataPathURI->as_string();

	my $javascript =<<EOF;
	awit_flot_draw_graph({
		id: '$encodedCanvasName',

		awitds: {
			sources: [
				{
					type: 'ajax',
					url: '$dataPathStr'
				}
			],
			xaxis: {
				'tag1': {
					'tx.cir': {
						label: 'TX Cir'
					},
					'tx.limit': {
						label: 'TX Limit'
					},
					'tx.rate': {
						label: 'TX Rate'
					},
					'rx.cir': {
						label: 'RX Cir'
					},
					'rx.limit': {
						label: 'RX Limit'
					},
					'rx.rate': {
						label: 'RX Rate'
					}
				}
			}
		}
	});
EOF
#	my $javascript =<<EOF;
#	awit_flot_draw_graph({
#		url: '$dataPathStr',
#		yaxes: [
#			{
#				labels: ['Total Pools'],
#				position: 'right',
#				tickDecimals: 0,
#				min: 0
#			}
#		]
#	});
#EOF

	return $javascript;
}



1;
# vim: ts=4
