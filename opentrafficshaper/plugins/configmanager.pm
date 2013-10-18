# OpenTrafficShaper configuration manager
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
		getLimit
		getLimits
		getLimitUsername
		getLimitTxInterface
		getLimitRxInterface
		getLimitMatchPriority
		setLimitAttribute
		getLimitAttribute
		removeLimitAttribute

		getOverride
		getOverrides

		getShaperState
		setShaperState

		getTrafficClasses
		getTrafficClassName
		isTrafficClassValid

		getTrafficPriority

		getTrafficDirection

		getInterface
		getInterfaces
		getInterfaceClasses
		getInterfaceDefaultPool
		getInterfaceRate
		getInterfaceGroups
		isInterfaceGroupValid

		getMatchPriorities
		isMatchPriorityValid
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

# Mandatory config attributes
sub LIMIT_REQUIRED_ATTRIBUTES {
	qw(
		Username IP
		InterfaceGroupID MatchPriorityID
		GroupID ClassID
		TrafficLimitTx TrafficLimitRx
		Status
		Source
	)
}

# Limit Changeset attributes - things that can be changed on the fly in the shaper
sub LIMIT_CHANGESET_ATTRIBUTES {
	qw(
		ClassID
		TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
	)
}

# Persistent attributes supported
sub LIMIT_PERSISTENT_ATTRIBUTES {
	qw(
		Username IP
		InterfaceGroupID MatchPriorityID
		GroupID ClassID
		TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
		FriendlyName Notes
		Expires Created
		Source
	)
}

# Override match attributes, one is required
sub OVERRIDE_MATCH_ATTRIBUTES {
	qw(
		Username IP
		GroupID
	)
}
# Override changeset attributes
sub OVERRIDE_CHANGESET_ATTRIBUTES {
	qw(
		ClassID
		TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
	)
}
# Override attributes supported for persistent storage
sub OVERRIDE_PERSISTENT_ATTRIBUTES {
	qw(
		FriendlyName
		Username IP GroupID
		ClassID TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
		Notes
		Expires Created
		Source
		LastUpdate
	)
}
# Override match criteria
sub OVERRIDE_MATCH_CRITERIA {
	(
		['GroupID'], ['Username'], ['IP'],
		['GroupID','Username'], ['GroupID','IP'],
		['Username','IP'],
		['GroupID','Username','IP'],
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
# LIMITS
#
# Supoprted user attributes:
# * Username
#    - Users username
# * IP
#    - Users IP
# * GroupID
#    - Group ID
# * InterfaceGroupID
#    - Interface group this limit is attached to
# * MatchPriorityID
#    - Match priority on the backend of this limit
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
#    - This is the source of the limit, typically  plugin.ModuleName
my $limitChangeQueue = { };
my $limits = { };
my $limitIPMap = { };
my $limitIDMap = { };
my $limitIDCounter = 1;

#
# OVERRIDES
#
# Selection criteria:
# * Username
#    - Users username
# * IP
#    - Users IP
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
#    - This is the source of the limit, typically  plugin.ModuleName
my $overrideChangeQueue = { };
my $overrides = { };
my $overrideMap = { };
my $overrideIDMap = { };
my $overrideIDCounter = 1;




# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] OpenTrafficShaper Config Manager v".VERSION." - Copyright (c) 2013, AllWorldIT");

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
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Traffic group definition '$group' has invalid ID, ignoring");
			next;
		}
		if (!defined($groupName) || $groupName eq "") {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Traffic group definition '$group' has invalid name, ignoring");
			next;
		}
		$config->{'groups'}->{$groupID} = $groupName;
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded traffic group '$groupName' with ID $groupID.");
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Traffic groups loaded.");


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
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Traffic class definition '$class' has invalid ID, ignoring");
			next;
		}
		if (!defined($className) || $className eq "") {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Traffic class definition '$class' has invalid name, ignoring");
			next;
		}
		$config->{'classes'}->{$classID} = $className;
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded traffic class '$className' with ID $classID.");
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Traffic classes loaded.");


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
			$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '$interface' has no 'name' attribute, using '$interface (auto)'");
		}

		# Check our interface rate
		if (defined($iconfig->{'rate'}) && $iconfig->{'rate'} ne "") {
			# Check rate is valid
			if (defined(my $rate = isNumber($iconfig->{'rate'}))) {
				$config->{'interfaces'}->{$interface}->{'rate'} = $rate;
			} else {
				$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '$interface' has invalid 'rate' attribute, using 100000 instead");
			}
		} else {
			$config->{'interfaces'}->{$interface}->{'rate'} = 100000;
			$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '$interface' has no 'rate' attribute specified, using 100000");
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
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '$interface' class definition '$iclass' has invalid Class ID, ignoring definition");
					next;
				}
				if (!defined($config->{'classes'}->{$iclassID})) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '$interface' class definition '$iclass' uses Class ID '$iclassID' which doesn't exist");
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
						$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '$interface' class '$iclassID' has invalid CIR, ignoring definition");
						next;
					}
				} else {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '$interface' class '$iclassID' has missing CIR, ignoring definition");
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
						$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '$interface' class '$iclassID' has invalid Limit, ignoring");
						next;
					}
				} else {
					$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Interface '$interface' class '$iclassID' has missing Limit, using CIR '$iclassCIR' instead",
							$config->{'interfaces'}->{$interface}->{'rate'});
					$iclassLimit = $iclassCIR;
				}

				# Check if rates are below are sane
				if ($iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'}) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '$interface' class '$iclassID' has CIR '$iclassCIR' > interface speed '%s', adjusting to '%s'",
							$iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'},
							$iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'});
					$iclassCIR = $iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'};
				}
				if ($iclassLimit > $config->{'interfaces'}->{$interface}->{'rate'}) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '$interface' class '$iclassID' has Limit '$iclassLimit' > interface speed '%s', adjusting to '%s'",
							$iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'},
							$iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'});
					$iclassLimit = $iclassCIR > $config->{'interfaces'}->{$interface}->{'rate'};
				}
				if ($iclassCIR > $iclassLimit) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '$interface' class '$iclassID' has CIR '$iclassLimit' > Limit '$iclassLimit', adjusting CIR to '$iclassLimit");
					$iclassCIR = $iclassLimit;
				}

				# Build class config
				$config->{'interfaces'}->{$interface}->{'classes'}->{$iclassID} = {
					'cir' => $iclassCIR,
					'limit' => $iclassLimit
				};

				$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded interface '$interface' class rate for class ID '$iclassID': $iclassCIR/$iclassLimit.");
			}

			# Time to check the interface classes
			foreach my $classID (keys %{$config->{'classes'}}) {
				# Check if we have a rate defined for this class in the interface definition
				if (!defined($config->{'interfaces'}->{$interface}->{'classes'}->{$classID})) {
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface '$interface' has no class '$classID' defined, using interface limit");
					$config->{'interfaces'}->{$interface}->{'classes'}->{$classID} = {
						'cir' => $config->{'interfaces'}->{$interface}->{'rate'},
						'limit' => $config->{'interfaces'}->{$interface}->{'rate'}
					};
				}
			}
		}

	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading interfaces completed.");

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
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface group definition '$interfaceGroup' has invalid interface '$txiface', ignoring");
			next;
		}
		if (!defined($config->{'interfaces'}->{$rxiface})) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface group definition '$interfaceGroup' has invalid interface '$rxiface', ignoring");
			next;
		}
		if (!defined($friendlyName) || $friendlyName eq "") {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Interface group definition '$interfaceGroup' has invalid friendly name, ignoring");
			next;
		}

		$config->{'interface_groups'}->{"$txiface,$rxiface"} = {
			'name' => $friendlyName,
			'txiface' => $txiface,
			'rxiface' => $rxiface
		};

		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded interface group '$friendlyName' with interfaces '$txiface/$rxiface'.");
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Interface groups loaded.");


	# Check if we using a default pool or not
	if (defined($gconfig->{'default_pool'})) {
		# Check if its a number
		if (defined(my $default_pool = isNumber($gconfig->{'default_pool'}))) {
			if (defined($config->{'classes'}->{$default_pool})) {
				$logger->log(LOG_INFO,"[CONFIGMANAGER] Default pool set to use class '$default_pool' (%s)",$config->{'classes'}->{$default_pool});
				$config->{'default_pool'} = $default_pool;
			} else {
				$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot enable default pool, class '$default_pool' does not exist");
			}
		} else {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot enable default pool, value for 'default_pool' is invalid");
		}
	}

	# Check if we have a state file
	if (defined(my $statefile = $globals->{'file.config'}->{'system'}->{'statefile'})) {
		$config->{'statefile'} = $statefile;
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Set statefile to '$statefile'");
	}

	# This is our configuration processing session
	POE::Session->create(
		inline_states => {
			_start => \&session_start,
			_stop => \&session_stop,

			tick => \&session_tick,

			process_limit_change => \&process_limit_change,
			process_limit_remove => \&process_limit_remove,

			process_override_change => \&process_override_change,
			process_override_remove => \&process_override_remove,

			handle_SIGHUP => \&handle_SIGHUP,
		}
	);
}


