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
		getLimitTxInterface getLimitRxInterface getLimitMatchPriority

		getTrafficPriority

		getShaperState setShaperState
		getInterfaces getInterfaceRate getInterfaceClasses getInterfaceDefaultPool

		isTrafficClassValid
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

	TC_ROOT_CLASS => 1,
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
	'ip_protocol' => "ip",
	'iphdr_offset' => 0,
};

# Queue of tasks to run
my @taskQueue = ( );
# TC classes & filters
my $tcClasses = { };
my $tcFilterMappings;
my $tcFilters = { };



# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[TC] OpenTrafficShaper tc Integration v".VERSION." - Copyright (c) 2013, AllWorldIT");


	# Grab some of our config we need
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
	# Loop with the configured interfaces and initialize them
	foreach my $interface (@{getInterfaces()})	{
		# Initialize interface
		$logger->log(LOG_INFO,"[TC] Queuing tasks to initialize '$interface'");
		_tc_iface_init($changeSet,$interface);
	}
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
			task_child_close => \&task_child_close,
			task_child_error => \&task_child_error,
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

	# Filter levels for the IP components
	my @components = split(/\./,$limit->{'IP'});
	my $ip1 = $components[0];
	my $ip2 = $components[1];
	my $ip3 = $components[2];
	my $ip4 = $components[3];
	# Grab some variables we going to need below
	my $txInterface = getLimitTxInterface($lid);
	my $rxInterface = getLimitRxInterface($lid);
	my $matchPriority = getLimitMatchPriority($lid);
	my $trafficPriority = getTrafficPriority($limit->{'ClassID'});

	# Check if we have a entry for the /8, if not we must create our 2nd level hash table and link it
	if (!defined($tcFilterMappings->{$txInterface}->{$matchPriority}->{$ip1})) {
		# Grab filter ID's for 2nd level
		my $txFilterID = _reserveTcFilter($txInterface,$matchPriority,$lid);
		# Track our mapping
		$tcFilterMappings->{$txInterface}->{$matchPriority}->{$ip1}->{'id'} = $txFilterID;
		$logger->log(LOG_DEBUG,"[TC] Linking 2nd level TX hash table to '$txFilterID' to '$ip1.0.0.0/8', priority '$matchPriority'");
		_tc_filter_add_dstlink($changeSet,$txInterface,TC_ROOT_CLASS,$matchPriority,$txFilterID,$config->{'ip_protocol'},800,"","$ip1.0.0.0/8","00ff0000");
	}
	if (!defined($tcFilterMappings->{$rxInterface}->{$matchPriority}->{$ip1})) {
		# Grab filter ID's for 2nd level
		my $rxFilterID = _reserveTcFilter($rxInterface,$matchPriority,$lid);
		# Track our mapping
		$tcFilterMappings->{$rxInterface}->{$matchPriority}->{$ip1}->{'id'} = $rxFilterID;
		$logger->log(LOG_DEBUG,"[TC] Linking 2nd level RX hash table to '$rxFilterID' to '$ip1.0.0.0/8', priority '$matchPriority'");
		_tc_filter_add_srclink($changeSet,$rxInterface,TC_ROOT_CLASS,$matchPriority,$rxFilterID,$config->{'ip_protocol'},800,"","$ip1.0.0.0/8","00ff0000");
	}

	# Check if we have our /16 hash entry, if not we must create the 3rd level hash table
	if (!defined($tcFilterMappings->{$txInterface}->{$matchPriority}->{$ip1}->{$ip2})) {
		# Grab filter ID's for 3rd level
		my $txFilterID = _reserveTcFilter($txInterface,$matchPriority,$lid);
		# Track our mapping
		$tcFilterMappings->{$txInterface}->{$matchPriority}->{$ip1}->{$ip2}->{'id'} = $txFilterID;
		# Grab some hash table ID's we need
		my $txIP1HtHex = $tcFilterMappings->{$txInterface}->{$matchPriority}->{$ip1}->{'id'};
		# And hex our IP component
		my $ip2Hex = toHex($ip2);
		$logger->log(LOG_DEBUG,"[TC] Linking 3rd level TX hash table to '$txFilterID' to '$ip1.$ip2.0.0/16', priority '$matchPriority'");
		_tc_filter_add_dstlink($changeSet,$txInterface,TC_ROOT_CLASS,$matchPriority,$txFilterID,$config->{'ip_protocol'},$txIP1HtHex,$ip2Hex,"$ip1.$ip2.0.0/16","0000ff00");
	}
	if (!defined($tcFilterMappings->{$rxInterface}->{$matchPriority}->{$ip1}->{$ip2})) {
		# Grab filter ID's for 3rd level
		my $rxFilterID = _reserveTcFilter($rxInterface,$matchPriority,$lid);
		# Track our mapping
		$tcFilterMappings->{$rxInterface}->{$matchPriority}->{$ip1}->{$ip2}->{'id'} = $rxFilterID;
		# Grab some hash table ID's we need
		my $rxIP1HtHex = $tcFilterMappings->{$rxInterface}->{$matchPriority}->{$ip1}->{'id'};
		# And hex our IP component
		my $ip2Hex = toHex($ip2);
		$logger->log(LOG_DEBUG,"[TC] Linking 3rd level RX hash table to '$rxFilterID' to '$ip1.$ip2.0.0/16', priority '$matchPriority'");
		_tc_filter_add_srclink($changeSet,$rxInterface,TC_ROOT_CLASS,$matchPriority,$rxFilterID,$config->{'ip_protocol'},$rxIP1HtHex,$ip2Hex,"$ip1.$ip2.0.0/16","0000ff00");
	}

	# Check if we have our /24 hash entry, if not we must create the 4th level hash table
	if (!defined($tcFilterMappings->{$txInterface}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3})) {
		# Grab filter ID's for 4th level
		my $txFilterID = _reserveTcFilter($txInterface,$matchPriority,$lid);
		# Track our mapping
		$tcFilterMappings->{$txInterface}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3}->{'id'} = $txFilterID;
		# Grab some hash table ID's we need
		my $txIP2HtHex = $tcFilterMappings->{$txInterface}->{$matchPriority}->{$ip1}->{$ip2}->{'id'};
		# And hex our IP component
		my $ip3Hex = toHex($ip3);
		$logger->log(LOG_DEBUG,"[TC] Linking 4th level TX hash table to '$txFilterID' to '$ip1.$ip2.$ip3.0/24', priority '$matchPriority'");
		_tc_filter_add_dstlink($changeSet,$txInterface,TC_ROOT_CLASS,$matchPriority,$txFilterID,$config->{'ip_protocol'},$txIP2HtHex,$ip3Hex,"$ip1.$ip2.$ip3.0/24","000000ff");
	}
	if (!defined($tcFilterMappings->{$rxInterface}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3})) {
		# Grab filter ID's for 4th level
		my $rxFilterID = _reserveTcFilter($rxInterface,$matchPriority,$lid);
		# Track our mapping
		$tcFilterMappings->{$rxInterface}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3}->{'id'} = $rxFilterID;
		# Grab some hash table ID's we need
		my $rxIP2HtHex = $tcFilterMappings->{$rxInterface}->{$matchPriority}->{$ip1}->{$ip2}->{'id'};
		# And hex our IP component
		my $ip3Hex = toHex($ip3);
		$logger->log(LOG_DEBUG,"[TC] Linking 4th level RX hash table to '$rxFilterID' to '$ip1.$ip2.$ip3.0/24', priority '$matchPriority'");
		_tc_filter_add_srclink($changeSet,$rxInterface,TC_ROOT_CLASS,$matchPriority,$rxFilterID,$config->{'ip_protocol'},$rxIP2HtHex,$ip3Hex,"$ip1.$ip2.$ip3.0/24","000000ff");
	}

	# Only if we have TX limits setup process them
	if (defined($changes->{'TrafficLimitTx'})) {
		# Generate our limit TC class
		my $txLimitTcClass = _reserveLimitTcClass($txInterface,$lid);
		# Get traffic class TC class
		my $classID = $changes->{'ClassID'};
		my $txClassTcClass = _getClassTcClass($txInterface,$classID);
		# Grab some hash table ID's we need
		my $txIP3HtHex = $tcFilterMappings->{$txInterface}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3}->{'id'};
		# And hex our IP component
		my $ip4Hex = toHex($ip4);
		$logger->log(LOG_DEBUG,"[TC] Linking TX IP '$limit->{'IP'}' to class '$txClassTcClass' at hash endpoint '$txIP3HtHex:$ip4Hex'");
		# Add shaping classes
		_tc_class_add($changeSet,$txInterface,TC_ROOT_CLASS,$txClassTcClass,$txLimitTcClass,$changes->{'TrafficLimitTx'},$changes->{'TrafficLimitTxBurst'},$trafficPriority);
		# Link filter to traffic flow (class)
		_tc_filter_add_flowlink($changeSet,$txInterface,TC_ROOT_CLASS,$trafficPriority,$config->{'ip_protocol'},$txIP3HtHex,$ip4Hex,"dst",16,$limit->{'IP'},$txLimitTcClass);
		# Add optimizations
		_tc_class_optimize($changeSet,$txInterface,$txLimitTcClass,$changes->{'TrafficLimitTx'});
		# Save limit tc class ID
		setLimitAttribute($lid,'tc.txclass',$txLimitTcClass);
		setLimitAttribute($lid,'tc.txfilter',"${txIP3HtHex}:${ip4Hex}:1");
		# Set current live values
		setLimitAttribute($lid,'tc.live.TrafficLimitTx',$changes->{'TrafficLimitTx'});
		setLimitAttribute($lid,'tc.live.TrafficLimitTxBurst',$changes->{'TrafficLimitTxBurst'});
	}

	# Only if we have RX limits setup process them
	if (defined($changes->{'TrafficLimitRx'})) {
		# Generate our limit TC class
		my $rxLimitTcClass = _reserveLimitTcClass($rxInterface,$lid);
		# Get traffic class TC class
		my $classID = $changes->{'ClassID'};
		my $rxClassTcClass = _getClassTcClass($rxInterface,$classID);
		# Grab some hash table ID's we need
		my $rxIP3HtHex = $tcFilterMappings->{$rxInterface}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3}->{'id'};
		# And hex our IP component
		my $ip4Hex = toHex($ip4);
		$logger->log(LOG_DEBUG,"[TC] Linking RX IP '$limit->{'IP'}' to class '$rxClassTcClass' at hash endpoint '$rxIP3HtHex:$ip4Hex'");
		# Add shaping classes
		_tc_class_add($changeSet,$rxInterface,TC_ROOT_CLASS,$rxClassTcClass,$rxLimitTcClass,$changes->{'TrafficLimitRx'},$changes->{'TrafficLimitRxBurst'},$trafficPriority);
		# Link filter to traffic flow (class)
		_tc_filter_add_flowlink($changeSet,$rxInterface,TC_ROOT_CLASS,$trafficPriority,$config->{'ip_protocol'},$rxIP3HtHex,$ip4Hex,"src",12,$limit->{'IP'},$rxLimitTcClass);
		# Add optimizations
		_tc_class_optimize($changeSet,$rxInterface,$rxLimitTcClass,$changes->{'TrafficLimitRx'});
		# Save limit tc class ID
		setLimitAttribute($lid,'tc.rxclass',$rxLimitTcClass);
		setLimitAttribute($lid,'tc.rxfilter',"${rxIP3HtHex}:${ip4Hex}:1");
		# Set current live values
		setLimitAttribute($lid,'tc.live.TrafficLimitRx',$changes->{'TrafficLimitRx'});
		setLimitAttribute($lid,'tc.live.TrafficLimitRxBurst',$changes->{'TrafficLimitRxBurst'});
	}

	setLimitAttribute($lid,'tc.live.ClassID',$changes->{'ClassID'});

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

	# Grab our interfaces
	my $txInterface = getLimitTxInterface($lid);
	my $rxInterface = getLimitRxInterface($lid);
	# Grab our classes
	my $txLimitTcClass = getLimitAttribute($lid,'tc.txclass');
	my $rxLimitTcClass = getLimitAttribute($lid,'tc.rxclass');
	# Grab our minor classes
	my $txClassTcClass = _getClassTcClass($txInterface,$classID);
	my $rxClassTcClass = _getClassTcClass($rxInterface,$classID);
	# Grab traffic priority
	my $trafficPriority = getTrafficPriority($classID);

	# Generate changeset
	my $changeSet = TC::ChangeSet->new();
	_tc_class_change($changeSet,$txInterface,TC_ROOT_CLASS,$txClassTcClass,$txLimitTcClass,$trafficLimitTx,$trafficLimitTxBurst,$trafficPriority);
	_tc_class_change($changeSet,$rxInterface,TC_ROOT_CLASS,$rxClassTcClass,$rxLimitTcClass,$trafficLimitRx,$trafficLimitRxBurst,$trafficPriority);

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

	# Make sure its being shaped at present, it could be we have multiple removes queued?
	if (getShaperState($lid) == SHAPER_NOTLIVE) {
		$logger->log(LOG_INFO,"[TC] Ignoring duplicate remove for '$limit->{'Username'}' [$lid]");
		return;
	}

	$logger->log(LOG_INFO,"[TC] Remove '$limit->{'Username'}' [$lid]");

	# Grab our interfaces
	my $txInterface = getLimitTxInterface($lid);
	my $rxInterface = getLimitRxInterface($lid);
	# Grab varaibles we need to make this happen
	my $txLimitTcClass = getLimitAttribute($lid,'tc.txclass');
	my $rxLimitTcClass = getLimitAttribute($lid,'tc.rxclass');
	# Grab our filters
	my $txFilter = getLimitAttribute($lid,'tc.txfilter');
	my $rxFilter = getLimitAttribute($lid,'tc.rxfilter');

	# Grab current class ID
	my $classID = getLimitAttribute($lid,'tc.live.ClassID');
	my $trafficPriority = getTrafficPriority($classID);
	# Grab our minor classes
	my $txClassTcClass = _getClassTcClass($txInterface,$classID);
	my $rxClassTcClass = _getClassTcClass($rxInterface,$classID);


	# Clear up the filter
	$changeSet->add([
			'/sbin/tc','filter','del',
				'dev',$txInterface,
				'parent','1:',
				'prio',$trafficPriority,
				'handle',$txFilter,
				'protocol',$config->{'ip_protocol'},
				'u32',
	]);
	$changeSet->add([
			'/sbin/tc','filter','del',
				'dev',$rxInterface,
				'parent','1:',
				'prio',$trafficPriority,
				'handle',$rxFilter,
				'protocol',$config->{'ip_protocol'},
				'u32',
	]);
	# Clear up the class
	$changeSet->add([
			'/sbin/tc','class','del',
				'dev',$txInterface,
				'parent',"1:$txClassTcClass",
				'classid',"1:$txLimitTcClass",
	]);
	$changeSet->add([
			'/sbin/tc','class','del',
				'dev',$rxInterface,
				'parent',"1:$rxClassTcClass",
				'classid',"1:$rxLimitTcClass",
	]);

	# And recycle the classs
	_disposeLimitTcClass($txInterface,$txLimitTcClass);
	_disposeLimitTcClass($rxInterface,$rxLimitTcClass);

	_disposePrioTcClass($txInterface,$txLimitTcClass);
	_disposePrioTcClass($rxInterface,$rxLimitTcClass);

	# Post changeset
	$kernel->post("_tc" => "queue" => $changeSet);

	# Mark as not live
	setShaperState($lid,SHAPER_NOTLIVE);

	# Cleanup attributes
	removeLimitAttribute($lid,'tc.txclass');
	removeLimitAttribute($lid,'tc.rxclass');
	removeLimitAttribute($lid,'tc.txfilter');
	removeLimitAttribute($lid,'tc.rxfilter');
}


