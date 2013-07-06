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

	# After how long does a user get removed if he's offline
	TIMEOUT_EXPIRE_OFFLINE => 300,

	# How often our config check ticks
	TICK_PERIOD => 5,
};


# Plugin info
our $pluginInfo = {
	Name => "Config Manager",
	Version => VERSION,
	
	Init => \&init,

	# Signals
	signal_SIGHUP => \&handle_SIGHUP,
};


# Copy of system globals
my $globals;
my $logger;

# Config
my $config;
my $groups = {
	1 => 'Default'
};
my $classes = {
	1 => 'Default'
};

# Pending changes
my $changeQueue = { };
# UserID counter
my $userIPMap = {};
my $userIDMap = {};
my $userIDCounter = 1;



# Initialize plugin
sub init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] OpenTrafficShaper Config Manager v".VERSION." - Copyright (c) 2013, AllWorldIT");

	# Split off groups to load
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading traffic groups...");
	# Check if we loaded an array or just text
	my @groups = ref($globals->{'file.config'}->{'shaping'}->{'group'}) eq "ARRAY" ? @{$globals->{'file.config'}->{'shaping'}->{'group'}} : ( $globals->{'file.config'}->{'shaping'}->{'group'} );
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
		$groups->{$groupID} = $groupName;
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded traffic group '$groupName' with ID $groupID.");
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading traffic groups completed.");

	# Split off traffic classes
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading traffic classes...");
	# Check if we loaded an array or just text
	my @classes = ref($globals->{'file.config'}->{'shaping'}->{'class'}) eq "ARRAY" ? @{$globals->{'file.config'}->{'shaping'}->{'class'}} : ( $globals->{'file.config'}->{'shaping'}->{'class'} );
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
		$classes->{$classID} = $className;
		$logger->log(LOG_INFO,"[CONFIGMANAGER] Loaded traffic class '$className' with ID $classID.");
	}
	$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Loading traffic classes completed.");

	# This is our configuration processing session
	POE::Session->create(
		inline_states => {
			_start => \&session_init,
			tick => \&session_tick,
			process_change => \&process_change,
		}
	);
}



# Initialize config manager
sub session_init {
	my $kernel = $_[KERNEL];


	# Set our alias
	$kernel->alias_set("configmanager");

	# Set delay on config updates
	$kernel->delay(tick => TICK_PERIOD);

	$logger->log(LOG_INFO,"[CONFIGMANAGER] Started");
}


