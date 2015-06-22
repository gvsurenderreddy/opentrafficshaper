# OpenTrafficShaper webserver module: limits page
# Copyright (C) 2007-2015, AllWorldIT
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
use HTTP::Status qw(
	:constants
);
use URI::Escape qw(
	uri_escape
);
use URI::QueryParam;
use Storable qw(
	dclone
);

use awitpt::util qw(
	parseURIQuery
	parseFormContent
	isUsername ISUSERNAME_ALLOW_ATSIGN
	isIPv4
	isNumber
	prettyUndef
);
use opentrafficshaper::constants;
use opentrafficshaper::logger;
use opentrafficshaper::plugins;
use opentrafficshaper::plugins::configmanager qw(
	getPools
	getPool
	getPoolByName
	getPoolShaperState
	isPoolReady

	getPoolMembers
	getPoolMember
	getAllPoolMembersByInterfaceGroupIP
	getPoolMemberShaperState
	isPoolMemberReady

	getPoolOverrides
	getPoolOverride

	getInterfaceGroup
	getInterfaceGroups
	isInterfaceGroupIDValid

	getMatchPriorities
	isMatchPriorityIDValid

	getTrafficClass
	getTrafficClasses
	isTrafficClassIDValid
);



# Sidebar menu options for this module
my $menu = [
	{
		'name' => 'Pools',
		'items' => [
			{
				'name' => 'List Pools',
				'link' => 'pool-list'
			},
			{
				'name' => 'List Manual Pools',
				'link' => 'pool-list?source=plugin.webserver.limits'
			},
			{
				'name' => 'Add Pool',
				'link' => 'pool-add'
			}
		]
	},
	{
		'name' => 'Pool Overrides',
		'items' => [
			{
				'name' => 'List Overrides',
				'link' => 'pool-override-list'
			},
			{
				'name' => 'Add Override',
				'link' => 'pool-override-add'
			}
		]
	},
	{
		'name' => 'Admin',
		'items' => [
			{
				'name' => 'Add Limit',
				'link' => 'limit-add'
			}
		]
	}
];



# Pool list page/action
sub pool_list
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	my @pools = getPools();

	# Pull in URL params
	my $queryParams = parseURIQuery($request);

	# Build content
	my $content = "";

	# Header
	$content .=<<EOF;
		<legend>Pool List</legend>
		<table class="table">
			<thead>
				<tr>
					<th></th>
					<th>Friendly Name</th>
					<th>Name</th>
					<th>Expires</th>
					<th>Members</th>
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
	foreach my $pid (@pools) {
		my $pool;
		# If we can't get the pool just move onto the next
		if (!defined($pool = getPool($pid))) {
			next;
		}

		# Conditionals
		if (defined($queryParams->{'source'})) {
			if ($pool->{'Source'} ne $queryParams->{'source'}->{'value'}) {
				next;
			}
		}

		# Get a nice last update string
		my $lastUpdate = DateTime->from_epoch( epoch => $pool->{'LastUpdate'} )->iso8601();

		my $poolCIRStr = encode_entities(sprintf('%s/%s',prettyUndef($pool->{'TxCIR'}),prettyUndef($pool->{'RxCIR'})));
		my $poolLimitStr = encode_entities(sprintf('%s/%s',prettyUndef($pool->{'TxLimit'}),prettyUndef($pool->{'RxLimit'})));
		my $poolFriendlyName = (defined($pool->{'FriendlyName'}) && $pool->{'FriendlyName'} ne "") ? $pool->{'FriendlyName'} :
				$pool->{'Name'};
		my $poolFriendlyNameEncoded = encode_entities($poolFriendlyName);

		my $poolNameEncoded = encode_entities($pool->{'Name'});

		my $poolExpiresStr = encode_entities(
				($pool->{'Expires'} > 0) ? DateTime->from_epoch( epoch => $pool->{'Expires'} )->iso8601() : '-never-'
		);

		my $poolMemberCount = getPoolMembers($pool->{'ID'});


		my $trafficClass = getTrafficClass($pool->{'TrafficClassID'});
		my $trafficClassNameEncoded = encode_entities($trafficClass->{'Name'});

		# Display relevant icons depending on pool status
		my $icons = "";
		if (getPoolShaperState($pool->{'ID'}) & SHAPER_NOTLIVE || $pool->{'Status'} == CFGM_CHANGED) {
			$icons .= '<span class="glyphicon glyphicon-time" />';
		}
		if ($pool->{'Status'} == CFGM_NEW) {
			$icons .= '<span class="glyphicon glyphicon-import" />';
		}
		if ($pool->{'Status'} == CFGM_OFFLINE) {
			$icons .= '<span class="glyphicon glyphicon-trash" />';
		}
#		if ($pool->{'Status'} eq 'conflict') {
#			$icons .= '<span class="glyphicon glyphicon-random" />';
#		}
#		if ($pool->{'Status'} eq 'conflict') {
#			$icons .= '<span class="glyphicon glyphicon-edit" />';
#		}

		my $urlStatsPool = sprintf('/statistics/by-pool?pool=%s',uri_escape("$pool->{'InterfaceGroupID'}:$pool->{'Name'}"));
		my $urlPoolEdit = sprintf('/limits/pool-edit?pid=%s',uri_escape($pool->{'ID'}));
		my $urlPoolMemberList = sprintf('/limits/poolmember-list?pid=%s',uri_escape($pool->{'ID'}));
		my $urlPoolRemove = sprintf('/limits/pool-remove?pid=%s',uri_escape($pool->{'ID'}));

		$content .= <<EOF;
				<tr>
					<td>$icons</td>
					<td>$poolFriendlyNameEncoded</td>
					<td>$poolNameEncoded</td>
					<td>$poolExpiresStr</td>
					<td class="align-right">$poolMemberCount</td>
					<td><span class="glyphicon glyphicon-arrow-right" /></td>
					<td class="align-center">$trafficClassNameEncoded</td>
					<td class="align-center">$poolCIRStr</td>
					<td class="align-center">$poolLimitStr</td>
					<td>
						<a href="$urlStatsPool"><span class="glyphicon glyphicon-stats"></span></a>
						<a href="$urlPoolEdit"><span class="glyphicon glyphicon-wrench"></span></a>
						<a href="$urlPoolMemberList"><span class="glyphicon glyphicon-link"></span></a>
						<a href="$urlPoolRemove"><span class="glyphicon glyphicon-remove"></span></a>
					</td>
				</tr>
EOF
	}

	# No results
	if (!@pools) {
		$content .=<<EOF;
				<tr class="info">
					<td colspan="10"><p class="text-center">No Results</p></td>
				</tr>
EOF
	}

	# Footer
	$content .=<<EOF;
			</tbody>
		</table>
		<span class="glyphicon glyphicon-time" /> - Processing,
		<span class="glyphicon glyphicon-edit" /> - Override,
		<span class="glyphicon glyphicon-import" /> - Being Added,
		<span class="glyphicon glyphicon-trash" /> - Being Removed,
		<span class="glyphicon glyphicon-random" /> - Conflicts
EOF

	return (HTTP_OK,$content,{ 'menu' => $menu });
}



