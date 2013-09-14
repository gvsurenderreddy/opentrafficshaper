# OpenTrafficShaper webserver module: configmanager page
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

package opentrafficshaper::plugins::webserver::pages::configmanager;

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
use opentrafficshaper::utils qw( parseFormContent isUsername isIP isNumber prettyUndef );

use opentrafficshaper::plugins::configmanager qw( getOverrides getOverride getTrafficClasses getTrafficClassName isTrafficClassValid );



# Sidebar menu options for this module
my $menu = {
	'View Overrides' =>  {
		'All Overrides' => '',
	},
	'Admin' =>  {
		'Add Override' => 'add',
	},
};



# Default page/action
sub default
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	my @overrides = getOverrides();

	# Build content
	my $content = "";

	# Header
	$content .=<<EOF;
<table class="table">
	<legend>Override List</legend>
	<thead>
		<tr>
			<th></th>
			<th>Friendly Name</th>
			<th>User</th>
			<th>Group</th>
			<th>IP</th>
			<th>Expires</th>
			<th></th>
			<th>Class</th>
			<th>CIR (Kbps)</th>
			<th>Limit (Kbps)</th>
			<th></th>
		</tr>
	</thead>
	<tbody>
EOF
	# Body
	foreach my $oid (@overrides) {
		my $override;
		# If we can't get the limit just move onto the next
		if (!defined($override = getOverride($oid))) {
			next;
		}

		my $keyEscaped = uri_escape($override->{'Key'});

		my $friendlyNameEncoded = prettyUndef(encode_entities($override->{'FriendlyName'}));
		my $usernameEncoded = prettyUndef(encode_entities($override->{'Username'}));
		my $ipAddress = prettyUndef($override->{'IP'});
		my $expiresStr = DateTime->from_epoch( epoch => $override->{'Expires'} )->iso8601();

		my $classStr = prettyUndef(getTrafficClassName($override->{'ClassID'}));
		my $cirStr = sprintf('%s/%s',prettyUndef($override->{'TrafficLimitTx'}),prettyUndef($override->{'TrafficLimitRx'}));
		my $limitStr = sprintf('%s/%s',prettyUndef($override->{'TrafficLimitTxBurst'}),prettyUndef($override->{'TrafficLimitRxBurst'}));


		$content .= <<EOF;
		<tr>
			<td></td>
			<td>$friendlyNameEncoded</td>
			<td>$usernameEncoded</td>
			<td>$override->{'GroupID'}</td>
			<td>$ipAddress</td>
			<td>$expiresStr</td>
			<td><span class="glyphicon glyphicon-arrow-right" /></td>
			<td>$classStr</td>
			<td>$cirStr</td>
			<td>$limitStr</td>
			<td>
				<a href="/configmanager/override-edit?key=$keyEscaped"><span class="glyphicon glyphicon-wrench" /></a>
				<a href="/configmanager/override-remove?key=$keyEscaped"><span class="glyphicon glyphicon-remove" /></a>
			</td>
		</tr>
EOF
	}

	# No results
	if (!@overrides) {
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


	return (HTTP_OK,$content,{ 'menu' => $menu });
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
		'inputTrafficClassEnabled' => undef,
		'inputLimitTx' => undef,
		'inputLimitTxEnabled' => undef,
		'inputLimitTxBurst' => undef,
		'inputLimitTxBurstEnabled' => undef,
		'inputLimitRx' => undef,
		'inputLimitRxEnabled' => undef,
		'inputLimitRxBurst' => undef,
		'inputLimitRxBurstEnabled' => undef,
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

		# Check POST data
		my $friendlyName = $params->{'inputFriendlyName'};

		# Make sure we have at least the username or IP
		my $username = isUsername($params->{'inputUsername'});
		my $ipAddress = isIP($params->{'inputIP'});
		if (!defined($username) && !defined($ipAddress)) {
			push(@errors,"IP Address and/or Username must be specified");
		}

		# If the traffic class is ticked, process it
		my $trafficClass;
		if (defined($params->{'inputTrafficClassEnabled'})) {
			if (!defined($trafficClass = isTrafficClassValid($params->{'inputTrafficClass'}))) {
				push(@errors,"Traffic class is not valid");
			}
		}
		# Check TrafficLimitTx
		my $trafficLimitTx;
		if (defined($params->{'inputTrafficLimitTxEnabled'})) {
			if (!defined($trafficLimitTx = isNumber($params->{'inputLimitTx'}))) {
				push(@errors,"Download CIR is not valid");
			}
		}
		my $trafficLimitTxBurst;
		if (defined($params->{'inputTrafficLimitTxBurstEnabled'})) {
			if (!defined($trafficLimitTxBurst = isNumber($params->{'inputLimitTxBurst'}))) {
				push(@errors,"Download limit is not valid");
			}
		}
		# Check TrafficLimitRx
		my $trafficLimitRx;
		if (defined($params->{'inputTrafficLimitRxEnabled'})) {
			if (!defined($trafficLimitRx = isNumber($params->{'inputLimitRx'}))) {
				push(@errors,"Upload CIR is not valid");
			}
		}
		my $trafficLimitRxBurst;
		if (defined($params->{'inputTrafficLimitRxBurstEnabled'})) {
			if (!defined($trafficLimitRxBurst = isNumber($params->{'inputLimitRxBurst'}))) {
				push(@errors,"Upload limit is not valid");
			}
		}
		# Check that we actually have something to override
		if (
				!defined($trafficClass) && 
				!defined($trafficLimitTx) && !defined($trafficLimitTxBurst) &&
				!defined($trafficLimitRx) && !defined($trafficLimitRxBurst)
		) {
			push(@errors,"Something must be specified to override");
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


		# If there are no errors we need to push this override
		if (!@errors) {
			# Build override
			my $override = {
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
				'Source' => "plugin.webserver.overrides",
			};

			# Throw the change at the config manager
			$kernel->post("configmanager" => "process_override_change" => $override);

			$logger->log(LOG_INFO,'[WEBSERVER/OVERRIDE/ADD] User: %s, IP: %s, Group: %s, Class: %s, Limits: %s/%s, Burst: %s/%s',
					prettyUndef($username),
					prettyUndef($ipAddress),
					"",
					prettyUndef($trafficClass),
					prettyUndef($trafficLimitTx),
					prettyUndef($trafficLimitRx),
					prettyUndef($trafficLimitTxBurst),
					prettyUndef($trafficLimitRxBurst)
			);

			return (HTTP_TEMPORARY_REDIRECT,'configmanager');
		}
	}

	# Handle checkboxes first and a little differently
	foreach my $item (
			"inputTrafficClassEnabled",
			"inputLimitTxEnabled","inputLimitTxBurstEnabled",
			"inputLimitRxEnabled", "inputLimitRxBurstEnabled"
	) {
		$params->{$item} = defined($params->{$item}) ? "checked" : "";	
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
	<legend>Add Override</legend>
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
	foreach my $classID (keys %{$trafficClasses}) {
		# Process selections nicely
		my $selected = "";
		if ($params->{'inputTrafficClass'} ne "" && $params->{'inputTrafficClass'} eq $classID) {
			$selected = "selected";
		}
		# And build the options
		$trafficClassStr .= '<option value="'.$classID.'" '.$selected.'>'.$trafficClasses->{$classID}.'</option>';
	}

	# Header
	$content .=<<EOF;
	<div class="form-group">
		<label for="inputFriendlyName" class="col-lg-2 control-label">FriendlyName</label>
		<div class="row">
			<div class="col-lg-4">
				<div class="input-group">
					<input name="inputFriendlyName" type="text" placeholder="Friendly Name" class="form-control" value="$params->{'inputFriendlyName'}" />
					<span class="input-group-addon">*</span>
				</div>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputUsername" class="col-lg-2 control-label">Username</label>
		<div class="row">
			<div class="col-lg-4">
				<input name="inputUsername" type="text" placeholder="Username To Override" class="form-control" value="$params->{'inputUsername'}" />
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputIP" class="col-lg-2 control-label">IP Address</label>
		<div class="row">
			<div class="col-lg-4">
				<input name="inputIP" type="text" placeholder="And/Or IP Address To Override" class="form-control" value="$params->{'inputIP'}" />
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="inputTafficClass" class="col-lg-2 control-label">Traffic Class</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="inputTrafficClassEnabled" type="checkbox" $params->{'inputTrafficClassEnabled'}/> Override
			</div>
			<div class="col-lg-2">
				<select name="inputTrafficClass" placeholder="Traffic Class" class="form-control" value="$params->{'inputTrafficClass'}">
					$trafficClassStr
				</select>
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="inputLimitTx" class="col-lg-2 control-label">Download CIR</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="inputLimitTxEnabled" type="checkbox" $params->{'inputLimitTxEnabled'}/> Override
			</div>

			<div class="col-lg-3">
				<div class="input-group">
					<input name="inputLimitTx" type="text" placeholder="Download CIR" class="form-control" value="$params->{'inputLimitTx'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="inputLimitTxBurst" class="col-lg-2 control-label">Download Limit</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="inputLimitTxBurstEnabled" type="checkbox" $params->{'inputLimitTxBurstEnabled'}/> Override
			</div>
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
			<div class="col-lg-2">
				<input name="inputLimitRxEnabled" type="checkbox" $params->{'inputLimitRxEnabled'}/> Override
			</div>
			<div class="col-lg-3">
				<div class="input-group">
					<input name="inputLimitRx" type="text" placeholder="Upload CIR" class="form-control" value="$params->{'inputLimitRx'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="inputLimitRxBurst" class="col-lg-2 control-label">Upload Limit</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="inputLimitRxBurstEnabled" type="checkbox" $params->{'inputLimitRxBurstEnabled'}/> Override
			</div>
			<div class="col-lg-3">
				<div class="input-group">
					<input name="inputLimitRxBurst" type="text" placeholder="Upload Limit" class="form-control" value="$params->{'inputLimitRxBurst'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
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
		<label for="inputNotes" class="col-lg-2 control-label">Notes</label>
		<div class="row">
			<div class="col-lg-4">
				<textarea name="inputNotes" placeholder="Notes" rows="3" class="form-control"></textarea>
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
