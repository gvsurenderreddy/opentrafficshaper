# OpenTrafficShaper webserver module: limits page
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

package opentrafficshaper::plugins::webserver::pages::limits;

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
use URI::Escape;

use opentrafficshaper::logger;
use opentrafficshaper::plugins;
use opentrafficshaper::utils;

use opentrafficshaper::plugins::configmanager qw( getLimits getTrafficClasses getPriorityName );



# Sidebar menu options for this module
my $menu = {
	'Limits' =>  {
		'Show Limits' => '',
	},
	'Admin' => {
		'Add Limit' => 'add',
	},
};



# Default page/action
sub default
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	my $limits = getLimits();

	# Build content
	my $content = "";

	# Header
	$content .=<<EOF;
<table class="table">
	<legend>Limit List</legend>
	<thead>
		<tr>
			<th></th>
			<th>User</th>
			<th>IP</th>
			<th>Class</th>
			<th>Group</th>
			<th>Limits</th>
			<th></th>
		</tr>
	</thead>
	<tbody>
EOF
	# Body
	foreach my $lid (getLimits()) {
		my $limit;
		# If we can't get the limit just move onto the next
		if (!defined($limit = getLimit($lid))) {
			next;
		}

		# Make style a bit pretty
		my $style = "";
		my $icon = "";
		if ($limit->{'Status'} eq "offline") {
			$icon = '<i class="glyphicon-trash"></i>';
			$style = "warning";
		} elsif ($limit->{'Status'} eq "new") {
#			$icon = '<i class="glyphicon-plus"></i>';
			$style = "info";
		} elsif ($limit->{'Status'} eq "conflict") {
			$icon = '<i class="glyphicon-random"></i>';
			$style = "error";
		}

		# Get a nice last update string
		my $lastUpdate = DateTime->from_epoch( epoch => $limit->{'LastUpdate'} )->iso8601();
		my $limits = $limit->{'TrafficLimitTx'} . "/" . $limit->{'TrafficLimitRx'};


		# If the statistics plugin is loaded pull in some stats
		my $statsPPSTx = my $statsRateTx = my $statsPrioTx = "-";
		my $statsPPSRx = my $statsRateRx = my $statsPrioRx = "-";
		if (plugin_is_loaded('statistics')) {
			my $stats = opentrafficshaper::plugins::statistics::getLastStats($limit->{'Username'});
			# Pull off tx stats
			if (my $statsTx = $stats->{'tx'}) {
				$statsPPSTx = $statsTx->{'current_pps'};
				$statsRateTx = $statsTx->{'current_rate'};
				$statsPrioTx = getPriorityName($limit->{'TrafficPriority'});
			}
			# Pull off rx stats
			if (my $statsRx = $stats->{'rx'}) {
				$statsPPSRx = $statsRx->{'current_pps'};
				$statsRateRx = $statsRx->{'current_rate'};
				$statsPrioRx = getPriorityName($limit->{'TrafficPriority'});
			}
		}

		my $usernameEncoded = encode_entities($limit->{'Username'});
		my $usernameEscaped = uri_escape($limit->{'Username'});


		$content .= <<EOF;
		<tr class="$style">
			<td>$icon</td>
			<td class="limit">
				$usernameEncoded
				<span class="limit-data" style="display:none">
					<table width="100%" border="0">
						<tr>
							<td>Source</td>
							<td>$limit->{'Source'}</td>
							<td>&nbsp;</td>
							<td>Last Update</td>
							<td>$lastUpdate</td>
						</tr>
						<tr>
							<td>Tx Priority</td>
							<td>$statsPrioTx</td>
							<td>&nbsp;</td>
							<td>Tx Priority</td>
							<td>$statsPrioRx</td>
						</tr>
						<tr>
							<td>Tx PPS</td>
							<td>$statsPPSTx</td>
							<td>&nbsp;</td>
							<td>Rx PPS</td>
							<td>$statsPPSRx</td>
						</tr>
						<tr>
							<td>Tx Rate</td>
							<td>$statsRateTx</td>
							<td>&nbsp;</td>
							<td>Rx Rate</td>
							<td>$statsRateRx</td>
						</tr>
					</table>
				</span>
			</td>
			<td>$limit->{'IP'}</td>
			<td>$limit->{'ClassID'}</td>
			<td>$limit->{'GroupID'}</td>
			<td>$limits</td>
			<td>
				<a href="/statistics/by-username?username=$usernameEscaped"><i class="glyphicon glyphicon-stats"></i></a>
				<i class="glyphicon glyphicon-wrench"></i>
			</td>
		</tr>
EOF
	}

	# No results
	if (keys %{$limits} < 1) {
		$content .=<<EOF;
		<tr class="info">
			<td colspan="8"><p class="text-center">No Results</p></td>
		</tr>
EOF
	}

	# Footer
	$content .=<<EOF;
	</tbody>
</table>
EOF

	my $style = <<EOF;
		.popover {
			max-width:none;
		}

		.popover td:nth-child(4), .popover td:first-child {
			font-weight:bold;
			text-transform:capitalize;
		}
EOF

	my $javascript = <<EOF;
		\$(document).ready(function(){
			\$('.limit').each(function(){
				\$(this).popover({
					html: true,
					content: \$(this).find('.limit-data').html(),
					placement: 'bottom',
					trigger: 'hover',
					container: \$(this),
					title: 'Statistics',
				});
			})
		});
EOF

	return (HTTP_OK,$content,{ 'style' => $style, 'menu' => $menu, 'javascript' => $javascript });
}


