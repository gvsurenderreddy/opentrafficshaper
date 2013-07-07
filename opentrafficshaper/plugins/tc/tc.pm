# OpenTrafficShaper Linux tc traffic shaping
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



package opentrafficshaper::plugins::tc;

use strict;
use warnings;


use POE qw( Wheel::Run Filter::Line );

use opentrafficshaper::constants;
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
};


# Plugin info
our $pluginInfo = {
	Name => "Linux tc Interface",
	Version => VERSION,
	
	Init => \&plugin_init,
	Start => \&plugin_start,

	# Signals
	signal_SIGHUP => \&handle_SIGHUP,
};


# Copy of system globals
my $globals;
my $logger;


# TODO: move to $config
# Our own config stuff
my $txiface = "eth1";
my $txiface_rate = "100";
my $rxiface = "eth0";
my $rxiface_rate = "100";

# Queue of tasks to run
my @taskQueue = ();
# TC classes & filters
my $tcFilterMappings;
my $tcClasses = {
	'free' => [ ],
	'track' => { },
};
my $tcFilters = {
	'free' => [ ],
	'track' => { },
};



# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[TC] OpenTrafficShaper tc Integration v".VERSION." - Copyright (c) 2013, AllWorldIT");


	# Check our interfaces
	if (defined(my $txi = $globals->{'file.config'}->{'plugin.tc'}->{'txiface'})) {
		$logger->log(LOG_INFO,"[TC] Set txiface to '$txi'");
		$txiface = $txi;
	}
	if (defined(my $txir = $globals->{'file.config'}->{'plugin.tc'}->{'txiface_rate'})) {
		$logger->log(LOG_INFO,"[TC] Set txiface_rate to '$txir'");
		$txiface_rate = $txir;
	}
	if (defined(my $rxi = $globals->{'file.config'}->{'plugin.tc'}->{'rxiface'})) {
		$logger->log(LOG_INFO,"[TC] Set rxiface to '$rxi'");
		$rxiface = $rxi;
	}
	if (defined(my $rxir = $globals->{'file.config'}->{'plugin.tc'}->{'rxiface_rate'})) {
		$logger->log(LOG_INFO,"[TC] Set rxiface_rate to '$rxir'");
		$rxiface_rate = $rxir;
	}


	# This session is our main session, its alias is "shaper"
	POE::Session->create(
		inline_states => {
			_start => \&session_init,
			add => \&do_add,
			change => \&do_change,
			remove => \&do_remove,
		}
	);

	# This is our session for communicating directly with tc, its alias is _tc
	POE::Session->create(
		inline_states => {
			_start => \&tc_session_init,
			# Public'ish
			queue => \&tc_task_add,
			# Internal
			tc_child_stdout => \&tc_child_stdout,
			tc_child_stderr => \&tc_child_stderr,
			tc_child_close => \&tc_child_close,
			tc_task_run_next => \&tc_task_run_next,
		}
	);
}


# Start the plugin
sub plugin_start
{
	# Initialize TX interface
	$logger->log(LOG_INFO,"[TC] Queuing tasks to initialize '$txiface'");
	_tc_task_add_to_queue([
			'/sbin/tc','qdisc','del',
				'dev',$txiface,
				'root',
	]);
	_tc_task_add_to_queue([
			'/sbin/tc','qdisc','add',
				'dev',$txiface,
				'root',
				'handle','1:',
				'htb',
	]);
	_tc_task_add_to_queue([
			'/sbin/tc','class','add',
				'dev',$txiface,
				'parent','1:',
				'classid','1:1',
				'htb',
					'rate',$txiface_rate."mbit",
	]);
	_tc_task_add_to_queue([
			'/sbin/tc','filter','add',
				'dev',$txiface,
				'parent','1:',
				'prio','10',
				'protocol','ip',
				'u32',
	]);

	# Initialize RX interface
	$logger->log(LOG_INFO,"[TC] Queuing tasks to initialize '$rxiface'");
	_tc_task_add_to_queue([
			'/sbin/tc','qdisc','del',
				'dev',$rxiface,
				'root',
	]);
	_tc_task_add_to_queue([
			'/sbin/tc','qdisc','add',
				'dev',$rxiface,
				'root',
				'handle','1:',
				'htb',
	]);
	_tc_task_add_to_queue([
			'/sbin/tc','class','add',
				'dev',$rxiface,
				'parent','1:',
				'classid','1:1',
				'htb',
					'rate',$rxiface_rate."mbit",
	]);
	_tc_task_add_to_queue([
			'/sbin/tc','filter','add',
				'dev',$rxiface,
				'parent','1:',
				'prio','10',
				'protocol','ip',
				'u32',
	]);
	$logger->log(LOG_INFO,"[TC] Started");
}


