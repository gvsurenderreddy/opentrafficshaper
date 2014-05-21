# OpenTrafficShaper Linux tc traffic shaping
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



package opentrafficshaper::plugins::tc;

use strict;
use warnings;

use POE qw(
	Wheel::Run Filter::Line
);

use awitpt::util qw(
	toHex
);
use opentrafficshaper::constants;
use opentrafficshaper::logger;
use opentrafficshaper::plugins::configmanager qw(
	getPool
	getPoolAttribute
	setPoolAttribute
	removePoolAttribute
	getPoolTxInterface
	getPoolRxInterface
	setPoolShaperState
	unsetPoolShaperState
	getPoolShaperState

	getEffectivePool

	getPoolMember
	setPoolMemberAttribute
	getPoolMemberAttribute
	removePoolMemberAttribute
	getPoolMemberMatchPriority
	setPoolMemberShaperState
	unsetPoolMemberShaperState
	getPoolMemberShaperState

	getTrafficClassPriority

	getAllTrafficClasses

	getInterface
	getInterfaces
	getInterfaceDefaultPool
	getEffectiveInterfaceTrafficClass2
	isInterfaceTrafficClassValid
	setInterfaceTrafficClassShaperState
	unsetInterfaceTrafficClassShaperState
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
	VERSION => '0.1.2',

	# 5% of a link can be used for very high priority traffic
	PROTO_RATE_LIMIT => 5,
	PROTO_RATE_BURST_MIN => 16, # With a minimum burst of 8KiB
	PROTO_RATE_BURST_MAXM => 1.5, # Multiplier for burst min to get to burst max

	# High priority traffic gets the first 20% of the bandidth to itself
	PRIO_RATE_LIMIT => 20,
	PRIO_RATE_BURST_MIN => 32, # With a minimum burst of 40KiB
	PRIO_RATE_BURST_MAXM => 1.5, # Multiplier for burst min to get to burst max

	TC_ROOT_CLASS => 1,
};


# Plugin info
our $pluginInfo = {
	Name => "Linux tc Interface",
	Version => VERSION,

	Init => \&plugin_init,
	Start => \&plugin_start,
};


# Our globals
my $globals;
# Copy of system logger
my $logger;

# Our configuration
my $config = {
	'ip_protocol' => "ip",
	'iphdr_offset' => 0,
};

#
# TASK QUEUE
#
# $globals->{'TaskQueue'}

#
# TC CLASSES & FILTERS
#
# $globals->{'TcClasses'}
# $globals->{'TcFilterMappings'}
# $globals->{'TcFilters'}