# Grab limit ID from TC class
sub getLIDFromTcLimitClass
{
	my ($interface,$tcLimitClass) = @_;

	return __getRefByMinorTcClass($interface,TC_ROOT_CLASS,$tcLimitClass);
}


# Function to return if this is linked to a system class or limit class
sub isTcLimitClass
{
	my ($interface,$majorTcClass,$minorTcClass) = @_;


	# Return the class ID if found
	if (my $ref = __getRefByMinorTcClass($interface,$majorTcClass,$minorTcClass)) {
		if (!($ref =~ /^_class_/)) {
			return $minorTcClass;
		}
	}

	return undef;
}


# Function to return the traffic class ID if its valid
sub isTcTrafficClassValid
{
	my ($interface,$majorTcClass,$minorTcClass) = @_;


	# Return the class ID if found
	if (__getRefByMinorTcClass($interface,$majorTcClass,$minorTcClass)) {
		return $minorTcClass;
	}

	return undef;
}

# Return the ClassID from a TC limit class
# This is similar to isTcTrafficClassValid() but returns the ref, not the minor class
sub getCIDFromTcLimitClass
{
	my ($interface,$majorTcClass,$minorTcClass) = @_;


	# Grab ref
	my $ref = __getRefByMinorTcClass($interface,$majorTcClass,$minorTcClass);
	# Chop off _class: and return if we did
	if (defined($ref) && $ref =~ s/^_class_://) {
		return $ref;
	}

	return undef;
}



