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
	Name => "Config Manager",
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


	print STDERR "tick at ", time(), ":  users = ". (keys %{$globals->{'users'}})  ."\n";

	# Reset tick
	$kernel->delay(tick => 5);
};


# Read event for server
sub process_change {
	my ($kernel, $user) = @_[KERNEL, ARG0];

	print STDERR "We were asked to process an update for $user->{'Username'}\n";
}



1;
# vim: ts=4
