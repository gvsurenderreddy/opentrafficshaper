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

use opentrafficshaper::plugins::configmanager qw(
		getLimit getLimitAttribute setLimitAttribute removeLimitAttribute
		getShaperState setShaperState
		getTrafficClasses
		getDefaultPoolConfig
		isTrafficClassValid
);


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
	getInterfaces
	getConfigTxIface
	getConfigRxIface
);

use constant {
	VERSION => '0.0.2',

	# 5% of a link can be used for very high priority traffic
	PROTO_RATE_LIMIT => 5,
	PROTO_RATE_BURST_MIN => 16,  # With a minimum burst of 8KiB
	PROTO_RATE_BURST_MAXM => 1.5,  # Multiplier for burst min to get to burst max

	# High priority traffic gets the first 20% of the bandidth to itself
	PRIO_RATE_LIMIT => 20,
	PRIO_RATE_BURST_MIN => 32,  # With a minimum burst of 40KiB
	PRIO_RATE_BURST_MAXM => 1.5,  # Multiplier for burst min to get to burst max

	TC_CLASS_BASE => 10,
	TC_CLASS_LIMIT_BASE => 100,

	TC_PRIO_BASE => 10,

	TC_FILTER_LIMIT_BASE => 100,
};


# Plugin info
our $pluginInfo = {
	Name => "Linux tc Interface",
	Version => VERSION,

	Init => \&plugin_init,
	Start => \&plugin_start,
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


	# We going to queue the initialization in plugin initialization so nothing at all can come before us
	my $changeSet = TC::ChangeSet->new();

	# Initialize TX interface
	$logger->log(LOG_INFO,"[TC] Queuing tasks to initialize '$config->{'txiface'}'");
	_tc_iface_init($changeSet,$config->{'txiface'},$config->{'txiface_rate'});

	# Initialize RX interface
	$logger->log(LOG_INFO,"[TC] Queuing tasks to initialize '$config->{'rxiface'}'");
	_tc_iface_init($changeSet,$config->{'rxiface'},$config->{'rxiface_rate'});

	_task_add_to_queue($changeSet);


	# This session is our main session, its alias is "shaper"
	POE::Session->create(
		inline_states => {
			_start => \&session_start,
			_stop => \&session_stop,

			add => \&do_add,
			change => \&do_change,
			remove => \&do_remove,
		}
	);

	# This is our session for communicating directly with tc, its alias is _tc
	POE::Session->create(
		inline_states => {
			_start => \&task_session_start,
			_stop => sub { },

			# Public'ish
			queue => \&task_add,
			# Internal
			task_child_stdout => \&task_child_stdout,
			task_child_stderr => \&task_child_stderr,
			task_child_stdin => \&task_child_stdin,
			task_child_error => \&task_child_error,
			task_child_close => \&task_child_close,
			task_run_next => \&task_run_next,
			# Signals
			handle_SIGCHLD => \&task_handle_SIGCHLD,
			handle_SIGINT => \&task_handle_SIGINT,
		}
	);

	return 1;
}


# Start the plugin
sub plugin_start
{
	$logger->log(LOG_INFO,"[TC] Started");
}


# Initialize this plugins main POE session
sub session_start
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Set our alias
	$kernel->alias_set("shaper");

	$logger->log(LOG_DEBUG,"[TC] Initialized");
}


# Initialize this plugins main POE session
sub session_stop
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Remove our alias
	$kernel->alias_remove("shaper");

	# Blow away data
	$globals = undef;
	@taskQueue = ();
	$tcFilterMappings = undef;
	# XXX: Destroy the rest too like config

	$logger->log(LOG_DEBUG,"[TC] Shutdown");

	$logger = undef;
}


