# OpenTrafficShaper webserver module: configmanager page
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
use HTTP::Status qw(
	:constants
);
use URI::Escape;

use awitpt::util qw(
	isNumber ISNUMBER_ALLOW_ZERO

	parseFormContent
	parseURIQuery

	prettyUndef
);
use opentrafficshaper::logger;
use opentrafficshaper::plugins;
use opentrafficshaper::plugins::configmanager qw(
	getInterfaces
	getInterface

	getTrafficClass
	getAllTrafficClasses

	getInterfaceTrafficClass
	changeInterfaceTrafficClass

	isInterfaceIDValid

	isTrafficClassIDValid
);



# Sidebar menu options for this module
my $menu = [
	{
		'name' => 'Admin',
		'items' => [
			{
				'name' => 'Configuration',
				'link' => 'admin-config'
			}
		]
	}
];



# Default page/action
sub default
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Build content
	my $content = "";

	return (HTTP_OK,$content,{ 'menu' => $menu });
}



# Admin configuration
sub admin_config
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	# Grab stuff we need
	my @interfaces = getInterfaces();


	# Errors to display above the form
	my @errors;

	# Build content
	my $content = "";

	# Form header
	$content .=<<EOF;
		<legend>Interface Rate Setup</legend>
EOF
	# Form data
	my $formData;


	# If this is a form try parse it
	if ($request->method eq "POST") {
		# Parse form data
		my $form = parseFormContent($request->content);

		# Loop with rate changes
		my $rateChanges = { };
		foreach my $elementName (keys %{$form}) {
			my $rateChange = $form->{$elementName};

			# Skip over blanks
			if ($rateChange->{'value'} =~ /^\s*$/) {
				next;
			}
			# Split off the various components of the element name
			my ($item,$interfaceID,$trafficClassID) = ($elementName =~ /^((?:CIR|Limit))\[([a-z0-9:.]+)\]\[([0-9]+)\]$/);
			# Make sure everything is defined
			if (!defined($item) || !defined($interfaceID) || !defined($trafficClassID)) {
				push(@errors,"Invalid data received");
				last;
			}

			# Check interface exists
			if (!defined($interfaceID = isInterfaceIDValid($interfaceID))) {
				push(@errors,"Invalid data received, interface ID is invalid");
				last;
			}
			# Check class is valid
			if (
					!defined($trafficClassID = isNumber($trafficClassID,ISNUMBER_ALLOW_ZERO)) ||
					($trafficClassID && !isTrafficClassIDValid($trafficClassID))
			) {
				push(@errors,"Invalid class ID received for interface [$interfaceID]");
				last;
			}
			# Check value is valid
			if (!defined($rateChange->{'value'} = isNumber($rateChange->{'value'}))) {
				push(@errors,"Invalid value received for interface [$interfaceID], class [$trafficClassID]");
				last;
			}

			$rateChanges->{$interfaceID}->{$trafficClassID}->{$item} = $rateChange->{'value'};
		}
# FIXME - check speed does not exceed inteface speed
		# Check if there are no errors
		if (!@errors) {
			# Loop with interfaces
			foreach my $interfaceID (keys %{$rateChanges}) {
				my $trafficClasses = $rateChanges->{$interfaceID};

				# Loop with traffic classes
				foreach my $trafficClassID (keys %{$trafficClasses}) {
					my $trafficClass = $trafficClasses->{$trafficClassID};

					# Set some additional items we need
					$trafficClass->{'InterfaceID'} = $interfaceID;
					$trafficClass->{'TrafficClassID'} = $trafficClassID;
					# Push changes
					changeInterfaceTrafficClass($trafficClass);
				}
			}

			return (HTTP_TEMPORARY_REDIRECT,"/configmanager");
		}
	}


	# Header
	$content .=<<EOF;
		<!-- Config Tabs -->
		<ul class="nav nav-tabs" id="configTabs">
			<li class="active"><a href="#interfaces" data-toggle="tab">Interfaces</a></li>
		</ul>
		<!-- Tab panes -->
		<div class="tab-content">
			<div class="tab-pane active" id="interfaces">
EOF

	# Spit out errors if we have any
	if (@errors > 0) {
		foreach my $error (@errors) {
			$content .= '<div class="alert alert-danger">'.encode_entities($error).'</div>';
		}
	}

	# Interfaces tab setup
	$content .=<<EOF;
				<br />
				<!-- Interface Tabs -->
				<ul class="nav nav-tabs" id="configInterfaceTabs">
EOF
	my $firstPaneActive = " active";
	foreach my $interfaceID (@interfaces) {
		my $interface = getInterface($interfaceID);
		my $encodedInterfaceID = encode_entities($interfaceID);
		my $encodedInterfaceName = encode_entities($interface->{'Name'});


		$content .=<<EOF;
					<li class="$firstPaneActive">
						<a href="#interface$encodedInterfaceID" data-toggle="tab">
							Interface: $encodedInterfaceName
						</a>
					</li>
EOF
		# No longer the first pane
		$firstPaneActive = "";
	}
	$content .=<<EOF;
				</ul>
				<!-- Tab panes -->
				<div class="tab-content">
