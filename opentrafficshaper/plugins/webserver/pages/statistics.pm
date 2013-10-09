# OpenTrafficShaper webserver module: users page
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
use opentrafficshaper::utils qw( parseURIQuery );

use opentrafficshaper::plugins::configmanager qw( getLimit );

use opentrafficshaper::plugins::statistics::statistics;

# Graphs by limit
sub bylimit
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	my $content = <<EOF;
		<div id="header">
			<h2>Limit Stats View</h2>
		</div>
EOF

	my $limit;

	# Maybe we were given an override key as a parameter? this would be an edit form
	if ($request->method eq "GET") {
		# Parse GET data
		my $queryParams = parseURIQuery($request);
		# We need a key first of all...
		if (!defined($queryParams->{'lid'})) {
			$content .=<<EOF;
				<tr class="info">
					<td colspan="8"><p class="text-center">No LID in Query String</p></td>
				</tr>
EOF
		}
		# Check if we get some data back when pulling the limit from the backend
		if (!defined($limit = getLimit($queryParams->{'lid'}))) {
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
	<div id="content" style="float:left">

		<div style="position: relative; top: 50px;">
			<h4 style="color:#8f8f8f;">Latest Data For: $usernameEncoded</h4>
		<br/>

		<div id="ajaxData" class="ajaxData" style="float:left; width:1024px; height: 560px"></div>
		</div>

	</div>
EOF

	# FIXME - Dynamic script inclusion required

	#$content .= statistics::do_test();
#	$content .= opentrafficshaper::plugins::statistics::do_test();

	# Files loaded at end of HTML document
	my @javascripts = (
		'/static/awit-flot/jquery.flot.min.js',
		'/static/awit-flot/jquery.flot.time.min.js',
#		'/static/awit-flot/jquery.flot.websockets.js'
	);

	# Build our data path using the URI module to make sure its nice and clean
	my $dataPath = URI->new('/statistics/data-by-limit');
	# Pass it the original query, just incase we had extra params we can use
	$dataPath->query_form( $request->uri->query_form() );
	my $dataPathStr = $dataPath->as_string();


	# String put in <script> </script> tags after the above files are loaded
	my $javascript =<<EOF;
// Tooltip - Displays detailed information regarding the data point
function showTooltip(x, y, contents) {
	jQuery('<div id="tooltip">' + contents + '</div>').css({
			position: 'absolute',
			display: 'none',
			top: y - 30,
			left: x - 50,
			color: "#fff",
			padding: '2px 5px',
			'border-radius': '6px',
			'background-color': '#000',
			opacity: 0.80
	}).appendTo("body").fadeIn(200);
}

var previousPoint = null;
jQuery("#ajaxData").bind("plothover", function (event, pos, item) {
	if (item) {
		if (previousPoint != item.dataIndex) {
			previousPoint = item.dataIndex;
			jQuery("#tooltip").remove();
			showTooltip(item.pageX, item.pageY, item.series.label);
		}
	} else {
		jQuery("#tooltip").remove();
		previousPoint = null;
	}
});


// Setting up the graph here
options = {

	series: {
		lines: {
			show: true,
			lineWidth: 1,
			fill: true,
			fillColor: {
				colors: [
					{ opacity: 0.1 },
					{ opacity: 0.13 }
				]
			}
		},

		points: {
			show: false,
			lineWidth: 2,
			radius: 3
		},

		shadowSize: 0,
		stack: true
	},

	grid: {
		hoverable: true,
		clickable: false,
		tickColor: "#f9f9f9",
		borderWidth: 0
	},

	legend: {
		labelBoxBorderColor: "#fff"
	},

	xaxis: {
		mode: "time",

		tickSize: [60, "second"],

		tickFormatter: function (v, axis) {
			var date = new Date(v);

			if (date.getSeconds() % 5 == 0) {
				var hours = date.getHours() < 10 ? "0" + date.getHours() : date.getHours();
				var minutes = date.getMinutes() < 10 ? "0" + date.getMinutes() : date.getMinutes();
				var seconds = date.getSeconds() < 10 ? "0" + date.getSeconds() : date.getSeconds();

				return hours + ":" + minutes + ":" + seconds;
			} else {
				return "";
			}
		},
	},

	yaxis: {
		min: 0,
//		max: 4000,
		tickFormatter: function (v, axis) {
			if (v % 10 == 0) {
				res = v.toString().replace(/\\B(?=(\\d{3})+(?!\\d))/g, ",");
				console.log(res);
				return res + ' Kbps';
			} else {
				return "";
			}
		},
	}
}

// Load data from ajax
jQuery.ajax({
	url: '$dataPathStr',
	dataType: 'json',

	success: function(statsData) {
		plot = null;

		// formatting time to match javascript's epoch in milliseconds
		for (i = 0; (i < statsData.length); i++) {
			//console.log(statsData[i].data);
			for (y = 0; (y < statsData[i].data.length); y++) {
				d = new Date(statsData[i].data[y][0] * 1000);
				statsData[i].data[y][0] = statsData[i].data[y][0] * 1000;
			}
		}

		if (statsData.length > 0) {
			plot = jQuery.plot(jQuery("#ajaxData"), statsData, options);
		}
	}
});
EOF

END:

	return (HTTP_OK,$content,{ 'javascripts' => \@javascripts, 'javascript' => $javascript });
}



sub databylimit
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Pull in query string
	my %query = $request->uri->query_form();

	# Check if the username was passed to us
	if (!defined($query{'lid'})) {
		return (HTTP_OK,undef,{ 'type' => 'json' });
	}

	# Pull in stats data
	my $statsData = opentrafficshaper::plugins::statistics::getStats($query{'lid'});

	# First stage refinement
	my $rawData;
	foreach my $timestamp (sort keys %{$statsData}) {
		foreach my $direction (keys %{$statsData->{$timestamp}}) {

			foreach my $stat ('rate','pps','cir','limit') {
				push(  @{$rawData->{"$direction.$stat"}->{'data'}} , [ $timestamp , $statsData->{$timestamp}->{$direction}->{$stat} ] );
			}

		}
	}
	# Second stage - add labels
	foreach my $direction ('tx','rx') {
		foreach my $stat ('rate','pps','cir','limit') {
				# Make it looks nice:  Tx Rate
				my $label = uc($direction) . " " . ucfirst($stat);
				# And set it as the label
				$rawData->{"$direction.$stat"}->{'label'} = $label;
		}
	}

	# Final stage, chop it out how we need it
	my $jsonData = [ $rawData->{'tx.limit'}, $rawData->{'rx.limit'}, $rawData->{'tx.rate'} , $rawData->{'rx.rate'} ];

	return (HTTP_OK,$jsonData,{ 'type' => 'json' });
}



1;