# Start the plugin
sub plugin_start
{
	$logger->log(LOG_INFO,"[CONFIGMANAGER] Started with ".( keys %{$limitChangeQueue} )." queued items");
}



# Initialize config manager
sub session_start
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Set our alias
	$kernel->alias_set("configmanager");

	# Load config
	if (-f $config->{'statefile'}) {
		_load_statefile($kernel);
	} else {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Statefile '$config->{'statefile'}' cannot be opened: $!");
	}

	# Set delay on config updates
	$kernel->delay(tick => TICK_PERIOD);

	$kernel->sig('HUP', 'handle_SIGHUP');

	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Initialized");
}


# Stop the session
sub session_stop
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
	$limitChangeQueue = { };
	$limits = { };
	$limitIPMap = { };
	$limitIDMap = { };
	$limitIDCounter = 1;

	$overrideChangeQueue = { };
	$overrides = { };
	$overrideMap = { };
	$overrideIDMap = { };
	$overrideIDCounter = 1;
	# XXX: Blow away rest? config?

	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Shutdown");

	$logger = undef;
}


# Time ticker for processing changes
sub session_tick
{
	my $kernel = $_[KERNEL];

	my $now = time();
	my $overridesChanged = 0;

	# Process queues
	if (_process_override_change_queue($kernel)) {
		$overridesChanged++;
	}
	_process_limit_change_queue($kernel);

	# Check if we must run cleanups
	if ($lastCleanup + CLEANUP_INTERVAL < $now) {
		_process_limit_cleanup($kernel);
		# Bump up overridesChanged if something changed
		if (_process_override_cleanup($kernel)) {
			$overridesChanged++;
		}
		$lastCleanup = $now;
	}

	# If overrides changed, we need to reprocess all limits
	if ($overridesChanged) {
		_resolve_overrides_and_post($kernel);
	}

	# Check if we should sync state to disk
	if ($stateChanged && $lastStateSync + STATE_SYNC_INTERVAL < $now) {
		_write_statefile();
	}

	# Reset tick
	$kernel->delay(tick => TICK_PERIOD);
}

# Process limit change
sub process_limit_change
{
	my ($kernel, $limit) = @_[KERNEL, ARG0];

	_process_limit_change($limit);
	_process_limit_change_queue($kernel);
}

# Process limit remove
sub process_limit_remove
{
	my ($kernel, $limit) = @_[KERNEL, ARG0];

	_process_limit_remove($kernel,$limit);
	_process_limit_change_queue($kernel);
}

