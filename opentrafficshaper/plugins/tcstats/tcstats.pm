# OpenTrafficShaper Linux tcstats traffic shaping statistics
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



package opentrafficshaper::plugins::tcstats;

use strict;
use warnings;


use POE qw( Wheel::Run Filter::Line );

use POE::Filter::TCStatistics;

use opentrafficshaper::constants;
use opentrafficshaper::logger;
use opentrafficshaper::utils;

use opentrafficshaper::plugins::configmanager qw(
		getInterfaces
);


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

	# How often our config check ticks
	TICK_PERIOD => 5,
};


# Plugin info
our $pluginInfo = {
	Name => "Linux tc Statistics Interface",
	Version => VERSION,

	Init => \&plugin_init,
	Start => \&plugin_start,

	Requires => ["tc","statistics"],
};


# Copy of system globals
my $globals;
my $logger;


# Last stats pulls
my $lastStats = { };


# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[TCSTATS] OpenTrafficShaper tc Statistics Integration v".VERSION." - Copyright (c) 2013, AllWorldIT");


	# This session is our main session, its alias is "shaper"
	POE::Session->create(
		inline_states => {
			_start => \&session_start,
			_stop => \&session_stop,

			tick => \&session_tick,
			# Internal
			task_child_stdout => \&task_child_stdout,
			task_child_stderr => \&task_child_stderr,
			task_child_close => \&task_child_close,
			# Signals
			handle_SIGCHLD => \&task_handle_SIGCHLD,
			handle_SIGINT => \&task_handle_SIGINT,
		}
	);

	return 1;
}


# Start the plugin
sub plugin_start
{
	$logger->log(LOG_INFO,"[TCSTATS] Started");
}


# Initialize this plugins main POE session
sub session_start
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Set our alias
	$kernel->alias_set("tcstats");

	# Set delay on config updates
	$kernel->delay(tick => TICK_PERIOD);

	$logger->log(LOG_DEBUG,"[TCSTATS] Initialized");
}


# Shut down session
sub session_stop
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];

	$kernel->alias_remove("tcstats");

	# Blow everything away
	$globals = undef;

	$logger->log(LOG_DEBUG,"[TCSTATS] Shutdown");

	$logger = undef;
}


# Time ticker for processing changes
sub session_tick
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Now
	my $now = time();

	# Loop with interfaces that need stats
	my $interfaceCount = 0;
	foreach my $interface (@{getInterfaces()})	{

		# Skip to next if we've already run for this interface
		if (defined($lastStats->{$interface}) && $lastStats->{$interface} + opentrafficshaper::plugins::statistics::STATISTICS_PERIOD > $now) {
			next;
		}

		$logger->log(LOG_INFO,"[TCSTATS] Generating stats for '$interface'");

		# TC commands to run
		my $cmd = [ '/sbin/tc', '-s', 'class', 'show', 'dev', $interface, 'parent', '1:' ];

		# Create task
		my $task = POE::Wheel::Run->new(
			Program => $cmd,
			StdinFilter => POE::Filter::Line->new(),
			StdoutFilter => POE::Filter::TCStatistics->new(),
			StderrFilter => POE::Filter::Line->new(),
			StdoutEvent => 'task_child_stdout',
			StderrEvent => 'task_child_stderr',
			CloseEvent => 'task_child_close',
		) or $logger->log(LOG_ERR,"[TCSTATS] TC: Unable to start task");

		# Intercept SIGCHLD
		$kernel->sig_child($task->ID, "sig_child");

		# Wheel events include the wheel's ID.
		$heap->{task_by_wid}->{$task->ID} = $task;
		# Signal events include the process ID.
		$heap->{task_by_pid}->{$task->PID} = $task;
		# Signal events include the process ID.
		$heap->{task_data}->{$task->ID} = {
			'timestamp' => $now,
			'interface' => $interface,
			'current_stat' => { }
		};

		# Build commandline string
		my $cmdStr = join(' ',@{$cmd});
		$logger->log(LOG_DEBUG,"[TCSTATS] TASK/".$task->ID.": Starting '$cmdStr' as ".$task->ID." with PID ".$task->PID);

		# Set last time we were run to now
		$lastStats->{$interface} = $now;

		# NK: Space the stats out, this will cause TICK_PERIOD to elapse before we do another interface
		$interfaceCount++;
		last;
	}

	# If we didn't fire up any stats, re-tick
	if (!$interfaceCount) {
		$kernel->delay(tick => TICK_PERIOD);
	}
};


