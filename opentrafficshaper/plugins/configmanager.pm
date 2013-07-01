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
	TIMEOUT_EXPIRE_OFFLINE => 60,
};


# Plugin info
our $pluginInfo = {
	Name => "Config Manager",
	Version => VERSION,
	
	Init => \&init,
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
my $userIDMap = {};
my $userIDCounter = 1;



# Initialize plugin
sub init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};


	# This is our configuration processing session
	POE::Session->create(
		inline_states => {
			_start => \&session_init,
			tick => \&session_tick,
			process_change => \&process_change,
		}
	);

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

}



# Initialize config manager
sub session_init {
	my $kernel = $_[KERNEL];


	# Set our alias
	$kernel->alias_set("configmanager");

	# Set delay on config updates
	$kernel->delay(tick => 5);
}


# Time ticker for processing changes
sub session_tick {
	my $kernel = $_[KERNEL];


	# Suck in global
	my $users = $globals->{'users'};

	# Now
	my $now = time();


	# Loop with changes
	foreach my $uid (keys %{$changeQueue}) {
		# Global user
		my $guser = $users->{$uid};
		# Change user
		my $cuser = $changeQueue->{$uid};


		# NO USER IN LIST
		if (!defined($guser)) {

			# NO USER IN LIST => CHANGE IS NEW or ONLINE
		   if (($cuser->{'Status'} eq "new" || $cuser->{'Status'} eq "online")) {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Processing new user '$cuser->{'Username'}' [$uid]");
				# This is now live
				$users->{$uid} = $cuser;
				$users->{$uid}->{'shaper.live'} = SHAPER_PENDING;
				# Clean things up a bit

				# Post to shaper
				$kernel->post("shaper" => "add" => $uid);

			# NO USER IN LIST => CHANGE IS OFFLINE OR UNKNOWN
			} else {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] Ignoring user '$cuser->{'Username'}' [$uid] state '$cuser->{'Status'}', user was not online");
			}
	
			# Remove from change queue
			delete($changeQueue->{$uid});

		# USER IN LIST
		} else {
			# USER IN LIST => CHANGE IS NEW
			if ($cuser->{'Status'} eq "new") {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] User '$cuser->{'Username'}' [$uid], user live but new connection?");

				# Remove from change queue
				delete($changeQueue->{$uid});

			# USER IN LIST => CHANGE IS ONLINE
			} elsif ($cuser->{'Status'} eq "online") {
				$logger->log(LOG_DEBUG,"[CONFIGMANAGER] User '$cuser->{'Username'}' [$uid], user in list, new online notification");

				# Remove from change queue
				delete($changeQueue->{$uid});

			# USER IN LIST => CHANGE IS OFFLINE
			} elsif ($cuser->{'Status'} eq "offline") {

				# USER IN LIST => CHANGE IS OFFLINE => TIMEOUT EXPIRED
				if ($now - $cuser->{'LastUpdate'} > TIMEOUT_EXPIRE_OFFLINE) {

					# Remove entry if no longer live
					if (!$guser->{'shaper.live'}) {
						$logger->log(LOG_DEBUG,"[CONFIGMANAGER] User '$cuser->{'Username'}' [$uid], user in list, but offline now, expired and not live on shaper");

						# Remove from system
						delete($users->{$uid});
						# Remove from change queue
						delete($changeQueue->{$uid});
						# Jump to next
						next;

					# Push to shaper
					} elsif ($guser->{'shaper.live'} == SHAPER_LIVE) {
						$logger->log(LOG_DEBUG,"[CONFIGMANAGER] User '$cuser->{'Username'}' [$uid], user in list, but offline now and expired, still live on shaper");

						# Post to shaper
						$kernel->post("shaper" => "remove" => $uid);
						# Update that we're offline
						$guser->{'Status'} = 'offline';

					} else {
						$logger->log(LOG_DEBUG,"[CONFIGMANAGER] User '$cuser->{'Username'}' [$uid], user in list, but offline now and expired, still live, waiting for shaper");
					}
				}
			}
		}

		# Update the last time we got an update
		$guser->{'Status'} = $cuser->{'Status'};
		$guser->{'LastUpdate'} = $cuser->{'LastUpdate'};
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
# Status
# - new
# - offline
# - online
# - unknown
# Source 
# - This is the source of the user, typically  plugin.ModuleName

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
	if ($status eq "new" || $status eq "offline" || $status eq "online" || $status eq "unknown") {
		return $status
	}
}

1;
# vim: ts=4