# Initialize plugin
sub plugin_init
{
	my $system = shift;


	# Setup our environment
	$logger = $system->{'logger'};

	$logger->log(LOG_NOTICE,"[TC] OpenTrafficShaper tc Integration v%s - Copyright (c) 2007-2014, AllWorldIT",VERSION);

	# Initialize
	$globals->{'TaskQueue'} = [ ];
	$globals->{'TcClasses'} = { };
	$globals->{'TcFilterMappings'} = { };
	$globals->{'TcFilters'} = { };

	# Grab some of our config we need
	if (defined(my $proto = $system->{'file.config'}->{'plugin.tc'}->{'protocol'})) {
		$logger->log(LOG_INFO,"[TC] Set protocol to '%s'",$proto);
		$config->{'ip_protocol'} = $proto;
	}
	if (defined(my $offset = $system->{'file.config'}->{'plugin.tc'}->{'iphdr_offset'})) {
		$logger->log(LOG_INFO,"[TC] Set IP header offset to '%s'",$offset);
		$config->{'iphdr_offset'} = $offset;
	}


	# We going to queue the initialization in plugin initialization so nothing at all can come before us
	my $changeSet = TC::ChangeSet->new();
	# Loop with the configured interfaces and initialize them
	foreach my $interfaceID (getInterfaces()) {
		my $interface = getInterface($interfaceID);
		# Initialize interface
		$logger->log(LOG_INFO,"[TC] Queuing tasks to initialize '%s'",$interface->{'Device'});
		_tc_iface_init($changeSet,$interfaceID);
	}
	_task_add_to_queue($changeSet);


	# This session is our main session, its alias is "shaper"
	POE::Session->create(
		inline_states => {
			_start => \&_session_start,
			_stop => \&_session_stop,

			class_change => \&_session_class_change,

			pool_add => \&_session_pool_add,
			pool_remove => \&_session_pool_remove,
			pool_change => \&_session_pool_change,

			poolmember_add => \&_session_poolmember_add,
			poolmember_remove => \&_session_poolmember_remove,
		}
	);

	# This is our session for communicating directly with tc, its alias is _tc
	POE::Session->create(
		inline_states => {
			_start => \&_task_session_start,
			_stop => sub { },
			# Signals
			_SIGCHLD => \&_task_SIGCHLD,
			_SIGINT => \&_task_SIGINT,

			# Public'ish
			queue => \&_task_queue,

			# Internal
			_task_child_stdout => \&_task_child_stdout,
			_task_child_stderr => \&_task_child_stderr,
			_task_child_stdin => \&_task_child_stdin,
			_task_child_close => \&_task_child_close,
			_task_child_error => \&_task_child_error,
			_task_run_next => \&_task_run_next,
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
sub _session_start
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Set our alias
	$kernel->alias_set("shaper");

	$logger->log(LOG_DEBUG,"[TC] Initialized");
}



# Initialize this plugins main POE session
sub _session_stop
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Remove our alias
	$kernel->alias_remove("shaper");

	# Blow away data
	$globals = undef;

	$logger->log(LOG_DEBUG,"[TC] Shutdown");

	$logger = undef;
}



# Event handler for changing a class
sub _session_class_change
{
	my ($kernel, $interfaceTrafficClassID) = @_[KERNEL, ARG0, ARG1];


	# Grab our effective class
	my $effectiveInterfaceTrafficClass = getEffectiveInterfaceTrafficClass2($interfaceTrafficClassID);

	# Grab interface ID
	my $interfaceID = $effectiveInterfaceTrafficClass->{'InterfaceID'};
	# Grab interface from config manager
	my $interface = getInterface($interfaceID);

	# Grab traffic class ID
	my $trafficClassID = $effectiveInterfaceTrafficClass->{'TrafficClassID'};

	$logger->log(LOG_INFO,"[TC] Processing interface class changes for '%s' traffic class ID '%s'",
			$interface->{'Device'},
			$trafficClassID
	);

	# Grab tc interface
	my $tcInterface = $globals->{'Interfaces'}->{$interfaceID};
	# Grab interface traffic class
	my $interfaceTrafficClass = $tcInterface->{'TrafficClasses'}->{$trafficClassID};

	# Grab the traffic class
	my $majorTcClass = $tcInterface->{'TcClass'};
	my $minorTcClass = $interfaceTrafficClass->{"TcClass"};

	# Generate changeset
	my $changeSet = TC::ChangeSet->new();

	# If we're a normal class we are treated differently than if we're a main/root class below (interface main speed)
	if ($minorTcClass > 1) {
		_tc_class_change($changeSet,$interfaceID,$majorTcClass,"",$minorTcClass,
				$effectiveInterfaceTrafficClass->{'CIR'},
				$effectiveInterfaceTrafficClass->{'Limit'}
		);
	# XXX: This will be the actual interface, we set limit and burst to the same
	} else {
		_tc_class_change($changeSet,$interfaceID,TC_ROOT_CLASS,"",$minorTcClass,$effectiveInterfaceTrafficClass->{'Limit'});
	}

	# Post changeset
	$kernel->post("_tc" => "queue" => $changeSet);

	# Mark as live
	unsetInterfaceTrafficClassShaperState($interfaceTrafficClassID,SHAPER_NOTLIVE|SHAPER_PENDING);
	setInterfaceTrafficClassShaperState($interfaceTrafficClassID,SHAPER_LIVE);
}



# Event handler for adding a pool
sub _session_pool_add
{
	my ($kernel,$heap,$pid) = @_[KERNEL, HEAP, ARG0];


	# Grab pool
	my $pool;
	if (!defined($pool = getPool($pid))) {
		$logger->log(LOG_ERR,"[TC] Shaper 'remove' event with non existing pool '%s'",$pid);
		return;
	}

	$logger->log(LOG_INFO,"[TC] Add pool '%s' to interface group '%s' [%s]",
			$pool->{'Name'},
			$pool->{'InterfaceGroupID'},
			$pool->{'ID'}
	);

	# Grab our effective pool
	my $effectivePool = getEffectivePool($pool->{'ID'});

	my $changeSet = TC::ChangeSet->new();

	# Grab some things we need from the main pool
	my $txInterfaceID = getPoolTxInterface($pool->{'ID'});
	my $rxInterfaceID = getPoolRxInterface($pool->{'ID'});

	# Grab effective config
	my $trafficClassID = $effectivePool->{'TrafficClassID'};
	my $txCIR = $effectivePool->{'TxCIR'};
	my $txLimit = $effectivePool->{'TxLimit'};
	my $rxCIR = $effectivePool->{'RxCIR'};
	my $rxLimit = $effectivePool->{'RxLimit'};
	my $trafficPriority = getTrafficClassPriority($effectivePool->{'TrafficClassID'});

	# Get the Tx traffic classes TC class
	my $tcClass_TxTrafficClass = _getTcClassFromTrafficClassID($txInterfaceID,$trafficClassID);
	# Generate our pools Tx TC class
	my $tcClass_TxPool = _reserveMinorTcClassByPoolID($txInterfaceID,$pool->{'ID'});
	# Add the main Tx TC class for this pool
	_tc_class_add($changeSet,$txInterfaceID,TC_ROOT_CLASS,$tcClass_TxTrafficClass,$tcClass_TxPool,$txCIR,
			$txLimit,$trafficPriority
	);
	# Add Tx TC optimizations
	_tc_class_optimize($changeSet,$txInterfaceID,$tcClass_TxPool,$txCIR);
	# Set Tx TC class
	setPoolAttribute($pool->{'ID'},'tc.txclass',$tcClass_TxPool);

	# Get the Rx traffic classes TC class
	my $tcClass_RxTrafficClass = _getTcClassFromTrafficClassID($rxInterfaceID,$trafficClassID);
	# Generate our pools Rx TC class
	my $tcClass_RxPool = _reserveMinorTcClassByPoolID($rxInterfaceID,$pool->{'ID'});
	# Add the main Rx TC class for this pool
	_tc_class_add($changeSet,$rxInterfaceID,TC_ROOT_CLASS,$tcClass_RxTrafficClass,$tcClass_RxPool,$rxCIR,
			$rxLimit,$trafficPriority
	);
	# Add Rx TC optimizations
	_tc_class_optimize($changeSet,$rxInterfaceID,$tcClass_RxPool,$rxCIR);
	# Set Rx TC
	setPoolAttribute($pool->{'ID'},'tc.rxclass',$tcClass_RxPool);

	# Post changeset
	$kernel->post("_tc" => "queue" => $changeSet);

	# Set current live values
	setPoolAttribute($pool->{'ID'},'shaper.live.ClassID',$trafficClassID);
	setPoolAttribute($pool->{'ID'},'shaper.live.TxCIR',$txCIR);
	setPoolAttribute($pool->{'ID'},'shaper.live.TxLimit',$txLimit);
	setPoolAttribute($pool->{'ID'},'shaper.live.RxCIR',$rxCIR);
	setPoolAttribute($pool->{'ID'},'shaper.live.RxLimit',$rxLimit);

	# Mark as live
	unsetPoolShaperState($pool->{'ID'},SHAPER_NOTLIVE|SHAPER_PENDING);
	setPoolShaperState($pool->{'ID'},SHAPER_LIVE);
}



# Event handler for removing a pool
sub _session_pool_remove
{
	my ($kernel, $pid) = @_[KERNEL, ARG0];


	my $changeSet = TC::ChangeSet->new();

	# Pull in pool
	my $pool;
	if (!defined($pool = getPool($pid))) {
		$logger->log(LOG_ERR,"[TC] Shaper 'remove' event with non existing pool '%s'",$pid);
		return;
	}

	# Make sure its not NOTLIVE
	if (getPoolShaperState($pid) & SHAPER_NOTLIVE) {
		$logger->log(LOG_WARN,"[TC] Ignoring remove for pool '%s' [%s]",
				$pool->{'Name'},
				$pool->{'ID'}
		);
		return;
	}

	$logger->log(LOG_INFO,"[TC] Removing pool '%s' [%s]",
			$pool->{'Name'},
			$pool->{'ID'}
	);

	# Grab our interfaces
	my $txInterfaceID = getPoolTxInterface($pool->{'ID'});
	my $rxInterfaceID = getPoolRxInterface($pool->{'ID'});
	# Grab the traffic class from the pool
	my $txPoolTcClass = getPoolAttribute($pool->{'ID'},'tc.txclass');
	my $rxPoolTcClass = getPoolAttribute($pool->{'ID'},'tc.rxclass');

	# Grab current class ID
	my $trafficClassID = getPoolAttribute($pool->{'ID'},'shaper.live.ClassID');
	# Grab our minor classes
	my $txTrafficClassTcClass = _getTcClassFromTrafficClassID($txInterfaceID,$trafficClassID);
	my $rxTrafficClassTcClass = _getTcClassFromTrafficClassID($rxInterfaceID,$trafficClassID);

	my $txInterface = getInterface($txInterfaceID);
	my $rxInterface = getInterface($rxInterfaceID);

	# Clear up the class
	$changeSet->add([
			'/sbin/tc','class','del',
				'dev',$txInterface->{'Device'},
				'parent',"1:$txTrafficClassTcClass",
				'classid',"1:$txPoolTcClass",
	]);
	$changeSet->add([
			'/sbin/tc','class','del',
				'dev',$rxInterface->{'Device'},
				'parent',"1:$rxTrafficClassTcClass",
				'classid',"1:$rxPoolTcClass",
	]);

	# And recycle the classs
	_disposePoolTcClass($txInterface->{'Device'},$txPoolTcClass);
	_disposePoolTcClass($rxInterface->{'Device'},$rxPoolTcClass);

	_disposePrioTcClass($txInterface->{'Device'},$txPoolTcClass);
	_disposePrioTcClass($rxInterface->{'Device'},$rxPoolTcClass);

	# Post changeset
	$kernel->post("_tc" => "queue" => $changeSet);

	# Cleanup attributes
	removePoolAttribute($pool->{'ID'},'tc.txclass');
	removePoolAttribute($pool->{'ID'},'tc.rxclass');

	removePoolAttribute($pool->{'ID'},'shaper.live.ClassID');
	removePoolAttribute($pool->{'ID'},'shaper.live.TxCIR');
	removePoolAttribute($pool->{'ID'},'shaper.live.TxLimit');
	removePoolAttribute($pool->{'ID'},'shaper.live.RxCIR');
	removePoolAttribute($pool->{'ID'},'shaper.live.RxLimit');

	# Mark as not live
	unsetPoolShaperState($pool->{'ID'},SHAPER_LIVE|SHAPER_PENDING);
	setPoolShaperState($pool->{'ID'},SHAPER_NOTLIVE);
}



## Event handler for changing a pool
sub _session_pool_change
{
	my ($kernel, $pid) = @_[KERNEL, ARG0];


	# Grab pool
	my $pool = getPool($pid);

	$logger->log(LOG_INFO,"[TC] Processing changes for '%s' [%s]",$pool->{'Name'},$pool->{'ID'});

	# Grab our effective pool
	my $effectivePool = getEffectivePool($pool->{'ID'});

	# Grab our interfaces
	my $txInterfaceID = getPoolTxInterface($pool->{'ID'});
	my $rxInterfaceID = getPoolRxInterface($pool->{'ID'});
	# Grab the traffic class from the pool
	my $txPoolTcClass = getPoolAttribute($pool->{'ID'},'tc.txclass');
	my $rxPoolTcClass = getPoolAttribute($pool->{'ID'},'tc.rxclass');

	# Grab effective config
	my $trafficClassID = $effectivePool->{'TrafficClassID'};
	my $txCIR = $effectivePool->{'TxCIR'};
	my $txLimit = $effectivePool->{'TxLimit'};
	my $rxCIR = $effectivePool->{'RxCIR'};
	my $rxLimit = $effectivePool->{'RxLimit'};
	my $trafficPriority = getTrafficClassPriority($trafficClassID);

	# Grab our minor classes
	my $txTrafficClassTcClass = _getTcClassFromTrafficClassID($txInterfaceID,$trafficClassID);
	my $rxTrafficClassTcClass = _getTcClassFromTrafficClassID($rxInterfaceID,$trafficClassID);

	# Generate changeset
	my $changeSet = TC::ChangeSet->new();

	_tc_class_change($changeSet,$txInterfaceID,TC_ROOT_CLASS,$txTrafficClassTcClass,$txPoolTcClass,$txCIR,
			$txLimit,$trafficPriority);
	_tc_class_change($changeSet,$rxInterfaceID,TC_ROOT_CLASS,$rxTrafficClassTcClass,$rxPoolTcClass,$rxCIR,
			$rxLimit,$trafficPriority);

	# Post changeset
	$kernel->post("_tc" => "queue" => $changeSet);

	setPoolAttribute($pool->{'ID'},'shaper.live.ClassID',$trafficClassID);
	setPoolAttribute($pool->{'ID'},'shaper.live.TxCIR',$txCIR);
	setPoolAttribute($pool->{'ID'},'shaper.live.TxLimit',$txLimit);
	setPoolAttribute($pool->{'ID'},'shaper.live.RxCIR',$rxCIR);
	setPoolAttribute($pool->{'ID'},'shaper.live.RxLimit',$rxLimit);

	# Mark as live
	unsetPoolShaperState($pool->{'ID'},SHAPER_NOTLIVE|SHAPER_PENDING);
	setPoolShaperState($pool->{'ID'},SHAPER_LIVE);
}



# Event handler for adding a pool member
sub _session_poolmember_add
{
	my ($kernel,$heap,$pmid) = @_[KERNEL, HEAP, ARG0];


	# Grab pool
	my $poolMember;
	if (!defined($poolMember = getPoolMember($pmid))) {
		$logger->log(LOG_ERR,"[TC] Shaper 'add' event with non existing pool member '%s'",$pmid);
		return;
	}

	$logger->log(LOG_INFO,"[TC] Add pool member '%s' to pool '%s' [%s]",
			$poolMember->{'IPAddress'},
			$poolMember->{'PoolID'},
			$poolMember->{'ID'}
	);

	my $changeSet = TC::ChangeSet->new();

	# Filter levels for the IP components
	my @components = split(/\./,$poolMember->{'IPAddress'});
	my $ip1 = $components[0];
	my $ip2 = $components[1];
	my $ip3 = $components[2];
	my $ip4 = $components[3];

	my $pool;
	if (!defined($pool = getPool($poolMember->{'PoolID'}))) {
		$logger->log(LOG_ERR,"[TC] Shaper 'poolmember_add' event with invalid PoolID");
		return;
	}

	# Grab some variables we going to need below
	my $txInterfaceID = getPoolTxInterface($pool->{'ID'});
	my $rxInterfaceID = getPoolRxInterface($pool->{'ID'});
	my $trafficPriority = getTrafficClassPriority($pool->{'TrafficClassID'});
	my $matchPriority = getPoolMemberMatchPriority($poolMember->{'ID'});

	# Check if we have a entry for the /8, if not we must create our 2nd level hash table and link it
	if (!defined($globals->{'TcFilterMappings'}->{$txInterfaceID}->{'dst'}->{$matchPriority}->{$ip1})) {
		# Grab filter ID's for 2nd level
		my $filterID = _reserveTcFilter($txInterfaceID,$matchPriority,$pool->{'ID'});
		# Track our mapping
		$globals->{'TcFilterMappings'}->{$txInterfaceID}->{'dst'}->{$matchPriority}->{$ip1}->{'id'} = $filterID;
		$logger->log(LOG_DEBUG,"[TC] Linking 2nd level TX hash table to '%s' to '%s.0.0.0/8', priority '%s'",
				$filterID,
				$ip1,
				$matchPriority
		);
		_tc_filter_add_dstlink($changeSet,$txInterfaceID,TC_ROOT_CLASS,$matchPriority,$filterID,$config->{'ip_protocol'},800,"",
				"$ip1.0.0.0/8","00ff0000");
	}
	if (!defined($globals->{'TcFilterMappings'}->{$rxInterfaceID}->{'src'}->{$matchPriority}->{$ip1})) {
		# Grab filter ID's for 2nd level
		my $filterID = _reserveTcFilter($rxInterfaceID,$matchPriority,$pool->{'ID'});
		# Track our mapping
		$globals->{'TcFilterMappings'}->{$rxInterfaceID}->{'src'}->{$matchPriority}->{$ip1}->{'id'} = $filterID;
		$logger->log(LOG_DEBUG,"[TC] Linking 2nd level RX hash table to '%s' to '%s.0.0.0/8', priority '%s'",
				$filterID,
				$ip1,
				$matchPriority
		);
		_tc_filter_add_srclink($changeSet,$rxInterfaceID,TC_ROOT_CLASS,$matchPriority,$filterID,$config->{'ip_protocol'},800,"",
				"$ip1.0.0.0/8","00ff0000");
	}

	# Check if we have our /16 hash entry, if not we must create the 3rd level hash table
	if (!defined($globals->{'TcFilterMappings'}->{$txInterfaceID}->{'dst'}->{$matchPriority}->{$ip1}->{$ip2})) {
		# Grab filter ID's for 3rd level
		my $filterID = _reserveTcFilter($txInterfaceID,$matchPriority,$pool->{'ID'});
		# Track our mapping
		$globals->{'TcFilterMappings'}->{$txInterfaceID}->{'dst'}->{$matchPriority}->{$ip1}->{$ip2}->{'id'} = $filterID;
		# Grab some hash table ID's we need
		my $ip1HtHex = $globals->{'TcFilterMappings'}->{$txInterfaceID}->{'dst'}->{$matchPriority}->{$ip1}->{'id'};
		# And hex our IP component
		my $ip2Hex = toHex($ip2);
		$logger->log(LOG_DEBUG,"[TC] Linking 3rd level TX hash table to '%s' to '%s.%s.0.0/16', priority '%s'",
				$filterID,
				$ip1,
				$ip2,
				$matchPriority
		);
		_tc_filter_add_dstlink($changeSet,$txInterfaceID,TC_ROOT_CLASS,$matchPriority,$filterID,$config->{'ip_protocol'},$ip1HtHex,
				$ip2Hex,"$ip1.$ip2.0.0/16","0000ff00");
	}
	if (!defined($globals->{'TcFilterMappings'}->{$rxInterfaceID}->{'src'}->{$matchPriority}->{$ip1}->{$ip2})) {
		# Grab filter ID's for 3rd level
		my $filterID = _reserveTcFilter($rxInterfaceID,$matchPriority,$pool->{'ID'});
		# Track our mapping
		$globals->{'TcFilterMappings'}->{$rxInterfaceID}->{'src'}->{$matchPriority}->{$ip1}->{$ip2}->{'id'} = $filterID;
		# Grab some hash table ID's we need
		my $ip1HtHex = $globals->{'TcFilterMappings'}->{$rxInterfaceID}->{'src'}->{$matchPriority}->{$ip1}->{'id'};
		# And hex our IP component
		my $ip2Hex = toHex($ip2);
		$logger->log(LOG_DEBUG,"[TC] Linking 3rd level RX hash table to '%s' to '%s.%s.0.0/16', priority '%s'",
				$filterID,
				$ip1,
				$ip2,
				$matchPriority
		);
		_tc_filter_add_srclink($changeSet,$rxInterfaceID,TC_ROOT_CLASS,$matchPriority,$filterID,$config->{'ip_protocol'},$ip1HtHex,
				$ip2Hex,"$ip1.$ip2.0.0/16","0000ff00");
	}

	# Check if we have our /24 hash entry, if not we must create the 4th level hash table
	if (!defined($globals->{'TcFilterMappings'}->{$txInterfaceID}->{'dst'}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3})) {
		# Grab filter ID's for 4th level
		my $filterID = _reserveTcFilter($txInterfaceID,$matchPriority,$pool->{'ID'});
		# Track our mapping
		$globals->{'TcFilterMappings'}->{$txInterfaceID}->{'dst'}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3}->{'id'} = $filterID;
		# Grab some hash table ID's we need
		my $ip2HtHex = $globals->{'TcFilterMappings'}->{$txInterfaceID}->{'dst'}->{$matchPriority}->{$ip1}->{$ip2}->{'id'};
		# And hex our IP component
		my $ip3Hex = toHex($ip3);
		$logger->log(LOG_DEBUG,"[TC] Linking 4th level TX hash table to '%s' to '%s.%s.%s.0/24', priority '%s'",
				$filterID,
				$ip1,
				$ip2,
				$ip3,
				$matchPriority
		);
		_tc_filter_add_dstlink($changeSet,$txInterfaceID,TC_ROOT_CLASS,$matchPriority,$filterID,$config->{'ip_protocol'},$ip2HtHex,
				$ip3Hex,"$ip1.$ip2.$ip3.0/24","000000ff");
	}
	if (!defined($globals->{'TcFilterMappings'}->{$rxInterfaceID}->{'src'}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3})) {
		# Grab filter ID's for 4th level
		my $filterID = _reserveTcFilter($rxInterfaceID,$matchPriority,$pool->{'ID'});
		# Track our mapping
		$globals->{'TcFilterMappings'}->{$rxInterfaceID}->{'src'}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3}->{'id'} = $filterID;
		# Grab some hash table ID's we need
		my $ip2HtHex = $globals->{'TcFilterMappings'}->{$rxInterfaceID}->{'src'}->{$matchPriority}->{$ip1}->{$ip2}->{'id'};
		# And hex our IP component
		my $ip3Hex = toHex($ip3);
		$logger->log(LOG_DEBUG,"[TC] Linking 4th level RX hash table to '%s' to '%s.%s.%s.0/24', priority '%s'",
				$filterID,
				$ip1,
				$ip2,
				$ip3,
				$matchPriority
		);
		_tc_filter_add_srclink($changeSet,$rxInterfaceID,TC_ROOT_CLASS,$matchPriority,$filterID,$config->{'ip_protocol'},$ip2HtHex,
				$ip3Hex,"$ip1.$ip2.$ip3.0/24","000000ff");
	}

	#
	# For sake of simplicity and so things loook all nice and similar, we going to do these 2 blocks in { }
	#

	# Only if we have TX limits setup process them
	{
		# Get the TX class
		my $tcClass_trafficClass = getPoolAttribute($pool->{'ID'},'tc.txclass');
		# Grab some hash table ID's we need
		my $ip3HtHex = $globals->{'TcFilterMappings'}->{$txInterfaceID}->{'dst'}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3}->{'id'};
		# And hex our IP component
		my $ip4Hex = toHex($ip4);
		$logger->log(LOG_DEBUG,"[TC] Linking pool member IP '%s' to class '%s' at hash endpoint '%s:%s'",
				$poolMember->{'IPAddress'},
				$tcClass_trafficClass,
				$ip3HtHex,
				$ip4Hex
		);

		# Link filter to traffic flow (class)
		_tc_filter_add_flowlink($changeSet,$txInterfaceID,TC_ROOT_CLASS,$trafficPriority,$config->{'ip_protocol'},$ip3HtHex,
				$ip4Hex,"dst",16,$poolMember->{'IPAddress'},$tcClass_trafficClass);

		# Save pool member filter ID
		setPoolMemberAttribute($poolMember->{'ID'},'tc.txfilter',"${ip3HtHex}:${ip4Hex}:1");
	}
	# Only if we have RX limits setup process them
	{
		# Generate our limit TC class
		my $tcClass_trafficClass = getPoolAttribute($pool->{'ID'},'tc.rxclass');
		# Grab some hash table ID's we need
		my $ip3HtHex = $globals->{'TcFilterMappings'}->{$rxInterfaceID}->{'src'}->{$matchPriority}->{$ip1}->{$ip2}->{$ip3}->{'id'};
		# And hex our IP component
		my $ip4Hex = toHex($ip4);
		$logger->log(LOG_DEBUG,"[TC] Linking RX IP '%s' to class '%s' at hash endpoint '%s:%s'",
				$poolMember->{'IPAddress'},
				$tcClass_trafficClass,
				$ip3HtHex,
				$ip4Hex
		);

		# Link filter to traffic flow (class)
		_tc_filter_add_flowlink($changeSet,$rxInterfaceID,TC_ROOT_CLASS,$trafficPriority,$config->{'ip_protocol'},$ip3HtHex,
				$ip4Hex,"src",12,$poolMember->{'IPAddress'},$tcClass_trafficClass);

		# Save pool member filter ID
		setPoolMemberAttribute($poolMember->{'ID'},'tc.rxfilter',"${ip3HtHex}:${ip4Hex}:1");
	}

	# Post changeset
	$kernel->post("_tc" => "queue" => $changeSet);

	# Mark pool member as live
	unsetPoolMemberShaperState($poolMember->{'ID'},SHAPER_NOTLIVE|SHAPER_PENDING);
	setPoolMemberShaperState($poolMember->{'ID'},SHAPER_LIVE);
}