# Process override change
sub process_override_change
{
	my ($kernel, $override) = @_[KERNEL, ARG0];

	_process_override_change($override);
	# If something changed, reprocess the limits
	if (_process_override_change_queue($kernel)) {
		_resolve_overrides_and_post($kernel);
	}
}

# Process override remove
sub process_override_remove
{
	my ($kernel, $override) = @_[KERNEL, ARG0];

	_process_override_remove($override);
	_process_override_change_queue($kernel);
	_resolve_overrides_and_post($kernel);
}


# Function to check the group ID exists
sub checkGroupID
{
	my $gid = shift;
	if (defined($config->{'groups'}->{$gid})) {
		return $gid;
	}
	return undef;
}


# Function to check interface group ID
sub checkInterfaceGroupID
{
	my $igid = shift;
	if (defined($config->{'interface_groups'}->{$igid})) {
		return $igid;
	}
	return undef;
}


# Function to check the match priority ID exists
sub checkMatchPriorityID
{
	my $mpid = shift;
	if (defined($config->{'match_priorities'}->{$mpid})) {
		return $mpid;
	}
	return undef;
}


# Function to check the class ID exists
sub checkClassID
{
	my $cid = shift;
	if (defined($config->{'classes'}->{$cid})) {
		return $cid;
	}
	return undef;
}


# Return interface classes
sub getInterface
{
	my $interface = shift;

	# If we have this interface return its classes
	if (defined($config->{'interfaces'}->{$interface})) {
		my $res = dclone($config->{'interfaces'}->{$interface});
		# We don't really want to return classes
		delete($config->{'interfaces'}->{$interface}->{'classes'});
		# And return it...
		return $res;
	}
	return undef;
}


# Function to return the configured Interfaces
sub getInterfaces
{
	return [ keys %{$config->{'interfaces'}} ];
}


# Return interface classes
sub getInterfaceClasses
{
	my $interface = shift;

	# If we have this interface return its classes
	if (defined($config->{'interfaces'}->{$interface})) {
		return dclone($config->{'interfaces'}->{$interface}->{'classes'});
	}
	return undef;
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
	my $interface = shift;

	# If we have this interface return its rate
	if (defined($config->{'interfaces'}->{$interface})) {
		return $config->{'interfaces'}->{$interface}->{'rate'};
	}
	return undef;
}


# Function to get interface groups
sub getInterfaceGroups
{
	my $interface_groups = dclone($config->{'interface_groups'});

	return $interface_groups;
}


# Function to check if interface group is valid
sub isInterfaceGroupValid
{
	my $interfaceGroup = shift;
	if (defined($interfaceGroup) && defined($config->{'interface_groups'}->{$interfaceGroup})) {
		return $interfaceGroup;
	}
	return undef;
}


# Function to get match priorities
sub getMatchPriorities
{
	my $match_priorities = dclone($config->{'match_priorities'});

	return $match_priorities;
}


# Function to check if interface group is valid
sub isMatchPriorityValid
{
	my $matchPriority = shift;
	if (defined($matchPriority) && defined($config->{'match_priorities'}->{$matchPriority})) {
		return $matchPriority;
	}
	return undef;
}


# Function to check if the status is ok
sub checkStatus
{
	my $status = shift;
	if ($status eq "new" || $status eq "offline" || $status eq "online" || $status eq "conflict" || $status eq "unknown") {
		return $status
	}
	return undef;
}


# Function to return a limit username
sub getLimitUsername
{
	my $lid = shift;
	if (defined($limits->{$lid})) {
		return $limits->{$lid}->{'Username'};
	}
	return undef;
}


# Function to return a limit TX interface
sub getLimitTxInterface
{
	my $lid = shift;
	if (defined($limits->{$lid})) {
		return $config->{'interface_groups'}->{$limits->{$lid}->{'InterfaceGroupID'}}->{'txiface'};
	}
	return undef;
}


# Function to return a limit RX interface
sub getLimitRxInterface
{
	my $lid = shift;
	if (defined($limits->{$lid})) {
		return $config->{'interface_groups'}->{$limits->{$lid}->{'InterfaceGroupID'}}->{'rxiface'};
	}
	return undef;
}


# Function to return a limit match priority
sub getLimitMatchPriority
{
	my $lid = shift;
	if (defined($limits->{$lid})) {
		# NK: No actual mappping yet
		return $limits->{$lid}->{'MatchPriorityID'};
	}
	return undef;
}


# Function to return a limit
sub getLimit
{
	my $lid = shift;

	if (defined($limits->{$lid})) {
		my %limit = %{$limits->{$lid}};
		return \%limit;
	}
	return undef;
}


# Function to return a list of limit ID's
sub getLimits
{
	return (keys %{$limits});
}


# Function to set a limit attribute
sub setLimitAttribute
{
	my ($lid,$attr,$value) = @_;


	# Only set it if it exists
	if (defined($lid) && defined($limits->{$lid})) {
		$limits->{$lid}->{'attributes'}->{$attr} = $value;
	}
}


# Function to get a limit attribute
sub getLimitAttribute
{
	my ($lid,$attr) = @_;


	# Check if attribute exists first
	if (defined($lid) && defined($limits->{$lid}) && defined($limits->{$lid}->{'attributes'}) && defined($limits->{$lid}->{'attributes'}->{$attr})) {
		return $limits->{$lid}->{'attributes'}->{$attr};
	}
	return undef;
}


# Function to remove a limit attribute
sub removeLimitAttribute
{
	my ($lid,$attr) = @_;


	# Check if attribute exists first
	if (defined($lid) && defined($limits->{$lid}) && defined($limits->{$lid}->{'attributes'}) && defined($limits->{$lid}->{'attributes'}->{$attr})) {
		delete($limits->{$lid}->{'attributes'}->{$attr});
	}
}


