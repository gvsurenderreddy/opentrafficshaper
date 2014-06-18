# OpenTrafficShaper configuration manager
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



package opentrafficshaper::plugins::configmanager;

use strict;
use warnings;

use POE;
use Storable qw(
	dclone
);
use Time::HiRes qw(
	gettimeofday
	tv_interval
);

use awitpt::util qw(
	isNumber ISNUMBER_ALLOW_ZERO
	isIPv4
	isUsername ISUSERNAME_ALLOW_ATSIGN

	prettyUndef

	getHashChanges
);
use opentrafficshaper::constants;
use opentrafficshaper::logger;



# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
	createGroup
	isGroupIDValid

	createTrafficClass
	getTrafficClass
	getTrafficClasses
	getInterfaceTrafficClass
	getAllTrafficClasses
	isTrafficClassIDValid

	isInterfaceIDValid

	createInterface
	createInterfaceClass
	createInterfaceGroup
	changeInterfaceTrafficClass
	getEffectiveInterfaceTrafficClass2
	isInterfaceTrafficClassValid
	setInterfaceTrafficClassShaperState
	unsetInterfaceTrafficClassShaperState

	createLimit

	getPoolOverride
	getPoolOverrides

	createPool
	removePool
	changePool
	getPools
	getPool
	getPoolByName
	getPoolTxInterface
	getPoolRxInterface
	getPoolTrafficClassID
	setPoolAttribute
	getPoolAttribute
	removePoolAttribute
	getPoolShaperState
	setPoolShaperState
	unsetPoolShaperState
	isPoolIDValid
	isPoolReady

	getEffectivePool

	createPoolMember
	removePoolMember
	changePoolMember
	getPoolMembers
	getPoolMember
	getPoolMemberByUsernameIP
	getAllPoolMembersByInterfaceGroupIP
	getPoolMemberMatchPriority
	setPoolMemberShaperState
	unsetPoolMemberShaperState
	getPoolMemberShaperState
	getPoolMemberMatchPriority
	setPoolMemberAttribute
	getPoolMemberAttribute
	removePoolMemberAttribute
	isPoolMemberReady

	getTrafficClassPriority

	getTrafficDirection

	getInterface
	getInterfaces
	getInterfaceDefaultPool
	getInterfaceLimit
	getInterfaceGroup
	getInterfaceGroups
	isInterfaceGroupIDValid

	getMatchPriorities
	isMatchPriorityIDValid
);

use constant {
	VERSION => '0.2.3',

	# After how long does a limit get removed if its's deemed offline
	TIMEOUT_EXPIRE_OFFLINE => 300,

	# How often our config check ticks
	TICK_PERIOD => 5,

	# Intervals for periodic actions
	CLEANUP_INTERVAL => 300,
	STATE_SYNC_INTERVAL => 300,
};


# Mandatory pool attributes
sub POOL_REQUIRED_ATTRIBUTES {
	qw(
		Name
		InterfaceGroupID
		TrafficClassID TxCIR RxCIR
		Source
	)
}

# Pool attributes that can be changed
sub POOL_CHANGE_ATTRIBUTES {
	qw(
		FriendlyName
		TrafficClassID TxCIR RxCIR TxLimit RxLimit
		Expires
		Notes
	)
}

# Pool persistent attributes
sub POOL_PERSISTENT_ATTRIBUTES {
	qw(
		ID
		Name
		FriendlyName
		InterfaceGroupID
		TrafficClassID TxCIR RxCIR TxLimit RxLimit
		Expires
		Source
		Notes
	)
}

# Class attributes that can be changed (overridden)
sub CLASS_CHANGE_ATTRIBUTES {
	qw(
		CIR Limit
	)
}

# Class attributes that can be overidden
sub CLASS_OVERRIDE_CHANGESET_ATTRIBUTES {
	qw(
		CIR Limit
	)
}

# Class attributes that can be overidden
sub CLASS_OVERRIDE_PERSISTENT_ATTRIBUTES {
	qw(
		InterfaceID
		TrafficClassID
		CIR Limit
	)
}

# Mandatory pool member attributes
sub POOLMEMBER_REQUIRED_ATTRIBUTES {
	qw(
		Username IPAddress
		MatchPriorityID
		PoolID
		GroupID
		Source
	)
}

# Pool member attributes that can be changed
sub POOLMEMBER_CHANGE_ATTRIBUTES {
	qw(
		FriendlyName
		Expires
		Notes
	)
}

# Pool member persistent attributes
sub POOLMEMBER_PERSISTENT_ATTRIBUTES {
	qw(
		FriendlyName
		Username IPAddress
		MatchPriorityID
		PoolID
		GroupID
		Source
		Expires
		Notes
	)
}


# Mandatory limit attributes
sub LIMIT_REQUIRED_ATTRIBUTES {
	qw(
		Username IPAddress
		InterfaceGroupID MatchPriorityID
		GroupID
		TrafficClassID	TxCIR RxCIR
		Source
	)
}


# Pool override match attributes, one is required
sub POOL_OVERRIDE_MATCH_ATTRIBUTES {
	qw(
		PoolName Username IPAddress
		GroupID
	)
}

# Pool override attributes
sub POOL_OVERRIDE_ATTRIBUTES {
	qw(
		FriendlyName
		PoolName Username IPAddress GroupID
		TrafficClassID TxCIR RxCIR TxLimit RxLimit
		Expires
		Notes
	)
}

# Pool override attributes that can be changed
sub POOL_OVERRIDE_CHANGE_ATTRIBUTES {
	qw(
		FriendlyName
		TrafficClassID TxCIR RxCIR TxLimit RxLimit
		Expires
		Notes
	)
}

# Pool override changeset attributes
sub POOL_OVERRIDE_CHANGESET_ATTRIBUTES {
	qw(
		TrafficClassID TxCIR RxCIR TxLimit RxLimit
	)
}

# Pool override attributes supported for persistent storage
sub POOL_OVERRIDE_PERSISTENT_ATTRIBUTES {
	qw(
		FriendlyName
		PoolName Username IPAddress GroupID
		TrafficClassID TxCIR RxCIR TxLimit RxLimit
		Notes
		Expires Created
		Source
		LastUpdate
	)
}




# Plugin info
our $pluginInfo = {
	Name => "Config Manager",
	Version => VERSION,

	Init => \&plugin_init,
	Start => \&plugin_start,
};


# This modules globals
my $globals;
# System logger
my $logger;

# Configuration for this plugin
our $config = {
	# Match priorities
	'match_priorities' => {
		1 => 'First',
		2 => 'Default',
		3 => 'Fallthrough'
	},
	# State file
	'statefile' => '/var/lib/opentrafficshaper/configmanager.state',
};


#
# GROUPS - pool members are linked to groups
#
# Attributes:
#  * ID
#  * Name
#
# $globals->{'Groups'}

#
# CLASSES
#
# Attributes:
#  * ID
#  * Name
#
# $globals->{'TrafficClasses'}


#
# INTERFACES
#
# Attributes:
#  * ID
#  * Name
#  * Interface
#  * Limit
#
# $globals->{'Interfaces'}


#
# POOLS
#
# Parameters:
# * ID
# * FriendlyName
#    - Used for display purposes
# * Name
#    - Unix timestamp when this entry expires, 0 if never
# * TrafficClassID
#    - Traffic class ID
# * InterfaceGroupID
#    - Interface group this pool is attached to
# * TxCIR
#    - Traffic limit in kbps
# * RxCIR
#    - Traffic limit in kbps
# * TxLimit
#    - Traffic bursting limit in kbps
# * RxLimit
#    - Traffic bursting limit in kbps
# * Notes
#    - Notes on this limit
# * Source
#    - This is the source of the limit, typically plugin.ModuleName
#
# $globals->{'Pools'}
# $globals->{'PoolNameMap'}
# $globals->{'PoolIDCounter'}


#
# POOL MEMBERS
#
# Supoprted user attributes:
# * ID
# * PoolID
#    - Pool ID
# * Username
#    - Users username
# * IPAddress
#    - Users IP address
# * GroupID
#    - Group ID
# * MatchPriorityID
#    - Match priority on the backend of this limit
# * TrafficClassID
#    - Class ID
# * Expires
#    - Unix timestamp when this entry expires, 0 if never
# * FriendlyName
#    - Used for display purposes instead of username if specified
# * Notes
#    - Notes on this limit
# * Status
#    - new
#    - offline
#    - online
#    - unknown
# * Source
#    - This is the source of the limit, typically plugin.ModuleName
#
# $globals->{'PoolMembers'}
# $globals->{'PoolMemberIDCounter'}
# $globals->{'PoolMemberMap'}


#
# POOL OVERRIDES
#
# Selection criteria:
# * PoolName
#    - Pool name
# * Username
#    - Users username
# * IPAddress
#    - Users IP address
# * GroupID
#    - Group ID
#
# Pool Overrides:
# * TrafficClassID
#    - Class ID
# * TxCIR
#    - Traffic limit in kbps
# * RxCIR
#    - Traffic limit in kbps
# * TxLimit
#    - Traffic bursting limit in kbps
# * RxLimit
#    - Traffic bursting limit in kbps
#
# Parameters:
# * ID
# * FriendlyName
#    - Used for display purposes
# * Expires
#    - Unix timestamp when this entry expires, 0 if never
# * Notes
#    - Notes on this limit
# * Source
#    - This is the source of the limit, typically plugin.ModuleName
#
# $globals->{'PoolOverrides'}
# $globals->{'PoolOverrideIDCounter'}


#
# CHANGE QUEUES
#
# $globals->{'PoolChangeQueue'}
# $globals->{'PoolMemberChangeQueue'}



