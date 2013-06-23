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


use POE qw( Wheel::Run Filter::Line );

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

my $classMaps = {
	1 => {
		1 => "Primary Interface",
	},
};
my $classID = 10;

my @taskQueue = ();



# Initialize plugin
sub init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};


	# This session is our main session, its alias is "shaper"
	POE::Session->create(
		inline_states => {
			_start => \&session_init,
			add => \&do_add,
			change => \&do_change,
			remove => \&do_remove,
		}
	);

	# This is our session for communicating directly with tc, its alias is _tc
	POE::Session->create(
		inline_states => {
			_start => \&tc_session_init,
			# Public'ish
			queue => \&tc_task_add,
			# Internal
			tc_child_stdout => \&tc_child_stdout,
			tc_child_stderr => \&tc_child_stderr,
			tc_child_close => \&tc_child_close,
			tc_task_run_next => \&tc_task_run_next,
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
	my ($kernel,$heap,$uid) = @_[KERNEL, HEAP, ARG0];


	# Pull in global
	my $users = $globals->{'users'};
	my $user = $users->{$uid};

	$users->{$uid}->{'shaper.live'} = SHAPER_LIVE;
	$logger->log(LOG_DEBUG," Add '$user->{'Username'}' [$uid]\n");

#	tc class add dev eth0 parent 1:1  classid 1:aa  htb rate 150kbps ceil 200kbps
#	tc filter add dev eth0 parent 1:1 protocol ip prio 1 u32 \
#		match ip dst 10.254.254.235/32 flowid 1:aa

	$classID++;
	my $classIDHex = sprintf('%x',$classID);

	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','class','add',
				'dev','eth0',
				'parent','1:1',
				'classid',"1:$classIDHex",
				'htb',
					'rate','150kbps',
					'ceil','200kbps',
	]);
	$kernel->post("_tc" => "queue" => [
			'/sbin/tc','filter','add',
				'dev','eth0',
				'parent','1:1',
				'protocol','ip',
				'prio','1',
				'u32',
					'match','ip','dst',$user->{'IP'},
				'flowid',"1:$classIDHex",
	]);
}

# Change event for tc
sub do_change {
	my ($kernel, $uid) = @_[KERNEL, ARG0];


	# Pull in global
	my $users = $globals->{'users'};
	my $user = $users->{$uid};

	$logger->log(LOG_DEBUG," Change '$user->{'Username'}' [$uid]\n");
}

# Remove event for tc
sub do_remove {
	my ($kernel, $uid) = @_[KERNEL, ARG0];


	# Pull in global
	my $users = $globals->{'users'};
	my $user = $users->{$uid};

	$users->{$uid}->{'shaper.live'} = SHAPER_NOTLIVE;
	$logger->log(LOG_DEBUG," Remove '$user->{'Username'}' [$uid]\n");
}




#
# Task/child communication & handling stuff
#

# Initialize our tc session
sub tc_session_init {
	my $kernel = $_[KERNEL];
	# Set our alias
	$kernel->alias_set("_tc");
}

# Run a task
sub tc_task_add
{
	my ($kernel,$heap,$cmd) = @_[KERNEL,HEAP,ARG0];


	# Build commandline string
	my $cmdStr = join(' ',@{$cmd});
	# Shove task on list
	$logger->log(LOG_DEBUG,"[TC] TASK: Queue '$cmdStr'");
	push(@taskQueue,$cmd);

	# Trigger a run if list is empty
	if (@taskQueue < 2) {
		$kernel->yield("tc_task_run_next");
	}
}


# Fire up the session starter
sub tc_task_run_next
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Check if we have a task coming off the top of the task queue
	if (my $cmd = shift(@taskQueue)) {

		# Create task
		my $task = POE::Wheel::Run->new(
			Program => $cmd,
			# We get full lines back
			StdioFilter => POE::Filter::Line->new(),
			StderrFilter => POE::Filter::Line->new(),
	        StdoutEvent => 'tc_child_stdout',
	        StderrEvent => 'tc_child_stderr',
			CloseEvent => 'tc_child_close',
		) or $logger->log(LOG_ERR,"[TC] TASK: Unable to start task");


		# Intercept SIGCHLD
	    $kernel->sig_child($task->PID, "sig_child");

		# Wheel events include the wheel's ID.
		$heap->{task_by_wid}->{$task->ID} = $task;
		# Signal events include the process ID.
		$heap->{task_by_pid}->{$task->PID} = $task;

		# Build commandline string
		my $cmdStr = join(' ',@{$cmd});
		$logger->log(LOG_DEBUG,"[TC] TASK/".$task->ID.": Starting '$cmdStr' as ".$task->ID." with PID ".$task->PID);
	}
}


# Child writes to STDOUT
sub tc_child_stdout
{
    my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
    my $child = $heap->{task_by_wid}->{$task_id};

	$logger->log(LOG_DEBUG,"[TC] TASK/$task_id: STDOUT => ".$stdout);
}


# Child writes to STDERR
sub tc_child_stderr
{
    my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
    my $child = $heap->{task_by_wid}->{$task_id};

	$logger->log(LOG_NOTICE,"[TC] TASK/$task_id: STDERR => ".$stdout);
}


# Child closed its handles, it won't communicate with us, so remove it
sub tc_child_close
{
    my ($kernel,$heap,$task_id) = @_[KERNEL,HEAP,ARG0];
    my $child = delete($heap->{task_by_wid}->{$task_id});

    # May have been reaped by tc_sigchld()
    if (!defined($child)) {
		$logger->log(LOG_DEBUG,"[TC] TASK/$task_id: Closed dead child");
		return;
    }

	$logger->log(LOG_DEBUG,"[TC] TASK/$task_id: Closed PID ".$child->PID);
    delete($heap->{task_by_pid}->{$child->PID});

	# Start next one, if there is a next one
	if (@taskQueue > 0) {
		$kernel->yield("tc_task_run_next");
	}
}


# Reap the dead child
sub tc_sigchld
{
	my ($kernel,$heap,$pid,$status) = @_[KERNEL,HEAP,ARG1,ARG2];
    my $child = delete($heap->{task_by_pid}->{$pid});


	$logger->log(LOG_DEBUG,"[TC] TASK: Task with PID $pid exited with status $status");

    # May have been reaped by tc_child_close()
    return if (!defined($child));

    delete($heap->{task_by_wid}{$child->ID});
}


1;
# vim: ts=4
