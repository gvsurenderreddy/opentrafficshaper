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
use Storable qw( dclone );

use opentrafficshaper::constants;
use opentrafficshaper::logger;
use opentrafficshaper::utils;

# NK: TODO: Maybe we want to remove timing at some stage? maybe not?
use Time::HiRes qw( gettimeofday tv_interval );


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
	createLimit
	getLimit
	getLimits
	getLimitUsername

	getOverride
	getOverrides

	createPool
	getPools
	getPool
	getPoolByIdentifer
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

	getPoolMembers
	getPoolMember
	getPoolMembersByIP
	getPoolMemberMatchPriority
	setPoolMemberShaperState
	unsetPoolMemberShaperState
	getPoolMemberShaperState
	getPoolMemberMatchPriority
	setPoolMemberAttribute
	getPoolMemberAttribute
	removePoolMemberAttribute
	isPoolMemberReady

	getTrafficClasses
	getAllTrafficClasses
	getTrafficClassName
	isTrafficClassIDValid

	getTrafficClassPriority

	getTrafficDirection

	isInterfaceIDValid
	isGroupIDValid

	getInterface
	getInterfaces
	getInterfaceTrafficClasses
	getInterfaceDefaultPool
	getInterfaceRate
	getInterfaceGroup
	getInterfaceGroups
	isInterfaceGroupIDValid

	getMatchPriorities
	isMatchPriorityIDValid
);

use constant {
	VERSION => '0.0.1',

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
		Identifier
		InterfaceGroupID
		ClassID TrafficLimitTx TrafficLimitRx
		Source
	)
}

# Pool attributes that can be changed
sub POOL_CHANGE_ATTRIBUTES {
	qw(
		FriendlyName
		ClassID TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
		Expires
		Notes
	)
}

# Pool persistent attributes
sub POOL_PERSISTENT_ATTRIBUTES {
	qw(
		Identifier
		FriendlyName
		InterfaceGroupID
		ClassID TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
		Expires
		Source
		Notes
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
		ClassID	TrafficLimitTx TrafficLimitRx
		Source
	)
}


# Override match attributes, one is required
sub OVERRIDE_MATCH_ATTRIBUTES {
	qw(
		PoolIdentifier Username IPAddress
		GroupID
	)
}

# Override attributes
sub OVERRIDE_ATTRIBUTES {
	qw(
		FriendlyName
		PoolIdentifier Username IPAddress GroupID
		ClassID TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
		Expires
		Notes
	)
}

# Override attributes that can be changed
sub OVERRIDE_CHANGE_ATTRIBUTES {
	qw(
		FriendlyName
		ClassID TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
		Expires
		Notes
	)
}

# Override changeset attributes
sub OVERRIDE_CHANGESET_ATTRIBUTES {
	qw(
		ClassID TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
	)
}

