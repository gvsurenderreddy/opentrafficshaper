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
	getInterfaceTrafficClass
	getInterface

	getTrafficClass
	getAllTrafficClasses

	isInterfaceIDValid

	changeTrafficClass
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


	# Items for our form...
	my @formElements = qw(
		FriendlyName
		Identifier
		ClassID
		TrafficLimitTx TrafficLimitTxBurst
		TrafficLimitRx TrafficLimitRxBurst
		Notes
	);

	# Grab stuff we need
	my $interfaces = getInterfaces();


	# Build content
	my $content = "";

	# Header
	$content .=<<EOF;
		<!-- Config Tabs -->
		<ul class="nav nav-tabs" id="configTabs">
			<li class="active"><a href="#interfaces" data-toggle="tab">Interfaces</a></li>
			<li><a href="#system" data-toggle="tab">System (TODO)</a></li>
		</ul>
		<!-- Tab panes -->
		<div class="tab-content">
			<div class="tab-pane active" id="interfaces">
EOF


	# Title of the form, by default its an add form
	my $formType = "Add";
	my $formNoEdit = "";
	# Form data
	my $formData;


	# If this is a form try parse it
	if ($request->method eq "POST") {
		# Parse form data
		my $form = parseFormContent($request->content);
		use Data::Dumper; warn "CONTENTDATA: ".Dumper($request->content);
		use Data::Dumper; warn "FORMDATA: ".Dumper($form);
	}


	# Interfaces tab setup
	$content .=<<EOF;
				<br />
				<!-- Interface Tabs -->
				<ul class="nav nav-tabs" id="configInterfaceTabs">
EOF
	my $firstPaneActive = " active";
	foreach my $interface (@{$interfaces}) {
		$content .=<<EOF;
					<li class="$firstPaneActive"><a href="#interface$interface" data-toggle="tab">Interface: $interface</a></li>
EOF
		# No longer the first pane
		$firstPaneActive = "";

		$formData->{"MainTrafficLimitTx[$interface]"} = getInterfaceRate($interface);
	}
	$content .=<<EOF;
				</ul>
				<!-- Tab panes -->
				<div class="tab-content">
EOF

	# Suck in list of interfaces
	$firstPaneActive = " active";
	foreach my $interface (@{$interfaces}) {
		# Interface tab
		$content .=<<EOF;
					<div class="tab-pane$firstPaneActive" id="interface$interface">
EOF
		# No longer the first pane
		$firstPaneActive = "";

		# Sanitize params if we need to
		foreach my $item (@formElements) {
			$formData->{$item} = defined($formData->{$item}) ? encode_entities($formData->{$item}) : "";
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
							<legend>Main: $interface</legend>
							<div class="form-group">
								<label for="TrafficLimitTx" class="col-md-1 control-label">CIR</label>
								<div class="row">
									<div class="col-md-3">
										<div class="input-group">
											<input name="MainTrafficLimitTx[$interface]" type="text" placeholder="CIR" class="form-control" value="$formData->{"MainTrafficLimitTx[$interface]"}" />
											<span class="input-group-addon">Kbps *<span>
										</div>
									</div>

									<label for="TrafficLimitTxBurst" class="col-md-1 control-label">Limit</label>
									<div class="col-md-3">
										<div class="input-group">
											<input name="MainTrafficLimitTxBurst[$interface]" type="text" placeholder="Limit" class="form-control" value="$formData->{'TrafficLimitTxBurst'}" />
											<span class="input-group-addon">Kbps<span>
										</div>
									</div>
								</div>
							</div>
EOF

		my $classes = getInterfaceTrafficClasses($interface);
		foreach my $class (sort { $a <=> $b } keys %{$classes}) {
			my $className = getTrafficClassName($class);
			my $classNameStr = encode_entities($className);

			#
			# Page content
			#
			$content .=<<EOF;
							<legend>Class: $interface - $classNameStr</legend>
							<div class="form-group">
								<label for="TrafficLimitTx" class="col-md-1 control-label">CIR</label>
								<div class="row">
									<div class="col-md-3">
										<div class="input-group">
											<input name="ClassTrafficLimitTx[$interface] x y [$class]" type="text" placeholder="CIR" class="form-control" value="$formData->{'TrafficLimitTx'}" />
											<span class="input-group-addon">Kbps *<span>
										</div>
									</div>

									<label for="TrafficLimitTxBurst" class="col-md-1 control-label">Limit</label>
									<div class="col-md-3">
										<div class="input-group">
											<input name="ClassTrafficLimitTxBurst[$interface][$class]" type="text" placeholder="Limit" class="form-control" value="$formData->{'TrafficLimitTxBurst'}" />
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