#
# Internal functions
#


# Function to initialize an interface
sub _tc_iface_init
{
	my ($changeSet,$interface) = @_;


	# Grab our interface rate
	my $rate = getInterfaceRate($interface);
	# Grab interface class configuration
	my $classes = getInterfaceClasses($interface);


	# Clear the qdisc from the interface
	$changeSet->add([
			'/sbin/tc','qdisc','del',
				'dev',$interface,
				'root',
	]);

	# Create our parent classes
	foreach my $classID (sort {$a <=> $b} keys %{$classes}) {
		# We don't really need the result, we just need the class created
		_reserveClassTcClass($interface,$classID);
	}

	# Do we have a default pool? if so we must direct traffic there
	my @qdiscOpts = ( );
	my $defaultPool = getInterfaceDefaultPool($interface);
	my $defaultPoolClass;
	if (defined($defaultPool)) {
		# Push unclassified traffic to this class
		$defaultPoolClass = _getClassTcClass($interface,$defaultPool);
		push(@qdiscOpts,'default',$defaultPoolClass);
	}

	# Add root qdisc
	$changeSet->add([
			'/sbin/tc','qdisc','add',
				'dev',$interface,
				'root',
				'handle','1:',
				'htb',
					@qdiscOpts
	]);

	# Attach our main rate to the qdisc
	$changeSet->add([
			'/sbin/tc','class','add',
				'dev',$interface,
				'parent','1:',
				'classid','1:1',
				'htb',
					'rate',"${rate}kbit",
					'burst',"${rate}kb",
	]);

	# Setup the classes
	while ((my $classID, my $class) = each(%{$classes})) {
		my $classTcClass = _getClassTcClass($interface,$classID);

		my $trafficPriority = getTrafficPriority($classID);

		# Add class
		$changeSet->add([
				'/sbin/tc','class','add',
					'dev',$interface,
					'parent','1:1',
					'classid',"1:$classTcClass",
					'htb',
						'rate',"$class->{'cir'}kbit",
						'ceil',"$class->{'limit'}kbit",
						'prio',$trafficPriority,
						'burst', "$class->{'limit'}kb",
		]);
	}

	# Process our default pool traffic optimizations
	if (defined($defaultPool)) {
		# If we have a rate for this iface, then use it
		_tc_class_optimize($changeSet,$interface,$defaultPoolClass,$classes->{$defaultPool}->{'limit'});

		# Make the queue size big enough
		my $queueSize = ($rate * 1024) / 8;

		# RED metrics (sort of as per manpage)
		my $redAvPkt = 1000;
		my $redMax = int($queueSize / 4); # 25% mark at 100% probabilty
		my $redMin = int($redMax / 3); # Max/3 is when the probability starts
		my $redBurst = int( ($redMin+$redMax) / (2*$redAvPkt));
		my $redLimit = $queueSize;

		my $prioTcClass = _getPrioTcClass($interface,$defaultPoolClass);

		# Priority band
		my $prioBand = 1;
		$changeSet->add([
				'/sbin/tc','qdisc','add',
					'dev',$interface,
					'parent',"$prioTcClass:".toHex($prioBand),
					'handle',_reserveMajorTcClass($interface,"_default_pool_:$defaultPoolClass=>$prioBand").":",
					'bfifo',
						'limit',$queueSize,
		]);

		$prioBand++;
		$changeSet->add([
				'/sbin/tc','qdisc','add',
					'dev',$interface,
					'parent',"$prioTcClass:".toHex($prioBand),
					'handle',_reserveMajorTcClass($interface,"_default_pool_:$defaultPoolClass=>$prioBand").":",
# TODO: NK - try enable the below
#					'estimator','1sec','4sec', # Quick monitoring, every 1s with 4s constraint
					'red',
						'min',$redMin,
						'max',$redMax,
						'limit',$redLimit,
						'burst',$redBurst,
						'avpkt',$redAvPkt,
						'ecn'
# XXX: Very new kernels only ... use redflowlimit in future
#						'sfq',
#							'divisor','16384',
#							'headdrop',
#							'redflowlimit',$queueSize,
#							'ecn',
		]);

		$prioBand++;
		$changeSet->add([
				'/sbin/tc','qdisc','add',
					'dev',$interface,
					'parent',"$prioTcClass:".toHex($prioBand),
					'handle',_reserveMajorTcClass($interface,"_default_pool_:$defaultPoolClass=>$prioBand").":",
					'red',
						'min',$redMin,
						'max',$redMax,
						'limit',$redLimit,
						'burst',$redBurst,
						'avpkt',$redAvPkt,
						'ecn'
		]);
	}

}