# Override attributes supported for persistent storage
sub OVERRIDE_PERSISTENT_ATTRIBUTES {
	qw(
		FriendlyName
		PoolIdentifier Username IPAddress GroupID
		ClassID TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
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


# Copy of system globals
my $globals;
my $logger;

# Configuration for this plugin
our $config = {
	# Class to use for unclassified traffic
	'default_pool' => undef,

	# Traffic groups
	'groups' => {
		1 => 'Default'
	},
	# Traffic classes
	'classes' => {
		1 => 'Default'
	},
	# Interfaces
	'interfaces' => {
	},
	# Interface groups
	'interface_groups' => {
	},
	# Match priorities
	'match_priorities' => {
		1 => 'First',
		2 => 'Default',
		3 => 'Fallthrough'
	},
	# State file
	'statefile' => '/var/lib/opentrafficshaper/configmanager.state',
};

# Last time the cleanup ran
my $lastCleanup = time();
# If our state has changed and when last we sync'd to disk
my $stateChanged = 0;
my $lastStateSync = time();


#
# INTERFACES
#
my $interfaceIPMap = {};


#
# POOLS
#
# Parameters:
# * FriendlyName
#    - Used for display purposes
# * Identifier
#    - Unix timestamp when this entry expires, 0 if never
# * ClassID
#    - Class ID
# * InterfaceGroupID
#    - Interface group this pool is attached to
# * TrafficLimitTx
#    - Traffic limit in kbps
# * TrafficLimitRx
#    - Traffic limit in kbps
# * TrafficLimitTxBurst
#    - Traffic bursting limit in kbps
# * TrafficLimitRxBurst
#    - Traffic bursting limit in kbps
# * Notes
#    - Notes on this limit
# * Source
#    - This is the source of the limit, typically plugin.ModuleName
my $pools = { };
my $poolIdentifierMap = { };
my $poolIDCounter = 1;


#
# POOL MEMBERS
#
# Supoprted user attributes:
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
# * ClassID
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
my $poolMembers = { };
my $poolMemberIDCounter = 1;
my $poolMemberMap = { };


#
# OVERRIDES
#
# Selection criteria:
# * PoolIdentifier
#    - Pool identifier
# * Username
#    - Users username
# * IPAddress
#    - Users IP address
# * GroupID
#    - Group ID
#
# Overrides:
# * ClassID
#    - Class ID
# * TrafficLimitTx
#    - Traffic limit in kbps
# * TrafficLimitRx
#    - Traffic limit in kbps
# * TrafficLimitTxBurst
#    - Traffic bursting limit in kbps
# * TrafficLimitRxBurst
#    - Traffic bursting limit in kbps
#
# Parameters:
# * FriendlyName
#    - Used for display purposes
# * Expires
#    - Unix timestamp when this entry expires, 0 if never
# * Notes
#    - Notes on this limit
# * Source
#    - This is the source of the limit, typically plugin.ModuleName
my $overrides = { };
my $overrideIDCounter = 1;


# Global change queues
my $poolChangeQueue = { };
my $poolMemberChangeQueue = { };



# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] OpenTrafficShaper Config Manager v%s - Copyright (c) 2007-2014, AllWorldIT",
			VERSION
	);

	# If we have global config, use it
	my $gconfig = { };
	if (defined($globals->{'file.config'}->{'shaping'})) {
		$gconfig = $globals->{'file.config'}->{'shaping'};
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
		$config->{'groups'}->{$groupID} = $groupName;
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded traffic group '%s' with ID %s.",$groupName,$groupID);
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
		my ($classID,$className) = split(/:/,$class);
		if (!defined(isNumber($classID))) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Traffic class definition '%s' has invalid ID, ignoring",$class);
			next;
		}
		if (!defined($className) || $className eq "") {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Traffic class definition '%s' has invalid name, ignoring",$class);
			next;
		}
		$config->{'classes'}->{$classID} = $className;
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded traffic class '%s' with ID %s",$className,$classID);
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Traffic classes loaded");


	# Load interfaces
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading interfaces...");
	my @interfaces;
	if (defined($globals->{'file.config'}->{'shaping.interface'})) {
		@interfaces = keys %{$globals->{'file.config'}->{'shaping.interface'}};
	} else {
		@interfaces = ( "eth0", "eth1" );
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] No interfaces defined, using 'eth0' and 'eth1'");
	}
	# Loop with interface
	foreach my $interface (@interfaces) {
		# This is the interface config to make things easier for us
		my $iconfig = { };
		# Check if its defined
		if (defined($globals->{'file.config'}->{'shaping.interface'}) &&
				defined($globals->{'file.config'}->{'shaping.interface'}->{$interface})
		) {
			$iconfig = $globals->{'file.config'}->{'shaping.interface'}->{$interface}
		}

		# Check our friendly name for this interface
		if (defined($iconfig->{'name'}) && $iconfig->{'name'} ne "") {
			$config->{'interfaces'}->{$interface}->{'name'} = $iconfig->{'name'};
		} else {
			$config->{'interfaces'}->{$interface}->{'name'} = "$interface (auto)";
			$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '%s' has no 'name' attribute, using '%s (auto)'",
					$interface,$interface
			);
		}

		# Check our interface rate
		if (defined($iconfig->{'rate'}) && $iconfig->{'rate'} ne "") {
			# Check rate is valid
			if (defined(my $rate = isNumber($iconfig->{'rate'}))) {
				$config->{'interfaces'}->{$interface}->{'rate'} = $rate;
			} else {
				$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' has invalid 'rate' attribute, using 100000 instead",
						$interface
				);
			}
		} else {
			$config->{'interfaces'}->{$interface}->{'rate'} = 100000;
			$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '%s' has no 'rate' attribute specified, using 100000",$interface);
		}


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
				my ($iclassID,$iclassCIR,$iclassLimit) = split(/[:\/]/,$iclass);


				if (!defined(isNumber($iclassID))) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class definition '%s' has invalid Class ID, ignoring ".
							"definition",
							$interface,
							$iclass
					);
					next;
				}
				if (!defined($config->{'classes'}->{$iclassID})) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class definition '%s' uses Class ID '%s' which doesn't ".
							"exist",
							$interface,
							$iclass,
							$iclassID
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
							$iclassCIR = int($config->{'interfaces'}->{$interface}->{'rate'} * ($cir / 100));
						} else {
							$iclassCIR = $cir;
						}
					} else {
						$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class '%s' has invalid CIR, ignoring definition",
								$interface,
								$iclassID
						);
						next;
					}
				} else {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class '%s' has missing CIR, ignoring definition",
							$interface,
							$iclassID
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
							$iclassLimit = int($config->{'interfaces'}->{$interface}->{'rate'} * ($Limit / 100));
						} else {
							$iclassLimit = $Limit;
						}
					} else {
						$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class '%s' has invalid Limit, ignoring",
								$interface,
								$iclassID
						);
						next;
					}
				} else {
					$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '%s' class '%s' has missing Limit, using CIR '%s' instead",
							$interface,
							$iclassID,
							$iclassCIR
					);
					$iclassLimit = $iclassCIR;
				}

				# Check if rates are below are sane
				if ($iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'}) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class '%s' has CIR '%s' > interface speed '%s', ".
							"adjusting to '%s'",
							$interface,
							$iclassID,
							$iclassCIR,
							$iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'},
							$iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'}
					);
					$iclassCIR = $iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'};
				}
				if ($iclassLimit > $config->{'interfaces'}->{$interface}->{'rate'}) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class '%s' has Limit '%s' > interface speed '%s', ".
							"adjusting to '%s'",
							$interface,
							$iclassID,
							$iclassCIR,
							$iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'},
							$iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'}
					);
					$iclassLimit = $iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'};
				}
				if ($iclassCIR > $iclassLimit) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' class '%s' has CIR '%s' > Limit '%s', adjusting CIR ".
							"to '%s'",
							$interface,
							$iclassID,
							$iclassLimit,
							$iclassLimit,
							$iclassLimit
					);
					$iclassCIR = $iclassLimit;
				}

				# Build class config
				$config->{'interfaces'}->{$interface}->{'classes'}->{$iclassID} = {
					'cir' => $iclassCIR,
					'limit' => $iclassLimit
				};

				$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded interface '%s' class rate for class ID '%s': %s/%s",
						$interface,
						$iclassID,
						$iclassCIR,
						$iclassLimit
				);
			}

			# Time to check the interface classes
			foreach my $classID (keys %{$config->{'classes'}}) {
				# Check if we have a rate defined for this class in the interface definition
				if (!defined($config->{'interfaces'}->{$interface}->{'classes'}->{$classID})) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '%s' has no class '%s' defined, using interface limit",
							$interface,
							$classID
					);
					$config->{'interfaces'}->{$interface}->{'classes'}->{$classID} = {
						'cir' => $config->{'interfaces'}->{$interface}->{'rate'},
						'limit' => $config->{'interfaces'}->{$interface}->{'rate'}
					};
				}
			}
		}

	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading interfaces completed");

	# Pull in interface groupings
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading interface groups...");
	# Check if we loaded an array or just text
	my @interfaceGroups;
	if (defined($gconfig->{'interface_group'})) {
		if (ref($gconfig->{'interface_group'}) eq "ARRAY") {
			@interfaceGroups = @{$gconfig->{'interface_group'}};
		} else {
			@interfaceGroups = ( $gconfig->{'interface_group'} );
		}
	} else {
		@interfaceGroups = ( "eth1,eth0:Default" );
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] No interface groups, trying default eth1,eth0");
	}
	# Loop with interface groups
	foreach my $interfaceGroup (@interfaceGroups) {
		# Skip comments
		next if ($interfaceGroup =~ /^\s*#/);
		# Split off class ID and class name
		my ($txiface,$rxiface,$friendlyName) = split(/[:,]/,$interfaceGroup);
		if (!defined($config->{'interfaces'}->{$txiface})) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface group definition '%s' has invalid interface '%s', ignoring",
					$interfaceGroup,
					$txiface
			);
			next;
		}
		if (!defined($config->{'interfaces'}->{$rxiface})) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface group definition '%s' has invalid interface '%s', ignoring",
					$interfaceGroup,
					$rxiface
			);
			next;
		}
		if (!defined($friendlyName) || $friendlyName eq "") {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface group definition '%s' has invalid friendly name, ignoring",
					$interfaceGroup,
			);
			next;
		}

		$config->{'interface_groups'}->{"$txiface,$rxiface"} = {
			'name' => $friendlyName,
			'txiface' => $txiface,
			'rxiface' => $rxiface
		};

		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded interface group '%s' with interfaces '%s/%s'",
				$friendlyName,
				$txiface,
				$rxiface
		);
	}

	# Initialize IP address map
	foreach my $interfaceGroupID (keys %{$config->{'interface_groups'}}) {
		# Blank interface IP address map for interface group
		$interfaceIPMap->{$interfaceGroupID} = { };
	}

	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Interface groups loaded");


	# Check if we using a default pool or not
	if (defined($gconfig->{'default_pool'})) {
		# Check if its a number
		if (defined(my $default_pool = isNumber($gconfig->{'default_pool'}))) {
			if (defined($config->{'classes'}->{$default_pool})) {
				$logger->log(LOG_INFO,"[CONFIGMANAGER] Default pool set to use class '%s' (%s)",
						$default_pool,
						$config->{'classes'}->{$default_pool}
				);
				$config->{'default_pool'} = $default_pool;
			} else {
				$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot enable default pool, class '%s' does not exist",
						$default_pool
				);
			}
		} else {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot enable default pool, value for 'default_pool' is invalid");
		}
	}

	# Check if we have a state file
	if (defined(my $statefile = $globals->{'file.config'}->{'system'}->{'statefile'})) {
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

			override_add => \&_session_override_add,
			override_change => \&_session_override_change,
			override_remove => \&_session_override_remove,

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
	$logger->log(LOG_INFO,"[CONFIGMANAGER] Started with %s pools, %s pool members and %s overrides",
			scalar(keys %{$pools}),
			scalar(keys %{$poolMembers}),
			scalar(keys %{$overrides})
	);
}



