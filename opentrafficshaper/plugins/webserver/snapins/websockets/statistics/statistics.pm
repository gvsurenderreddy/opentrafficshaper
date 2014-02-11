# OpenTrafficShaper webserver module: statistics websockets
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
use HTTP::Status qw( :constants );
use JSON;
use POE;
use URI;

use awitpt::util qw(
	parseKeyPairString
);
use opentrafficshaper::logger;
use opentrafficshaper::plugins::configmanager qw(
	getPoolByName
	getInterfaceGroup
	isTrafficClassIDValid
);


use constant {
	VERSION => '0.1.1'
};


# Plugin info
our $pluginInfo = {
	Name => "Webserver/WebSockets/Statistics",
	Version => VERSION,

	Requires => ["webserver","statistics"],

	Init => \&plugin_init,
};

# Logger
my $logger;

# Stats subscriptsions
my $subscribers = {}; # Connections subscribed, indexed by client_session_id then ssid
my $subscriberMap = {}; # Index of connections by ssid


# Initialize plugin
sub plugin_init
{
	my $system = shift;


	# Setup our environment
	$logger = $system->{'logger'};

	$logger->log(LOG_NOTICE,"[WEBSERVER] OpenTrafficShaper Snapin [WebSockets/Statistics] Module v%s - Copyright (c) 2013-2014".
			", AllWorldIT",
			VERSION
	);

	# Protocol conversion
	opentrafficshaper::plugins::webserver::snapin_register('HTTP=>WebSocket','statistics','graphdata', {
			'requires' => [ 'statistics' ],
			'on_request' => \&graphdata_http2websocket,
		}
	);

	# Live graphdata feed
	opentrafficshaper::plugins::webserver::snapin_register('WebSocket','statistics','graphdata', {
			'requires' => [ 'statistics' ],
			'on_request' => \&graphdata_websocket_onrequest,
			'on_disconnect' => \&graphdata_websocket_disconnect
		}
	);

	# This is our session handling sending data to connections
	POE::Session->create(
		inline_states => {
			_start => \&_session_start,
			_stop => \&_session_stop,

			'websocket.send' => \&_session_websocket_send,
		}
	);

	return 1;
}


# Session initialization
sub _session_start
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Set our alias
	$kernel->alias_set("plugin.webserver.websockets.statistics");

	$logger->log(LOG_DEBUG,"[WEBSERVER] Snapin/WebSockets/Statistics - Initialized");
}


# Session stop
sub _session_stop
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Remove our alias
	$kernel->alias_remove("plugin.webserver.websockets.statistics");

	$subscribers = {};
	$subscriberMap = {};

	$logger->log(LOG_DEBUG,"[WEBSERVER] Snapin/WebSockets/Statistics - Shutdown");

	$logger = undef;
}


# Send data to client
sub _session_websocket_send
{
	my ($kernel,$heap,$statsData) = @_[KERNEL, HEAP, ARG0, ARG1];


	# Loop with stats data
	foreach my $ssid (keys %{$statsData}) {
		my $ssidStat = $statsData->{$ssid};

		# Check if we know about this SSID
		if (!defined($subscriberMap->{$ssid})) {
			$logger->log(LOG_ERR,"[WEBSERVER] Snapin/WebSockets/Statistics - Subscription inconsidency with SSID '$ssid'");
			next;
		}

		# First stage, pull in the data items we want
		my $rawData;
		# Loop with timestamps
		foreach my $timestamp (sort keys %{$ssidStat}) {
			# Grab the stat
			my $tstat = $ssidStat->{$timestamp};
			# Loop with its keys
			foreach my $item (keys %{$tstat}) {
				# Add the keys to the data to return
				push(@{$rawData->{$item}->{'data'}},[
						$timestamp,
						$tstat->{$item}
				]);
			}
		}

		my $socket = $subscriberMap->{$ssid}->{'Socket'};
		my $tag = $subscriberMap->{$ssid}->{'Tag'};

		$socket->put(_json_data({ $tag => $rawData }));
	}

}


# HTTP to WebSocket
sub graphdata_websocket_disconnect
{
	my ($kernel,$globals,$client_session_id) = @_;


	$logger->log(LOG_INFO,"[WEBSERVER] Snapin/WebSockets/Statistics - Client '$client_session_id' disconnected");

	# Loop with our clients' subscriber ID's
	foreach my $ssid (keys %{$subscribers->{$client_session_id}}) {
		# And unsubscribe them
		opentrafficshaper::plugins::statistics::unsubscribe($ssid);
		# Remove the ssid map
		delete($subscriberMap->{$ssid});
	}
	# Remove the client
	delete($subscribers->{$client_session_id});
}


