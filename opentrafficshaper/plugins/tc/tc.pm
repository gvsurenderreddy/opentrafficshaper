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

	# 5% of a link can be used for very high priority traffic
	PROTO_RATE_LIMIT => 5,
	PROTO_RATE_BURST_MIN => 16,  # With a minimum burst of 8KiB
	PROTO_RATE_BURST_MAXM => 1.5,  # Multiplier for burst min to get to burst max

	# High priority traffic gets the first 20% of the bandidth to itself
	PRIO_RATE_LIMIT => 20,
	PRIO_RATE_BURST_MIN => 32,  # With a minimum burst of 40KiB
	PRIO_RATE_BURST_MAXM => 1.5,  # Multiplier for burst min to get to burst max
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


# Our configuration
my $config = {
	'txiface' => "eth1",
	'txiface_rate' => 100,
	'rxiface' => "eth0",
	'rxiface_rate' => 100,

	'ip_protocol' => "ip",
	'iphdr_offset' => 0,
};

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
		$config->{'txiface'} = $txi;
	}
	if (defined(my $txir = $globals->{'file.config'}->{'plugin.tc'}->{'txiface_rate'})) {
		$logger->log(LOG_INFO,"[TC] Set txiface_rate to '$txir'");
		$config->{'txiface_rate'} = $txir;
	}
	if (defined(my $rxi = $globals->{'file.config'}->{'plugin.tc'}->{'rxiface'})) {
		$logger->log(LOG_INFO,"[TC] Set rxiface to '$rxi'");
		$config->{'rxiface'} = $rxi;
	}
	if (defined(my $rxir = $globals->{'file.config'}->{'plugin.tc'}->{'rxiface_rate'})) {
		$logger->log(LOG_INFO,"[TC] Set rxiface_rate to '$rxir'");
		$config->{'rxiface_rate'} = $rxir;
	}
	if (defined(my $proto = $globals->{'file.config'}->{'plugin.tc'}->{'protocol'})) {
		$logger->log(LOG_INFO,"[TC] Set protocol to '$proto'");
		$config->{'ip_protocol'} = $proto;
	}
	if (defined(my $offset = $globals->{'file.config'}->{'plugin.tc'}->{'iphdr_offset'})) {
		$logger->log(LOG_INFO,"[TC] Set IP header offset to '$offset'");
		$config->{'iphdr_offset'} = $offset;
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
			_start => \&task_session_init,
			# Public'ish
			queue => \&task_add,
			# Internal
			task_child_stdout => \&task_child_stdout,
			task_child_stderr => \&task_child_stderr,
			task_child_close => \&task_child_close,
			task_run_next => \&task_run_next,
		}
	);

	return 1;
}