# Initialize config manager
sub _session_start
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Set our alias
	$kernel->alias_set("configmanager");

	# Load config
	if (-f $config->{'statefile'}) {
		_load_statefile($kernel);
	} else {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Statefile '%s' cannot be opened: %s",$config->{'statefile'},$!);
	}

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
	if ($stateChanged) {
		# The 1 means FULL WRITE of all entries
		_write_statefile(1);
	}

	# Blow away all data
	$globals = undef;

	$interfaceIPMap = { };

	$pools = { };
	$poolIdentifierMap = { };
	$poolIDCounter = 1;

	$poolMembers = { };
	$poolMemberIDCounter = 1;
	$poolMemberMap = { };

	$poolChangeQueue = { };
	$poolMemberChangeQueue = { };

	# XXX: Blow away rest? config?

	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Shutdown");

	$logger = undef;
}


# Time ticker for processing changes
sub _session_tick
{
	my $kernel = $_[KERNEL];


	my $now = time();

	# Check if we should sync state to disk
	if ($stateChanged && $lastStateSync + STATE_SYNC_INTERVAL < $now) {
		_write_statefile();
	}

	# Check if we should cleanup
	if ($lastCleanup + CLEANUP_INTERVAL < $now) {
		# Loop with all overrides and check for expired entries
		while (my ($oid, $override) = each(%{$overrides})) {
			# Override has effectively expired
			if (defined($override->{'Expires'}) && $override->{'Expires'} > 0 && $override->{'Expires'} < $now) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Override '%s' [%s] has expired, removing",
						$override->{'FriendlyName'},
						$oid
				);
				removeOverride($oid);
			}
		}
		# Loop with all pool members and check for expired entries
		while (my ($pmid, $poolMember) = each(%{$poolMembers})) {
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
		while (my ($pid, $pool) = each(%{$pools})) {
			# Pool has effectively expired
			if (defined($pool->{'Expires'}) && $pool->{'Expires'} > 0 && $pool->{'Expires'} < $now) {
				# There are no members, its safe to remove
				if (getPoolMembers($pid) == 0) {
					$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] has expired, removing",
							$pool->{'Identifier'},
							$pid
					);
					removePool($pid);
				}
			}
		}
		# Reset last cleanup time
		$lastCleanup = $now;
	}

	# Loop through pool change queue
	while (my ($pid, $pool) = each(%{$poolChangeQueue})) {

		my $shaperState = getPoolShaperState($pool->{'ID'});

		# Pool is newly added
		if ($pool->{'Status'} == CFGM_NEW) {

			# If the change is not yet live, we should queue it to go live
			if ($shaperState == SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] new and not live, adding to shaper",
						$pool->{'Identifier'},
						$pid
				);
				$kernel->post('shaper' => 'pool_add' => $pid);
				# Set pending online
				setPoolShaperState($pool->{'ID'},SHAPER_PENDING);
				$pool->{'Status'} = CFGM_ONLINE;
				# Remove from queue
				delete($poolChangeQueue->{$pid});
			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' [%s] has UNKNOWN state (CFGM_NEW && !SHAPER_NOTLIVE)");
			}

		# Pool is online but NOTLIVE
		} elsif ($pool->{'Status'} == CFGM_ONLINE) {

			# We've transitioned more than likely from offline, any state to online
			# We don't care if the shaper is pending removal, we going to force re-adding now
			if ($shaperState != SHAPER_LIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] online and not in live state, re-queue as add",
						$pool->{'Identifier'},
						$pid
				);
				$pool->{'Status'} = CFGM_NEW;
			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' [%s] has UNKNOWN state (CFGM_ONLINE && SHAPER_LIVE)",
						$pool->{'Identifier'},
						$pid
				);
			}


		# Pool has been modified
		} elsif ($pool->{'Status'} == CFGM_CHANGED) {

			# If the shaper is live we can go ahead
			if ($shaperState == SHAPER_LIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] has been modified, sending to shaper",
						$pool->{'Identifier'},
						$pid
				);
				$kernel->post('shaper' => 'pool_change' => $pid);
				# Set pending online
				setPoolShaperState($pool->{'ID'},SHAPER_PENDING);
				$pool->{'Status'} = CFGM_ONLINE;
				# Remove from queue
				delete($poolChangeQueue->{$pid});

			} elsif ($shaperState == SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] has been modified but not live, re-queue as add",
						$pool->{'Identifier'},
						$pid
				);
				$pool->{'Status'} = CFGM_NEW;

			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' [%s] has UNKNOWN state (CFGM_CHANGED && !SHAPER_LIVE && ".
						"!SHAPER_NOTLIVE)",
						$pool->{'Identifier'},
						$pid
				);
			}


		# Pool is being removed?
		} elsif ($pool->{'Status'} == CFGM_OFFLINE) {

			# If the change is live, but should go offline, queue it
			if ($shaperState == SHAPER_LIVE) {

				if ($now - $pool->{'LastUpdate'} > 30) {
					# If we still have pool members, we got to abort
					if (!getPoolMembers($pid)) {
						$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] marked offline and stale, removing from shaper",
								$pool->{'Identifier'},
								$pid
						);
						$kernel->post('shaper' => 'pool_remove' => $pid);
						setPoolShaperState($pool->{'ID'},SHAPER_PENDING);
					} else {
						$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] marked offline, but still has pool members, ".
								"aborting remove",
								$pool->{'Identifier'},
								$pid
						);
						$pool->{'Status'} = CFGM_ONLINE;
						delete($poolChangeQueue->{$pid});
					}

				} else {
					# Try remove all our pool members
					if (my @poolMembers = getPoolMembers($pid)) {
						# Loop with members and remove
						foreach my $pmid (@poolMembers) {
							my $poolMember = $poolMembers->{$pmid};
							# Only remove ones online
							if ($poolMember->{'Status'} == CFGM_ONLINE) {
								$logger->log(LOG_INFO,"[CONFIGMANAGER] Pool '%s' [%s] marked offline and fresh, removing pool ".
										"member [%s]",
										$pool->{'Identifier'},
										$pid,
										$pmid
								);
								removePoolMember($pmid);
							}
						}
					} else {
						$logger->log(LOG_INFO,"[CONFIGMANAGER] Pool '%s' [%s] marked offline and fresh, postponing",
								$pool->{'Identifier'},
								$pid
						);
					}
				}

			} elsif ($shaperState == SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' [%s] marked offline and is not live, removing",
						$pool->{'identifier'},
						$pid
				);
				# Remove pool from identifier map
				delete($poolIdentifierMap->{$pool->{'InterfaceGroupID'}}->{$pool->{'Identifier'}});
				# Remove pool member mapping
				delete($poolMemberMap->{$pool->{'ID'}});
				# Remove from queue
				delete($poolChangeQueue->{$pid});
				# Cleanup overrides
				_override_remove_pool($pool->{'ID'});
				# Remove pool
				delete($pools->{$pool->{'ID'}});
			}

		} else {
			$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' [%s] has UNKNOWN state '%s'",
					$pool->{'Identifier'},
					$pid,
					$pool->{'Status'}
			);
		}
	}

	# Loop through pool member change queue
	while (my ($pmid, $poolMember) = each(%{$poolMemberChangeQueue})) {

		my $pool = $pools->{$poolMember->{'PoolID'}};
		my $shaperState = getPoolMemberShaperState($poolMember->{'ID'});

		# Pool is newly added
		if ($poolMember->{'Status'} == CFGM_NEW) {

			# If the change is not yet live, we should queue it to go live
			if ($shaperState == SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] new and not live, adding to shaper",
						$pool->{'Identifier'},
						$poolMember->{'IPAddress'},
						$pmid
				);
				$kernel->post('shaper' => 'poolmember_add' => $pmid);
				# Set pending online
				setPoolMemberShaperState($poolMember->{'ID'},SHAPER_PENDING);
				$poolMember->{'Status'} = CFGM_ONLINE;
				# Remove from queue
				delete($poolMemberChangeQueue->{$pmid});
			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has UNKNOWN state (CFGM_NEW && !SHAPER_NOTLIVE)",
						$pool->{'Identifier'},
						$poolMember->{'IPAddress'},
						$pmid
				);
			}

		# Pool member is online but NOTLIVE
		} elsif ($poolMember->{'Status'} == CFGM_ONLINE) {

			# We've transitioned more than likely from offline, any state to online
			# We don't care if the shaper is pending removal, we going to force re-adding now
			if ($shaperState != SHAPER_LIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] online and not in live state, re-queue as add",
						$pool->{'Identifier'},
						$poolMember->{'IPAddress'},
						$pmid
				);
				$poolMember->{'Status'} = CFGM_NEW;
			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has UNKNOWN state (CFGM_ONLINE && SHAPER_LIVE)",
						$pool->{'Identifier'},
						$poolMember->{'IPAddress'},
						$pmid
				);
			}


		# Pool member has been modified
		} elsif ($poolMember->{'Status'} == CFGM_CHANGED) {

			# If the shaper is live we can go ahead
			if ($shaperState == SHAPER_LIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has been modified, sending to shaper",
						$pool->{'Identifier'},
						$poolMember->{'IPAddress'},
						$pmid
				);
				$kernel->post('shaper' => 'poolmember_change' => $pmid);
				# Set pending online
				setPoolMemberShaperState($poolMember->{'ID'},SHAPER_PENDING);
				$poolMember->{'Status'} = CFGM_ONLINE;
				# Remove from queue
				delete($poolMemberChangeQueue->{$pmid});

			} elsif ($shaperState == SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has been modified but not live, re-queue as ".
						"add",
						$pool->{'Identifier'},
						$poolMember->{'IPAddress'},
						$pmid
				);
				$poolMember->{'Status'} = CFGM_NEW;
			} else {
				$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has UNKNOWN state (CFGM_CHANGED && ".
						"!SHAPER_LIVE && !SHAPER_NOTLIVE)",
						$pool->{'Identifier'},
						$poolMember->{'IPAddress'},
						$pmid
				);
			}


		# Pool is being removed?
		} elsif ($poolMember->{'Status'} == CFGM_OFFLINE) {

			# If the change is live, but should go offline, queue it
			if ($shaperState == SHAPER_LIVE) {

				if ($now - $poolMember->{'LastUpdate'} > 10) {
					$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] marked offline and stale, removing from ".
							"shaper",
							$pool->{'Identifier'},
							$poolMember->{'IPAddress'},
							$pmid
					);
					$kernel->post('shaper' => 'poolmember_remove' => $pmid);
					setPoolMemberShaperState($poolMember->{'ID'},SHAPER_PENDING);
				} else {
					$logger->log(LOG_INFO,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] marked offline and fresh, postponing",
							$pool->{'Identifier'},
							$poolMember->{'IPAddress'},
							$pmid
					);
				}

			} elsif ($shaperState == SHAPER_NOTLIVE) {
				$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] marked offline and is not live, removing",
						$pool->{'Identifier'},
						$poolMember->{'IPAddress'},
						$pmid
				);
				# Unlink interface IP address map
				delete($interfaceIPMap->{$pool->{'InterfaceGroupID'}}->{$poolMember->{'IPAddress'}}->{$poolMember->{'ID'}});
				# Unlink pool map
				delete($poolMemberMap->{$pool->{'ID'}}->{$poolMember->{'ID'}});
				# Remove from queue
				delete($poolMemberChangeQueue->{$pmid});
				# We need to re-process the overrides after the member has been removed
				_override_resolve([$poolMember->{'PoolID'}]);
				# Remove pool member
				delete($poolMembers->{$poolMember->{'ID'}});
			}

		} else {
			$logger->log(LOG_ERR,"[CONFIGMANAGER] Pool '%s' member '%s' [%s] has UNKNOWN state '%s'",
					$pool->{'Identifier'},
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

	$logger->log(LOG_WARN,"[CONFIGMANAGER] Got SIGHUP, ignoring for now");
}


# Event for 'pool_add'
sub _session_pool_add
{
	my ($kernel, $poolData) = @_[KERNEL, ARG0];


	if (!defined($poolData)) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] No pool data provided for 'pool_add' event");
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
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Invalid pool ID '%s' for 'pool_remove' event",prettyUndef($pid));
		return;
	}

	removePool($pid);
}