# HTTP to WebSocket
sub graphdata_http2websocket
{
	my ($kernel,$globals,$client_session_id,$request,$socket) = @_;


	# Grab the query string
#	my %queryForm = $request->uri->query_form();

	# Check we have a user ID
#	if (!defined($queryForm{'uid'})) {
#		return (HTTP_BAD_REQUEST,"Request not valid","Request does not contain a 'uid' parameter");
#	}
#	my $uid = $queryForm{'uid'};

	$logger->log(LOG_INFO,"[WEBSERVER] Snapin/WebSockets/Statistics - Accepting upgrade of HTTP to WebSocket");

	# Subscribe to the stats for this user
#	if (!defined($uSubscriptions->{$uid}) || !(keys %{$uSubscriptions->{$uid}})) {
#		$logger->log(LOG_INFO,"[WEBSERVER] Snapin/WebSockets/Statistics - Subscribing to '$uid'");
#		$kernel->post('statistics' => 'subscribe' => 'plugin.webserver.websockets.statistics' => 'websocket.send' => $uid);
#	}

	# Setup tracking of our client & user subscriptions
#	$cSubscriptions->{$client_session_id}->{$uid} = $socket;
#	$uSubscriptions->{$uid}->{$client_session_id} = $socket;

	# And return...
	return;
}


