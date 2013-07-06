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

package opentrafficshaper::plugins::webserver::pages::users;

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



# Sidebar menu options for this module
my $menu = {
	'Users' =>  {
		'Show Users' => '',
	},
	'Admin' => {
		'Add User' => 'add',
	},
};



# Default page/action
sub default
{
	my ($kernel,$globals,$module,$daction,$request) = @_;

	# If we not passed default by the main app, just return
	return if ($daction ne "default");

	my $users = $globals->{'users'};


	# Build content
	my $content = "";

	# Header
	$content .=<<EOF;
<table class="table">
	<legend>User List</legend>
	<thead>
		<tr>
			<th>#</th>
			<th>User</th>
			<th>IP</th>
			<th>Source</th>
			<th>LastUpdate</th>
			<th>Class</th>
			<th>Group</th>
			<th>Limits</th>
		</tr>
	</thead>
	<tbody>
EOF
	# Body
	foreach my $uid (keys %{$users}) {
		my $user = $users->{$uid};

		# Make style a bit pretty
		my $style = "";
		my $icon = "";
		if ($user->{'Status'} eq "offline") {
			$style = "warning";
		} elsif ($user->{'Status'} eq "new") {
			$style = "info";
		} elsif ($user->{'Status'} eq "conflict") {
			$icon = '<i class="icon-random"></i>';
			$style = "error";
		}

		# Get a nice last update string
		my $lastUpdate = DateTime->from_epoch( epoch => $user->{'LastUpdate'} )->iso8601();
		my $limits = $user->{'TrafficLimitTx'} . "/" . $user->{'TrafficLimitRx'};

		$content .=<<EOF;
		<tr class="$style">
			<td>$icon</td>
			<td>$user->{'Username'}</td>
			<td>$user->{'IP'}</td>
			<td>$user->{'Source'}</td>
			<td>$lastUpdate</td>
			<td>$user->{'ClassID'}</td>
			<td>$user->{'GroupID'}</td>
			<td>$limits</td>
		</tr>
EOF
	}
	# No results
	if (keys %{$globals->{'users'}} < 1) {
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


	return (HTTP_OK,$content,$menu);
}


# Add action
sub add
{
	my ($kernel,$globals,$module,$daction,$request) = @_;


	# Setup our environment
	my $logger = $globals->{'logger'};

	# Errors to display
	my @errors;
	# Form items
	my $params = {
		'inputUsername' => undef,
		'inputIP' => undef,
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
			return (HTTP_TEMPORARY_REDIRECT,'users');
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
			# Build user
			my $user = {
				'Username' => $username,
				'IP' => $ipAddress,
				'GroupID' => 1,
				'ClassID' => 1,
				'TrafficLimitTx' => $trafficLimitTx,
				'TrafficLimitRx' => $trafficLimitRx,
				'TrafficLimitTxBurst' => $trafficLimitTx,
				'TrafficLimitRxBurst' => $trafficLimitRx,
				'Status' => "online",
				'Source' => "plugin.webserver.users",
			};

			# Throw the change at the config manager
			$kernel->post("configmanager" => "process_change" => $user);

			$logger->log(LOG_INFO,"[WEBSERVER/USERS/ADD] User: $username, IP: $ipAddress, Group: 1, Class: 2, ".
					"Limits: ".prettyUndef($trafficLimitTx)."/".prettyUndef($trafficLimitRx).", Burst: ".prettyUndef($trafficLimitTx)."/".prettyUndef($trafficLimitRx));

			return (HTTP_TEMPORARY_REDIRECT,'users');
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
<form class="form-horizontal" method="post">
	<legend>Add Manual User</legend>
EOF

	# Spit out errors if we have any
	if (@errors > 0) {
		foreach my $error (@errors) {
			$content .= '<div class="alert alert-error">'.$error.'</div>';
		}
	}

	# Header
	$content .=<<EOF;
	<div class="control-group">
		<label class="control-label" for="inputUsername">Username</label>
		<div class="controls">
			<input name="inputUsername" type="text" placeholder="Username" value="$params->{'inputUsername'}" />
		</div>
	</div>
	<div class="control-group">
		<label class="control-label" for="inputIP">IP Address</label>
		<div class="controls">
			<input name="inputIP" type="text" placeholder="IP Address" value="$params->{'inputIP'}" />
		</div>
	</div>
	<div class="control-group">
		<label class="control-label" for="inputLimitTx">Download Limit</label>
		<div class="controls">
			<div class="input-append">
				<input name="inputLimitTx" type="text" class="span5" placeholder="TX Limit" value="$params->{'inputLimitTx'}" />
				<span class="add-on">Kbps<span>
			</div>
		</div>
	</div>
	<div class="control-group">
		<label class="control-label" for="inputLimitRx">Upload Limit</label>
		<div class="controls">
			<div class="input-append">
				<input name="inputLimitRx" type="text" class="span5" placeholder="RX Limit" value="$params->{'inputLimitRx'}" />
				<span class="add-on">Kbps<span>
			</div>
		</div>
	</div>
	<div class="control-group">
		<div class="controls">
			<button type="submit" class="btn btn-primary">Add</button>
			<button name="cancel" type="submit" class="btn">Cancel</button>
		</div>
	</div>
</form>
EOF

	return (200,$content,$menu);
}


1;