# Initialize plugin
sub plugin_init
{
	my $system = shift;


	my $now = time();

	# Setup our environment
	$logger = $system->{'logger'};

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] OpenTrafficShaper Config Manager v%s - Copyright (c) 2007-2014, AllWorldIT",
			VERSION
	);

	# Initialize
	$globals->{'LastCleanup'} = $now;
	$globals->{'StateChanged'} = 0;
	$globals->{'LastStateSync'} = $now;

	$globals->{'Groups'} = { };
	$globals->{'TrafficClasses'} = { };

	$globals->{'Interfaces'} = { };
	$globals->{'InterfaceGroups'} = { };

	$globals->{'Pools'} = { };
	$globals->{'PoolNameMap'} = { };
	$globals->{'PoolIDCounter'} = 1;
	$globals->{'DefaultPool'} = undef;

	$globals->{'PoolMembers'} = { };
	$globals->{'PoolMemberIDCounter'} = 1;
	$globals->{'PoolMemberMap'} = { };

	$globals->{'PoolOverrides'} = { };
	$globals->{'PoolOverrideIDCounter'} = 1;

	$globals->{'InterfaceTrafficClasses'} = { };
	$globals->{'InterfaceTrafficClassCounter'} = 1;

	$globals->{'PoolChangeQueue'} = { };
	$globals->{'PoolMemberChangeQueue'} = { };
	$globals->{'InterfaceTrafficClassChangeQueue'} = { };

	# If we have global config, use it
	my $gconfig = { };
	if (defined($system->{'file.config'}->{'shaping'})) {
		$gconfig = $system->{'file.config'}->{'shaping'};
	}

	# Split off groups to load
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading traffic groups...");
	# Check if we loaded an array or just text
	my @groups;
	if (defined($gconfig->{'group'})) {
		if (ref($gconfig->{'group'}) eq "ARRAY") {
			@groups = @{$gconfig->{'group'}};
		} else {
			@groups = ( $gconfig->{'group'} );
		}
	} else {
		@groups = ( "1:Default (auto)" );
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] No groups, setting up defaults");
	}
	# Loop with groups
	foreach my $group (@groups) {
		# Skip comments
		next if ($group =~ /^\s*#/);
		# Split off group ID and group name
		my ($groupID,$groupName) = split(/:/,$group);
		if (!defined($groupID) || int($groupID) < 1) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Traffic group definition '%s' has invalid ID, ignoring",$group);
			next;
		}
		if (!defined($groupName) || $groupName eq "") {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Traffic group definition '%s' has invalid name, ignoring",$group);
			next;
		}
		# Create group
		$groupID = createGroup({
			'ID' => $groupID,
			'Name' => $groupName
		});

		if (defined($groupID)) {
			$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded traffic group '%s' [%s]",$groupName,$groupID);
		}
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Traffic groups loaded");


	# Split off traffic classes
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading traffic classes...");
	# Check if we loaded an array or just text
	my @classes;
	if (defined($gconfig->{'class'})) {
		if (ref($gconfig->{'class'}) eq "ARRAY") {
			@classes = @{$gconfig->{'class'}};
		} else {
			@classes = ( $gconfig->{'class'} );
		}
	} else {
		@classes = ( "1:Default (auto)" );
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] No classes, setting up defaults");
	}
	# Loop with classes
	foreach my $class (@classes) {
		# Skip comments
		next if ($class =~ /^\s*#/);
		# Split off class ID and class name
		my ($trafficClassID,$className) = split(/:/,$class);
		if (!defined(isNumber($trafficClassID))) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Traffic class definition '%s' has invalid ID, ignoring",$class);
			next;
		}
		if (!defined($className) || $className eq "") {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Traffic class definition '%s' has invalid name, ignoring",$class);
			next;
		}
		# Create class
		$trafficClassID = createTrafficClass({
			'ID' => $trafficClassID,
			'Name' => $className
		});

		if (!defined($trafficClassID)) {
			next;
		}

		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded traffic class '%s' [%s]",$className,$trafficClassID);
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Traffic classes loaded");


	# Load interfaces
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading interfaces...");
	my @interfaces;
	if (defined($system->{'file.config'}->{'shaping.interface'})) {
		@interfaces = keys %{$system->{'file.config'}->{'shaping.interface'}};
	} else {
		@interfaces = ( "eth0", "eth1" );
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] No interfaces defined, using 'eth0' and 'eth1'");
	}
	# Loop with interface
	foreach my $interface (@interfaces) {
		# This is the interface config to make things easier for us
		my $iconfig = { };
		# Check if its defined
		if (defined($system->{'file.config'}->{'shaping.interface'}) &&
				defined($system->{'file.config'}->{'shaping.interface'}->{$interface})
		) {
			$iconfig = $system->{'file.config'}->{'shaping.interface'}->{$interface}
		}

		# Check our friendly name for this interface
		my $interfaceName = "$interface (auto)";
		if (defined($iconfig->{'name'}) && $iconfig->{'name'} ne "") {
			$interfaceName = $iconfig->{'name'};
		} else {
			$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '%s' has no 'name' attribute, using '%s (auto)'",
					$interface,$interface
			);
		}

		# Check our interface rate
		my $interfaceLimit = 100000;
		if (defined($iconfig->{'rate'}) && $iconfig->{'rate'} ne "") {
			# Check limit is valid
			if (defined(my $rate = isNumber($iconfig->{'rate'}))) {
				$interfaceLimit = $rate;
			} else {
				$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' has invalid 'rate' attribute, using 100000 instead",
						$interface
				);
			}
		} else {
			$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '%s' has no 'rate' attribute specified, using 100000",$interface);
		}

		# Create interface
		my $interfaceID = createInterface({
			'ID' => $interface,
			'Name' => $interfaceName,
			'Device' => $interface,
			'Limit' => $interfaceLimit
		});


		# Check if we have a section in our
		if (defined($iconfig->{'class_rate'})) {

			# Lets pull off the class_rate items
			my @iclasses;
			if (ref($iconfig->{'class_rate'}) eq "ARRAY") {
				@iclasses = @{$iconfig->{'class_rate'}};
			} else {
				@iclasses = ( $iconfig->{'class_rate'} );
			}

			# Loop with class_rates and parse
			foreach my $iclass (@iclasses) {
				# Skip comments
				next if ($iclass =~ /^\s*#/);
				# Split off class ID and class name
				my ($itrafficClassID,$iclassCIR,$iclassLimit) = split(/[:\/]/,$iclass);


				if (!defined($itrafficClassID = isTrafficClassIDValid($itrafficClassID))) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class definition '%s' has invalid Class ID, ignoring ".
							"definition",
							$interface,
							$iclass
					);
					next;
				}

				# If the CIR is defined, try use it
				if (defined($iclassCIR)) {
					# If its not a number, something is wrong
					if ($iclassCIR =~ /^([1-9][0-9]*)(%)?$/) {
						my ($cir,$percent) = ($1,$2);
						# Check if this is a percentage or an actual kbps value
						if (defined($percent)) {
							$iclassCIR = int($interfaceLimit * ($cir / 100));
						} else {
							$iclassCIR = $cir;
						}
					} else {
						$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class '%s' has invalid CIR, ignoring definition",
								$interface,
								$itrafficClassID
						);
						next;
					}
				} else {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class '%s' has missing CIR, ignoring definition",
							$interface,
							$itrafficClassID
					);
					next;
				}

				# If the limit is defined, try use it
				if (defined($iclassLimit)) {
					# If its not a number, something is wrong
					if ($iclassLimit =~ /^([1-9][0-9]*)(%)?$/) {
						my ($Limit,$percent) = ($1,$2);
						# Check if this is a percentage or an actual kbps value
						if (defined($percent)) {
							$iclassLimit = int($interfaceLimit * ($Limit / 100));
						} else {
							$iclassLimit = $Limit;
						}
					} else {
						$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class '%s' has invalid Limit, ignoring",
								$interface,
								$itrafficClassID
						);
						next;
					}
				} else {
					$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '%s' class '%s' has missing Limit, using CIR '%s' instead",
							$interface,
							$itrafficClassID,
							$iclassCIR
					);
					$iclassLimit = $iclassCIR;
				}

				# Check if rates are below are sane
				if ($iclassCIR > $interfaceLimit) {
					$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '%s' class '%s' has CIR '%s' > interface speed '%s', ".
							"adjusting to '%s'",
							$interface,
							$itrafficClassID,
							$iclassCIR,
							$interfaceLimit,
							$interfaceLimit
					);
					$iclassCIR = $interfaceLimit;
				}
				if ($iclassLimit > $interfaceLimit) {
					$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '%s' class '%s' has Limit '%s' > interface speed '%s', ".
							"adjusting to '%s'",
							$interface,
							$itrafficClassID,
							$iclassCIR,
							$interfaceLimit,
							$interfaceLimit
					);
					$iclassLimit = $interfaceLimit;
				}
				if ($iclassCIR > $iclassLimit) {
					$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '%s' class '%s' has CIR '%s' > Limit '%s', adjusting CIR ".
							"to '%s'",
							$interface,
							$itrafficClassID,
							$iclassLimit,
							$iclassLimit,
							$iclassLimit
					);
					$iclassCIR = $iclassLimit;
				}

				# Create class
				my $interfaceTrafficClassID = createInterfaceTrafficClass({
						'InterfaceID' => $interfaceID,
						'TrafficClassID' => $itrafficClassID,
						'CIR' => $iclassCIR,
						'Limit' => $iclassLimit
				});

				if (!defined($interfaceTrafficClassID)) {
					next;
				}

				$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded interface '%s' class rate for class ID '%s': %s/%s",
						$interface,
						$itrafficClassID,
						$iclassCIR,
						$iclassLimit
				);
			}

		}

		# Time to check the interface classes
		foreach my $trafficClassID (getAllTrafficClasses()) {
			# Check if we have a rate defined for this class in the interface definition
			if (!isInterfaceTrafficClassValid($interfaceID,$trafficClassID)) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '%s' has no class '%s' defined, using interface limit",
						$interface,
						$trafficClassID
				);
				# Create the default class
				createInterfaceTrafficClass({
					'InterfaceID' => $interfaceID,
					'TrafficClassID' => $trafficClassID,
					'CIR' => $interfaceLimit,
					'Limit' => $interfaceLimit
				});

				$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded interface '%s' default class rate for class ID '%s': %s/%s",
						$interface,
						$trafficClassID,
						$interfaceLimit,
						$interfaceLimit
				);
			}
		}
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading interfaces completed");

	# Pull in interface groupings
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading interface groups...");
	# Check if we loaded an array or just text
	my @cinterfaceGroups;
	if (defined($gconfig->{'interface_group'})) {
		if (ref($gconfig->{'interface_group'}) eq "ARRAY") {
			@cinterfaceGroups = @{$gconfig->{'interface_group'}};
		} else {
			@cinterfaceGroups = ( $gconfig->{'interface_group'} );
		}
	} else {
		@cinterfaceGroups = ( "eth1,eth0:Default" );
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] No interface groups, trying default eth1,eth0");
	}
	# Loop with interface groups
	foreach my $interfaceGroup (@cinterfaceGroups) {
		# Skip comments
		next if ($interfaceGroup =~ /^\s*#/);
		# Split off class ID and class name
		my ($txInterface,$rxInterface,$friendlyName) = split(/[:,]/,$interfaceGroup);
		if (!isInterfaceIDValid($txInterface)) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface group definition '%s' has invalid interface '%s', ignoring",
					$interfaceGroup,
					$txInterface
			);
			next;
		}
		if (!isInterfaceIDValid($rxInterface)) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface group definition '%s' has invalid interface '%s', ignoring",
					$interfaceGroup,
					$rxInterface
			);
			next;
		}
		if (!defined($friendlyName) || $friendlyName eq "") {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface group definition '%s' has invalid friendly name, ignoring",
					$interfaceGroup,
			);
			next;
		}

		# Create interface group
		my $interfaceGroupID = createInterfaceGroup({
				'Name' => $friendlyName,
				'TxInterface' => $txInterface,
				'RxInterface' => $rxInterface
		});

		if (!defined($interfaceGroupID)) {
			next;
		}

		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded interface group '%s' [%s] with interfaces '%s/%s'",
				$friendlyName,
				$interfaceGroupID,
				$txInterface,
				$rxInterface
		);
	}

	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Interface groups loaded");


	# Check if we using a default pool or not
	if (defined($gconfig->{'default_pool'})) {
		# Check if its a number
		if (defined(my $default_pool = isNumber($gconfig->{'default_pool'}))) {
			if (isTrafficClassIDValid($default_pool)) {
				$logger->log(LOG_INFO,"[CONFIGMANAGER] Default pool set to use class '%s'",
						$default_pool
				);
				$globals->{'DefaultPool'} = $default_pool;
			} else {
				$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot enable default pool, class '%s' does not exist",
						$default_pool
				);
			}
		} else {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot enable default pool, value for 'default_pool' is invalid");
		}
	}

# TODO - loop and queue init interfaces?

	# Check if we have a state file
	if (defined(my $statefile = $system->{'file.config'}->{'system'}->{'statefile'})) {
		$config->{'statefile'} = $statefile;
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Set statefile to '%s'",$statefile);
	}

	# This is our configuration processing session
	POE::Session->create(
		inline_states => {
			_start => \&_session_start,
			_stop => \&_session_stop,
			_tick => \&_session_tick,
			_SIGHUP => \&_session_SIGHUP,

			limit_add => \&_session_limit_add,

			pool_override_add => \&_session_pool_override_add,
			pool_override_change => \&_session_pool_override_change,
			pool_override_remove => \&_session_pool_override_remove,

			pool_add => \&_session_pool_add,
			pool_remove => \&_session_pool_remove,
			pool_change => \&_session_pool_change,

			poolmember_add => \&_session_poolmember_add,
			poolmember_remove => \&_session_poolmember_remove,
			poolmember_change => \&_session_poolmember_change,

		}
	);
}



# Start the plugin
sub plugin_start
{
	# Load config
	if (-f $config->{'statefile'}) {
		_load_statefile();
	} else {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Statefile '%s' cannot be opened: %s",$config->{'statefile'},$!);
	}

	$logger->log(LOG_INFO,"[CONFIGMANAGER] Started with %s pools, %s pool members and %s pool overrides",
			scalar(keys %{$globals->{'Pools'}}),
			scalar(keys %{$globals->{'PoolMembers'}}),
			scalar(keys %{$globals->{'PoolOverrides'}})
	);
}



# Initialize config manager
sub _session_start
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Set our alias
	$kernel->alias_set("configmanager");

	# Set delay on config updates
	$kernel->delay('_tick' => TICK_PERIOD);

	$kernel->sig('HUP', '_SIGHUP');

	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Initialized");
}



# Stop the session
sub _session_stop
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Shutting down, saving configuration...");

	# We only need to write the sate if something changed?
	if ($globals->{'StateChanged'}) {
		# The 1 means FULL WRITE of all entries
		_write_statefile(1);
	}

	# Blow away all data
	$globals = undef;

	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Shutdown");

	$logger = undef;
}