# Websocket data handler
sub graphdata_websocket_onrequest
{
	my ($kernel,$globals,$client_session_id,$request,$socket) = @_;


	my $logger = $globals->{'logger'};

	# Parse the command we got...
	if ($request->{'function'} eq "subscribe") {

		# Grab the first parameter as our tag
		my $tag = shift(@{$request->{'args'}});
		if (!defined($tag) || ref($tag) ne "") {
			return (
					opentrafficshaper::plugins::webserver::WS_ERROR,
					"The first parameter of 'subscribe' must be a text based tag"
			);
		}

		# Pull off our datasets
		my $datasets = { };
		foreach my $arg (@{$request->{'args'}}) {
			my ($item,$params) = split(/=/,$arg);
			push(@{$datasets->{$item}},$params);

		}

		# Parse dataset data
		my @sidList;
		if (defined($datasets->{'pool'})) {
			# Loop with pool specifications
			foreach my $poolSpec (@{$datasets->{'pool'}}) {
				# Split interface group id and pool name
				my ($rawInterfaceGroupID,$rawPoolName) = split(/:/,$poolSpec);
				if (!defined($rawInterfaceGroupID)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource for pool has invalid format '$poolSpec'"
					);
				}
				if (!defined($rawPoolName)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource for pool has invalid format '$poolSpec'"
					);
				}

				# Check if we can grab the interface group
				my $interfaceGroup = getInterfaceGroup($rawInterfaceGroupID);
				if (!defined($interfaceGroup)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource has invalid interface group '$rawInterfaceGroupID'"
					);
				}

				# Check if the pool name exists
				my $pool = getPoolByName($rawInterfaceGroupID,$rawPoolName);
				if (!defined($pool)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource has invalid pool '$rawPoolName'"
					);
				}
				# Check if we have a stats ID
				my $sid = opentrafficshaper::plugins::statistics::getSIDFromPID($pool->{'ID'});
				if (!defined($sid)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource stats for pool not found '$rawPoolName'"
					);
				}

				# Add SID to SID list that we need to subscribe to
				push(@sidList,{'SID' => $sid});
			}
		}

		if (defined($datasets->{'class'})) {
			# Loop with class specifications
			foreach my $classIDSpec (@{$datasets->{'class'}}) {
				# Check we have a tag, interface group ID and class ID
				my ($rawInterfaceGroupID,$rawClassID) = split(/:/,$classIDSpec);
				if (!defined($rawInterfaceGroupID)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource for class has invalid format '$classIDSpec'"
					);
				}
				if (!defined($rawClassID)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource for class has invalid format '$classIDSpec'"
					);
				}

				# Get more sane values...
				my $interfaceGroup = getInterfaceGroup($rawInterfaceGroupID);
				if (!defined($interfaceGroup)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource has invalid interface group '$rawInterfaceGroupID'"
					);
				}
				my $classID = isTrafficClassIDValid($rawClassID);
				if (!defined($classID)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource has invalid class '$rawClassID'"
					);
				}

				# Loop with both directions
				foreach my $direction ('Tx','Rx') {
					my $interfaceDevice = $interfaceGroup->{"${direction}Interface"};
					# Grab stats ID
					my $sid = opentrafficshaper::plugins::statistics::getSIDFromCID($interfaceDevice,$classID);
					if (!defined($sid)) {
						return (
								opentrafficshaper::plugins::webserver::WS_FAIL,
								"Datasource stats for class '$classID' on interface '$interfaceDevice' not found"
						);
					}
					# Add SID to SID list that we need to subscribe to
					push(@sidList,{'SID' => $sid, 'Conversions' => { 'Direction' => lc($direction) }});
				}
			}
		}

		if (defined($datasets->{'interface-group'})) {
			# Loop with interface-group specifications
			foreach my $interfaceGroupSpec (@{$datasets->{'interface-group'}}) {
				# Check we have a tag, interface group ID and class ID
				my ($rawInterfaceGroupID) = split(/:/,$interfaceGroupSpec);
				if (!defined($rawInterfaceGroupID)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource for interface group has invalid format '$interfaceGroupSpec'"
					);
				}

				# Get more sane values...
				my $interfaceGroup = getInterfaceGroup($rawInterfaceGroupID);
				if (!defined($interfaceGroup)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource has invalid interface group '$rawInterfaceGroupID'"
					);
				}

				# Loop with both directions
				foreach my $direction ('Tx','Rx') {
					my $interfaceDevice = $interfaceGroup->{"${direction}Interface"};
					# Grab stats ID using a small direction hack
					my $sid = opentrafficshaper::plugins::statistics::getSIDFromCID($interfaceDevice,0);
					if (!defined($sid)) {
						return (
								opentrafficshaper::plugins::webserver::WS_FAIL,
								"Datasource stats for interface '$interfaceDevice' not found"
						);
					}
					# Add SID to SID list that we need to subscribe to
					push(@sidList,{'SID' => $sid, 'Conversions' => { 'Direction' => lc($direction) }});
				}
			}
		}

		if (defined($datasets->{'counter'})) {
			# Loop with counter specifications
			foreach my $counterSpec (@{$datasets->{'counter'}}) {
				# Check we have a tag and counter
				my ($rawCounter) = split(/:/,$counterSpec);
				if (!defined($rawCounter)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource for counter has invalid format '$counterSpec'"
					);
				}
				# Grab the SID
				my $sid = opentrafficshaper::plugins::statistics::getSIDFromCounter($rawCounter);
				if (!defined($sid)) {
					return (
							opentrafficshaper::plugins::webserver::WS_FAIL,
							"Datasource stats for counter not found '$rawCounter'"
					);
				}
				# Add SID to SID list that we need to subscribe to
				push(@sidList,{'SID' => $sid, 'Conversions' => { 'Name' => $rawCounter }});
			}
		}

		# No datasources?
		if (!@sidList) {
			return (
					opentrafficshaper::plugins::webserver::WS_FAIL,
					"Failed to identify any subscription requests"
			);
		}

		# Loop wiht subscription list
		foreach my $item (@sidList) {
			my $ssid = opentrafficshaper::plugins::statistics::subscribe(
					$item->{'SID'},
					$item->{'Conversions'},
					'plugin.webserver.websockets.statistics',
					'websocket.send'
			);
			# Save this client and the streaming id (ssid) we got back
			$subscriberMap->{$ssid} = $subscribers->{$client_session_id}->{$ssid} = {
				'Tag' => $tag,
				'SID' => $item->{'SID'},
				'Socket' => $socket
			};
		}

		return (opentrafficshaper::plugins::webserver::WS_OK,"Subscribed");

	# No command at all
	} else {
		return (opentrafficshaper::plugins::webserver::WS_ERROR,"Function '$request->{'function'}' does not exist");
	}

	return (opentrafficshaper::plugins::webserver::WS_OK,"Function not found");
}


#
# Internal functions
#


# Return a json dataset
sub _json_data
{
	my $data = shift;


	# Build the structure we're going to encode
	my $res;
	$res->{'status'} = "success";
	$res->{'data'} = $data;
	# Use ID of 0 to signify out of band data
	$res->{'id'} = -1;

	return encode_json($res);
}


1;
# vim: ts=4