# Function to apply traffic optimizations to a classes
# XXX: This probably needs working on
sub _tc_class_optimize
{
	my ($changeSet,$interface,$limitTcClass,$rate) = @_;


	# Rate for things like ICMP , ACK, SYN ... etc
	my $rateBand1 = int($rate * (PROTO_RATE_LIMIT / 100));
	$rateBand1 = PROTO_RATE_BURST_MIN if ($rateBand1 < PROTO_RATE_BURST_MIN);
	my $rateBand1Burst = ($rateBand1 / 8) * PROTO_RATE_BURST_MAXM;
	# Rate for things like VoIP/SSH/Telnet
	my $rateBand2 = int($rate * (PRIO_RATE_LIMIT / 100));
	$rateBand2 = PRIO_RATE_BURST_MIN if ($rateBand2 < PRIO_RATE_BURST_MIN);
	my $rateBand2Burst = ($rateBand2 / 8) * PRIO_RATE_BURST_MAXM;

	my $prioTcClass = _reservePrioTcClass($interface,$limitTcClass);

	#
	# DEFINE 3 PRIO BANDS
	#

	# We then prioritize traffic into 3 bands based on TOS
	$changeSet->add([
			'/sbin/tc','qdisc','add',
				'dev',$interface,
				'parent',"1:$limitTcClass",
				'handle',"$prioTcClass:",
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
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x1','0xff', # ICMP
						'at',9+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	# Prioritize ACK up to a certain limit
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x10','0xff', # ACK
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	# Prioritize SYN-ACK up to a certain limit
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x12','0xff', # SYN-ACK
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	# Prioritize FIN up to a certain limit
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x1','0xff', # FIN
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	# Prioritize RST up to a certain limit
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u8','0x4','0xff', # RST
						'at',33+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand1}kbit",'burst',"${rateBand1Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	# DNS
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x0035','0xffff', # SPORT 53
						'at',20+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x0035','0xffff', # DPORT 53
						'at',22+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	# VOIP
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x13c4','0xffff', # SPORT 5060
						'at',20+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x13c4','0xffff', # DPORT 5060
						'at',22+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	# SNMP
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0xa1','0xffff', # SPORT 161
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:1",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0xa1','0xffff', # DPORT 161
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:1",
	]);
	# TODO: Make this customizable not hard coded?
	# Mikrotik Management Port
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x2063','0xffff', # SPORT 8291
						'at',20+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u16','0x2063','0xffff', # DPORT 8291
						'at',22+$config->{'iphdr_offset'},
				'police',
					'rate',"${rateBand2}kbit",'burst',"${rateBand2Burst}k",'continue',
				'flowid',"$prioTcClass:1",
	]);
	# SMTP
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x19','0xffff', # SPORT 25
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:2",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x19','0xffff', # DPORT 25
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:2",
	]);
	# POP3
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x6e','0xffff', # SPORT 110
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:2",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x6e','0xffff', # DPORT 110
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:2",
	]);
	# IMAP
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x8f','0xffff', # SPORT 143
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:2",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x8f','0xffff', # DPORT 143
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:2",
	]);
	# HTTP
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x50','0xffff', # SPORT 80
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:2",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x50','0xffff', # DPORT 80
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:2",
	]);
	# HTTPS
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x1bb','0xffff', # SPORT 443
						'at',20+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:2",
	]);
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$prioTcClass:",
				'prio','1',
				'protocol',$config->{'ip_protocol'},
				'u32',
					'match','u8','0x6','0xff', # TCP
						'at',9+$config->{'iphdr_offset'},
					'match','u16','0x1bb','0xffff', # DPORT 443
						'at',22+$config->{'iphdr_offset'},
				'flowid',"$prioTcClass:2",
	]);
}


