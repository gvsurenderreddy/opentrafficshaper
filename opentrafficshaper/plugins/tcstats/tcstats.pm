# OpenTrafficShaper Linux tcstats traffic shaping statistics
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



package opentrafficshaper::plugins::tcstats;

use strict;
use warnings;


use POE qw( Wheel::Run Filter::Line );

use POE::Filter::TCStatistics;

use opentrafficshaper::constants;
use opentrafficshaper::logger;

use opentrafficshaper::plugins::configmanager qw(
	getInterface
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
	VERSION => '0.1.2',

	# How often we tick
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


# Our globals
my $globals;
# Copy of system logger
my $logger;


# Last stats pulls
#
# $globals->{'LastStats'}



# Initialize plugin
sub plugin_init
{
	my $system = shift;


	# Setup our environment
	$logger = $system->{'logger'};

	$logger->log(LOG_NOTICE,"[TCSTATS] OpenTrafficShaper tc Statistics Integration v%s - Copyright (c) 2013-2014, AllWorldIT",
			VERSION
	);

	# Initialize
	$globals->{'LastStats'} = { };

	# This session is our main session, its alias is "shaper"
	POE::Session->create(
		inline_states => {
			_start => \&_session_start,
			_stop => \&_session_stop,
			_tick => \&_session_tick,

			_task_child_stdout => \&_task_child_stdout,
			_task_child_stderr => \&_task_child_stderr,
			_task_child_close => \&_task_child_close,

			_SIGCHLD => \&_task_handle_SIGCHLD,
			_SIGINT => \&_task_handle_SIGINT,
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
sub _session_start
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Set our alias
	$kernel->alias_set("tcstats");

	# Set delay on config updates
	$kernel->delay('_tick' => TICK_PERIOD);

	$logger->log(LOG_DEBUG,"[TCSTATS] Initialized");
}



# Shut down session
sub _session_stop
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];

	$kernel->alias_remove("tcstats");

	# Blow everything away
	$globals = undef;

	$logger->log(LOG_DEBUG,"[TCSTATS] Shutdown");

	$logger = undef;
}



# Time ticker for processing changes
sub _session_tick
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Now
	my $now = time();

	my @interfaces = getInterfaces();

	# Loop with interfaces that need stats
	my $interfaceCount = 0;
	foreach my $interfaceID (@interfaces)	{
		my $interface = getInterface($interfaceID);

		# Skip to next if we've already run for this interface
		if (defined($globals->{'LastStats'}->{$interfaceID}) &&
				$globals->{'LastStats'}->{$interfaceID} + opentrafficshaper::plugins::statistics::STATISTICS_PERIOD > $now
		) {
			next;
		}

		$logger->log(LOG_INFO,"[TCSTATS] Generating stats for '%s'",$interfaceID);

		# TC commands to run
		my $cmd = [ '/sbin/tc', '-s', 'class', 'show', 'dev', $interface->{'Device'}, 'parent', '1:' ];

		# Create task
		my $task = POE::Wheel::Run->new(
			Program => $cmd,
			StdinFilter => POE::Filter::Line->new(),
			StdoutFilter => POE::Filter::TCStatistics->new(),
			StderrFilter => POE::Filter::Line->new(),
			StdoutEvent => '_task_child_stdout',
			StderrEvent => '_task_child_stderr',
			CloseEvent => '_task_child_close',
		) or $logger->log(LOG_ERR,"[TCSTATS] TC: Unable to start task");

		# Intercept SIGCHLD
		$kernel->sig_child($task->ID, "_SIGCHLD");

		# Wheel events include the wheel's ID.
		$heap->{task_by_wid}->{$task->ID} = $task;
		# Signal events include the process ID.
		$heap->{task_by_pid}->{$task->PID} = $task;
		# Signal events include the process ID.
		$heap->{task_data}->{$task->ID} = {
			'Timestamp' => $now,
			'Interface' => $interfaceID,
			'CurrentStat' => { }
		};

		# Build commandline string
		my $cmdStr = join(' ',@{$cmd});
		$logger->log(LOG_DEBUG,"[TCSTATS] TASK/%s: Starting '%s' as %s with PID %s",$task->ID,$cmdStr,$task->ID,$task->PID);

		# Set last time we were run to now
		$globals->{'LastStats'}->{$interface} = $now;

		# NK: Space the stats out, this will cause TICK_PERIOD to elapse before we do another interface
		$interfaceCount++;
		last;
	}

	# If we didn't fire up any stats, re-tick
	if (!$interfaceCount) {
		$kernel->delay('_tick' => TICK_PERIOD);
	}
};



