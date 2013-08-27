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

	# Signals
	signal_SIGHUP => \&handle_SIGHUP,
};


# Copy of system globals
my $globals;
my $logger;


# Our configuration
my $config = {
};


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
			_start => \&session_init,
			tick => \&session_tick,
			# Internal
			task_child_stdout => \&task_child_stdout,
			task_child_stderr => \&task_child_stderr,
			task_child_close => \&task_child_close,
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
sub session_init {
	my $kernel = $_[KERNEL];


	# Set our alias
	$kernel->alias_set("tcstats");

	# Set delay on config updates
	$kernel->delay(tick => TICK_PERIOD);

	$logger->log(LOG_DEBUG,"[TCSTATS] Initialized");
}

# Time ticker for processing changes
sub session_tick {
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# Suck in global
	my $users = $globals->{'users'};
	my $tcConfig = $opentrafficshaper::plugins::tc::config;

	# Now
	my $now = time();

	my $iface = "eth1";

	# Work out traffic direction
	my $direction;
	if ($iface eq opentrafficshaper::plugins::tc::getConfigTxIface()) {
		$direction = 'tx';
	} elsif ($iface eq opentrafficshaper::plugins::tc::getConfigRxIface()) {
		$direction = 'rx';
	} else {
		# Reset tick
		$kernel->delay(tick => TICK_PERIOD);
		$logger->log(LOG_ERR,"[TCSTATS] Unknown interface '$iface'");
		return;
	}

	# TC commands to run
	my $cmd = [ '/sbin/tc', '-s', 'class', 'show', 'dev', $iface ];

	# Create task
	my $task = POE::Wheel::Run->new(
		Program => $cmd,
		# We get full lines back
		StdioFilter => POE::Filter::Line->new(),
		StderrFilter => POE::Filter::Line->new(),
        StdoutEvent => 'task_child_stdout',
        StderrEvent => 'task_child_stderr',
		CloseEvent => 'task_child_close',
	) or $logger->log(LOG_ERR,"[TCSTATS] TC: Unable to start task");

	# Intercept SIGCHLD
    $kernel->sig_child($task->PID, "sig_child");

	# Wheel events include the wheel's ID.
	$heap->{task_by_wid}->{$task->ID} = $task;
	# Signal events include the process ID.
	$heap->{task_by_pid}->{$task->PID} = $task;
	# Signal events include the process ID.
	$heap->{task_data}->{$task->ID} = {
		'timestamp' => $now,
		'iface' => $iface,
		'direction' => $direction,
		'stats' => { }
	};

	# Build commandline string
	my $cmdStr = join(' ',@{$cmd});
	$logger->log(LOG_DEBUG,"[TCSTATS] TASK/".$task->ID.": Starting '$cmdStr' as ".$task->ID." with PID ".$task->PID);
};