# Function to easily add a hash table
sub _tc_filter_add_dstlink
{
	my ($changeSet,$interface,$parentID,$priority,$filterID,$protocol,$htHex,$ipHex,$cidr,$mask) = @_;

	# Add hash table
	_tc_filter_hash_add($changeSet,$interface,$parentID,$priority,$filterID,$config->{'ip_protocol'});
	# Add filter to it
	_tc_filter_add($changeSet,$interface,$parentID,$priority,$filterID,$protocol,$htHex,$ipHex,"dst",16,$cidr,$mask);
}


# Function to easily add a hash table
sub _tc_filter_add_srclink
{
	my ($changeSet,$interface,$parentID,$priority,$filterID,$protocol,$htHex,$ipHex,$cidr,$mask) = @_;

	# Add hash table
	_tc_filter_hash_add($changeSet,$interface,$parentID,$priority,$filterID,$config->{'ip_protocol'});
	# Add filter to it
	_tc_filter_add($changeSet,$interface,$parentID,$priority,$filterID,$protocol,$htHex,$ipHex,"src",12,$cidr,$mask);
}


# Function to easily add a hash table
sub _tc_filter_add_flowlink
{
	my ($changeSet,$interface,$parentID,$priority,$protocol,$htHex,$ipHex,$type,$offset,$ip,$limitTcClass) = @_;


	# Link hash table
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$parentID:",
				'prio',$priority,
				'handle',"$htHex:$ipHex:1",
				'protocol',$protocol,
				'u32',
					# Root hash table
					'ht',"$htHex:$ipHex:",
						'match','ip',$type,$ip,
							'at',$offset+$config->{'iphdr_offset'},
					# Link to our flow
					'flowid',"1:$limitTcClass",
	]);
}