# Initialize this plugins main POE session
sub session_init {
	my $kernel = $_[KERNEL];


	# Set our alias
	$kernel->alias_set("shaper");

	$logger->log(LOG_DEBUG,"[TC] Initialized");
}


# Add event for tc
sub do_add {
	my ($kernel,$heap,$uid) = @_[KERNEL, HEAP, ARG0];


	# Pull in global
	my $users = $globals->{'users'};
	my $user = $users->{$uid};

	$logger->log(LOG_DEBUG," Add '$user->{'Username'}' [$uid]\n");


	my @components = split(/\./,$user->{'IP'});

	# Filter level 2-4
	my $ip1 = $components[0];
	my $ip2 = $components[1];
	my $ip3 = $components[2];
	my $ip4 = $components[3];

	# Check if we have a entry for the /8, if not we must create our 2nd level hash table and link it
	if (!defined($tcFilterMappings->{$ip1})) {
		# Setup IP1's hash table
		my $filterID  = getTcFilter();
		$tcFilterMappings->{$ip1}->{'id'} = $filterID;


		$logger->log(LOG_DEBUG,"Linking 2nd level hash table to '$filterID' to $ip1.0.0/8\n");

		# Create second level hash table for $ip1
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol','ip',
					'u32',
						'divisor','256',
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol','ip',
					'u32',
						'divisor','256',
		]);
		# Link hash table
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent','1:',
					'prio','10',
					'protocol','ip',
					'u32',
						# Root hash table
						'ht','800::',
							'match','ip','dst',"$ip1.0.0.0/8",
						'hashkey','mask','0x00ff0000','at',16,
						# Link to our hash table
						'link',"$filterID:"
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent','1:',
					'prio','10',
					'protocol','ip',
					'u32',
						# Root hash table
						'ht','800::',
							'match','ip','src',"$ip1.0.0.0/8",
						'hashkey','mask','0x00ff0000','at',16,
						# Link to our hash table
						'link',"$filterID:"
		]);
	}

	# Check if we have our /16 hash entry, if not we must create the 3rd level hash table
	if (!defined($tcFilterMappings->{$ip1}->{$ip2})) {
		my $filterID  = getTcFilter();
		# Set 2nd level hash table ID
		$tcFilterMappings->{$ip1}->{$ip2}->{'id'} = $filterID;
		# Grab some hash table ID's we need
		my $ip1HtHex = $tcFilterMappings->{$ip1}->{'id'};
		my $ip2Hex = toHex($ip2);


		$logger->log(LOG_DEBUG,"Linking 3rd level hash table to '$filterID' to $ip1.$ip2.0.0/16\n");
		# Create second level hash table for $fl1
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol','ip',
					'u32',
						'divisor','256',
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol','ip',
					'u32',
						'divisor','256',
		]);
		# Link hash table
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent','1:',
					'prio','10',
					'protocol','ip',
					'u32',
						# This is the 2nd level hash table
						'ht',"${ip1HtHex}:${ip2Hex}:",
							'match','ip','dst',"$ip1.$ip2.0.0/16",
						'hashkey','mask','0x0000ff00','at',16,
						# That we're linking to our hash table
						'link',"$filterID:"
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent','1:',
					'prio','10',
					'protocol','ip',
					'u32',
						# This is the 2nd level hash table
						'ht',"${ip1HtHex}:${ip2Hex}:",
							'match','ip','src',"$ip1.$ip2.0.0/16",
						'hashkey','mask','0x0000ff00','at',16,
						# That we're linking to our hash table
						'link',"$filterID:"
		]);
	}

	# Check if we have our /24 hash entry, if not we must create the 4th level hash table
	if (!defined($tcFilterMappings->{$ip1}->{$ip2}->{$ip3})) {
		my $filterID  = getTcFilter();
		# Set 3rd level hash table ID
		$tcFilterMappings->{$ip1}->{$ip2}->{$ip3}->{'id'} = $filterID;
		# Grab some hash table ID's we need
		my $ip2HtHex = $tcFilterMappings->{$ip1}->{$ip2}->{'id'};
		my $ip3Hex = toHex($ip3);


		$logger->log(LOG_DEBUG,"Linking 4th level hash table to '$filterID' to $ip1.$ip2.$ip3.0/24\n");
		# Create second level hash table for $fl1
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol','ip',
					'u32',
						'divisor','256',
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol','ip',
					'u32',
						'divisor','256',
		]);
		# Link hash table
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent','1:',
					'prio','10',
					'protocol','ip',
					'u32',
						# This is the 3rd level hash table
						'ht',"${ip2HtHex}:${ip3Hex}:",
							'match','ip','dst',"$ip1.$ip2.$ip3.0/24",
						'hashkey','mask','0x000000ff','at',16,
						# That we're linking to our hash table
						'link',"$filterID:"
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent','1:',
					'prio','10',
					'protocol','ip',
					'u32',
						# This is the 3rd level hash table
						'ht',"${ip2HtHex}:${ip3Hex}:",
							'match','ip','src',"$ip1.$ip2.$ip3.0/24",
						'hashkey','mask','0x000000ff','at',16,
						# That we're linking to our hash table
						'link',"$filterID:"
		]);

	}



	# Only if we have limits setup process them
	if (defined($user->{'TrafficLimitTx'}) && defined($user->{'TrafficLimitRx'})) {
		# Build users tc class ID
		my $classID  = getTcClass();
		# Grab some hash table ID's we need
		my $ip3HtHex = $tcFilterMappings->{$ip1}->{$ip2}->{$ip3}->{'id'};
		my $ip4Hex = toHex($ip4);
		# Generate our filter handle
		my $filterHandle = "${ip3HtHex}:${ip4Hex}:1";

		# Save user tc class ID
		$user->{'tc.class'} = $classID;
		$user->{'tc.filter'} = "${ip3HtHex}:${ip4Hex}:1";

		#
		# SETUP MAIN TRAFFIC LIMITS
		#

		# Create main rate limiting classes
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','class','add',
					'dev',$txiface,
					'parent','1:1',
					'classid',"1:$classID",
					'htb',
						'rate', $user->{'TrafficLimitTx'} . "kbit",
						'ceil', $user->{'TrafficLimitTxBurst'} . "kbit",
						'prio',$user->{'TrafficPriority'},
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','class','add',
					'dev',$rxiface,
					'parent','1:1',
					'classid',"1:$classID",
					'htb',
						'rate', $user->{'TrafficLimitRx'} . "kbit",
						'ceil', $user->{'TrafficLimitRxBurst'} . "kbit",
						'prio',$user->{'TrafficPriority'},
		]);

		#
		# DEFINE 3 PRIO BANDS
		#

		# We then prioritize traffic into 3 bands based on TOS
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','qdisc','add',
					'dev',$txiface,
					'parent',"1:$classID",
					'handle',"$classID:",
					'prio',
						'bands','3',
						'priomap','2','2','2','2','2','2','2','2','2','2','2','2','2','2','2','2',
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','qdisc','add',
					'dev',$rxiface,
					'parent',"1:$classID",
					'handle',"$classID:",
					'prio',
						'bands','3',
						'priomap','2','2','2','2','2','2','2','2','2','2','2','2','2','2','2','2',
		]);


		#
		# SETUP DEFAULT CLASSIFICATION OF TRAFFIC
		#

		# Default traffic classification to main class
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent','1:',
					'prio','10',
					'handle',$filterHandle,
					'protocol','ip',
					'u32',
						'ht',"${ip3HtHex}:${ip4Hex}:",
						'match','ip','dst',$user->{'IP'},
					'flowid',"1:$classID",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent','1:',
					'prio','10',
					'handle',$filterHandle,
					'protocol','ip',
					'u32',
						'ht',"${ip3HtHex}:${ip4Hex}:",
						'match','ip','src',$user->{'IP'},
					'flowid',"1:$classID",
		]);


		#
		# CLASSIFICATIONS
		#

		# Prioritize ICMP up to a certain limit
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','1','0xff',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','1','0xff',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		# Prioritize ACK up to a certain limit
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','0x6','0xff', # TCP
						'match','u8','0x05','0x0f','at','0', # ??
						'match','u8','0x10','0xff','at','33', # ACK
						'match','u16','0x0000','0xffc0','at','2',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','0x6','0xff', # TCP
						'match','u8','0x05','0x0f','at','0', # ??
						'match','u8','0x10','0xff','at','33', # ACK
						'match','u16','0x0000','0xffc0','at','2',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		# Prioritize SYN-ACK up to a certain limit
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','0x6','0xff', # TCP
						'match','u8','0x05','0x0f','at','0', # ??
						'match','u8','0x12','0x12','at','33', # SYN-ACK
						'match','u16','0x0000','0xffc0','at','2',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','0x6','0xff', # TCP
						'match','u8','0x05','0x0f','at','0', # ??
						'match','u8','0x12','0x12','at','33', # SYN-ACK
						'match','u16','0x0000','0xffc0','at','2',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		# Prioritize FIN up to a certain limit
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','0x6','0xff', # TCP
						'match','u8','0x05','0x0f','at','0', # ??
						'match','u8','0x01','0x01','at','33', # FIN
						'match','u16','0x0000','0xffc0','at','2',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','0x6','0xff', # TCP
						'match','u8','0x05','0x0f','at','0', # ??
						'match','u8','0x01','0x01','at','33', # FIN
						'match','u16','0x0000','0xffc0','at','2',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		# Prioritize RST up to a certain limit
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','0x6','0xff', # TCP
						'match','u8','0x05','0x0f','at','0', # ??
						'match','u8','0x04','0x04','at','33', # RST
						'match','u16','0x0000','0xffc0','at','2',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','0x6','0xff', # TCP
						'match','u8','0x05','0x0f','at','0', # ??
						'match','u8','0x04','0x04','at','33', # RST
						'match','u16','0x0000','0xffc0','at','2',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		# DNS
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','sport','53','0xffff',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','dport','53','0xffff',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','sport','53','0xffff',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','dport','53','0xffff',
					'police',
						'rate','2kbit','burst','4k','continue',
					'flowid',"$classID:1",
		]);
		# VOIP
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','sport','5060','0xffff',
					'police',
						'rate','128kbit','burst','40k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','dport','5060','0xffff',
					'police',
						'rate','128kbit','burst','40k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','sport','5060','0xffff',
					'police',
						'rate','128kbit','burst','40k','continue',
					'flowid',"$classID:1",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','dport','5060','0xffff',
					'police',
						'rate','128kbit','burst','40k','continue',
					'flowid',"$classID:1",
		]);
		# SMTP
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','sport','25','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','dport','25','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','sport','25','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','dport','25','0xffff',
					'flowid',"$classID:2",
		]);
		# POP3
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','sport','110','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','dport','110','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','sport','110','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','dport','110','0xffff',
					'flowid',"$classID:2",
		]);
		# IMAP
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','sport','143','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','dport','143','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','sport','143','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','dport','143','0xffff',
					'flowid',"$classID:2",
		]);
		# HTTP
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','sport','80','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','dport','80','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','sport','80','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','dport','80','0xffff',
					'flowid',"$classID:2",
		]);
		# HTTPS
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','sport','443','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$txiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','dport','443','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','sport','443','0xffff',
					'flowid',"$classID:2",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$rxiface,
					'parent',"$classID:",
					'prio','1',
					'protocol','ip',
					'u32',
						'match','ip','protocol','6','0xff', # TCP
						'match','ip','dport','443','0xffff',
					'flowid',"$classID:2",
		]);
	}

	# Mark as live
	$user->{'shaper.live'} = SHAPER_LIVE;
}