# Pool add/edit action
sub pool_addedit
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Setup our environment
	my $logger = $globals->{'logger'};

	# Errors to display above the form
	my @errors;

	# Items for our form...
	my @formElements = qw(
		FriendlyName
		Name
		InterfaceGroupID
		TrafficClassID
		TxCIR TxLimit
		RxCIR RxLimit
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
	# If we have a pool, this is where its kept
	my $pool;

	# Get query params
	my $queryParams = parseURIQuery($request);

	# If we have a pool ID, pull in the pool
	if (defined($queryParams->{'pid'})) {
		# Check if we can grab the pool
		if (!defined($pool = getPool($queryParams->{'pid'}->{'value'}))) {
			return (HTTP_TEMPORARY_REDIRECT,"/limits");
		}
	}

	# If this is a form try parse it
	if ($request->method eq "POST") {
		# Parse form data
		my $form = parseFormContent($request->content);

		# If user pressed cancel, redirect
		if (defined($form->{'cancel'})) {
			# Redirects to default page
			return (HTTP_TEMPORARY_REDIRECT,'/limits');
		}

		# Transform form into form data
		foreach my $key (keys %{$form}) {
			$formData->{$key} = $form->{$key}->{'value'};
		}

		# Set form type if its edit
		if (defined($form->{'submit'}) && $form->{'submit'}->{'value'} eq "Edit") {
			# Check pool exists
			if (!defined($pool)) {
				return (HTTP_TEMPORARY_REDIRECT,'/limits');
			}

			$formData->{'ID'} = $pool->{'ID'};

			$formType = "Edit";
			$formNoEdit = "readonly";
		}

	# Maybe we were given a pool key as a parameter? this would be an edit form
	} elsif ($request->method eq "GET") {
		if (defined($pool)) {
			# Setup form data from pool
			foreach my $key (@formElements) {
				$formData->{$key} = $pool->{$key};
			}

			$formType = "Edit";
			$formNoEdit = "readonly";

		# Woops ... no query string?
		} elsif (keys %{$queryParams} > 0) {
			return (HTTP_TEMPORARY_REDIRECT,'/limits');
		}
	}

	# We only do this if we have hash elements
	if (ref($formData) eq "HASH") {
		# Grab friendly name
		my $friendlyName = $formData->{'FriendlyName'};

		# Check POST data
		my $name;
		if (!defined($name = isUsername($formData->{'Name'},ISUSERNAME_ALLOW_ATSIGN))) {
			push(@errors,"Name is not valid");
		}
		my $interfaceGroupID;
		if (!defined($interfaceGroupID = isInterfaceGroupIDValid($formData->{'InterfaceGroupID'}))) {
			push(@errors,"Interface group is not valid");
		}
		if ($formType ne "Edit" && getPoolByName($interfaceGroupID,$name)) {
			push(@errors,"A pool with the same name already exists");
		}
		my $trafficClassID;
		if (!defined($trafficClassID = isTrafficClassIDValid($formData->{'TrafficClassID'}))) {
			push(@errors,"Traffic class is not valid");
		}
		my $txCIR = isNumber($formData->{'TxCIR'});
		my $txLimit = isNumber($formData->{'TxLimit'});
		if (!defined($txCIR) && !defined($txLimit)) {
			push(@errors,"A valid download CIR and/or limit is required");
		}
		my $rxCIR = isNumber($formData->{'RxCIR'});
		my $rxLimit = isNumber($formData->{'RxLimit'});
		if (!defined($rxCIR) && !defined($rxLimit)) {
			push(@errors,"A valid upload CIR and/or limit is required");
		}

		# Make sure pool is not transitioning states
		if ($formType eq "Edit") {
			if (!isPoolReady($pool->{'ID'})) {
				push(@errors,"Pool is not currently in a READY state, please try again");
			}
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
			# Build pool details
			my $poolData = {
				'FriendlyName' => $friendlyName,
				'Name' => $name,
				'InterfaceGroupID' => $interfaceGroupID,
				'TrafficClassID' => $trafficClassID,
				'TxCIR' => $txCIR,
				'TxLimit' => $txLimit,
				'RxCIR' => $rxCIR,
				'RxLimit' => $rxLimit,
				'Expires' => $expires,
				'Notes' => $notes,
			};

			my $cEvent;
			if ($formType eq "Add") {
				$poolData->{'Status'} = CFGM_ONLINE;
				$poolData->{'Source'} = 'plugin.webserver.limits';
				$cEvent = "pool_add";
			} else {
				$poolData->{'ID'} = $formData->{'ID'};
				$cEvent = "pool_change";
			}

			$kernel->post("configmanager" => $cEvent => $poolData);

			$logger->log(LOG_INFO,"[WEBSERVER/LIMITS] Pool: %s, Name: %s, InterfaceGroup: %s, Class: %s, Limits: %s/%s, ".
					"Burst: %s/%s",
					$formType,
					prettyUndef($name),
					prettyUndef($interfaceGroupID),
					prettyUndef($trafficClassID),
					prettyUndef($txCIR),
					prettyUndef($rxCIR),
					prettyUndef($txLimit),
					prettyUndef($rxLimit)
			);

			return (HTTP_TEMPORARY_REDIRECT,'/limits');
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
		<legend>$formType Pool</legend>
		<form role="form" method="post">
EOF

	# Spit out errors if we have any
	if (@errors > 0) {
		foreach my $error (@errors) {
			$content .= '<div class="alert alert-danger">'.encode_entities($error).'</div>';
		}
	}

	# Generate interface group list
	my @interfaceGroups = sort(getInterfaceGroups());
	my $interfaceGroupStr = "";
	foreach my $interfaceGroupID (@interfaceGroups) {
		my $interfaceGroup = getInterfaceGroup($interfaceGroupID);
		my $interfaceGroupIDEncoded = encode_entities($interfaceGroupID);
		my $interfaceGroupNameEncoded = encode_entities($interfaceGroup->{'Name'});

		# Check if this item is selected
		my $selected = "";
		if ($formData->{'InterfaceGroupID'} ne "" && $formData->{'InterfaceGroupID'} eq $interfaceGroupID) {
			$selected = "selected";
		}

		# And build the options
		$interfaceGroupStr .= '<option value="'.$interfaceGroupIDEncoded.'" '.$selected.'>'.
				$interfaceGroupNameEncoded.'</option>';
	}

	# Generate traffic class list
	my @trafficClasses = sort(getTrafficClasses());
	my $trafficClassStr = "";
	foreach my $trafficClassID (@trafficClasses) {
		my $trafficClass = getTrafficClass($trafficClassID);
		my $trafficClassIDEncoded = encode_entities($trafficClassID);
		my $trafficClassNameEncoded = encode_entities($trafficClass->{'Name'});
		# Process selections nicely
		my $selected = "";
		if ($formData->{'TrafficClassID'} ne "" && $formData->{'TrafficClassID'} eq $trafficClassID) {
			$selected = "selected";
		}
		# And build the options
		$trafficClassStr .= '<option value="'.$trafficClassIDEncoded.'" '.$selected.'>'.$trafficClassNameEncoded.'</option>';
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
		$expiresModifierStr .= '<option value="'.$expireModifier.'" '.$selected.'>'.
				encode_entities($expiresModifiers->{$expireModifier}).'</option>';
	}

	# Blank expires if its 0
	if (defined($formData->{'Expires'}) && $formData->{'Expires'} eq "0") {
		$formData->{'Expires'} = "";
	}

	# Page content
	$content .=<<EOF;
			<div class="form-group">
				<label for="FriendlyName" class="col-md-2 control-label">Friendly Name</label>
				<div class="row">
					<div class="col-md-4 input-group">
						<input name="FriendlyName" type="text" placeholder="Opt. Friendly Name" class="form-control"
								value="$formData->{'FriendlyName'}" />
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="Name" class="col-md-2 control-label">Name</label>
				<div class="row">
					<div class="col-md-4 input-group">
						<input name="Name" type="text" placeholder="Name" class="form-control"
								value="$formData->{'Name'}" $formNoEdit />
						<span class="input-group-addon">*</span>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="InterfaceGroupID" class="col-md-2 control-label">Interface Group</label>
				<div class="row">
					<div class="col-md-2">
						<select name="InterfaceGroupID" class="form-control" $formNoEdit>
							$interfaceGroupStr
						</select>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="TrafficClassID" class="col-md-2 control-label">Traffic Class</label>
				<div class="row">
					<div class="col-md-2">
						<select name="TrafficClassID" class="form-control">
							$trafficClassStr
						</select>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="TxCIR" class="col-md-2 control-label">Download CIR</label>
				<div class="row">
					<div class="col-md-3">
						<div class="input-group">
							<input name="TxCIR" type="text" placeholder="Download CIR" class="form-control"
									value="$formData->{'TxCIR'}" />
							<span class="input-group-addon">Kbps *<span>
						</div>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="TxLimit" class="col-md-2 control-label">Download Limit</label>
				<div class="row">
					<div class="col-md-3">
						<div class="input-group">
							<input name="TxLimit" type="text" placeholder="Download Limit" class="form-control"
									value="$formData->{'TxLimit'}" />
							<span class="input-group-addon">Kbps<span>
						</div>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="RxCIR" class="col-md-2 control-label">Upload CIR</label>
				<div class="row">
					<div class="col-md-3">
						<div class="input-group">
							<input name="RxCIR" type="text" placeholder="Upload CIR" class="form-control"
									value="$formData->{'RxCIR'}" />
							<span class="input-group-addon">Kbps *<span>
						</div>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="RxLimit" class="col-md-2 control-label">Upload Limit</label>
				<div class="row">
					<div class="col-md-3">
						<div class="input-group">
							<input name="RxLimit" type="text" placeholder="Upload Limit" class="form-control"
									value="$formData->{'RxLimit'}" />
							<span class="input-group-addon">Kbps<span>
						</div>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="Expires" class="col-md-2 control-label">Expires</label>
				<div class="row">
					<div class="col-md-2">
						<input name="Expires" type="text" placeholder="Optional" class="form-control"
								value="$formData->{'Expires'}" />
					</div>
					<div class="col-md-2">
						<select name="inputExpires.modifier" class="form-control" value="$formData->{'inputExpires.modifier'}">
							$expiresModifierStr
						</select>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="Notes" class="col-md-2 control-label">Notes</label>
				<div class="row">
					<div class="col-md-4">
						<textarea name="Notes" placeholder="Opt. Notes" rows="3"
								class="form-control">$formData->{'Notes'}</textarea>
					</div>
				</div>
			</div>
			<div class="form-group">
				<button name="submit" type="submit" value="$formType" class="btn btn-primary">$formType</button>
				<button name="cancel" type="submit" class="btn">Cancel</button>
			</div>
		</form>
EOF

	return (HTTP_OK,$content,{ 'menu' => $menu });
}



# Pool remove action
sub pool_remove
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Content to return
	my $content = "";


	# Pull in query data
	my $queryParams = parseURIQuery($request);
	# We need a key first of all...
	if (!defined($queryParams->{'pid'})) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				No pool ID in query string!
			</div>
EOF
		goto END;
	}

	# Grab the pool
	my $pool = getPool($queryParams->{'pid'}->{'value'});

	# Make sure the pool ID is valid... we would have a pool now if it was
	if (!defined($pool)) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				Invalid pool ID!
			</div>
EOF
		goto END;
	}

	# Make sure its a manual pool we're removing
	if ($pool->{'Source'} ne "plugin.webserver.limits") {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				Only manual pools can be removed!
			</div>
EOF
		goto END;
	}

	# Pull in POST
	my $form = parseFormContent($request->content);

	# If this is a post, then its probably a confirmation
	if (defined($form->{'confirm'})) {
		# Check if its a success
		if ($form->{'confirm'}->{'value'} eq "Yes") {
			# Post the removal
			$kernel->post("configmanager" => "pool_remove" => $pool->{'ID'});
		}
		return (HTTP_TEMPORARY_REDIRECT,'/limits');
	}

	# Make the friendly name HTML safe
	my $encodedPoolName = encode_entities($pool->{'Name'});

	# Build our confirmation dialog
	$content .= <<EOF;
		<div class="alert alert-danger">
			Are you very sure you wish to remove pool for "$encodedPoolName"?
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