# Function to easily add a hash table
sub _tc_filter_hash_add
{
	my ($changeSet,$interface,$parentID,$priority,$filterID,$protocol) = @_;

	# Create second level hash table for $ip1
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$parentID:",
				'prio',$priority,
				'handle',"$filterID:",
				'protocol',$protocol,
				'u32',
					'divisor','256',
	]);
}


# Function to easily add a hash table
sub _tc_filter_add
{
	my ($changeSet,$interface,$parentID,$priority,$filterID,$protocol,$htHex,$ipHex,$type,$offset,$cidr,$mask) = @_;

	# Link hash table
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface,
				'parent',"$parentID:",
				'prio',$priority,
				'protocol',$protocol,
				'u32',
					# Root hash table
					'ht',"$htHex:$ipHex:",
						'match','ip',$type,$cidr,
							'at',$offset+$config->{'iphdr_offset'},
					'hashkey','mask',"0x$mask",
						'at',$offset+$config->{'iphdr_offset'},
					# Link to our hash table
					'link',"$filterID:"
	]);
}


# Function to add a TC class
sub _tc_class_add
{
		my ($changeSet,$interface,$majorTcClass,$classTcClass,$limitTcClass,$rate,$ceil,$trafficPriority) = @_;

		# Set burst to a sane value
		my $burst = int($ceil / 8 / 5);

		# Create main rate limiting classes
		$changeSet->add([
				'/sbin/tc','class','add',
					'dev',$interface,
					'parent',"$majorTcClass:$classTcClass",
					'classid',"$majorTcClass:$limitTcClass",
					'htb',
						'rate', "${rate}kbit",
						'ceil', "${ceil}kbit",
						'prio', $trafficPriority,
						'burst', "${burst}kb",
		]);
}