# Change event for tc
sub do_change {
	my ($kernel, $uid, $changes) = @_[KERNEL, ARG0];


	# Pull in global
	my $users = $globals->{'users'};
	my $user = $users->{$uid};

	$logger->log(LOG_DEBUG,"Processing changes for '$user->{'Username'}' [$uid]\n");

	# We going to pull in the defaults
	my $trafficLimitTx = $user->{'TrafficLimitTx'};
	my $trafficLimitRx = $user->{'TrafficLimitRx'};
	my $trafficLimitTxBurst = $user->{'TrafficLimitTxBurst'};
	my $trafficLimitRxBurst = $user->{'TrafficLimitRxBurst'};
	# Lets see if we can override them...
	if (defined($changes->{'TrafficLimitTx'})) {
		$trafficLimitTx = $changes->{'TrafficLimitTx'};
	}
	if (defined($changes->{'TrafficLimitRx'})) {
		$trafficLimitRx = $changes->{'TrafficLimitRx'};
	}
	if (defined($changes->{'TrafficLimitTxBurst'})) {
		$trafficLimitTxBurst = $changes->{'TrafficLimitTxBurst'};
	}
	if (defined($changes->{'TrafficLimitRxBurst'})) {
		$trafficLimitRxBurst = $changes->{'TrafficLimitRxBurst'};
	}

	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','class','change',
				'dev',$txiface,
				'parent','1:1',
				'classid',"1:$user->{'tc.class'}",
				'htb',
					'rate', $trafficLimitTx . "kbit",
					'ceil', $trafficLimitTxBurst . "kbit",
					'prio',$user->{'TrafficPriority'},
	]);
	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','class','change',
				'dev',$rxiface,
				'parent','1:1',
				'classid',"1:$user->{'tc.class'}",
				'htb',
					'rate', $trafficLimitRx . "kbit",
					'ceil', $trafficLimitRxBurst . "kbit",
					'prio',$user->{'TrafficPriority'},
	]);
}