# Pool member list page/action
sub poolmember_list
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Build content
	my $content = "";
	# Build custom menu
	my $customMenu = $menu;


	# Pull in query params
	my $queryParams = parseURIQuery($request);
	# We need a key first of all...
	if (!defined($queryParams->{'pid'})) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				No pool ID in query string!
			</div>
EOF
		goto END;
	}

	# Grab the pool
	my $pool = getPool($queryParams->{'pid'}->{'value'});

	# If pool is not defined, it means we got an invalid pool ID
	if (!defined($pool)) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				Invalid pool ID!
			</div>
EOF
		goto END;
	}

	# Grab pools members
	my @poolMembers = getPoolMembers($pool->{'ID'});

	my $poolFriendlyName = (defined($pool->{'FriendlyName'}) && $pool->{'FriendlyName'} ne "") ? $pool->{'FriendlyName'} :
			$pool->{'Name'};
	my $poolFriendlyNameEncoded = encode_entities($poolFriendlyName);
	my $poolNameEncoded = encode_entities($pool->{'Name'});

	my $urlPoolMemberAdd = sprintf('poolmember-add?pid=%s',uri_escape($pool->{'ID'}));

	# Menu
	$customMenu = [
		{
			'name' => 'Pool Members',
			'items' => [
				{
					'name' => 'Add Pool Member',
					'link' => $urlPoolMemberAdd
				},
			],
		},
		@{$menu}
	];
	# Header
	$content .=<<EOF;
		<legend>
			<a href="pool-list"><span class="glyphicon glyphicon-circle-arrow-left"></span></a>
			Pool Member List: '$poolFriendlyNameEncoded' [$poolNameEncoded]
		</legend>
		<table class="table">
			<thead>
				<tr>
					<th></th>
					<th>Friendly Name</th>
					<th>Username</th>
					<th>IP</th>
					<th>Created</th>
					<th>Updated</th>
					<th>Expires</th>
					<th></th>
				</tr>
			</thead>
			<tbody>
EOF
	# Body
	foreach my $pmid (@poolMembers) {
		my $poolMember;
		# If we can't get the pool member just move onto the next
		if (!defined($poolMember = getPoolMember($pmid))) {
			next;
		}

		# Get a nice last update string
		my $poolMemberFriendlyName = (defined($poolMember->{'FriendlyName'}) && $poolMember->{'FriendlyName'} ne "") ?
				$poolMember->{'FriendlyName'} : $poolMember->{'Username'};
		my $poolMemberFriendlyNameEncoded = encode_entities($poolMemberFriendlyName);

		my $poolMemberUsernameEncoded = encode_entities($poolMember->{'Username'});

		my $poolMemberIPEncoded = encode_entities($poolMember->{'IPAddress'});

		my $poolMemberCreatedStr = encode_entities(($poolMember->{'Created'} > 0) ?
				DateTime->from_epoch( epoch => $poolMember->{'Created'} )->iso8601() : '-never-');
		my $poolMemberUpdatedStr = encode_entities(($poolMember->{'LastUpdate'} > 0) ?
				DateTime->from_epoch( epoch => $poolMember->{'LastUpdate'} )->iso8601() : '-never-');
		my $poolMemberExpiresStr = encode_entities(($poolMember->{'Expires'} > 0) ?
				DateTime->from_epoch( epoch => $poolMember->{'Expires'} )->iso8601() : '-never-');

		my $poolMemberShaperState = getPoolMemberShaperState($poolMember->{'ID'});

		# Display relevant icons depending on pool status
		my $icons = "";
		if (!($poolMemberShaperState & SHAPER_LIVE)) {
			$icons .= '<span class="glyphicon glyphicon-time" />';
		}
		if ($poolMember->{'Status'} == CFGM_NEW) {
			$icons .= '<span class="glyphicon glyphicon-import" />';
		}
		if ($poolMember->{'Status'} == CFGM_OFFLINE) {
			$icons .= '<span class="glyphicon glyphicon-trash" />';
		}
		if ($poolMemberShaperState & SHAPER_CONFLICT) {
			$icons .= '<span class="glyphicon glyphicon-random" />';
		}

		my $urlPoolMemberEdit = sprintf('/limits/poolmember-edit?pmid=%s',uri_escape($poolMember->{'ID'}));
		my $urlPoolMemberRemove = sprintf('/limits/poolmember-remove?pmid=%s',uri_escape($poolMember->{'ID'}));

		$content .= <<EOF;
				<tr>
					<td>$icons</td>
					<td>$poolMemberFriendlyNameEncoded</td>
					<td>$poolMemberUsernameEncoded</td>
					<td>$poolMemberIPEncoded</td>
					<td>$poolMemberCreatedStr</td>
					<td>$poolMemberUpdatedStr</td>
					<td>$poolMemberExpiresStr</td>
					<td>
						<a href="$urlPoolMemberEdit"><span class="glyphicon glyphicon-wrench"></span></a>
						<a href="$urlPoolMemberRemove"><span class="glyphicon glyphicon-remove"></span></a>
					</td>
				</tr>
EOF
	}

	# No results
	if (!@poolMembers) {
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
		<span class="glyphicon glyphicon-time" /> - Processing,
		<span class="glyphicon glyphicon-edit" /> - Override,
		<span class="glyphicon glyphicon-import" /> - Being Added,
		<span class="glyphicon glyphicon-trash" /> - Being Removed,
		<span class="glyphicon glyphicon-random" /> - Conflicts
EOF

END:
	return (HTTP_OK,$content,{ 'menu' => $customMenu });
}