# Event handler for removing a pool member
sub _session_poolmember_remove
{
	my ($kernel, $pmid) = @_[KERNEL, ARG0];


	# Pull in pool member
	my $poolMember;
	if (!defined($poolMember = getPoolMember($pmid))) {
		$logger->log(LOG_ERR,"[TC] Shaper 'remove' event with non existing pool member '%s'",$pmid);
		return;
	}

	# Grab the pool members associated pool
	my $pool = getPool($poolMember->{'PoolID'});

	# Make sure its not NOTLIVE
	if (getPoolMemberShaperState($pmid) & SHAPER_NOTLIVE) {
		$logger->log(LOG_WARN,"[TC] Ignoring remove for pool member '%s' with IP '%s' [%s] from pool '%s'",
				$poolMember->{'Username'},
				$poolMember->{'IPAddress'},
				$poolMember->{'ID'},
				$pool->{'Name'}
		);
		return;
	}

	$logger->log(LOG_INFO,"[TC] Removing pool member '%s' with IP '%s' [%s] from pool '%s'",
			$poolMember->{'Username'},
			$poolMember->{'IPAddress'},
			$poolMember->{'ID'},
			$pool->{'Name'}
	);

	# Grab our interfaces
	my $txInterfaceID = getPoolTxInterface($pool->{'ID'});
	my $rxInterfaceID = getPoolRxInterface($pool->{'ID'});
	# Grab the filter ID's from the pool member which is linked to the traffic class
	my $txFilter = getPoolMemberAttribute($poolMember->{'ID'},'tc.txfilter');
	my $rxFilter = getPoolMemberAttribute($poolMember->{'ID'},'tc.rxfilter');

	# Grab current class ID
	my $trafficClassID = getPoolAttribute($pool->{'ID'},'shaper.live.ClassID');
	my $trafficPriority = getTrafficClassPriority($trafficClassID);

	my $txInterface = getInterface($txInterfaceID);
	my $rxInterface = getInterface($rxInterfaceID);

	my $changeSet = TC::ChangeSet->new();

	# Clear up the filter
	$changeSet->add([
			'/sbin/tc','filter','del',
				'dev',$txInterface->{'Device'},
				'parent','1:',
				'prio',$trafficPriority,
				'handle',$txFilter,
				'protocol',$config->{'ip_protocol'},
				'u32',
	]);
	$changeSet->add([
			'/sbin/tc','filter','del',
				'dev',$rxInterface->{'Device'},
				'parent','1:',
				'prio',$trafficPriority,
				'handle',$rxFilter,
				'protocol',$config->{'ip_protocol'},
				'u32',
	]);

	# Post changeset
	$kernel->post("_tc" => "queue" => $changeSet);

	# Cleanup attributes
	removePoolMemberAttribute($poolMember->{'ID'},'tc.txfilter');
	removePoolMemberAttribute($poolMember->{'ID'},'tc.rxfilter');

	# Mark as not live
	unsetPoolMemberShaperState($poolMember->{'ID'},SHAPER_LIVE|SHAPER_PENDING);
	setPoolMemberShaperState($poolMember->{'ID'},SHAPER_NOTLIVE);
}