# Time ticker for processing changes
sub session_tick {
	my $kernel = $_[KERNEL];


	# Suck in global
	my $users = $globals->{'users'};

	# Now
	my $now = time();


	#
	# LOOP WITH CHANGES
	#

	foreach my $uid (keys %{$changeQueue}) {
		# Global user
		my $guser = $users->{$uid};
		# Change user
		my $cuser = $changeQueue->{$uid};


		# USER IN LIST
		if (defined($guser)) {

			# USER IN LIST => CHANGE IS NEW
			if ($cuser->{'Status'} eq "new") {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] User '$cuser->{'Username'}' [$uid], user live but new connection?");

				# Get the changes we made and push them to the shaper
				if (my $changes = processChanges($guser,$cuser)) {
					# Post to shaper
					$kernel->post("shaper" => "change" => $uid => $changes);
				}

				# Remove from change queue
				delete($changeQueue->{$uid});

			# USER IN LIST => CHANGE IS ONLINE
			} elsif ($cuser->{'Status'} eq "online") {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] User '$cuser->{'Username'}' [$uid], user in list, new online notification");

				# Get the changes we made and push them to the shaper
				if (my $changes = processChanges($guser,$cuser)) {
					# Post to shaper
					$kernel->post("shaper" => "change" => $uid => $changes);
				}

				# Remove from change queue
				delete($changeQueue->{$uid});

			# USER IN LIST => CHANGE IS OFFLINE
			} elsif ($cuser->{'Status'} eq "offline") {

				# USER IN LIST => CHANGE IS OFFLINE => TIMEOUT EXPIRED
				if ($now - $cuser->{'LastUpdate'} > TIMEOUT_EXPIRE_OFFLINE) {

					# Remove entry if no longer live
					if ($guser->{'shaper.live'} == SHAPER_NOTLIVE) {
						$logger->log(LOG_DEBUG,"[CONFIGMANAGER] User '$cuser->{'Username'}' [$uid] offline and removed from shaper");

						# Remove from system
						delete($users->{$uid});
						# Remove from change queue
						delete($changeQueue->{$uid});
						# Jump to next
						next;

					# Push to shaper
					} elsif ($guser->{'shaper.live'} == SHAPER_LIVE) {
						$logger->log(LOG_DEBUG,"[CONFIGMANAGER] User '$cuser->{'Username'}' [$uid] offline, queue remove from shaper");

						# Post removal to shaper
						$kernel->post("shaper" => "remove" => $uid);
						# Update that we're offline
						$guser->{'Status'} = 'offline';

						# Set this UID as no longer using this IP
						delete($userIPMap->{$cuser->{'IP'}}->{$uid});

					} else {
						$logger->log(LOG_DEBUG,"[CONFIGMANAGER] User '$cuser->{'Username'}' [$uid], user in list, but offline now and expired, still live, waiting for shaper");
					}
				}
			}

		# USER NOT IN LIST
		} else {
			# NO USER IN LIST => CHANGE IS NEW or ONLINE
		   if (($cuser->{'Status'} eq "new" || $cuser->{'Status'} eq "online")) {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Processing new user '$cuser->{'Username'}' [$uid]");

				# Check if there are IP conflicts
				my @ipUsers = keys %{$userIPMap->{$cuser->{'IP'}}};
				if (
					# If there is already an entry and its not us ...
					@ipUsers == 1 && !defined($userIPMap->{$cuser->{'IP'}}->{$uid})
					# Or if there is more than 1 entry...
					|| @ipUsers > 1 
				) {
					# Don't post to shaper & override status
					$cuser->{'Status'} = 'conflict';
					$cuser->{'shaper.live'} = SHAPER_NOTLIVE;
					# Give a bit of info
					$logger->log(LOG_WARN,"[CONFIGMANAGER] Cannot process user '".$cuser->{'Username'}."' IP '$cuser->{'IP'}' conflicts with users '".
							join(',',
								map { $users->{$_}->{'Username'}  } 
								@ipUsers
							)
					."'.");

					# Remove conflicted users from shaper
					foreach my $uid2 (@ipUsers) {
						# Check if the user has been setup already (all but the user we busy with, as its setup below)
						if (defined($userIPMap->{$cuser->{'IP'}}->{$uid2})) {
							my $guser2 = $users->{$uid2};

							# If the user is active or pending on the shaper, remove it
							if ($guser2->{'shaper.live'} == SHAPER_LIVE || $guser2->{'shaper.live'} == SHAPER_PENDING) {
								$logger->log(LOG_WARN,"[CONFIGMANAGER] Removing conflicted user '".$guser2->{'Username'}."' [$uid2] from shaper'");
								# Post removal to shaper
								$kernel->post("shaper" => "remove" => $uid2);
								# Update that we're offline
								$guser2->{'Status'} = 'conflict';
							}
						}
					}

				# All is good, no conflicts ... lets add
				} else {
					# Post to shaper
					$cuser->{'shaper.live'} = SHAPER_PENDING;
					$kernel->post("shaper" => "add" => $uid);
				}

				# Set this UID as using this IP
				$userIPMap->{$cuser->{'IP'}}->{$uid} = 1;

				# This is now live
				$users->{$uid} = $cuser;


			# NO USER IN LIST => CHANGE IS OFFLINE OR UNKNOWN
			} else {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Ignoring user '$cuser->{'Username'}' [$uid] state '$cuser->{'Status'}', not in our global list");
			}
	
			# Remove from change queue
			delete($changeQueue->{$uid});
		}

		# Update the last time we got an update
		if (defined($guser)) {
			$guser->{'Status'} = $cuser->{'Status'};
			$guser->{'LastUpdate'} = $cuser->{'LastUpdate'};
			# This item is optional
			$guser->{'Expires'} = $cuser->{'Expires'} if (defined($cuser->{'Expires'}));
		}
	}


	#
	# CHECK OUT CONNECTED USERS
	#
	foreach my $uid (keys %{$changeQueue}) {
		# Global user
		my $guser = $users->{$uid};

		# Check for expired users
		if ($now > $guser->{'Expires'}) {
			# Looks like this user has expired?
			my $cuser = {
				'Username' => 'Username',
				'Status' => 'offline',
				'LastUpdate' => $guser->{'LastUpdate'},
			};
			# Add to change queue
			$changeQueue->{$uid} = $cuser;
		}
	}

	# Reset tick
	$kernel->delay(tick => 5);
};