# Start the plugin
sub plugin_start
{
	# Initialize TX interface
	$logger->log(LOG_INFO,"[TC] Queuing tasks to initialize '$config->{'txiface'}'");
	_tc_init_iface($config->{'txiface'},$config->{'txiface_rate'});
	tc_addtask_optimize(undef,$config->{'txiface'},3,$config->{'txiface_rate'}*1024); # Rate is in mbit
	_tc_optimize_iface($config->{'txiface'},3,3,$config->{'txiface_rate'});

	# Initialize RX interface
	$logger->log(LOG_INFO,"[TC] Queuing tasks to initialize '$config->{'rxiface'}'");
	_tc_init_iface($config->{'rxiface'},$config->{'rxiface_rate'});
	tc_addtask_optimize(undef,$config->{'rxiface'},3,$config->{'rxiface_rate'}*1024); # Rate is in mbit
	_tc_optimize_iface($config->{'rxiface'},3,3,$config->{'rxiface_rate'});

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
		my $filterID  = getTcFilter($uid);
		$tcFilterMappings->{$ip1}->{'id'} = $filterID;


		$logger->log(LOG_DEBUG,"Linking 2nd level hash table to '$filterID' to $ip1.0.0/8\n");

		# Create second level hash table for $ip1
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol',$config->{'ip_protocol'},
					'u32',
						'divisor','256',
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'rxiface'},
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol',$config->{'ip_protocol'},
					'u32',
						'divisor','256',
		]);
		# Link hash table
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'protocol',$config->{'ip_protocol'},
					'u32',
						# Root hash table
						'ht','800::',
							'match','ip','dst',"$ip1.0.0.0/8",
								'at',16+$config->{'iphdr_offset'},
						'hashkey','mask','0x00ff0000',
							'at',16+$config->{'iphdr_offset'},
						# Link to our hash table
						'link',"$filterID:"
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'rxiface'},
					'parent','1:',
					'prio','10',
					'protocol',$config->{'ip_protocol'},
					'u32',
						# Root hash table
						'ht','800::',
							'match','ip','src',"$ip1.0.0.0/8",
								'at',12+$config->{'iphdr_offset'},
						'hashkey','mask','0x00ff0000',
							'at',12+$config->{'iphdr_offset'},
						# Link to our hash table
						'link',"$filterID:"
		]);
	}

	# Check if we have our /16 hash entry, if not we must create the 3rd level hash table
	if (!defined($tcFilterMappings->{$ip1}->{$ip2})) {
		my $filterID  = getTcFilter($uid);
		# Set 2nd level hash table ID
		$tcFilterMappings->{$ip1}->{$ip2}->{'id'} = $filterID;
		# Grab some hash table ID's we need
		my $ip1HtHex = $tcFilterMappings->{$ip1}->{'id'};
		my $ip2Hex = toHex($ip2);


		$logger->log(LOG_DEBUG,"Linking 3rd level hash table to '$filterID' to $ip1.$ip2.0.0/16\n");
		# Create second level hash table for $fl1
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol',$config->{'ip_protocol'},
					'u32',
						'divisor','256',
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'rxiface'},
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol',$config->{'ip_protocol'},
					'u32',
						'divisor','256',
		]);
		# Link hash table
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'protocol',$config->{'ip_protocol'},
					'u32',
						# This is the 2nd level hash table
						'ht',"${ip1HtHex}:${ip2Hex}:",
							'match','ip','dst',"$ip1.$ip2.0.0/16",
								'at',16+$config->{'iphdr_offset'},
						'hashkey','mask','0x0000ff00',
							'at',16+$config->{'iphdr_offset'},
						# That we're linking to our hash table
						'link',"$filterID:"
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'rxiface'},
					'parent','1:',
					'prio','10',
					'protocol',$config->{'ip_protocol'},
					'u32',
						# This is the 2nd level hash table
						'ht',"${ip1HtHex}:${ip2Hex}:",
							'match','ip','src',"$ip1.$ip2.0.0/16",
								'at',12+$config->{'iphdr_offset'},
						'hashkey','mask','0x0000ff00',
							'at',12+$config->{'iphdr_offset'},
						# That we're linking to our hash table
						'link',"$filterID:"
		]);
	}

	# Check if we have our /24 hash entry, if not we must create the 4th level hash table
	if (!defined($tcFilterMappings->{$ip1}->{$ip2}->{$ip3})) {
		my $filterID  = getTcFilter($uid);
		# Set 3rd level hash table ID
		$tcFilterMappings->{$ip1}->{$ip2}->{$ip3}->{'id'} = $filterID;
		# Grab some hash table ID's we need
		my $ip2HtHex = $tcFilterMappings->{$ip1}->{$ip2}->{'id'};
		my $ip3Hex = toHex($ip3);


		$logger->log(LOG_DEBUG,"Linking 4th level hash table to '$filterID' to $ip1.$ip2.$ip3.0/24\n");
		# Create second level hash table for $fl1
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol',$config->{'ip_protocol'},
					'u32',
						'divisor','256',
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'rxiface'},
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol',$config->{'ip_protocol'},
					'u32',
						'divisor','256',
		]);
		# Link hash table
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'protocol',$config->{'ip_protocol'},
					'u32',
						# This is the 3rd level hash table
						'ht',"${ip2HtHex}:${ip3Hex}:",
							'match','ip','dst',"$ip1.$ip2.$ip3.0/24",
								'at',16+$config->{'iphdr_offset'},
						'hashkey','mask','0x000000ff',
							'at',16+$config->{'iphdr_offset'},
						# That we're linking to our hash table
						'link',"$filterID:"
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'rxiface'},
					'parent','1:',
					'prio','10',
					'protocol',$config->{'ip_protocol'},
					'u32',
						# This is the 3rd level hash table
						'ht',"${ip2HtHex}:${ip3Hex}:",
							'match','ip','src',"$ip1.$ip2.$ip3.0/24",
								'at',12+$config->{'iphdr_offset'},
						'hashkey','mask','0x000000ff',
							'at',12+$config->{'iphdr_offset'},
						# That we're linking to our hash table
						'link',"$filterID:"
		]);

	}



	# Only if we have limits setup process them
	if (defined($user->{'TrafficLimitTx'}) && defined($user->{'TrafficLimitRx'})) {
		# Build users tc class ID
		my $classID  = getTcClass($uid);
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
					'dev',$config->{'txiface'},
					'parent','1:2',
					'classid',"1:$classID",
					'htb',
						'rate', $user->{'TrafficLimitTx'} . "kbit",
						'ceil', $user->{'TrafficLimitTxBurst'} . "kbit",
						'prio',$user->{'TrafficPriority'},
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','class','add',
					'dev',$config->{'rxiface'},
					'parent','1:2',
					'classid',"1:$classID",
					'htb',
						'rate', $user->{'TrafficLimitRx'} . "kbit",
						'ceil', $user->{'TrafficLimitRxBurst'} . "kbit",
						'prio',$user->{'TrafficPriority'},
		]);

		#
		# SETUP DEFAULT CLASSIFICATION OF TRAFFIC
		#

		# Default traffic classification to main class
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'handle',$filterHandle,
					'protocol',$config->{'ip_protocol'},
					'u32',
						'ht',"${ip3HtHex}:${ip4Hex}:",
							'match','ip','dst',$user->{'IP'},
								'at',16+$config->{'iphdr_offset'},
					'flowid',"1:$classID",
		]);
		$kernel->post("_tc" => "queue" => [
				'/sbin/tc','filter','add',
					'dev',$config->{'rxiface'},
					'parent','1:',
					'prio','10',
					'handle',$filterHandle,
					'protocol',$config->{'ip_protocol'},
					'u32',
						'ht',"${ip3HtHex}:${ip4Hex}:",
							'match','ip','src',$user->{'IP'},
								'at',12+$config->{'iphdr_offset'},
					'flowid',"1:$classID",
		]);

		tc_addtask_optimize($kernel,$config->{'txiface'},$classID,$user->{'TrafficLimitTx'});
		tc_addtask_optimize($kernel,$config->{'rxiface'},$classID,$user->{'TrafficLimitRx'});
	}

	# Mark as live
	$user->{'_shaper.state'} = SHAPER_LIVE;
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
				'dev',$config->{'txiface'},
				'parent','1:2',
				'classid',"1:$user->{'tc.class'}",
				'htb',
					'rate', $trafficLimitTx . "kbit",
					'ceil', $trafficLimitTxBurst . "kbit",
					'prio',$user->{'TrafficPriority'},
	]);
	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','class','change',
				'dev',$config->{'rxiface'},
				'parent','1:2',
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
				'dev',$config->{'txiface'},
				'parent','1:',
				'prio','10',
				'handle',$filterHandle,
				'protocol',$config->{'ip_protocol'},
				'u32',
	]);
	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','filter','del',
				'dev',$config->{'rxiface'},
				'parent','1:',
				'prio','10',
				'handle',$filterHandle,
				'protocol',$config->{'ip_protocol'},
				'u32',
	]);
	# Clear up the class
	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','class','del',
				'dev',$config->{'txiface'},
				'parent','1:2',
				'classid',"1:$classID",
	]);
	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','class','del',
				'dev',$config->{'rxiface'},
				'parent','1:2',
				'classid',"1:$classID",
	]);

	# And recycle the class
	disposeTcClass($classID);

	# Mark as not live
	$user->{'_shaper.state'} = SHAPER_NOTLIVE;
}