# Grab pool ID from TC class
sub getPIDFromTcClass
{
	my ($interfaceID,$majorTcClass,$minorTcClass) = @_;


	# Return the pool ID if found
	my $ref = __getRefByMinorTcClass($interfaceID,$majorTcClass,$minorTcClass);
	if (!defined($ref) || substr($ref,0,13) ne "_pool_class_:") {
		return;
	}

	return substr($ref,13);
}



# Function to return if this is linked to a pool's class
sub isPoolTcClass
{
	my ($interfaceID,$majorTcClass,$minorTcClass) = @_;


	my $pid = getPIDFromTcClass($interfaceID,$majorTcClass,$minorTcClass);
	if (!defined($pid)) {
		return;
	}

	return $minorTcClass;
}



# Return the ClassID from a TC class
# This is similar to isTcTrafficClassValid() but returns the ref, not the minor class
sub getCIDFromTcClass
{
	my ($interfaceID,$majorTcClass,$minorTcClass) = @_;


	# Grab ref
	my $ref = __getRefByMinorTcClass($interfaceID,$majorTcClass,$minorTcClass);
	# If we're not a traffic class, just return
	if (substr($ref,0,16) ne "_traffic_class_:") {
		return;
	}

	# Else return the part after the above tag
	return substr($ref,16);
}


