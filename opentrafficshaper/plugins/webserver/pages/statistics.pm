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
	isNumber
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

# Graphs to display on pools stat page
sub POOL_GRAPHS {
	{
		3600 => 'Last Hour',
		86400 => 'Last 24 Hours',
		604800 => 'Last 7 Days',
		2419200 => 'Last Month'
	}
};


# Graphs by pool
sub byPool
{
	my ($kernel,$system,$client_session_id,$request) = @_;


	# Header
	my $content = "";

	# Check request
	if ($request->method ne "GET") {
		$content .=<<EOF;
			<p class="info text-center">Invalid Method</p>
EOF
		goto END;
	}

	# Parse GET data
	my $queryParams = parseURIQuery($request);
	# We need our PID
	if (!defined($queryParams->{'pool'})) {
		$content .=<<EOF;
			<p class="info text-center">No "pool" in Query String</p>
EOF
			goto END;
	}

	# Check we have an interface group ID and pool name
	my ($interfaceGroupID,$poolName) = split(/:/,$queryParams->{'pool'}->{'value'});
	if (!defined($interfaceGroupID) || !defined($poolName)) {
		$content .=<<EOF;
			<p class="info text-center">Format of "pool" option is invalid, use InterfaceGroupID:PoolName</p>
EOF
			goto END;
	}

	# Check if we get some data back when pulling in the pool from the backend
	my $pool;
	if (!defined($pool = getPoolByName($interfaceGroupID,$poolName))) {
		$content .=<<EOF;
			<p class="info text-center">Pool Not Found</p>
EOF
			goto END;
	}

	# Header for the page
	$content .= <<EOF;
		<legend>
			<a href="/limits/pool-list"><span class="glyphicon glyphicon-circle-arrow-left"></span></a>
			Pool Stats View
		</legend>
EOF

	# Menu setup
	my $menu = [
		{
			'name' => 'Graphs',
			'items' => [
				{
					'name' => 'Live',
					'link' => sprintf("by-pool?pool=%s",uri_escape("$interfaceGroupID:$poolName"))
				},
				{
					'name' => 'Historical',
					'link' => sprintf("by-pool?pool=%s&static=1",uri_escape("$interfaceGroupID:$poolName"))
				}
			]
		}
	];


	my $name = (defined($pool->{'FriendlyName'}) && $pool->{'FriendlyName'} ne "") ? $pool->{'FriendlyName'} :
			$pool->{'Name'};
	my $nameEncoded = encode_entities($name);


	# Build content
	$content .= <<EOF;
EOF

	# Graphs to display
	my @graphs = ();

	# Check if we doing a static display or not
	if (defined($queryParams->{'static'}) && $queryParams->{'static'}) {
		# Loop with periods to display on this page
		foreach my $period (sort { $a <=> $b } keys %{POOL_GRAPHS()}) {
			my $canvasName = "flotCanvas$period";
			my $graphName = POOL_GRAPHS()->{$period};

			my $now = time();
			my $startTimestamp = $now - $period;

			$content .= <<EOF;
				<h4 style="color: #8F8F8F;">Statistics: $nameEncoded - $graphName</h4>
				<div id="$canvasName" class="flotCanvas poolCanvas" style="width: 800px; height: 240px" ></div>
EOF

			# Static graphs
			push(@graphs,{
				'Type' => 'graph',
				'Tag' => $canvasName,
				'Title' => sprintf("Pool: %s",$pool->{'Name'}),
				'Datasources' => [
					{
						'Type' => 'ajax',
						'Subscriptions' => [
							{
								'Type' => 'pool',
								'Data' => sprintf('%s:%s',$pool->{'InterfaceGroupID'},$pool->{'Name'}),
								'StartTimestamp' => $startTimestamp,
								'EndTimestamp' => $now
							}
						]
					}
				],
				'XIdentifiers' => [
					{ 'Name' => 'tx.cir', 'Label' => "TX Cir", 'Timespan' => $period },
					{ 'Name' => 'tx.limit', 'Label' => "TX Limit", 'Timespan' => $period },
					{ 'Name' => 'tx.rate', 'Label' => "TX Rate", 'Timespan' => $period },
					{ 'Name' => 'rx.cir', 'Label' => "RX Cir", 'Timespan' => $period },
					{ 'Name' => 'rx.limit', 'Label' => "RX Limit", 'Timespan' => $period },
					{ 'Name' => 'rx.rate', 'Label' => "RX Rate", 'Timespan' => $period }
				]
			});
		}

	# Display live graph
	} else {
		my $canvasName = "flotCanvas";

		$content .= <<EOF;
			<h4 style="color: #8F8F8F;">Live Statistics: $nameEncoded</h4>
			<div id="$canvasName" class="flotCanvas poolCanvas" style="width: 1000px; height: 400px" />
EOF

		# Live graph
		push(@graphs,{
			'Type' => 'graph',
			'Tag' => $canvasName,
			'Title' => sprintf("Pool: %s",$pool->{'Name'}),
			'Datasources' => [
				{
					'Type' => 'websocket',
					'Subscriptions' => [
						sprintf('pool=%s:%s',$pool->{'InterfaceGroupID'},$pool->{'Name'})
					]
				}
			],
			'XIdentifiers' => [
				{ 'Name' => 'tx.cir', 'Label' => "TX Cir", 'Timespan' => 900 },
				{ 'Name' => 'tx.limit', 'Label' => "TX Limit", 'Timespan' => 900 },
				{ 'Name' => 'tx.rate', 'Label' => "TX Rate", 'Timespan' => 900 },
				{ 'Name' => 'rx.cir', 'Label' => "RX Cir", 'Timespan' => 900 },
				{ 'Name' => 'rx.limit', 'Label' => "RX Limit", 'Timespan' => 900 },
				{ 'Name' => 'rx.rate', 'Label' => "RX Rate", 'Timespan' => 900 }
			]
		});
	}

	# Build graphs
	my $javascript = _buildGraphJavascript(\@graphs);

	# Files loaded at end of HTML document
	my @javascripts = (
		'/static/flot/jquery.flot.min.js',
		'/static/flot/jquery.flot.time.min.js',
		'/static/flot/jquery.flot.pie.min.js',
		'/static/flot/jquery.flot.resize.min.js',
		'/static/js/flot-functions.js',
		'/static/awit-flot-toolkit/js/jquery.flot.awitds.js',
		'/static/awit-flot-toolkit/js/resize.js'
	);
	my @stylesheets = (
		'/static/awit-flot-toolkit/css/awit-flot-toolkit.css'
	);

END:
	return (HTTP_OK,$content,{ 'menu' => $menu, 'javascripts' => \@javascripts, 'javascript' => $javascript });
}



