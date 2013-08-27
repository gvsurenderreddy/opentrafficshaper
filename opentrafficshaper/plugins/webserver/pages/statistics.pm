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

use opentrafficshaper::logger;
use opentrafficshaper::utils;

use opentrafficshaper::plugins::statistics::statistics;

# Default page/action
sub default
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Build content
	my $content = <<EOF;
		
	<div id="header">
		<h2>Traffic Shaper Stats</h2>
	</div>

	<div id="content" style="float:left">

		<div style="position: relative; top:50px;">
		<h4 style="color:#8f8f8f;">Json Data (loads from /static/stats.json.js)</h4>
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

	# String put in <script> </script> tags after the above files are loaded
	my $javascript =<<EOF;
	//
    // Tooltip - Displays detailed information regarding the data point
    //
	function showTooltip(x, y, contents) {
		jQuery('<div id="tooltip">' + contents + '</div>').css( {
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
                var x = item.datapoint[0].toFixed(0),
                    y = item.datapoint[1].toFixed(0);

                showTooltip(item.pageX, item.pageY,
                            item.series.label + ' date: ' + month);
            }
        }
        else {
            jQuery("#tooltip").remove();
            previousPoint = null;
        }
    });


	// Setting up the graph here
	options = {
		series: {
			lines: { show: true,
					lineWidth: 1,
					fill: true, 
					fillColor: { colors: [ { opacity: 0.1 }, { opacity: 0.13 } ] }
				 },
			points: { show: true, 
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
			// show: false
			labelBoxBorderColor: "#fff"
			//,container: '#legend-container'
		},

		xaxis: {
			mode: "time",
			tickSize: [2, "second"],
			tickFormatter: function (v, axis) {
				var date = new Date(v);
		 		
				if (date.getSeconds() % 1 == 0) {
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
			max: 4000,
			tickFormatter: function (v, axis) {
				if (v % 10 == 0) {
					return v;
				} else {
					return "";
				}
			},
		}
	}
	//*/

	// loading the stats.json.js file as data and drawing the graph on successful response.
	jQuery.ajax({
	  url: '/static/stats.json.js',
	  dataType: "json",
	  success: function(statsData){
		plot = null;
		if (statsData.length > 0) {
			plot = jQuery.plot(jQuery("#ajaxData"), statsData, options);
		}
	  }
	});


EOF

	return (HTTP_OK,$content,{ 'javascripts' => \@javascripts, 'javascript' => $javascript });
}



1;