#
# Internal functions
#


# Function to initialize an interface
sub _tc_iface_init
{
	my ($changeSet,$interfaceID) = @_;


	# Grab our interface rate
	my $interface = getInterface($interfaceID);

### --- Interface Setup

	# Clear the qdisc from the interface
	$changeSet->add([
			'/sbin/tc','qdisc','del',
				'dev',$interface->{'Device'},
				'root',
	]);

	# Initialize the major TC class
	my $interfaceTcClass = _reserveMajorTcClass($interfaceID,"root");

	# Set interface RootClass
	$globals->{'Interfaces'}->{$interfaceID} = {
		'TcClass' => $interfaceTcClass
	};

### --- Interface Traffic Class Setup

	# Reserve our parent TC classes
	my @trafficClasses = getAllTrafficClasses();
	foreach my $trafficClassID (sort {$a <=> $b} @trafficClasses) {
		# Record the class we get for this interface traffic class ID
		my $interfaceTrafficClassTcClass = _reserveMinorTcClassByTrafficClassID($interfaceID,$trafficClassID);
	}

	# Do we have a default pool? if so we must direct traffic there
	my @qdiscOpts = ( );
	my $defaultPool = getInterfaceDefaultPool($interfaceID);
	my $defaultPoolTcClass;
	if (defined($defaultPool)) {
		# Push unclassified traffic to this class
		$defaultPoolTcClass = _getTcClassFromTrafficClassID($interfaceID,$defaultPool);
		push(@qdiscOpts,'default',$defaultPoolTcClass);
	}


### --- Interface Setup Part 2

	# Add root qdisc
	$changeSet->add([
			'/sbin/tc','qdisc','add',
				'dev',$interface->{'Device'},
				'root',
				'handle','1:',
				'htb',
					@qdiscOpts
	]);

	# Attach our main limit on the qdisc
	my $burst = int(($interface->{'Limit'}/8) * 0.10); # 10% burst
	$changeSet->add([
			'/sbin/tc','class','add',
				'dev',$interface->{'Device'},
				'parent','1:',
				'classid','1:1',
				'htb',
					'rate',"$interface->{'Limit'}kbit",
					'burst',"${burst}kb",
	]);

	# Class 0 is our interface, it points to 1 (the major TcClass)) : 1 (class below)
	$globals->{'Interfaces'}->{$interfaceID}->{'TrafficClasses'}->{'0'} = {
		'TcClass' => '1',
		'CIR' => $interface->{'Limit'},
		'Limit' => $interface->{'Limit'}
	};


### --- Setup each class

	# Setup the classes
	foreach my $trafficClassID (@trafficClasses) {
		my $interfaceTrafficClassID = isInterfaceTrafficClassValid($interfaceID,$trafficClassID);
		my $interfaceTrafficClass = getEffectiveInterfaceTrafficClass2($interfaceTrafficClassID);
		my $tcClass = _getTcClassFromTrafficClassID($interfaceID,$trafficClassID);
		my $trafficPriority = getTrafficClassPriority($trafficClassID);

		$burst = int(($interfaceTrafficClass->{'Limit'}/8) * 0.10); # 10% burst

		# Add class
		$changeSet->add([
				'/sbin/tc','class','add',
					'dev',$interface->{'Device'},
					'parent','1:1',
					'classid',"1:$tcClass",
					'htb',
						'rate',"$interfaceTrafficClass->{'CIR'}kbit",
						'ceil',"$interfaceTrafficClass->{'Limit'}kbit",
						'prio',$trafficPriority,
						'burst', "${burst}kb",
		]);

		# Setup interface traffic class details
		$globals->{'Interfaces'}->{$interfaceID}->{'TrafficClasses'}->{$trafficClassID} = {
			'TcClass' => $tcClass,
			'CIR' => $interfaceTrafficClass->{'CIR'},
			'Limit' => $interfaceTrafficClass->{'Limit'}
		};
	}

	# Process our default pool traffic optimizations
	if (defined($defaultPool)) {
		my $interfaceTrafficClassID = isInterfaceTrafficClassValid($interfaceID,$defaultPool);
		my $interfaceTrafficClass = getEffectiveInterfaceTrafficClass2($interfaceTrafficClassID);


		# If we have a rate for this iface, then use it
		_tc_class_optimize($changeSet,$interfaceID,$defaultPoolTcClass,$interfaceTrafficClass->{'Limit'});

		# Make the queue size big enough
		my $queueSize = int((($interface->{'Limit'} * 1000) / 8) * 5); # Should give a 5s queue time, eg. (100kbps * 1000 / 8) * 5

		# RED metrics (sort of as per manpage)
		my $redAvPkt = 1000;
		my $redMax = int($queueSize * 0.75); # 75% mark at 100% probabilty
		my $redMin = int($queueSize * 0.10); # 10% mark start RED
#		my $redBurst = int( ($redMin+$redMax) / (2*$redAvPkt));
		my $redBurst = int($queueSize * 0.10); # 10% burst
		my $redLimit = $queueSize;

		my $prioTcClass = _getPrioTcClass($interfaceID,$defaultPoolTcClass);

		# Priority band
		my $prioBand = 1;
		$changeSet->add([
				'/sbin/tc','qdisc','add',
					'dev',$interface->{'Device'},
					'parent',"$prioTcClass:".toHex($prioBand),
					'handle',_reserveMajorTcClass($interfaceID,"_default_pool_:$defaultPoolTcClass=>$prioBand").":",
					'bfifo',
						'limit',$queueSize,
		]);

		$prioBand++;
		$changeSet->add([
				'/sbin/tc','qdisc','add',
					'dev',$interface->{'Device'},
					'parent',"$prioTcClass:".toHex($prioBand),
					'handle',_reserveMajorTcClass($interfaceID,"_default_pool_:$defaultPoolTcClass=>$prioBand").":",
# TODO: NK - try enable the below
#					'estimator','1sec','4sec', # Quick monitoring, every 1s with 4s constraint
					'red',
						'min',$redMin,
						'max',$redMax,
						'limit',$redLimit,
						'burst',$redBurst,
						'avpkt',$redAvPkt,
# NK: ECN may cause excessive dips in traffic if there is an exceptional amount of traffic
#						'ecn'
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
					'dev',$interface->{'Device'},
					'parent',"$prioTcClass:".toHex($prioBand),
					'handle',_reserveMajorTcClass($interfaceID,"_default_pool_:$defaultPoolTcClass=>$prioBand").":",
					'red',
						'min',$redMin,
						'max',$redMax,
						'limit',$redLimit,
						'burst',$redBurst,
						'avpkt',$redAvPkt,
# NK: ECN may cause excessive dips in traffic if there is an exceptional amount of traffic
#						'ecn'
		]);
	}
}