# Function to return a override
sub getOverride
{
	my $oid = shift;

	if (defined($oid) && defined($overrides->{$oid})) {
		my %override = %{$overrides->{$oid}};
		return \%override;
	}
	return undef;
}


# Function to return a list of override ID's
sub getOverrides
{
	return (keys %{$overrides});
}


# Function to set shaper state on a limit
sub setShaperState
{
	my ($lid,$state) = @_;

	if (defined($lid) && defined($limits->{$lid})) {
		$limits->{$lid}->{'_shaper.state'} = $state;
	}
	return undef;
}


# Function to get shaper state on a limit
sub getShaperState
{
	my $lid = shift;
	if (defined($lid) && defined($limits->{$lid})) {
		return $limits->{$lid}->{'_shaper.state'};
	}
	return undef;
}


# Function to get traffic classes
sub getTrafficClasses
{
	my $classes = dclone($config->{'classes'});

	return $classes;
}


# Function to get class name
sub getTrafficClassName
{
	my $class = shift;
	if (defined($class) && defined($config->{'classes'}->{$class})) {
		return $config->{'classes'}->{$class};
	}
	return undef;
}


# Function to check if traffic class is valid
sub isTrafficClassValid
{
	my $class = shift;
	if (defined($class) && defined($config->{'classes'}->{$class})) {
		return $class;
	}
	return undef;
}


# Function to return the traffic priority based on a traffic class
sub getTrafficPriority
{
	my $class = shift;
	# NK: Short circuit, our ClassID = Priority
	if (defined($class) && defined($config->{'classes'}->{$class})) {
		return $class;
	}
	return undef;
}


# Handle SIGHUP
sub handle_SIGHUP
{
	my ($kernel, $heap, $signal_name) = @_[KERNEL, HEAP, ARG0];

	$logger->log(LOG_WARN,"[CONFIGMANAGER] Got SIGHUP, ignoring for now");
}



#
# Internal functions
#

# Function to compute the changes between two limits
sub _getAppliedLimitChangeset
{
	my ($orig,$new) = @_;

	my $res;

	# Loop through what can change
	foreach my $item (LIMIT_CHANGESET_ATTRIBUTES) {
		# If new item is defined, and we didn't have a value before, or the new value is different
		if (defined($new->{$item}) && (!defined($orig->{$item}) || $orig->{$item} ne $new->{$item})) {
			# If so record it & make the change
			$res->{$item} = $orig->{$item} = $new->{$item};
		}
	}

	# If we have an override changeset to calculate, lets do it!
	if (defined(my $overrideNew = $orig->{'override'})) {

		# If there is currently a live override
		if (defined(my $overrideLive = $orig->{'_override.live'})) {

			# Loop through everything
			foreach my $item (LIMIT_CHANGESET_ATTRIBUTES) {
				# If we have a new override defined
				if (defined($overrideNew->{$item})) {
					# Check if it differs
			   	   if ($overrideLive->{$item} ne $overrideNew->{$item}) {
					   $res->{$item} = $overrideLive->{$item} = $overrideNew->{$item};
				   }

				# We don't have a new override, but we had one before
				} elsif (defined($overrideLive->{$item})) {
					# If it differs to the main item, then add it to the change list
					if ($overrideLive->{$item} ne $orig->{$item}) {
						$res->{$item} = $orig->{$item};
					}

					# Its no longer live so remove it
					delete($overrideLive->{$item});
				}
			}

		# If there was nothing being overridden and is now...
		} else {
			# Loop and add
			foreach my $item (keys %{$overrideNew}) {
				# If they differ change it
				if ($orig->{$item} ne $overrideNew->{$item}) {
					$res->{$item} = $overrideLive->{$item} = $overrideNew->{$item};
				}
			}
			$orig->{'_override.live'} = $overrideLive;
		}


	# If there is no new override...
	} else {
		# Only if there was indeed one before...
		if (defined(my $overrideLive = $orig->{'_override.live'})) {
			# Make sure we set all the values back
			foreach my $item (keys %{$overrideLive}) {
				$res->{$item} = $orig->{$item};
			}
			# Blow the override away
			delete($orig->{'_override.live'});
		}
	}


	return $res;
}