# Time ticker for processing changes
sub _session_tick
{
	my $kernel = $_[KERNEL];


	my $now = time();

	# Check if we should sync state to disk
	if ($globals->{'StateChanged'} && $globals->{'LastStateSync'} + STATE_SYNC_INTERVAL < $now) {
		_write_statefile();
	}


	# Check if we should cleanup
	if ($globals->{'LastCleanup'} + CLEANUP_INTERVAL < $now) {
		# Loop with all pool overrides and check for expired entries
		while (my ($poid, $poolOverride) = each(%{$globals->{'PoolOverrides'}})) {
			# Pool override has effectively expired
			if (defined($poolOverride->{'Expires'}) && $poolOverride->{'Expires'} > 0 && $poolOverride->{'Expires'} < $now) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool override '%s' [%s] has expired, removing",
						$poolOverride->{'FriendlyName'},
						$poid
				);
				removePoolOverride($poid);
			}
		}
		# Loop with all pool members and check for expired entries
		while (my ($pmid, $poolMember) = each(%{$globals->{'PoolMembers'}})) {
			# Pool member has effectively expired
			if (defined($poolMember->{'Expires'}) && $poolMember->{'Expires'} > 0 && $poolMember->{'Expires'} < $now) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool member '%s' [%s] has expired, removing",
						$poolMember->{'Username'},
						$pmid
				);
				removePoolMember($pmid);
			}
		}
		# Loop with all the pools and check for expired entries
		while (my ($pid, $pool) = each(%{$globals->{'Pools'}})) {
			# Pool has effectively expired
			if (defined($pool->{'Expires'}) && $pool->{'Expires'} > 0 && $pool->{'Expires'} < $now) {
				# There are no members, its safe to remove
				if (getPoolMembers($pid) == 0) {
					$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] has expired, removing",
							$pool->{'Name'},
							$pid
					);
					removePool($pid);
				}
			}
		}
		# Reset last cleanup time
		$globals->{'LastCleanup'} = $now;
	}

	# Loop through interface traffic classes
	while (my ($interfaceTrafficClassID, $interfaceTrafficClass) = each(%{$globals->{'InterfaceTrafficClassChangeQueue'}})) {
		my $shaperState = getInterfaceTrafficClassShaperState($interfaceTrafficClassID);

		# Traffic class has been changed
		if ($interfaceTrafficClass->{'Status'} == CFGM_CHANGED) {
			# If the shaper is live we can go ahead
			if ($shaperState & SHAPER_LIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface traffic class [%s] has been modified, sending to shaper",
						$interfaceTrafficClassID
				);
				$kernel->post('shaper' => 'class_change' => $interfaceTrafficClassID);
				# Set pending online
				setInterfaceTrafficClassShaperState($interfaceTrafficClassID,SHAPER_PENDING);
				$interfaceTrafficClass->{'Status'} = CFGM_ONLINE;
				# Remove from queue
				delete($globals->{'InterfaceTrafficClassChangeQueue'}->{$interfaceTrafficClassID});

			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Interface traffic class [%s] has UNKNOWN state '%s'",
						$interfaceTrafficClassID,
						$shaperState
				);
			}

		} else {
			$logger->log(LOG_ERR,"[CONFIGMANAGER] Interface traffic class [%s] has UNKNOWN status '%s'",
					$interfaceTrafficClassID,
					$interfaceTrafficClass->{'Status'}
			);
		}
	}


	# Loop through pool change queue
	while (my ($pid, $pool) = each(%{$globals->{'PoolChangeQueue'}})) {
		my $shaperState = getPoolShaperState($pid);

		# Pool is newly added
		if ($pool->{'Status'} == CFGM_NEW) {

			# If the change is not yet live, we should queue it to go live
			if ($shaperState & SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] new and is not live, adding to shaper",
						$pool->{'Name'},
						$pid
				);
				$kernel->post('shaper' => 'pool_add' => $pid);
				# Set pending online
				setPoolShaperState($pid,SHAPER_PENDING);
				$pool->{'Status'} = CFGM_ONLINE;
				# Remove from queue
				delete($globals->{'PoolChangeQueue'}->{$pid});

			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' [%s] has UNKNOWN state '%s'",
						$pool->{'Name'},
						$pid,
						$shaperState
				);
			}

		# Pool is online but NOTLIVE
		} elsif ($pool->{'Status'} == CFGM_ONLINE) {

			# We've transitioned more than likely from offline, any state to online
			# We don't care if the shaper is pending removal, we going to force re-adding now
			if (!($shaperState & SHAPER_LIVE)) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] online and is not live, re-queue as add",
						$pool->{'Name'},
						$pid
				);
				$pool->{'Status'} = CFGM_NEW;

			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' [%s] has UNKNOWN state '%s'",
						$pool->{'Name'},
						$pid,
						$shaperState
				);
			}


		# Pool has been modified
		} elsif ($pool->{'Status'} == CFGM_CHANGED) {
			# If the shaper is live we can go ahead
			if ($shaperState & SHAPER_LIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] has been modified, sending to shaper",
						$pool->{'Name'},
						$pid
				);
				$kernel->post('shaper' => 'pool_change' => $pid);
				# Set pending online
				setPoolShaperState($pid,SHAPER_PENDING);
				$pool->{'Status'} = CFGM_ONLINE;
				# Remove from queue
				delete($globals->{'PoolChangeQueue'}->{$pid});

			} elsif ($shaperState & SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] has been modified and is not live, re-queue as add",
						$pool->{'Name'},
						$pid
				);
				$pool->{'Status'} = CFGM_NEW;

			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' [%s] has UNKNOWN state '%s'",
						$pool->{'Name'},
						$pid,
						$shaperState
				);
			}


		# Pool is being removed?
		} elsif ($pool->{'Status'} == CFGM_OFFLINE) {

			# If the change is live, but should go offline, queue it
			if ($shaperState & SHAPER_LIVE) {

				if ($now - $pool->{'LastUpdate'} > TIMEOUT_EXPIRE_OFFLINE) {
					# If we still have pool members, we got to abort
					if (!getPoolMembers($pid)) {
						$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] marked offline and expired, removing from shaper",
								$pool->{'Name'},
								$pid
						);
						$kernel->post('shaper' => 'pool_remove' => $pid);
						setPoolShaperState($pid,SHAPER_PENDING);
					} else {
						$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] marked offline, but still has pool members, ".
								"aborting remove",
								$pool->{'Name'},
								$pid
						);
						$pool->{'Status'} = CFGM_ONLINE;
						delete($globals->{'PoolChangeQueue'}->{$pid});
					}

				} else {
					# Try remove all our pool members
					if (my @poolMembers = getPoolMembers($pid)) {
						# Loop with members and remove
						foreach my $pmid (@poolMembers) {
							my $poolMember = $globals->{'PoolMembers'}->{$pmid};
							# Only remove ones online
							if ($poolMember->{'Status'} == CFGM_ONLINE) {
								$logger->log(LOG_INFO,"[CONFIGMANAGER] Pool '%s' [%s] marked offline and not expired, removing ".
										"pool member [%s]",
										$pool->{'Name'},
										$pid,
										$pmid
								);
								removePoolMember($pmid);
							}
						}
					}
				}

			} elsif ($shaperState & SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] marked offline and is not live, removing",
						$pool->{'Name'},
						$pid
				);
				# Remove pool from name map
				delete($globals->{'PoolNameMap'}->{$pool->{'InterfaceGroupID'}}->{$pool->{'Name'}});
				# Remove pool member mapping
				delete($globals->{'PoolMemberMap'}->{$pid});
				# Remove from queue
				delete($globals->{'PoolChangeQueue'}->{$pid});
				# Cleanup pool overrides
				_remove_pool_override($pid);
				# Remove pool
				delete($globals->{'Pools'}->{$pid});
			}

		} else {
			$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' [%s] has UNKNOWN status '%s'",
					$pool->{'Name'},
					$pid,
					$pool->{'Status'}
			);
		}
	}


	# Loop through pool member change queue
	while (my ($pmid, $poolMember) = each(%{$globals->{'PoolMemberChangeQueue'}})) {

		my $pool = $globals->{'Pools'}->{$poolMember->{'PoolID'}};

		# We need to skip doing anything until the pool becomes live
		if (getPoolShaperState($pool->{'ID'}) & SHAPER_NOTLIVE) {
			next;
		}

		my $shaperState = getPoolMemberShaperState($pmid);

		# Pool member is newly added
		if ($poolMember->{'Status'} == CFGM_NEW) {

			# If the change is not yet live, we should queue it to go live
			if ($shaperState & SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] new and is not live, adding to shaper",
						$pool->{'Name'},
						$poolMember->{'IPAddress'},
						$pmid
				);
				$kernel->post('shaper' => 'poolmember_add' => $pmid);
				# Set pending online
				setPoolMemberShaperState($pmid,SHAPER_PENDING);
				$poolMember->{'Status'} = CFGM_ONLINE;
				# Remove from queue
				delete($globals->{'PoolMemberChangeQueue'}->{$pmid});

			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has UNKNOWN state '%s'",
						$pool->{'Name'},
						$poolMember->{'IPAddress'},
						$pmid,
						$shaperState
				);
			}

		# Pool member is online but NOTLIVE
		} elsif ($poolMember->{'Status'} == CFGM_ONLINE) {

			# We've transitioned more than likely from offline, any state to online
			# We don't care if the shaper is pending removal, we going to force re-adding now
			if (!($shaperState & SHAPER_LIVE)) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] online and is not live, re-queue as add",
						$pool->{'Name'},
						$poolMember->{'IPAddress'},
						$pmid
				);
				$poolMember->{'Status'} = CFGM_NEW;

			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has UNKNOWN state '%s'",
						$pool->{'Name'},
						$poolMember->{'IPAddress'},
						$pmid,
						$shaperState
				);
			}


		# Pool member has been modified
		} elsif ($poolMember->{'Status'} == CFGM_CHANGED) {

			# If the shaper is live we can go ahead
			if ($shaperState & SHAPER_LIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has been modified, sending to shaper",
						$pool->{'Name'},
						$poolMember->{'IPAddress'},
						$pmid
				);
				$kernel->post('shaper' => 'poolmember_change' => $pmid);
				# Set pending online
				setPoolMemberShaperState($pmid,SHAPER_PENDING);
				$poolMember->{'Status'} = CFGM_ONLINE;
				# Remove from queue
				delete($globals->{'PoolMemberChangeQueue'}->{$pmid});

			} elsif ($shaperState & SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has been modified and is not live, re-queue as ".
						"add",
						$pool->{'Name'},
						$poolMember->{'IPAddress'},
						$pmid
				);
				$poolMember->{'Status'} = CFGM_NEW;

			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has UNKNOWN state '%s'",
						$pool->{'Name'},
						$poolMember->{'IPAddress'},
						$pmid,
						$shaperState
				);
			}


		# Pool is being removed?
		} elsif ($poolMember->{'Status'} == CFGM_OFFLINE) {

			# If the change is live, but should go offline, queue it
			if ($shaperState & SHAPER_LIVE) {

				if ($now - $poolMember->{'LastUpdate'} > TIMEOUT_EXPIRE_OFFLINE) {
					$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] marked offline and expired, removing ".
							"from shaper",
							$pool->{'Name'},
							$poolMember->{'IPAddress'},
							$pmid
					);
					$kernel->post('shaper' => 'poolmember_remove' => $pmid);
					setPoolMemberShaperState($pmid,SHAPER_PENDING);

				} else {
					$logger->log(LOG_INFO,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] marked offline and fresh, postponing",
							$pool->{'Name'},
							$poolMember->{'IPAddress'},
							$pmid
					);
				}

			} elsif ($shaperState & SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] marked offline and is not live, removing",
						$pool->{'Name'},
						$poolMember->{'IPAddress'},
						$pmid
				);
				# Unlink interface IP address map
				delete($globals->{'InterfaceGroups'}->{$pool->{'InterfaceGroupID'}}->{'IPMap'}->{$poolMember->{'IPAddress'}}
						->{$pmid});
				# Unlink pool map
				delete($globals->{'PoolMemberMap'}->{$pool->{'ID'}}->{$pmid});
				# Remove from queue
				delete($globals->{'PoolMemberChangeQueue'}->{$pmid});
				# We need to re-process the pool overrides after the member has been removed
				_resolve_pool_override([$poolMember->{'PoolID'}]);
				# Remove pool member
				delete($globals->{'PoolMembers'}->{$pmid});

				# Check if we have/had conflicts
				if ((my @conflicts = keys
					%{$globals->{'InterfaceGroups'}->{$pool->{'InterfaceGroupID'}}->{'IPMap'}->{$poolMember->{'IPAddress'}}}) > 0)
				{
					# We can only re-tag a pool member for adding if we have 1 pool member
					if (@conflicts == 1) {
						# Grab conflicted pool member, its index 0 in the conflicts array
						my $cPoolMember = $globals->{'PoolMembers'}->{$conflicts[0]};
						# Grab pool
						my $cPool = $globals->{'Pools'}->{$cPoolMember->{'PoolID'}};
						# Unset conflict state
						unsetPoolMemberShaperState($cPoolMember->{'ID'},SHAPER_CONFLICT);
						# Add to change queue
						$globals->{'PoolMemberChangeQueue'}->{$poolMember->{'ID'}} = $poolMember;

						$logger->log(LOG_NOTICE,"[CONFIGMANAGER] IP '%s' is no longer conflicted, removing conflict from  ".
								"pool '%s' member '%s' [%s]",
							$cPoolMember->{'IPAddress'},
							$cPool->{'Name'},
							$cPoolMember->{'Username'},
							$cPoolMember->{'ID'}
						);
					} else {
						# Loop wiht conflicts and build some log items to use
						my @logItems;
						foreach my $pmid (@conflicts) {
							my $cPoolMember = $globals->{'PoolMembers'}->{$pmid};
							my $cPool = $globals->{'Pools'}->{$cPoolMember->{'PoolID'}};
							push(@logItems,sprintf("Pool:%s/Member:%s",$cPool->{'Name'},$cPoolMember->{'Username'}));
						}

						$logger->log(LOG_NOTICE,"[CONFIGMANAGER] IP '%s' is still in conflict: %s",
							$poolMember->{'IPAddress'},
							join(", ",@logItems)
						);
					}
				}
			}

		} else {
			$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has UNKNOWN status '%s'",
					$pool->{'Name'},
					$poolMember->{'IPAddress'},
					$pmid,
					$poolMember->{'Status'}
			);
		}

	}

	# Reset tick
	$kernel->delay('_tick' => TICK_PERIOD);
}



# Handle SIGHUP
sub _session_SIGHUP
{
	my ($kernel, $heap, $signal_name) = @_[KERNEL, HEAP, ARG0];

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Got SIGHUP, ignoring for now");
}



# Event for 'pool_add'
sub _session_pool_add
{
	my ($kernel, $poolData) = @_[KERNEL, ARG0];


	if (!defined($poolData)) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] No pool data provided for 'pool_add' event");
		return;
	}

	# Check if we have all the attributes we need
	my $isInvalid;
	foreach my $attr (POOL_REQUIRED_ATTRIBUTES) {
		if (!defined($poolData->{$attr})) {
			$isInvalid = $attr;
			last;
		}
	}
	if ($isInvalid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add as there is an attribute missing: '%s'",
				$isInvalid
		);
		return;
	}

	createPool($poolData);
}



# Event for 'pool_remove'
sub _session_pool_remove
{
	my ($kernel, $pid) = @_[KERNEL, ARG0];


	my $pool;
	if (!defined(getPool($pid))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Invalid pool ID '%s' for 'pool_remove' event",prettyUndef($pid));
		return;
	}

	removePool($pid);
}



