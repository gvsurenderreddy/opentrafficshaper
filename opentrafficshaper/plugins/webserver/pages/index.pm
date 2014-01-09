# OpenTrafficShaper webserver module: index page
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

package opentrafficshaper::plugins::webserver::pages::index;

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


use opentrafficshaper::plugins;


# Dashboard
sub _catchall
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Build content
	my $content = "";

	if (!isPluginLoaded('statistics')) {
		$content .= "No Statistics Plugin";
		goto END;
	}

	my @leftGraphs;
	my @rightGraphs;


	for (my $i = 0; $i < 7; $i++) {
		push(@leftGraphs,"Class $i");
	}
	for (my $i = 0; $i < 2; $i++) {
		push(@rightGraphs,"Main $i");
	}

	# Loop while we have graphs to output
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
				$content .= <<EOF;
							<h4 style="color:#8f8f8f;">Latest Data For: $graph</h4>
							<div id="flotCanvas" class="flotCanvas" style="width: 520px; height: 150px; border: 1px dashed black">
							</div>
EOF
			}
			# LHS - Spacer
			$content .= <<EOF;
						</div>
						<div class="col-xs-6">
EOF
			# Graph 2
			if (defined(my $graph = shift(@leftGraphs))) {
				$content .= <<EOF;
							<h4 style="color:#8f8f8f;">Latest Data For: $graph</h4>
							<div id="flotCanvas" class="flotCanvas" style="width: 520px; height: 150px; border: 1px dashed black">
							</div>
EOF
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
			$content .= <<EOF;
					<h4 style="color:#8f8f8f;">Latest Data For: $graph</h4>
					<div id="flotCanvas" class="flotCanvas" style="width: 520px; height: 340px; border: 1px dashed black"></div>
EOF
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

END:
	return (200,$content);
}


1;
# vim: ts=4