# This is the real function
sub _process_limit_change
{
	my $limit = shift;


	# Check if we have all the attributes we need
	my $isInvalid;
	foreach my $attr (LIMIT_REQUIRED_ATTRIBUTES) {
		if (!defined($limit->{$attr})) {
			$isInvalid = $attr;
			last;
		}
	}
	if ($isInvalid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process limit change as thre is an attribute missing: '$isInvalid'");
		return;
	}

	# We start off blank so we only pull in whats supported
	my $limitChange;
	if (!defined($limitChange->{'Username'} = $limit->{'Username'})) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process limit change as username is invalid.");
		return;
	}
	$limitChange->{'Username'} = $limit->{'Username'};
	$limitChange->{'IP'} = $limit->{'IP'};
	# Check group is OK
	if (!defined($limitChange->{'GroupID'} = checkGroupID($limit->{'GroupID'}))) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process limit change for '".$limit->{'Username'}."' as the GroupID is invalid.");
		return;
	}
	# Check interface group ID is OK
	if (!defined($limitChange->{'InterfaceGroupID'} = checkInterfaceGroupID($limit->{'InterfaceGroupID'}))) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process limit change for '".$limit->{'Username'}."' as the InterfaceGroupID is invalid.");
		return;
	}
	# Check match priority is OK
	if (!defined($limitChange->{'MatchPriorityID'} = checkMatchPriorityID($limit->{'MatchPriorityID'}))) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process limit change for '".$limit->{'Username'}."' as the MatchPriorityID is invalid.");
		return;
	}
	# Check class is OK
	if (!defined($limitChange->{'ClassID'} = checkClassID($limit->{'ClassID'}))) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process limit change for '".$limit->{'Username'}."' as the ClassID is invalid.");
		return;
	}
	$limitChange->{'TrafficLimitTx'} = $limit->{'TrafficLimitTx'};
	$limitChange->{'TrafficLimitRx'} = $limit->{'TrafficLimitRx'};
	# Take base limits if we don't have any burst values set
	$limitChange->{'TrafficLimitTxBurst'} = $limit->{'TrafficLimitTxBurst'};
	$limitChange->{'TrafficLimitRxBurst'} = $limit->{'TrafficLimitRxBurst'};

	# If we don't have burst limits, set them to the traffic limit, and reset the limit to 25%
	if (!defined($limitChange->{'TrafficLimitTxBurst'})) {
		$limitChange->{'TrafficLimitTxBurst'} = $limitChange->{'TrafficLimitTx'};
		$limitChange->{'TrafficLimitTx'} = int($limitChange->{'TrafficLimitTxBurst'}/4);
	}
	if (!defined($limitChange->{'TrafficLimitRxBurst'})) {
		$limitChange->{'TrafficLimitRxBurst'} = $limitChange->{'TrafficLimitRx'};
		$limitChange->{'TrafficLimitRx'} = int($limitChange->{'TrafficLimitRxBurst'}/4);
	}

	# Set when this entry expires
	$limitChange->{'Expires'} = defined($limit->{'Expires'}) ? int($limit->{'Expires'}) : 0;

	# Set friendly name and notes
	$limitChange->{'FriendlyName'} = $limit->{'FriendlyName'};
	$limitChange->{'Notes'} = $limit->{'Notes'};

	# Set when this entry was created
	$limitChange->{'Created'} = defined($limit->{'Created'}) ? $limit->{'Created'} : time();

	# Check status is OK
	if (!($limitChange->{'Status'} = checkStatus($limit->{'Status'}))) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process user change for '".$limit->{'Username'}."' as the Status is invalid.");
		return;
	}

	$limitChange->{'Source'} = $limit->{'Source'};

	# Create a unique limit identifier
	my $limitID = sprintf('%s/%s',$limit->{'Username'},$limit->{'IP'});
	# If we've not seen it
	my $lid;
	if (!defined($lid = $limitIDMap->{$limitID})) {
		# Give it the next limit ID in the list
		$limitIDMap->{$limitID} = $lid = ++$limitIDCounter;
	}

	# Set the user ID before we post to the change queue
	$limitChange->{'ID'} = $lid;
	$limitChange->{'LastUpdate'} = time();
	# Push change to change queue
	$limitChangeQueue->{$lid} = $limitChange;
}


# Process actual limit removal
sub _process_limit_remove
{
	my ($kernel,$limit) = @_;

	my $lid = $limit->{'ID'};


	# If the entry is not live, remove it
	if ($limit->{'_shaper.state'} == SHAPER_NOTLIVE || $limit->{'_shaper.state'} == SHAPER_PENDING) {
		# Remove from system
		delete($limits->{$lid});
		# Set this UID as no longer using this IP
		# NK: If we try remove it before the limit is actually removed we could get a reconnection causing this value
		#     to be totally gone, which means we not tracking this limit using this IP anymore, not easily solved!!
		delete($limitIPMap->{$limit->{'IP'}}->{$lid});
		# Check if we can delete the IP too
		if (keys %{$limitIPMap->{$limit->{'IP'}}} == 0) {
			delete($limitIPMap->{$limit->{'IP'}});
		}

		# Remove from change queue
		delete($limitChangeQueue->{$lid});

	# If the entry is live, schedule shaper removal
	} elsif ($limit->{'_shaper.state'} == SHAPER_LIVE) {
		# Build a removal...
		my $rlimit = {
			'Username' => $limit->{'Username'},
			'IP' => $limit->{'IP'},
			'Status' => 'offline',
			'LastUpdate' => time(),
		};
		# Queue removal
		$limitChangeQueue->{$lid} = $rlimit;

		# Post removal to shaper
		$kernel->post('shaper' => 'remove' => $lid);
	}
}


# This is the real process_override_change function
sub _process_override_change
{
	my $override = shift;


	# Pull in mandatory items and check if the result is valid
	my $overrideChange;
	my $isValid = 0;
	foreach my $item (OVERRIDE_MATCH_ATTRIBUTES) {
		$overrideChange->{$item} = $override->{$item};
		$isValid++;
	}
	# Make sure we have at least 1
	if (!$isValid) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process override as there is no selection attribute");
		return;
	}

	# Pull in attributes that can be changed
	foreach my $item (OVERRIDE_CHANGESET_ATTRIBUTES) {
		$overrideChange->{$item} = $override->{$item};
	}

	# Check group is OK
	if (defined($overrideChange->{'GroupID'}) && !checkGroupID($overrideChange->{'GroupID'})) {
		$logger->log(LOG_DEBUG,'[CONFIGMANAGER] Cannot process override for "User: %s, IP: %s, GroupID: %s" as the GroupID is invalid.',
			prettyUndef($overrideChange->{'Username'}),prettyUndef($overrideChange->{'IP'}),prettyUndef($overrideChange->{'GroupID'})
		);
		return;
	}

	# Check class is OK
	if (defined($overrideChange->{'ClassID'}) && !checkClassID($overrideChange->{'ClassID'})) {
		$logger->log(LOG_DEBUG,'[CONFIGMANAGER] Cannot process override for "User: %s, IP: %s, GroupID: %s" as the ClassID is invalid.',
			prettyUndef($overrideChange->{'Username'}),prettyUndef($overrideChange->{'IP'}),prettyUndef($overrideChange->{'GroupID'})
		);
		return;
	}

	# Set when this entry expires
	$overrideChange->{'Expires'} = defined($override->{'Expires'}) ? int($override->{'Expires'}) : 0;

	# Set friendly name and notes
	$overrideChange->{'FriendlyName'} = $override->{'FriendlyName'};
	$overrideChange->{'Notes'} = $override->{'Notes'};

	# Set when this entry was created
	$overrideChange->{'Created'} = defined($override->{'Created'}) ? $override->{'Created'} : time();

	$overrideChange->{'LastUpdate'} = time();

	# Create a unique override identifier, FriendlyName is unique
	my $overrideID = $override->{'FriendlyName'};
	# If we've not seen it
	my $oid;
	if (!defined($oid = $overrideIDMap->{$overrideID})) {
		# Give it the next override ID in the list
		$overrideIDMap->{$overrideID} = $oid = ++$overrideIDCounter;
	}
	$overrideChange->{'ID'} = $oid;

	$overrideChangeQueue->{$oid} = $overrideChange;
}


