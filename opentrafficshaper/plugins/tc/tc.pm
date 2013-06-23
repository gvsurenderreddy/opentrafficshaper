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
};


# Plugin info
our $pluginInfo = {
	Name => "Linux tc Interface",
	Version => VERSION,
	
	Init => \&init,
};


# Copy of system globals
my $globals;
my $logger;


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
			add => \&do_add,
			change => \&do_change,
			remove => \&do_remove,
		}
	);

	$logger->log(LOG_NOTICE,"[TC] OpenTrafficShaper tc Integration v".VERSION." - Copyright (c) 2013, AllWorldIT")
}



# Initialize config manager
sub session_init {
	my $kernel = $_[KERNEL];


	# Set our alias
	$kernel->alias_set("shaper");
}


# Add event for tc
sub do_add {
	my ($kernel, $uid) = @_[KERNEL, ARG0];


	# Pull in global
	my $users = %globals->{'users'};
	my $user = $users->{$uid};


	$users->{$uid}->{'shaper_live'} = SHAPER_LIVE;
	print STDERR " TC => add $user->{'Username'}\n";
}

# Change event for tc
sub do_change {
	my ($kernel, $user) = @_[KERNEL, ARG0];

	print STDERR " TC => change $user->{'Username'}\n";
}

# Remove event for tc
sub do_remove {
	my ($kernel, $user) = @_[KERNEL, ARG0];

	$users->{$uid}->{'shaper_live'} = 0;
	print STDERR " TC => remove $user->{'Username'}\n";
}



1;
# vim: ts=4
