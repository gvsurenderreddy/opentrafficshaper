# OpenTrafficShaper Traffic shaping statistics
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



package opentrafficshaper::plugins::statistics;

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
);

use constant {
	VERSION => '0.0.1',
};


# Plugin info
our $pluginInfo = {
	Name => "Statistics Interface",
	Version => VERSION,
	
	Init => \&plugin_init,
	Start => \&plugin_start,

	# Signals
	signal_SIGHUP => \&handle_SIGHUP,
};


# Copy of system globals
my $globals;
my $logger;


# Our configuration
my $config = {
	'dsn_name' => "dbi:SQLite:dbname=/tmp/statsfile.sqlite",
	'dsn_user' => "",
	'dsn_pass' => "",
};

# Stats cache
my $statsCache = {};
# Stats subscribers
my $subscribers;
# $subscribers => $user => [  { 'session' => 'event' }, { 'session' , 'event' } ]


# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[STATISTICS] OpenTrafficShaper Statistics v".VERSION." - Copyright (c) 2013, AllWorldIT");


	# Check our interfaces
	if (defined(my $dsnn = $globals->{'file.config'}->{'plugin.STATISTICS'}->{'dsn_name'})) {
		$logger->log(LOG_INFO,"[STATISTICS] Set dsn_name to '$dsnn'");
		$config->{'dsn_name'} = $dsnn;
	}
	if (defined(my $dsnu = $globals->{'file.config'}->{'plugin.STATISTICS'}->{'dsn_user'})) {
		$logger->log(LOG_INFO,"[STATISTICS] Set dsn_user to '$dsnu'");
		$config->{'dsn_user'} = $dsnu;
	}
	if (defined(my $dsnp = $globals->{'file.config'}->{'plugin.STATISTICS'}->{'dsn_pass'})) {
		$logger->log(LOG_INFO,"[STATISTICS] Set dsn_pass to '$dsnp'");
		$config->{'dsn_pass'} = $dsnp;
	}


	# This session is our main session, its alias is "shaper"
	POE::Session->create(
		inline_states => {
			_start => \&session_init,

			# Stats update event
			update => \&do_update,
			# Subscription events
			subscribe => \&do_subscribe,
			unsubscribe => \&do_unsubscribe,
		}
	);

	return 1;
}


# Start the plugin
sub plugin_start
{
	$logger->log(LOG_INFO,"[STATISTICS] Started");
}


# Initialize this plugins main POE session
sub session_init {
	my $kernel = $_[KERNEL];


	# Set our alias
	$kernel->alias_set("statistics");

	$logger->log(LOG_DEBUG,"[STATISTICS] Initialized");
}

# Update users Statistics
# $uid has some special use cases:
#	main:$iface:all	- Interface total stats
#	main:$iface:classes	- Interface classified traffic
#	main:$iface:besteffort	- Interface best effort traffic
sub do_update {
	my ($kernel, $item, $stats) = @_[KERNEL, ARG0, ARG1];


	# Save entry
	$statsCache->{$item}->{$stats->{'timestamp'}} = $stats;

	# Buffer size
	$logger->log(LOG_INFO,"[STATISTICS] Statistics update for '%s', buffered '%s' items",$item,scalar keys %{$statsCache->{$item}});

	if ($item =~ /^main/) {
	} else {
		# Pull in global
		my $users = $globals->{'users'};
		my $user = $users->{$item};

	}


	# Check if we have an event handler subscriber for this item
	if (defined($subscribers->{$item}) && %{$subscribers->{$item}}) {
print STDERR "Pass1\n";
		# If we do, loop with them
		foreach my $handler (keys %{$subscribers->{$item}}) {
print STDERR "Pass2: $handler\n";

			# If no events are linked to this handler, continue
			if (!(keys %{$subscribers->{$item}->{$handler}})) {
print STDERR "Pass3: $handler\n";
				next;
			}

			# Or ... If we have events, process them
			foreach my $event (keys %{$subscribers->{$item}->{$handler}}) {
print STDERR "Pass4: $event\n";

				$kernel->post($handler => $event => $item => $stats);

			}
		}
	}



}


# Handle subscriptions to updates
sub do_subscribe {
	my ($kernel, $handler, $handlerEvent, $item) = @_[KERNEL, ARG0, ARG1, ARG2];


	$logger->log(LOG_INFO,"[STATISTICS] Got subscription request from '$handler' for '$item' via event '$handlerEvent'");

	$subscribers->{$item}->{$handler}->{$handlerEvent} = $item;
}


# Handle unsubscribes
sub do_unsubscribe {
	my ($kernel, $handler, $handlerEvent, $item) = @_[KERNEL, ARG0, ARG1, ARG2];


	$logger->log(LOG_INFO,"[STATISTICS] Got unsubscription request for '$handler' regarding '$item'");

	delete($subscribers->{$item}->{$handler}->{$handlerEvent});
}


sub handle_SIGHUP
{
	$logger->log(LOG_WARN,"[STATISTICS] Got SIGHUP, ignoring for now");
}

1;
# vim: ts=4