# Function to get next available TC filter 
sub getTcFilter
{
	my $uid = shift;


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

	$tcFilters->{'track'}->{$id} = $uid;

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
	my $uid = shift;


	my $id = pop(@{$tcClasses->{'free'}});

	# Generate new number
	if (!$id) {
		$id = keys %{$tcClasses->{'track'}};
		$id += 100;
		# Hex it
		$id = toHex($id);
	}

	$tcClasses->{'track'}->{$id} = $uid;

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
# Grab user from TC class
sub getUIDFromTcClass
{
	my $id = shift;

	return $tcClasses->{'track'}->{$id};
}

# Function to initialize an interface
sub _tc_init_iface
{
	my ($iface,$rate) = @_;


	# Work out rates
	my $BERate = int($rate/10); # We use 10% of the rate for Best effort
	my $CIRate = $rate - $BERate; # Rest is for our clients

	_task_add_to_queue([
			'/sbin/tc','qdisc','del',
				'dev',$iface,
				'root',
	]);
	_task_add_to_queue([
			'/sbin/tc','qdisc','add',
				'dev',$iface,
				'root',
				'handle','1:',
				'htb',
					'default','3' # Push any unclassified traffic to 1:3
	]);
	_task_add_to_queue([
			'/sbin/tc','class','add',
				'dev',$iface,
				'parent','1:',
				'classid','1:1',
				'htb',
					'rate',"${rate}mbit",
	]);
	_task_add_to_queue([
			'/sbin/tc','class','add',
				'dev',$iface,
				'parent','1:1',
				'classid','1:2',
				'htb',
					'rate',"${CIRate}mbit",
					'ceil',"${rate}mbit",
					# Highest priority
					'prio','5',
	]);
	_task_add_to_queue([
			'/sbin/tc','class','add',
				'dev',$iface,
				'parent','1:1',
				'classid','1:3',
				'htb',
					'rate',"${BERate}mbit",
					'ceil',"${rate}mbit",
					# Lowest priority
					'prio','7',
	]);
}

# Function to apply SFQ to the interface priority classes
sub _tc_optimize_iface
{
	my ($iface,$prioClass,$prioCount,$rate) = @_;


	# Make the queue size big enough
	my $queueSize = ($rate * 1024 * 1024) / 8;

	# RED metrics (sort of as per manpage)
	my $redAvPkt = 1000;
	my $redMax = int($queueSize / 4);
	my $redMin = int($redMax / 3);
	my $redBurst = int( ($redMin+$redMin+$redMax) / (4*$redAvPkt));
	my $redLimit = $queueSize;

	# Use $i as an increasing number to be added to the base class
	my $i = 1;
	_task_add_to_queue([
			'/sbin/tc','qdisc','add',
				'dev',$iface,
				'parent',"$prioClass:$i",
				'handle',$prioClass+$i.":",
				'bfifo',
					'limit',$queueSize,
	]);

	$i++;
	_task_add_to_queue([
			'/sbin/tc','qdisc','add',
				'dev',$iface,
				'parent',"$prioClass:$i",
				'handle',$prioClass+$i.":",
# FIXME: NK - try enable the below
#				'estimator','1sec','4sec', # Quick monitoring, every 1s with 4s constraint
				'red',
					'min',$redMin,
					'max',$redMax,
					'limit',$redLimit,
					'burst',$redBurst,
					'avpkt',$redAvPkt,
					'ecn'
# XXX: Very new kernels only ... use redflowlimit in future
#					'sfq',
#						'divisor','16384',
#						'headdrop',
#						'redflowlimit',$queueSize,
#						'ecn',
	]);

	$i++;
	_task_add_to_queue([
			'/sbin/tc','qdisc','add',
				'dev',$iface,
				'parent',"$prioClass:$i",
				'handle',$prioClass+$i.":",
				'red',
					'min',$redMin,
					'max',$redMax,
					'limit',$redLimit,
					'burst',$redBurst,
					'avpkt',$redAvPkt,
					'ecn'
	]);
}

# Function to apply traffic optimizations to a classes
sub tc_addtask_optimize
{
	my ($kernel,$iface,$classID,$rate) = @_;


	my $callTc;
	if (defined($kernel)) {
		# Use our kernel object
		$callTc = sub {
			$kernel->post(@_);
		};
	} else {
		# Fake it if we don't have a kernel and just add to the task queue
		$callTc = sub { 
			_task_add_to_queue($_[2]);
		};
	}

	# Rate for things like ICMP , ACK, SYN ... etc
	my $rateBand1 = int($rate * (PROTO_RATE_LIMIT / 100));
	$rateBand1 = PROTO_RATE_BURST_MIN if ($rateBand1 < PROTO_RATE_BURST_MIN); 
	my $rateBand1Burst = ($rateBand1 / 8) * PROTO_RATE_BURST_MAXM;
	# Rate for things like VoIP/SSH/Telnet
	my $rateBand2 = int($rate * (PRIO_RATE_LIMIT / 100));
	$rateBand2 = PRIO_RATE_BURST_MIN if ($rateBand2 < PRIO_RATE_BURST_MIN);
	my $rateBand2Burst = ($rateBand2 / 8) * PRIO_RATE_BURST_MAXM;

	#
	# DEFINE 3 PRIO BANDS
	#

	# We then prioritize traffic into 3 bands based on TOS
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','qdisc','add',
				'dev',$iface,
				'parent',"1:$classID",
				'handle',"$classID:",
				'prio',
					'bands','3',
					'priomap','2','2','2','2','2','2','2','2','2','2','2','2','2','2','2','2',
	]);


	#
	# CLASSIFICATIONS
	#

	# Prioritize ICMP up to a certain limit
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x1','0xff', # ICMP
						'at',9+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	# Prioritize ACK up to a certain limit
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x10','0xff', # ACK
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	# Prioritize SYN-ACK up to a certain limit
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x12','0xff', # SYN-ACK
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	# Prioritize FIN up to a certain limit
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x1','0xff', # FIN
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	# Prioritize RST up to a certain limit
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x4','0xff', # RST
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	# DNS
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x0035','0xffff', # SPORT 53
						'at',20+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x0035','0xffff', # DPORT 53
						'at',22+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	# VOIP
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x13c4','0xffff', # SPORT 5060
						'at',20+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x13c4','0xffff', # DPORT 5060
						'at',22+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	# SNMP
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0xa1','0xffff', # SPORT 161
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$classID:1",
	]);
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0xa1','0xffff', # DPORT 161
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$classID:1",
	]);
	# FIXME: Make this customizable not hard coded
	# Mikrotik Management Port
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x2063','0xffff', # SPORT 8291
						'at',20+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x2063','0xffff', # DPORT 8291
						'at',22+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$classID:1",
	]);
	# SMTP
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x19','0xffff', # SPORT 25
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$classID:2",
	]);
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x19','0xffff', # DPORT 25
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$classID:2",
	]);
	# POP3
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x6e','0xffff', # SPORT 110
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$classID:2",
	]);
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x6e','0xffff', # DPORT 110
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$classID:2",
	]);
	# IMAP
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x8f','0xffff', # SPORT 143
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$classID:2",
	]);
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x8f','0xffff', # DPORT 143
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$classID:2",
	]);
	# HTTP
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x50','0xffff', # SPORT 80
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$classID:2",
	]);
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x50','0xffff', # DPORT 80
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$classID:2",
	]);
	# HTTPS
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x1bb','0xffff', # SPORT 443
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$classID:2",
	]);
	$callTc->("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$classID:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x1bb','0xffff', # DPORT 443
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$classID:2",
	]);
}



