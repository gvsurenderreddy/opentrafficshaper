# OpenTrafficShaper radius module
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



package opentrafficshaper::plugins::radius;

use strict;
use warnings;


use opentrafficshaper::plugins::radius::Radius::Dictionary;
use opentrafficshaper::plugins::radius::Radius::Packet;

use POE;
use IO::Socket::INET;

use opentrafficshaper::logger;
use awitpt::util;
use opentrafficshaper::plugins::configmanager qw(
	createPool
	changePool

	createPoolMember
	changePoolMember

	createLimit

	getPoolByName
	getPoolMember
	getPoolMembers
	getPoolMemberByUsernameIP

	isInterfaceGroupIDValid
	isTrafficClassIDValid
	isMatchPriorityIDValid
	isGroupIDValid
);


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
);

use constant {
	VERSION => '0.2.1',

	DATAGRAM_MAXLEN => 8192,

	DEFAULT_EXPIRY_PERIOD => 86400,

	# Expirty period for removal of entries
	REMOVE_EXPIRY_PERIOD => 60,

	# IANA public enterprise number
	# This is used as the radius vendor code
	IANA_PEN => 42109,
};


# Plugin info
our $pluginInfo = {
	Name => "Radius",
	Version => VERSION,

	Init => \&plugin_init,
	Start => \&plugin_start,
};


# Our globals
my $globals;
# Copy of system logger
my $logger;


# Our own data storage
my $config = {
	'expiry_period' => DEFAULT_EXPIRY_PERIOD,
	'username_to_pool_transform' => undef,
	'interface_group' => 'eth1,eth0',
	'match_priority' => 2,
	'traffic_class' => 2,
	'group' => 1,
};