# Child writes to STDOUT
sub task_child_stdout
{
    my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
    my $child = $heap->{task_by_wid}->{$task_id};
    my $stats = $heap->{task_data}->{$task_id}->{'stats'};
    my $iface = $heap->{task_data}->{$task_id}->{'iface'};
    my $direction = $heap->{task_data}->{$task_id}->{'direction'};
    my $timestamp = $heap->{task_data}->{$task_id}->{'timestamp'};


#	$logger->log(LOG_INFO,"[TCSTATS] TASK/$task_id: STDOUT => ".$stdout);


	# If we have a class, blank our stats
	if ($stdout =~ /^class /) {
		%{$stats} = ( );
	}

	# class htb 1:1 root rate 100000Kbit ceil 100000Kbit burst 51800b cburst 51800b
	# class htb 1:3 parent 1:1 leaf 3: prio 7 rate 10000Kbit ceil 100000Kbit burst 6620b cburst 51800b
	if ($stdout =~ /^class htb ([0-9a-f]+:[0-9a-f]+) (?:parent )?([0-9a-f]+:[0-9a-f]+|root) (?:leaf ([0-9a-f]+): )?(?:prio ([0-9]+) )?rate ([0-9]+[MKG]?)bit ceil ([0-9]+[MKG]?)bit /) {
		my ($chandle,$phandle,$leaf,$prio,$rate,$ceil) = ($1,$2,$3,$4,$5,$6);

		($stats->{'_class_parent'},$stats->{'_class_child'}) = split(/:/,$chandle);
#		($stats->{'_chandle_main'},$stats->{'_chandle_sub'}) = split(/:/,$chandle);
#		$stats->{'_phandle'} = $phandle;
#		$stats->{'_leaf'} = $leaf;
		$stats->{'priority'} = $prio;
		$stats->{'rate'} = $rate;
		$stats->{'rate_burst'} = $ceil;

#		$logger->log(LOG_DEBUG,"[TCSTATS] FOUND: chandle = $chandle, phandle = $phandle, leaf = $leaf, prio = $prio, rate = $rate, ceil = $ceil");

	#   Sent 0 bytes 0 pkt (dropped 0, overlimits 0 requeues 0)
	} elsif ($stdout =~ / Sent ([0-9]+) bytes ([0-9]+) pkt \(dropped ([0-9]+), overlimits ([0-9]+) requeues ([0-9]+)\)/) {
		my ($sent_bytes,$sent_packets,$dropped,$overlimits,$requeues) = ($1,$2,$3,$4,$5);

		$stats->{'total_bytes'} = $sent_bytes;
		$stats->{'total_packets'} = $sent_packets;
		$stats->{'total_dropped'} = $dropped;
		$stats->{'total_overlimits'} = $overlimits;

#		$logger->log(LOG_DEBUG,"[TCSTATS] FOUND: sent_bytes = $sent_bytes, sent_packets = $sent_packets, dropped = $dropped, overlimits = $overlimits, requeues = $requeues");

	#   rate 0bit 0pps backlog 0b 0p requeues 0
	} elsif ($stdout =~ / rate ([0-9]+[MKG]?)bit ([0-9]+)pps backlog ([0-9]+[MKG]?)b ([0-9]+)p requeues ([0-9]+)/) {
		my ($rate_bits,$rate_packets,$backlog_bytes,$backlog_packets,$requeues) = ($1,$2,$3,$4,$5);

		$stats->{'current_rate'} = $rate_bits;
		$stats->{'current_pps'} = $rate_packets;
		$stats->{'current_queue_size'} = $backlog_bytes;
		$stats->{'current_queue_len'} = $backlog_packets;

#		$logger->log(LOG_DEBUG,"[TCSTATS] FOUND: rate_bits = $rate_bits, rate_packets = $rate_packets, backlog_bytes = $backlog_bytes, backlog_packets = $backlog_packets, requeues = $requeues");

	#   lended: 0 borrowed: 0 giants: 0
	} elsif ($stdout =~ / lended: ([0-9]+) borrowed: ([0-9]+) giants: ([0-9]+)/) {
		my ($lended,$borrowed,$giants) = ($1,$2,$3);

		$stats->{'lended'} = $lended;
		$stats->{'borrowed'} = $borrowed;
		
#		$logger->log(LOG_DEBUG,"[TCSTATS] FOUND: lended = $lended, borrowed = $borrowed, giants = $giants");

	#   tokens: 64968 ctokens: 64750
	} elsif ($stdout =~ / tokens/) {

	} elsif ($stdout eq "") {

		# If we don't have stats just return
		if (!%{$stats}) {
			return;
		}

		# Item to update
		my $item;

		# Is this a system class?
		if ($stats->{'_class_parent'} == 1 && (my $classChildDec = hex($stats->{'_class_child'})) < 100) {

			# Split off the different types of updates
			if ($classChildDec == 1) {
				$item = "main:${iface}:all";
			} elsif ($classChildDec == 2) {
				$item = "main:${iface}:classes";
			} elsif ($classChildDec == 3) {
				$item = "main:${iface}:besteffort";
			} else {
				$logger->log(LOG_WARN,"[TCSTATS] System traffic class '%s:%s' NOT FOUND",$stats->{'_class_parent'},$stats->{'_class_client'});
			}

		} else {
			$item = opentrafficshaper::plugins::tc::getUIDFromTcClass($stats->{'_class_child'});
			if (!$item) {
				$logger->log(LOG_WARN,"[TCSTATS] User for traffic class '%s:%s' NOT FOUND",$stats->{'_class_parent'},$stats->{'_class_client'});
			}
		}

		# Make sure we have the uid now
		if (defined($item)) {
			# Build our submission, this is basically copying the hash
			my %submission = %{$stats};
			$submission{'timestamp'} = $timestamp;
			$submission{'direction'} = $direction;

			$logger->log(LOG_DEBUG,"[TCSTATS] Submitting stats for [%s]",$item);
			$kernel->post("statistics" => "update" => $item => \%submission);
		}

		# Blank stats and start over
		$stats = { };
	}
}


# Child writes to STDERR
sub task_child_stderr
{
    my ($kernel,$heap,$stdout,$task_id) = @_[KERNEL,HEAP,ARG0,ARG1];
    my $child = $heap->{task_by_wid}->{$task_id};

	$logger->log(LOG_WARN,"[TCSTATS] TASK/$task_id: STDERR => ".$stdout);
}


# Child closed its handles, it won't communicate with us, so remove it
sub task_child_close
{
    my ($kernel,$heap,$task_id) = @_[KERNEL,HEAP,ARG0];
    my $child = delete($heap->{task_by_wid}->{$task_id});

    # May have been reaped by task_sigchld()
    if (!defined($child)) {
		$logger->log(LOG_DEBUG,"[TCSTATS] TASK/$task_id: Closed dead child");
		return;
    }

	$logger->log(LOG_DEBUG,"[TCSTATS] TASK/$task_id: Closed PID ".$child->PID);
    delete($heap->{task_by_pid}->{$child->PID});
    delete($heap->{task_by_pid}->{$task_id});

	# Fire up next tick
	$kernel->delay(tick => TICK_PERIOD);
}


# Reap the dead child
sub task_sigchld
{
	my ($kernel,$heap,$pid,$status) = @_[KERNEL,HEAP,ARG1,ARG2];
    my $child = delete($heap->{task_by_pid}->{$pid});


	$logger->log(LOG_DEBUG,"[TCSTATS] TASK: Task with PID $pid exited with status $status");

    # May have been reaped by task_child_close()
    return if (!defined($child));

    delete($heap->{task_by_wid}{$child->ID});
    delete($heap->{task_data}{$child->ID});
}




sub handle_SIGHUP
{
	$logger->log(LOG_WARN,"[TCSTATS] Got SIGHUP, ignoring for now");
}

1;
# vim: ts=4