# Add action
sub add
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Setup our environment
	my $logger = $globals->{'logger'};

	# Errors to display
	my @errors;
	# Form items
	my $params = {
		'inputUsername' => undef,
		'inputIP' => undef,
		'inputTrafficClass' => undef,
		'inputExpires' => undef,
		'inputExpiresModifier' => undef,
		'inputLimitTx' => undef,
		'inputLimitRx' => undef,
	};

	# If this is a form try parse it
	if ($request->method eq "POST") {
		# Parse form data
		$params = parseFormContent($request->content);

		# If user pressed cancel, redirect
		if (defined($params->{'cancel'})) {
			# Redirects to default page
			return (HTTP_TEMPORARY_REDIRECT,'limits');
		}

		# Check POST data
		my $username;
		if (!defined($username = isUsername($params->{'inputUsername'}))) {
			push(@errors,"Username is not valid");
		}
		my $ipAddress;
		if (!defined($ipAddress = isIP($params->{'inputIP'}))) {
			push(@errors,"IP address is not valid");
		}
		my $trafficLimitTx;
		if (!defined($trafficLimitTx = isNumber($params->{'inputLimitTx'}))) {
			push(@errors,"Download limit is not valid");
		}
		my $trafficLimitRx;
		if (!defined($trafficLimitRx = isNumber($params->{'inputLimitRx'}))) {
			push(@errors,"Upload limit is not valid");
		}

		# If there are no errors we need to push this update
		if (!@errors) {
			# Build limit
			my $limit = {
				'Username' => $username,
				'IP' => $ipAddress,
				'GroupID' => 1,
				'ClassID' => 1,
				'TrafficLimitTx' => $trafficLimitTx,
				'TrafficLimitRx' => $trafficLimitRx,
				'TrafficLimitTxBurst' => $trafficLimitTx,
				'TrafficLimitRxBurst' => $trafficLimitRx,
				'Status' => "online",
				'Source' => "plugin.webserver.limits",
			};

			# Throw the change at the config manager
			$kernel->post("configmanager" => "process_change" => $limit);

			$logger->log(LOG_INFO,"[WEBSERVER/LIMIS/ADD] User: $username, IP: $ipAddress, Group: 1, Class: 2, ".
					"Limits: ".prettyUndef($trafficLimitTx)."/".prettyUndef($trafficLimitRx).", Burst: ".prettyUndef($trafficLimitTx)."/".prettyUndef($trafficLimitRx));

			return (HTTP_TEMPORARY_REDIRECT,'limits');
		}
	}

	# Sanitize params if we need to
	foreach my $item (keys %{$params}) {
		$params->{$item} = defined($params->{$item}) ? encode_entities($params->{$item}) : "";	
	}

	# Build content
	my $content = "";

	# Form header
	$content .=<<EOF;
<form role="form" method="post">
	<legend>Add Manual Limit</legend>
EOF

	# Spit out errors if we have any
	if (@errors > 0) {
		foreach my $error (@errors) {
			$content .= '<div class="alert alert-error">'.$error.'</div>';
		}
	}

	# Generate traffic class list
	my $trafficClasses = getTrafficClasses();
	my $trafficClassStr = "";
	foreach my $classID (keys %{$trafficClasses}) {
		$trafficClassStr .= '<option value="'.$classID.'">'.$trafficClasses->{$classID}.'</option>';
	}

	# Header
	$content .=<<EOF;
	<div class="form-group">
		<label for="inputUsername" class="col-lg-2 control-label">Username</label>
		<div class="row">
			<div class="col-lg-4">
				<input name="inputUsername" type="text" placeholder="Username" class="form-control" value="$params->{'inputUsername'}" />
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputIP" class="col-lg-2 control-label">IP Address</label>
		<div class="row">
			<div class="col-lg-4">
				<input name="inputIP" type="text" placeholder="IP Address" class="form-control" value="$params->{'inputIP'}" />
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputTafficClass" class="col-lg-2 control-label">Traffic Class</label>
		<div class="row">
			<div class="col-lg-2">
				<select name="inputTrafficClass" placeholder="Traffic Class" class="form-control" value="$params->{'inputTrafficClass'}">
					$trafficClassStr
				</select>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputExpires" class="col-lg-2 control-label">Expires</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="inputExpires" type="text" placeholder="Expires" class="form-control" value="$params->{'inputExpires'}" />
			</div>
			<div class="col-lg-2">
				<select name="inputExpiresModifier" placeholder="Expires Modifier" class="form-control" value="$params->{'inputExpiresModifier'}">
					<option value="m">Mins</option>
					<option value="h">Hours</option>
					<option value="d">Days</option>
				</select>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputLimitTx" class="col-lg-2 control-label">Download Limit</label>
		<div class="row">
			<div class="col-lg-3">
				<div class="input-group">
					<input name="inputLimitTx" type="text" placeholder="TX Limit" class="form-control" value="$params->{'inputLimitTx'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputLimitRx" class="col-lg-2 control-label">Upload Limit</label>
		<div class="row">
			<div class="col-lg-3">
				<div class="input-group">
					<input name="inputLimitRx" type="text" placeholder="RX Limit" class="form-control" value="$params->{'inputLimitRx'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputDescription" class="col-lg-2 control-label">Description</label>
		<div class="row">
			<div class="col-lg-4">
				<textarea name="inputDescription" placeholder="Description" rows="3" class="form-control"></textarea>
			</div>
		</div>
	</div>
	<div class="form-group">
		<button type="submit" class="btn btn-primary">Add</button>
		<button name="cancel" type="submit" class="btn">Cancel</button>
	</div>
</form>
EOF

	return (HTTP_OK,$content,{ 'menu' => $menu });
}


1;