# Event for 'pool_change'
sub _session_pool_change
{
	my ($kernel, $poolData) = @_[KERNEL, ARG0];


	if (!isPoolIDValid($poolData->{'ID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Invalid pool ID '%s' for 'pool_change' event",prettyUndef($poolData->{'ID'}));
		return;
	}

	changePool($poolData);
}



# Event for 'poolmember_add'
sub _session_poolmember_add
{
	my ($kernel, $poolMemberData) = @_[KERNEL, ARG0];


	if (!defined($poolMemberData)) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] No pool member data provided for 'poolmember_add' event");
		return;
	}

	# Check if we have all the attributes we need
	my $isInvalid;
	foreach my $attr (POOLMEMBER_REQUIRED_ATTRIBUTES) {
		if (!defined($poolMemberData->{$attr})) {
			$isInvalid = $attr;
			last;
		}
	}
	if ($isInvalid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process poolmember add as there is an attribute missing: '%s',$isInvalid");
		return;
	}

	createPoolMember($poolMemberData);
}



# Event for 'poolmember_remove'
sub _session_poolmember_remove
{
	my ($kernel, $pmid) = @_[KERNEL, ARG0];


	if (!isPoolMemberIDValid($pmid)) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Invalid pool member ID '%s' for 'poolmember_remove' event",prettyUndef($pmid));
		return;
	}

	removePoolMember($pmid);
}



# Event for 'poolmember_change'
sub _session_poolmember_change
{
	my ($kernel, $poolMemberData) = @_[KERNEL, ARG0];


	if (!isPoolMemberIDValid($poolMemberData->{'ID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Invalid pool member ID '%s' for 'poolmember_change' event",
				prettyUndef($poolMemberData->{'ID'})
		);
		return;
	}

	changePoolMember($poolMemberData);
}



# Event for 'limit_add'
sub _session_limit_add
{
	my ($kernel, $limitData) = @_[KERNEL, ARG0];


	if (!defined($limitData)) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] No limit data provided for 'limit_add' event");
		return;
	}

	# Check if we have all the attributes we need
	my $isInvalid;
	foreach my $attr (LIMIT_REQUIRED_ATTRIBUTES) {
		if (!defined($limitData->{$attr})) {
			$isInvalid = $attr;
			last;
		}
	}
	if ($isInvalid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process limit add as there is an attribute missing: '%s'",$isInvalid);
		return;
	}

	createLimit($limitData);
}



# Event for 'pool_override_add'
sub _session_pool_override_add
{
	my ($kernel, $poolOverrideData) = @_[KERNEL, ARG0];


	if (!defined($poolOverrideData)) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] No pool override data provided for 'pool_override_add' event");
		return;
	}

	# Check that we have at least one match attribute
	my $isValid = 0;
	foreach my $item (POOL_OVERRIDE_MATCH_ATTRIBUTES) {
		$isValid++;
	}
	if (!$isValid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool override as there is no selection attribute");
		return;
	}

	createPoolOverride($poolOverrideData);
}



# Event for 'pool_override_remove'
sub _session_pool_override_remove
{
	my ($kernel, $poid) = @_[KERNEL, ARG0];


	if (!isPoolOverrideIDValid($poid)) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Invalid pool override ID '%s' for 'pool_override_remove' event",
				prettyUndef($poid)
		);
		return;
	}

	removePoolOverride($poid);
}



