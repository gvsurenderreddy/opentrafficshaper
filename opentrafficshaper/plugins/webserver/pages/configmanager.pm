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
use opentrafficshaper::utils qw( parseFormContent parseURIQuery isUsername isIP isNumber prettyUndef );

use opentrafficshaper::plugins::configmanager qw( getOverrides getOverride getTrafficClasses getTrafficClassName isTrafficClassValid );



# Sidebar menu options for this module
my $menu = {
	'View Overrides' =>  {
		'All Overrides' => '',
	},
	'Admin' =>  {
		'Add Override' => 'override-add',
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

		my $idEscaped = uri_escape($override->{'ID'});

		my $friendlyNameEncoded = prettyUndef(encode_entities($override->{'FriendlyName'}));
		my $usernameEncoded = prettyUndef(encode_entities($override->{'Username'}));
		my $ipAddress = prettyUndef($override->{'IP'});
		my $expiresStr = ($override->{'Expires'} > 0) ? DateTime->from_epoch( epoch => $override->{'Expires'} )->iso8601() : '-never-';

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
				<a href="/configmanager/override-edit?oid=$idEscaped"><span class="glyphicon glyphicon-wrench" /></a>
				<a href="/configmanager/override-remove?oid=$idEscaped"><span class="glyphicon glyphicon-remove" /></a>
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


# Add/edit action
sub override_addedit
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
		ClassID
		TrafficLimitTx TrafficLimitTxBurst
		TrafficLimitRx TrafficLimitRxBurst
		Expires inputExpires.modifier
		Notes
	);
	my @formElementCheckboxes = qw(
		ClassID
		TrafficLimitTx TrafficLimitTxBurst
		TrafficLimitRx TrafficLimitRxBurst
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

	#
	# Here is where we going to try load data we already have
	#

	# If this is a form try parse it
	if ($request->method eq "POST") {
		# Parse form data
		$formData = parseFormContent($request->content);

		# If user pressed cancel, redirect
		if (defined($formData->{'cancel'})) {
			# Redirects to default page
			return (HTTP_TEMPORARY_REDIRECT,'configmanager');
		}

	# Maybe we were given an override key as a parameter? this would be an edit form
	} elsif ($request->method eq "GET") {
		# Parse GET data
		my $queryParams = parseURIQuery($request);
		# We need a ID first of all...
		if (defined($queryParams->{'oid'})) {
			# Check if we get some data back when pulling the override from the backend
			if (defined($formData = getOverride($queryParams->{'oid'}))) {
				# Setup our checkboxes
				foreach my $checkbox (@formElementCheckboxes) {
					if (defined($formData->{$checkbox})) {
						$formData->{"input$checkbox.enabled"} = "on";
					}
				}

				# Work out expires modifier
				# XXX - TODO
			# If we didn't get any data, then something went wrong
			} else {
				my $encodedID = encode_entities($queryParams->{'oid'});
				push(@errors,"Override data could not be loaded using oid '$encodedID'");
			}
			# Lastly if we were given a oid, this is actually an edit
			$formType = "Edit";
			$formNoEdit = "readonly";

		# Woops ... no query string?
		} elsif (%{$queryParams} > 0) {
			push(@errors,"No override oid in query string!");
			$formType = "Edit";
			$formNoEdit = "readonly";
		}
	}


	#
	# If we already have data, lets check how valid it is...
	#

	# We only do this if we have hash elements
	if (ref($formData) eq "HASH") {
		my $friendlyName = $formData->{'FriendlyName'};
		if (!defined($friendlyName)) {
			push(@errors,"Friendly name must be specified");
		}

		# Make sure we have at least the username or IP
		my $username = isUsername($formData->{'Username'});
		my $ipAddress = isIP($formData->{'IP'});
		if (!defined($username) && !defined($ipAddress)) {
			push(@errors,"IP Address and/or Username must be specified");
		}

		# If the traffic class is ticked, process it
		my $classID;
		if (defined($formData->{'inputClassID.enabled'})) {
			if (!defined($classID = isTrafficClassValid($formData->{'ClassID'}))) {
				push(@errors,"Traffic class is not valid");
			}
		}
		# Check traffic limits
		my $trafficLimitTx;
		if (defined($formData->{'inputTrafficLimitTx.enabled'})) {
			if (!defined($trafficLimitTx = isNumber($formData->{'TrafficLimitTx'}))) {
				push(@errors,"Download CIR is not valid");
			}
		}
		my $trafficLimitTxBurst;
		if (defined($formData->{'inputTrafficLimitTxBurst.enabled'})) {
			if (!defined($trafficLimitTxBurst = isNumber($formData->{'TrafficLimitTxBurst'}))) {
				push(@errors,"Download limit is not valid");
			}
		}
		# Check TrafficLimitRx
		my $trafficLimitRx;
		if (defined($formData->{'inputTrafficLimitRx.enabled'})) {
			if (!defined($trafficLimitRx = isNumber($formData->{'TrafficLimitRx'}))) {
				push(@errors,"Upload CIR is not valid");
			}
		}
		my $trafficLimitRxBurst;
		if (defined($formData->{'inputTrafficLimitRxBurst.enabled'})) {
			if (!defined($trafficLimitRxBurst = isNumber($formData->{'TrafficLimitRxBurst'}))) {
				push(@errors,"Upload limit is not valid");
			}
		}
		# Check that we actually have something to override
		if (
				!defined($classID) &&
				!defined($trafficLimitTx) && !defined($trafficLimitTxBurst) &&
				!defined($trafficLimitRx) && !defined($trafficLimitRxBurst)
		) {
			push(@errors,"Something must be specified to override");
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

					# Minutes
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

		#
		# Process change if this is a POST and there are no errors
		#

		# If there are no errors we need to push this override
		if (!@errors && $request->method eq "POST") {
			# Build override
			my $override = {
				'FriendlyName' => $friendlyName,
				'Username' => $username,
				'IP' => $ipAddress,
				'GroupID' => 1,
				'ClassID' => $classID,
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
					prettyUndef($classID),
					prettyUndef($trafficLimitTx),
					prettyUndef($trafficLimitRx),
					prettyUndef($trafficLimitTxBurst),
					prettyUndef($trafficLimitRxBurst)
			);

			return (HTTP_TEMPORARY_REDIRECT,'configmanager');
		}
	}


	#
	# Sanitize all data we going to be using
	#

	# Handle checkboxes first and a little differently
	foreach my $item (@formElementCheckboxes) {
		$formData->{"input$item.enabled"} = defined($formData->{"input$item.enabled"}) ? "checked" : "";
	}
	# Sanitize params if we need to
	foreach my $item (@formElements) {
		$formData->{$item} = defined($formData->{$item}) ? encode_entities($formData->{$item}) : "";
	}

	# Build content
	my $content = "";

	#
	# Form header
	#
	$content .=<<EOF;
<form role="form" method="post">
	<legend>$formType Override</legend>
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
		<label for="FriendlyName" class="col-lg-2 control-label">FriendlyName</label>
		<div class="row">
			<div class="col-lg-4">
				<div class="input-group">
					<input name="FriendlyName" type="text" placeholder="Friendly Name" class="form-control" value="$formData->{'FriendlyName'}" />
					<span class="input-group-addon">*</span>
				</div>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="Username" class="col-lg-2 control-label">Username</label>
		<div class="row">
			<div class="col-lg-4">
				<input name="Username" type="text" placeholder="Username To Override" class="form-control" value="$formData->{'Username'}" $formNoEdit/>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="IP" class="col-lg-2 control-label">IP Address</label>
		<div class="row">
			<div class="col-lg-4">
				<input name="IP" type="text" placeholder="And/Or IP Address To Override" class="form-control" value="$formData->{'IP'}" $formNoEdit/>
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="ClassID" class="col-lg-2 control-label">Traffic Class</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="inputClassID.enabled" type="checkbox" $formData->{'inputClassID.enabled'}/> Override
			</div>
			<div class="col-lg-2">
				<select name="ClassID" class="form-control">
					$trafficClassStr
				</select>
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="TrafficLimitTx" class="col-lg-2 control-label">Download CIR</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="inputTrafficLimitTx.enabled" type="checkbox" $formData->{'inputTrafficLimitTx.enabled'}/> Override
			</div>

			<div class="col-lg-3">
				<div class="input-group">
					<input name="TrafficLimitTx" type="text" placeholder="Download CIR" class="form-control" value="$formData->{'TrafficLimitTx'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="TrafficLimitTxBurst" class="col-lg-2 control-label">Download Limit</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="inputTrafficLimitTxBurst.enabled" type="checkbox" $formData->{'inputTrafficLimitTxBurst.enabled'}/> Override
			</div>
			<div class="col-lg-3">
				<div class="input-group">
					<input name="TrafficLimitTxBurst" type="text" placeholder="Download Limit" class="form-control" value="$formData->{'TrafficLimitTxBurst'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="inputTrafficLimitRx" class="col-lg-2 control-label">Upload CIR</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="inputTrafficLimitRx.enabled" type="checkbox" $formData->{'inputTrafficLimitRx.enabled'}/> Override
			</div>
			<div class="col-lg-3">
				<div class="input-group">
					<input name="TrafficLimitRx" type="text" placeholder="Upload CIR" class="form-control" value="$formData->{'TrafficLimitRx'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>
	<div class="form-group">
		<label for="TrafficLimitRxBurst" class="col-lg-2 control-label">Upload Limit</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="inputTrafficLimitRxBurst.enabled" type="checkbox" $formData->{'inputTrafficLimitRxBurst.enabled'}/> Override
			</div>
			<div class="col-lg-3">
				<div class="input-group">
					<input name="TrafficLimitRxBurst" type="text" placeholder="Upload Limit" class="form-control" value="$formData->{'TrafficLimitRxBurst'}" />
					<span class="input-group-addon">Kbps<span>
				</div>
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="Expires" class="col-lg-2 control-label">Expires</label>
		<div class="row">
			<div class="col-lg-2">
				<input name="Expires" type="text" placeholder="Expires" class="form-control" value="$formData->{'Expires'}" />
			</div>
			<div class="col-lg-2">
				<select name="inputExpires.modifier" class="form-control" value="$formData->{'inputExpires.modifier'}">
					$expiresModifierStr
				</select>
			</div>
		</div>
	</div>

	<div class="form-group">
		<label for="Notes" class="col-lg-2 control-label">Notes</label>
		<div class="row">
			<div class="col-lg-4">
				<textarea name="Notes" placeholder="Notes" rows="3" class="form-control"></textarea>
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
sub override_remove
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Content to return
	my $content = "";


	# Pull in GET
	my $queryParams = parseURIQuery($request);
	# We need a key first of all...
	if (!defined($queryParams->{'oid'})) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				No override oid in query string!
			</div>
EOF
		goto END;
	}

	# Grab the override
	my $override = getOverride($queryParams->{'oid'});

	# Make the oid safe for HTML
	my $encodedID = encode_entities($queryParams->{'oid'});

	# Make sure the oid was valid... we would have an override now if it was
	if (!defined($override)) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				Invalid override oid "$encodedID"!
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
			$kernel->post("configmanager" => "process_override_remove" => $override);
		}
		return (HTTP_TEMPORARY_REDIRECT,'configmanager');
	}


	# Make the friendly name HTML safe
	my $encodedFriendlyName = encode_entities($override->{'FriendlyName'});

	# Build our confirmation dialog
	$content .= <<EOF;
		<div class="alert alert-danger">
			Are you very sure you wish to remove override "$encodedFriendlyName"?
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