# Function to apply traffic optimizations to a classes
# XXX: This probably needs working on
sub _tc_class_optimize
{
	my ($changeSet,$interfaceID,$poolTcClass,$rate) = @_;


	my $interface = getInterface($interfaceID);

	# Rate for things like ICMP , ACK, SYN ... etc
	my $rateBand1 = int($rate * (PROTO_RATE_LIMIT / 100));
	$rateBand1 = PROTO_RATE_BURST_MIN if ($rateBand1 < PROTO_RATE_BURST_MIN);
	my $rateBand1Burst = ($rateBand1 / 8) * PROTO_RATE_BURST_MAXM;
	# Rate for things like VoIP/SSH/Telnet
	my $rateBand2 = int($rate * (PRIO_RATE_LIMIT / 100));
	$rateBand2 = PRIO_RATE_BURST_MIN if ($rateBand2 < PRIO_RATE_BURST_MIN);
	my $rateBand2Burst = ($rateBand2 / 8) * PRIO_RATE_BURST_MAXM;

	my $prioTcClass = _reserveMajorTcClassByPrioClass($interfaceID,$poolTcClass);

	#
	# DEFINE 3 PRIO BANDS
	#

	# We then prioritize traffic into 3 bands based on TOS
	$changeSet->add([
			'/sbin/tc','qdisc','add',
				'dev',$interface->{'Device'},
				'parent',"1:$poolTcClass",
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
				'dev',$interface->{'Device'},
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
	my ($changeSet,$interfaceID,$parentID,$priority,$filterID,$protocol,$htHex,$ipHex,$cidr,$mask) = @_;


	# Add hash table
	_tc_filter_hash_add($changeSet,$interfaceID,$parentID,$priority,$filterID,$config->{'ip_protocol'});
	# Add filter to it
	_tc_filter_add($changeSet,$interfaceID,$parentID,$priority,$filterID,$protocol,$htHex,$ipHex,"dst",16,$cidr,$mask);
}



# Function to easily add a hash table
sub _tc_filter_add_srclink
{
	my ($changeSet,$interfaceID,$parentID,$priority,$filterID,$protocol,$htHex,$ipHex,$cidr,$mask) = @_;


	# Add hash table
	_tc_filter_hash_add($changeSet,$interfaceID,$parentID,$priority,$filterID,$config->{'ip_protocol'});
	# Add filter to it
	_tc_filter_add($changeSet,$interfaceID,$parentID,$priority,$filterID,$protocol,$htHex,$ipHex,"src",12,$cidr,$mask);
}



# Function to easily add a hash table
sub _tc_filter_add_flowlink
{
	my ($changeSet,$interfaceID,$parentID,$priority,$protocol,$htHex,$ipHex,$type,$offset,$ip,$poolTcClass) = @_;


	my $interface = getInterface($interfaceID);

	# Link hash table
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface->{'Device'},
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
					'flowid',"1:$poolTcClass",
	]);
}



