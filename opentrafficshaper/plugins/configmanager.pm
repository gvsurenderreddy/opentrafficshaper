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
		getLimit
		getLimits
		getLimitUsername
		setLimitAttribute
		getLimitAttribute

		getShaperState
		setShaperState

		getTrafficClasses

		getPriorityName
);

use constant {
	VERSION => '0.0.1',

	# After how long does a limit get removed if its's deemed offline
	TIMEOUT_EXPIRE_OFFLINE => 300,

	# How often our config check ticks
	TICK_PERIOD => 5,

};

# Mandatory config attributes
sub CONFIG_ATTRIBUTES {
	qw(
		Username IP
		GroupID ClassID
		TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
		Expires Status
		Source
	)
}

# Changeset attributes - things that can be changed on the fly
sub CHANGESET_ATTRIBUTES {
	qw(
		GroupID ClassID
		TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
		Expires
	)
}

# Persistent attributes supported
sub PERSISTENT_ATTRIBUTES {
	qw(
		Username IP
		GroupID ClassID
		TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
		Expires Created
		Source
	)
}

# Override attributes supported
sub OVERRIDE_ATTRIBUTES {
	qw(
		Username IP
		GroupID ClassID
		TrafficLimitTx TrafficLimitRx TrafficLimitTxBurst TrafficLimitRxBurst
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
my $config = {
	# Use default pool for unclassified traffic
	'use_default_pool' => 0,
	'default_pool_txrate' => undef,
	'default_pool_rxrate' => undef,
	'default_pool_priority' => 10,
	# Traffic groups
	'groups' => {
		1 => 'Default'
	},
	# Traffic classes
	'classes' => {
		1 => 'Default'
	},
	# State file
	'statefile' => '/var/lib/opentrafficshaper/configmanager.state',
};


# Pending changes
my $changeQueue = { };

# Main variables handling our limits
my $limits = { };
my $limitIPMap = { };
my $limitIDMap = { };
my $limitIDCounter = 1;
my $overrides = { };


# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] OpenTrafficShaper Config Manager v".VERSION." - Copyright (c) 2013, AllWorldIT");

	# Split off groups to load
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading traffic groups...");
	# Check if we loaded an array or just text
	my @groups = ref($globals->{'file.config'}->{'shaping'}->{'group'}) eq "ARRAY" ? @{$globals->{'file.config'}->{'shaping'}->{'group'}} :
			( $globals->{'file.config'}->{'shaping'}->{'group'} );
	# Loop with groups
	foreach my $group (@groups) {
		# Skip comments
		next if ($group =~ /^\s*#/);
		# Split off group ID and group name
		my ($groupID,$groupName) = split(/:/,$group);
		if (!defined($groupID) || int($groupID) < 1) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to load traffic group definition '$group': ID is invalid");
			next;
		}
		if (!defined($groupName) || $groupName eq "") {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to load traffic group definition '$group': Name is invalid");
			next;
		}
		$config->{'groups'}->{$groupID} = $groupName;
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded traffic group '$groupName' with ID $groupID.");
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading traffic groups completed.");

	# Split off traffic classes
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading traffic classes...");
	# Check if we loaded an array or just text
	my @classes = ref($globals->{'file.config'}->{'shaping'}->{'class'}) eq "ARRAY" ? @{$globals->{'file.config'}->{'shaping'}->{'class'}} :
			( $globals->{'file.config'}->{'shaping'}->{'class'} );
	# Loop with classes
	foreach my $class (@classes) {
		# Skip comments
		next if ($class =~ /^\s*#/);
		# Split off class ID and class name
		my ($classID,$className) = split(/:/,$class);
		if (!defined($classID) || int($classID) < 1) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to load traffic class definition '$class': ID is invalid");
			next;
		}
		if (!defined($className) || $className eq "") {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to load traffic class definition '$class': Name is invalid");
			next;
		}
		$config->{'classes'}->{$classID} = $className;
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded traffic class '$className' with ID $classID.");
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading traffic classes completed.");

	# Check if we using a default pool or not
	if (defined(my $dp = booleanize($globals->{'file.config'}->{'shaping'}->{'use_default_pool'}))) {
		# If we are using the default pool, load the limits
		if ($config->{'use_default_pool'} = $dp) {
			# Pull in both config items
			if (defined(my $txir = $globals->{'file.config'}->{'shaping'}->{'default_pool_txrate'})) {
				$logger->log(LOG_INFO,"[CONFIGMANAGER] Set default_pool_txrate to '$txir'");
				$config->{'default_pool_txrate'} = isNumber($txir);
			} else {
				$logger->log(LOG_WARN,"[CONFIGMANAGER] There is a problem with default_pool_txrate, config item use_default_pool disabled");
			}
			if (defined(my $rxir = $globals->{'file.config'}->{'shaping'}->{'default_pool_rxrate'})) {
				$logger->log(LOG_INFO,"[CONFIGMANAGER] Set default_pool_rxrate to '$rxir'");
				$config->{'default_pool_rxrate'} = isNumber($rxir);
			} else {
				$logger->log(LOG_WARN,"[CONFIGMANAGER] There is a problem with default_pool_rxrate, config item use_default_pool disabled");
			}
			# Check we have both items configured, if not deconfigure
			if (!defined($config->{'default_pool_txrate'}) || !defined($config->{'default_pool_rxrate'})) {
				$config->{'use_default_pool'} = 0;
			}
		}
	}
	$logger->log(LOG_INFO,"[CONFIGMANAGER] Using of default pool ". ( $config->{'use_default_pool'} ?
			"ENABLED with rates $config->{'default_pool_txrate'}/$config->{'default_pool_rxrate'}" : "DISABLED" )  );

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
			process_change => \&process_change,

			handle_SIGHUP => \&handle_SIGHUP,
		}
	);
}


# Start the plugin
sub plugin_start
{
	$logger->log(LOG_INFO,"[CONFIGMANAGER] Started with ".( keys %{$changeQueue} )." queued items");
}



# Initialize config manager
sub session_start
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Set our alias
	$kernel->alias_set("configmanager");

	# Load config
	if (-f $config->{'statefile'}) {
		_load_statefile();
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

	_write_statefile();

	# Blow away all data
	$globals = undef;
	$changeQueue = { };
	$limits = { };
	$limitIPMap = { };
	$limitIDMap = { };
	$limitIDCounter = 1;
	$overrides = { };
	# XXX: Blow away rest? config?

	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Shutdown");

	$logger = undef;
}


# Time ticker for processing changes
sub session_tick {
	my $kernel = $_[KERNEL];


	# Now
	my $now = time();


	#
	# LOOP WITH CHANGES
	#

	foreach my $lid (keys %{$changeQueue}) {
		# Changes for limit
		# Minimum required info is:
		# - Username
		# - IP
		# - Status
		# - LastUpdate
		my $climit = $changeQueue->{$lid};

		#
		# LIMIT IN LIST
		#
		if (defined(my $glimit = $limits->{$lid})) {

			# This is a new limit notification
			if ($climit->{'Status'} eq "new") {
				$logger->log(LOG_INFO,"[CONFIGMANAGER] Limit '$climit->{'Username'}' [$lid], limit already live but new state provided?");

				# Get the changes we made and push them to the shaper
				if (my $changes = _getChangeset($glimit,$climit)) {
					# Post to shaper
					$kernel->post("shaper" => "change" => $lid => $changes);
				}

				# Remove from change queue
				delete($changeQueue->{$lid});

			# Online or "ping" status notification
			} elsif ($climit->{'Status'} eq "online") {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Limit '$climit->{'Username'}' [$lid], limit still online");

				# Get the changes we made and push them to the shaper
				if (my $changes = _getChangeset($glimit,$climit)) {
					# Post to shaper
					$kernel->post("shaper" => "change" => $lid => $changes);
				}

				# Remove from change queue
				delete($changeQueue->{$lid});

			# Offline notification, this we going to treat specially
			} elsif ($climit->{'Status'} eq "offline") {

				# We first check if this update was received some time ago, and if it exceeds our expire time
				# We don't want to immediately remove a limit, only for him to come back on a few seconds later, the cost in exec()'s
				# would be pretty high
				if ($now - $climit->{'LastUpdate'} > TIMEOUT_EXPIRE_OFFLINE) {

					# Remove entry if no longer live
					if ($glimit->{'_shaper.state'} == SHAPER_NOTLIVE) {
						$logger->log(LOG_INFO,"[CONFIGMANAGER] Limit '$climit->{'Username'}' [$lid] offline and removed from shaper");

						# Remove from system
						delete($limits->{$lid});
						# Remove from change queue
						delete($changeQueue->{$lid});
						# Set this UID as no longer using this IP
						# NK: If we try remove it before the limit is actually removed we could get a reconnection causing this value
						#     to be totally gone, which means we not tracking this limit using this IP anymore, not easily solved!!
						delete($limitIPMap->{$glimit->{'IP'}}->{$lid});
						# Check if we can delete the IP too
						if (keys %{$limitIPMap->{$glimit->{'IP'}}} == 0) {
							delete($limitIPMap->{$glimit->{'IP'}});
						}

						# Next record, we don't want to do any updates below
						next;

					# Push to shaper
					} elsif ($glimit->{'_shaper.state'} == SHAPER_LIVE) {
						$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Limit '$climit->{'Username'}' [$lid] offline, queue remove from shaper");

						# Post removal to shaper
						$kernel->post("shaper" => "remove" => $lid);

					} else {
						$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Limit '$climit->{'Username'}' [$lid], limit in list, but offline now and".
								" expired, still live, waiting for shaper");
					}
				}
			}

			# Update the limit data
			$glimit->{'Status'} = $climit->{'Status'};
			$glimit->{'LastUpdate'} = $climit->{'LastUpdate'};
			$glimit->{'Expires'} = $climit->{'Expires'};

		#
		# LIMIT NOT IN LIST
		#
		} else {
			# We take new and online notifications the same way here if the limit is not in our global limit list already
		   if (($climit->{'Status'} eq "new" || $climit->{'Status'} eq "online")) {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Processing new limit '$climit->{'Username'}' [$lid]");

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
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process limit '".$climit->{'Username'}."' IP '$climit->{'IP'}' conflicts with users '".
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
								# Post removal to shaper
								$kernel->post("shaper" => "remove" => $lid2);
								# Update that we're offline directly to global limit table
								$glimit2->{'Status'} = 'conflict';
							}
						}
					}

				# All looks good, no conflicts, we're set to add this limit!
				} else {
					# Post to the limit to the shaper
					$climit->{'_shaper.state'} = SHAPER_PENDING;
					$kernel->post("shaper" => "add" => $lid);

				}

				# Set this UID as using this IP
				$limitIPMap->{$climit->{'IP'}}->{$lid} = 1;

				# This is now live
				$limits->{$lid} = $climit;

			# Limit is not in our list and this is an unknown state we're trasitioning to
			} else {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Ignoring limit '$climit->{'Username'}' [$lid] state '$climit->{'Status'}', not in our".
						" global list");
			}

			# Remove from change queue
			delete($changeQueue->{$lid});
		}

	}


	#
	# CHECK OUT CONNECTED LIMITS
	#
	foreach my $lid (keys %{$limits}) {
		# Global limit
		my $glimit = $limits->{$lid};


if (!defined($glimit->{'Expires'})) {
	use Data::Dumper; warn "UNDEFINED: ".Dumper($glimit,$lid);
}

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
			$changeQueue->{$lid} = $climit;
		}
	}

	# Reset tick
	$kernel->delay(tick => TICK_PERIOD);
};