# Process actual override removal
sub _process_override_remove
{
	my $override = shift;
	my $oid = $override->{'ID'};


	# Remove from system
	delete($overrides->{$oid});
	# Remove from change queue
	delete($overrideChangeQueue->{$oid});
	# Remove from map
	delete($overrideMap->{$override->{'GroupID'}}->{$override->{'Username'}}->{$override->{'IP'}});
	if (keys %{$overrideMap->{$override->{'GroupID'}}->{$override->{'Username'}}} < 1) {
		delete($overrideMap->{$override->{'GroupID'}}->{$override->{'Username'}});
	}
	if (keys %{$overrideMap->{$override->{'GroupID'}}} < 1) {
		delete($overrideMap->{$override->{'GroupID'}});
	}
}


# Do the actual limit queue processing
sub _process_limit_change_queue
{
	my $kernel = shift;


	# Now
	my $now = time();

	# Loop with changes in queue
	foreach my $lid (keys %{$limitChangeQueue}) {
		# Changes for limit
		# Minimum required info is:
		# - Username
		# - IP
		# - Status
		# - LastUpdate
		my $climit = $limitChangeQueue->{$lid};

		#
		# LIMIT IN LIST
		#
		if (defined(my $glimit = $limits->{$lid})) {
			my $updateShaper = 0;

			# This is a new limit notification
			if ($climit->{'Status'} eq "new") {
				$logger->log(LOG_INFO,"[CONFIGMANAGER] Limit '$climit->{'Username'}' [$lid], limit already live but new state provided?");
				$updateShaper = 1;

				# Remove from change queue
				delete($limitChangeQueue->{$lid});

			# Online or "ping" status notification
			} elsif ($climit->{'Status'} eq "online") {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Limit '$climit->{'Username'}' [$lid], limit still online");
				$updateShaper = 1;

				# Remove from change queue
				delete($limitChangeQueue->{$lid});

			# Offline notification, this we going to treat specially
			} elsif ($climit->{'Status'} eq "offline") {

				# We first check if this update was received some time ago, and if it exceeds our expire time
				# We don't want to immediately remove a limit, only for him to come back on a few seconds later, the cost in exec()'s
				# would be pretty high
				if ($now - $climit->{'LastUpdate'} > TIMEOUT_EXPIRE_OFFLINE) {

					# Remove entry if no longer live
					if ($glimit->{'_shaper.state'} == SHAPER_NOTLIVE) {
						$logger->log(LOG_INFO,"[CONFIGMANAGER] Limit '$climit->{'Username'}' [$lid] offline and removed from shaper");

						_process_limit_remove($kernel,$glimit);

						# Next record, we don't want to do any updates below
						next;

					# Push to shaper
					} elsif ($glimit->{'_shaper.state'} == SHAPER_LIVE) {
						$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Limit '$climit->{'Username'}' [$lid] offline, queue remove from shaper");

						_process_limit_remove($kernel,$glimit);

					} else {
						$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Limit '$climit->{'Username'}' [$lid], limit in list, but offline now and".
								" expired, still live, waiting for shaper");
					}
				}
			}

			# Update the limit data
			$glimit->{'Status'} = $climit->{'Status'};
			$glimit->{'LastUpdate'} = $climit->{'LastUpdate'};

			# Set these if they exist
			if (defined($climit->{'Expires'})) {
				$glimit->{'Expires'} = $climit->{'Expires'};
			}
			if (defined($climit->{'FriendlyName'})) {
				$glimit->{'FriendlyName'} = $climit->{'FriendlyName'};
			}
			if (defined($climit->{'Notes'})) {
				$glimit->{'Notes'} = $climit->{'Notes'};
			}

			# If the group changed, re-apply the overrides
			# Note: This MUST be done here BEFORE the changeset, so we post the shaper changes after the overrides take effect
			if (defined($climit->{'GroupID'}) && $climit->{'GroupID'} != $glimit->{'GroupID'}) {
				_resolve_overrides($lid);
				$updateShaper = 1;
			}
			# If we need to post a shaper update, its time to calculate the changeset
			if ($updateShaper) {
				# Generate a changeset
				if (my $changeset = _getAppliedLimitChangeset($glimit,$climit)) {
					# Post it
					$kernel->post('shaper' => 'change' => $lid => $changeset);
				}
			}


		# Limit is not in the global list, must be an addition?
		} else {
			# We take new and online notifications the same way here if the limit is not in our global limit list already
		   if (($climit->{'Status'} eq "new" || $climit->{'Status'} eq "online")) {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Processing new limit '$climit->{'Username'}' [$lid]");

				my $updateShaper = 0;

				# We first going to look for IP conflicts...
				my @ipLimits = keys %{$limitIPMap->{$climit->{'IP'}}};
				if (
					# If there is already an entry and its not us ...
					( @ipLimits == 1 && !defined($limitIPMap->{$climit->{'IP'}}->{$lid}) )
					# Or if there is more than 1 entry...
					|| @ipLimits > 1
				) {
					# We not going to post this to the shaper, but we are going to override the status
					$climit->{'Status'} = 'conflict';
					$climit->{'_shaper.state'} = SHAPER_NOTLIVE;
					# Give a bit of info
					my @conflictUsernames;
					foreach my $lid (@ipLimits) {
						push(@conflictUsernames,$limits->{$lid}->{'Username'});
					}
					# Output log line
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process limit '".$climit->{'Username'}."' IP '$climit->{'IP'}' conflicts with limits '".
							join(',',@conflictUsernames)."'.");

					# We cannot trust shaping when there is more than 1 limit on the IP, so we going to remove all limits with this
					# IP from the shaper below...
					foreach my $lid2 (@ipLimits) {
						# Check if the limit has been setup already (all but the limit we busy with, as its setup below)
						if (defined($limitIPMap->{$climit->{'IP'}}->{$lid2})) {
							my $glimit2 = $limits->{$lid2};

							# If the limit is active or pending on the shaper, remove it
							if ($glimit2->{'_shaper.state'} == SHAPER_LIVE || $glimit2->{'_shaper.state'} == SHAPER_PENDING) {
								$logger->log(LOG_WARN,"[CONFIGMANAGER] Removing conflicted limit '".$glimit2->{'Username'}."' [$lid2] from shaper'");
								# Post removal to shaper, these are already in the shaper, so this is why we do it here and not after the overrides below
								$kernel->post('shaper' => 'remove' => $lid2);
								# Update that we're offline directly to global limit table
								$glimit2->{'Status'} = 'conflict';
							}
						}
					}

				# All looks good, no conflicts, we're set to add this limit!
				} else {
					# Post to the limit to the shaper
					$climit->{'_shaper.state'} = SHAPER_PENDING;
					$updateShaper = 1;
				}

				# Set this UID as using this IP
				$limitIPMap->{$climit->{'IP'}}->{$lid} = 1;

				# This is now live
				$limits->{$lid} = $climit;

				# Resolve this limit's overrides, this works on the GLOBAL $limits!!
				_resolve_overrides($lid);

				# Just to keep things in the right order
				if ($updateShaper) {
					# We need a hack to blank the current shaping items so we can generate an initial changeset below
					# dlimit - all attrs,  climit - our own limit, with attrs removed
					my $dlimit; %{$dlimit} = %{$climit};
					foreach my $item (LIMIT_CHANGESET_ATTRIBUTES) {
						delete($climit->{$item});
					}
					my $changeset = _getAppliedLimitChangeset($climit,$dlimit);
					$kernel->post('shaper' => 'add' => $lid => $changeset);
				}

			# Limit is not in our list and this is an unknown state we're trasitioning to
			} else {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Ignoring limit '$climit->{'Username'}' [$lid] state '$climit->{'Status'}', not in our".
						" global list");
			}

			# Remove from change queue
			delete($limitChangeQueue->{$lid});
		}

		# Well, we changed something...
		$stateChanged++;
	}


}