# Function to easily add a hash table
sub _tc_filter_hash_add
{
	my ($changeSet,$interfaceID,$parentID,$priority,$filterID,$protocol) = @_;


	my $interface = getInterface($interfaceID);

	# Create second level hash table for $ip1
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface->{'Device'},
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
	my ($changeSet,$interfaceID,$parentID,$priority,$filterID,$protocol,$htHex,$ipHex,$type,$offset,$cidr,$mask) = @_;


	my $interface = getInterface($interfaceID);

	# Link hash table
	$changeSet->add([
			'/sbin/tc','filter','add',
				'dev',$interface->{'Device'},
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
	my ($changeSet,$interfaceID,$majorTcClass,$trafficClassTcClass,$poolTcClass,$rate,$ceil,$trafficPriority) = @_;


	my $interface = getInterface($interfaceID);

	# Set burst to a sane value
	my $burst = int(($ceil / 8) * 0.10); # 10% burst

	# Create main rate limiting classes
	$changeSet->add([
			'/sbin/tc','class','add',
				'dev',$interface->{'Device'},
				'parent',"$majorTcClass:$trafficClassTcClass",
				'classid',"$majorTcClass:$poolTcClass",
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
	my ($changeSet,$interfaceID,$majorTcClass,$trafficClassTcClass,$poolTcClass,$rate,$ceil,$trafficPriority) = @_;


	my $interface = getInterface($interfaceID);

	my @args = ();

	# Based on if ceil is avaiable, set burst
	my $burst;
	if (defined($ceil)) {
		$burst = int(($ceil / 8) * 0.10);
	} else {
		# If ceil is not available, set burst and ceil
		$burst = $ceil = $rate;
	}

	# Check if we have a priority
	if (defined($trafficPriority)) {
		push(@args,'prio',$trafficPriority);
	}

	# Create main rate limiting classes
	$changeSet->add([
			'/sbin/tc','class','change',
				'dev',$interface->{'Device'},
				'parent',"$majorTcClass:$trafficClassTcClass",
				'classid',"$majorTcClass:$poolTcClass",
				'htb',
					'rate', "${rate}kbit",
					'ceil', "${ceil}kbit",
					'burst', "${burst}kb",
					@args
	]);
}



# Get a pool TC class from pool ID
sub _reserveMinorTcClassByPoolID
{
	my ($interfaceID,$pid) = @_;

	return __reserveMinorTcClass($interfaceID,TC_ROOT_CLASS,"_pool_class_:$pid");
}



# Get a traffic class TC class
sub _reserveMinorTcClassByTrafficClassID
{
	my ($interfaceID,$trafficClassID) = @_;

	return __reserveMinorTcClass($interfaceID,TC_ROOT_CLASS,"_traffic_class_:$trafficClassID");
}



# Get a prio class TC class
# This is a MAJOR class!
sub _reserveMajorTcClassByPrioClass
{
	my ($interfaceID,$trafficClassID) = @_;


	return _reserveMajorTcClass($interfaceID,"_priority_class_:$trafficClassID");
}



# Return TC class from a traffic class ID
sub _getTcClassFromTrafficClassID
{
	my ($interfaceID,$trafficClassID) = @_;


	return __getMinorTcClassByRef($interfaceID,TC_ROOT_CLASS,"_traffic_class_:$trafficClassID");
}



# Return prio TC class using class
# This returns a MAJOR class from a tc class
sub _getPrioTcClass
{
	my ($interfaceID,$tcClass) = @_;

	return __getMajorTcClassByRef($interfaceID,"_priority_class_:$tcClass");
}



# Function to dispose of a TC class
sub _disposePoolTcClass
{
	my ($interfaceID,$tcClass) = @_;

	return __disposeMinorTcClass($interfaceID,TC_ROOT_CLASS,$tcClass);
}



# Function to dispose of a major TC class
# Uses a TC class to get a MAJOR class, then disposes it
sub _disposePrioTcClass
{
	my ($interfaceID,$tcClass) = @_;


	# If we can grab the major class dipose of it
	my $majorTcClass = _getPrioTcClass($interfaceID,$tcClass);
	if (!defined($majorTcClass)) {
		return;
	}

	return __disposeMajorTcClass($interfaceID,$majorTcClass);
}



# Function to get next available TC class
sub __reserveMinorTcClass
{
	my ($interfaceID,$majorTcClass,$ref) = @_;


	# Setup defaults if we don't have anything defined
	if (!defined($globals->{'TcClasses'}->{$interfaceID}) || !defined($globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass})) {
		$globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass} = {
			# Skip 0 and 1
			'Counter' => 2,
			'Free' => [ ],
			'Track' => { },
			'Reverse' => { },
		};
	}

	# Maybe we have one free?
	my $minorTcClass = shift(@{$globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass}->{'Free'}});

	# Generate new number
	if (!$minorTcClass) {
		$minorTcClass = $globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass}->{'Counter'}++;
		# Hex it
		$minorTcClass = toHex($minorTcClass);
	}

	$globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass}->{'Track'}->{$minorTcClass} = $ref;
	$globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass}->{'Reverse'}->{$ref} = $minorTcClass;

	return $minorTcClass;
}



# Function to get next available major TC class
sub _reserveMajorTcClass
{
	my ($interfaceID,$ref) = @_;


	# Setup defaults if we don't have anything defined
	if (!defined($globals->{'TcClasses'}->{$interfaceID})) {
		$globals->{'TcClasses'}->{$interfaceID} = {
			# Skip 0
			'Counter' => 1,
			'Free' => [ ],
			'Track' => { },
			'Reverse' => { },
		};
	}

	# Maybe we have one free?
	my $majorTcClass = shift(@{$globals->{'TcClasses'}->{$interfaceID}->{'Free'}});

	# Generate new number
	if (!$majorTcClass) {
		$majorTcClass = $globals->{'TcClasses'}->{$interfaceID}->{'Counter'}++;
		# Hex it
		$majorTcClass = toHex($majorTcClass);
	}

	$globals->{'TcClasses'}->{$interfaceID}->{'Track'}->{$majorTcClass} = $ref;
	$globals->{'TcClasses'}->{$interfaceID}->{'Reverse'}->{$ref} = $majorTcClass;

	return $majorTcClass;
}



# Get a minor class by its rerf
sub __getMinorTcClassByRef
{
	my ($interfaceID,$majorTcClass,$ref) = @_;


	if (!defined($globals->{'TcClasses'}->{$interfaceID}) || !defined($globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass})) {
		return;
	}

	return $globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass}->{'Reverse'}->{$ref};
}



# Get a major class by its rerf
sub __getMajorTcClassByRef
{
	my ($interfaceID,$ref) = @_;


	if (!defined($globals->{'TcClasses'}->{$interfaceID})) {
		return;
	}

	return $globals->{'TcClasses'}->{$interfaceID}->{'Reverse'}->{$ref};
}



# Get ref using the minor tc class
sub __getRefByMinorTcClass
{
	my ($interfaceID,$majorTcClass,$minorTcClass) = @_;


	if (!defined($globals->{'TcClasses'}->{$interfaceID}) || !defined($globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass})) {
		return;
	}

	return $globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass}->{'Track'}->{$minorTcClass};
}



# Function to dispose of a TC class
sub __disposeMinorTcClass
{
	my ($interfaceID,$majorTcClass,$tcMinorClass) = @_;


	my $ref = $globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass}->{'Track'}->{$tcMinorClass};
	# Push onto free list
	push(@{$globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass}->{'Free'}},$tcMinorClass);
	# Blank the value
	$globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass}->{'Track'}->{$tcMinorClass} = undef;
	delete($globals->{'TcClasses'}->{$interfaceID}->{$majorTcClass}->{'Reverse'}->{$ref});
}



# Function to dispose of a major TC class
sub __disposeMajorTcClass
{
	my ($interfaceID,$tcMajorClass) = @_;


	my $ref = $globals->{'TcClasses'}->{$interfaceID}->{'Track'}->{$tcMajorClass};
	# Push onto free list
	push(@{$globals->{'TcClasses'}->{$interfaceID}->{'Free'}},$tcMajorClass);
	# Blank the value
	$globals->{'TcClasses'}->{$interfaceID}->{'Track'}->{$tcMajorClass} = undef;
	delete($globals->{'TcClasses'}->{$interfaceID}->{'Reverse'}->{$ref});
}



# Function to get next available TC filter
sub _reserveTcFilter
{
	my ($interfaceID,$ref) = @_;


	# Setup defaults if we don't have anything defined
	if (!defined($globals->{'TcFilters'}->{$interfaceID})) {
		$globals->{'TcFilters'}->{$interfaceID} = {
			# Skip 0 and 1
			'Counter' => 2,
			'Free' => [ ],
			'Track' => { },
		};
	}

	# Maybe we have one free?
	my $filterID = shift(@{$globals->{'TcFilters'}->{$interfaceID}->{'Free'}});

	# Generate new number
	if (!$filterID) {
		$filterID = $globals->{'TcFilters'}->{$interfaceID}->{'Counter'}++;
		# We cannot use ID 800, its internal
		$filterID = $globals->{'TcFilters'}->{$interfaceID}->{'Counter'}++ if ($filterID == 800);
		# Hex it
		$filterID = toHex($filterID);
	}

	$globals->{'TcFilters'}->{$interfaceID}->{'Track'}->{$filterID} = $ref;

	return $filterID;
}



