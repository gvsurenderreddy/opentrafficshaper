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

use opentrafficshaper::plugins::configmanager qw(
		getLimits getLimit

		getInterfaceGroups
		isInterfaceGroupValid

		getMatchPriorities
		isMatchPriorityValid

		getTrafficClasses getTrafficClassName
		isTrafficClassValid
);



# Sidebar menu options for this module
my $menu = {
	'View Limits' =>  {
		'All Limits' => '',
		'Manual Limits' => './?source=plugin.webserver.limits',
	},
	'Admin' => {
		'Add Limit' => 'limit-add',
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
			if ($limit->{'Source'} ne $queryParams->{'source'}->{'value'}) {
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
		if (isPluginLoaded('statistics')) {
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

		my $lidEncoded = encode_entities($limit->{'ID'});

		my $name = (defined($limit->{'FriendlyName'}) && $limit->{'FriendlyName'} ne "") ? $limit->{'FriendlyName'} : $limit->{'Username'};
		my $usernameEncoded = encode_entities($name);

		my $classStr = getTrafficClassName($limit->{'ClassID'});

		# We only support removing certain sources of limits
		my $removeLink = "";
		if ($limit->{'Source'} eq "plugin.webserver.limits") {
			$removeLink = "<a href=\"/limits/limit-remove?lid=$lidEncoded\"><span class=\"glyphicon glyphicon-remove\"></span></a>";
		}

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
				<a href="/statistics/by-limit?lid=$lidEncoded"><span class="glyphicon glyphicon-stats"></span></a>
				<a href="/limits/limit-edit?lid=$lidEncoded"><span class="glyphicon glyphicon-wrench"></span></a>
				$removeLink
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


# Add/edit action
sub limit_addedit
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Setup our environment
	my $logger = $globals->{'logger'};

	# Errors to display above the form
	my @errors;

	# Items for our form...
	my @formElements = qw(
		FriendlyName
		Username IP
		InterfaceGroupID
		MatchPriorityID
		ClassID
		TrafficLimitTx TrafficLimitTxBurst
		TrafficLimitRx TrafficLimitRxBurst
		Expires inputExpires.modifier
		Notes
	);

	# Expires modifier options
	my $expiresModifiers = {
		'm' => "Minutes",
		'h' => "Hours",
		'd' => "Days",
		'n' => "Never",
	};


	# Title of the form, by default its an add form
	my $formType = "Add";
	my $formNoEdit = "";
	# Form data
	my $formData;

	# If this is a form try parse it
	if ($request->method eq "POST") {
		# Parse form data
		$formData = parseFormContent($request->content);

		# If user pressed cancel, redirect
		if (defined($formData->{'cancel'})) {
			# Redirects to default page
			return (HTTP_TEMPORARY_REDIRECT,'limits');
		}

	# Maybe we were given an override key as a parameter? this would be an edit form
	} elsif ($request->method eq "GET") {
		# Parse GET data
		my $queryParams = parseURIQuery($request);
		# We need a key first of all...
		if (defined($queryParams->{'lid'})) {
			# Check if we get some data back when pulling the limit from the backend
			if (defined($formData = getLimit($queryParams->{'lid'}->{'value'}))) {
				# We need to make sure we're only editing our own limits
				if ($formData->{'Source'} ne "plugin.webserver.limits") {
					return (HTTP_TEMPORARY_REDIRECT,'limits');
				}

				# Work out expires modifier
# XXX - TODO
			# If we didn't get any data, then something went wrong
			} else {
				my $encodedID = encode_entities($queryParams->{'lid'}->{'value'});
				push(@errors,"Limit data could not be loaded using limit ID '$encodedID'");
			}
			# Lastly if we were given a key, this is actually an edit
			$formType = "Edit";
			$formNoEdit = "readonly";

		# Woops ... no query string?
		} elsif (%{$queryParams} > 0) {
			push(@errors,"No limit ID in query string!");
			$formType = "Edit";
			$formNoEdit = "readonly";
		}
	}

	#
	# If we already have data, lets check how valid it is...
	#

	# We only do this if we have hash elements
	if (ref($formData) eq "HASH") {
		# Grab friendly name
		my $friendlyName = $formData->{'FriendlyName'};

		# Check POST data
		my $username;
		if (!defined($username = isUsername($formData->{'Username'}))) {
			push(@errors,"Username is not valid");
		}
		my $ipAddress;
		if (!defined($ipAddress = isIP($formData->{'IP'}))) {
			push(@errors,"IP address is not valid");
		}
		my $interfaceGroupID;
		if (!defined($interfaceGroupID = isInterfaceGroupValid($formData->{'InterfaceGroupID'}))) {
			push(@errors,"Interface group is not valid");
		}
		my $matchPriorityID;
		if (!defined($matchPriorityID = isMatchPriorityValid($formData->{'MatchPriorityID'}))) {
			push(@errors,"Match priority is not valid");
		}
		my $classID;
		if (!defined($classID = isTrafficClassValid($formData->{'ClassID'}))) {
			push(@errors,"Traffic class is not valid");
		}
		my $trafficLimitTx = isNumber($formData->{'TrafficLimitTx'});
		my $trafficLimitTxBurst = isNumber($formData->{'TrafficLimitTxBurst'});
		if (!defined($trafficLimitTx) && !defined($trafficLimitTxBurst)) {
			push(@errors,"A valid download CIR and/or limit is required");
		}
		my $trafficLimitRx = isNumber($formData->{'TrafficLimitRx'});
		my $trafficLimitRxBurst = isNumber($formData->{'TrafficLimitRxBurst'});
		if (!defined($trafficLimitRx) && !defined($trafficLimitRxBurst)) {
			push(@errors,"A valid upload CIR and/or limit is required");
		}

		my $expires = 0;
		if (defined($formData->{'Expires'}) && $formData->{'Expires'} ne "") {
			if (!defined($expires = isNumber($formData->{'Expires'}))) {
				push(@errors,"Expires value is not valid");
			# Check the modifier
			} else {
				# Check if its defined
				if (defined($formData->{'inputExpires.modifier'}) && $formData->{'inputExpires.modifier'} ne "") {
					# Never
					if ($formData->{'inputExpires.modifier'} eq "n") {
						$expires = 0;
					} elsif ($formData->{'inputExpires.modifier'} eq "m") {
						$expires *= 60;
					# Hours
					} elsif ($formData->{'inputExpires.modifier'} eq "h") {
						$expires *= 3600;
					# Days
					} elsif ($formData->{'inputExpires.modifier'} eq "d") {
						$expires *= 86400;
					} else {
						push(@errors,"Expires modifier is not valid");
					}
				}
				# Base the expiry off now, plus the expiry time
				if ($expires > 0) {
					$expires += time();
				}
			}
		}
		# Grab notes
		my $notes = $formData->{'Notes'};

		# If there are no errors we need to push this update
		if (!@errors && $request->method eq "POST") {
			# Build limit
			my $limit = {
				'FriendlyName' => $friendlyName,
				'Username' => $username,
				'IP' => $ipAddress,
				'GroupID' => 1,
				'InterfaceGroupID' => $interfaceGroupID,
				'MatchPriorityID' => $matchPriorityID,
				'ClassID' => $classID,
				'TrafficLimitTx' => $trafficLimitTx,
				'TrafficLimitTxBurst' => $trafficLimitTxBurst,
				'TrafficLimitRx' => $trafficLimitRx,
				'TrafficLimitRxBurst' => $trafficLimitRxBurst,
				'Expires' => $expires,
				'Notes' => $notes,
			};

			# Throw the change at the config manager after we add extra data we need
			if ($formType eq "Add") {
				$limit->{'Status'} = 'online';
				$limit->{'Source'} = 'plugin.webserver.limits';
			}

			$kernel->post("configmanager" => "process_limit_change" => $limit);

			$logger->log(LOG_INFO,'[WEBSERVER/LIMITS] Acount: %s, User: %s, IP: %s, Group: %s, InterfaceGroup: %s, MatchPriority: %s, Class: %s, Limits: %s/%s, Burst: %s/%s',
					$formType,
					prettyUndef($username),
					prettyUndef($ipAddress),
					prettyUndef(undef),
					prettyUndef($interfaceGroupID),
					prettyUndef($matchPriorityID),
					prettyUndef($classID),
					prettyUndef($trafficLimitTx),
					prettyUndef($trafficLimitRx),
					prettyUndef($trafficLimitTxBurst),
					prettyUndef($trafficLimitRxBurst)
			);

			return (HTTP_TEMPORARY_REDIRECT,'limits');
		}
	}

	# Sanitize params if we need to
	foreach my $item (@formElements) {
		$formData->{$item} = defined($formData->{$item}) ? encode_entities($formData->{$item}) : "";
	}

	# Build content
	my $content = "";

	# Form header
	$content .=<<EOF;
<form role="form" method="post">
	<legend>$formType Manual Limit</legend>
EOF

	# Spit out errors if we have any
	if (@errors > 0) {
		foreach my $error (@errors) {
			$content .= '<div class="alert alert-danger">'.$error.'</div>';
		}
	}

	# Generate interface group list
	my $interfaceGroups = getInterfaceGroups();
	my $interfaceGroupStr = "";
	foreach my $interfaceGroupID (sort keys %{$interfaceGroups}) {
		# Process selections nicely
		my $selected = "";
		if ($formData->{'InterfaceGroupID'} ne "" && $formData->{'InterfaceGroupID'} eq $interfaceGroupID) {
			$selected = "selected";
		}
		# And build the options
		$interfaceGroupStr .= '<option value="'.$interfaceGroupID.'" '.$selected.'>'.$interfaceGroups->{$interfaceGroupID}->{'name'}.'</option>';
	}

	# Generate match priority list
	my $matchPriorities = getMatchPriorities();
	my $matchPriorityStr = "";
	foreach my $matchPriorityID (sort keys %{$matchPriorities}) {
		# Process selections nicely
		my $selected = "";
		if ($formData->{'MatchPriorityID'} ne "" && $formData->{'MatchPriorityID'} eq $matchPriorityID) {
			$selected = "selected";
		}
		# Default to 2 if nothing specified
		if ($formData->{'MatchPriorityID'} eq "" && $matchPriorityID eq "2") {
			$selected = "selected";
		}
		# And build the options
		$matchPriorityStr .= '<option value="'.$matchPriorityID.'" '.$selected.'>'.$matchPriorities->{$matchPriorityID}.'</option>';
	}

	# Generate traffic class list
	my $trafficClasses = getTrafficClasses();
	my $trafficClassStr = "";
	foreach my $classID (sort keys %{$trafficClasses}) {
		# Process selections nicely
		my $selected = "";
		if ($formData->{'ClassID'} ne "" && $formData->{'ClassID'} eq $classID) {
			$selected = "selected";
		}
		# And build the options
		$trafficClassStr .= '<option value="'.$classID.'" '.$selected.'>'.$trafficClasses->{$classID}.'</option>';
	}

	# Generate expires modifiers list
	my $expiresModifierStr = "";
	foreach my $expireModifier (sort keys %{$expiresModifiers}) {
		# Process selections nicely
		my $selected = "";
		if ($formData->{'inputExpires.modifier'} ne "" && $formData->{'inputExpires.modifier'} eq $expireModifier) {
			$selected = "selected";
		}
		# Default to n if nothing is specified
		if ($formData->{'inputExpires.modifier'} eq "" && $expireModifier eq "n") {
			$selected = "selected";
		}
		# And build the options
		$expiresModifierStr .= '<option value="'.$expireModifier.'" '.$selected.'>'.$expiresModifiers->{$expireModifier}.'</option>';
	}

	# Blank expires if its 0
	if (defined($formData->{'Expires'}) && $formData->{'Expires'} eq "0") {
		$formData->{'Expires'} = "";
	}

	#
	# Page content
	#
	$content .=<<EOF;
	<div class="form-group">
		<label for="FriendlyName" class="col-lg-2 control-label">Friendly Name</label>
		<div class="row">
			<div class="col-lg-4 input-group">
				<input name="FriendlyName" type="text" placeholder="Opt. Friendly Name" class="form-control" value="$formData->{'FriendlyName'}" />
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="Username" class="col-lg-2 control-label">Username</label>
		<div class="row">
			<div class="col-lg-4 input-group">
				<input name="Username" type="text" placeholder="Username" class="form-control" value="$formData->{'Username'}" $formNoEdit/>
				<span class="input-group-addon">*</span>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="IP" class="col-lg-2 control-label">IP Address</label>
		<div class="row">
			<div class="col-lg-4 input-group">
				<input name="IP" type="text" placeholder="IP Address" class="form-control" value="$formData->{'IP'}" $formNoEdit/>
				<span class="input-group-addon">*</span>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="InterfaceGroupID" class="col-lg-2 control-label">Interface Group</label>
		<div class="row">
			<div class="col-lg-2">
				<select name="InterfaceGroupID" class="form-control" $formNoEdit>
					$interfaceGroupStr
				</select>
			</div>

			<label for="MatchPriorityID" class="col-lg-2 control-label">Match Priority</label>
			<div class="col-lg-2">
				<select name="MatchPriorityID" class="form-control" $formNoEdit>
					$matchPriorityStr
				</select>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="ClassID" class="col-lg-2 control-label">Traffic Class</label>
		<div class="row">
			<div class="col-lg-2">
				<select name="ClassID" class="form-control">
					$trafficClassStr
				</select>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="Expires" class="col-lg-2 control-label">Expires</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="Expires" type="text" placeholder="Optional" class="form-control" value="$formData->{'Expires'}" />
			</div>
			<div class="col-lg-2">
				<select name="inputExpires.modifier" class="form-control" value="$formData->{'inputExpires.modifier'}">
					$expiresModifierStr
				</select>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="TrafficLimitTx" class="col-lg-2 control-label">Download CIR</label>
		<div class="row">
			<div class="col-lg-3">
				<div class="input-group">
					<input name="TrafficLimitTx" type="text" placeholder="Download CIR" class="form-control" value="$formData->{'TrafficLimitTx'}" />
					<span class="input-group-addon">Kbps *<span>
				</div>
			</div>

			<label for="TrafficLimitTxBurst" class="col-lg-1 control-label">Limit</label>
			<div class="col-lg-3">
				<div class="input-group">
					<input name="TrafficLimitTxBurst" type="text" placeholder="Download Limit" class="form-control" value="$formData->{'TrafficLimitTxBurst'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="TrafficLimitRx" class="col-lg-2 control-label">Upload CIR</label>
		<div class="row">
			<div class="col-lg-3">
				<div class="input-group">
					<input name="TrafficLimitRx" type="text" placeholder="Upload CIR" class="form-control" value="$formData->{'TrafficLimitRx'}" />
					<span class="input-group-addon">Kbps *<span>
				</div>
			</div>

			<label for="TrafficLimitRxBurst" class="col-lg-1 control-label">Limit</label>
			<div class="col-lg-3">
				<div class="input-group">
					<input name="TrafficLimitRxBurst" type="text" placeholder="Upload Limit" class="form-control" value="$formData->{'TrafficLimitRxBurst'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="Notes" class="col-lg-2 control-label">Notes</label>
		<div class="row">
			<div class="col-lg-4">
				<textarea name="Notes" placeholder="Opt. Notes" rows="3" class="form-control"></textarea>
			</div>
		</div>
	</div>
	<div class="form-group">
		<button type="submit" class="btn btn-primary">$formType</button>
		<button name="cancel" type="submit" class="btn">Cancel</button>
	</div>
</form>
EOF

	return (HTTP_OK,$content,{ 'menu' => $menu });
}


# Remove action
sub limit_remove
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Content to return
	my $content = "";


	# Pull in GET
	my $queryParams = parseURIQuery($request);
	# We need a key first of all...
	if (!defined($queryParams->{'lid'})) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				No limit ID in query string!
			</div>
EOF
		goto END;
	}

	# Grab the limit
	my $limit = getLimit($queryParams->{'lid'}->{'value'});

	# Make the key safe for HTML
	my $encodedLID = encode_entities($queryParams->{'lid'}->{'value'});

	# Make sure the limit ID is valid... we would have a limit now if it was
	if (!defined($limit)) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				Invalid limit ID "$encodedLID"!
			</div>
EOF
		goto END;
	}

	# Make sure its a manual limit we're removing
	if ($limit->{'Source'} ne "plugin.webserver.limits") {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				Only manual limits can be removed!
			</div>
EOF
		goto END;
	}

	# Pull in POST
	my $postParams = parseFormContent($request->content);
	# If this is a post, then its probably a confirmation
	if (defined($postParams->{'confirm'})) {
		# Check if its a success
		if ($postParams->{'confirm'} eq "Yes") {
			# Post the removal
			$kernel->post("configmanager" => "process_limit_remove" => $limit);
		}
		return (HTTP_TEMPORARY_REDIRECT,'limits');
	}


	# Make the friendly name HTML safe
	my $encodedUsername = encode_entities($limit->{'Username'});

	# Build our confirmation dialog
	$content .= <<EOF;
		<div class="alert alert-danger">
			Are you very sure you wish to remove limit for "$encodedUsername"?
		</div>
		<form role="form" method="post">
			<input type="submit" class="btn btn-primary" name="confirm" value="Yes" />
			<input type="submit" class="btn btn-default" name="confirm" value="No" />
		</form>
EOF
	# And here is where we return
END:
	return (HTTP_OK,$content,{ 'menu' => $menu });
}

1;
# vim: ts=4