# Child writes to STDOUT
sub task_child_stdout
{
	my ($kernel,$heap,$stat,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
	my $task = $heap->{task_by_wid}->{$task_id};

	# Grab task data
	my $taskData = $heap->{'task_data'}->{$task_id};

	my $interface = $taskData->{'interface'};
	my $timestamp = $taskData->{'timestamp'};

	# Stats ID to update
	my $sid;
	# Default to transmit statistics
	my $direction = opentrafficshaper::plugins::statistics::STATISTICS_DIR_TX;

	# Is this a system class?
	# XXX: _class_parent is hard coded to 1
	if ($stat->{'_class_parent'} == 1 && (my $classChildDec = hex($stat->{'_class_child'})) < 100) {

		# Split off the different types of updates
		if ($classChildDec == 1) {
			$sid = opentrafficshaper::plugins::statistics::getSIDFromCID($interface,0);
		} else {
			# Save the class with the decimal number
			if (my $tcClass =  opentrafficshaper::plugins::tc::isTcTrafficClassValid($interface,1,$stat->{'_class_child'})) {
				my $classID = hex($tcClass);
				$sid = opentrafficshaper::plugins::statistics::getSIDFromCID($interface,$classID);
			} else {
				$logger->log(LOG_WARN,"[TCSTATS] System traffic class '%s:%s' NOT FOUND",$stat->{'_class_parent'},$stat->{'_class_child'});
			}
		}

	} else {
		if (defined(my $lid = opentrafficshaper::plugins::tc::getLIDFromTcLimitClass($interface,$stat->{'_class_child'}))) {
			$sid = opentrafficshaper::plugins::statistics::getSIDFromLID($lid);
			$direction = opentrafficshaper::plugins::statistics::getTrafficDirection($lid,$interface);
		}
	}

	# Make sure we have the lid now
	if (defined($sid)) {
		# Build our submission
		$stat->{'timestamp'} = $timestamp;
		$stat->{'direction'} = $direction;

		$taskData->{'stats'}->{$sid} = $stat;
	}
}


# Child writes to STDERR
sub task_child_stderr
{
	my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
	my $task = $heap->{task_by_wid}->{$task_id};

	$logger->log(LOG_WARN,"[TCSTATS] TASK/$task_id: STDERR => ".$stdout);
}


# Child closed its handles, it won't communicate with us, so remove it
sub task_child_close
{
	my ($kernel,$heap,$task_id) = @_[KERNEL,HEAP,ARG0];
	my $task = $heap->{task_by_wid}->{$task_id};
	my $taskData = $heap->{'task_data'}->{$task_id};


	# May have been reaped by task_sigchld()
	if (!defined($task)) {
		$logger->log(LOG_DEBUG,"[TCSTATS] TASK/$task_id: Closed dead child");
		return;
	}

	# Push consolidated update through
	$kernel->post("statistics" => "update" => $taskData->{'stats'});

	$logger->log(LOG_DEBUG,"[TCSTATS] TASK/$task_id: Closed PID ".$task->PID);

	# Cleanup
	delete($heap->{task_by_pid}->{$task->PID});
	delete($heap->{task_by_wid}->{$task_id});
	delete($heap->{task_data}->{$task_id});

	# Fire up next tick
	$kernel->delay(tick => TICK_PERIOD);
}


# Reap the dead child
sub task_sigchld
{
	my ($kernel,$heap,$pid,$status) = @_[KERNEL,HEAP,ARG1,ARG2];
	my $task = $heap->{task_by_pid}->{$pid};


	$logger->log(LOG_DEBUG,"[TCSTATS] TASK: Task with PID $pid exited with status $status");

	# May have been reaped by task_child_close()
	return if (!defined($task));

	# Cleanup
	delete($heap->{task_by_pid}->{$pid});
	delete($heap->{task_by_wid}->{$task->ID});
	delete($heap->{task_data}->{$task->ID});
}


1;
# vim: ts=4