# Remove event for tc
sub do_remove {
	my ($kernel, $uid) = @_[KERNEL, ARG0];


	# Pull in global
	my $users = $globals->{'users'};
	my $user = $users->{$uid};

	$logger->log(LOG_DEBUG," Remove '$user->{'Username'}' [$uid]\n");

	# Grab ClassID
	my $classID = $user->{'tc.class'};
	my $filterHandle = $user->{'tc.filter'};

	# Clear up the filter
	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','filter','del',
				'dev',$txiface,
				'parent','1:',
				'prio','10',
				'handle',$filterHandle,
				'protocol','ip',
				'u32',
	]);
	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','filter','del',
				'dev',$rxiface,
				'parent','1:',
				'prio','10',
				'handle',$filterHandle,
				'protocol','ip',
				'u32',
	]);
	# Clear up the class
	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','class','del',
				'dev',$txiface,
				'parent','1:1',
				'classid',"1:$classID",
	]);
	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','class','del',
				'dev',$rxiface,
				'parent','1:1',
				'classid',"1:$classID",
	]);

	# And recycle the class
	disposeTcClass($classID);

	# Mark as not live
	$users->{$uid}->{'shaper.live'} = SHAPER_NOTLIVE;
}


# Function to get next available TC filter 
sub getTcFilter
{
	my $id = pop(@{$tcFilters->{'free'}});

	# Generate new number
	if (!$id) {
		$id = keys %{$tcFilters->{'track'}};
		# Bump ID up by 10
		$id += 100;
		# We cannot use ID 800, its internal
		$id = 801 if ($id == 800);
		# Hex it
		$id = toHex($id);
	}

	$tcFilters->{'track'}->{$id} = 1;

	return $id;
}
# Function to dispose of a TC Filter
sub disposeTcFilter
{
	my $id = shift;

	# Push onto free list
	push(@{$tcFilters->{'free'}},$id);
	# Blank the value
	$tcFilters->{'track'}->{$id} = undef;
}