# Pool member add/edit action
sub poolmember_addedit
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Setup our environment
	my $logger = $globals->{'logger'};

	# Errors to display above the form
	my @errors;

	# Items for our form...
	my @formElements = qw(
		FriendlyName
		Username IPAddress
		MatchPriorityID
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
	# Pool
	my $pool;
	my $poolMember;


	# Parse query params
	my $queryParams = parseURIQuery($request);

	# If we have a pool member ID, pull in the pool member
	if (defined($queryParams->{'pmid'})) {
		# Check if we can grab the pool member
		if (!defined($poolMember = getPoolMember($queryParams->{'pmid'}->{'value'}))) {
			return (HTTP_TEMPORARY_REDIRECT,"/limits");
		}

		$pool = getPool($poolMember->{'PoolID'});

	# If we have a pool ID, pull in the pool
	} elsif (defined($queryParams->{'pid'})) {
		# Check if we can grab the pool
		if (!defined($pool = getPool($queryParams->{'pid'}->{'value'}))) {
			return (HTTP_TEMPORARY_REDIRECT,"/limits");
		}
	}

	# If this is a form try parse it
	if ($request->method eq "POST") {
		# Parse form data
		my $form = parseFormContent($request->content);

		# If user pressed cancel, redirect
		if (defined($form->{'cancel'})) {
			# If the pool member is defined, rededirect to pool member list
			if (defined($poolMember)) {
				return (HTTP_TEMPORARY_REDIRECT,sprintf('/limits/poolmember-list?pid=%s',$pool->{'IID'}));
			# Do same for pool
			} elsif (defined($pool)) {
				return (HTTP_TEMPORARY_REDIRECT,sprintf('/limits/poolmember-list?pid=%s',$pool->{'IID'}));
			}

			return (HTTP_TEMPORARY_REDIRECT,'/limits');
		}

		# Transform form into form data
		foreach my $key (keys %{$form}) {
			$formData->{$key} = $form->{$key}->{'value'};
		}

		# Set form type if its edit
		if (defined($form->{'submit'}) && $form->{'submit'}->{'value'} eq "Edit") {
			# If there is no pool member on submit, redirect<F7>
			if (!defined($poolMember)) {
				return (HTTP_TEMPORARY_REDIRECT,'/limits');
			}

			$formData->{'ID'} = $poolMember->{'ID'};

			$formType = "Edit";
			$formNoEdit = "readonly";
		}

	# Maybe we were given a pool override key as a parameter? this would be an edit form
	} elsif ($request->method eq "GET") {
		# If we got a pool member, this is an edit
		if (defined($poolMember)) {
			# Setup form data from pool member
			foreach my $key (@formElements) {
				$formData->{$key} = $poolMember->{$key};
			}

			# Lastly if we were given a key, this is actually an edit
			$formType = "Edit";
			$formNoEdit = "readonly";

		# Woops ... no query string?
		} elsif (!defined($pool)) {
			return (HTTP_TEMPORARY_REDIRECT,'/limits');
		}
	}

	if (ref($formData) eq "HASH") {
		# Grab friendly name
		my $friendlyName = $formData->{'FriendlyName'};

		# Check POST data
		my $username;
		if (!defined($username = isUsername($formData->{'Username'},ISUSERNAME_ALLOW_ATSIGN))) {
			push(@errors,"Username is not valid");
		}
		my $ipAddress;
		if (!defined($ipAddress = isIPv4($formData->{'IPAddress'}))) {
			push(@errors,"IP address is not valid");
		}
		my $matchPriorityID;
		if (!defined($matchPriorityID = isMatchPriorityIDValid($formData->{'MatchPriorityID'}))) {
			push(@errors,"Match priority is not valid");
		}

		if ($formType eq "Add") {
			if (getAllPoolMembersByInterfaceGroupIP($pool->{'InterfaceGroupID'},$ipAddress)) {
				push(@errors,"A pool member with the same IP address already exists");
			}
		} elsif ($formType eq "Edit") {
			if (!isPoolMemberReady($poolMember->{'ID'})) {
				push(@errors,"Pool member is not currently in a READY state, please try again");
			}
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
			my $poolMemberData = {
				'FriendlyName' => $friendlyName,
				'Username' => $username,
				'IPAddress' => $ipAddress,
				'GroupID' => 1,
				'MatchPriorityID' => $matchPriorityID,
				'Expires' => $expires,
				'Notes' => $notes,
			};

			my $cEvent;
			if ($formType eq "Add") {
				$poolMemberData->{'PoolID'} = $pool->{'ID'};
				$poolMemberData->{'Source'} = 'plugin.webserver.limits';
				$cEvent = "poolmember_add";
			} else {
				$poolMemberData->{'ID'} = $poolMember->{'ID'};
				$cEvent = "poolmember_change";
			}

			$kernel->post("configmanager" => $cEvent => $poolMemberData);

			$logger->log(LOG_INFO,'[WEBSERVER/POOLMEMBER] Account: %s, User: %s, IP: %s, Group: %s, MatchPriority: %s, Pool: %s',
					$formType,
					prettyUndef($username),
					prettyUndef($ipAddress),
					prettyUndef(undef),
					prettyUndef($matchPriorityID),
					prettyUndef($pool->{'ID'}),
			);

			return (HTTP_TEMPORARY_REDIRECT,sprintf('/limits/poolmember-list?pid=%s',$pool->{'ID'}));
		}
	}

	# Sanitize params if we need to
	foreach my $item (@formElements) {
		$formData->{$item} = defined($formData->{$item}) ? encode_entities($formData->{$item}) : "";
	}

	my $pidEscaped = uri_escape($pool->{'ID'});

	# Build content
	my $content = "";
	# Menu
	my $customMenu = [
		{
			'name' => 'Pool Members',
			'items' => [
				{
					'name' => 'Add Pool Member',
					'link' => "poolmember-add?pid=$pidEscaped",
				},
			],
		},
		@{$menu}
	];


	# Form header
	$content .=<<EOF;
		<legend>$formType Pool Member</legend>
		<form role="form" method="post">
EOF

	# Spit out errors if we have any
	if (@errors > 0) {
		foreach my $error (@errors) {
			$content .= '<div class="alert alert-danger">'.encode_entities($error).'</div>';
		}
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
		$matchPriorityStr .= '<option value="'.$matchPriorityID.'" '.$selected.'>'.$matchPriorities->{$matchPriorityID}.
				'</option>';
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
		$expiresModifierStr .= '<option value="'.$expireModifier.'" '.$selected.'>'.
				encode_entities($expiresModifiers->{$expireModifier}).'</option>';
	}

	# Blank expires if its 0
	if (defined($formData->{'Expires'}) && $formData->{'Expires'} eq "0") {
		$formData->{'Expires'} = "";
	}

	# Page content
	$content .=<<EOF;
			<div class="form-group">
				<label for="FriendlyName" class="col-md-2 control-label">Friendly Name</label>
				<div class="row">
					<div class="col-md-4 input-group">
						<input name="FriendlyName" type="text" placeholder="Opt. Friendly Name" class="form-control"
								value="$formData->{'FriendlyName'}" />
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="Username" class="col-md-2 control-label">Username</label>
				<div class="row">
					<div class="col-md-4 input-group">
						<input name="Username" type="text" placeholder="Username" class="form-control"
								value="$formData->{'Username'}" $formNoEdit />
						<span class="input-group-addon">*</span>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="IPAddress" class="col-md-2 control-label">IP Address</label>
				<div class="row">
					<div class="col-md-4 input-group">
						<input name="IPAddress" type="text" placeholder="IP Address" class="form-control"
								value="$formData->{'IPAddress'}" $formNoEdit />
						<span class="input-group-addon">*</span>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="MatchPriorityID" class="col-md-2 control-label">Match Priority</label>
				<div class="row">
					<div class="col-md-2">
						<select name="MatchPriorityID" class="form-control" $formNoEdit>
							$matchPriorityStr
						</select>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="Expires" class="col-md-2 control-label">Expires</label>
				<div class="row">
					<div class="col-md-2">
						<input name="Expires" type="text" placeholder="Optional" class="form-control"
								value="$formData->{'Expires'}" />
					</div>
					<div class="col-md-2">
						<select name="inputExpires.modifier" class="form-control" value="$formData->{'inputExpires.modifier'}">
							$expiresModifierStr
						</select>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="Notes" class="col-md-2 control-label">Notes</label>
				<div class="row">
					<div class="col-md-4">
						<textarea name="Notes" placeholder="Opt. Notes" rows="3"
								class="form-control">$formData->{'Notes'}</textarea>
					</div>
				</div>
			</div>
			<div class="form-group">
				<button name="submit" type="submit" value="$formType" class="btn btn-primary">$formType</button>
				<button name="cancel" type="submit" class="btn">Cancel</button>
			</div>
		</form>
EOF

	return (HTTP_OK,$content,{ 'menu' => $customMenu });
}