# Graphs by class
sub byClass
{
	my ($kernel,$system,$client_session_id,$request) = @_;


	# Header
	my $content = "";

	# Check request
	if ($request->method ne "GET") {
		$content .=<<EOF;
			<p class="info text-center">Invalid Method</p>
EOF
		goto END;
	}

	# Parse GET data
	my $queryParams = parseURIQuery($request);
	# We need our class definition
	if (!defined($queryParams->{'class'})) {
		$content .=<<EOF;
			<p class="info text-center">No "class" in Query String</p>
EOF
			goto END;
	}

	# Check we have an interface group ID and traffic class id
	my ($interfaceGroupID,$trafficClassID) = split(/:/,$queryParams->{'class'}->{'value'});
	if (!defined($interfaceGroupID) || !defined($trafficClassID)) {
		$content .=<<EOF;
			<p class="info text-center">Format of "class" option is invalid, use InterfaceGroupID:ClassID</p>
EOF
			goto END;
	}

	# Check if we get some data back when pulling in the interface group from the backend
	my $interfaceGroup;
	if (!defined($interfaceGroup = getInterfaceGroup($interfaceGroupID))) {
		$content .=<<EOF;
			<p class="info text-center">Interface Group Not Found</p>
EOF
			goto END;
	}

	# Check if we get some data back when pulling in the traffic class from the backend
	my $trafficClass;
	if (!defined($trafficClass = getTrafficClass($trafficClassID))) {
		$content .=<<EOF;
			<p class="info text-center">Traffic Class Not Found</p>
EOF
			goto END;
	}


	# Header for the page
	$content .= <<EOF;
		<legend>
			<a href="/limits/pool-list"><span class="glyphicon glyphicon-circle-arrow-left"></span></a>
			Class Stats View
		</legend>
EOF

	# Menu setup
	my $menu = [
		{
			'name' => 'Graphs',
			'items' => [
				{
					'name' => 'Live',
					'link' => sprintf("by-class?class=%s",uri_escape("$interfaceGroupID:$trafficClassID"))
				},
				{
					'name' => 'Historical',
					'link' => sprintf("by-class?class=%s&static=1",uri_escape("$interfaceGroupID:$trafficClassID"))
				}
			]
		}
	];


	my $nameEncoded = encode_entities($trafficClass->{'Name'});


	# Build content
	$content .= <<EOF;
EOF

	# Graphs to display
	my @graphs = ();

	# Check if we doing a static display or not
	if (defined($queryParams->{'static'}) && $queryParams->{'static'}) {
		# Loop with periods to display on this page
		foreach my $period (sort { $a <=> $b } keys %{POOL_GRAPHS()}) {
			my $canvasName = "flotCanvas$period";
			my $graphName = POOL_GRAPHS()->{$period};

			my $now = time();
			my $startTimestamp = $now - $period;

			$content .= <<EOF;
				<h4 style="color: #8F8F8F;">Class Statistics: $nameEncoded - $graphName</h4>
				<div id="$canvasName" class="flotCanvas poolCanvas" style="width: 800px; height: 240px" ></div>
EOF

			# Static graphs
			push(@graphs,{
				'Type' => 'graph',
				'Tag' => $canvasName,
				'Title' => sprintf("Class: %s",$trafficClass->{'Name'}),
				'Datasources' => [
					{
						'Type' => 'ajax',
						'Subscriptions' => [
							{
								'Type' => 'class',
								'Data' => sprintf('%s:%s',$interfaceGroupID,$trafficClassID),
								'StartTimestamp' => $startTimestamp,
								'EndTimestamp' => $now
							}
						]
					}
				],
				'XIdentifiers' => [
					{ 'Name' => 'tx.cir', 'Label' => "TX Cir", 'Timespan' => $period },
					{ 'Name' => 'tx.limit', 'Label' => "TX Limit", 'Timespan' => $period },
					{ 'Name' => 'tx.rate', 'Label' => "TX Rate", 'Timespan' => $period },
					{ 'Name' => 'rx.cir', 'Label' => "RX Cir", 'Timespan' => $period },
					{ 'Name' => 'rx.limit', 'Label' => "RX Limit", 'Timespan' => $period },
					{ 'Name' => 'rx.rate', 'Label' => "RX Rate", 'Timespan' => $period }
				]
			});
		}

	# Display live graph
	} else {
		my $canvasName = "flotCanvas";

		$content .= <<EOF;
			<h4 style="color: #8F8F8F;">Live Statistics: $nameEncoded</h4>
			<div id="$canvasName" class="flotCanvas poolCanvas" style="width: 1000px; height: 400px" />
EOF

		# Live graph
		push(@graphs,{
			'Type' => 'graph',
			'Tag' => $canvasName,
			'Title' => sprintf("Class: %s",$trafficClass->{'Name'}),
			'Datasources' => [
				{
					'Type' => 'websocket',
					'Subscriptions' => [
						sprintf('class=%s:%s',$interfaceGroupID,$trafficClassID)
					]
				}
			],
			'XIdentifiers' => [
				{ 'Name' => 'tx.cir', 'Label' => "TX Cir", 'Timespan' => 900 },
				{ 'Name' => 'tx.limit', 'Label' => "TX Limit", 'Timespan' => 900 },
				{ 'Name' => 'tx.rate', 'Label' => "TX Rate", 'Timespan' => 900 },
				{ 'Name' => 'rx.cir', 'Label' => "RX Cir", 'Timespan' => 900 },
				{ 'Name' => 'rx.limit', 'Label' => "RX Limit", 'Timespan' => 900 },
				{ 'Name' => 'rx.rate', 'Label' => "RX Rate", 'Timespan' => 900 }
			]
		});
	}

	# Build graphs
	my $javascript = _buildGraphJavascript(\@graphs);

	# Files loaded at end of HTML document
	my @javascripts = (
		'/static/flot/jquery.flot.min.js',
		'/static/flot/jquery.flot.time.min.js',
		'/static/flot/jquery.flot.pie.min.js',
		'/static/flot/jquery.flot.resize.min.js',
		'/static/js/flot-functions.js',
		'/static/awit-flot-toolkit/js/jquery.flot.awitds.js',
		'/static/awit-flot-toolkit/js/resize.js'
	);
	my @stylesheets = (
		'/static/awit-flot-toolkit/css/awit-flot-toolkit.css'
	);

END:
	return (HTTP_OK,$content,{ 'menu' => $menu, 'javascripts' => \@javascripts, 'javascript' => $javascript });
}