# Add event for tc
sub do_add
{
	my ($kernel,$heap,$lid,$changes) = @_[KERNEL, HEAP, ARG0, ARG1];

	my $changeSet = TC::ChangeSet->new();


	# Pull in limit
	my $limit;
	if (!defined($limit = getLimit($lid))) {
		$logger->log(LOG_ERR,"[TC] Shaper 'add' event with non existing limit '$lid'");
		return;
	}

	$logger->log(LOG_INFO,"[TC] Add '$limit->{'Username'}' [$lid]");


	my @components = split(/\./,$limit->{'IP'});

	# Filter level 2-4
	my $ip1 = $components[0];
	my $ip2 = $components[1];
	my $ip3 = $components[2];
	my $ip4 = $components[3];

	# Check if we have a entry for the /8, if not we must create our 2nd level hash table and link it
	if (!defined($tcFilterMappings->{$ip1})) {
		# Setup IP1's hash table
		my $filterID  = getTcFilter($lid);
		$tcFilterMappings->{$ip1}->{'id'} = $filterID;


		$logger->log(LOG_DEBUG,"[TC] Linking 2nd level hash table to '$filterID' to $ip1.0.0/8");

		# Create second level hash table for $ip1
		$changeSet->add([
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol',$config->{'ip_protocol'},
					'u32',
						'divisor','256',
		]);
		$changeSet->add([
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
		$changeSet->add([
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
		$changeSet->add([
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
		my $filterID  = getTcFilter($lid);
		# Set 2nd level hash table ID
		$tcFilterMappings->{$ip1}->{$ip2}->{'id'} = $filterID;
		# Grab some hash table ID's we need
		my $ip1HtHex = $tcFilterMappings->{$ip1}->{'id'};
		my $ip2Hex = toHex($ip2);


		$logger->log(LOG_DEBUG,"[TC] Linking 3rd level hash table to '$filterID' to $ip1.$ip2.0.0/16");
		# Create second level hash table for $fl1
		$changeSet->add([
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol',$config->{'ip_protocol'},
					'u32',
						'divisor','256',
		]);
		$changeSet->add([
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
		$changeSet->add([
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
		$changeSet->add([
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
		my $filterID  = getTcFilter($lid);
		# Set 3rd level hash table ID
		$tcFilterMappings->{$ip1}->{$ip2}->{$ip3}->{'id'} = $filterID;
		# Grab some hash table ID's we need
		my $ip2HtHex = $tcFilterMappings->{$ip1}->{$ip2}->{'id'};
		my $ip3Hex = toHex($ip3);


		$logger->log(LOG_DEBUG,"[TC] Linking 4th level hash table to '$filterID' to $ip1.$ip2.$ip3.0/24");
		# Create second level hash table for $fl1
		$changeSet->add([
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'handle',"$filterID:",
					'protocol',$config->{'ip_protocol'},
					'u32',
						'divisor','256',
		]);
		$changeSet->add([
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
		$changeSet->add([
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
		$changeSet->add([
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
	if (defined($changes->{'TrafficLimitTx'}) && defined($changes->{'TrafficLimitRx'})) {
		# Build limit tc class ID
		my $tcClass  = getTcClass($lid);
		# Get parent tc class
		my $classID = $changes->{'ClassID'};
		my $parentTcClass = getParentTcClassFromClassID($classID);
		# Grab some hash table ID's we need
		my $ip3HtHex = $tcFilterMappings->{$ip1}->{$ip2}->{$ip3}->{'id'};
		my $ip4Hex = toHex($ip4);
		# Generate our filter handle
		my $filterHandle = "${ip3HtHex}:${ip4Hex}:1";

		# Save limit tc class ID
		setLimitAttribute($lid,'tc.class',$tcClass);
		setLimitAttribute($lid,'tc.filter',"${ip3HtHex}:${ip4Hex}:1");

		#
		# SETUP MAIN TRAFFIC LIMITS
		#

		# Create main rate limiting classes
		$changeSet->add([
				'/sbin/tc','class','add',
					'dev',$config->{'txiface'},
					'parent',"1:$parentTcClass",
					'classid',"1:$tcClass",
					'htb',
						'rate', $changes->{'TrafficLimitTx'} . "kbit",
						'ceil', $changes->{'TrafficLimitTxBurst'} . "kbit",
						'prio', $changes->{'TrafficPriority'},
		]);
		$changeSet->add([
				'/sbin/tc','class','add',
					'dev',$config->{'rxiface'},
					'parent',"1:$parentTcClass",
					'classid',"1:$tcClass",
					'htb',
						'rate', $changes->{'TrafficLimitRx'} . "kbit",
						'ceil', $changes->{'TrafficLimitRxBurst'} . "kbit",
						'prio', $changes->{'TrafficPriority'},
		]);

		#
		# SETUP DEFAULT CLASSIFICATION OF TRAFFIC
		#

		# Default traffic classification to main class
		$changeSet->add([
				'/sbin/tc','filter','add',
					'dev',$config->{'txiface'},
					'parent','1:',
					'prio','10',
					'handle',$filterHandle,
					'protocol',$config->{'ip_protocol'},
					'u32',
						'ht',"${ip3HtHex}:${ip4Hex}:",
							'match','ip','dst',$limit->{'IP'},
								'at',16+$config->{'iphdr_offset'},
					'flowid',"1:$tcClass",
		]);
		$changeSet->add([
				'/sbin/tc','filter','add',
					'dev',$config->{'rxiface'},
					'parent','1:',
					'prio','10',
					'handle',$filterHandle,
					'protocol',$config->{'ip_protocol'},
					'u32',
						'ht',"${ip3HtHex}:${ip4Hex}:",
							'match','ip','src',$limit->{'IP'},
								'at',12+$config->{'iphdr_offset'},
					'flowid',"1:$tcClass",
		]);

		_tc_class_optimize($changeSet,$config->{'txiface'},$tcClass,$changes->{'TrafficLimitTx'});
		_tc_class_optimize($changeSet,$config->{'rxiface'},$tcClass,$changes->{'TrafficLimitRx'});

		# Set current live values
		setLimitAttribute($lid,'tc.live.ClassID',$changes->{'ClassID'});
		setLimitAttribute($lid,'tc.live.TrafficLimitTx',$changes->{'TrafficLimitTx'});
		setLimitAttribute($lid,'tc.live.TrafficLimitTxBurst',$changes->{'TrafficLimitTxBurst'});
		setLimitAttribute($lid,'tc.live.TrafficLimitRx',$changes->{'TrafficLimitRx'});
		setLimitAttribute($lid,'tc.live.TrafficLimitRxBurst',$changes->{'TrafficLimitRxBurst'});
		setLimitAttribute($lid,'tc.live.TrafficPriority',$changes->{'TrafficPriority'});
	}

	# Post changeset
	$kernel->post("_tc" => "queue" => $changeSet);

	# Mark as live
	setShaperState($lid,SHAPER_LIVE);
}


# Change event for tc
sub do_change
{
	my ($kernel, $lid, $changes) = @_[KERNEL, ARG0, ARG1];



	# Pull in limit
	my $limit;
	if (!defined($limit = getLimit($lid))) {
		$logger->log(LOG_ERR,"[TC] Shaper 'change' event with non existing limit '$lid'");
		return;
	}

	# Check if we don't have a changeset
	if (!defined($changes)) {
		$logger->log(LOG_WARN,"[TC] Shaper got a undefined changeset to process for '$lid'");
		return;
	}

	$logger->log(LOG_INFO,"[TC] Processing changes for '$limit->{'Username'}' [$lid]");

	# Pull in values we need
	my $classID = getLimitAttribute($lid,'tc.live.ClassID');
	if (defined($changes->{'ClassID'}) && $changes->{'ClassID'} ne $classID) {
		$classID = $changes->{'ClassID'};
		setLimitAttribute($lid,'tc.live.ClassID',$classID);
	}

	my $trafficLimitTx;
	my $trafficLimitTxBurst;
	if (defined($changes->{'TrafficLimitTx'})) {
		$trafficLimitTx = $changes->{'TrafficLimitTx'};
		setLimitAttribute($lid,'tc.live.TrafficLimitTx',$trafficLimitTx);
	} else {
		$trafficLimitTx = getLimitAttribute($lid,'tc.live.TrafficLimitTx');
	}
	if (defined($changes->{'TrafficLimitTxBurst'})) {
		$trafficLimitTxBurst = $changes->{'TrafficLimitTxBurst'};
		setLimitAttribute($lid,'tc.live.TrafficLimitTxBurst',$trafficLimitTxBurst);
	} else {
		$trafficLimitTxBurst = getLimitAttribute($lid,'tc.live.TrafficLimitTxBurst');
	}

	my $trafficLimitRx;
	my $trafficLimitRxBurst;
	if (defined($changes->{'TrafficLimitRx'})) {
		$trafficLimitRx = $changes->{'TrafficLimitRx'};
		setLimitAttribute($lid,'tc.live.TrafficLimitRx',$trafficLimitRx);
	} else {
		$trafficLimitRx = getLimitAttribute($lid,'tc.live.TrafficLimitRx');
	}
	if (defined($changes->{'TrafficLimitRxBurst'})) {
		$trafficLimitRxBurst = $changes->{'TrafficLimitRxBurst'};
		setLimitAttribute($lid,'tc.live.TrafficLimitRxBurst',$trafficLimitRxBurst);
	} else {
		$trafficLimitRxBurst = getLimitAttribute($lid,'tc.live.TrafficLimitRxBurst');
	}

	my $trafficPriority;
	if (defined($changes->{'TrafficPriority'})) {
		$trafficPriority = $changes->{'TrafficPriority'};
		setLimitAttribute($lid,'tc.live.TrafficPriority',$trafficPriority);
	} else {
		$trafficPriority = getLimitAttribute($lid,'tc.live.TrafficPriority');
	}

	my $tcClass = getLimitAttribute($lid,'tc.class');


	my $parentTcClass = getParentTcClassFromClassID($classID);


	my $changeSet = TC::ChangeSet->new();
	$changeSet->add([
			'/sbin/tc','class','change',
				'dev',$config->{'txiface'},
				'parent',"1:$parentTcClass",
				'classid',"1:$tcClass",
				'htb',
					'rate', $trafficLimitTx . "kbit",
					'ceil', $trafficLimitTxBurst . "kbit",
					'prio', $trafficPriority,
	]);
	$changeSet->add([
			'/sbin/tc','class','change',
				'dev',$config->{'rxiface'},
				'parent',"1:$parentTcClass",
				'classid',"1:$tcClass",
				'htb',
					'rate', $trafficLimitRx . "kbit",
					'ceil', $trafficLimitRxBurst . "kbit",
					'prio', $trafficPriority,
	]);
	# Post changeset
	$kernel->post("_tc" => "queue" => $changeSet);
}


# Remove event for tc
sub do_remove
{
	my ($kernel, $lid) = @_[KERNEL, ARG0];

	my $changeSet = TC::ChangeSet->new();


	# Pull in limit
	my $limit;
	if (!defined($limit = getLimit($lid))) {
		$logger->log(LOG_ERR,"[TC] Shaper 'change' event with non existing limit '$lid'");
		return;
	}

	$logger->log(LOG_INFO,"[TC] Remove '$limit->{'Username'}' [$lid]");

	# Grab varaibles we need to make this happen
	my $tcClass = getLimitAttribute($lid,'tc.class');
	my $filterHandle = getLimitAttribute($lid,'tc.filter');

	my $classID = getLimitAttribute($lid,'tc.live.ClassID');
	my $parentTcClass = getParentTcClassFromClassID($classID);


	# Clear up the filter
	$changeSet->add([
			'/sbin/tc','filter','del',
				'dev',$config->{'txiface'},
				'parent','1:',
				'prio','10',
				'handle',$filterHandle,
				'protocol',$config->{'ip_protocol'},
				'u32',
	]);
	$changeSet->add([
			'/sbin/tc','filter','del',
				'dev',$config->{'rxiface'},
				'parent','1:',
				'prio','10',
				'handle',$filterHandle,
				'protocol',$config->{'ip_protocol'},
				'u32',
	]);
	# Clear up the class
	$changeSet->add([
			'/sbin/tc','class','del',
				'dev',$config->{'txiface'},
				'parent',"1:$parentTcClass",
				'classid',"1:$tcClass",
	]);
	$changeSet->add([
			'/sbin/tc','class','del',
				'dev',$config->{'rxiface'},
				'parent',"1:$parentTcClass",
				'classid',"1:$tcClass",
	]);

	# And recycle the class
	disposeTcClass($tcClass);

	# Post changeset
	$kernel->post("_tc" => "queue" => $changeSet);

	# Mark as not live
	setShaperState($lid,SHAPER_NOTLIVE);

	# Cleanup attributes
	removeLimitAttribute($lid,'tc.class');
	removeLimitAttribute($lid,'tc.filter');
}


# Function to get next available TC filter
sub getTcFilter
{
	my $lid = shift;


	my $id = pop(@{$tcFilters->{'free'}});

	# Generate new number
	if (!$id) {
		$id = keys %{$tcFilters->{'track'}};
		# Bump ID up
		$id += TC_FILTER_LIMIT_BASE;
		# We cannot use ID 800, its internal
		$id = 801 if ($id == 800);
		# Hex it
		$id = toHex($id);
	}

	$tcFilters->{'track'}->{$id} = $lid;

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


# Function to get TC parent class from ClassID
sub getParentTcClassFromClassID
{
	my $cid = shift;

	return toHex($cid + TC_CLASS_BASE);;
}

# Function to get next available TC class
sub getTcClass
{
	my $lid = shift;


	my $id = pop(@{$tcClasses->{'free'}});

	# Generate new number
	if (!$id) {
		$id = keys %{$tcClasses->{'track'}};
		$id += TC_CLASS_LIMIT_BASE;
		# Hex it
		$id = toHex($id);
	}

	$tcClasses->{'track'}->{$id} = $lid;

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


# Grab limit ID from TC class
sub getLIDFromTcClass
{
	my $class = shift;

	return $tcClasses->{'track'}->{$class};
}


# Get interfaces we manage
sub getInterfaces
{
	return ($config->{'txiface'},$config->{'rxiface'});
}


# Get TX iface
sub getConfigTxIface
{
	return $config->{'txiface'};
}


# Get RX iface
sub getConfigRxIface
{
	return $config->{'rxiface'};
}

sub isTcTrafficClassValid
{
	my $class = shift;

	my $classID = hex($class) - TC_CLASS_BASE;

	return isTrafficClassValid($classID);
}


# Function to initialize an interface
sub _tc_iface_init
{
	my ($changeSet,$iface,$rate) = @_;


	# Work out rates
	my $BERate = int($rate/10); # We use 10% of the rate for Best effort
	my $CIRate = $rate - $BERate; # Rest is for our clients
	# Config that may change...
	my @rootConfig = ();


	$changeSet->add([
			'/sbin/tc','qdisc','del',
				'dev',$iface,
				'root',
	]);

	# Do we have a default pool? if so we must direct traffic there
	my $defaultPool = getDefaultPoolConfig();
	my $defaultPoolClass;
	if ($defaultPool) {
		# Push unclassified traffic to this class
		$defaultPoolClass = getParentTcClassFromClassID($defaultPool->{'classid'});
		push(@rootConfig,'default',$defaultPoolClass);
	}

	$changeSet->add([
			'/sbin/tc','qdisc','add',
				'dev',$iface,
				'root',
				'handle','1:',
				'htb',
					@rootConfig
	]);
	$changeSet->add([
			'/sbin/tc','class','add',
				'dev',$iface,
				'parent','1:',
				'classid','1:1',
				'htb',
					'rate',"${rate}mbit",
	]);

	my $classes = getTrafficClasses();
	my $lastClassUsed = 0;
	foreach my $classID (keys %{$classes}) {
		my $parentTcClass = getParentTcClassFromClassID($classID);

		# Add class
		$changeSet->add([
				'/sbin/tc','class','add',
					'dev',$iface,
					'parent','1:1',
					'classid',"1:$parentTcClass",
					'htb',
						'rate',"${BERate}mbit",
						'ceil',"${rate}mbit",
						'prio',$classID,
		]);
		# Bump if we ascending in class ID's...
		if ($classID > $lastClassUsed) {
			$lastClassUsed = $classID;
		}
	}

	# Process our default pool traffic optimizations
	if (defined($defaultPool)) {
		# XXX: Bit dirty - Work out which rate to use
		my $rateItem;
		if ($iface eq $config->{'txiface'}) {
			$rateItem = "txrate";
		} elsif ($iface eq $config->{'rxiface'}) {
			$rateItem = "rxrate";
		}
		# If we have a rate for this iface, then use it
		if (defined($rateItem)) {
			_tc_class_optimize($changeSet,$iface,$defaultPoolClass,$defaultPool->{$rateItem});
			# This is going to add queue diciplines for our 3 bands
			_tc_iface_optimize($changeSet,$lastClassUsed,$iface,$defaultPoolClass,$defaultPool->{$rateItem});
		}
	}
}


# Function to apply SFQ to the interface priority classes
# XXX: This probably needs working on
sub _tc_iface_optimize
{
	my ($changeSet,$lastClassUsed,$iface,$parentClass,$rate) = @_;


	# Make the queue size big enough
	my $queueSize = ($rate * 1024) / 8;

	# RED metrics (sort of as per manpage)
	my $redAvPkt = 1000;
	my $redMax = int($queueSize / 4);
	my $redMin = int($redMax / 3);
	my $redBurst = int( ($redMin+$redMin+$redMax) / (4*$redAvPkt));
	my $redLimit = $queueSize;

	# Priority band
	my $i = 1;

	$changeSet->add([
			'/sbin/tc','qdisc','add',
				'dev',$iface,
				'parent',"$parentClass:".toHex($i),
				'handle',getParentTcClassFromClassID($lastClassUsed+$i).":",
				'bfifo',
					'limit',$queueSize,
	]);

	$i++;
	$changeSet->add([
			'/sbin/tc','qdisc','add',
				'dev',$iface,
				'parent',"$parentClass:".toHex($i),
				'handle',getParentTcClassFromClassID($lastClassUsed+$i).":",
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
	$changeSet->add([
			'/sbin/tc','qdisc','add',
				'dev',$iface,
				'parent',"$parentClass:".toHex($i),
				'handle',getParentTcClassFromClassID($lastClassUsed+$i).":",
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
# XXX: This probably needs working on
sub _tc_class_optimize
{
	my ($changeSet,$iface,$tcClass,$rate) = @_;


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
	$changeSet->add([
			'/sbin/tc','qdisc','add',
				'dev',$iface,
				'parent',"1:$tcClass",
				'handle',"$tcClass:",
				'prio',
					'bands','3',
					'priomap','2','2','2','2','2','2','2','2','2','2','2','2','2','2','2','2',
	]);

	#
	# CLASSIFICATIONS
	#

	# Prioritize ICMP up to a certain limit
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x1','0xff', # ICMP
						'at',9+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	# Prioritize ACK up to a certain limit
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x10','0xff', # ACK
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	# Prioritize SYN-ACK up to a certain limit
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x12','0xff', # SYN-ACK
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	# Prioritize FIN up to a certain limit
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x1','0xff', # FIN
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	# Prioritize RST up to a certain limit
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x4','0xff', # RST
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	# DNS
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x0035','0xffff', # SPORT 53
						'at',20+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x0035','0xffff', # DPORT 53
						'at',22+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	# VOIP
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x13c4','0xffff', # SPORT 5060
						'at',20+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x13c4','0xffff', # DPORT 5060
						'at',22+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	# SNMP
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0xa1','0xffff', # SPORT 161
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$tcClass:1",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0xa1','0xffff', # DPORT 161
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$tcClass:1",
	]);
	# FIXME: Make this customizable not hard coded
	# Mikrotik Management Port
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x2063','0xffff', # SPORT 8291
						'at',20+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x2063','0xffff', # DPORT 8291
						'at',22+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$tcClass:1",
	]);
	# SMTP
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x19','0xffff', # SPORT 25
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$tcClass:2",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x19','0xffff', # DPORT 25
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$tcClass:2",
	]);
	# POP3
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x6e','0xffff', # SPORT 110
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$tcClass:2",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x6e','0xffff', # DPORT 110
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$tcClass:2",
	]);
	# IMAP
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x8f','0xffff', # SPORT 143
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$tcClass:2",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x8f','0xffff', # DPORT 143
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$tcClass:2",
	]);
	# HTTP
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x50','0xffff', # SPORT 80
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$tcClass:2",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x50','0xffff', # DPORT 80
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$tcClass:2",
	]);
	# HTTPS
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x1bb','0xffff', # SPORT 443
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$tcClass:2",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$iface,
				'parent',"$tcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x1bb','0xffff', # DPORT 443
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$tcClass:2",
	]);
}



#
# Task/child communication & handling stuff
#

# Initialize our tc session
sub task_session_start
{
	my $kernel = $_[KERNEL];

	# Set our alias
	$kernel->alias_set("_tc");

	# Setup handing of console INT
	$kernel->sig('INT', 'handle_SIGINT');

	# Fire things up, we trigger this to process the task queue generated during init
	$kernel->yield("task_run_next");
}


# Add task to queue
sub _task_add_to_queue
{
	my $changeSet = shift;


	# Extract the changeset into commands
	my $numChanges = 0;
	foreach my $cmd ($changeSet->extract()) {
		# Rip off path to tc command
		shift(@{$cmd});
		# Build commandline string
		my $cmdStr = join(' ',@{$cmd});
		push(@taskQueue,$cmdStr);
		$numChanges++;
	}

	$logger->log(LOG_DEBUG,"[TC] TASK: Queued $numChanges changes");
}


# Send the next command in the task direction
sub _task_put_next
{
	my ($heap,$task) = @_;


	# Task was busy, this signifies its done, so lets take the next command
	if (my $cmdStr = shift(@taskQueue)) {
		# Remove off idle task list if its there
		delete($heap->{'idle_tasks'}->{$task->ID});

		$task->put($cmdStr);
		$logger->log(LOG_DEBUG,"[TC] TASK/".$task->ID.": Starting '$cmdStr' as ".$task->ID." with PID ".$task->PID);

	# If there is no commands in the queue, set it to idle
	} else {
		# Set task to idle
		$heap->{'idle_tasks'}->{$task->ID} = $task;
	}
}


# Run a task
sub task_add
{
	my ($kernel,$heap,$changeSet) = @_[KERNEL,HEAP,ARG0];


	# Internal function to add command to queue
	_task_add_to_queue($changeSet);

	# Trigger a run if list is not empty
	if (@taskQueue) {
		$kernel->yield("task_run_next");
	}
}


# Run next task
sub task_run_next
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# If we already have children processing tasks, don't create another
	if (keys %{$heap->{'task_by_wid'}}) {
		# Loop with idle tasks ... return if we found one
		foreach my $task_id (keys %{$heap->{'idle_tasks'}}) {
			_task_put_next($heap,$heap->{'idle_tasks'}->{$task_id});
			# XXX: Limit concurrency to 1
			last;
		}
		# XXX: Limit concurrency to 1
		return;
	}

	# Check if we have a task coming off the top of the task queue
	if (@taskQueue) {

		# Create task
		my $task = POE::Wheel::Run->new(
			Program => [ '/sbin/tc', '-force', '-batch' ],
			Conduit => 'pipe',
#			Program => [ '/root/tc.sh' ],
			StdioFilter => POE::Filter::Line->new( Literal => "\n" ),
			StderrFilter => POE::Filter::Line->new( Literal => "\n" ),
			StdoutEvent => 'task_child_stdout',
			StderrEvent => 'task_child_stderr',
			CloseEvent => 'task_child_close',
			StdinEvent => 'task_child_stdin',
			ErrorEvent => 'task_child_error',
		) or $logger->log(LOG_ERR,"[TC] TASK: Unable to start task");

		# Set task ID
		my $task_id = $task->ID;


		# Intercept SIGCHLD
		$kernel->sig_child($task->PID, "handle_SIGCHLD");

		# Wheel events include the wheel's ID.
		$heap->{'task_by_wid'}->{$task_id} = $task;
		# Signal events include the process ID.
		$heap->{'task_by_pid'}->{$task_id} = $task;

		_task_put_next($heap,$task);
	}
}


# Child writes to STDOUT
sub task_child_stdout
{
	my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
	my $task = $heap->{'task_by_wid'}->{$task_id};

	$logger->log(LOG_INFO,"[TC] TASK/$task_id: STDOUT => ".$stdout);
}


# Child writes to STDERR
sub task_child_stderr
{
	my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
	my $task = $heap->{'task_by_wid'}->{$task_id};

	$logger->log(LOG_WARN,"[TC] TASK/$task_id: STDERR => ".$stdout);
}


# Child flushed to STDIN
sub task_child_stdin
{
	my ($kernel,$heap,$task_id) = @_[KERNEL,HEAP,ARG0];
	my $task = $heap->{'task_by_wid'}->{$task_id};

	$logger->log(LOG_DEBUG,"[TC] TASK/$task_id is READY");
	# And shove another queued command its direction
	_task_put_next($heap,$task);
}



# Child closed its handles, it won't communicate with us, so remove it
sub task_child_close
{
	my ($kernel,$heap,$task_id) = @_[KERNEL,HEAP,ARG0];
	my $task = $heap->{'task_by_wid'}->{$task_id};

	# May have been reaped by task_sigchld()
	if (!defined($task)) {
		$logger->log(LOG_DEBUG,"[TC] TASK/$task_id: Closed dead child");
		return;
	}

	$logger->log(LOG_DEBUG,"[TC] TASK/$task_id: Closed PID ".$task->PID);

	# Remove other references
	delete($heap->{'task_by_wid'}->{$task_id});
	delete($heap->{'task_by_pid'}->{$task->PID});
	delete($heap->{'idle_tasks'}->{$task_id});

	# Start next one, if there is a next one
	if (@taskQueue) {
		$kernel->yield("task_run_next");
	}
}


# Child got an error event, lets remove it too
sub task_child_error
{
	my ($kernel,$heap,$operation,$errnum,$errstr,$task_id) = @_[KERNEL,HEAP,ARG0..ARG3];
	my $task = $heap->{'task_by_wid'}->{$task_id};

	if ($operation eq "read" && !$errnum) {
		$errstr = "Remote end closed"
	}

	$logger->log(LOG_ERR,"[TC] Task $task_id generated $operation error $errnum: '$errstr'");

	# If there is no task, return
	if (!defined($task)) {
		return;
	}

	# Remove other references
	delete($heap->{'task_by_wid'}->{$task_id});
	delete($heap->{'task_by_pid'}->{$task->PID});
	delete($heap->{'idle_tasks'}->{$task_id});

	# Start next one, if there is a next one
	if (@taskQueue) {
		$kernel->yield("task_run_next");
	}
}


# Reap the dead child
sub task_handle_SIGCHLD
{
	my ($kernel,$heap,$pid,$status) = @_[KERNEL,HEAP,ARG1,ARG2];
	my $task = $heap->{'task_by_pid'}->{$pid};


	$logger->log(LOG_DEBUG,"[TC] TASK: Task with PID $pid exited with status $status");

	# May have been reaped by task_child_close()
	return if (!defined($task));

	# Remove other references
	delete($heap->{'task_by_wid'}->{$task->ID});
	delete($heap->{'task_by_pid'}->{$pid});
	delete($heap->{'idle_tasks'}->{$task->ID});
}


# Handle SIGINT
sub task_handle_SIGINT
{
	my ($kernel,$heap,$signal_name) = @_[KERNEL,HEAP,ARG0];

	# Shutdown stdin on all children, this will terminate /sbin/tc
	foreach my $task_id (keys %{$heap->{'task_by_wid'}}) {
		my $task = $heap->{'task_by_wid'}{$task_id};
#		$kernel->sig_child($task->PID, "asig_child");
#		$task->kill("INT"); #NK: doesn't work
		$kernel->post($task,"shutdown_stdin"); #NK: doesn't work
	}

	$logger->log(LOG_WARN,"[TC] Killed children processes");
}






# TC changeset item
package TC::ChangeSet;

use strict;
use warnings;

# Create object
sub new
{
	my $class = shift;

	my $self = {
		'list' => [ ]
	};

	bless $self, $class;
	return $self;
}


# Add a change to the list
sub add
{
	my ($self,$change) = @_;

	push(@{$self->{'list'}},$change);
}


# Return the list
sub extract
{
	my $self = shift;

	return @{$self->{'list'}};
}



1;
# vim: ts=4
