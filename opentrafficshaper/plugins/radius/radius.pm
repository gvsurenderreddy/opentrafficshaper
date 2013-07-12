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


use opentrafficshaper::plugins::radius::Radius::Dictionary;
use opentrafficshaper::plugins::radius::Radius::Packet;

use POE;
use IO::Socket::INET;

use opentrafficshaper::logger;
use opentrafficshaper::utils;


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
	DEFAULT_EXPIRY_PERIOD => 86400,
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

	# Signals
	signal_SIGHUP => \&handle_SIGHUP,
};


# Copy of system globals
my $globals;
my $logger;
# Our own data storage
my $config = {
	'expiry_period' => DEFAULT_EXPIRY_PERIOD
};

my $dictionary;


# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[RADIUS] OpenTrafficShaper Radius Module v".VERSION." - Copyright (c) 2013, AllWorldIT");

	# Split off dictionaries to load
	my @dicts = ref($globals->{'file.config'}->{'plugin.radius'}->{'dictionary'}) eq "ARRAY" ? 
			@{$globals->{'file.config'}->{'plugin.radius'}->{'dictionary'}} : ( $globals->{'file.config'}->{'plugin.radius'}->{'dictionary'} );
	foreach my $dict (@dicts) {
		$dict =~ s/\s+//g;
 		# Skip comments
 		next if ($dict =~ /^#/);
		# Check if we have a path, if we do use it
		if (defined($globals->{'file.config'}->{'plugin.radius'}->{'dictionary_path'})) {
			$dict = $globals->{'file.config'}->{'plugin.radius'}->{'dictionary_path'} . "/$dict";
		}
		push(@{$config->{'config.dictionaries'}},$dict);
	}

	# Load dictionaries
	$logger->log(LOG_DEBUG,"[RADIUS] Loading dictionaries...");
	my $dict = new opentrafficshaper::plugins::radius::Radius::Dictionary;
	foreach my $df (@{$config->{'config.dictionaries'}}) {
		# Load dictionary
		if ($dict->readfile($df)) {
			$logger->log(LOG_INFO,"[RADIUS] Loaded dictionary '$df'.");
		} else {
			$logger->log(LOG_WARN,"[RADIUS] Failed to load dictionary '$df': $!");
		}
	}
	$logger->log(LOG_DEBUG,"[RADIUS] Loading dictionaries completed.");
	# Store the dictionary
	$dictionary = $dict;

	# Check if we must override the expiry time
	if (defined(my $expiry = $globals->{'file.config'}->{'plugin.radius'}->{'expiry_period'})) {
		$logger->log(LOG_INFO,"[RADIUS] Set expiry_period to '$expiry'");
		$config->{'expiry_period'} = $expiry;
	}

	# Radius listener
	POE::Session->create(
		inline_states => {
			_start => \&server_init,
			get_datagram => \&server_read,
		}
	);
}


# Start the plugin
sub plugin_start
{
	$logger->log(LOG_INFO,"[RADIUS] Started");
}



# Initialize server
sub server_init {
	my $kernel = $_[KERNEL];

	my $socket = IO::Socket::INET->new(
		Proto	 => 'udp',
		LocalPort => '1813',
	);
	die "Couldn't create server socket: $!" unless $socket;

	# Set our alias
	$kernel->alias_set("plugin.radius");

	# Setup our reader
	$kernel->select_read($socket, "get_datagram");

	$logger->log(LOG_DEBUG,"[RADIUS] Initialized");
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
	my $pkt = new opentrafficshaper::plugins::radius::Radius::Packet($dictionary,$udp_packet);

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

	# Time now
	my $now = time();

	# Pull in a variables from packet
	my $username = $pkt->rawattr("User-Name");
	my $trafficGroup;
	if (my $attrRawVal = $pkt->vsattr(IANA_PEN,'OpenTrafficShaper-Traffic-Group')) {
		$trafficGroup = @{ $attrRawVal }[0];
	}
	my $trafficClass;
	if (my $attrRawVal = $pkt->vsattr(IANA_PEN,'OpenTrafficShaper-Traffic-Class')) {
		$trafficClass = @{ $attrRawVal }[0];
	}
	my $trafficLimit;
	if (my $attrRawVal = $pkt->vsattr(IANA_PEN,'OpenTrafficShaper-Traffic-Limit')) {
		$trafficLimit = @{ $attrRawVal }[0];
	}

	# Grab rate limits from the string we got
	my $trafficLimitRx; my $trafficLimitTx;
	my $trafficLimitRxBurst; my $trafficLimitTxBurst;
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
		$trafficGroup = 1;
	}
	if (!defined($trafficClass)) {
		$trafficClass = 1;
	}

	# FIXME: NK - better way?
	# If we don't have rate limits, short circuit
	if (!defined($trafficLimitTx)) {
		$trafficLimitTx = 1000;
		return;
	}
	if (!defined($trafficLimitRx)) {
		$trafficLimitRx = 200;
		return;
	}

	# Build user
	my $user = {
		'Username' => $username,
		'IP' => $pkt->attr('Framed-IP-Address'),
		'GroupID' => $trafficGroup,
		'ClassID' => $trafficClass,
		'TrafficLimitTx' => $trafficLimitTx,
		'TrafficLimitRx' => $trafficLimitRx,
		'TrafficLimitTxBurst' => $trafficLimitTxBurst,
		'TrafficLimitRxBurst' => $trafficLimitRxBurst,
		'Expires' => $now + (defined($globals->{'file.config'}->{'plugin.radius'}->{'expire_entries'}) ? 
				$globals->{'file.config'}->{'plugin.radius'}->{'expire_entries'} : $config->{'expiry_period'}),
		'Status' => getStatus($pkt->rawattr('Acct-Status-Type')),
		'Source' => "plugin.radius",
	};

	# Throw the change at the config manager
	$kernel->post("configmanager" => "process_change" => $user);

	$logger->log(LOG_INFO,"[RADIUS] Code: $user->{'Status'}, User: $user->{'Username'}, IP: $user->{'IP'}, Group: $user->{'GroupID'}, Class: $user->{'ClassID'}, ".
			"Limits: ".prettyUndef($trafficLimitTx)."/".prettyUndef($trafficLimitRx).", Burst: ".prettyUndef($trafficLimitTxBurst)."/".prettyUndef($trafficLimitRxBurst));
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


# Handle SIGHUP
sub handle_SIGHUP
{
	$logger->log(LOG_WARN,"[RADIUS] Got SIGHUP, ignoring for now");
}

1;
# vim: ts=4