# Dashboard display
sub dashboard
{
	my ($kernel,$system,$client_session_id,$request) = @_;


	# Header
	my $content = <<EOF;
		<legend>
			Dashboard View
		</legend>
EOF

	# Build list of graphs for the left hand side
	my @interfaceGroups = sort(getInterfaceGroups());
	my @trafficClasses = sort(getAllTrafficClasses());

	my $timespan = 900;

	my @graphs;
	my $graphCounter = 0;

	foreach my $interfaceGroupID (@interfaceGroups) {
		my $interfaceGroup = getInterfaceGroup($interfaceGroupID);

		push(@graphs,{
			'.InterfaceGroup' => $interfaceGroup->{'ID'},
			'Tag' => sprintf('tag%s',$graphCounter++),
			'Type' => 'graph',
			'Title' => sprintf("%s: Main",$interfaceGroup->{'Name'}),
			'Datasources' => [
				{
					'Type' => 'websocket',
					'Subscriptions' => [
						sprintf('interface-group=%s',$interfaceGroupID),
					]
				}
			],
			'XIdentifiers' => [
				{ 'Name' => 'tx.rate', 'Label' => "TX Rate", 'Timespan' => $timespan },
				{ 'Name' => 'rx.rate', 'Label' => "RX Rate", 'Timespan' => $timespan }
			]
		});
	}


	foreach my $graph (@graphs) {
		my $interfaceGroupEscaped = uri_escape($graph->{'.InterfaceGroup'});

		$content .= <<EOF;
			<div class="row">
				<h4 class="text-center" style="color:#8f8f8f;">$graph->{'Title'}</h4>
				<a href="/statistics/igdashboard?interface-group=$interfaceGroupEscaped">
					<div id="$graph->{'Tag'}" class="flotCanvas poolCanvas"
							style="width: 1000px; height: 250px; margin-left: auto; margin-right: auto;">
					</div>
				</a>
			</div>
EOF
	}

	# Build graphs
	my $javascript = _buildGraphJavascript(\@graphs);


	# Files loaded at end of HTML document
	my @javascripts = (
		'/static/flot/jquery.flot.min.js',
		'/static/flot/jquery.flot.time.min.js',
		'/static/flot/jquery.flot.pie.min.js',
		'/static/flot/jquery.flot.resize.min.js',
		'/static/js/flot-functions.js',
		'/static/awit-flot-toolkit/js/jquery.flot.awitds.js',
		'/static/awit-flot-toolkit/js/resize.js'
	);
	my @stylesheets = (
		'/static/awit-flot-toolkit/css/awit-flot-toolkit.css'
	);

	return (HTTP_OK,$content,{
			'javascripts' => \@javascripts,
			'javascript' => $javascript,
			'stylesheets' => \@stylesheets
	});
}