# Process shaper change
sub process_change
{
	my ($kernel, $limit) = @_[KERNEL, ARG0];

	_process_change($limit);
}


# Function to check the group ID exists
sub checkGroupID
{
	my $gid = shift;
	if (defined($config->{'groups'}->{$gid})) {
		return $gid;
	}
	return;
}


# Function to check the class ID exists
sub checkClassID
{
	my $cid = shift;
	if (defined($config->{'classes'}->{$cid})) {
		return $cid;
	}
	return;
}


# Function to check if the status is ok
sub checkStatus
{
	my $status = shift;
	if ($status eq "new" || $status eq "offline" || $status eq "online" || $status eq "conflict" || $status eq "unknown") {
		return $status
	}
	return;
}


# Function to return a limit username
sub getLimitUsername
{
	my $lid = shift;
	if (defined($limits->{$lid})) {
		return $limits->{$lid}->{'Username'};
	}
	return;
}


# Function to return a limit
sub getLimit
{
	my $lid = shift;

	if (defined($limits->{$lid})) {
		my %limit = %{$limits->{$lid}};
		return \%limit;
	}
	return;
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
	if (defined($limits->{$lid})) {
		$limits->{$lid}->{'attributes'}->{$attr} = $value;
	}
	return;
}


# Function to get a limit attribute
sub getLimitAttribute
{
	my ($lid,$attr) = @_;


	# Check if attribute exists first
	if (defined($limits->{$lid}) && defined($limits->{$lid}->{'attributes'}) && defined($limits->{$lid}->{'attributes'}->{$attr})) {
		return $limits->{$lid}->{'attributes'}->{$attr};
	}
	return;
}