# Function to change a TC class
sub _tc_class_change
{
		my ($changeSet,$interface,$majorTcClass,$classTcClass,$limitTcClass,$rate,$ceil,$trafficPriority) = @_;


		# Set burst to a sane value
		my $burst = int($ceil / 8 / 5);

		# Create main rate limiting classes
		$changeSet->add([
				'/sbin/tc','class','change',
					'dev',$interface,
					'parent',"$majorTcClass:$classTcClass",
					'classid',"$majorTcClass:$limitTcClass",
					'htb',
						'rate', "${rate}kbit",
						'ceil', "${ceil}kbit",
						'prio', $trafficPriority,
						'burst', "${burst}kb",
		]);
}


# Get a limit class TC class
sub _reserveLimitTcClass
{
	my ($interface,$lid) = @_;

	return __reserveMinorTcClass($interface,TC_ROOT_CLASS,$lid);
}


# Get a traffic class TC class
sub _reserveClassTcClass
{
	my ($interface,$classID) = @_;

	return __reserveMinorTcClass($interface,TC_ROOT_CLASS,"_class_:$classID");
}


# Get a prio class TC class
# This is a MAJOR class!
sub _reservePrioTcClass
{
	my ($interface,$classID) = @_;

	return _reserveMajorTcClass($interface,"_prioclass_:$classID");
}


# Return TC class using class
sub _getClassTcClass
{
	my ($interface,$classID) = @_;

	return __getMinorTcClassByRef($interface,TC_ROOT_CLASS,"_class_:$classID");
}


# Return prio TC class using class
# This returns a MAJOR class from a tc class
sub _getPrioTcClass
{
	my ($interface,$tcClass) = @_;

	return __getMajorTcClassByRef($interface,"_prioclass_:$tcClass");
}


# Function to dispose of a TC class
sub _disposeLimitTcClass
{
	my ($interface,$tcClass) = @_;

	return __disposeMinorTcClass($interface,TC_ROOT_CLASS,$tcClass);
}


# Function to dispose of a major TC class
# Uses a TC class to get a MAJOR class, then disposes it
sub _disposePrioTcClass
{
	my ($interface,$tcClass) = @_;


	# If we can grab the major class dipose of it
	if (my $majorTcClass = _getPrioTcClass($interface,$tcClass)) {
		return __disposeMajorTcClass($interface,$majorTcClass);
	}

	return undef;
}



# Function to get next available TC class
sub __reserveMinorTcClass
{
	my ($interface,$majorTcClass,$ref) = @_;


	# Setup defaults if we don't have anything defined
	if (!defined($tcClasses->{$interface}) || !defined($tcClasses->{$interface}->{$majorTcClass})) {
		$tcClasses->{$interface}->{$majorTcClass} = {
			'free' => [ ],
			'track' => { },
			'reverse' => { },
		};
	}

	# Maybe we have one free?
	my $minorTcClass = pop(@{$tcClasses->{$interface}->{$majorTcClass}->{'free'}});

	# Generate new number
	if (!$minorTcClass) {
		$minorTcClass = keys %{$tcClasses->{$interface}->{$majorTcClass}->{'track'}};
		$minorTcClass += 2; # Skip 0 and 1
		# Hex it
		$minorTcClass = toHex($minorTcClass);
	}

	$tcClasses->{$interface}->{$majorTcClass}->{'track'}->{$minorTcClass} = $ref;
	$tcClasses->{$interface}->{$majorTcClass}->{'reverse'}->{$ref} = $minorTcClass;

	return $minorTcClass;
}