#
# Task/child communication & handling stuff
#

# Initialize our tc session
sub task_session_init {
	my $kernel = $_[KERNEL];
	# Set our alias
	$kernel->alias_set("_tc");

	# Fire things up, we trigger this to process the task queue generated during init
	$kernel->yield("task_run_next");
}

# Add task to queue
sub _task_add_to_queue
{
	my $cmd = shift;


	# Build commandline string
	my $cmdStr = join(' ',@{$cmd});
	# Shove task on list
	$logger->log(LOG_DEBUG,"[TC] TASK: Queue '$cmdStr'");
	push(@taskQueue,$cmd);
}


# Run a task
sub task_add
{
	my ($kernel,$heap,$cmd) = @_[KERNEL,HEAP,ARG0];


	# Internal function to add command to queue
	_task_add_to_queue($cmd);

	# Trigger a run if list is empty
	if (@taskQueue < 2) {
		$kernel->yield("task_run_next");
	}
}


# Fire up the session starter
sub task_run_next
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
	        StdoutEvent => 'task_child_stdout',
	        StderrEvent => 'task_child_stderr',
			CloseEvent => 'task_child_close',
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
sub task_child_stdout
{
    my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
    my $child = $heap->{task_by_wid}->{$task_id};

	$logger->log(LOG_INFO,"[TC] TASK/$task_id: STDOUT => ".$stdout);
}