# Function to set shaper state on a limit
sub setShaperState
{
	my ($lid,$state) = @_;

	if (defined($limits->{$lid})) {
		$limits->{$lid}->{'_shaper.state'} = $state;
	}
}


# Function to get shaper state on a limit
sub getShaperState
{
	my $lid = shift;
	if (defined($limits->{$lid})) {
		return $limits->{$lid}->{'_shaper.state'};
	}
	return;
}


# Function to get traffic classes
sub getTrafficClasses
{
	my %classes = %{$config->{'classes'}};

	return \%classes;
}


# Function to get priority name
sub getPriorityName
{
	my $prio = shift;
	return $config->{'classes'}->{$prio};
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

# Function to compute the changes between two users
sub _getChangeset
{
	my ($orig,$new) = @_;

	my $res;

	# Loop through what can change
	foreach my $item (CHANGESET_ATTRIBUTES) {
		# Check if its first set, if it is, check if its changed
		if (defined($new->{$item}) && $orig->{$item} ne $new->{$item}) {
			# If so record it & make the change
			$res->{$item} = $orig->{$item} = $new->{$item};
		}
	}

	return $res;
}


# This is the real function
# Supoprted user attributes:
#
# Username
#  - Users username
# IP
#  - Users IP
# GroupID
#  - Group ID
# ClassID
#  - Class ID
# TrafficLimitTx
#  - Traffic limit in kbps
# TrafficLimitRx
#  - Traffic limit in kbps
# TrafficLimitTxBurst
#  - Traffic bursting limit in kbps
# TrafficLimitRxBurst
#  - Traffic bursting limit in kbps
# Expires
#  - Unix timestamp when this entry expires, 0 if never
# Status
#  - new
#  - offline
#  - online
#  - unknown
# Source
#  - This is the source of the limit, typically  plugin.ModuleName
sub _process_change
{
	my $limit = shift;


	# We start off blank so we only pull in whats supported
	my $limitChange;
	if (!($limitChange->{'Username'} = $limit->{'Username'})) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process limit change as username is invalid.");
		return;
	}
	$limitChange->{'Username'} = $limit->{'Username'};
	$limitChange->{'IP'} = $limit->{'IP'};
	# Check group is OK
	if (!($limitChange->{'GroupID'} = checkGroupID($limit->{'GroupID'}))) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process limit change for '".$limit->{'Username'}."' as the GroupID is invalid.");
		return;
	}
	# Check class is OK
	if (!($limitChange->{'ClassID'} = checkClassID($limit->{'ClassID'}))) {
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


	# Optional priority, we default to 5
	$limitChange->{'TrafficPriority'} = defined($limit->{'TrafficPriority'}) ? $limit->{'TrafficPriority'} : 5;

	# Set when this entry expires
	$limitChange->{'Expires'} = defined($limit->{'Expires'}) ? $limit->{'Expires'} : 0;

	# Set when this entry was created
	$limitChange->{'Created'} = defined($limit->{'Created'}) ? $limit->{'Created'} : time();

	# Check status is OK
	if (!($limitChange->{'Status'} = checkStatus($limit->{'Status'}))) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process user change for '".$limit->{'Username'}."' as the Status is invalid.");
		return;
	}

	$limitChange->{'Source'} = $limit->{'Source'};

	# Create a unique limit identifier
	my $limitUniq = $limit->{'Username'} . "/" . $limit->{'IP'};
	# If we've not seen it
	my $lid;
	if (!defined($lid = $limitIDMap->{$limitUniq})) {
		# Give it the next limitID in the list
		$limitIDMap->{$limitUniq} = $lid = ++$limitIDCounter;
	}

	# Set the user ID before we post to the change queue
	$limitChange->{'ID'} = $lid;
	$limitChange->{'LastUpdate'} = time();

	# Push change to change queue
	$changeQueue->{$lid} = $limitChange;
}