# Initialize plugin
sub plugin_init
{
	my $system = shift;


	# Setup our environment
	$logger = $system->{'logger'};

	$logger->log(LOG_NOTICE,"[RADIUS] OpenTrafficShaper Radius Module v%s - Copyright (c) 2013-2014, AllWorldIT",VERSION);

	# Inititalize
	$globals->{'Dictionary'} = undef;

	# Split off dictionaries to load
	my @dicts = ref($system->{'file.config'}->{'plugin.radius'}->{'dictionary'}) eq "ARRAY" ?
			@{$system->{'file.config'}->{'plugin.radius'}->{'dictionary'}} :
			( $system->{'file.config'}->{'plugin.radius'}->{'dictionary'} );

	foreach my $dict (@dicts) {
		$dict =~ s/\s+//g;
 		# Skip comments
 		next if ($dict =~ /^#/);
		# Check if we have a path, if we do use it
		if (defined($system->{'file.config'}->{'plugin.radius'}->{'dictionary_path'})) {
			$dict = $system->{'file.config'}->{'plugin.radius'}->{'dictionary_path'} . "/$dict";
		}
		push(@{$config->{'config.dictionaries'}},$dict);
	}

	# Load dictionaries
	$logger->log(LOG_DEBUG,"[RADIUS] Loading dictionaries...");
	my $dict = new opentrafficshaper::plugins::radius::Radius::Dictionary;
	foreach my $df (@{$config->{'config.dictionaries'}}) {
		# Load dictionary
		if ($dict->readfile($df)) {
			$logger->log(LOG_INFO,"[RADIUS] Loaded dictionary '%s'",$df);
		} else {
			$logger->log(LOG_WARN,"[RADIUS] Failed to load dictionary '%s': %s",$df,$!);
		}
	}
	$logger->log(LOG_DEBUG,"[RADIUS] Loading dictionaries completed.");
	# Store the dictionary
	$globals->{'Dictionary'} = $dict;

	# Check if we must override the expiry time
	if (defined(my $expiry = $system->{'file.config'}->{'plugin.radius'}->{'expiry_period'})) {
		$logger->log(LOG_INFO,"[RADIUS] Set expiry_period to '%s'",$expiry);
		$config->{'expiry_period'} = $expiry;
	}

	# Check if we got a username to pool transform
	if (defined(my $userPoolTransform = $system->{'file.config'}->{'plugin.radius'}->{'username_to_pool_transform'})) {
		$logger->log(LOG_INFO,"[RADIUS] Set username_to_pool_transform to '%s'",$userPoolTransform);
		$config->{'username_to_pool_transform'} = $userPoolTransform;
	}

	# Default interface group to use
	if (defined(my $interfaceGroup = $system->{'file.config'}->{'plugin.radius'}->{'default_interface_group'})) {
		if (isInterfaceGroupIDValid($interfaceGroup)) {
			$logger->log(LOG_INFO,"[RADIUS] Set interface_group to '%s'",$interfaceGroup);
			$config->{'interface_group'} = $interfaceGroup;
		} else {
			$logger->log(LOG_WARN,"[RADIUS] Cannot set 'interface_group' as value '%s' is invalid",$interfaceGroup);
		}
	} else {
		$logger->log(LOG_INFO,"[RADIUS] Using default interface_group '%s'",$config->{'interface_group'});
	}

	# Default match priority to use
	if (defined(my $matchPriority = $system->{'file.config'}->{'plugin.radius'}->{'default_match_priority'})) {
		if (isMatchPriorityIDValid($matchPriority)) {
			$logger->log(LOG_INFO,"[RADIUS] Set match_priority to '%s'",$matchPriority);
			$config->{'match_priority'} = $matchPriority;
		} else {
			$logger->log(LOG_WARN,"[RADIUS] Cannot set 'match_priority' as value '%s' is invalid",$matchPriority);
		}
	}

	# Default traffic class to use
	if (defined(my $trafficClassID = $system->{'file.config'}->{'plugin.radius'}->{'default_traffic_class'})) {
		if (isTrafficClassIDValid($trafficClassID)) {
			$logger->log(LOG_INFO,"[RADIUS] Set traffic_class to '%s'",$trafficClassID);
			$config->{'traffic_class'} = $trafficClassID;
		} else {
			$logger->log(LOG_WARN,"[RADIUS] Cannot set 'traffic_class' as value '%s' is invalid",$trafficClassID);
		}
	}

	# Default group to use
	if (defined(my $group = $system->{'file.config'}->{'plugin.radius'}->{'default_group'})) {
		if (isGroupIDValid($group)) {
			$logger->log(LOG_INFO,"[RADIUS] Set group to '%s'",$group);
			$config->{'group'} = $group;
		} else {
			$logger->log(LOG_WARN,"[RADIUS] Cannot set 'group' as value '%s' is invalid",$group);
		}
	}

	# Radius listener
	POE::Session->create(
		inline_states => {
			_start => \&_session_start,
			_stop => \&_session_stop,
			_socket_read => \&_session_socket_read,
		}
	);

	return 1;
}



# Start the plugin
sub plugin_start
{
	$logger->log(LOG_INFO,"[RADIUS] Started");
}



# Initialize server
sub _session_start
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Create socket for radius
	if (!defined($heap->{'socket'} = IO::Socket::INET->new(
			Proto => 'udp',
# TODO - Add to config file
#			LocalAddr => '192.168.254.2',
			LocalPort => '1813',
	))) {
		$logger->log(LOG_ERR,"Failed to create Radius listening socket: %s",$!);
		return;
	}

	# Set our alias
	$kernel->alias_set("plugin.radius");

	# Setup our socket reader event
	$kernel->select_read($heap->{'socket'}, "_socket_read");

	$logger->log(LOG_DEBUG,"[RADIUS] Initialized");
}



# Shut down server
sub _session_stop
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Tear down the socket select
	if (defined($heap->{'socket'})) {
		$kernel->select_read($heap->{'socket'},undef);
	}

	# Blow everything away
	$globals = undef;

	$logger->log(LOG_DEBUG,"[RADIUS] Shutdown");

	$logger = undef;
}