# Function to get next available TC class 
sub getTcClass
{
	my $id = pop(@{$tcClasses->{'free'}});

	# Generate new number
	if (!$id) {
		$id = keys %{$tcClasses->{'track'}};
		$id += 100;
		# Hex it
		$id = toHex($id);
	}

	$tcClasses->{'track'}->{$id} = 1;

	return $id;
}
# Function to dispose of a TC class
sub disposeTcClass
{
	my $id = shift;

	# Push onto free list
	push(@{$tcClasses->{'free'}},$id);
	# Blank the value
	$tcClasses->{'track'}->{$id} = undef;
}




#
# Task/child communication & handling stuff
#

# Initialize our tc session
sub tc_session_init {
	my $kernel = $_[KERNEL];
	# Set our alias
	$kernel->alias_set("_tc");

	# Fire things up, we trigger this to process the task queue generated during init
	$kernel->yield("tc_task_run_next");
}

# Add task to queue
sub _tc_task_add_to_queue
{
	my $cmd = shift;


	# Build commandline string
	my $cmdStr = join(' ',@{$cmd});
	# Shove task on list
	$logger->log(LOG_DEBUG,"[TC] TASK: Queue '$cmdStr'");
	push(@taskQueue,$cmd);
}


# Run a task
sub tc_task_add
{
	my ($kernel,$heap,$cmd) = @_[KERNEL,HEAP,ARG0];


	# Internal function to add command to queue
	_tc_task_add_to_queue($cmd);

	# Trigger a run if list is empty
	if (@taskQueue < 2) {
		$kernel->yield("tc_task_run_next");
	}
}