# Pool member remove action
sub poolmember_remove
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Content to return
	my $content = "";
	# Build custom menu
	my $customMenu = $menu;

	# Pull in query params
	my $queryParams = parseURIQuery($request);
	# We need a key first of all...
	if (!defined($queryParams->{'pmid'})) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				No pool member ID in query string!
			</div>
EOF
		goto END;
	}

	# Grab the pool
	my $poolMember = getPoolMember($queryParams->{'pmid'}->{'value'});

	# If we don't have a pool member it means the ID we got is invalid
	if (!defined($poolMember)) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				Invalid pool member ID!
			</div>
EOF
		goto END;
	}

	# Make the pool ID safe for HTML
	my $urlPoolMemberAdd = sprintf('/limits/poolmember-add?pid=%s',encode_entities($poolMember->{'PoolID'}));

	# Menu
	$customMenu = [
		{
			'name' => 'Pool Members',
			'items' => [
				{
					'name' => 'Add Pool Member',
					'link' => $urlPoolMemberAdd
				},
			],
		},
		@{$menu}
	];

	# Pull in POST
	my $form = parseFormContent($request->content);

	# If this is a post, then its probably a confirmation
	if (defined($form->{'confirm'})) {
		# Check if its a success
		if ($form->{'confirm'}->{'value'} eq "Yes") {
			# Post the removal
			$kernel->post("configmanager" => "poolmember_remove" => $poolMember->{'ID'});
		}
		return (HTTP_TEMPORARY_REDIRECT,sprintf('/limits/poolmember-list?pid=%s',$poolMember->{'PoolID'}));
	}

	# Make the friendly name HTML safe
	my $poolMemberFriendlyName = (defined($poolMember->{'FriendlyName'}) && $poolMember->{'FriendlyName'} ne "") ?
			$poolMember->{'FriendlyName'} : $poolMember->{'Username'};
	my $poolMemberFriendlyNameEncoded = encode_entities($poolMemberFriendlyName);
	my $poolMemberUsernameEncoded = encode_entities($poolMember->{'Username'});

	# Build our confirmation dialog
	$content .= <<EOF;
		<div class="alert alert-danger">
			Are you very sure you wish to remove pool member "$poolMemberFriendlyNameEncoded" [$poolMemberUsernameEncoded]?
		</div>
		<form role="form" method="post">
			<input type="submit" class="btn btn-primary" name="confirm" value="Yes" />
			<input type="submit" class="btn btn-default" name="confirm" value="No" />
		</form>
EOF
	# And here is where we return
END:
	return (HTTP_OK,$content,{ 'menu' => $customMenu });
}



