# OpenTrafficShaper webserver module
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



package opentrafficshaper::plugins::webserver;

use strict;
use warnings;


use POE;


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
);

use constant {
	VERSION => '0.0.1'
};


# Plugin info
our $pluginInfo = {
	Name => "Webserver",
	Version => VERSION,
	
	Init => \&init,
};


# Copy of system globals
my $globals;


# Initialize plugin
sub init
{
	$globals = shift;


	print STDERR "HI HTERE!! \n";


	# Spawn a web server on port 8088 of all interfaces.
	POE::Component::Server::TCP->new(
		Alias => "webserver",
		Port => 8088,
		ClientFilter => 'POE::Filter::HTTPD',
		# Function to handle HTTP requests (as we passing through a filter)
		ClientInput => \&handle_request
	);
}


sub handle_request
{
	my ($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];


	# We may have a response from the filter indicating an error
	if ($request->isa("HTTP::Response")) {
		$heap->{client}->put($request);
		$kernel->yield("shutdown");
		return;
	}

	my $response = HTTP::Response->new(200);
	$response->push_header('Content-type', 'text/html');

	my $content = 
	  # Break the HTML tag for the wiki.
	  "<html><head><title>Your Request</title></head>"
	;


		$content .= "<table>";
		$content .= "  <tr><td>User</td><td>IP</td></tr>";
		foreach my $user (keys %{$globals->{'users'}}) {
			$content .= "  <tr><td>".$user."</td><td>".$globals->{'users'}->{$user}."</td></tr>";
		}

		$content .= "</table>";

		$content .= "</body></html>";

	$response->content($content);
	# Once the content has been built, send it back to the client
	# and schedule a shutdown.

	$heap->{client}->put($response);
	$kernel->yield("shutdown");
}




1;
# vim: ts=4