# Load our statefile
sub _load_statefile
{
	# Check if the state file exists first of all
	if (! -e $config->{'statefile'}) {
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Statefile '".$config->{'statefile'}."' doesn't exist");
		return;
	}

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
		my $ouser;
		foreach my $attr (OVERRIDE_ATTRIBUTES) {
			if (defined($override->{$attr})) {
				$ouser->{$attr} = $override->{$attr};
			}
		}

		# Check username & IP are defined
		if (!defined($ouser->{'Username'})) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to load user override with no username '$section'");
			next;
		}

		$overrides->{$ouser->{'Username'}} = $ouser;
	}

	# Loop with persistent users
	foreach my $section ($state->GroupMembers('persist')) {
		my $user = $stateHash{$section};

		# User to push through to process change
		my $cuser;
		foreach my $attr (PERSISTENT_ATTRIBUTES) {
			if (defined($user->{$attr})) {
				$cuser->{$attr} = $user->{$attr};
			}
		}
		# This is a new entry
		$cuser->{'Status'} = 'new';

		# Check username & IP are defined
		if (!defined($cuser->{'Username'}) || !defined($cuser->{'IP'})) {
			$logger->log(LOG_WARN,"[CONFIGMANAGER] Failed to load persistent user with no username or no IP '$section'");
			next;
		}

		# Process this user
		_process_change($cuser);
	}
}