# Event for 'pool_change'
sub _session_pool_change
{
	my ($kernel, $poolData) = @_[KERNEL, ARG0];


	if (!isPoolIDValid($poolData->{'ID'})) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Invalid pool ID '%s' for 'pool_change' event",prettyUndef($poolData->{'ID'}));
		return;
	}

	changePool($poolData);
}


# Event for 'poolmember_add'
sub _session_poolmember_add
{
	my ($kernel, $poolMemberData) = @_[KERNEL, ARG0];


	if (!defined($poolMemberData)) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] No pool member data provided for 'poolmember_add' event");
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
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Invalid pool member ID '%s' for 'poolmember_remove' event",prettyUndef($pmid));
		return;
	}

	removePoolMember($pmid);
}


# Event for 'poolmember_change'
sub _session_poolmember_change
{
	my ($kernel, $poolMemberData) = @_[KERNEL, ARG0];


	if (!isPoolMemberIDValid($poolMemberData->{'ID'})) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Invalid pool member ID '%s' for 'poolmember_change' event",
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
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] No limit data provided for 'limit_add' event");
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


# Event for 'override_add'
sub _session_override_add
{
	my ($kernel, $overrideData) = @_[KERNEL, ARG0];


	if (!defined($overrideData)) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] No override data provided for 'override_add' event");
		return;
	}

	# Check that we have at least one match attribute
	my $isValid = 0;
	foreach my $item (OVERRIDE_MATCH_ATTRIBUTES) {
		$isValid++;
	}
	if (!$isValid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process override as there is no selection attribute");
		return;
	}

	createOverride($overrideData);
}


# Event for 'override_remove'
sub _session_override_remove
{
	my ($kernel, $oid) = @_[KERNEL, ARG0];


	if (!isOverrideIDValid($oid)) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Invalid override ID '%s' for 'override_remove' event",prettyUndef($oid));
		return;
	}

	removeOverride($oid);
}


# Event for 'override_change'
sub _session_override_change
{
	my ($kernel, $overrideData) = @_[KERNEL, ARG0];


	if (!isOverrideIDValid($overrideData->{'ID'})) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Invalid override ID '%s' for 'override_change' event",
				prettyUndef($overrideData->{'ID'})
		);
		return;
	}

	changeOverride($overrideData);
}


# Function to check the group ID exists
sub isGroupIDValid
{
	my $gid = shift;


	if (defined($config->{'groups'}->{$gid})) {
		return $gid;
	}

	return;
}


# Function to return if an interface ID is valid
sub isInterfaceIDValid
{
	my $iid = shift;


	# Return undef if interface is not valid
	if (!defined($config->{'interfaces'}->{$iid})) {
		return;
	}

	return $iid;
}


# Function to return the configured Interfaces
sub getInterfaces
{
	return [ keys %{$config->{'interfaces'}} ];
}