EOF

	# Suck in list of interfaces
	$firstPaneActive = " active";
	foreach my $interfaceID (@interfaces) {
		my $interface = getInterface($interfaceID);
		my $encodedInterfaceID = encode_entities($interfaceID);
		my $encodedInterfaceName = encode_entities($interface->{'Name'});
		my $encodedInterfaceLimit = encode_entities($interface->{'Limit'});


		# Interface tab
		$content .=<<EOF;
					<div class="tab-pane$firstPaneActive" id="interface$encodedInterfaceID">
EOF
		# No longer the first pane
		$firstPaneActive = "";

		# Sanitize params if we need to
		if (defined($formData->{"Limit[$encodedInterfaceID][0]"})) {
		   $formData->{"Limit[$encodedInterfaceID][0]"} =
				   encode_entities($formData->{"Limit[$encodedInterfaceID][0]"});
		} else {
		   $formData->{"Limit[$encodedInterfaceID][0]"} = "";
		}


		#
		# Form header
		#
		$content .=<<EOF;
						<form role="form" method="post">
EOF
		#
		# Page content
		#
		$content .=<<EOF;
							<br />
							<legend>Main: $encodedInterfaceName</legend>
							<div class="form-group">
								<label for="Limit" class="col-md-1 control-label">Speed</label>
								<div class="row">
									<div class="col-md-3">
										<div class="input-group">
											<input name="Limit[$encodedInterfaceID][0]" type="text"
													placeholder="$encodedInterfaceLimit" class="form-control"
													value="$formData->{"Limit[$encodedInterfaceID][0]"}" />
											<span class="input-group-addon">Kbps *<span>
										</div>
									</div>
								</div>
							</div>
EOF

		# Grab classes and loop
		my @trafficClasses = getAllTrafficClasses();
		foreach my $trafficClassID (sort { $a <=> $b } @trafficClasses) {
			my $trafficClass = getTrafficClass($trafficClassID);
			my $encodedTrafficClassID = encode_entities($trafficClassID);
			my $encodedTrafficClassName = encode_entities($trafficClass->{'Name'});
			my $interfaceTrafficClass = getInterfaceTrafficClass($interfaceID,$trafficClassID);
			my $encodedInterfaceTrafficClassCIR = encode_entities($interfaceTrafficClass->{'CIR'});
			my $encodedInterfaceTrafficClassLimit = encode_entities($interfaceTrafficClass->{'Limit'});


			# Sanitize params if we need to
			if (defined($formData->{"CIR[$encodedInterfaceID][$encodedTrafficClassID]"})) {
			   $formData->{"CIR[$encodedInterfaceID][$encodedTrafficClassID]"} =
					   encode_entities($formData->{"CIR[$encodedInterfaceID][$encodedTrafficClassID]"});
			} else {
			   $formData->{"CIR[$encodedInterfaceID][$encodedTrafficClassID]"} = "";
			}
			if (defined($formData->{"Limit[$encodedInterfaceID][$encodedTrafficClassID]"})) {
			   $formData->{"Limit[$encodedInterfaceID][$encodedTrafficClassID]"} =
					   encode_entities($formData->{"Limit[$encodedInterfaceID][$encodedTrafficClassID]"});
			} else {
			   $formData->{"Limit[$encodedInterfaceID][$encodedTrafficClassID]"} = "";
			}

			#
			# Page content
			#
			$content .=<<EOF;
							<legend>Class: $encodedInterfaceName - $encodedTrafficClassName</legend>
							<div class="form-group">
								<label for="TxCIR" class="col-md-1 control-label">CIR</label>
								<div class="row">
									<div class="col-md-3">
										<div class="input-group">
											<input name="CIR[$encodedInterfaceID][$encodedTrafficClassID]" type="text"
													placeholder="$encodedInterfaceTrafficClassCIR" class="form-control"
													value="$formData->{"CIR[$encodedInterfaceID][$encodedTrafficClassID]"}" />
											<span class="input-group-addon">Kbps *<span>
										</div>
									</div>

									<label for="TxLimit" class="col-md-1 control-label">Limit</label>
									<div class="col-md-3">
										<div class="input-group">
											<input name="Limit[$encodedInterfaceID][$encodedTrafficClassID]" type="text"
													placeholder="$encodedInterfaceTrafficClassLimit" class="form-control"
													value="$formData->{"Limit[$encodedInterfaceID][$encodedTrafficClassID]"}" />
											<span class="input-group-addon">Kbps<span>
										</div>
									</div>
								</div>
							</div>
EOF
		}

		$content .=<<EOF;
							<div class="form-group">
								<button type="submit" class="btn btn-primary">Update</button>
								<button name="cancel" type="submit" class="btn">Cancel</button>
							</div>
						</form>
EOF
		# Footer
		$content .=<<EOF;
					</div>
EOF
	}

	$content .=<<EOF;
				</div>
			</div>
EOF

	$content .=<<EOF;
		</div>
EOF


	return (HTTP_OK,$content,{ 'menu' => $menu });
}




1;
# vim: ts=4