# Process shaper change
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
#  - This is the source of the user, typically  plugin.ModuleName
sub process_change {
	my ($kernel, $user) = @_[KERNEL, ARG0];



	# Create a unique user identifier
	my $userUniq = $user->{'Username'} . "/" . $user->{'IP'};

	# If we've not seen it
	my $uid;
	if (!defined($uid = $userIDMap->{$userUniq})) {
		# Give it the next userID in the list
		$userIDMap->{$userUniq} = $uid = ++$userIDCounter;
	}

	# We start off blank so we only pull in whats supported
	my $userChange;
	if (!($userChange->{'Username'} = $user->{'Username'})) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process user change as username is invalid.");
	}
	$userChange->{'Username'} = $user->{'Username'};
	$userChange->{'IP'} = $user->{'IP'};
	# Check group is OK
	if (!($userChange->{'GroupID'} = checkGroupID($user->{'GroupID'}))) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process user change for '".$user->{'Username'}."' as the GroupID is invalid.");
	}
	# Check class is OK
	if (!($userChange->{'ClassID'} = checkClassID($user->{'ClassID'}))) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process user change for '".$user->{'Username'}."' as the ClassID is invalid.");
	}
	$userChange->{'TrafficLimitTx'} = $user->{'TrafficLimitTx'};
	$userChange->{'TrafficLimitRx'} = $user->{'TrafficLimitRx'};
	# Take base limits if we don't have any burst values set
	$userChange->{'TrafficLimitTxBurst'} = defined($user->{'TrafficLimitTxBurst'}) ? $user->{'TrafficLimitTxBurst'} : $user->{'TrafficLimitTx'};
	$userChange->{'TrafficLimitRxBurst'} = defined($user->{'TrafficLimitRxBurst'}) ? $user->{'TrafficLimitRxBurst'} : $user->{'TrafficLimitRx'};

	# Set when this entry expires
	$userChange->{'Expires'} = defined($user->{'Expires'}) ? $user->{'Expires'} : 0;

	# Check status is OK
	if (!($userChange->{'Status'} = checkStatus($user->{'Status'}))) {
		$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Cannot process user change for '".$user->{'Username'}."' as the Status is invalid.");
	}

	$userChange->{'Source'} = $user->{'Source'};

	# Set the user ID before we post to the change queue
	$userChange->{'ID'} = $uid;
	$userChange->{'LastUpdate'} = time();

	# Push change to change queue
	$changeQueue->{$uid} = $userChange;
}


# Function to compute the changes between two users
sub processChanges
{
	my ($orig,$new) = @_;

	my $res;

	# Loop through what can change
	foreach my $item ('GroupID','ClassID','TrafficLimitTx','TrafficLimitRx','TrafficLimitTxBurst','TrafficLimitRxBurst') {
		# Check if its first set, if it is, check if its changed
		if (defined($new->{$item}) && $orig->{$item} ne $new->{$item}) {
			# If so record it & make the change
			$res->{$item} = $orig->{$item} = $new->{$item};
		}
	}

	return $res;
}


# Function to check the group ID exists
sub checkGroupID
{
	my $gid = shift;
	return $gid if (defined($groups->{$gid}));
}

# Function to check the class ID exists
sub checkClassID
{
	my $cid = shift;
	return $cid if (defined($classes->{$cid}));
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



# Handle SIGHUP
sub handle_SIGHUP
{
	$logger->log(LOG_WARN,"[CONFIGMANAGER] Got SIGHUP, ignoring for now");
}

1;
# vim: ts=4