# Return interface classes
sub getInterface
{
	my $iid = shift;


	# If we have this interface return its classes
	if (!isInterfaceIDValid($iid)) {
		return;
	}

	my $res = dclone($config->{'interfaces'}->{$iid});
	# We don't really want to return classes
	delete($res->{'classes'});
	# And return it...
	return $res;
}


# Return interface traffic classes
sub getInterfaceTrafficClasses
{
	my $iid = shift;


	# If we have this interface return its classes
	if (!isInterfaceIDValid($iid)) {
		return;
	}

	return dclone($config->{'interfaces'}->{$iid}->{'classes'});
}


# Function to return our default pool configuration
sub getInterfaceDefaultPool
{
	my $interface = shift;


	# We don't really need the interface to return the default pool
	return $config->{'default_pool'};
}


# Function to return interface rate
sub getInterfaceRate
{
	my $iid = shift;


	# If we have this interface return its classes
	if (!isInterfaceIDValid($iid)) {
		return;
	}

	return $config->{'interfaces'}->{$iid}->{'rate'};
}


# Function to get interface groups
sub getInterfaceGroups
{
	my $interface_groups = dclone($config->{'interface_groups'});


	return $interface_groups;
}


# Function to check if interface group is valid
sub isInterfaceGroupIDValid
{
	my $igid = shift;


	if (!defined($igid) || !defined($config->{'interface_groups'}->{$igid})) {
		return;
	}

	return $igid;
}


# Function to get an interface group
sub getInterfaceGroup
{
	my $igid = shift;


	if (!isInterfaceGroupIDValid($igid)) {
		return;
	}

	return dclone($config->{'interface_groups'}->{$igid});
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

	$pools->{$pid}->{'.attributes'}->{$attr} = $value;

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
	if (!defined($pools->{$pid}->{'.attributes'}) || !defined($pools->{$pid}->{'.attributes'}->{$attr})) {
		return;
	}

	return $pools->{$pid}->{'.attributes'}->{$attr};
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
	if (!defined($pools->{$pid}->{'.attributes'}) || !defined($pools->{$pid}->{'.attributes'}->{$attr})) {
		return;
	}

	return delete($pools->{$pid}->{'.attributes'}->{$attr});
}


# Function to return a override
sub getOverride
{
	my $oid = shift;


	if (!isOverrideIDValid($oid)) {
		return;
	}

	my $override = dclone($overrides->{$oid});

	return $override;
}


