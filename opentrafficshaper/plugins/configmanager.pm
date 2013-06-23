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

	$logger->log(LOG_NOTICE,"[CONFIGMANAGER] OpenTrafficShaper Config Manager v".VERSION." - Copyright (c) 2013, AllWorldIT")
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


# Read event for server
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

	# Set the user ID before we post to the change queue
	$user->{'ID'} = $uid;
	$user->{'LastUpdate'} = time();

	# Push change to change queue
	$changeQueue->{$uid} = $user;
}



1;
# vim: ts=4