# Process cleanup of limits
sub _process_limit_cleanup
{
	my $kernel = shift;


	my $now = time();

	# Loop with limits and check for expired entries
	while ((my $lid, my $glimit) = each(%{$limits})) {
		# Check for expired limits
		if ($glimit->{'Expires'} && $glimit->{'Expires'} < $now) {
			$logger->log(LOG_INFO,"[CONFIGMANAGER] Limit '$glimit->{'Username'}' has expired, marking offline");
			# Looks like this limit has expired?
			my $climit = {
				'Username' => $glimit->{'Username'},
				'IP' => $glimit->{'IP'},
				'Status' => 'offline',
				'LastUpdate' => $glimit->{'LastUpdate'},
			};
			# Add to change queue
			$limitChangeQueue->{$lid} = $climit;
		}
	}
}


# Do the actual override queue processing
# This function returns 1 if it made a change, 0 if not
sub _process_override_change_queue
{
	my $kernel = shift;


	# Now
	my $now = time();

	# Overrides changed
	my $overridesChanged = 0;

	# Loop with override change queue
	foreach my $oid (keys %{$overrideChangeQueue}) {
		my $coverride = $overrideChangeQueue->{$oid};

		# Blank attributes not specified
		foreach my $attr (OVERRIDE_MATCH_ATTRIBUTES) {
			if (!defined($coverride->{$attr})) {
				$coverride->{$attr} = '';
			}
		}

		# This is now live
		$overrides->{$oid} = $coverride;
		$overrideMap->{$coverride->{'GroupID'}}->{$coverride->{'Username'}}->{$coverride->{'IP'}} = $coverride;

		# Remove from change queue
		delete($overrideChangeQueue->{$oid});

		$overridesChanged = 1;

		# Something changed...
		$stateChanged++;
	}

	return $overridesChanged;
}


# Process cleanup of overrides
# This function returns 1 if it made a change, 0 if not
sub _process_override_cleanup
{
	my $overridesChanged = 0;


	my $now = time();

	# Check for expired overides
	while ((undef, my $goverride) = each(%{$overrides})) {
		# Check for expired overrides
		if ($goverride->{'Expires'} && $goverride->{'Expires'} < $now) {
			$logger->log(LOG_INFO,"[CONFIGMANAGER] Override 'Username: %s, IP: %s' has expired, removing",
				$goverride->{'Username'},
				$goverride->{'IP'},
			);

			# Remove the override
			_process_override_remove($goverride);

			$overridesChanged = 1;
		}
	}

	return $overridesChanged;
}



# This function calls _resolve_overrides() plus posts events to the shaper
sub _resolve_overrides_and_post
{
	my ($kernel,$lid) = @_;


	# Check if any items actually were changed
	my @changed;
	if (!(@changed = _resolve_overrides())) {
		return;
	}

	# If so generate a changeset, with no limit change (resolves overrides internally) and post it
	foreach my $lid (@changed) {
		# Get our changeset, with no limit applied to it
		if (my $changeset = _getAppliedLimitChangeset($limits->{$lid},{})) {
			# Post to shaper
			$kernel->post('shaper' => 'change' => $lid => $changeset);
		}
	}
}