# Child writes to STDERR
sub task_child_stderr
{
    my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
    my $child = $heap->{task_by_wid}->{$task_id};

	$logger->log(LOG_WARN,"[TC] TASK/$task_id: STDERR => ".$stdout);
}


# Child closed its handles, it won't communicate with us, so remove it
sub task_child_close
{
    my ($kernel,$heap,$task_id) = @_[KERNEL,HEAP,ARG0];
    my $child = delete($heap->{task_by_wid}->{$task_id});

    # May have been reaped by task_sigchld()
    if (!defined($child)) {
		$logger->log(LOG_DEBUG,"[TC] TASK/$task_id: Closed dead child");
		return;
    }

	$logger->log(LOG_DEBUG,"[TC] TASK/$task_id: Closed PID ".$child->PID);
    delete($heap->{task_by_pid}->{$child->PID});

	# Start next one, if there is a next one
	if (@taskQueue > 0) {
		$kernel->yield("task_run_next");
	}
}


# Reap the dead child
sub task_sigchld
{
	my ($kernel,$heap,$pid,$status) = @_[KERNEL,HEAP,ARG1,ARG2];
    my $child = delete($heap->{task_by_pid}->{$pid});


	$logger->log(LOG_DEBUG,"[TC] TASK: Task with PID $pid exited with status $status");

    # May have been reaped by task_child_close()
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
