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
use URI::QueryParam;

use opentrafficshaper::logger;
use opentrafficshaper::plugins;
use opentrafficshaper::utils qw( parseURIQuery parseFormContent isUsername isIP isNumber prettyUndef );

use opentrafficshaper::plugins::configmanager qw( getLimits getLimit getTrafficClasses getTrafficClassName isTrafficClassValid );



# Sidebar menu options for this module
my $menu = {
	'View Limits' =>  {
		'All Limits' => '',
		'Manual Limits' => './?source=plugin.webserver.limits',
	},
	'Admin' => {
		'Add Limit' => 'add',
	},
};



# Default page/action
sub default
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	my @limits = getLimits();

	# Pull in URL params
	my $queryParams = parseURIQuery($request);

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
			<th>CIR (Kbps)</th>
			<th>Limits (Kbps)</th>
			<th></th>
		</tr>
	</thead>
	<tbody>
EOF
	# Body
	foreach my $lid (@limits) {
		my $limit;
		# If we can't get the limit just move onto the next
		if (!defined($limit = getLimit($lid))) {
			next;
		}

		# Conditionals
		if (defined($queryParams->{'source'})) {
			if ($limit->{'Source'} ne $queryParams->{'source'}) {
				next;
			}
		}

		# Make style a bit pretty
		my $style = "";
		my $icon = "";
		if ($limit->{'Status'} eq "offline") {
			$icon = '<span class="glyphicon glyphicon-trash"></span>';
			$style = "warning";
		} elsif ($limit->{'Status'} eq "new") {
#			$icon = '<i class="glyphicon-plus"></i>';
			$style = "info";
		} elsif ($limit->{'Status'} eq "conflict") {
			$icon = '<span class="glyphicon glyphicon-random"></span>';
			$style = "error";
		}

		# Get a nice last update string
		my $lastUpdate = DateTime->from_epoch( epoch => $limit->{'LastUpdate'} )->iso8601();

		my $cirStr = sprintf('%s/%s',prettyUndef($limit->{'TrafficLimitTx'}),prettyUndef($limit->{'TrafficLimitRx'}));
		my $limitStr = sprintf('%s/%s',prettyUndef($limit->{'TrafficLimitTxBurst'}),prettyUndef($limit->{'TrafficLimitRxBurst'}));


		# If the statistics plugin is loaded pull in some stats
		my $statsPPSTx = my $statsRateTx = my $statsPrioTx = "-";
		my $statsPPSRx = my $statsRateRx = my $statsPrioRx = "-";
		if (plugin_is_loaded('statistics')) {
			my $stats = opentrafficshaper::plugins::statistics::getLastStats($limit->{'Username'});
			# Pull off tx stats
			if (my $statsTx = $stats->{'tx'}) {
				$statsPPSTx = $statsTx->{'current_pps'};
				$statsRateTx = $statsTx->{'current_rate'};
				$statsPrioTx = $statsTx->{'priority'};
			}
			# Pull off rx stats
			if (my $statsRx = $stats->{'rx'}) {
				$statsPPSRx = $statsRx->{'current_pps'};
				$statsRateRx = $statsRx->{'current_rate'};
				$statsPrioRx = $statsRx->{'priority'};
			}
		}

		my $usernameEncoded = encode_entities($limit->{'Username'});
		my $usernameEscaped = uri_escape($limit->{'Username'});

		my $classStr = getTrafficClassName($limit->{'ClassID'});

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
			<td>$classStr</td>
			<td>$limit->{'GroupID'}</td>
			<td>$cirStr</td>
			<td>$limitStr</td>
			<td>
				<a href="/statistics/by-username?username=$usernameEscaped"><span class="glyphicon glyphicon-stats"></span></a>
				<a href="/limits/limit-edit?username=$usernameEscaped"><span class="glyphicon glyphicon-wrench"></span></a>
				<a href="/limits/limit-remove?username=$usernameEscaped"><span class="glyphicon glyphicon-remove"></span></a>
			</td>
		</tr>
EOF
	}

	# No results
	if (!@limits) {
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
		'inputFriendlyName' => undef,
		'inputUsername' => undef,
		'inputIP' => undef,
		'inputTrafficClass' => undef,
		'inputLimitTx' => undef,
		'inputLimitTxBurst' => undef,
		'inputLimitRx' => undef,
		'inputLimitRxBurst' => undef,
		'inputExpires' => undef,
		'inputExpiresModifier' => undef,
		'inputNotes' => undef,
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

		# Grab friendly name
		my $friendlyName = $params->{'inputFriendlyName'};

		# Check POST data
		my $username;
		if (!defined($username = isUsername($params->{'inputUsername'}))) {
			push(@errors,"Username is not valid");
		}
		my $ipAddress;
		if (!defined($ipAddress = isIP($params->{'inputIP'}))) {
			push(@errors,"IP address is not valid");
		}
		my $trafficClass;
		if (!defined($trafficClass = isTrafficClassValid($params->{'inputTrafficClass'}))) {
			push(@errors,"Traffic class is not valid");
		}
		my $trafficLimitTx = isNumber($params->{'inputLimitTx'});
		my $trafficLimitTxBurst = isNumber($params->{'inputLimitTxBurst'});
		if (!defined($trafficLimitTx) && !defined($trafficLimitTxBurst)) {
			push(@errors,"A valid download CIR and/or limit is required");
		}
		my $trafficLimitRx = isNumber($params->{'inputLimitRx'});
		my $trafficLimitRxBurst = isNumber($params->{'inputLimitRxBurst'});
		if (!defined($trafficLimitRx) && !defined($trafficLimitRxBurst)) {
			push(@errors,"A valid upload CIR and/or limit is required");
		}

		my $expires = 0;
		if (defined($params->{'inputExpires'}) && $params->{'inputExpires'} ne "") {
			if (!defined($expires = isNumber($params->{'inputExpires'}))) {
				push(@errors,"Expires value is not valid");
			# Check the modifier
			} else {
				# Check if its defined
				if (defined($params->{'inputExpiresModifier'}) && $params->{'inputExpiresModifier'} ne "") {
					# Minutes
					if ($params->{'inputExpiresModifier'} eq "m") {
						$expires *= 60;
					# Hours
					} elsif ($params->{'inputExpiresModifier'} eq "h") {
						$expires *= 3600;
					# Days
					} elsif ($params->{'inputExpiresModifier'} eq "d") {
						$expires *= 86400;
					} else {
						push(@errors,"Expires modifier is not valid");
					}
				}
				# Set right time for expiry
				$expires += time();
			}
		}
		# Grab notes
		my $notes = $params->{'inputNotes'};

		# If there are no errors we need to push this update
		if (!@errors) {
			# Build limit
			my $limit = {
				'FriendlyName' => $friendlyName,
				'Username' => $username,
				'IP' => $ipAddress,
				'GroupID' => 1,
				'ClassID' => $trafficClass,
				'TrafficLimitTx' => $trafficLimitTx,
				'TrafficLimitTxBurst' => $trafficLimitTxBurst,
				'TrafficLimitRx' => $trafficLimitRx,
				'TrafficLimitRxBurst' => $trafficLimitRxBurst,
				'Expires' => $expires,
				'Notes' => $notes,
				'Source' => "plugin.webserver.limits",
			};

			# Throw the change at the config manager
			$kernel->post("configmanager" => "process_limit_change" => $limit);

			$logger->log(LOG_INFO,'[WEBSERVER/LIMITS/ADD] User: %s, IP: %s, Group: %s, Class: %s, Limits: %s/%s, Burst: %s/%s',
					prettyUndef($username),
					prettyUndef($ipAddress),
					undef,
					prettyUndef($trafficClass),
					prettyUndef($trafficLimitTx),
					prettyUndef($trafficLimitRx),
					prettyUndef($trafficLimitTxBurst),
					prettyUndef($trafficLimitRxBurst)
			);

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
			$content .= '<div class="alert alert-danger">'.$error.'</div>';
		}
	}

	# Generate traffic class list
	my $trafficClasses = getTrafficClasses();
	my $trafficClassStr = "";
	foreach my $classID (sort keys %{$trafficClasses}) {
		$trafficClassStr .= '<option value="'.$classID.'">'.$trafficClasses->{$classID}.'</option>';
	}

	# Header
	$content .=<<EOF;
	<div class="form-group">
		<label for="inputFriendlyName" class="col-lg-2 control-label">Friendly Name</label>
		<div class="row">
			<div class="col-lg-4 input-group">
				<input name="inputFriendlyName" type="text" placeholder="Opt. Friendly Name" class="form-control" value="$params->{'inputFriendlyName'}" />
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputUsername" class="col-lg-2 control-label">Username</label>
		<div class="row">
			<div class="col-lg-4 input-group">
				<input name="inputUsername" type="text" placeholder="Username" class="form-control" value="$params->{'inputUsername'}" />
				<span class="input-group-addon">*</span>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputIP" class="col-lg-2 control-label">IP Address</label>
		<div class="row">
			<div class="col-lg-4 input-group">
				<input name="inputIP" type="text" placeholder="IP Address" class="form-control" value="$params->{'inputIP'}" />
				<span class="input-group-addon">*</span>
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
				<input name="inputExpires" type="text" placeholder="Opt. Expires" class="form-control" value="$params->{'inputExpires'}" />
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
		<label for="inputLimitTx" class="col-lg-2 control-label">Download CIR</label>
		<div class="row">
			<div class="col-lg-3">
				<div class="input-group">
					<input name="inputLimitTx" type="text" placeholder="Download CIR" class="form-control" value="$params->{'inputLimitTx'}" />
					<span class="input-group-addon">Kbps *<span>
				</div>
			</div>

			<label for="inputLimitTxBurst" class="col-lg-1 control-label">Limit</label>
			<div class="col-lg-3">
				<div class="input-group">
					<input name="inputLimitTxBurst" type="text" placeholder="Download Limit" class="form-control" value="$params->{'inputLimitTxBurst'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="inputLimitRx" class="col-lg-2 control-label">Upload CIR</label>
		<div class="row">
			<div class="col-lg-3">
				<div class="input-group">
					<input name="inputLimitRx" type="text" placeholder="Upload CIR" class="form-control" value="$params->{'inputLimitRx'}" />
					<span class="input-group-addon">Kbps *<span>
				</div>
			</div>

			<label for="inputLimitRxBurst" class="col-lg-1 control-label">Limit</label>
			<div class="col-lg-3">
				<div class="input-group">
					<input name="inputLimitRxBurst" type="text" placeholder="Upload Limit" class="form-control" value="$params->{'inputLimitRxBurst'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputNotes" class="col-lg-2 control-label">Notes</label>
		<div class="row">
			<div class="col-lg-4">
				<textarea name="inputNotes" placeholder="Opt. Notes" rows="3" class="form-control"></textarea>
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
# vim: ts=4