# Resolve all overrides and post limit changes if any match
# We take 1 optional argument, which is a single limit to process
sub _resolve_overrides
{
	my $lid = shift;


	# Hack to intercept and create a single element hash
	my $limitHash;
	if (defined($lid)) {
		$limitHash->{$lid} = $limits->{$lid};
	} else {
		$limitHash = $limits;
	}

	# Loop with all limits, keep a list of lid's updated
	my @overridden;
	while ((my $lid, my $limit) = each(%{$limitHash})) {
		my $overrideResult;

		# Loop with the attributes in matching order
		foreach my $attrSet (OVERRIDE_MATCH_CRITERIA) {
			# Start with a blank match
			my $criteria = { 'GroupID' => '', 'Username' => '', 'IP' => '' };

			# Build match from user
			foreach my $attr (@{$attrSet}) {
				if ($attr ne '') {
					$criteria->{$attr} = $limit->{$attr};
				}
			}

			# Check for match
			if (
					defined($overrideMap->{$criteria->{'GroupID'}}) && defined($overrideMap->{$criteria->{'GroupID'}}->{$criteria->{'Username'}}) &&
					defined(my $moverride = $overrideMap->{$criteria->{'GroupID'}}->{$criteria->{'Username'}}->{$criteria->{'IP'}})
			) {
				# Apply attributes to override result
				foreach my $attr (OVERRIDE_CHANGESET_ATTRIBUTES) {
					# Merge in attribute if the matched override has it set
					if (defined($moverride->{$attr})) {
						$overrideResult->{$attr} = $moverride->{$attr};
					}
				}
			}
		}

		# if we have an override result, it means we matched something
		# If we don't have an overrideResult, and we had one, it means something changed too
		if (defined($overrideResult) || defined($limit->{'override'})) {
			push(@overridden,$lid);
		}

		$limit->{'override'} = $overrideResult;
	}

	return @overridden;
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
		my $reason = $1 || "Config file blank?";
		$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to open statefile '".$config->{'statefile'}."': $reason");
		# NK: Breaks load on blank file
		# Set it to undef so we don't overwrite it...
		#$config->{'statefile'} = undef;
		return;
	}
	# Grab the object handle
	my $state = tied( %stateHash );

	# Loop with user overrides
	foreach my $section ($state->GroupMembers('override')) {
		my $override = $stateHash{$section};

		# Our user override
		my $coverride;
		foreach my $attr (OVERRIDE_PERSISTENT_ATTRIBUTES) {
			if (defined($override->{$attr})) {
				$coverride->{$attr} = $override->{$attr};
			}
		}

		# Proces this override
		_process_override_change($coverride);
	}

	# Loop with persistent limits
	foreach my $section ($state->GroupMembers('persist')) {
		my $user = $stateHash{$section};

		# User to push through to process change
		my $cuser;
		foreach my $attr (LIMIT_PERSISTENT_ATTRIBUTES) {
			if (defined($user->{$attr})) {
				$cuser->{$attr} = $user->{$attr};
			}
		}
		# This is a new entry
		$cuser->{'Status'} = 'new';

		# Check username & IP are defined
		if (!defined($cuser->{'Username'}) || !defined($cuser->{'IP'})) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to load persistent user with no username or IP '$section'");
			next;
		}

		# Process this user
		_process_limit_change($cuser);
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
	if (keys %{$limits} < 1 && keys %{$overrides} < 1) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] Not writing state file as there are no active limits or overrides");
		return;
	}

	my $timer1 = [gettimeofday];

	# Create new state file object
	my $state = new Config::IniFiles();

	# Loop with persistent limits, these are limits with expires = 0
	while ((undef, my $limit) = each(%{$limits})) {
		# Skip over dynamic entries, we only want persistent ones unless we doing a full write
		next if (!$fullWrite && $limit->{'Source'} eq "plugin.radius");

		# Pull in the section name
		my $section = "persist " . $limit->{'Username'};

		# Add a new section for this user
		$state->AddSection($section);
		# Items we want for persistent entries
		foreach my $pItem (LIMIT_PERSISTENT_ATTRIBUTES) {
			# Set items up
			if (defined(my $value = $limit->{$pItem})) {
				$state->newval($section,$pItem,$value);
			}
		}
	}

	# Loop with overrides
	foreach my $oid (keys %{$overrides}) {
		# Pull in the section name
		my $section = "override " . $oid;

		# Add a new section for this user
		$state->AddSection($section);
		# Items we want for override entries
		foreach my $pItem (OVERRIDE_PERSISTENT_ATTRIBUTES) {
			# Set items up
			if (defined(my $value = $overrides->{$oid}->{$pItem})) {
				$state->newval($section,$pItem,$value);
			}
		}

	}

	# Check for an error
	my $newFilename = $config->{'statefile'}.".new";
	if (!defined($state->WriteConfig($newFilename))) {
		$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to write temporary statefile '$newFilename': $!");
		return;
	}

	# If we have a state file, we going to rename it
	my $bakFilename = $config->{'statefile'}.".bak";
	if (-f $config->{'statefile'}) {
		# Check if we could rename/move
		if (!rename($config->{'statefile'},$bakFilename)) {
			$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to rename '%s' to '$bakFilename': $!",$config->{'statefile'});
			return;
		}
	}
	# Move the new filename in place
	if (!rename($newFilename,$config->{'statefile'})) {
		$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to rename '$newFilename' to '%s': $!",$config->{'statefile'});
		return;
	}

	my $timer2 = [gettimeofday];
	my $timediff2 = tv_interval($timer1,$timer2);

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] State file '%s' saved in %s",$config->{'statefile'},sprintf('%.3fs',$timediff2));
}


1;
# vim: ts=4