# Fire up the session starter
sub tc_task_run_next
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Check if we have a task coming off the top of the task queue
	if (my $cmd = shift(@taskQueue)) {

		# Create task
		my $task = POE::Wheel::Run->new(
			Program => $cmd,
			# We get full lines back
			StdioFilter => POE::Filter::Line->new(),
			StderrFilter => POE::Filter::Line->new(),
	        StdoutEvent => 'tc_child_stdout',
	        StderrEvent => 'tc_child_stderr',
			CloseEvent => 'tc_child_close',
		) or $logger->log(LOG_ERR,"[TC] TASK: Unable to start task");


		# Intercept SIGCHLD
	    $kernel->sig_child($task->PID, "sig_child");

		# Wheel events include the wheel's ID.
		$heap->{task_by_wid}->{$task->ID} = $task;
		# Signal events include the process ID.
		$heap->{task_by_pid}->{$task->PID} = $task;

		# Build commandline string
		my $cmdStr = join(' ',@{$cmd});
		$logger->log(LOG_DEBUG,"[TC] TASK/".$task->ID.": Starting '$cmdStr' as ".$task->ID." with PID ".$task->PID);
	}
}


# Child writes to STDOUT
sub tc_child_stdout
{
    my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
    my $child = $heap->{task_by_wid}->{$task_id};

	$logger->log(LOG_INFO,"[TC] TASK/$task_id: STDOUT => ".$stdout);
}


# Child writes to STDERR
sub tc_child_stderr
{
    my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
    my $child = $heap->{task_by_wid}->{$task_id};

	$logger->log(LOG_WARN,"[TC] TASK/$task_id: STDERR => ".$stdout);
}


# Child closed its handles, it won't communicate with us, so remove it
sub tc_child_close
{
    my ($kernel,$heap,$task_id) = @_[KERNEL,HEAP,ARG0];
    my $child = delete($heap->{task_by_wid}->{$task_id});

    # May have been reaped by tc_sigchld()
    if (!defined($child)) {
		$logger->log(LOG_DEBUG,"[TC] TASK/$task_id: Closed dead child");
		return;
    }

	$logger->log(LOG_DEBUG,"[TC] TASK/$task_id: Closed PID ".$child->PID);
    delete($heap->{task_by_pid}->{$child->PID});

	# Start next one, if there is a next one
	if (@taskQueue > 0) {
		$kernel->yield("tc_task_run_next");
	}
}


# Reap the dead child
sub tc_sigchld
{
	my ($kernel,$heap,$pid,$status) = @_[KERNEL,HEAP,ARG1,ARG2];
    my $child = delete($heap->{task_by_pid}->{$pid});


	$logger->log(LOG_DEBUG,"[TC] TASK: Task with PID $pid exited with status $status");

    # May have been reaped by tc_child_close()
    return if (!defined($child));

    delete($heap->{task_by_wid}{$child->ID});
}


# Handle SIGHUP
sub handle_SIGHUP
{
	$logger->log(LOG_WARN,"[TC] Got SIGHUP, ignoring for now");
}

1;
# vim: ts=4
