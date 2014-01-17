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

use opentrafficshaper::logger;
use opentrafficshaper::utils qw(
	parseKeyPairString
);

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

# Copy of system globals
my $globals;
my $logger;

# Stats subscriptsions
my $subscribers = {}; # Connections subscribed, indexed by client_session_id then ssid
my $subscriberMap = {}; # Index of connections by ssid


# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

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

	# Destroy data
	$globals = undef;

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
			foreach my $item (keys $tstat) {
				# Add the keys to the data to return
				push(@{$rawData->{$item}->{'data'}},[
						$timestamp,
						$tstat->{$item}
				]);
			}
		}

		my $socket = $subscriberMap->{$ssid}->{'socket'};
		my $tag = $subscriberMap->{$ssid}->{'tag'};

		$socket->put(_json_success({ $tag => $rawData }));
	}

}


# HTTP to WebSocket
sub graphdata_websocket_disconnect
{
	my ($kernel,$globals,$client_session_id) = @_;


	my $logger = $globals->{'logger'};

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


	my $logger = $globals->{'logger'};

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


	# Rip off tag
	my $tag;
	if ($request =~ s/^([a-zA-Z0-9]+) //) {
		$tag = $1;
	} else {
		return (0,_json_error("Invalid command format, use: <tag> <command> ..."));
	}

	# Parse the command we got...
	if ($request =~ /^subscribe\s+(.*)/i) {
		my $params = parseKeyPairString($1);

		# Parse params
		my @sidList;
		if (defined($params->{'pool'})) {
			# Loop with pool specifications
			foreach my $poolSpec (@{$params->{'pool'}->{'values'}}) {
				# Split interface group id and pool name
				my ($rawInterfaceGroupID,$rawPoolName) = split(/:/,$poolSpec);
				if (!defined($rawInterfaceGroupID)) {
					return (0,_json_error("Tag '$tag' datasource has invalid format '$poolSpec'"));
				}
				if (!defined($rawPoolName)) {
					return (0,_json_error("Tag '$tag' datasource has invalid format '$poolSpec'"));
				}

				# Check if we can grab the interface group
				my $interfaceGroup = getInterfaceGroup($rawInterfaceGroupID);
				if (!defined($interfaceGroup)) {
					return (0,_json_error("Tag '$tag' datasource has invalid interface ID '$rawInterfaceGroupID'"));
				}

				# Check if the pool name exists
				my $pool = getPoolByName($rawInterfaceGroupID,$rawPoolName);
				if (!defined($pool)) {
					return (0,_json_error("Tag '$tag' datasource pool not found '$rawPoolName'"));
				}
				# Check if we have a stats ID
				my $sid = opentrafficshaper::plugins::statistics::getSIDFromPID($pool->{'ID'});
				if (!defined($sid)) {
					return (0,_json_error("Tag '$tag' datasource stats for pool not found '$rawPoolName'"));
				}

				# Add SID to SID list that we need to subscribe to
				push(@sidList,{'sid' => $sid});
			}
		}

		if (defined($params->{'class'})) {
			# Loop with class specifications
			foreach my $classIDSpec (@{$params->{'class'}->{'values'}}) {
				# Check we have a tag, interface group ID and class ID
				my ($rawInterfaceGroupID,$rawClassID) = split(/:/,$classIDSpec);
				if (!defined($rawInterfaceGroupID)) {
					return (0,_json_error("Tag '$tag' datasource has invalid format '$classIDSpec'"));
				}
				if (!defined($rawClassID)) {
					return (0,_json_error("Tag '$tag' datasource has invalid format '$classIDSpec'"));
				}

				# Get more sane values...
				my $interfaceGroup = getInterfaceGroup($rawInterfaceGroupID);
				if (!defined($interfaceGroup)) {
					return (0,_json_error("Tag '$tag' datasource has invalid interface ID '$rawInterfaceGroupID'"));
				}
				my $classID = isTrafficClassIDValid($rawClassID);
				if (!defined($classID)) {
					return (0,_json_error("Tag '$tag' datasource has invalid class ID '$rawClassID'"));
				}

				# Loop with both directions
				foreach my $direction ('tx','rx') {
					# Grab stats ID
					my $sid = opentrafficshaper::plugins::statistics::getSIDFromCID($interfaceGroup->{"${direction}iface"},
							$classID);
					if (!defined($sid)) {
						return (0,_json_error("Tag '$tag' datasource stats for class ID not found '$classID'"));
					}
					# Add SID to SID list that we need to subscribe to
					push(@sidList,{'sid' => $sid, 'conversions' => { 'direction' => $direction }});
				}
			}
		}

		if (defined($params->{'interface-group'})) {
			# Loop with interface-group specifications
			foreach my $interfaceGroupSpec (@{$params->{'interface-group'}->{'values'}}) {
				# Check we have a tag, interface group ID and class ID
				my ($rawInterfaceGroupID) = split(/:/,$interfaceGroupSpec);
				if (!defined($rawInterfaceGroupID)) {
					return (0,_json_error("Tag '$tag' atasource has invalid format '$interfaceGroupSpec'"));
				}

				# Get more sane values...
				my $interfaceGroup = getInterfaceGroup($rawInterfaceGroupID);
				if (!defined($interfaceGroup)) {
					return (0,_json_error("Tag '$tag' Datasource has invalid interface ID '$rawInterfaceGroupID'"));
				}

				# Loop with both directions
				foreach my $direction ('tx','rx') {
					# Grab stats ID using a small direction hack
					my $sid = opentrafficshaper::plugins::statistics::getSIDFromCID($interfaceGroup->{"${direction}iface"},0);
					if (!defined($sid)) {
						return (0,_json_error("Tag '$tag' Datasource stats for interface group ID not found ".
									"'$rawInterfaceGroupID'"));
					}
					# Add SID to SID list that we need to subscribe to
					push(@sidList,{'sid' => $sid, 'conversions' => { 'direction' => $direction }});
				}
			}
		}

		if (defined($params->{'counter'})) {
			# Loop with counter specifications
			foreach my $counterSpec (@{$params->{'counter'}->{'values'}}) {
				# Check we have a tag and counter
				my ($rawCounter) = split(/:/,$counterSpec);
				if (!defined($rawCounter)) {
					return (0,_json_error("Tag '$tag' datasource has invalid format '$counterSpec'"));
				}
				# Grab the SID
				my $sid = opentrafficshaper::plugins::statistics::getSIDFromCounter($rawCounter);
				if (!defined($sid)) {
					return (0,_json_error("Tag '$tag' datasource stats for counter not found '$rawCounter'"));
				}
				# Add SID to SID list that we need to subscribe to
				push(@sidList,{'sid' => $sid});
			}
		}

		# No datasources?
		if (!@sidList) {
			return (0,_json_error("Tag '$tag' invalid subscribe command, use: <tag> subscribe <pool|class>=<id>"));
		}

		# Loop wiht subscription list
		foreach my $item (@sidList) {
			my $ssid = opentrafficshaper::plugins::statistics::subscribe(
					$item->{'sid'},
					$item->{'conversions'},
					'plugin.webserver.websockets.statistics',
					'websocket.send'
			);
			# Save this client and the streaming id (ssid) we got back
			$subscriberMap->{$ssid} = $subscribers->{$client_session_id}->{$ssid} = {
				'tag' => $tag,
				'sid' => $item->{'sid'},
				'socket' => $socket
			};
		}

		return (0,_json_success("$tag Subscription completed"));

	# No command at all
	} else {
		return (0,_json_error("$tag Invalid command: $request"));
	}

	return (0,"ERM");
}


#
# Internal functions
#


# Return a json error
sub _json_error
{
	my ($message,$data) = @_;


	# Build the structure we're going to encode
	my $res;
	$res->{'status'} = "error";
	$res->{'message'} = $message;
	if (defined($data)) {
		$res->{'data'} = $data;
	}

	return encode_json($res);
}


# Return a json error
sub _json_success
{
	my $data = shift;


	# Build the structure we're going to encode
	my $res;
	$res->{'status'} = "success";
	$res->{'data'} = $data;

	return encode_json($res);
}


1;
# vim: ts=4