# Function to get next available major TC class
sub _reserveMajorTcClass
{
	my ($interface,$ref) = @_;


	# Setup defaults if we don't have anything defined
	if (!defined($tcClasses->{$interface})) {
		$tcClasses->{$interface} = {
			'free' => [ ],
			'track' => { },
			'reverse' => { },
		};
	}

	# Maybe we have one free?
	my $majorTcClass = pop(@{$tcClasses->{$interface}->{'free'}});

	# Generate new number
	if (!$majorTcClass) {
		$majorTcClass = keys %{$tcClasses->{$interface}->{'track'}};
		$majorTcClass += 2; # Skip 0 and 1
		# Hex it
		$majorTcClass = toHex($majorTcClass);
	}

	$tcClasses->{$interface}->{'track'}->{$majorTcClass} = $ref;
	$tcClasses->{$interface}->{'reverse'}->{$ref} = $majorTcClass;

	return $majorTcClass;
}


# Get a minor class by its rerf
sub __getMinorTcClassByRef
{
	my ($interface,$majorTcClass,$ref) = @_;


	if (defined($tcClasses->{$interface}) && defined($tcClasses->{$interface}->{$majorTcClass})) {
		return $tcClasses->{$interface}->{$majorTcClass}->{'reverse'}->{$ref};
	}

	return undef;
}


# Get a major class by its rerf
sub __getMajorTcClassByRef
{
	my ($interface,$ref) = @_;


	if (defined($tcClasses->{$interface})) {
		return $tcClasses->{$interface}->{'reverse'}->{$ref};
	}

	return undef;
}


# Get ref using the minor tc class
sub __getRefByMinorTcClass
{
	my ($interface,$majorTcClass,$minorTcClass) = @_;


	if (defined($tcClasses->{$interface}) && defined($tcClasses->{$interface}->{$majorTcClass})) {
		return $tcClasses->{$interface}->{$majorTcClass}->{'track'}->{$minorTcClass};
	}

	return undef;
}


# Function to dispose of a TC class
sub __disposeMinorTcClass
{
	my ($interface,$majorTcClass,$tcMinorClass) = @_;


	my $ref = $tcClasses->{$interface}->{$majorTcClass}->{'track'}->{$tcMinorClass};
	# Push onto free list
	push(@{$tcClasses->{$interface}->{$majorTcClass}->{'free'}},$tcMinorClass);
	# Blank the value
	$tcClasses->{$interface}->{$majorTcClass}->{'track'}->{$tcMinorClass} = undef;
	delete($tcClasses->{$interface}->{$majorTcClass}->{'reverse'}->{$ref});
}


# Function to dispose of a major TC class
sub __disposeMajorTcClass
{
	my ($interface,$tcMajorClass) = @_;


	my $ref = $tcClasses->{$interface}->{'track'}->{$tcMajorClass};
	# Push onto free list
	push(@{$tcClasses->{$interface}->{'free'}},$tcMajorClass);
	# Blank the value
	$tcClasses->{$interface}->{'track'}->{$tcMajorClass} = undef;
	delete($tcClasses->{$interface}->{'reverse'}->{$ref});
}


# Function to get next available TC filter
sub _reserveTcFilter
{
	my ($interface,$ref) = @_;


	# Setup defaults if we don't have anything defined
	if (!defined($tcFilters->{$interface})) {
		$tcFilters->{$interface} = {
			'free' => [ ],
			'track' => { },
		};
	}

	# Maybe we have one free?
	my $filterID = pop(@{$tcFilters->{$interface}->{'free'}});

	# Generate new number
	if (!$filterID) {
		$filterID = keys %{$tcFilters->{$interface}->{'track'}};
		# Bump ID up
		$filterID += TC_FILTER_LIMIT_BASE;
		# We cannot use ID 800, its internal
		$filterID = 801 if ($filterID == 800);
		# Hex it
		$filterID = toHex($filterID);
	}

	$tcFilters->{$interface}->{'track'}->{$filterID} = $ref;

	return $filterID;
}


# Function to dispose of a TC Filter
sub _disposeTcFilter
{
	my ($interface,$filterID) = @_;

	# Push onto free list
	push(@{$tcFilters->{$interface}->{'free'}},$filterID);
	# Blank the value
	$tcFilters->{$interface}->{'track'}->{$filterID} = undef;
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
	return if (!defined($task));

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