# Read event for server
sub _session_socket_read
{
	my ($kernel, $socket) = @_[KERNEL, ARG0];


	# Read in packet from the socket
	my $peer = recv($socket, my $udp_packet = "", DATAGRAM_MAXLEN, 0);
	# If we don't have a peer, just return
	if (!defined($peer)) {
		$logger->log(LOG_WARN,"[RADIUS] Peer appears to be undefined");
		return;
	}

	# Get peer port and addy from remote host
	my ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);
	my $peer_addr_h = inet_ntoa($peer_addr);

	# Parse packet
	my $pkt = opentrafficshaper::plugins::radius::Radius::Packet->new($globals->{'Dictionary'},$udp_packet);

	# Build log line
	my $logLine = sprintf("Remote: %s:%s, Code: %s, Identifier: %s => ",$peer_addr_h,$peer_port,$pkt->code,$pkt->identifier);
	foreach my $attr ($pkt->attributes) {
		$logLine .= sprintf(" %s: '%s',", $attr, $pkt->rawattr($attr));
	}
	# Add vattributes onto logline
	$logLine .= ". VREPLY => ";
	# Loop with vendors
	foreach my $vendor ($pkt->vendors()) {
		# Loop with attributes
		foreach my $attr ($pkt->vsattributes($vendor)) {
			# Grab the value
			my @attrRawVal = ( $pkt->vsattr($vendor,$attr) );
			my $attrVal = $attrRawVal[0][0];
			# Sanatize it a bit
			if ($attrVal =~ /[[:cntrl:]]/) {
				$attrVal = "-nonprint-";
			} else {
				$attrVal = "'$attrVal'";
			}

			$logLine .= sprintf(" %s/%s: %s,",$vendor,$attr,$attrVal);
		}
	}
	$logger->log(LOG_DEBUG,"[RADIUS] %s",$logLine);


	# TODO - verify packet

	# Time now
	my $now = time();

	# Pull in a variables from packet
	my $username = $pkt->rawattr("User-Name");
	my $group = $config->{'group'};
	if (my $attrRawVal = $pkt->vsattr(IANA_PEN,'OpenTrafficShaper-Traffic-Group')) {
		my $var = @{ $attrRawVal }[0];
		# Next check if its valid
		if (isGroupIDValid($var)) {
			$group = $var;
		} else {
			$logger->log(LOG_WARN,"[RADIUS] Cannot set 'group' for user '%s' as value '%s' is invalid, using default '%s'",
					$username,
					$var,
					$group
			);
		}
	}
	my $trafficClassID = $config->{'traffic_class'};
	if (my $attrRawVal = $pkt->vsattr(IANA_PEN,'OpenTrafficShaper-Traffic-Class')) {
		my $var = @{ $attrRawVal }[0];
		# Check if its valid
		if (isTrafficClassIDValid($var)) {
			$trafficClassID = $var;
		} else {
			$logger->log(LOG_WARN,"[RADIUS] Cannot set 'traffic_class' for user '%s' as value '%s' is invalid, using default '%s'",
					$username,
					$var,
					$trafficClassID
			);
		}
	}

	my $trafficLimit;
	if (my $attrRawVal = $pkt->vsattr(IANA_PEN,'OpenTrafficShaper-Traffic-Limit')) {
		$trafficLimit = @{ $attrRawVal }[0];
	}
	# We assume below that we will have limits
	if (!defined($trafficLimit)) {
		$logger->log(LOG_NOTICE,"[RADIUS] No traffic limit set for user '%s', ignoring",$username);
		return;
	}
	# Grab rate limits below from the string we got
	my $rxCIR; my $txCIR;
	my $rxLimit; my $txLimit;
	# Match rx-rate[/tx-rate] rx-burst-rate[/tx-burst-rate]
	if ($trafficLimit =~ /^(\d+)([km])(?:\/(\d+)([km]))?(?: (\d+)([km])(?:\/(\d+)([km]))?)?/) {
		$rxCIR = getKbit($1,$2);
		$txCIR = getKbit($3,$4);
		$rxLimit = getKbit($5,$6);
		$txLimit = getKbit($7,$8);

		# Set our limits if they not defined
		if (!defined($rxLimit)) {
			$rxLimit = $rxCIR;
			$rxCIR = $rxCIR / 4;
		}
		if (!defined($txLimit)) {
			$txLimit = $txCIR;
			$txCIR = $txCIR / 4;
		}

	} else {
		$logger->log(LOG_WARN,"[RADIUS] The 'OpenTrafficShaper-Traffic-Limit' attribute appears to be invalid for user '%s'".
				": '%s'",
				$username,
				$trafficLimit
		);
		return;
	}

	# Check if we have a pool transform
	my $poolName;
	if (defined($config->{'username_to_pool_transform'})) {
		# Check if transform matches, if it does set pool name
		if ($username =~ $config->{'username_to_pool_transform'}) {
			$poolName = $1;
		}
	}

	# Check if the pool name is being overridden
	if (my $attrRawVal = $pkt->vsattr(IANA_PEN,'OpenTrafficShaper-Traffic-Pool')) {
		$poolName = @{ $attrRawVal }[0];
	}

	# If we got a pool name, check if it exists
	if (defined($poolName)) {
		if (!defined(getPoolByName($config->{'interface_group'},$poolName))) {
			$logger->log(LOG_NOTICE,"[RADIUS] Pool '%s' not found, using username '%s' instead",
				$poolName,
				$username
			);
			$poolName = $username;
		}
	# If we didn't get the pool name, just use the username
	} else {
		$poolName = $username;
	}

	# Try grab the pool
	my $pool = getPoolByName($config->{'interface_group'},$poolName);
	my $pid = defined($pool) ? $pool->{'ID'} : undef;

	my $ipAddress = $pkt->attr('Framed-IP-Address');
	my $statusType = getStatus($pkt->rawattr('Acct-Status-Type'));

	$logger->log(LOG_INFO,"[RADIUS] Status: %s, User: %s, IP: %s, InterfaceGroup: %s, MatchPriorityID: %s, Group: %s, Class: %s, ".
			"CIR: %s/%s, Limit: %s/%s",
			$statusType,
			$username,
			$ipAddress,
			$config->{'interface_group'},
			$config->{'match_priority'},
			$group,
			$trafficClassID,
			prettyUndef($txCIR),
			prettyUndef($rxCIR),
			prettyUndef($txLimit),
			prettyUndef($rxLimit)
	);

	# Check if user is new or online
	if ($statusType eq "new" || $statusType eq "online") {
		# Check if pool is defined
		if (defined($pool)) {
			my @poolMembers = getPoolMembers($pid);

			# Check if we created the pool
			if ($pool->{'Source'} eq "plugin.radius") {
				# Make sure the pool is 0 or 1
				if (@poolMembers < 2) {
					# Change the details
					my $changes = changePool({
							'ID' => $pid,
							'TrafficClassID' => $trafficClassID,
							'TxCIR' => $txCIR,
							'RxCIR' => $rxCIR,
							# These MUST be defined
							'TxLimit' => $txLimit,
							'RxLimit' => $rxLimit,

							'Expires' => $now + DEFAULT_EXPIRY_PERIOD
					});

					my @txtChanges;
					foreach my $item (keys %{$changes}) {
						# Make expires look nice
						my $value = $changes->{$item};
						if ($item eq "Expires") {
							$value = sprintf("%s [%s]",$value,scalar(localtime($value)));
						}
						push(@txtChanges,sprintf("%s = %s",$item,$value));
					}
					if (@txtChanges) {
						$logger->log(LOG_INFO,"[RADIUS] Pool '%s' updated: %s",$poolName,join(", ",@txtChanges));
					}

				# If we do have more than 1 member, make a note of it
				} else {
					$logger->log(LOG_NOTICE,"[RADIUS] Pool '%s' has more than 1 member, not updating",$poolName);
				}
			}

		# No pool, time to create one
		} else {
			# If we don't have rate limits, short circuit
			if (!defined($txCIR)) {
				$logger->log(LOG_NOTICE,"[RADIUS] Pool '%s' has no 'TxCIR', aborting",$poolName);
				return;
			}
			if (!defined($rxCIR)) {
				$logger->log(LOG_NOTICE,"[RADIUS] Pool '%s' has no 'RxCIR', aborting",$poolName);
				return;
			}

			# Create pool
			$pid = createPool({
					'FriendlyName' => $ipAddress,
					'Name' => $poolName,
					'InterfaceGroupID' => $config->{'interface_group'},
					'TrafficClassID' => $trafficClassID,
					'TxCIR' => $txCIR,
					'RxCIR' => $rxCIR,
					'TxLimit' => $txLimit,
					'RxLimit' => $rxLimit,
					'Expires' => $now + $config->{'expiry_period'},
					'Source' => "plugin.radius",
			});
			if (!defined($pid)) {
				$logger->log(LOG_WARN,"[RADIUS] Pool '%s' failed to create, aborting",$poolName);
				return;
			}
		}

		# If we have a pool member
		if (defined(my $pmid = getPoolMemberByUsernameIP($pid,$username,$ipAddress))) {
			my $poolMember = getPoolMember($pmid);

			# Check if we created the pool member
			if ($poolMember->{'Source'} eq "plugin.radius") {

				my $changes = changePoolMember({
						'ID' => $poolMember->{'ID'},
						'Expires' => $now + DEFAULT_EXPIRY_PERIOD
				});

				my @txtChanges;
				foreach my $item (keys %{$changes}) {
					# Make expires look nice
					my $value = $changes->{$item};
					if ($item eq "Expires") {
						$value = sprintf("%s [%s]",$value,scalar(localtime($value)));
					}
					push(@txtChanges,sprintf("%s = %s",$item,$value));
				}
				if (@txtChanges) {
					$logger->log(LOG_INFO,"[RADIUS] Pool '%s' member '%s' updated: %s",
							$poolName,
							$username,
							join(", ",@txtChanges)
					);
				}

				# TODO: Add output of updated items here too?
				changePool({
						'ID' => $pid,
						'FriendlyName' => $ipAddress
				});


			# If not display message
			} else {
				$logger->log(LOG_NOTICE,"[RADIUS] Pool '%s' member '%s' update ignored as it was not added by 'plugin.radius'",
						$poolName,
						$username
				);
			}

		# We have a pool but no member...
		} else {
			createPoolMember({
				'FriendlyName' => $username,
				'Username' => $username,
				'IPAddress' => $ipAddress,
				'InterfaceGroupID' => $config->{'interface_group'},
				'MatchPriorityID' => $config->{'match_priority'},
				'PoolID' => $pid,
				'GroupID' => $group,
				'Expires' => $now + $config->{'expiry_period'},
				'Source' => "plugin.radius",
			});

			# TODO: Add output of updated items here too?
			changePool({
					'ID' => $pid,
					'FriendlyName' => $ipAddress
			});
		}

	# Radius user going offline
	} elsif ($statusType eq "offline") {

		# Check if we have a pool
		if (defined($pool)) {
			# Grab pool members
			my @poolMembers = getPoolMembers($pool->{'ID'});

			# If this is ours we can set the expires to "queue" removal
			if ($pool->{'Source'} eq "plugin.radius") {
				# If there is only 1 pool member, then lets expire the pool in the removal expiry period
				if (@poolMembers == 1) {
					$logger->log(LOG_INFO,"[RADIUS] Expiring pool '$poolName'");
					changePool({
							'ID' => $pool->{'ID'},
							'Expires' => $now + REMOVE_EXPIRY_PERIOD
					});
				}
			}

			# Check if we have a pool member with this username and IP
			if (my $pmid = getPoolMemberByUsernameIP($pool->{'ID'},$username,$ipAddress)) {
				$logger->log(LOG_INFO,"[RADIUS] Expiring pool '$poolName' member '$username'");
				changePoolMember({
						'ID' => $pmid,
						'Expires' => $now + REMOVE_EXPIRY_PERIOD
				});
			}

			$logger->log(LOG_INFO,"[RADIUS] Pool '$poolName' member '$username' set to expire as they're offline");

		# No pool
		} else {
			$logger->log(LOG_DEBUG,"[RADIUS] Pool '$poolName' member '$username' doesn't exist went offline");
		}


	} else {
		$logger->log(LOG_WARN,"[RADIUS] Unknown radius code '%s' for pool '%s' member '%s'",$pkt->code,$poolName,$username);
	}

}



# Convert status into something easy to useful
sub getStatus
{
	my $status = shift;

	if ($status == 1) {
		return "new";
	} elsif ($status == 2) {
		return "offline";
	} elsif ($status == 3) {
		return "online";
	} else {
		return "unknown";
	}
}



# Simple function to reduce everything to kbit
sub getKbit
{
	my ($counter,$quantifier) = @_;

	# If there is no counter
	return undef if (!defined($counter));

	# We need a quantifier
	return undef if (!defined($quantifier));

	# Initialize counter
	my $newCounter = $counter;

	if ($quantifier =~ /^m$/i) {
		$newCounter = $counter * 1024;
	} elsif ($quantifier =~ /^k$/i) {
		$newCounter = $counter * 1;
	} else {
		return undef;
	}

	return $newCounter;
}



1;
# vim: ts=4