# Child writes to STDOUT
sub _task_child_stdout
{
	my ($kernel,$heap,$stat,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];


	my $task = $heap->{task_by_wid}->{$task_id};

	# Grab task data
	my $taskData = $heap->{'task_data'}->{$task_id};

	my $interface = $taskData->{'Interface'};
	my $timestamp = $taskData->{'Timestamp'};

	# Stats ID to update
	my $sid;
	# Default to transmit statistics
	my $direction = opentrafficshaper::plugins::statistics::STATISTICS_DIR_TX;

	# Is this a system class?
	my $classChildDec = hex($stat->{'TCClassChild'});
	# Check if this is a limit class...
	if (opentrafficshaper::plugins::tc::isPoolTcClass($interface,$stat->{'TCClassParent'},$stat->{'TCClassChild'})) {

		if (defined(my $pid = opentrafficshaper::plugins::tc::getPIDFromTcClass($interface,$stat->{'TCClassParent'},
						$stat->{'TCClassChild'}))
		) {
			$sid = opentrafficshaper::plugins::statistics::setSIDFromPID($pid);
			$direction = opentrafficshaper::plugins::statistics::getTrafficDirection($pid,$interface);
		} else {
			$logger->log(LOG_WARN,"[TCSTATS] Pool traffic class '%s:%s' NOT FOUND",$stat->{'TCClassParent'},
					$stat->{'TCClassChild'}
			);
		}

	} else {
		# Class = 1 is the root
		# XXX: Should this be hard coded or used like TC_ROOT_CLASS is
		if ($classChildDec == 1) {
			# This is a special case case
			$sid = opentrafficshaper::plugins::statistics::setSIDFromCID($interface,0);

		} else {
			# Save the class with the decimal number
			if (my $classID = opentrafficshaper::plugins::tc::getCIDFromTcClass($interface,
						opentrafficshaper::plugins::tc::TC_ROOT_CLASS,$stat->{'TCClassChild'})
			) {
				$sid = opentrafficshaper::plugins::statistics::setSIDFromCID($interface,$classID);
			} else {
				$logger->log(LOG_WARN,"[TCSTATS] System traffic class '%s:%s' NOT FOUND",$stat->{'TCClassParent'},
						$stat->{'TCClassChild'}
				);
			}
		}
	}

	# Make sure we have the lid now
	if (defined($sid)) {
		# Build our submission
		$stat->{'Timestamp'} = $timestamp;
		$stat->{'Direction'} = $direction;

		$taskData->{'Stats'}->{$sid} = $stat;
	}
}



# Child writes to STDERR
sub _task_child_stderr
{
	my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];


	my $task = $heap->{task_by_wid}->{$task_id};

	$logger->log(LOG_WARN,"[TCSTATS] TASK/%s: STDERR => %s",$task_id,$stdout);
}



# Child closed its handles, it won't communicate with us, so remove it
sub _task_child_close
{
	my ($kernel,$heap,$task_id) = @_[KERNEL,HEAP,ARG0];


	my $task = $heap->{task_by_wid}->{$task_id};
	my $taskData = $heap->{'task_data'}->{$task_id};

	# May have been reaped by task_sigchld()
	if (!defined($task)) {
		$logger->log(LOG_DEBUG,"[TCSTATS] TASK/%s: Closed dead child",$task_id);
		return;
	}

	# Push consolidated update through
	$kernel->post("statistics" => "update" => $taskData->{'Stats'});

	$logger->log(LOG_DEBUG,"[TCSTATS] TASK/%s: Closed PID %s",$task_id,$task->PID);

	# Cleanup
	delete($heap->{task_by_pid}->{$task->PID});
	delete($heap->{task_by_wid}->{$task_id});
	delete($heap->{task_data}->{$task_id});

	# Fire up next tick
	$kernel->delay('_tick' => TICK_PERIOD);
}



# Reap the dead child
sub _task_handle_SIGCHLD
{
	my ($kernel,$heap,$pid,$status) = @_[KERNEL,HEAP,ARG1,ARG2];
	my $task = $heap->{task_by_pid}->{$pid};


	$logger->log(LOG_DEBUG,"[TCSTATS] TASK: Task with PID %s exited with status %s",$pid,$status);

	# May have been reaped by task_child_close()
	return if (!defined($task));

	# Cleanup
	delete($heap->{task_by_pid}->{$pid});
	delete($heap->{task_by_wid}->{$task->ID});
	delete($heap->{task_data}->{$task->ID});
}



# Handle SIGINT
sub _task_handle_SIGINT
{
	my ($kernel,$heap,$signal_name) = @_[KERNEL,HEAP,ARG0];

	# Shutdown stdin on all children, this will terminate /sbin/tc
	foreach my $task_id (keys %{$heap->{'task_by_wid'}}) {
		my $task = $heap->{'task_by_wid'}{$task_id};
#		$kernel->sig_child($task->PID, "asig_child");
#		$task->kill("INT"); #NK: doesn't work
		$kernel->post($task,"shutdown_stdin"); #NK: doesn't work
	}

	$logger->log(LOG_WARN,"[TCSTATS] Killed children processes");
}



1;
# vim: ts=4