# Dashboard display for interface groups
sub igdashboard
{
	my ($kernel,$system,$client_session_id,$request) = @_;


	# Header
	my $content = <<EOF;
		<legend>
			<a href="/statistics/dashboard"><span class="glyphicon glyphicon-circle-arrow-left"></span></a>
			Interface Dashboard View
		</legend>
EOF

	# Get query params
	my $queryParams = parseURIQuery($request);

	# We need our PID
	if (!defined($queryParams->{'interface-group'})) {
		$content .=<<EOF;
			<p class="info text-center">No "interface-group" in Query String</p>
EOF
		return (HTTP_TEMPORARY_REDIRECT,"/statistics");
	}

	my $interfaceGroup = getInterfaceGroup($queryParams->{'interface-group'}->{'value'});
	if (!defined($interfaceGroup)) {
		$content .=<<EOF;
			<p class="info text-center">Invalid "interface-group" in Query String</p>
EOF
		return (HTTP_TEMPORARY_REDIRECT,"/statistics");
	}

	# Left and right graphs are added to the main graph list
	my @graphs = ();
	# Left and right graphs
	my @leftGraphs = ();
	my @rightGraphs = ();

	# Build list of graphs for the left hand side
	my @trafficClasses = sort(getAllTrafficClasses());

	my $timespan = 900;

	foreach my $trafficClassID (@trafficClasses) {
		my $trafficClass = getTrafficClass($trafficClassID);

		push(@leftGraphs,{
			'Type' => 'graph',
			'Title' => sprintf("%s: %s",$interfaceGroup->{'Name'},$trafficClass->{'Name'}),
			'.URIData' => uri_escape(sprintf('%s:%s',$interfaceGroup->{'ID'},$trafficClassID)),
			'Datasources' => [
				{
					'Type' => 'websocket',
					'Subscriptions' => [
						sprintf('class=%s:%s',$interfaceGroup->{'ID'},$trafficClassID),
						sprintf('counter=configmanager.classpoolmembers.%s',$trafficClassID)
					]
				}
			],
			'XIdentifiers' => [
				{ 'Name' => 'tx.cir', 'Label' => "TX Cir", 'Timespan' => $timespan },
				{ 'Name' => 'tx.limit', 'Label' => "TX Limit", 'Timespan' => $timespan },
				{ 'Name' => 'tx.rate', 'Label' => "TX Rate", 'Timespan' => $timespan },
				{ 'Name' => 'rx.cir', 'Label' => "RX Cir", 'Timespan' => $timespan },
				{ 'Name' => 'rx.limit', 'Label' => "RX Limit", 'Timespan' => $timespan },
				{ 'Name' => 'rx.rate', 'Label' => "RX Rate", 'Timespan' => $timespan }
			],
			'YIdentifiers' => [
				{
					'Name' => sprintf('configmanager.classpoolmembers.%s',$trafficClassID),
					'Label' => "Pool Count",
					'Timespan' => $timespan
				},
			]
		});
	}

	# Pool distribution
	my @dataSubscriptions = ();
	my @xidentifiers = ();
	foreach my $trafficClassID (@trafficClasses) {
		my $trafficClass = getTrafficClass($trafficClassID);

		push(@dataSubscriptions,sprintf('counter=configmanager.classpools.%s',$trafficClassID));
		push(@xidentifiers,{
				'Name' => sprintf('configmanager.classpools.%s',$trafficClassID),
				'Label' => $trafficClass->{'Name'}
		});
	}
	push(@rightGraphs,{
		'Type' => 'pie',
		'Title' => "Pool Distribution",
		'Datasources' => [
			{
				'Type' => 'websocket',
				'Subscriptions' => \@dataSubscriptions
			}
		],
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
				<div class="col-md-8">
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
				my $uriData = $graph->{'.URIData'};

				# Assign this graph a tag
				$graph->{'Tag'} = "tag".$graphCounter++;

				$content .= <<EOF;
							<h4 style="color:#8f8f8f;">$graph->{'Title'}</h4>
							<a href="/statistics/by-class?class=$uriData">
								<div id="$graph->{'Tag'}" class="flotCanvas dashboardCanvas"
										style="width: 600px; height: 250px"></div>
							</a>
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
				my $uriData = $graph->{'.URIData'};

				# Assign this graph a tag
				$graph->{'Tag'} = "tag".$graphCounter++;

				$content .= <<EOF;
							<h4 style="color:#8f8f8f;">$graph->{'Title'}</h4>
							<a href="/statistics/by-class?class=$uriData">
								<div id="$graph->{'Tag'}" class="flotCanvas dashboardCanvas"
										style="width: 600px; height: 250px"></div>
							</a>
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
				<div class="col-md-4">
EOF
		# Graph
		if (defined(my $graph = shift(@rightGraphs))) {
			# Assign this graph a tag
			$graph->{'Tag'} = "tag".$graphCounter++;

			$content .= <<EOF;
					<h4 style="color:#8f8f8f;">$graph->{'Title'}</h4>
					<div id="$graph->{'Tag'}" class="flotCanvas dashboardCanvas" style="width: 600px; height: 340px"></div>
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


	# Build graphs
	my $javascript = _buildGraphJavascript(\@graphs);


	# Files loaded at end of HTML document
	my @javascripts = (
		'/static/flot/jquery.flot.min.js',
		'/static/flot/jquery.flot.time.min.js',
		'/static/flot/jquery.flot.pie.min.js',
		'/static/flot/jquery.flot.resize.min.js',
		'/static/js/flot-functions.js',
		'/static/awit-flot-toolkit/js/jquery.flot.awitds.js',
		'/static/awit-flot-toolkit/js/resize.js'
	);
	my @stylesheets = (
		'/static/awit-flot-toolkit/css/awit-flot-toolkit.css'
	);

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

	# Check for some things that apply to all types of data
	my $startTimestamp;
	my $endTimestamp;
	if (defined($queryParams->{'start'})) {
		$startTimestamp = isNumber($queryParams->{'start'}->{'value'});
	}
	if (defined($queryParams->{'end'})) {
		$endTimestamp = isNumber($queryParams->{'end'}->{'value'});
	}

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
			my $statsData = opentrafficshaper::plugins::statistics::getStatsBySID($sid,undef,$startTimestamp,$endTimestamp);
			# Loop with timestamps
			foreach my $timestamp (sort keys %{$statsData}) {
				# Grab the stat
				my $tstat = $statsData->{$timestamp};
				# Loop with its keys
				foreach my $item (keys %{$tstat}) {
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
			foreach my $direction ('Tx','Rx') {
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
				my $statsData = opentrafficshaper::plugins::statistics::getStatsBySID(
						$sid,
						{ 'Direction' => lc($direction)	},
						$startTimestamp,
						$endTimestamp
				);

				# Loop with timestamps
				foreach my $timestamp (sort keys %{$statsData}) {
					# Grab the stat
					my $tstat = $statsData->{$timestamp};
					# Loop with its keys
					foreach my $item (keys %{$tstat}) {
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
				my $statsData = opentrafficshaper::plugins::statistics::getStatsBySID(
						$sid,
						{ 'Direction' => lc($direction) },
						$startTimestamp,
						$endTimestamp
				);

				# Loop with timestamps
				foreach my $timestamp (sort keys %{$statsData}) {
					# Grab the stat
					my $tstat = $statsData->{$timestamp};
					# Loop with its keys
					foreach my $item (keys %{$tstat}) {
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
				foreach my $item (keys %{$tstat}) {
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



# Function to build the javascript we need to display graphs in a canvas
sub _buildGraphJavascript
{
	my $graphs = shift;

	my $javascript = "";

	foreach my $graph (@{$graphs}) {
		my $encodedCanvasName = encode_entities($graph->{'Tag'});

		# Items we going to need...
		my @datasources = ();
		my $axesIdentifiers = { 'X' => [ ], 'Y' => [ ] };
		my @axesStrList;
		# Loop with and build the JS for our datasources
		foreach my $datasource (@{$graph->{'Datasources'}}) {
			# Websocket based data
			if ($datasource->{'Type'} eq "websocket") {

				# Create Subscriptions
				my @subscriptions;
				foreach my $subscription (@{$datasource->{'Subscriptions'}}) {
					my $encodedSubscription = encode_entities($subscription);
					push(@subscriptions,"{ 'function': 'subscribe', args: ['$encodedCanvasName','$encodedSubscription'] }");
				}

				# Create subscription string
				my $subscriptionStr = join(',',@subscriptions);

				# Add datasource
				push(@datasources,<<EOF);
						{
							type: 'websocket',
							uri: 'ws://'+window.location.host+'/statistics/graphdata',
							shared: true,
							// Websocket specific
							onconnect: [
								$subscriptionStr
							]
						}
EOF
			# JSON based data
			} elsif ($datasource->{'Type'} eq "ajax") {
				# Create Subscriptions
				my @subscriptions;
				foreach my $subscription (@{$datasource->{'Subscriptions'}}) {
					my $encodedType = encode_entities($subscription->{'Type'});
					my $encodedData = encode_entities($subscription->{'Data'});

					# Data we nee dto pull
					push(@subscriptions,sprintf(
						"%s=%s:%s",
						$encodedType,
						$encodedCanvasName,
						$encodedData
					));
					# Check if we have a start period
					if (defined($subscription->{'StartTimestamp'})) {
						push(@subscriptions,sprintf("start=%s",$subscription->{'StartTimestamp'}));
					}
					# Check if we have an end period
					if (defined($subscription->{'EndTimestamp'})) {
						push(@subscriptions,sprintf("end=%s",$subscription->{'EndTimestamp'}));
					}
				}
				# Create subscription string
				my $subscriptionStr = join('&',@subscriptions);

				# Add datasource
				push(@datasources,<<EOF);
						{
							type: 'ajax',
							url: '///'+window.location.host+'/statistics/jsondata?$subscriptionStr'
						}
EOF
			}
		}
		# Loop with axes and build our axes structure
		foreach my $axis (keys %{$axesIdentifiers}) {
			foreach my $identifier (@{$graph->{"${axis}Identifiers"}}) {
				# Our first identifier option is the label
				my @options = (
						sprintf("label: '%s'", encode_entities($identifier->{'Label'}))
				);
				# Set limiting factors if there are any
				if (defined($identifier->{'Timespan'})) {
					push(@options,sprintf("maxTimespan: %s",$identifier->{'Timespan'}));
				}
				if (defined($identifier->{'Count'})) {
					push(@options,sprintf("maxCount: %s",$identifier->{'Count'}));
				}
				# Join everything up
				my $optionsStr = join(' ,',@options);
				# Add to axes
				push(@{$axesIdentifiers->{$axis}},sprintf("'%s': { %s }",encode_entities($identifier->{'Name'}),$optionsStr));
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
						$datasourceStr
					],
					$axesStr
				}
			});
EOF
	}

	return $javascript;
}



1;
# vim: ts=4