# Event for 'pool_override_change'
sub _session_pool_override_change
{
	my ($kernel, $poolOverrideData) = @_[KERNEL, ARG0];


	if (!isPoolOverrideIDValid($poolOverrideData->{'ID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Invalid pool override ID '%s' for 'pool_override_change' event",
				prettyUndef($poolOverrideData->{'ID'})
		);
		return;
	}

	changePoolOverride($poolOverrideData);
}


# Function to create a group
sub createGroup
{
	my $groupData = shift;


	my $group;

	# Check if ID is valid
	if (!defined($group->{'ID'} = $groupData->{'ID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add group as ID is invalid");
		return;
	}
	# Check if Name is valid
	if (!defined($group->{'Name'} = $groupData->{'Name'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add group as Name is invalid");
		return;
	}


	# Add pool
	$globals->{'Groups'}->{$group->{'ID'}} = $group;

	return $group->{'ID'};
}



# Function to check the group ID exists
sub isGroupIDValid
{
	my $gid = shift;


	if (!defined($globals->{'Groups'}->{$gid})) {
		return;
	}

	return $gid;
}



# Function to create a traffic class
sub createTrafficClass
{
	my $classData = shift;


	my $class;

	# Check if ID is valid
	if (!defined($class->{'ID'} = $classData->{'ID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add traffic class as ID is invalid");
		return;
	}

	# Check if Name is valid
	if (!defined($class->{'Name'} = $classData->{'Name'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add traffic class as Name is invalid");
		return;
	}

	# Add pool
	$globals->{'TrafficClasses'}->{$class->{'ID'}} = $class;

	return $class->{'ID'};
}



# Function to get traffic classes
sub getTrafficClasses
{
	my @trafficClasses = ( );


	# Loop with traffic classes
	foreach my $trafficClassID (keys %{$globals->{'TrafficClasses'}}) {
		# Skip over default pool if we have one
		if (defined($globals->{'DefaultPool'}) && $trafficClassID eq $globals->{'DefaultPool'}) {
			next;
		}
		# Add to class list
		push (@trafficClasses,$trafficClassID);
	}

	return @trafficClasses;
}



# Function to get a interface traffic class
sub getInterfaceTrafficClass
{
	my ($interfaceID,$trafficClassID) = @_;


	# Check if this interface ID is valid
	if (!isInterfaceIDValid($interfaceID)) {
		return;
	}
	# Check if traffic class ID is valid
	if (!defined($trafficClassID = isNumber($trafficClassID,ISNUMBER_ALLOW_ZERO))) {
		return;
	}
	if ($trafficClassID && !isTrafficClassIDValid($trafficClassID)) {
		return;
	}

	my $interfaceTrafficClass = dclone($globals->{'Interfaces'}->{$interfaceID}->{'TrafficClasses'}->{$trafficClassID});

	# Check if the traffic class ID is not 0
	if ($trafficClassID) {
		$interfaceTrafficClass->{'Name'} = $globals->{'TrafficClasses'}->{$trafficClassID}->{'Name'};
	# If if it 0, this is a root class
	} else {
		$interfaceTrafficClass->{'Name'} = "Root Class";
	}

	delete($interfaceTrafficClass->{'.applied_overrides'});

	return $interfaceTrafficClass;
}



# Function to get a interface traffic class
sub getInterfaceTrafficClass2
{
	my $interfaceTrafficClassID = shift;


	# Check if this interface ID is valid
	if (!isInterfaceTrafficClassIDValid2($interfaceTrafficClassID)) {
		return;
	}

	my $interfaceTrafficClass = dclone($globals->{'InterfaceTrafficClasses'}->{$interfaceTrafficClassID});

	$interfaceTrafficClass->{'Name'} = $globals->{'TrafficClasses'}->{$interfaceTrafficClass->{'TrafficClassID'}};

	delete($interfaceTrafficClass->{'.applied_overrides'});

	return $interfaceTrafficClass;
}



# Function to check if traffic class is valid
sub isInterfaceTrafficClassValid
{
	my ($interfaceID,$trafficClassID) = @_;


	if (
			!defined($interfaceID) || !defined($trafficClassID) ||
			!defined($globals->{'Interfaces'}->{$interfaceID}) ||
			!defined($globals->{'Interfaces'}->{$interfaceID}->{'TrafficClasses'}->{$trafficClassID})
	) {
		return;
	}

	return $globals->{'Interfaces'}->{$interfaceID}->{'TrafficClasses'}->{$trafficClassID}->{'ID'};
}



# Function to check the interface traffic class ID is valid
sub isInterfaceTrafficClassIDValid2
{
	my $interfaceTrafficClassID = shift;


	if (
			!defined($interfaceTrafficClassID) ||
			!defined($globals->{'InterfaceTrafficClasses'}->{$interfaceTrafficClassID})
	) {
		return;
	}

	return $interfaceTrafficClassID;
}



# Function to create an interface class
sub createInterfaceTrafficClass
{
	my $interfaceTrafficClassData = shift;


	my $interfaceTrafficClass;

	# Check if InterfaceID is valid
	if (!defined($interfaceTrafficClass->{'InterfaceID'} = isInterfaceIDValid($interfaceTrafficClassData->{'InterfaceID'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add interface traffic class as InterfaceID is invalid");
		return;
	}

	# Check if traffic class ID is valid
	my $interfaceTrafficClassID;
	if (!defined($interfaceTrafficClassID = isNumber($interfaceTrafficClassData->{'TrafficClassID'},ISNUMBER_ALLOW_ZERO))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process class change as there is no 'TrafficClassID' attribute");
		return;
	}
	if ($interfaceTrafficClassID && !isTrafficClassIDValid($interfaceTrafficClassData->{'TrafficClassID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process class change as 'TrafficClassID' attribute is invalid");
		return;
	}
	$interfaceTrafficClass->{'TrafficClassID'} = $interfaceTrafficClassID;

	# Check CIR is valid
	if (!defined($interfaceTrafficClass->{'CIR'} = isNumber($interfaceTrafficClassData->{'CIR'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add interface as CIR is invalid");
		return;
	}

	# Check Limit is valid
	if (!defined($interfaceTrafficClass->{'Limit'} = isNumber($interfaceTrafficClassData->{'Limit'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add interface as Limit is invalid");
		return;
	}

	# Set ID
	$interfaceTrafficClass->{'ID'} = $globals->{'InterfaceTrafficClassCounter'}++;

	# Set status
	$interfaceTrafficClass->{'Status'} = CFGM_NEW;

	# Add interface
	$globals->{'Interfaces'}->{$interfaceTrafficClass->{'InterfaceID'}}->{'TrafficClasses'}
			->{$interfaceTrafficClass->{'TrafficClassID'}} = $interfaceTrafficClass;

	# Link to interface traffic classes
	$globals->{'InterfaceTrafficClasses'}->{$interfaceTrafficClass->{'ID'}} = $interfaceTrafficClass;

	# TODO: Hack, this should set NOTLIVE & NEW and have the shaper create as per note in plugin_init section
	# Set status on this interface traffic class
	setInterfaceTrafficClassShaperState($interfaceTrafficClass->{'ID'},SHAPER_LIVE);
	$interfaceTrafficClass->{'Status'} = CFGM_ONLINE;

	return $interfaceTrafficClass->{'TrafficClassID'};
}



# Function to change a traffic class
sub changeInterfaceTrafficClass
{
	my $interfaceTrafficClassData = shift;


	# Check interface exists first
	my $interfaceID;
	if (!defined($interfaceID = isInterfaceIDValid($interfaceTrafficClassData->{'InterfaceID'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process interface class change as there is no 'InterfaceID' attribute");
		return;
	}

	# Check if traffic class ID is valid
	my $trafficClassID;
	if (!defined($trafficClassID = isNumber($interfaceTrafficClassData->{'TrafficClassID'},ISNUMBER_ALLOW_ZERO))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process class change as there is no 'TrafficClassID' attribute");
		return;
	}
	if ($trafficClassID && !isTrafficClassIDValid($interfaceTrafficClassData->{'TrafficClassID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process class change as 'TrafficClassID' attribute is invalid");
		return;
	}

	my $interfaceTrafficClass =  $globals->{'Interfaces'}->{$interfaceID}->{'TrafficClasses'}->{$trafficClassID};

	my $changes = getHashChanges($interfaceTrafficClass,$interfaceTrafficClassData,[CLASS_CHANGE_ATTRIBUTES]);

	# Bump up changes
	$globals->{'StateChanged'}++;

	# Flag changed
	$interfaceTrafficClass->{'Status'} = CFGM_CHANGED;

	# XXX - hack our override in
	$interfaceTrafficClass->{'.applied_overrides'}->{'change'} = $changes;

	# Add to change queue
	$globals->{'InterfaceTrafficClassChangeQueue'}->{$interfaceTrafficClass->{'ID'}} = $interfaceTrafficClass;

	# Return what was changed
	return dclone($changes);
}



# Function to return a class with any items changed as per class overrides
sub getEffectiveInterfaceTrafficClass2
{
	my $interfaceTrafficClassID = shift;


	my $interfaceTrafficClass;
	if (!defined($interfaceTrafficClass = getInterfaceTrafficClass2($interfaceTrafficClassID))) {
		return;
	}

	my $realInterfaceTrafficClass = $globals->{'InterfaceTrafficClasses'}->{$interfaceTrafficClassID};

	# If we have applied class overrides, check out what changes there may be
	if (defined(my $appliedClassOverrides = $realInterfaceTrafficClass->{'.applied_overrides'})) {
		my $interfaceTrafficClassOverrideSet;

		# Loop with class overrides in ascending fashion, least matches to most
		foreach my $interfaceTrafficClassID (
				sort { $appliedClassOverrides->{$a} <=> $appliedClassOverrides->{$b} } keys %{$appliedClassOverrides}
		) {
			my $interfaceTrafficClassOverride = $appliedClassOverrides->{$interfaceTrafficClassID};

			# Loop with attributes and create our override set
			foreach my $attr (CLASS_OVERRIDE_CHANGESET_ATTRIBUTES) {
			# Set class override set attribute if the class override has defined it
				if (defined($interfaceTrafficClassOverride->{$attr}) && $interfaceTrafficClassOverride->{$attr} ne "") {
					$interfaceTrafficClassOverrideSet->{$attr} = $interfaceTrafficClassOverride->{$attr};
				}
			}
		}
		# Set class overrides on pool
		if (defined($interfaceTrafficClassOverrideSet)) {
			foreach my $attr (keys %{$interfaceTrafficClassOverrideSet}) {
				$interfaceTrafficClass->{$attr} = $interfaceTrafficClassOverrideSet->{$attr};
			}
		}
	}

	return $interfaceTrafficClass;
}



# Function to set interface traffic class shaper state
sub setInterfaceTrafficClassShaperState
{
	my ($interfaceTrafficClassID,$state) = @_;


	# Check interface traffic class exists first
	if (!isInterfaceTrafficClassIDValid2($interfaceTrafficClassID)) {
		return;
	}

	$globals->{'InterfacesTrafficClasses'}->{$interfaceTrafficClassID}->{'.shaper_state'} |= $state;

	return $globals->{'InterfacesTrafficClasses'}->{$interfaceTrafficClassID}->{'.shaper_state'};
}



# Function to unset interface traffic class shaper state
sub unsetInterfaceTrafficClassShaperState
{
	my ($interfaceTrafficClassID,$state) = @_;


	# Check interface traffic class exists first
	if (!isInterfaceTrafficClassIDValid2($interfaceTrafficClassID)) {
		return;
	}

	$globals->{'InterfacesTrafficClasses'}->{$interfaceTrafficClassID}->{'.shaper_state'} &= ~$state;

	return $globals->{'InterfacesTrafficClasses'}->{$interfaceTrafficClassID}->{'.shaper_state'};
}



# Function to get shaper state for a interface traffic class
sub getInterfaceTrafficClassShaperState
{
	my $interfaceTrafficClassID = shift;


	# Check interface traffic class exists first
	if (!isInterfaceTrafficClassIDValid2($interfaceTrafficClassID)) {
		return;
	}

	return $globals->{'InterfacesTrafficClasses'}->{$interfaceTrafficClassID}->{'.shaper_state'};
}



# Function to get all traffic classes
sub getAllTrafficClasses
{
	return ( keys %{$globals->{'TrafficClasses'}} );
}



# Function to get a traffic class
sub getTrafficClass
{
	my $trafficClassID = shift;


	if (!isTrafficClassIDValid($trafficClassID)) {
		return;
	}

	return $globals->{'TrafficClasses'}->{$trafficClassID};
}



# Function to check if traffic class is valid
sub isTrafficClassIDValid
{
	my $trafficClassID = shift;


	if (!defined($trafficClassID) || !defined($globals->{'TrafficClasses'}->{$trafficClassID})) {
		return;
	}

	return $trafficClassID;
}



# Function to return the traffic priority based on a traffic class
sub getTrafficClassPriority
{
	my $trafficClassID = shift;


	# Check it exists first
	if (!isTrafficClassIDValid($trafficClassID)) {
		return;
	}

	# NK: Short circuit, our TrafficClassID = Priority
	return $trafficClassID;
}



# Function to create an interface
sub createInterface
{
	my $interfaceData = shift;


	my $interface;

	# Check if ID is valid
	if (!defined($interface->{'ID'} = $interfaceData->{'ID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add interface as ID is invalid");
		return;
	}

	# Check if Interface is valid
	if (!defined($interface->{'Device'} = $interfaceData->{'Device'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add interface as Device is invalid");
		return;
	}

	# Check if Name is valid
	if (!defined($interface->{'Name'} = $interfaceData->{'Name'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add interface as Name is invalid");
		return;
	}

	# Check Limit is valid
	if (!defined($interface->{'Limit'} = isNumber($interfaceData->{'Limit'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add interface as Limit is invalid");
		return;
	}

	# Add interface
	$globals->{'Interfaces'}->{$interface->{'ID'}} = $interface;

	# Create interface main traffic class
	createInterfaceTrafficClass({
			'InterfaceID' => $interface->{'ID'},
			'TrafficClassID' => 0,
			'CIR' => $interfaceData->{'Limit'},
			'Limit' => $interfaceData->{'Limit'},
	});

	return $interface->{'ID'};
}



# Function to return if an interface ID is valid
sub isInterfaceIDValid
{
	my $interfaceID = shift;


	# Return undef if interface is not valid
	if (!defined($globals->{'Interfaces'}->{$interfaceID})) {
		return;
	}

	return $interfaceID;
}



# Function to return the configured Interfaces
sub getInterfaces
{
	return ( keys %{$globals->{'Interfaces'}} );
}



# Return interface classes
sub getInterface
{
	my $interfaceID = shift;


	# Check if interface ID is valid
	if (!isInterfaceIDValid($interfaceID)) {
		return;
	}

	my $res = dclone($globals->{'Interfaces'}->{$interfaceID});
	# We don't want to return TrafficClasses
	delete($res->{'TrafficClasses'});
	# And return it...
	return $res;
}



# Function to return our default pool configuration
sub getInterfaceDefaultPool
{
	my $interface = shift;


	# We don't really need the interface to return the default pool
	return $globals->{'DefaultPool'};
}



# Function to create an interface group
sub createInterfaceGroup
{
	my $interfaceGroupData = shift;


	my $interfaceGroup;


	# Check if Name is valid
	if (!defined($interfaceGroup->{'Name'} = $interfaceGroupData->{'Name'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add interface group as Name is invalid");
		return;
	}

	# Check if TxInterface is valid
	if (!defined($interfaceGroup->{'TxInterface'} = isInterfaceIDValid($interfaceGroupData->{'TxInterface'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add interface group as TxInterface is invalid");
		return;
	}

	# Check if RxInterface is valid
	if (!defined($interfaceGroup->{'RxInterface'} = isInterfaceIDValid($interfaceGroupData->{'RxInterface'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to add interface group as RxInterface is invalid");
		return;
	}

	$interfaceGroup->{'ID'} = sprintf('%s,%s',$interfaceGroup->{'TxInterface'},$interfaceGroup->{'RxInterface'});

	$interfaceGroup->{'IPMap'} = { };

	# Add interface group
	$globals->{'InterfaceGroups'}->{$interfaceGroup->{'ID'}} = $interfaceGroup;

	return $interfaceGroup->{'ID'};
}



# Function to get interface groups
sub getInterfaceGroups
{
	return ( keys %{$globals->{'InterfaceGroups'}} );
}



# Function to get an interface group
sub getInterfaceGroup
{
	my $interfaceGroupID = shift;


	if (!isInterfaceGroupIDValid($interfaceGroupID)) {
		return;
	}

	my $interfaceGroup = dclone($globals->{'InterfaceGroups'}->{$interfaceGroupID});

	delete($interfaceGroup->{'IPMap'});

	return $interfaceGroup;
}



# Function to check if interface group is valid
sub isInterfaceGroupIDValid
{
	my $interfaceGroupID = shift;


	if (!defined($interfaceGroupID) || !defined($globals->{'InterfaceGroups'}->{$interfaceGroupID})) {
		return;
	}

	return $interfaceGroupID;
}


# Function to get match priorities
sub getMatchPriorities
{
	return dclone($config->{'match_priorities'});
}



# Function to check if interface group is valid
sub isMatchPriorityIDValid
{
	my $mpid = shift;


	# Check all is ok
	if (!defined($mpid) || !defined($config->{'match_priorities'}->{$mpid})) {
		return;
	}

	return $mpid;
}



# Function to set a pool attribute
sub setPoolAttribute
{
	my ($pid,$attr,$value) = @_;


	# Return if it doesn't exist
	if (!isPoolIDValid($pid)) {
		return;
	}

	$globals->{'Pools'}->{$pid}->{'.attributes'}->{$attr} = $value;

	return $value;
}



# Function to get a pool attribute
sub getPoolAttribute
{
	my ($pid,$attr) = @_;


	# Return if it doesn't exist
	if (!isPoolIDValid($pid)) {
		return;
	}

	# Check if attribute exists first
	if (
			!defined($globals->{'Pools'}->{$pid}->{'.attributes'}) ||
			!defined($globals->{'Pools'}->{$pid}->{'.attributes'}->{$attr}))
	{
		return;
	}

	return $globals->{'Pools'}->{$pid}->{'.attributes'}->{$attr};
}



# Function to remove a pool attribute
sub removePoolAttribute
{
	my ($pid,$attr) = @_;


	# Return if it doesn't exist
	if (!isPoolIDValid($pid)) {
		return;
	}

	# Check if attribute exists first
	if (
			!defined($globals->{'Pools'}->{$pid}->{'.attributes'}) ||
			!defined($globals->{'Pools'}->{$pid}->{'.attributes'}->{$attr}))
	{
		return;
	}

	return delete($globals->{'Pools'}->{$pid}->{'.attributes'}->{$attr});
}



# Function to return a pool override
sub getPoolOverride
{
	my $poid = shift;


	if (!isPoolOverrideIDValid($poid)) {
		return;
	}

	my $poolOverride = dclone($globals->{'PoolOverrides'}->{$poid});

	return $poolOverride;
}



## Function to return a list of pool override ID's
sub getPoolOverrides
{
	return (keys %{$globals->{'PoolOverrides'}});
}



# Function to create a pool
sub createPool
{
	my $poolData = shift;


	# Check if we have all the attributes we need
	my $isInvalid;
	foreach my $attr (POOL_REQUIRED_ATTRIBUTES) {
		if (!defined($poolData->{$attr})) {
			$isInvalid = $attr;
			last;
		}
	}
	if ($isInvalid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add for '%s' as there is an attribute missing: '%s'",
				prettyUndef($poolData->{'Name'}),
				$isInvalid
		);
		return;
	}

	my $pool;

	my $now = time();

	# Now check if the name is valid
	if (!defined($pool->{'Name'} = $poolData->{'Name'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add as Name is invalid");
		return;
	}
	# Check interface group ID is OK
	if (!defined($pool->{'InterfaceGroupID'} = isInterfaceGroupIDValid($poolData->{'InterfaceGroupID'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add for '%s' as the InterfaceGroupID is invalid",
				$pool->{'Name'}
		);
		return;
	}
	# If we already have this name added, return it as the pool
	if (defined(my $pool = $globals->{'PoolNameMap'}->{$pool->{'InterfaceGroupID'}}->{$pool->{'Name'}})) {
		return $pool->{'ID'};
	}
	# Check class is OK
	if (!defined($pool->{'TrafficClassID'} = isTrafficClassIDValid($poolData->{'TrafficClassID'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add for '%s' as the TrafficClassID is invalid",
				$pool->{'Name'}
		);
		return;
	}
	# Make sure things are not attached to the default pool
	if (defined($globals->{'DefaultPool'}) && $pool->{'TrafficClassID'} eq $globals->{'DefaultPool'}) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add for '%s' as the TrafficClassID is the default pool class",
				$pool->{'Name'}
		);
		return;
	}
	# Check traffic limits
	if (!isNumber($pool->{'TxCIR'} = $poolData->{'TxCIR'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add for '%s' as the TxCIR is invalid",
				$pool->{'Name'}
		);
		return;
	}
	if (!isNumber($pool->{'RxCIR'} = $poolData->{'RxCIR'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add for '%s' as the RxCIR is invalid",
				$pool->{'Name'}
		);
		return;
	}
	# If we don't have burst limits, improvize
	if (!defined($pool->{'TxLimit'} = $poolData->{'TxLimit'})) {
		$pool->{'TxLimit'} = $pool->{'TxCIR'};
		$pool->{'TxCIR'} = int($pool->{'TxLimit'}/4);
	}
	if (!defined($pool->{'RxLimit'} = $poolData->{'RxLimit'})) {
		$pool->{'RxLimit'} = $pool->{'RxCIR'};
		$pool->{'RxCIR'} = int($pool->{'RxLimit'}/4);
	}
	# Set source
	$pool->{'Source'} = $poolData->{'Source'};
	# Set when this entry was created
	$pool->{'Created'} = defined($poolData->{'Created'}) ? $poolData->{'Created'} : $now;
	$pool->{'LastUpdate'} = $now;
	# Set when this entry expires
	$pool->{'Expires'} = defined($poolData->{'Expires'}) ? int($poolData->{'Expires'}) : 0;
	# Check status is OK
	$pool->{'Status'} = CFGM_NEW;
	# Set friendly name and notes
	$pool->{'FriendlyName'} = $poolData->{'FriendlyName'};
	# Set notes
	$pool->{'Notes'} = $poolData->{'Notes'};

	# Assign pool ID
	$pool->{'ID'} = $globals->{'PoolIDCounter'}++;

	# Add pool
	$globals->{'Pools'}->{$pool->{'ID'}} = $pool;

	# Link pool name map
	$globals->{'PoolNameMap'}->{$pool->{'InterfaceGroupID'}}->{$pool->{'Name'}} = $pool;
	# Blank our pool member mapping
	$globals->{'PoolMemberMap'}->{$pool->{'ID'}} = { };

	setPoolShaperState($pool->{'ID'},SHAPER_NOTLIVE);

	# Pool needs updating
	$globals->{'PoolChangeQueue'}->{$pool->{'ID'}} = $pool;

	# Resolve pool overrides
	_resolve_pool_override([$pool->{'ID'}]);

	# Bump up changes
	$globals->{'StateChanged'}++;

	return $pool->{'ID'};
}



# Function to remove a pool
sub removePool
{
	my $pid = shift;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	my $pool = $globals->{'Pools'}->{$pid};

	# Check if pool is not already offlining
	if ($pool->{'Status'} == CFGM_OFFLINE) {
		return;
	}

	my $now = time();

	# Set status to offline so its caught by our garbage collector
	$pool->{'Status'} = CFGM_OFFLINE;

	# Updated pool's last updated timestamp
	$pool->{'LastUpdate'} = $now;

	# Pool needs updating
	$globals->{'PoolChangeQueue'}->{$pool->{'ID'}} = $pool;

	# Bump up changes
	$globals->{'StateChanged'}++;

	return;
}



# Function to change a pool
sub changePool
{
	my $poolData = shift;


	# Check pool exists first
	if (!isPoolIDValid($poolData->{'ID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool change as there is no 'ID' attribute");
		return;
	}

	my $pool = $globals->{'Pools'}->{$poolData->{'ID'}};

	my $now = time();

	my $changes = getHashChanges($pool,$poolData,[POOL_CHANGE_ATTRIBUTES]);
	# Make changes...
	foreach my $item (keys %{$changes}) {
		$pool->{$item} = $changes->{$item};
	}

	# Set pool to being updated
	$pool->{'Status'} = CFGM_CHANGED;
	# Pool was just updated, so update our timestamp
	$pool->{'LastUpdate'} = $now;

	# Pool needs updating
	$globals->{'PoolChangeQueue'}->{$pool->{'ID'}} = $pool;

	# Bump up changes
	$globals->{'StateChanged'}++;

	# Return what was changed
	return dclone($changes);
}



# Function to return a pool
sub getPool
{
	my $pid = shift;


	if (!isPoolIDValid($pid)) {
		return;
	}

	my $pool = dclone($globals->{'Pools'}->{$pid});

	# Remove attributes?
	delete($pool->{'.attributes'});
	delete($pool->{'.applied_overrides'});

	return $pool;
}



# Function to get a pool by its name
sub getPoolByName
{
	my ($interfaceGroupID,$name) = @_;


	# Make sure both params are defined or we get warnings
	if (!defined($interfaceGroupID) || !defined($name)) {
		return;
	}

	# Maybe it doesn't exist?
	if (
			!defined($globals->{'PoolNameMap'}->{$interfaceGroupID}) ||
			!defined($globals->{'PoolNameMap'}->{$interfaceGroupID}->{$name}))
	{
		return;
	}

	return dclone($globals->{'PoolNameMap'}->{$interfaceGroupID}->{$name});
}



# Function to return a list of pool ID's
sub getPools
{
	return (keys %{$globals->{'Pools'}});
}



# Function to return a pool TX interface
sub getPoolTxInterface
{
	my $pid = shift;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	return $globals->{'InterfaceGroups'}->{$globals->{'Pools'}->{$pid}->{'InterfaceGroupID'}}->{'TxInterface'};
}



# Function to return a pool RX interface
sub getPoolRxInterface
{
	my $pid = shift;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	return $globals->{'InterfaceGroups'}->{$globals->{'Pools'}->{$pid}->{'InterfaceGroupID'}}->{'RxInterface'};
}



# Function to return a pool traffic class ID
sub getPoolTrafficClassID
{
	my $pid = shift;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	return $globals->{'Pools'}->{$pid}->{'TrafficClassID'};
}



# Function to set pools shaper state
sub setPoolShaperState
{
	my ($pid,$state) = @_;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	$globals->{'Pools'}->{$pid}->{'.shaper_state'} |= $state;

	return $globals->{'Pools'}->{$pid}->{'.shaper_state'};
}



# Function to unset pools shaper state
sub unsetPoolShaperState
{
	my ($pid,$state) = @_;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	$globals->{'Pools'}->{$pid}->{'.shaper_state'} &= ~$state;

	return $globals->{'Pools'}->{$pid}->{'.shaper_state'};
}



# Function to get shaper state for a pool
sub getPoolShaperState
{
	my $pid = shift;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	return $globals->{'Pools'}->{$pid}->{'.shaper_state'};
}



# Function to check the pool ID exists
sub isPoolIDValid
{
	my $pid = shift;


	if (!defined($pid) || !defined($globals->{'Pools'}->{$pid})) {
		return;
	}

	return $pid;
}



# Function to return if a pool is ready for any kind of modification
sub isPoolReady
{
	my $pid = shift;


	# Get state and check pool exists all in one
	my $state;
	if (!defined($state = getPoolShaperState($pid))) {
		return;
	}

	return ($globals->{'Pools'}->{$pid}->{'Status'} == CFGM_ONLINE && $state & SHAPER_LIVE);
}



# Function to return a pool with any items changed as per pool overrides
sub getEffectivePool
{
	my $pid = shift;


	my $pool;
	if (!defined($pool = getPool($pid))) {
		return;
	}

	my $realPool = $globals->{'Pools'}->{$pid};

	# If we have applied pool overrides, check out what changes there may be
	if (defined(my $appliedPoolOverrides = $realPool->{'.applied_overrides'})) {
		my $poolOverrideSet;

		# Loop with pool overrides in ascending fashion, least matches to most
		foreach my $poid ( sort { $appliedPoolOverrides->{$a} <=> $appliedPoolOverrides->{$b} } keys %{$appliedPoolOverrides}) {
			my $poolOverride = $globals->{'PoolOverrides'}->{$poid};

			# Loop with attributes and create our pool override set
			foreach my $attr (POOL_OVERRIDE_CHANGESET_ATTRIBUTES) {
				# Set pool override set attribute if the pool override has defined it
				if (defined($poolOverride->{$attr}) && $poolOverride->{$attr} ne "") {
					$poolOverrideSet->{$attr} = $poolOverride->{$attr};
				}
			}
		}

		# Set pool overrides on pool
		if (defined($poolOverrideSet)) {
			foreach my $attr (keys %{$poolOverrideSet}) {
				$pool->{$attr} = $poolOverrideSet->{$attr};
			}
		}
	}

	return $pool;
}



# Function to create a pool member
sub createPoolMember
{
	my $poolMemberData = shift;


	# Check if we have all the attributes we need
	my $isInvalid;
	foreach my $attr (POOLMEMBER_REQUIRED_ATTRIBUTES) {
		if (!defined($poolMemberData->{$attr})) {
			$isInvalid = $attr;
			last;
		}
	}
	if ($isInvalid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool member add as there is an attribute missing: '%s'",$isInvalid);
		return;
	}

	my $poolMember;

	my $now = time();

	# Check if IP address is defined
	if (!defined(isIPv4($poolMember->{'IPAddress'} = $poolMemberData->{'IPAddress'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool member add as the IPAddress is invalid");
		return;
	}
	# Now check if Username its valid
	if (!defined(isUsername($poolMember->{'Username'} = $poolMemberData->{'Username'}, ISUSERNAME_ALLOW_ATSIGN))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool member add as Username is invalid");
		return;
	}

	# Check pool ID is OK
	if (!defined($poolMember->{'PoolID'} = isPoolIDValid($poolMemberData->{'PoolID'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool member add for '%s' as the PoolID is invalid",
				$poolMemberData->{'Username'}
		);
		return;
	}

	# Grab pool
	my $pool = $globals->{'Pools'}->{$poolMember->{'PoolID'}};

	# Check match priority ID is OK
	if (!defined($poolMember->{'MatchPriorityID'} = isMatchPriorityIDValid($poolMemberData->{'MatchPriorityID'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool member add for '%s' as the MatchPriorityID is invalid",
				$poolMemberData->{'Username'}
		);
		return;
	}
	# Check group ID is OK
	if (!defined($poolMember->{'GroupID'} = isGroupIDValid($poolMemberData->{'GroupID'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool member add for '%s' as the GroupID is invalid",
				$poolMemberData->{'Username'}
		);
		return;
	}
	# Set source
	$poolMember->{'Source'} = $poolMemberData->{'Source'};
	# Set when this entry was created
	$poolMember->{'Created'} = defined($poolMemberData->{'Created'}) ? $poolMemberData->{'Created'} : $now;
	$poolMember->{'LastUpdate'} = $now;
	# Set when this entry expires
	$poolMember->{'Expires'} = defined($poolMemberData->{'Expires'}) ? int($poolMemberData->{'Expires'}) : 0;
	# Check status is OK
	$poolMember->{'Status'} = CFGM_NEW;
	# Set friendly name and notes
	$poolMember->{'FriendlyName'} = $poolMemberData->{'FriendlyName'};
	# Set notes
	$poolMember->{'Notes'} = $poolMemberData->{'Notes'};

	# Create pool member ID
	$poolMember->{'ID'} = $globals->{'PoolMemberIDCounter'}++;

	# Add pool member
	$globals->{'PoolMembers'}->{$poolMember->{'ID'}} = $poolMember;

	# Link pool map
	$globals->{'PoolMemberMap'}->{$pool->{'ID'}}->{$poolMember->{'ID'}} = $poolMember;

	# Updated pool's last updated timestamp
	$pool->{'LastUpdate'} = $now;
	# Make sure pool is online and not offlining
	if ($pool->{'Status'} == CFGM_OFFLINE) {
		$pool->{'Status'} = CFGM_ONLINE;
	}

	setPoolMemberShaperState($poolMember->{'ID'},SHAPER_NOTLIVE);

	# Check for IP conflicts
	if (
			defined($globals->{'InterfaceGroups'}->{$pool->{'InterfaceGroupID'}}->{'IPMap'}->{$poolMember->{'IPAddress'}}) &&
			(my @conflicts = keys %{$globals->{'InterfaceGroups'}->{$pool->{'InterfaceGroupID'}}->{'IPMap'}
					->{$poolMember->{'IPAddress'}}}) > 0
	) {
		# Loop wiht conflicts and build some log items to use
		my @logItems;
		foreach my $pmid (@conflicts) {
			my $cPoolMember = $globals->{'PoolMembers'}->{$pmid};
			my $cPool = $globals->{'Pools'}->{$cPoolMember->{'PoolID'}};
			push(@logItems,sprintf("Pool:%s/Member:%s",$cPool->{'Name'},$cPoolMember->{'Username'}));
		}

		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' IP '%s' conflicts with: %s",
				$pool->{'Name'},
				$poolMember->{'Username'},
				$poolMember->{'IPAddress'},
				join(", ",@logItems)
		);

		# We don't have to add it to the queue, as its in a conflicted state
		setPoolMemberShaperState($poolMember->{'ID'},SHAPER_CONFLICT);

	} else {
		# Pool member needs updating
		$globals->{'PoolMemberChangeQueue'}->{$poolMember->{'ID'}} = $poolMember;
	}

	# Link interface IP address map, we must do the check above FIRST, as that needs the pool to be added to the pool map
	$globals->{'InterfaceGroups'}->{$pool->{'InterfaceGroupID'}}->{'IPMap'}->{$poolMember->{'IPAddress'}}
			->{$poolMember->{'ID'}} = $poolMember;

	# Resolve pool overrides, there may of been no pool members, now there is one and we may be able to apply a pool override
	_resolve_pool_override([$pool->{'ID'}]);

	# Bump up changes
	$globals->{'StateChanged'}++;

	return $poolMember->{'ID'};
}



# Function to remove pool member, this function is actually just going to flag it offline
# the offline pool members will be caught by cleanup and removed, we do this because we
# need the pool member setup in the removal functions, we cannot remove it first, and we
# cannot allow plugins to remove internal data structures either.
sub removePoolMember
{
	my $pmid = shift;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	my $poolMember = $globals->{'PoolMembers'}->{$pmid};

	# Check if pool member is not already offlining
	if ($poolMember->{'Status'} == CFGM_OFFLINE) {
		return;
	}

	my $now = time();

	# Grab pool
	my $pool = $globals->{'Pools'}->{$poolMember->{'PoolID'}};

	# Updated pool's last updated timestamp
	$pool->{'LastUpdate'} = $now;

	# Set status to offline so its caught by our garbage collector
	$poolMember->{'Status'} = CFGM_OFFLINE;

	# Update pool members last updated timestamp
	$poolMember->{'LastUpdate'} = $now;

	# Pool member needs updating
	$globals->{'PoolMemberChangeQueue'}->{$poolMember->{'ID'}} = $poolMember;

	# Bump up changes
	$globals->{'StateChanged'}++;

	return;
}



# Function to change a pool member
sub changePoolMember
{
	my $poolMemberData = shift;


	# Check pool member exists first
	if (!isPoolMemberIDValid($poolMemberData->{'ID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool change as there is no 'ID' attribute");
		return;
	}

	my $poolMember = $globals->{'PoolMembers'}->{$poolMemberData->{'ID'}};
	my $pool = $globals->{'Pools'}->{$poolMember->{'PoolID'}};

	my $now = time();

	my $changes = getHashChanges($poolMember,$poolMemberData,[POOLMEMBER_CHANGE_ATTRIBUTES]);

	# Make changes...
	foreach my $item (keys %{$changes}) {
		$poolMember->{$item} = $changes->{$item};
	}

	# Pool member isn't really updated, so we just set the last updated timestamp
	$poolMember->{'LastUpdate'} = $now;
	# Pool was just updated, so update our timestamp
	$pool->{'LastUpdate'} = $now;

	# Bump up changes
	$globals->{'StateChanged'}++;

	# Return what was changed
	return dclone($changes);
}



# Function to return a list of pool ID's
sub getPoolMembers
{
	my $pid = shift;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	# Check our member map is not undefined
	if (!defined($globals->{'PoolMemberMap'}->{$pid})) {
		return;
	}

	return keys %{$globals->{'PoolMemberMap'}->{$pid}};
}



# Function to return a pool member
sub getPoolMember
{
	my $pmid = shift;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	my $poolMember = dclone($globals->{'PoolMembers'}->{$pmid});

	# Remove attributes?
	delete($poolMember->{'.attributes'});

	return $poolMember;
}



# Function to return a list of pool ID's
sub getPoolMemberByUsernameIP
{
	my ($pid,$username,$ipAddress) = @_;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	# Check our member map is not undefined
	if (!defined($globals->{'PoolMemberMap'}->{$pid})) {
		return;
	}

	# Loop with pool members and grab the match, there can only be one as we cannot conflict username and IP
	foreach my $pmid (keys %{$globals->{'PoolMemberMap'}->{$pid}}) {
		my $poolMember = $globals->{'PoolMemberMap'}->{$pid}->{$pmid};

		if ($poolMember->{'Username'} eq $username && $poolMember->{'IPAddress'} eq $ipAddress) {
			return $pmid;
		}
	}

	return;
}



# Function to return pool member ID's with a certain IP address using an interface group
sub getAllPoolMembersByInterfaceGroupIP
{
	my ($interfaceGroupID,$ipAddress) = @_;


	# Make sure both params are defined or we get warnings
	if (!defined($interfaceGroupID) || !defined($ipAddress)) {
		return;
	}

	# Maybe it doesn't exist?
	if (!defined($globals->{'InterfaceGroups'}->{$interfaceGroupID}->{'IPMap'}->{$ipAddress})) {
		return;
	}

	return keys %{$globals->{'InterfaceGroups'}->{$interfaceGroupID}->{'IPMap'}->{$ipAddress}};
}



# Function to check the pool member ID exists
sub isPoolMemberIDValid
{
	my $pmid = shift;


	if (!defined($pmid) || !defined($globals->{'PoolMembers'}->{$pmid})) {
		return;
	}

	return $pmid;
}



# Function to return if a pool member is ready for any kind of modification
sub isPoolMemberReady
{
	my $pmid = shift;


	# Check pool exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	return ($globals->{'PoolMembers'}->{$pmid}->{'Status'} == CFGM_ONLINE && getPoolMemberShaperState($pmid) & SHAPER_LIVE);
}



# Function to return a pool member match priority
sub getPoolMemberMatchPriority
{
	my $pmid = shift;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	# NK: No actual mappping yet, we just return the ID
	return $globals->{'PoolMembers'}->{$pmid}->{'MatchPriorityID'};
}



# Function to set a pool member attribute
sub setPoolMemberAttribute
{
	my ($pmid,$attr,$value) = @_;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	$globals->{'PoolMembers'}->{$pmid}->{'.attributes'}->{$attr} = $value;

	return $value;
}



# Function to set pool member shaper state
sub setPoolMemberShaperState
{
	my ($pmid,$state) = @_;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	$globals->{'PoolMembers'}->{$pmid}->{'.shaper_state'} |= $state;

	return $globals->{'PoolMembers'}->{$pmid}->{'.shaper_state'};
}



# Function to unset pool member shaper state
sub unsetPoolMemberShaperState
{
	my ($pmid,$state) = @_;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	$globals->{'PoolMembers'}->{$pmid}->{'.shaper_state'} &= ~$state;

	return $globals->{'PoolMembers'}->{$pmid}->{'.shaper_state'};
}



# Function to get shaper state for a pool
sub getPoolMemberShaperState
{
	my $pmid = shift;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	return $globals->{'PoolMembers'}->{$pmid}->{'.shaper_state'};
}



# Function to get a pool member attribute
sub getPoolMemberAttribute
{
	my ($pmid,$attr) = @_;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	# Check if attribute exists first
	if (
			!defined($globals->{'PoolMembers'}->{$pmid}->{'.attributes'}) ||
			!defined($globals->{'PoolMembers'}->{$pmid}->{'.attributes'}->{$attr}))
	{
		return;
	}

	return $globals->{'PoolMembers'}->{$pmid}->{'.attributes'}->{$attr};
}



# Function to remove a pool member attribute
sub removePoolMemberAttribute
{
	my ($pmid,$attr) = @_;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	# Check if attribute exists first
	if (
			!defined($globals->{'PoolMembers'}->{$pmid}->{'.attributes'}) ||
			!defined($globals->{'PoolMembers'}->{$pmid}->{'.attributes'}->{$attr}))
	{
		return;
	}

	return delete($globals->{'PoolMembers'}->{$pmid}->{'.attributes'}->{$attr});
}



# Create a limit, which is the combination of a pool and a pool member
sub createLimit
{
	my $limitData = shift;


	# Check if we have all the attributes we need
	my $isInvalid;
	foreach my $attr (LIMIT_REQUIRED_ATTRIBUTES) {
		if (!defined($limitData->{$attr})) {
			$isInvalid = $attr;
			last;
		}
	}
	if ($isInvalid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process limit add as there is an attribute missing: '%s'",$isInvalid);
		return;
	}

	# Check if IP address is defined
	if (!defined(isIPv4($limitData->{'IPAddress'} = $limitData->{'IPAddress'}))) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process limit add as the IP address is invalid");
		return;
	}

	my $poolName = $limitData->{'Username'};
	my $poolData = {
		'FriendlyName' => $limitData->{'IPAddress'},
		'Name' => $poolName,
		'InterfaceGroupID' => $limitData->{'InterfaceGroupID'},
		'TrafficClassID' => $limitData->{'TrafficClassID'},
		'TxCIR' => $limitData->{'TxCIR'},
		'TxLimit' => $limitData->{'TxLimit'},
		'RxCIR' => $limitData->{'RxCIR'},
		'RxLimit' => $limitData->{'RxLimit'},
		'Expires' => $limitData->{'Expires'},
		'Notes' => $limitData->{'Notes'},
		'Source' => $limitData->{'Source'}
	};

	# If we didn't succeed just exit
	my $poolID;
	if (!defined($poolID = createPool($poolData))) {
		return;
	}

	my $poolMemberData = {
		'FriendlyName' => $limitData->{'FriendlyName'},
		'Username' => $limitData->{'Username'},
		'IPAddress' => $limitData->{'IPAddress'},
		'InterfaceGroupID' => $limitData->{'InterfaceGroupID'},
		'MatchPriorityID' => $limitData->{'MatchPriorityID'},
		'PoolID' => $poolID,
		'GroupID' => $limitData->{'GroupID'},
		'Expires' => $limitData->{'Expires'},
		'Notes' => $limitData->{'Notes'},
		'Source' => $limitData->{'Source'}
	};

	my $poolMemberID;
	if (!defined($poolMemberID = createPoolMember($poolMemberData))) {
		return;
	}

	return ($poolMemberID,$poolID);
}



# Function to create a pool override
sub createPoolOverride
{
	my $poolOverrideData = shift;


	# Check that we have at least one match attribute
	my $isValid = 0;
	foreach my $item (POOL_OVERRIDE_MATCH_ATTRIBUTES) {
		$isValid++;
	}
	if (!$isValid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool override as there is no selection attribute");
		return;
	}

	my $poolOverride;

	my $now = time();

	# Pull in attributes
	foreach my $item (POOL_OVERRIDE_ATTRIBUTES) {
		$poolOverride->{$item} = $poolOverrideData->{$item};
	}

	# Check group is OK
	if (defined($poolOverride->{'GroupID'}) && !isGroupIDValid($poolOverride->{'GroupID'})) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process pool override for user '%s', IP '%s', GroupID '%s' as the ".
				"GroupID is invalid",
				prettyUndef($poolOverride->{'Username'}),
				prettyUndef($poolOverride->{'IPAddress'}),
				prettyUndef($poolOverride->{'GroupID'})
		);
		return;
	}

	# Check class is OK
	if (defined($poolOverride->{'TrafficClassID'}) && !isTrafficClassIDValid($poolOverride->{'TrafficClassID'})) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process pool override for user '%s', IP '%s', GroupID '%s' as the ".
				"TrafficClassID is invalid",
				prettyUndef($poolOverride->{'Username'}),
				prettyUndef($poolOverride->{'IPAddress'}),
				prettyUndef($poolOverride->{'GroupID'})
		);
		return;
	}

	# Set source
	$poolOverride->{'Source'} = $poolOverrideData->{'Source'};
	# Set when this entry was created
	$poolOverride->{'Created'} = defined($poolOverrideData->{'Created'}) ? $poolOverrideData->{'Created'} : $now;
	$poolOverride->{'LastUpdate'} = $now;
	# Set when this entry expires
	$poolOverride->{'Expires'} = defined($poolOverrideData->{'Expires'}) ? int($poolOverrideData->{'Expires'}) : 0;
	# Check status is OK
	$poolOverride->{'Status'} = CFGM_NEW;
	# Set friendly name and notes
	$poolOverride->{'FriendlyName'} = $poolOverrideData->{'FriendlyName'};
	# Set notes
	$poolOverride->{'Notes'} = $poolOverrideData->{'Notes'};

	# Create pool member ID
	$poolOverride->{'ID'} = $globals->{'PoolOverrideIDCounter'}++;

	# Add pool override
	$globals->{'PoolOverrides'}->{$poolOverride->{'ID'}} = $poolOverride;

	# Resolve pool overrides
	_resolve_pool_override(undef,[$poolOverride->{'ID'}]);

	# Bump up changes
	$globals->{'StateChanged'}++;

	return $poolOverride->{'ID'};
}



# Function to remove a pool override
sub removePoolOverride
{
	my $poid = shift;


	# Check pool override exists first
	if (!isPoolOverrideIDValid($poid)) {
		return;
	}

	my $poolOverride = $globals->{'PoolOverrides'}->{$poid};

	# Remove pool override from pools that have it and trigger a change
	if (defined($poolOverride->{'.applied_pools'})) {
		foreach my $pid (keys %{$poolOverride->{'.applied_pools'}}) {
			my $pool = $globals->{'Pools'}->{$pid};

			# Remove pool overrides from the pool
			delete($pool->{'.applied_overrides'}->{$poolOverride->{'ID'}});

			# If the pool is online and live, trigger a change
			if ($pool->{'Status'} == CFGM_ONLINE && getPoolShaperState($pid) & SHAPER_LIVE) {
				$globals->{'PoolChangeQueue'}->{$pool->{'ID'}} = $pool;
				$pool->{'Status'} = CFGM_CHANGED;
			}
		}
	}

	# Remove pool override
	delete($globals->{'PoolOverrides'}->{$poolOverride->{'ID'}});

	# Bump up changes
	$globals->{'StateChanged'}++;

	return;
}



# Function to change a pool override
sub changePoolOverride
{
	my $poolOverrideData = shift;


	# Check pool override exists first
	if (!isPoolOverrideIDValid($poolOverrideData->{'ID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool override change as there is no 'ID' attribute");
		return;
	}

	my $poolOverride = $globals->{'PoolOverrides'}->{$poolOverrideData->{'ID'}};

	my $now = time();

	my $changes = getHashChanges($poolOverride,$poolOverrideData,[POOL_OVERRIDE_CHANGE_ATTRIBUTES]);
	# Make changes...
	foreach my $item (keys %{$changes}) {
		$poolOverride->{$item} = $changes->{$item};
	}

	# Set status to updated
	$poolOverride->{'Status'} = CFGM_CHANGED;
	# Set timestamp
	$poolOverride->{'LastUpdate'} = $now;

	# Resolve pool overrides to see if any attributes changed, we only do this if it already matches
	# We do NOT support changing match attributes
	if (defined($poolOverride->{'.applied_pools'}) && (my @pids = keys %{$poolOverride->{'.applied_pools'}}) > 0) {
		_resolve_pool_override([@pids],[$poolOverride->{'ID'}]);
	}

	# Bump up changes
	$globals->{'StateChanged'}++;

	# Return what was changed
	return dclone($changes);
}



# Function to check the pool override ID exists
sub isPoolOverrideIDValid
{
	my $poid = shift;


	if (!defined($poid) || !defined($globals->{'PoolOverrides'}->{$poid})) {
		return;
	}

	return $poid;
}



#
# Internal functions
#


# Resolve all pool overrides or those linked to a pid or oid
# We take 2 optional argument, which is a single pool override and a single pool to process
sub _resolve_pool_override
{
	my ($pids,$poids) = @_;


	# Hack to intercept and create a single element hash if we get ID's above
	my $poolHash;
	if (defined($pids)) {
		foreach my $pid (@{$pids}) {
			$poolHash->{$pid} = $globals->{'Pools'}->{$pid};
		}
	} else {
		$poolHash = $globals->{'Pools'};
	}
	my $poolOverrideHash;
	if (defined($poids)) {
		foreach my $poid (@{$poids}) {
			$poolOverrideHash->{$poid} = $globals->{'PoolOverrides'}->{$poid};
		}
	} else {
		$poolOverrideHash = $globals->{'PoolOverrides'};
	}

	# Loop with all pools, keep a list of pid's updated
	my $matchList;
	while ((my $pid, my $pool) = each(%{$poolHash})) {
		# Build a candidate from the pool
		my $candidate = {
			'PoolName' => $pool->{'Name'},
		};

		# If we only have 1 member in the pool, add its username, IP and group
		if ((my ($pmid) = getPoolMembers($pid)) == 1) {
			my $poolMember = getPoolMember($pmid);
			$candidate->{'Username'} = $poolMember->{'Username'};
			$candidate->{'IPAddress'} = $poolMember->{'IPAddress'};
			$candidate->{'GroupID'} = $poolMember->{'GroupID'};
		}
		# Loop with all pool overrides and generate a match list
		while ((my $poid, my $poolOverride) = each(%{$poolOverrideHash})) {

			my $numMatches = 0;
			my $numMismatches = 0;

			# Loop with the attributes and check for a full match
			foreach my $attr (POOL_OVERRIDE_MATCH_ATTRIBUTES) {

				# If this attribute in the pool override is set, then lets check it
				if (defined($poolOverride->{$attr}) && $poolOverride->{$attr} ne "") {
					# Check for match or mismatch
					if (defined($candidate->{$attr}) && $candidate->{$attr} eq $poolOverride->{$attr}) {
						$numMatches++;
					} else {
						$numMismatches++;
					}
				}
			}

			# Setup the match list with what was matched
			if ($numMatches && !$numMismatches) {
				$matchList->{$pid}->{$poid} = $numMatches;
			} else {
				$matchList->{$pid}->{$poid} = undef;
			}
		}
	}

	# Loop with the match list
	foreach my $pid (keys %{$matchList}) {
		my $pool = $globals->{'Pools'}->{$pid};
		# Original Effective pool
		my $oePool = getEffectivePool($pid);

		# Loop with pool overrides for this pool
		foreach my $poid (keys %{$matchList->{$pid}}) {
			my $poolOverride = $globals->{'PoolOverrides'}->{$poid};

			# If we have a match, record it in pools & pool overrides
			if (defined($matchList->{$pid}->{$poid})) {

				# Setup trakcing of what is applied to what
				$globals->{'PoolOverrides'}->{$poid}->{'.applied_pools'}->{$pid} = $matchList->{$pid}->{$poid};
				$globals->{'Pools'}->{$pid}->{'.applied_overrides'}->{$poid} = $matchList->{$pid}->{$poid};

				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Pool override '%s' [%s] applied to pool '%s' [%s]",
						$poolOverride->{'FriendlyName'},
						$poolOverride->{'ID'},
						$pool->{'Name'},
						$pool->{'ID'}
				);

			# We didn't match, but we may of matched before?
			} else {
				# There was a pool override before, so something changed now that there is none
				if (defined($globals->{'Pools'}->{$pid}->{'.applied_overrides'}->{$poid})) {
					# Remove pool overrides
					delete($globals->{'Pools'}->{$pid}->{'.applied_overrides'}->{$poid});
					delete($globals->{'PoolOverrides'}->{$poid}->{'.applied_pools'}->{$pid});

					$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Pool override '%s' no longer applies to pool '%s' [%s]",
							$poolOverride->{'ID'},
							$pool->{'Name'},
							$pool->{'ID'}
					);
				}
			}
		}
		# New Effective pool
		my $nePool = getEffectivePool($pid);

		# Get changes between effective pool states
		my $poolChanges = getHashChanges($oePool,$nePool,[POOL_OVERRIDE_CHANGESET_ATTRIBUTES]);

		# If there were pool changes, trigger a pool update
		if (keys %{$poolChanges} > 0) {
			# If the pool is currently online and live, trigger a change
			if ($pool->{'Status'} == CFGM_ONLINE && getPoolShaperState($pid) & SHAPER_LIVE) {
				$pool->{'Status'} = CFGM_CHANGED;
				$globals->{'PoolChangeQueue'}->{$pool->{'ID'}} = $pool;
			}
		}
	}
}



# Remove pool override information
sub _remove_pool_override
{
	my $pid = shift;


	if (!isPoolIDValid($pid)) {
		return;
	}

	my $pool = $globals->{'Pools'}->{$pid};

	# Remove pool from pool overrides if there are any
	if (defined($pool->{'.applied_overrides'})) {
		foreach my $poid (keys %{$pool->{'.applied_overrides'}}) {
			delete($globals->{'PoolOverrides'}->{$poid}->{'.applied_pools'}->{$pool->{'ID'}});
		}
	}
}



# Load our statefile
sub _load_statefile
{
	# Check if the state file exists first of all
	if (! -f $config->{'statefile'}) {
		$logger->log(LOG_ERR,"[CONFIGMANAGER] Statefile '%s' doesn't exist",$config->{'statefile'});
		return;
	}
	if (! -s $config->{'statefile'}) {
		$logger->log(LOG_ERR,"[CONFIGMANAGER] Statefile '%s' has zero size ignoring",$config->{'statefile'});
		return;
	}

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Loading statefile '%s'",$config->{'statefile'});

	# Pull in a hash for our statefile
	my %stateHash;
	if (! tie %stateHash, 'Config::IniFiles', ( -file => $config->{'statefile'} )) {
		# Check if we got errors, if we did use them for our reason
		my @errors = @Config::IniFiles::errors;
		my $reason = $1 || join('; ',@errors);

		$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to open statefile '%s': %s",$config->{'statefile'},$reason);

		# Set it to undef so we don't overwrite it...
		if (@errors) {
			$config->{'statefile'} = undef;
		}

		return;
	}

	# Grab the object handle
	my $state = tied( %stateHash );

	# Loop with interface traffic class overrides
	foreach my $section ($state->GroupMembers('interface_traffic_class.override')) {
		my $classOverride = $stateHash{$section};

		# Loop with the persistent attributes and create our hash
		my $cClassOverride;
		foreach my $attr (CLASS_OVERRIDE_PERSISTENT_ATTRIBUTES) {
			if (defined($classOverride->{$attr})) {
				# If its an array, join all the items
				if (ref($classOverride->{$attr}) eq "ARRAY") {
					$classOverride->{$attr} = join("\n",@{$classOverride->{$attr}});
				}
				$cClassOverride->{$attr} = $classOverride->{$attr};
			}
		}

		# XXX - Hack, Proces this class override
		changeInterfaceTrafficClass($cClassOverride);
	}

	# Loop with user pool overrides
	foreach my $section ($state->GroupMembers('pool.override')) {
		my $poolOverride = $stateHash{$section};

		# Loop with the persistent attributes and create our hash
		my $cPoolOverride;
		foreach my $attr (POOL_OVERRIDE_PERSISTENT_ATTRIBUTES) {
			if (defined($poolOverride->{$attr})) {
				# If its an array, join all the items
				if (ref($poolOverride->{$attr}) eq "ARRAY") {
					$poolOverride->{$attr} = join("\n",@{$poolOverride->{$attr}});
				}
				$cPoolOverride->{$attr} = $poolOverride->{$attr};
			}
		}

		# Proces this pool override
		createPoolOverride($cPoolOverride);
	}

	# We need a pool ID translation, when we recreate pools we get different ID's, we cannot restore members with orignal ID's
	my %pidMap;

	# Loop with pools
	foreach my $section ($state->GroupMembers('pool')) {
		my $pool = $stateHash{$section};

		# Loop with the attributes to create the hash
		my $cpool;
		foreach my $attr (POOL_PERSISTENT_ATTRIBUTES) {
			if (defined($pool->{$attr})) {
				# If its an array, join all the items
				if (ref($pool->{$attr}) eq "ARRAY") {
					$pool->{$attr} = join("\n",@{$pool->{$attr}});
				}
				$cpool->{$attr} = $pool->{$attr};
			}
		}

		# Process this pool
		if (defined(my $pid = createPool($cpool))) {
			# Save the new ID
			$pidMap{$pool->{'ID'}} = $pid;
		} else {
			$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to load pool '%s' [%s], members will be ignored",
				prettyUndef($cpool->{'Name'}),
				$section
			);
		}
	}

	# Loop with pool members
	foreach my $section ($state->GroupMembers('pool_member')) {
		my $poolMember = $stateHash{$section};

		# Loop with the attributes to create the hash
		my $cpoolMember;
		foreach my $attr (POOLMEMBER_PERSISTENT_ATTRIBUTES) {
			if (defined($poolMember->{$attr})) {
				# If its an array, join all the items
				if (ref($poolMember->{$attr}) eq "ARRAY") {
					$poolMember->{$attr} = join("\n",@{$poolMember->{$attr}});
				}
				$cpoolMember->{$attr} = $poolMember->{$attr};
			}
		}

		# Translate pool ID
		if (my $pid = $pidMap{$cpoolMember->{'PoolID'}}) {
			$cpoolMember->{'PoolID'} = $pid;
			# Process this pool member
			if (!defined(my $pmid = createPoolMember($cpoolMember))) {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to load pool member '%s'",$pmid);
			}
		} else {
			$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to load pool member '%s', no pool ID map for '%s'",
					$cpoolMember->{'Username'},
					$cpoolMember->{'PoolID'}
			);
		}
	}
}



# Write out statefile
sub _write_statefile
{
	my $fullWrite = shift;


	# We reset this early so we don't get triggred continuously if we encounter errors
	$globals->{'StateChanged'} = 0;
	$globals->{'LastStateSync'} = time();

	# Check if the state file exists first of all
	if (!defined($config->{'statefile'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] No statefile defined. Possible initial load error?");
		return;
	}

	# Only write out if we actually have limits & pool overrides, else we may of crashed?
	if (!(keys %{$globals->{'Pools'}}) && !(keys %{$globals->{'PoolOverrides'}})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Not writing state file as there are no active pools or pool overrides");
		return;
	}

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Saving statefile '%s'",$config->{'statefile'});

	my $timer1 = [gettimeofday];

	# Create new state file object
	my $state = new Config::IniFiles();

	# XXX - Hack, loop with class overrides
	while ((my $itcid, my $interfaceTrafficClass) = each(%{$globals->{'InterfaceTrafficClasses'}})) {
		# Skip over non-overridden classes
		if (!defined($interfaceTrafficClass->{'.applied_overrides'})) {
			next;
		}

		# Create a section name
		my $section = "interface_traffic_class.override " . $itcid;

		# Add a section for this class override
		$state->AddSection($section);
		# XXX - Hack, Attributes we want to save for this traffic class override
		foreach my $attr (CLASS_OVERRIDE_PERSISTENT_ATTRIBUTES) {
			# Set items up
			if (defined(my $value = $interfaceTrafficClass->{$attr})) {
				$state->newval($section,$attr,$value);
			}
		}
		# XXX - Hack, loop with the override
		foreach my $attr (CLASS_OVERRIDE_PERSISTENT_ATTRIBUTES) {
			# Set items up
			if (defined(my $value = $interfaceTrafficClass->{'.applied_overrides'}->{'change'}->{$attr})) {
				$state->newval($section,$attr,$value);
			}
		}
	}

	# Loop with pool overrides
	while ((my $poid, my $poolOverride) = each(%{$globals->{'PoolOverrides'}})) {
		# Create a section name
		my $section = "pool.override " . $poid;

		# Add a section for this pool override
		$state->AddSection($section);
		# Attributes we want to save for this pool override
		foreach my $attr (POOL_OVERRIDE_PERSISTENT_ATTRIBUTES) {
			# Set items up
			if (defined(my $value = $globals->{'PoolOverrides'}->{$poid}->{$attr})) {
				$state->newval($section,$attr,$value);
			}
		}
	}

	# Loop with pools
	while ((my $pid, my $pool) = each(%{$globals->{'Pools'}})) {
		# Skip over dynamic entries, we only want persistent ones unless we doing a full write
		next if (!$fullWrite && $pool->{'Source'} eq "plugin.radius");

		# Create a section name
		my $section = "pool " . $pid;

		# Add a section for this pool
		$state->AddSection($section);
		# Persistent attributes we want
		foreach my $attr (POOL_PERSISTENT_ATTRIBUTES) {
			# Set items up
			if (defined(my $value = $pool->{$attr})) {
				$state->newval($section,$attr,$value);
			}
		}

		# Save pool members too
		foreach my $pmid (keys %{$globals->{'PoolMemberMap'}->{$pid}}) {
			# Create a section name for the pool member
			$section = "pool_member " . $pmid;

			# Add a new section for this pool member
			$state->AddSection($section);

			my $poolMember = $globals->{'PoolMembers'}->{$pmid};

			# Items we want for persistent entries
			foreach my $attr (POOLMEMBER_PERSISTENT_ATTRIBUTES) {
				# Set items up
				if (defined(my $value = $poolMember->{$attr})) {
					$state->newval($section,$attr,$value);
				}
			}
		}
	}

	# Check for an error
	my $newFilename = $config->{'statefile'}.".new";
	if (!defined($state->WriteConfig($newFilename))) {
		$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to write temporary statefile '%s': %s",$newFilename,$!);
		return;
	}

	# If we have a state file, we going to rename it
	my $bakFilename = $config->{'statefile'}.".bak";
	if (-f $config->{'statefile'}) {
		# Check if we could rename/move
		if (!rename($config->{'statefile'},$bakFilename)) {
			$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to rename '%s' to '%s': %s",$config->{'statefile'},$bakFilename,$!);
			return;
		}
	}
	# Move the new filename in place
	if (!rename($newFilename,$config->{'statefile'})) {
		$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to rename '%s' to '%s': %s",$newFilename,$config->{'statefile'},$!);
		return;
	}

	my $timer2 = [gettimeofday];
	my $timediff2 = tv_interval($timer1,$timer2);

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] State file '%s' saved in %s",$config->{'statefile'},sprintf('%.3fs',$timediff2));
}



1;
# vim: ts=4
