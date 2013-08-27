# OpenTrafficShaper webserver module: statistics websockets
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

package opentrafficshaper::plugins::webserver::snapins::websockets::statistics;

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
use POE;

use opentrafficshaper::logger;
use opentrafficshaper::utils;


use constant {
	VERSION => '0.0.1'
};


# Plugin info
our $pluginInfo = {
	Name => "Webserver/WebSockets/Statistics",
	Version => VERSION,
	
	Requires => ["webserver","statistics"],

	Init => \&plugin_init,
};

# Copy of system globals
my $globals;
my $logger;

# Stats subscriptsions
my $cSubscriptions = {}; # Clients
my $uSubscriptions = {}; # Users


# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[WEBSERVER] OpenTrafficShaper Snapin [WebSockets/Statistics] Module v".VERSION." - Copyright (c) 2013, AllWorldIT");

	# Protocol conversion
	opentrafficshaper::plugins::webserver::snapin_register('HTTP=>WebSocket','statistics','graphdata', {
			'requires' => [ 'statistics' ],
			'on_request' => \&graphdata_http2websocket,
			'on_disconnect' => \&websocket_disconnect,
		}
	);

	# Live graphdata feed
	opentrafficshaper::plugins::webserver::snapin_register('WebSocket','statistics','graphdata', {
			'requires' => [ 'statistics' ],
			'on_request' => \&graphdata_websocket,
		}
	);

	# This is our session handling sending data to connections
	POE::Session->create(
		inline_states => {
			_start => \&session_init,
			'websocket.send' => \&do_send,
		}
	);

	return 1;
}


# Session initialization
sub session_init
{
	my $kernel = $_[KERNEL];

	# Set our alias
	$kernel->alias_set("plugin.webserver.websockets.statistics");

	$logger->log(LOG_DEBUG,"[WEBSERVER] Snapin/WebSockets/Statistics - Initialized");
}


# Send data to client
sub do_send
{
	my ($kernel,$heap,$uid,$data) = @_[KERNEL, HEAP, ARG0, ARG1];


	# Loop through subscriptions
	foreach my $client_session_id (keys %{$uSubscriptions->{$uid}}) {
		my $socket = $uSubscriptions->{$uid}->{$client_session_id};

		use Data::Dumper; print STDERR "Got request to send client '$client_session_id': ".Dumper($data);

#		my $json = sprintf('{"label": "%s", data: [%s] }', );

		$socket->put("hello there");
	}
}



# HTTP to WebSocket
sub websocket_disconnect
{
	my ($kernel,$globals,$client_session_id) = @_;
	my $logger = $globals->{'logger'};


	$logger->log(LOG_INFO,"[WEBSERVER] Snapin/WebSockets/Statistics - Client '$client_session_id' disconnected");

	# Loop with our UID's
	foreach my $uid (keys %{$cSubscriptions->{$client_session_id}}) {
		# Remove tracking info
		delete($uSubscriptions->{$uid}->{$client_session_id});
		delete($cSubscriptions->{$client_session_id}->{$uid});
		# If there are no more clients for this uid, then unsubscribe it
		if (keys %{$uSubscriptions->{$uid}} < 1) {
			$kernel->post('statistics' => 'unsubscribe' => 'plugin.webserver.websockets.statistics' => 'websocket.send' => $uid);
		}
	}

}


# HTTP to WebSocket
sub graphdata_http2websocket
{
	my ($kernel,$globals,$client_session_id,$request,$socket) = @_;
	my $logger = $globals->{'logger'};


	# Grab the query string
	my %queryForm = $request->uri->query_form();

	# Check we have a user ID
	if (!defined($queryForm{'uid'})) {
		return (HTTP_BAD_REQUEST,"Request not valid","Request does not contain a 'uid' parameter");
	}
	my $uid = $queryForm{'uid'};

	$logger->log(LOG_INFO,"[WEBSERVER] Snapin/WebSockets/Statistics - Accepting upgrade of HTTP to WebSocket");

	# Subscribe to the stats for this user
	if (!defined($uSubscriptions->{$uid}) || !(keys %{$uSubscriptions->{$uid}})) {
		$logger->log(LOG_INFO,"[WEBSERVER] Snapin/WebSockets/Statistics - Subscribing to '$uid'");
		$kernel->post('statistics' => 'subscribe' => 'plugin.webserver.websockets.statistics' => 'websocket.send' => $uid);
	}

	# Setup tracking of our client & user subscriptions
	$cSubscriptions->{$client_session_id}->{$uid} = $socket;
	$uSubscriptions->{$uid}->{$client_session_id} = $socket;

	# And return...
	return;
}


1;