## Function to return a list of override ID's
sub getOverrides
{
	return (keys %{$overrides});
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

	# Now check if the identifier is valid
	if (!defined($pool->{'Identifier'} = $poolData->{'Identifier'})) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Cannot process pool add as Identifier is invalid");
		return;
	}
	# Check interface group ID is OK
	if (!defined($pool->{'InterfaceGroupID'} = isInterfaceGroupIDValid($poolData->{'InterfaceGroupID'}))) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Cannot process pool add for '%s' as the InterfaceGroupID is invalid",
				$pool->{'Identifier'}
		);
		return;
	}
	# If we already have this identifier added, return it as the pool
	if (defined(my $pool = $poolIdentifierMap->{$pool->{'InterfaceGroupID'}}->{$pool->{'Identifier'}})) {
		return $pool->{'ID'};
	}
	# Check class is OK
	if (!defined($pool->{'ClassID'} = isClassIDValid($poolData->{'ClassID'}))) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Cannot process pool add for '%s' as the ClassID is invalid",
				$pool->{'Identifier'}
		);
		return;
	}
	# Make sure things are not attached to the default pool
	if (defined($config->{'default_pool'}) && $pool->{'ClassID'} eq $config->{'default_pool'}) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add for '%s' as the ClassID is the 'default_pool' ClassID",
				$pool->{'Identifier'}
		);
		return;
	}
	# Check traffic limits
	if (!isNumber($pool->{'TrafficLimitTx'} = $poolData->{'TrafficLimitTx'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add for '%s' as the TrafficLimitTx is invalid",
				$pool->{'Identifier'}
		);
		return;
	}
	if (!isNumber($pool->{'TrafficLimitRx'} = $poolData->{'TrafficLimitRx'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process pool add for '%s' as the TrafficLimitRx is invalid",
				$pool->{'Identifier'}
		);
		return;
	}
	# If we don't have burst limits, improvize
	if (!defined($pool->{'TrafficLimitTxBurst'} = $poolData->{'TrafficLimitTxBurst'})) {
		$pool->{'TrafficLimitTxBurst'} = $pool->{'TrafficLimitTx'};
		$pool->{'TrafficLimitTx'} = int($pool->{'TrafficLimitTxBurst'}/4);
	}
	if (!defined($pool->{'TrafficLimitRxBurst'} = $poolData->{'TrafficLimitRxBurst'})) {
		$pool->{'TrafficLimitRxBurst'} = $pool->{'TrafficLimitRx'};
		$pool->{'TrafficLimitRx'} = int($pool->{'TrafficLimitRxBurst'}/4);
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
	$pool->{'ID'} = $poolIDCounter++;

	# Add pool
	$pools->{$pool->{'ID'}} = $pool;

	# Link pool identifier map
	$poolIdentifierMap->{$pool->{'InterfaceGroupID'}}->{$pool->{'Identifier'}} = $pool;
	# Blank our pool member mapping
	$poolMemberMap->{$pool->{'ID'}} = { };

	setPoolShaperState($pool->{'ID'},SHAPER_NOTLIVE);

	# Pool needs updating
	$poolChangeQueue->{$pool->{'ID'}} = $pool;

	# Resolve overrides
	_override_resolve([$pool->{'ID'}]);

	# Bump up changes
	$stateChanged++;

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

	my $pool = $pools->{$pid};

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
	$poolChangeQueue->{$pool->{'ID'}} = $pool;

	# Bump up changes
	$stateChanged++;

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

	my $pool = $pools->{$poolData->{'ID'}};

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
	$poolChangeQueue->{$pool->{'ID'}} = $pool;

	# Bump up changes
	$stateChanged++;

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

	my $pool = dclone($pools->{$pid});

	# Remove attributes?
	delete($pool->{'.attributes'});
	delete($pool->{'.applied_attributes'});

	return $pool;
}


# Function to get a pool member by its identifier
sub getPoolByIdentifer
{
	my ($interfaceGroupID,$identifier) = @_;


	# Make sure both params are defined or we get warnings
	if (!defined($interfaceGroupID) || !defined($identifier)) {
		return;
	}

	# Maybe it doesn't exist?
	if (!defined($poolIdentifierMap->{$interfaceGroupID}) || !defined($poolIdentifierMap->{$interfaceGroupID}->{$identifier})) {
		return;
	}

	return dclone($poolIdentifierMap->{$interfaceGroupID}->{$identifier});
}


# Function to return a list of pool ID's
sub getPools
{
	return (keys %{$pools});
}


# Function to return a pool TX interface
sub getPoolTxInterface
{
	my $pid = shift;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	return $config->{'interface_groups'}->{$pools->{$pid}->{'InterfaceGroupID'}}->{'txiface'};
}


# Function to return a pool RX interface
sub getPoolRxInterface
{
	my $pid = shift;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	return $config->{'interface_groups'}->{$pools->{$pid}->{'InterfaceGroupID'}}->{'rxiface'};
}


# Function to return a pool traffic class ID
sub getPoolTrafficClassID
{
	my $pid = shift;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	return $pools->{$pid}->{'ClassID'};
}


# Function to set pools shaper state
sub setPoolShaperState
{
	my ($pid,$state) = @_;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	$pools->{$pid}->{'.shaper_state'} = $state;

	return $state;
}


# Function to unset pools shaper state
sub unsetPoolShaperState
{
	my ($pid,$state) = @_;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	$pools->{$pid}->{'.shaper_state'} ^= $state;

	return $pools->{$pid}->{'.shaper_state'};
}


# Function to get shaper state for a pool
sub getPoolShaperState
{
	my $pid = shift;


	# Check pool exists first
	if (!isPoolIDValid($pid)) {
		return;
	}

	return $pools->{$pid}->{'.shaper_state'};
}


# Function to check the pool ID exists
sub isPoolIDValid
{
	my $pid = shift;


	if (!defined($pid) || !defined($pools->{$pid})) {
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

	return ($pools->{$pid}->{'Status'} == CFGM_ONLINE && $state == SHAPER_LIVE);
}


# Function to return a pool with any items changed as per overrides
sub getEffectivePool
{
	my $pid = shift;


	my $pool;
	if (!defined($pool = getPool($pid))) {
		return;
	}

	# If we have applied overrides, check out what changes there may be
	if (defined(my $appliedOverrides = $pools->{$pid}->{'.applied_overrides'})) {
		my $overrideSet;

		# Loop with overrides in ascending fashion, least matches to most
		foreach my $oid ( sort { $appliedOverrides->{$a} <=> $appliedOverrides->{$b} } keys %{$appliedOverrides}) {
			my $override = $overrides->{$oid};

			# Loop with attributes and create our override set
			foreach my $attr (OVERRIDE_CHANGESET_ATTRIBUTES) {
				# Set override set attribute if the override has defined it
				if (defined($override->{$attr}) && $override->{$attr} ne "") {
					$overrideSet->{$attr} = $override->{$attr};
				}
			}
		}

		# Set overrides on pool
		if (defined($overrideSet)) {
			foreach my $attr (keys %{$overrideSet}) {
				$pool->{$attr} = $overrideSet->{$attr};
			}
		}
	}

	return $pool;
}


# Function to create a pool member
sub	createPoolMember
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
	if (!defined(isIP($poolMember->{'IPAddress'} = $poolMemberData->{'IPAddress'}))) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Cannot process pool member add as the IPAddress is invalid");
		return;
	}
	# Now check if Username its valid
	if (!defined(isUsername($poolMember->{'Username'} = $poolMemberData->{'Username'}))) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Cannot process pool member add as Username is invalid");
		return;
	}

	# Check pool ID is OK
	if (!defined($poolMember->{'PoolID'} = isPoolIDValid($poolMemberData->{'PoolID'}))) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Cannot process pool member add for '%s' as the PoolID is invalid",
				$poolMemberData->{'Username'}
		);
		return;
	}

	# Grab pool
	my $pool = $pools->{$poolMember->{'PoolID'}};

	# Check match priority ID is OK
	if (!defined($poolMember->{'MatchPriorityID'} = isMatchPriorityIDValid($poolMemberData->{'MatchPriorityID'}))) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Cannot process pool member add for '%s' as the MatchPriorityID is invalid",
				$poolMemberData->{'Username'}
		);
		return;
	}
	# Check group ID is OK
	if (!defined($poolMember->{'GroupID'} = isGroupIDValid($poolMemberData->{'GroupID'}))) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Cannot process pool member add for '%s' as the GroupID is invalid",
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
	$poolMember->{'ID'} = $poolMemberIDCounter++;

	# Add pool member
	$poolMembers->{$poolMember->{'ID'}} = $poolMember;

	# Link interface IP address map
	$interfaceIPMap->{$pool->{'InterfaceGroupID'}}->{$poolMember->{'IPAddress'}}->{$poolMember->{'ID'}} = $poolMember;
	# Link pool map
	$poolMemberMap->{$pool->{'ID'}}->{$poolMember->{'ID'}} = $poolMember;

	# Updated pool's last updated timestamp
	$pool->{'LastUpdate'} = $now;
	# Make sure pool is online and not offlining
	if ($pool->{'Status'} == CFGM_OFFLINE) {
		$pool->{'Status'} = CFGM_ONLINE;
	}

	setPoolMemberShaperState($poolMember->{'ID'},SHAPER_NOTLIVE);

	# Pool member needs updating
	$poolMemberChangeQueue->{$poolMember->{'ID'}} = $poolMember;

	# Resolve overrides, there may of been no pool members, now there is one and we may be able to apply an override
	_override_resolve([$pool->{'ID'}]);

	# Bump up changes
	$stateChanged++;

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

	my $poolMember = $poolMembers->{$pmid};

	# Check if pool member is not already offlining
	if ($poolMember->{'Status'} == CFGM_OFFLINE) {
		return;
	}

	my $now = time();

	# Grab pool
	my $pool = $pools->{$poolMember->{'PoolID'}};

	# Updated pool's last updated timestamp
	$pool->{'LastUpdate'} = $now;

	# Set status to offline so its caught by our garbage collector
	$poolMember->{'Status'} = CFGM_OFFLINE;

	# Update pool members last updated timestamp
	$poolMember->{'LastUpdate'} = $now;

	# Pool member needs updating
	$poolMemberChangeQueue->{$poolMember->{'ID'}} = $poolMember;

	# Bump up changes
	$stateChanged++;

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

	my $poolMember = $poolMembers->{$poolMemberData->{'ID'}};
	my $pool = $pools->{$poolMember->{'PoolID'}};

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
	$stateChanged++;

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
	if (!defined($poolMemberMap->{$pid})) {
		return;
	}

	return keys %{$poolMemberMap->{$pid}};
}


# Function to return a pool member
sub getPoolMember
{
	my $pmid = shift;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	my $poolMember = dclone($poolMembers->{$pmid});

	# Remove attributes?
	delete($poolMember->{'.attributes'});

	return $poolMember;
}


# Function to return pool member ID's with a certain IP address
sub getPoolMembersByIP
{
	my ($interfaceGroupID,$ipAddress) = @_;


	# Make sure both params are defined or we get warnings
	if (!defined($interfaceGroupID) || !defined($ipAddress)) {
		return;
	}

	# Maybe it doesn't exist?
	if (!defined($interfaceIPMap->{$interfaceGroupID}) || !defined($interfaceIPMap->{$interfaceGroupID}->{$ipAddress})) {
		return;
	}

	return keys %{$interfaceIPMap->{$interfaceGroupID}->{$ipAddress}};
}