# Add action
sub limit_add
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Setup our environment
	my $logger = $globals->{'logger'};

	# Errors to display above the form
	my @errors;

	# Items for our form...
	my @formElements = qw(
		FriendlyName
		Username IPAddress
		InterfaceGroupID
		MatchPriorityID
		TrafficClassID
		TxCIR TxLimit
		RxCIR RxLimit
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


	# Form data
	my $formData;

	# If this is a form try parse it
	if ($request->method eq "POST") {
		# Parse form data
		my $form = parseFormContent($request->content);

		# If user pressed cancel, redirect
		if (defined($form->{'cancel'})) {
			# Redirects to default page
			return (HTTP_TEMPORARY_REDIRECT,'/limits');
		}

		# Transform form into form data
		foreach my $key (keys %{$form}) {
			$formData->{$key} = $form->{$key}->{'value'};
		}
	}

	# We only do this if we have hash elements
	if (ref($formData) eq "HASH") {
		# Grab friendly name
		my $friendlyName = $formData->{'FriendlyName'};

		# Check POST data
		my $username;
		if (!defined($username = isUsername($formData->{'Username'},ISUSERNAME_ALLOW_ATSIGN))) {
			push(@errors,"Username is not valid");
		}
		my $ipAddress;
		if (!defined($ipAddress = isIPv4($formData->{'IPAddress'}))) {
			push(@errors,"IP address is not valid");
		}
		my $interfaceGroupID;
		if (!defined($interfaceGroupID = isInterfaceGroupIDValid($formData->{'InterfaceGroupID'}))) {
			push(@errors,"Interface group is not valid");
		}
		my $matchPriorityID;
		if (!defined($matchPriorityID = isMatchPriorityIDValid($formData->{'MatchPriorityID'}))) {
			push(@errors,"Match priority is not valid");
		}
		my $trafficClassID;
		if (!defined($trafficClassID = isTrafficClassIDValid($formData->{'TrafficClassID'}))) {
			push(@errors,"Traffic class is not valid");
		}
		my $txCIR = isNumber($formData->{'TxCIR'});
		my $txLimit = isNumber($formData->{'TxLimit'});
		if (!defined($txCIR) && !defined($txLimit)) {
			push(@errors,"A valid download CIR and/or limit is required");
		}
		my $rxCIR = isNumber($formData->{'RxCIR'});
		my $rxLimit = isNumber($formData->{'RxLimit'});
		if (!defined($rxCIR) && !defined($rxLimit)) {
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
				'IPAddress' => $ipAddress,
				'GroupID' => 1,
				'InterfaceGroupID' => $interfaceGroupID,
				'MatchPriorityID' => $matchPriorityID,
				'TrafficClassID' => $trafficClassID,
				'TxCIR' => $txCIR,
				'TxLimit' => $txLimit,
				'RxCIR' => $rxCIR,
				'RxLimit' => $rxLimit,
				'Expires' => $expires,
				'Notes' => $notes,
			};

			# Throw the change at the config manager after we add extra data we need
			$limit->{'Status'} = CFGM_ONLINE;
			$limit->{'Source'} = 'plugin.webserver.limits';

			$kernel->post("configmanager" => "limit_add" => $limit);

			$logger->log(LOG_INFO,"[WEBSERVER/LIMITS] New User: %s, IP: %s, Group: %s, InterfaceGroup: %s, MatchPriority: %s, ".
					"Class: %s, Limits: %s/%s, Burst: %s/%s",
					prettyUndef($username),
					prettyUndef($ipAddress),
					prettyUndef(undef),
					prettyUndef($interfaceGroupID),
					prettyUndef($matchPriorityID),
					prettyUndef($trafficClassID),
					prettyUndef($txCIR),
					prettyUndef($rxCIR),
					prettyUndef($txLimit),
					prettyUndef($rxLimit)
			);

			return (HTTP_TEMPORARY_REDIRECT,'/limits');
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
		<legend>Add Limit</legend>
		<form role="form" method="post">
EOF

	# Spit out errors if we have any
	if (@errors > 0) {
		foreach my $error (@errors) {
			$content .= '<div class="alert alert-danger">'.encode_entities($error).'</div>';
		}
	}

	# Generate interface group list
	my @interfaceGroups = sort(getInterfaceGroups());
	my $interfaceGroupStr = "";
	foreach my $interfaceGroupID (@interfaceGroups) {
		my $interfaceGroup = getInterfaceGroup($interfaceGroupID);

		# Process selections nicely
		my $selected = "";
		if ($formData->{'InterfaceGroupID'} ne "" && $formData->{'InterfaceGroupID'} eq $interfaceGroupID) {
			$selected = "selected";
		}
		# And build the options
		$interfaceGroupStr .= '<option value="'.encode_entities($interfaceGroupID).'" '.$selected.'>'.
				encode_entities($interfaceGroup->{'Name'}).'</option>';
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
		$matchPriorityStr .= '<option value="'.encode_entities($matchPriorityID).'" '.$selected.'>'.
				encode_entities($matchPriorities->{$matchPriorityID}).'</option>';
	}

	# Generate traffic class list
	my @trafficClasses = sort(getTrafficClasses());
	my $trafficClassStr = "";
	foreach my $trafficClassID (@trafficClasses) {
		my $trafficClass = getTrafficClass($trafficClassID);

		# Process selections nicely
		my $selected = "";
		if ($formData->{'TrafficClassID'} ne "" && $formData->{'TrafficClassID'} eq $trafficClassID) {
			$selected = "selected";
		}
		# And build the options
		$trafficClassStr .= '<option value="'.encode_entities($trafficClassID).'" '.$selected.'>'.
				encode_entities($trafficClass->{'Name'}).'</option>';
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
		$expiresModifierStr .= '<option value="'.$expireModifier.'" '.$selected.'>'.
				encode_entities($expiresModifiers->{$expireModifier}).'</option>';
	}

	# Blank expires if its 0
	if (defined($formData->{'Expires'}) && $formData->{'Expires'} eq "0") {
		$formData->{'Expires'} = "";
	}

	# Page content
	$content .=<<EOF;
			<div class="form-group">
				<label for="FriendlyName" class="col-md-2 control-label">Friendly Name</label>
				<div class="row">
					<div class="col-md-4 input-group">
						<input name="FriendlyName" type="text" placeholder="Opt. Friendly Name" class="form-control"
								value="$formData->{'FriendlyName'}" />
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="Username" class="col-md-2 control-label">Username</label>
				<div class="row">
					<div class="col-md-4 input-group">
						<input name="Username" type="text" placeholder="Username" class="form-control"
								value="$formData->{'Username'}" />
						<span class="input-group-addon">*</span>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="IPAddress" class="col-md-2 control-label">IP Address</label>
				<div class="row">
					<div class="col-md-4 input-group">
						<input name="IPAddress" type="text" placeholder="IP Address" class="form-control"
								value="$formData->{'IPAddress'}" />
						<span class="input-group-addon">*</span>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="InterfaceGroupID" class="col-md-2 control-label">Interface Group</label>
				<div class="row">
					<div class="col-md-2">
						<select name="InterfaceGroupID" class="form-control">
							$interfaceGroupStr
						</select>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="MatchPriorityID" class="col-md-2 control-label">Match Priority</label>
				<div class="row">
					<div class="col-md-2">
						<select name="MatchPriorityID" class="form-control">
							$matchPriorityStr
						</select>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="TrafficClassID" class="col-md-2 control-label">Traffic Class</label>
				<div class="row">
					<div class="col-md-2">
						<select name="TrafficClassID" class="form-control">
							$trafficClassStr
						</select>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="Expires" class="col-md-2 control-label">Expires</label>
				<div class="row">
					<div class="col-md-2">
						<input name="Expires" type="text" placeholder="Optional" class="form-control"
								value="$formData->{'Expires'}" />
					</div>
					<div class="col-md-2">
						<select name="inputExpires.modifier" class="form-control" value="$formData->{'inputExpires.modifier'}">
							$expiresModifierStr
						</select>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="TxCIR" class="col-md-2 control-label">Download CIR</label>
				<div class="row">
					<div class="col-md-3">
						<div class="input-group">
							<input name="TxCIR" type="text" placeholder="Download CIR" class="form-control"
									value="$formData->{'TxCIR'}" />
							<span class="input-group-addon">Kbps *<span>
						</div>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="TxLimit" class="col-md-2 control-label">Download Limit</label>
				<div class="row">
					<div class="col-md-3">
						<div class="input-group">
							<input name="TxLimit" type="text" placeholder="Download Limit" class="form-control"
									value="$formData->{'TxLimit'}" />
							<span class="input-group-addon">Kbps<span>
						</div>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="RxCIR" class="col-md-2 control-label">Upload CIR</label>
				<div class="row">
					<div class="col-md-3">
						<div class="input-group">
							<input name="RxCIR" type="text" placeholder="Upload CIR" class="form-control"
									value="$formData->{'RxCIR'}" />
							<span class="input-group-addon">Kbps *<span>
						</div>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="RxLimit" class="col-md-2 control-label">Upload Limit</label>
				<div class="row">
					<div class="col-md-3">
						<div class="input-group">
							<input name="RxLimit" type="text" placeholder="Upload Limit" class="form-control"
									value="$formData->{'RxLimit'}" />
							<span class="input-group-addon">Kbps<span>
						</div>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="Notes" class="col-md-2 control-label">Notes</label>
				<div class="row">
					<div class="col-md-4">
						<textarea name="Notes" placeholder="Opt. Notes" rows="3"
								class="form-control">$formData->{'Notes'}</textarea>
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



# Pool override list
sub pool_override_list
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	my @poolOverrides = getPoolOverrides();

	# Build content
	my $content = "";

	# Header
	$content .=<<EOF;
		<legend>Pool Override List</legend>
		<table class="table">
			<thead>
				<tr>
					<th></th>
					<th>Friendly Name</th>
					<th>Pool</th>
					<th>User</th>
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
	foreach my $poid (@poolOverrides) {
		my $poolOverride;
		# If we can't get the pool override, just skip it
		if (!defined($poolOverride = getPoolOverride($poid))) {
			next;
		}

		my $poolOverrideFriendlyNameEncoded = encode_entities(prettyUndef($poolOverride->{'FriendlyName'}));
		my $poolOverridePoolNameEncoded = encode_entities(prettyUndef($poolOverride->{'PoolName'}));
		my $poolOverrideUsernameEncoded = encode_entities(prettyUndef($poolOverride->{'Username'}));
		my $poolOverrideIPAddressEncoded = encode_entities(prettyUndef($poolOverride->{'IPAddress'}));
		my $poolOverrideExpiresStr = encode_entities(
				($poolOverride->{'Expires'} > 0) ?
						DateTime->from_epoch( epoch => $poolOverride->{'Expires'} )->iso8601() : '-never-'
		);

		my $poolOverrideTrafficClassStr = "-undef-";
		if (defined($poolOverride->{'TrafficClassID'})) {
			my $trafficClass = getTrafficClass($poolOverride->{'TrafficClassID'});
			$poolOverrideTrafficClassStr = encode_entities($trafficClass->{'Name'});
		}

		my $poolOverrideCIRStr = encode_entities(
			sprintf('%s/%s',prettyUndef($poolOverride->{'TxCIR'}),prettyUndef($poolOverride->{'RxCIR'}))
		);
		my $poolOverrideLimitStr = encode_entities(
			sprintf('%s/%s',prettyUndef($poolOverride->{'TxLimit'}),prettyUndef($poolOverride->{'RxLimit'}))
		);

		my $urlPoolOverrideEdit = sprintf('/limits/pool-override-edit?poid=%s',encode_entities($poolOverride->{'ID'}));
		my $urlPoolOverrideRemove = sprintf('/limits/pool-override-remove?poid=%s',encode_entities($poolOverride->{'ID'}));

		$content .= <<EOF;
				<tr>
					<td></td>
					<td>$poolOverrideFriendlyNameEncoded</td>
					<td>$poolOverridePoolNameEncoded</td>
					<td>$poolOverrideUsernameEncoded</td>
					<td>$poolOverrideIPAddressEncoded</td>
					<td>$poolOverrideExpiresStr</td>
					<td><span class="glyphicon glyphicon-arrow-right" /></td>
					<td class="align-center">$poolOverrideTrafficClassStr</td>
					<td class="align-center">$poolOverrideCIRStr</td>
					<td class="align-center">$poolOverrideLimitStr</td>
					<td>
						<a href="$urlPoolOverrideEdit"><span class="glyphicon glyphicon-wrench" /></a>
						<a href="$urlPoolOverrideRemove"><span class="glyphicon glyphicon-remove" /></a>
					</td>
				</tr>
EOF
	}

	# No results
	if (!@poolOverrides) {
		$content .=<<EOF;
				<tr class="info">
					<td colspan="11"><p class="text-center">No Results</p></td>
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
sub pool_override_addedit
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Setup our environment
	my $logger = $globals->{'logger'};

	# Errors to display above the form
	my @errors;

	# Items for our form...
	my @formElements = qw(
		FriendlyName
		PoolName Username IPAddress
		TrafficClassID
		TxCIR TxLimit
		RxCIR RxLimit
		Expires inputExpires.modifier
		Notes
	);
	my @formElementCheckboxes = qw(
		TrafficClassID
		TxCIR TxLimit
		RxCIR RxLimit
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
	# If we have a pool override, this is where its kept
	my $poolOverride;

	# Grab query params
	my $queryParams = parseURIQuery($request);

	# If we have a pool override ID, pull in the pool override
	if (defined($queryParams->{'poid'})) {
		# Check if we can grab the pool override
		if (!defined($poolOverride = getPoolOverride($queryParams->{'poid'}->{'value'}))) {
			return (HTTP_TEMPORARY_REDIRECT,"limits/pool-override-list");
		}
	}

	# If this is a form try parse it
	if ($request->method eq "POST") {
		# Parse form data
		my $form = parseFormContent($request->content);

		# If user pressed cancel, redirect
		if (defined($form->{'cancel'})) {
			# Redirects to default page
			return (HTTP_TEMPORARY_REDIRECT,'/limits/pool-override-list');
		}

		# Transform form into form data
		foreach my $key (keys %{$form}) {
			$formData->{$key} = $form->{$key}->{'value'};
		}

		# Set form type if its edit
		if (defined($form->{'submit'}) && $form->{'submit'}->{'value'} eq "Edit") {
			# Check pool override exists
			if (!defined($poolOverride)) {
				return (HTTP_TEMPORARY_REDIRECT,'/limits/pool-override-list');
			}

			$formData->{'ID'} = $poolOverride->{'ID'};

			$formType = "Edit";
			$formNoEdit = "readonly";
		}

	# A GET would indicate that a pool override ID was passed normally
	} elsif ($request->method eq "GET") {
		# We need a pool override
		if (defined($poolOverride)) {
			# Setup form data from pool override
			foreach my $key (@formElements) {
				$formData->{$key} = $poolOverride->{$key};
			}
			# Setup our checkboxes
			foreach my $checkbox (@formElementCheckboxes) {
				if (defined($formData->{$checkbox})) {
					$formData->{"input$checkbox.enabled"} = "on";
				}
			}

			$formType = "Edit";
			$formNoEdit = "readonly";

		# Woops ... no query string?
		} elsif (keys %{$queryParams} > 0) {
			return (HTTP_TEMPORARY_REDIRECT,'/limits/pool-override-list');
		}
	}


	# We only do this if we have hash elements
	if (ref($formData) eq "HASH") {
		my $friendlyName = $formData->{'FriendlyName'};
		if (!defined($friendlyName)) {
			push(@errors,"Friendly name must be specified");
		}

		# Make sure we have at least a pool name, username or IP address
		my $poolName = isUsername($formData->{'PoolName'},ISUSERNAME_ALLOW_ATSIGN);
		my $username = isUsername($formData->{'Username'},ISUSERNAME_ALLOW_ATSIGN);
		my $ipAddress = isIPv4($formData->{'IPAddress'});
		if (!defined($poolName) && !defined($username) && !defined($ipAddress)) {
			push(@errors,"A pool name and/or IP address and/or Username must be specified");
		}

		# If the traffic class is ticked, process it
		my $trafficClassID;
		if (defined($formData->{'inputTrafficClassID.enabled'})) {
			if (!defined($trafficClassID = isTrafficClassIDValid($formData->{'TrafficClassID'}))) {
				push(@errors,"Traffic class is not valid");
			}
		}
		# Check traffic limits
		my $txCIR;
		if (defined($formData->{'inputTxCIR.enabled'})) {
			if (!defined($txCIR = isNumber($formData->{'TxCIR'}))) {
				push(@errors,"Download CIR is not valid");
			}
		}
		my $txLimit;
		if (defined($formData->{'inputTxLimit.enabled'})) {
			if (!defined($txLimit = isNumber($formData->{'TxLimit'}))) {
				push(@errors,"Download limit is not valid");
			}
		}
		# Check RxCIR
		my $rxCIR;
		if (defined($formData->{'inputRxCIR.enabled'})) {
			if (!defined($rxCIR = isNumber($formData->{'RxCIR'}))) {
				push(@errors,"Upload CIR is not valid");
			}
		}
		my $rxLimit;
		if (defined($formData->{'inputRxLimit.enabled'})) {
			if (!defined($rxLimit = isNumber($formData->{'RxLimit'}))) {
				push(@errors,"Upload limit is not valid");
			}
		}
		# Check that we actually have something to pool override
		if (
				!defined($trafficClassID) &&
				!defined($txCIR) && !defined($txLimit) &&
				!defined($rxCIR) && !defined($rxLimit)
		) {
			push(@errors,"Something must be specified to pool override");
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

		# If there are no errors we need to push this pool override
		if (!@errors && $request->method eq "POST") {
			# Build pool override
			my $poolOverrideData = {
				'FriendlyName' => $friendlyName,
				'PoolName' => $poolName,
				'Username' => $username,
				'IPAddress' => $ipAddress,
#				'GroupID' => 1,
				'TrafficClassID' => $trafficClassID,
				'TxCIR' => $txCIR,
				'TxLimit' => $txLimit,
				'RxCIR' => $rxCIR,
				'RxLimit' => $rxLimit,
				'Expires' => $expires,
				'Notes' => $notes,
			};

			# Check if this is an add or edit
			my $cEvent;
			if ($formType eq "Add") {
				$cEvent = "pool_override_add";
			} else {
				$poolOverrideData->{'ID'} = $formData->{'ID'};
				$cEvent = "pool_override_change";
			}

			$kernel->post("configmanager" => $cEvent => $poolOverrideData);

			$logger->log(LOG_INFO,"[WEBSERVER/POOL-OVERRIDE/ADD] Pool: %s, User: %s, IP: %s, Group: %s, Class: %s, Limits: %s/%s, ".
					"Burst: %s/%s",
					prettyUndef($poolName),
					prettyUndef($username),
					prettyUndef($ipAddress),
					"",
					prettyUndef($trafficClassID),
					prettyUndef($txCIR),
					prettyUndef($rxCIR),
					prettyUndef($txLimit),
					prettyUndef($rxLimit)
			);

			return (HTTP_TEMPORARY_REDIRECT,'/limits/pool-override-list');
		}
	}

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

	# Form header
	$content .=<<EOF;
		<legend>$formType Pool Override</legend>
		<form role="form" method="post">
EOF

	# Spit out errors if we have any
	if (@errors > 0) {
		foreach my $error (@errors) {
			$content .= '<div class="alert alert-danger">'.encode_entities($error).'</div>';
		}
	}

	# Generate traffic class list
	my @trafficClasses = sort(getTrafficClasses());
	my $trafficClassStr = "";
	foreach my $trafficClassID (@trafficClasses) {
		my $trafficClass = getTrafficClass($trafficClassID);

		# Process selections nicely
		my $selected = "";
		if ($formData->{'TrafficClassID'} ne "" && $formData->{'TrafficClassID'} eq $trafficClassID) {
			$selected = "selected";
		}
		# And build the options
		$trafficClassStr .= '<option value="'.$trafficClassID.'" '.$selected.'>'.encode_entities($trafficClass->{'Name'}).
				'</option>';
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
		$expiresModifierStr .= '<option value="'.$expireModifier.'" '.$selected.'>'.
				encode_entities($expiresModifiers->{$expireModifier}).'</option>';
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
				<label for="FriendlyName" class="col-md-2 control-label">FriendlyName</label>
				<div class="row">
					<div class="col-md-4">
						<div class="input-group">
							<input name="FriendlyName" type="text" placeholder="Friendly Name" class="form-control"
									value="$formData->{'FriendlyName'}" />
							<span class="input-group-addon">*</span>
						</div>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="PoolName" class="col-md-2 control-label">Pool Name</label>
				<div class="row">
					<div class="col-md-4">
						<input name="PoolName" type="text" placeholder="Pool Name To Override" class="form-control"
								value="$formData->{'PoolName'}" $formNoEdit/>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="Username" class="col-md-2 control-label">Username</label>
				<div class="row">
					<div class="col-md-4">
						<input name="Username" type="text" placeholder="Username To Override" class="form-control"
								value="$formData->{'Username'}" $formNoEdit/>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="IPAddress" class="col-md-2 control-label">IP Address</label>
				<div class="row">
					<div class="col-md-4">
						<input name="IPAddress" type="text" placeholder="And/Or IP Address To Override" class="form-control"
								value="$formData->{'IPAddress'}" $formNoEdit/>
					</div>
				</div>
			</div>

			<div class="form-group">
				<label for="TrafficClassID" class="col-md-2 control-label">Traffic Class</label>
				<div class="row">
					<div class="col-md-3">
						<input name="inputTrafficClassID.enabled" type="checkbox" $formData->{'inputTrafficClassID.enabled'}/>
						Override
						<select name="TrafficClassID" class="form-control">
							$trafficClassStr
						</select>
					</div>
				</div>
			</div>

			<div class="form-group">
				<label for="TxCIR" class="col-md-2 control-label">Download CIR</label>
				<div class="row">
					<div class="col-md-3">
						<input name="inputTxCIR.enabled" type="checkbox" $formData->{'inputTxCIR.enabled'} />
						Override
						<div class="input-group">
							<input name="TxCIR" type="text" placeholder="Download CIR" class="form-control"
									value="$formData->{'TxCIR'}" />
							<span class="input-group-addon">Kbps<span>
						</div>
					</div>
				</div>
			</div>

			<div class="form-group">
				<label for="TxLimit" class="col-md-2 control-label">Download Limit</label>
				<div class="row">
					<div class="col-md-3">
						<input name="inputTxLimit.enabled" type="checkbox"
								$formData->{'inputTxLimit.enabled'}/> Override
						<div class="input-group">
							<input name="TxLimit" type="text" placeholder="Download Limit" class="form-control"
									value="$formData->{'TxLimit'}" />
							<span class="input-group-addon">Kbps<span>
						</div>
					</div>
				</div>
			</div>

			<div class="form-group">
				<label for="inputRxCIR" class="col-md-2 control-label">Upload CIR</label>
				<div class="row">
					<div class="col-md-3">
						<input name="inputRxCIR.enabled" type="checkbox"
								$formData->{'inputRxCIR.enabled'}/> Override
						<div class="input-group">
							<input name="RxCIR" type="text" placeholder="Upload CIR" class="form-control"
									value="$formData->{'RxCIR'}" />
							<span class="input-group-addon">Kbps<span>
						</div>
					</div>
				</div>
			</div>
			<div class="form-group">
				<label for="RxLimit" class="col-md-2 control-label">Upload Limit</label>
				<div class="row">
					<div class="col-md-3">
						<input name="inputRxLimit.enabled" type="checkbox"
								$formData->{'inputRxLimit.enabled'}/> Override
						<div class="input-group">
							<input name="RxLimit" type="text" placeholder="Upload Limit" class="form-control"
									value="$formData->{'RxLimit'}" />
							<span class="input-group-addon">Kbps<span>
						</div>
					</div>
				</div>
			</div>

			<div class="form-group">
				<label for="Expires" class="col-md-2 control-label">Expires</label>
				<div class="row">
					<div class="col-md-2">
						<input name="Expires" type="text" placeholder="Expires" class="form-control"
								value="$formData->{'Expires'}" />
					</div>
					<div class="col-md-2">
						<select name="inputExpires.modifier" class="form-control" value="$formData->{'inputExpires.modifier'}">
							$expiresModifierStr
						</select>
					</div>
				</div>
			</div>

			<div class="form-group">
				<label for="Notes" class="col-md-2 control-label">Notes</label>
				<div class="row">
					<div class="col-md-4">
						<textarea name="Notes" placeholder="Notes" rows="3" class="form-control">$formData->{'Notes'}</textarea>
					</div>
				</div>
			</div>
			<div class="form-group">
				<button name="submit" type="submit" value="$formType" class="btn btn-primary">$formType</button>
				<button name="cancel" type="submit" class="btn">Cancel</button>
			</div>
		</form>
EOF

	return (HTTP_OK,$content,{ 'menu' => $menu });
}



# Remove action
sub pool_override_remove
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Content to return
	my $content = "";

	# Pull in GET
	my $queryParams = parseURIQuery($request);
	# We need a key first of all...
	if (!defined($queryParams->{'poid'})) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				No pool override oid in query string!
			</div>
EOF
		goto END;
	}

	# Grab the pool override
	my $poolOverride = getPoolOverride($queryParams->{'poid'}->{'value'});

	# Make the oid safe for HTML
	my $encodedPoolOverrideID = encode_entities($queryParams->{'poid'}->{'value'});

	# Make sure the oid was valid... we would have an pool override now if it was
	if (!defined($poolOverride)) {
		$content = <<EOF;
			<div class="alert alert-danger text-center">
				Invalid pool override oid "$encodedPoolOverrideID"!
			</div>
EOF
		goto END;
	}

	# Pull in POST
	my $form = parseFormContent($request->content);
	# If this is a post, then its probably a confirmation
	if (defined($form->{'confirm'})) {
		# Check if its a success
		if ($form->{'confirm'}->{'value'} eq "Yes") {
			# Post the removal
			$kernel->post("configmanager" => "pool_override_remove" => $poolOverride->{'ID'});
		}
		return (HTTP_TEMPORARY_REDIRECT,'/limits/pool-override-list');
	}


	# Make the friendly name HTML safe
	my $encodedPoolOverrideFriendlyName = encode_entities($poolOverride->{'FriendlyName'});

	# Build our confirmation dialog
	$content .= <<EOF;
		<div class="alert alert-danger">
			Are you very sure you wish to remove pool override "$encodedPoolOverrideFriendlyName"?
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