# Write out statefile
sub _write_statefile
{
	# Check if the state file exists first of all
	if (!defined($config->{'statefile'})) {
		$logger->log(LOG_WARN,"[CONFIGMANAGER] No statefile defined. Possible initial load error?");
		return;
	}

	# Create new state file object
	my $state = new Config::IniFiles();

	# Loop with persistent users, these are users with expires = 0
	foreach my $lid (keys %{$limits}) {
		# Skip over expiring entries, we only want persistent ones
		# XXX: Should we not just save all of them? load?
		next if ($limits->{$lid}->{'Expires'});
		# Pull in the section name
		my $section = "persist " . $limits->{$lid}->{'Username'};

		# Add a new section for this user
		$state->AddSection($section);
		# Items we want for persistent entries
		foreach my $pItem (PERSISTENT_ATTRIBUTES) {
			# Set items up
			if (defined(my $value = $limits->{$lid}->{$pItem})) {
				$state->newval($section,$pItem,$value);
			}
		}
	}

	# Loop with overrides
	foreach my $username (keys %{$overrides}) {
		# Pull in the section name
		my $section = "override " . $username;

		# Add a new section for this user
		$state->AddSection($section);
		# Items we want for override entries
		foreach my $pItem (OVERRIDE_ATTRIBUTES) {
			# Set items up
			if (defined(my $value = $overrides->{$username}->{$pItem})) {
				$state->newval($section,$pItem,$value);
			}
		}

	}

	# Check for an error
	if (!defined($state->WriteConfig($config->{'statefile'}))) {
		$logger->log(LOG_ERR,"[CONFIGMANAGER] Failed to write statefile '".$config->{'statefile'}."': $!");
		return;
	}

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] Configuration saved");
}


1;
# vim: ts=4