# Function to check the pool member ID exists
sub isPoolMemberIDValid
{
	my $pmid = shift;


	if (!defined($pmid) || !defined($poolMembers->{$pmid})) {
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

	return ($poolMembers->{$pmid}->{'Status'} == CFGM_ONLINE && getPoolMemberShaperState($pmid) == SHAPER_LIVE);
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
	return $poolMembers->{$pmid}->{'MatchPriorityID'};
}


# Function to set a pool member attribute
sub setPoolMemberAttribute
{
	my ($pmid,$attr,$value) = @_;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	$poolMembers->{$pmid}->{'.attributes'}->{$attr} = $value;

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

	$poolMembers->{$pmid}->{'.shaper_state'} = $state;

	return $state;
}


# Function to unset pool member shaper state
sub unsetPoolMemberShaperState
{
	my ($pmid,$state) = @_;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	$poolMembers->{$pmid}->{'.shaper_state'} ^= $state;

	return $poolMembers->{$pmid}->{'.shaper_state'};
}


# Function to get shaper state for a pool
sub getPoolMemberShaperState
{
	my $pmid = shift;


	# Check pool member exists first
	if (!isPoolMemberIDValid($pmid)) {
		return;
	}

	return $poolMembers->{$pmid}->{'.shaper_state'};
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
	if (!defined($poolMembers->{$pmid}->{'.attributes'}) || !defined($poolMembers->{$pmid}->{'.attributes'}->{$attr})) {
		return;
	}

	return $poolMembers->{$pmid}->{'.attributes'}->{$attr};
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
	if (!defined($poolMembers->{$pmid}->{'.attributes'}) || !defined($poolMembers->{$pmid}->{'.attributes'}->{$attr})) {
		return;
	}

	return delete($poolMembers->{$pmid}->{'.attributes'}->{$attr});
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
	if (!defined(isIP($limitData->{'IPAddress'} = $limitData->{'IPAddress'}))) {
		$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Cannot process limit add as the IP address is invalid");
		return;
	}

	my $poolIdentifier = $limitData->{'Username'};
	my $poolData = {
		'FriendlyName' => $limitData->{'IPAddress'},
		'Identifier' => $poolIdentifier,
		'InterfaceGroupID' => $limitData->{'InterfaceGroupID'},
		'ClassID' => $limitData->{'ClassID'},
		'TrafficLimitTx' => $limitData->{'TrafficLimitTx'},
		'TrafficLimitTxBurst' => $limitData->{'TrafficLimitTxBurst'},
		'TrafficLimitRx' => $limitData->{'TrafficLimitRx'},
		'TrafficLimitRxBurst' => $limitData->{'TrafficLimitRxBurst'},
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


# Function to create a override
sub createOverride
{
	my $overrideData = shift;


	# Check that we have at least one match attribute
	my $isValid = 0;
	foreach my $item (OVERRIDE_MATCH_ATTRIBUTES) {
		$isValid++;
	}
	if (!$isValid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process override as there is no selection attribute");
		return;
	}

	my $override;

	my $now = time();

	# Pull in attributes
	foreach my $item (OVERRIDE_ATTRIBUTES) {
		$override->{$item} = $overrideData->{$item};
	}

	# Check group is OK
	if (defined($override->{'GroupID'}) && !isGroupIDValid($override->{'GroupID'})) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process override for user '%s', IP '%s', GroupID '%s' as the GroupID is ".
				"invalid",
				prettyUndef($override->{'Username'}),
				prettyUndef($override->{'IPAddress'}),
				prettyUndef($override->{'GroupID'})
		);
		return;
	}

	# Check class is OK
	if (defined($override->{'ClassID'}) && !isTrafficClassIDValid($override->{'ClassID'})) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process override for user '%s', IP '%s', GroupID '%s' as the ClassID is ".
				"invalid",
				prettyUndef($override->{'Username'}),
				prettyUndef($override->{'IPAddress'}),
				prettyUndef($override->{'GroupID'})
		);
		return;
	}

	# Set source
	$override->{'Source'} = $overrideData->{'Source'};
	# Set when this entry was created
	$override->{'Created'} = defined($overrideData->{'Created'}) ? $overrideData->{'Created'} : $now;
	$override->{'LastUpdate'} = $now;
	# Set when this entry expires
	$override->{'Expires'} = defined($overrideData->{'Expires'}) ? int($overrideData->{'Expires'}) : 0;
	# Check status is OK
	$override->{'Status'} = CFGM_NEW;
	# Set friendly name and notes
	$override->{'FriendlyName'} = $overrideData->{'FriendlyName'};
	# Set notes
	$override->{'Notes'} = $overrideData->{'Notes'};

	# Create pool member ID
	$override->{'ID'} = $overrideIDCounter++;

	# Add override
	$overrides->{$override->{'ID'}} = $override;

	# Resolve overrides
	_override_resolve(undef,[$override->{'ID'}]);

	# Bump up changes
	$stateChanged++;

	return $override->{'ID'};
}


# Function to remove an override
sub removeOverride
{
	my $oid = shift;


	# Check override exists first
	if (!isOverrideIDValid($oid)) {
		return;
	}

	my $override = $overrides->{$oid};

	# Remove override from pools that have it and trigger a change
	if (defined($override->{'.applied_pools'})) {
		foreach my $pid (keys %{$override->{'.applied_pools'}}) {
			my $pool = $pools->{$pid};

			# Remove overrides from the pool
			delete($pool->{'.applied_overrides'}->{$override->{'ID'}});

			# If the pool is online and live, trigger a change
			if ($pool->{'Status'} == CFGM_ONLINE && getPoolShaperState($pid) == SHAPER_LIVE) {
				$poolChangeQueue->{$pool->{'ID'}} = $pool;
				$pool->{'Status'} = CFGM_CHANGED;
			}
		}
	}

	# Remove override
	delete($overrides->{$override->{'ID'}});

	# Bump up changes
	$stateChanged++;

	return;
}