# Function to dispose of a TC Filter
sub _disposeTcFilter
{
	my ($interfaceID,$filterID) = @_;

	# Push onto free list
	push(@{$globals->{'TcFilters'}->{$interfaceID}->{'Free'}},$filterID);
	# Blank the value
	$globals->{'TcFilters'}->{$interfaceID}->{'Track'}->{$filterID} = undef;
}



#
# Task/child communication & handling stuff
#



# Initialize our tc session
sub _task_session_start
{
	my $kernel = $_[KERNEL];

	# Set our alias
	$kernel->alias_set("_tc");

	# Setup handing of console INT
	$kernel->sig("INT", "_SIGINT");

	# Fire things up, we trigger this to process the task queue generated during init
	$kernel->yield("_task_run_next");
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
		push(@{$globals->{'TaskQueue'}},$cmdStr);
		$numChanges++;
	}

	$logger->log(LOG_DEBUG,"[TC] TASK: Queued %s changes",$numChanges);
}



# Send the next command in the task direction
sub _task_put_next
{
	my ($heap,$task) = @_;


	# Task was busy, this signifies its done, so lets take the next command
	if (my $cmdStr = shift(@{$globals->{'TaskQueue'}})) {
		# Remove off idle task list if its there
		delete($heap->{'idle_tasks'}->{$task->ID});

		$task->put($cmdStr);
		$logger->log(LOG_DEBUG,"[TC] TASK/%s: Starting '%s' as %s with PID %s",$task->ID,$cmdStr,$task->ID,$task->PID);

		$heap->{'task_line_num'}->{$task->ID} = $cmdStr;

	# If there is no commands in the queue, set it to idle
	} else {
		# Set task to idle
		$heap->{'idle_tasks'}->{$task->ID} = $task;
	}
}



# Queue a task
sub _task_queue
{
	my ($kernel,$heap,$changeSet) = @_[KERNEL,HEAP,ARG0];


	# Internal function to add command to queue
	_task_add_to_queue($changeSet);

	# Trigger a run if list is not empty
	if (@{$globals->{'TaskQueue'}}) {
		$kernel->yield("_task_run_next");
	}
}



# Run next task
sub _task_run_next
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
	if (@{$globals->{'TaskQueue'}}) {

		# Create task
		my $task = POE::Wheel::Run->new(
			Program => [ '/sbin/tc', '-force', '-batch' ],
			Conduit => 'pipe',
			StdioFilter => POE::Filter::Line->new( Literal => "\n" ),
			StderrFilter => POE::Filter::Line->new( Literal => "\n" ),
			StdoutEvent => '_task_child_stdout',
			StderrEvent => '_task_child_stderr',
			CloseEvent => '_task_child_close',
			StdinEvent => '_task_child_stdin',
			ErrorEvent => '_task_child_error',
		) or $logger->log(LOG_ERR,"[TC] TASK: Unable to start task");

		# Set task ID
		my $task_id = $task->ID;


		# Intercept SIGCHLD
		$kernel->sig_child($task->PID, "_SIGCHLD");

		# Wheel events include the wheel's ID.
		$heap->{'task_by_wid'}->{$task_id} = $task;
		# Signal events include the process ID.
		$heap->{'task_by_pid'}->{$task_id} = $task;
		# Set line number to 0
		$heap->{'task_line_num'}->{$task_id} = 0;

		_task_put_next($heap,$task);
	}
}



# Child writes to STDOUT
sub _task_child_stdout
{
	my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];


	my $task = $heap->{'task_by_wid'}->{$task_id};

	$logger->log(LOG_INFO,"[TC] TASK/%s: STDOUT => %s",$task_id,$stdout);
}



# Child writes to STDERR
sub _task_child_stderr
{
	my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];


	my $task = $heap->{'task_by_wid'}->{$task_id};

	$logger->log(LOG_WARN,"[TC] TASK/%s: STDERR '%s' => %s",$task_id,$heap->{'task_line_num'}->{$task_id},$stdout);
}



# Child flushed to STDIN
sub _task_child_stdin
{
	my ($kernel,$heap,$task_id) = @_[KERNEL,HEAP,ARG0];


	my $task = $heap->{'task_by_wid'}->{$task_id};

	$logger->log(LOG_DEBUG,"[TC] TASK/%s is READY",$task_id);
	# And shove another queued command its direction
	_task_put_next($heap,$task);
}



# Child closed its handles, it won't communicate with us, so remove it
sub _task_child_close
{
	my ($kernel,$heap,$task_id) = @_[KERNEL,HEAP,ARG0];


	my $task = $heap->{'task_by_wid'}->{$task_id};

	# May have been reaped by task_sigchld()
	if (!defined($task)) {
		$logger->log(LOG_DEBUG,"[TC] TASK/%s: Closed dead child",$task_id);
		return;
	}

	$logger->log(LOG_DEBUG,"[TC] TASK/%s: Closed PID %s",$task_id,$task->PID);

	# Remove other references
	delete($heap->{'task_by_wid'}->{$task_id});
	delete($heap->{'task_by_pid'}->{$task->PID});
	delete($heap->{'idle_tasks'}->{$task_id});
	delete($heap->{'task_line_num'}->{$task_id});

	# Start next one, if there is a next one
	if (@{$globals->{'TaskQueue'}}) {
		$kernel->yield("_task_run_next");
	}
}



# Child got an error event, lets remove it too
sub _task_child_error
{
	my ($kernel,$heap,$operation,$errnum,$errstr,$task_id) = @_[KERNEL,HEAP,ARG0..ARG3];


	my $task = $heap->{'task_by_wid'}->{$task_id};

	if ($operation eq "read" && !$errnum) {
		$errstr = "Remote end closed"
	}

	$logger->log(LOG_ERR,"[TC] Task %s generated %s error %s: '%s'",$task_id,$operation,$errnum,$errstr);

	# If there is no task, return
	return if (!defined($task));

	# Remove other references
	delete($heap->{'task_by_wid'}->{$task_id});
	delete($heap->{'task_by_pid'}->{$task->PID});
	delete($heap->{'idle_tasks'}->{$task_id});
	delete($heap->{'task_line_num'}->{$task_id});

	# Start next one, if there is a next one
	if (@{$globals->{'TaskQueue'}}) {
		$kernel->yield("_task_run_next");
	}
}



# Reap the dead child
sub _task_SIGCHLD
{
	my ($kernel,$heap,$pid,$status) = @_[KERNEL,HEAP,ARG1,ARG2];


	my $task = $heap->{'task_by_pid'}->{$pid};

	$logger->log(LOG_DEBUG,"[TC] TASK: Task with PID %s exited with status %s",$pid,$status);

	# May have been reaped by task_child_close()
	return if (!defined($task));

	# Remove other references
	delete($heap->{'task_by_wid'}->{$task->ID});
	delete($heap->{'task_by_pid'}->{$pid});
	delete($heap->{'idle_tasks'}->{$task->ID});
	delete($heap->{'task_line_num'}->{$task->ID});
}



# Handle SIGINT
sub _task_SIGINT
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
