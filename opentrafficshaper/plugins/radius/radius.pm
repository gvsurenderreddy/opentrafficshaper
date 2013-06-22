# OpenTrafficShaper radius module
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



package opentrafficshaper::plugins::radius;

use strict;
use warnings;


use POE;
use IO::Socket::INET;

use opentrafficshaper::logger;



# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
);

use constant {
	VERSION => '0.0.1',
	DATAGRAM_MAXLEN => 8192,
};


# Plugin info
our $pluginInfo = {
	Name => "Radius",
	Version => VERSION,
	
	Init => \&init,
};


# Copy of system globals
my $globals;
my $logger;


# Initialize plugin
sub init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	# Radius listener
	POE::Session->create(
		inline_states => {
			_start => \&server_init,
			get_datagram => \&server_read,
		}
	);

	$logger->log(LOG_NOTICE,"[RADIUS] OpenTrafficShaper Radius Module v".VERSION." - Copyright (c) 2013, AllWorldIT")
}


# Initialize server
sub server_init {
	my $kernel = $_[KERNEL];

	my $socket = IO::Socket::INET->new(
		Proto	 => 'udp',
		LocalPort => '1813',
	);
	die "Couldn't create server socket: $!" unless $socket;

	$kernel->select_read($socket, "get_datagram");
}


# Read event for server
sub server_read {
	my ($kernel, $socket) = @_[KERNEL, ARG0];


	my $peer = recv($socket, my $udp_packet = "", DATAGRAM_MAXLEN, 0);
	# If we don't have a peer, just return
	return unless defined $peer;

	# Get peer port and addy from remote host
	my ($peer_port, $peer_addr) = unpack_sockaddr_in($peer);
	my $peer_addr_h = inet_ntoa($peer_addr);

	# Parse packet
	my $pkt = new Radius::Packet($globals->{'radius'}->{'dictionary'},$udp_packet);

	# Build log line
	my $logLine = sprintf("Remote: $peer_addr_h, Code: %s, Identifier: %s => ",$pkt->code,$pkt->identifier);
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
	$logger->log(LOG_DEBUG,"[RADIUS] $logLine");


	# TODO - verify packet




	# Pull in a variables from packet
	my $username = $pkt->rawattr("User-Name");
	my $trafficGroup;
	if (my $attrRawVal = $pkt->vsattr(11111,'OpenTrafficShaper-Traffic-Group')) {
		$trafficGroup = @{ $attrRawVal }[0];
	}
	my $trafficClass;
	if (my $attrRawVal = $pkt->vsattr(11111,'OpenTrafficShaper-Traffic-Class')) {
		$trafficClass = @{ $attrRawVal }[0];
	}
	my $trafficLimit;
	if (my $attrRawVal = $pkt->vsattr(11111,'OpenTrafficShaper-Traffic-Limit')) {
		$trafficLimit = @{ $attrRawVal }[0];
	}

	# Grab rate limits from the string we got
	my $trafficLimitRx = 0; my $trafficLimitTx = 0;
	my $trafficLimitRxBurst = 0; my $trafficLimitTxBurst = 0;
	if (defined($trafficLimit)) {
		my ($trafficLimitRxQuantifier,$trafficLimitTxQuantifier);
		my ($trafficLimitRxBurstQuantifier,$trafficLimitTxBurstQuantifier);
		# Match rx-rate[/tx-rate] rx-burst-rate[/tx-burst-rate]
		if ($trafficLimit =~ /^(\d+)([km])(?:\/(\d+)([km]))?(?: (\d+)([km])(?:\/(\d+)([km]))?)?/) {
			$trafficLimitRx = getKbit($1,$2);
			$trafficLimitTx = getKbit($3,$4);
			$trafficLimitRxBurst = getKbit($5,$6);
			$trafficLimitTxBurst = getKbit($7,$8);
		}
	}

	# Set default if they undefined
	if (!defined($trafficGroup)) {
		$trafficGroup = 0;
	}
	if (!defined($trafficClass)) {
		$trafficClass = 0;
	}

	my $user = {
		'Username' => $username,
		'IP' => $pkt->attr('Framed-IP-Address'),
		'Group' => $trafficGroup,
		'GroupName' => "Group 1",
		'Class' => $trafficClass,
		'ClassName' => "Class A",
		'Limits' => "$trafficLimitTx / $trafficLimitRx",
		'BurstLimits' => "$trafficLimitTxBurst / $trafficLimitRxBurst",
		'Status' => getStatus($pkt->rawattr('Acct-Status-Type')),
	};

	$globals->{'users'}->{$username} = $user;

	$logger->log(LOG_DEBUG,"=> Code: $user->{'Status'}, User: $user->{'Username'}, IP: $user->{'IP'}, Group: $user->{'Group'}, Class: $user->{'Class'}, Limits: $user->{'Limits'}, Burst: $user->{'BurstLimits'}");
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

	# If there is no counter, return 0
	return 0 if (!defined($counter));

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