# Function to change an override
sub changeOverride
{
	my $overrideData = shift;


	# Check override exists first
	if (!isOverrideIDValid($overrideData->{'ID'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process override change as there is no 'ID' attribute");
		return;
	}

	my $override = $overrides->{$overrideData->{'ID'}};

	my $now = time();

	my $changes = getHashChanges($override,$overrideData,[OVERRIDE_CHANGE_ATTRIBUTES]);
	# Make changes...
	foreach my $item (keys %{$changes}) {
		$override->{$item} = $changes->{$item};
	}

	# Set status to updated
	$override->{'Status'} = CFGM_CHANGED;
	# Set timestamp
	$override->{'LastUpdate'} = $now;

	# Resolve overrides to see if any attributes changed, we only do this if it already matches
	# We do NOT support changing match attributes
	if (defined($override->{'.applied_pools'}) && (my @pids = keys %{$override->{'.applied_pools'}}) > 0) {
		_override_resolve([@pids],[$override->{'ID'}]);
	}

	# Bump up changes
	$stateChanged++;

	# Return what was changed
	return dclone($changes);
}


# Function to check the override ID exists
sub isOverrideIDValid
{
	my $oid = shift;


	if (!defined($oid) || !defined($overrides->{$oid})) {
		return;
	}

	return $oid;
}


# Function to get traffic classes
sub getTrafficClasses
{
	my $classes = dclone($config->{'classes'});


	# Remove default pool class if we have one
	if (defined(my $classID = $config->{'default_pool'})) {
		delete($classes->{$classID});
	}

	return $classes;
}


# Function to get all traffic classes
sub getAllTrafficClasses
{
	my $classes = dclone($config->{'classes'});

	return $classes;
}


# Function to get class name
sub getTrafficClassName
{
	my $classID = shift;


	if (!isTrafficClassIDValid($classID)) {
		return;
	}

	return $config->{'classes'}->{$classID};
}


# Function to check if traffic class is valid
sub isTrafficClassIDValid
{
	my $classID = shift;


	if (!defined($classID) || !defined($config->{'classes'}->{$classID})) {
		return;
	}

	return $classID;
}


# Function to return the traffic priority based on a traffic class
sub getTrafficClassPriority
{
	my $classID = shift;


	# Check it exists first
	if (!isTrafficClassIDValid($classID)) {
		return;
	}

	# NK: Short circuit, our ClassID = Priority
	return $classID;
}


#
# Internal functions
#


# Resolve all overrides or those linked to a pid or oid
# We take 2 optional argument, which is a single override and a single pool to process
sub _override_resolve
{
	my ($pids,$oids) = @_;


	# Hack to intercept and create a single element hash if we get ID's above
	my $poolHash;
	if (defined($pids)) {
		foreach my $pid (@{$pids}) {
			$poolHash->{$pid} = $pools->{$pid};
		}
	} else {
		$poolHash = $pools;
	}
	my $overrideHash;
	if (defined($oids)) {
		foreach my $oid (@{$oids}) {
			$overrideHash->{$oid} = $overrides->{$oid};
		}
	} else {
		$overrideHash = $overrides;
	}

	# Loop with all pools, keep a list of pid's updated
	my $matchList;
	while ((my $pid, my $pool) = each(%{$poolHash})) {
		# Build a candidate from the pool
		my $candidate = {
			'PoolIdentifier' => $pool->{'Identifier'},
		};

		# If we only have 1 member in the pool, add its username, IP and group
		if ((my ($pmid) = getPoolMembers($pid)) == 1) {
			my $poolMember = getPoolMember($pmid);
			$candidate->{'Username'} = $poolMember->{'Username'};
			$candidate->{'IPAddress'} = $poolMember->{'IPAddress'};
			$candidate->{'GroupID'} = $poolMember->{'GroupID'};
		}
		# Loop with all overrides and generate a match list
		while ((my $oid, my $override) = each(%{$overrideHash})) {

			my $numMatches = 0;
			my $numMismatches = 0;

			# Loop with the attributes and check for a full match
			foreach my $attr (OVERRIDE_MATCH_ATTRIBUTES) {

				# If this attribute in the override is set, then lets check it
				if (defined($override->{$attr}) && $override->{$attr} ne "") {
					# Check for match or mismatch
					if (defined($candidate->{$attr}) && $candidate->{$attr} eq $override->{$attr}) {
						$numMatches++;
					} else {
						$numMismatches++;
					}
				}
			}

			# Setup the match list with what was matched
			if ($numMatches && !$numMismatches) {
				$matchList->{$pid}->{$oid} = $numMatches;
			} else {
				$matchList->{$pid}->{$oid} = undef;
			}
		}
	}

	# Loop with the match list
	foreach my $pid (keys %{$matchList}) {
		my $pool = $pools->{$pid};
		# Original Effective pool
		my $oePool = getEffectivePool($pid);

		# Loop with overrides for this pool
		foreach my $oid (keys %{$matchList->{$pid}}) {
			my $override = $overrides->{$oid};

			# If we have a match, record it in pools & overrides
			if (defined($matchList->{$pid}->{$oid})) {

				# Setup trakcing of what is applied to what
				$overrides->{$oid}->{'.applied_pools'}->{$pid} = $matchList->{$pid}->{$oid};
				$pools->{$pid}->{'.applied_overrides'}->{$oid} = $matchList->{$pid}->{$oid};

				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Override '%s' [%s] applied to pool '%s' [%s]",
						$override->{'FriendlyName'},
						$override->{'ID'},
						$pool->{'Identifier'},
						$pool->{'ID'}
				);

			# We didn't match, but we may of matched before?
			} else {
				# There was an override before, so something changed now that there is none
				if (defined($pools->{$pid}->{'.applied_overrides'}->{$oid})) {
					# Remove overrides
					delete($pools->{$pid}->{'.applied_overrides'}->{$oid});
					delete($overrides->{$oid}->{'.applied_pools'}->{$pid});

					$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Override '%s' no longer applies to pool '%s' [%s]",
							$override->{'ID'},
							$pool->{'Identifier'},
							$pool->{'ID'}
					);
				}
			}
		}
		# New Effective pool
		my $nePool = getEffectivePool($pid);

		# Get changes between effective pool states
		my $poolChanges = getHashChanges($oePool,$nePool,[OVERRIDE_CHANGESET_ATTRIBUTES]);

		# If there were pool changes, trigger a pool update
		if (keys %{$poolChanges} > 0) {
			# If the pool is currently online and live, trigger a change
			if ($pool->{'Status'} == CFGM_ONLINE && getPoolShaperState($pid) == SHAPER_LIVE) {
				$pool->{'Status'} = CFGM_CHANGED;
				$poolChangeQueue->{$pool->{'ID'}} = $pool;
			}
		}
	}
}


# Remove pool override information
sub _override_remove_pool
{
	my $pid = shift;


	if (!isPoolIDValid($pid)) {
		return;
	}

	my $pool = $pools->{$pid};

	# Remove pool from overrides if there are any
	if (defined($pool->{'.applied_overrides'})) {
		foreach my $oid (keys %{$pool->{'.applied_overrides'}}) {
			delete($overrides->{$oid}->{'.applied_pools'}->{$pool->{'ID'}});
		}
	}
}


# Load our statefile
sub _load_statefile
{
	my $kernel = shift;


	# Check if the state file exists first of all
	if (! -e $config->{'statefile'}) {
		$logger->log(LOG_ERR,"[CONFIGMANAGER] Statefile '%s' doesn't exist",$config->{'statefile'});
		return;
	}

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Loading statefile '%s'",$config->{'statefile'});

	# Pull in a hash for our statefile
	my %stateHash;
	if (! tie %stateHash, 'Config::IniFiles', ( -file => $config->{'statefile'} )) {
		# Check if we got errors, if we did use them for our reason
		my @errors = @Config::IniFiles::errors;
		my $reason = $1 || join('; ',@errors) || "Config file blank?";

		$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to open statefile '%s': %s",$config->{'statefile'},$reason);

		# Set it to undef so we don't overwrite it...
		if (@errors) {
			$config->{'statefile'} = undef;
		}

		return;
	}

	# Grab the object handle
	my $state = tied( %stateHash );

	# Loop with user overrides
	foreach my $section ($state->GroupMembers('override')) {
		my $override = $stateHash{$section};

		# Loop with the persistent attributes and create our hash
		my $coverride;
		foreach my $attr (OVERRIDE_PERSISTENT_ATTRIBUTES) {
			if (defined($override->{$attr})) {
				# If its an array, join all the items
				if (ref($override->{$attr}) eq "ARRAY") {
					$override->{$attr} = join("\n",@{$override->{$attr}});
				}
				$coverride->{$attr} = $override->{$attr};
			}
		}

		# Proces this override
		createOverride($coverride);
	}

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
		createPool($cpool);
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

		# Process this pool member
		createPoolMember($cpoolMember);
	}
}


# Write out statefile
sub _write_statefile
{
	my $fullWrite = shift;


	# We reset this early so we don't get triggred continuously if we encounter errors
	$stateChanged = 0;
	$lastStateSync = time();

	# Check if the state file exists first of all
	if (!defined($config->{'statefile'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] No statefile defined. Possible initial load error?");
		return;
	}

	# Only write out if we actually have limits & overrides, else we may of crashed?
	if (!(keys %{$pools}) && !(keys %{$overrides})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Not writing state file as there are no active pools or overrides");
		return;
	}

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Saving statefile '%s'",$config->{'statefile'});

	my $timer1 = [gettimeofday];

	# Create new state file object
	my $state = new Config::IniFiles();

	# Loop with overrides
	while ((my $oid, my $override) = each(%{$overrides})) {
		# Create a section name
		my $section = "override " . $oid;

		# Add a section for this override
		$state->AddSection($section);
		# Attributes we want to save for this override
		foreach my $attr (OVERRIDE_PERSISTENT_ATTRIBUTES) {
			# Set items up
			if (defined(my $value = $overrides->{$oid}->{$attr})) {
				$state->newval($section,$attr,$value);
			}
		}

	}

	# Loop with pools
	while ((my $pid, my $pool) = each(%{$pools})) {
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
		foreach my $pmid (keys %{$poolMemberMap->{$pid}}) {
			# Create a section name for the pool member
			$section = "pool_member " . $pmid;

			# Add a new section for this pool member
			$state->AddSection($section);

			my $poolMember = $poolMembers->{$pmid};

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
