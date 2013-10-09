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


use DBI;
use POE;

use opentrafficshaper::constants;
use opentrafficshaper::logger;
use opentrafficshaper::utils;

use opentrafficshaper::plugins::configmanager qw( getLimitUsername );

# FIXME
use Time::HiRes qw( gettimeofday tv_interval );

# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
	STATISTICS_DIR_TX
	STATISTICS_DIR_RX
);
@EXPORT_OK = qw(
	getLastStats
	getCachedStats
);

use constant {
	VERSION => '0.0.1',
	# How often our config check ticks
	TICK_PERIOD => 1,

	STATISTICS_DIR_TX => 1,
	STATISTICS_DIR_RX => 2,
};


# Plugin info
our $pluginInfo = {
	Name => "Statistics Interface",
	Version => VERSION,

	Init => \&plugin_init,
	Start => \&plugin_start,
};

# There is no way to do this automatically
use constant { STATISTICS_NUM_ITEMS => 11 };


# Copy of system globals
my $globals;
my $logger;

# Our configuration
my $config = {
	'db_dsn' => undef,
	'db_username' => "",
	'db_password' => "",
};

# Stats configuration
my $statsConfig = {
	1 => {
		'precision' => 300,
		'retention' => 2, # 2 days
	},
	2 => {
		'precision' => 900,
		'retention' => 14, # 2 week
	},
	3 => {
		'precision' => 3600,
		'retention' => 28 * 2, # 2 months
	},
	4 => {
		'precision' => 21600, # 6hr
		'retention' => 28 * 12 * 2, # 2 years
	},
};


# Handle of DBI
my $dbi;
# DB user mappings
my $statsDBLIDMap = { };
# Stats queue
my $statsQueue = [ ];
my $cleanupQueue = [ ];
# Stats ubscribers
my $subscribers;
# Prepared statements we need...
my $statsPreparedStatements = { };
# Last cleanup time
my $lastCleanup = { };


# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[STATISTICS] OpenTrafficShaper Statistics v".VERSION." - Copyright (c) 2013, AllWorldIT");


	# Check our interfaces
	if (defined(my $dbdsn = $globals->{'file.config'}->{'plugin.statistics'}->{'db_dsn'})) {
		$logger->log(LOG_INFO,"[STATISTICS] Set db_dsn to '$dbdsn'");
		$config->{'db_dsn'} = $dbdsn;
	} else {
		$logger->log(LOG_WARN,"[STATISTICS] No db_dsn to specified in configuration file. Stats storage disabled!");
	}
	if (defined(my $dbuser = $globals->{'file.config'}->{'plugin.statistics'}->{'db_username'})) {
		$logger->log(LOG_INFO,"[STATISTICS] Set db_username to '$dbuser'");
		$config->{'db_username'} = $dbuser;
	}
	if (defined(my $dbpass = $globals->{'file.config'}->{'plugin.statistics'}->{'db_password'})) {
		$logger->log(LOG_INFO,"[STATISTICS] Set db_password to '$dbpass'");
		$config->{'db_password'} = $dbpass;
	}

	# This is our main stats session
	POE::Session->create(
		inline_states => {
			_start => \&session_start,
			_stop => \&session_stop,

			tick => \&session_tick,

			db_ready => \&do_db_ready,
			db_notready => \&do_db_notready,
			db_query_success => \&do_db_query_success,
			db_query_failure => \&do_db_query_failure,

			# Stats update event
			update => \&do_update,
			# Subscription events
			subscribe => \&do_subscribe,
			unsubscribe => \&do_unsubscribe,

		}
	);

	# Create DBI agent
	if (defined($config->{'db_dsn'})) {
		$dbi = DBI->connect(
				$config->{'db_dsn'}, $config->{'db_username'}, $config->{'db_password'},
				{
					'AutoCommit' => 1,
					'RaiseError' => 1,
					'FetchHashKeyName' => 'NAME_lc'
				}
		);
		if (!defined($dbi)) {
# FIXME
#warn $DBI::errstr;
		}

		# If we're working with SQLite, we need to apply some performance pragma's
		if ($config->{'db_dsn'} =~ /sqlite/i) {
			$logger->log(LOG_INFO,"[STATISTICS] Applied SQLite PRAGMA's");
			$dbi->do("PRAGMA journal_mode = OFF");
			$dbi->do("PRAGMA synchronous = OFF");
			$dbi->do("PRAGMA cache_size = -32768");
		}

		my $res = $dbi->prepare('
			INSERT INTO users (`Username`) VALUES (?)
		');
		if ($res) {
			$statsPreparedStatements->{'user_add'} = $res;
		}
#FIXME

		$statsPreparedStatements->{'user_get'} = $dbi->prepare('
			SELECT ID FROM users WHERE `Username` = ?
		');
# FIXME
		$statsPreparedStatements->{'stats_add'} = $dbi->prepare('
			INSERT INTO stats
				(
					`UserID`, `Key`, `Timestamp`,
					`Direction`,
					`CIR`, `Limit`, `Rate`, `PPS`, `Queue_Len`,
					`Total_Bytes`, `Total_Packets`, `Total_Overlimits`, `Total_Dropped`
				)
			VALUES
				(
					?, ?, ?,
					?,
					?, ?, ?, ?, ?,
					?, ?, ?, ?
				)
		');

		# Set last cleanup to now
		foreach my $key (keys %{$statsConfig}) {
			$lastCleanup->{$key} = time();
		}
	}


	return 1;
}


# Start the plugin
sub plugin_start
{
	$logger->log(LOG_INFO,"[STATISTICS] Started");

}


# Initialize this plugins main POE session
sub session_start
{
	my ($kernel,$heap) = @_[KERNEL, HEAP];


	# Set our alias
	$kernel->alias_set("statistics");

	# Set delay on config updates
	$kernel->delay(tick => TICK_PERIOD);

	$logger->log(LOG_DEBUG,"[STATISTICS] Initialized");
}


# Stop session
sub session_stop
{
	my ($kernel,$heap) = @_[KERNEL, HEAP];


	# Remove our alias
	$kernel->alias_remove("statistics");

	# Tear down data
	$globals = undef;
	$dbi = undef;
	$statsDBLIDMap = { };
	$subscribers = undef;
	$statsPreparedStatements = { };
	$lastCleanup = undef;

	$logger->log(LOG_DEBUG,"[STATISTICS] Shutdown");

	$logger = undef;
}


# Time ticker for processing changes
sub session_tick
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];

	my $now = time();
	my $timer1 = [gettimeofday];

	my $statsAddSTH = $statsPreparedStatements->{'stats_add'};

	my $maxFlush = int(@{$statsQueue} / 300) + 1;
	my $numFlush = 0;

	# Loop...
	my @tstSt;
	my @tstVals;
	while (defined(my $stat = shift(@{$statsQueue})) && $numFlush < $maxFlush) {
		# NK
#		my $res = $statsAddSTH->execute(
#			$stat->{'userid'}, $stat->{'key'}, $stat->{'timestamp'},
#			$stat->{'direction'},
#			$stat->{'cir'}, $stat->{'limit'}, $stat->{'rate'}, $stat->{'pps'}, $stat->{'queue_len'},
#			$stat->{'total_bytes'}, $stat->{'total_packets'}, $stat->{'total_overlimits'}, $stat->{'total_dropped'}
#		);
#		if (!defined($res)) {
# FIXME
#warn "DB QUERY FAILED: ".$statsAddSTH->errstr();
#		}
		push(@tstVals,
			$stat->{'userid'}, $stat->{'key'}, $stat->{'timestamp'},
			$stat->{'direction'},
			$stat->{'cir'}, $stat->{'limit'}, $stat->{'rate'}, $stat->{'pps'}, $stat->{'queue_len'},
			$stat->{'total_bytes'}, $stat->{'total_packets'}, $stat->{'total_overlimits'}, $stat->{'total_dropped'}
		);
		push(@tstSt,"(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)");
		$numFlush++;
	}

# FIXME - TEST
	if (@tstVals > 0) {
	my $res = $dbi->do('
			INSERT INTO stats
				(
					`UserID`, `Key`, `Timestamp`,
					`Direction`,
					`CIR`, `Limit`, `Rate`, `PPS`, `Queue_Len`,
					`Total_Bytes`, `Total_Packets`, `Total_Overlimits`, `Total_Dropped`
				)
			VALUES
	'.join(',',@tstSt),undef,@tstVals);

		if (!defined($res)) {
#warn "DB QUERY FAILED: ".$dbi->errstr();
		}
	}

	my $timer2 = [gettimeofday];
	my $timediff2 = tv_interval($timer1,$timer2);
	warn "STATS FLUSH: $numFlush/$maxFlush records, time ".sprintf('%.3fs',$timediff2);





	my $res;


	my $sth = $dbi->prepare('
		SELECT
			*
		FROM
			stats
		WHERE
			`Key` = ?
			AND `Timestamp` > ?
			AND `Timestamp` < ?
	');

	my $sth2 = $dbi->prepare('
		DELETE
		FROM
			stats
		WHERE
			`Key` = ?
			AND `Timestamp` < ?
	');

	my $sth3 = $dbi->prepare('
		SELECT
			ID
		FROM
			stats
		WHERE
			`Key` = ?
			AND `Timestamp` < ?
	');



	my @statsMaxItems = (
		'cir','limit','rate','pps','queue_len',
	);

	my @statsAvgItems = (
		'total_bytes','total_packets','total_overlimits','total_dropped'
	);

	# Loop with our stats consolidation configuration
	foreach my $key (keys %{$statsConfig}) {
		my $timerA = [gettimeofday];

		my $precision = $statsConfig->{$key}->{'precision'};
		my $thisPeriod = _getAlignedTime($now,$precision);
		my $lastPeriod = $thisPeriod - $precision;
		my $prevKey = $key - 1;

		# If we havn't exited the last period, then skip
		if ($lastCleanup->{$key} > $lastPeriod) {
			next;
		}
		# Set last cleanup to now
		$lastCleanup->{$key} = $now;

		# Pull last periods rows
		$res = $sth->execute($prevKey,$lastPeriod - $precision,$lastPeriod);

		my $cData = {};
		while (my $item = $sth->fetchrow_hashref()) {
			my $itemPeriod = _getAlignedTime($item->{'timestamp'},$precision);

			# If this user for this period or direction doesn't exist, create it
			if (
					!defined($cData->{$item->{'userid'}}) ||
					!defined($cData->{$item->{'userid'}}->{$itemPeriod}) ||
					!defined($cData->{$item->{'userid'}}->{$itemPeriod}->{$item->{'direction'}})
			) {
				# Set 0's for everything
				foreach my $key (@statsMaxItems,@statsAvgItems) {
					$cData->{$item->{'userid'}}->{$itemPeriod}->{$item->{'direction'}}->{$key} = 0;
				}
				# And number of records to 0 too
				$cData->{$item->{'userid'}}->{$itemPeriod}->{$item->{'direction'}}->{'_recs'} = 0;
			}

			# Setup easy to use stats variable
			my $curStat = $cData->{$item->{'userid'}}->{$itemPeriod}->{$item->{direction}};

			# Check max items
			foreach my $key (@statsMaxItems) {
					# Only set if current item is higher
					if ($item->{$key} > $curStat->{$key}) {
						$curStat->{$key} = $item->{$key};
					}
			}
			# Work out averages
			foreach my $key (@statsAvgItems) {
					$curStat->{$key} += $item->{$key};
			}

			$curStat->{'_recs'}++;
		}

		# Loop with user ID's
		foreach my $userid (keys %{$cData}) {
			# Loop with periods
			foreach my $period (keys %{$cData->{$userid}}) {
				# Loop with directions
				foreach my $direction (keys %{$cData->{$userid}->{$period}}) {
					my $curStat = $cData->{$userid}->{$period}->{$direction};
					# Make sure our avrages are divided properly
					foreach my $item (@statsAvgItems) {
						$curStat->{$item} = int($curStat->{$item} / $curStat->{'_recs'});
					}

					# Setup other items we need to insert
					$curStat->{'userid'} = $userid;
					$curStat->{'key'} = $key;
					$curStat->{'timestamp'} = $period;
					$curStat->{'direction'} = $direction;

					# Queue for insert
					push(@{$statsQueue},$curStat);
				}
			}
		}

		my $timerB = [gettimeofday];
		my $timediffB = tv_interval($timerA,$timerB);
		warn "COMPUTE TIME: $key @ ".sprintf('%.3fs',$timediffB);
	}

	my $timer3 = [gettimeofday];

# FIXME hard coded 1800 for the stats stream
	$res = $sth2->execute(0, $now - 1800);

	foreach my $key (keys %{$statsConfig}) {
		$res = $sth2->execute($key, $now - ($statsConfig->{$key}->{'retention'} * 86400)  );
	}



	my $timer4 = [gettimeofday];
	my $timediff4 = tv_interval($timer3,$timer4);
	 warn "DB CLEAN TIME: ".sprintf('%.3fs',$timediff4);




END:
	# Set delay on config updates
	$kernel->delay(tick => TICK_PERIOD);
}


# Update limit Statistics
# $item has some special use cases:
#	main:$iface:all	- Interface total stats
#	main:$iface:classes	- Interface classified traffic
#	main:$iface:besteffort	- Interface best effort traffic
sub do_update
{
	my ($kernel, $statsData) = @_[KERNEL, ARG0];




my $timer0 = [gettimeofday];

	# Loop through stats data we got
	foreach my $rawItem (keys %{$statsData}) {
		my $stat = $statsData->{$rawItem};


		# ID of the stat item in the stats table
		my $statsID;

		if ($rawItem =~ /^main/) {
#			$statsItem = $rawItem;
#FIXME
next;

		} else {
			if (!defined($statsID = _getStatsIDFromLID($rawItem))) {
# FIXME
warn "IT BLEW UP!!!";
				next;
			}
		}

		$stat->{'userid'} = $statsID;
		$stat->{'key'} = 0;

		push(@{$statsQueue},$stat);



#		# Check if we have an event handler subscriber for this item
#		if (defined($subscribers->{$statsItem}) && %{$subscribers->{$statsItem}}) {
#			# If we do, loop with them
#			foreach my $handler (keys %{$subscribers->{$statsItem}}) {
#
#				# If no events are linked to this handler, continue
#				if (!(keys %{$subscribers->{$statsItem}->{$handler}})) {
#					next;
#				}
#
#				# Or ... If we have events, process them
#				foreach my $event (keys %{$subscribers->{$statsItem}->{$handler}}) {
#
#					$kernel->post($handler => $event => $statsItem => $stat);
#				}
#			}
#		}
	}

	my $timer1 = [gettimeofday];
	 my $timediff1 = tv_interval($timer0,$timer1);
	 warn "STATS TIME: ".sprintf('%.3fs',$timediff1);

#	use Devel::Size qw(total_size);
#	warn "QUEUE SIZE: ".total_size($statsQueue);
}


# Handle subscriptions to updates
sub do_subscribe
{
	my ($kernel, $handler, $handlerEvent, $item) = @_[KERNEL, ARG0, ARG1, ARG2];


	$logger->log(LOG_INFO,"[STATISTICS] Got subscription request from '$handler' for '$item' via event '$handlerEvent'");

	$subscribers->{$item}->{$handler}->{$handlerEvent} = $item;
}


# Handle unsubscribes
sub do_unsubscribe
{
	my ($kernel, $handler, $handlerEvent, $item) = @_[KERNEL, ARG0, ARG1, ARG2];


	$logger->log(LOG_INFO,"[STATISTICS] Got unsubscription request for '$handler' regarding '$item'");

	delete($subscribers->{$item}->{$handler}->{$handlerEvent});
}

# Return user last stats
sub getLastStats
{
	my $lid = shift;

	my $statistics;

#	# Do we have stats for this user in the cache?
#	if (defined($statsCache->{$lid})) {
#		# Grab last entry
#		my $lastTimestamp = (sort keys %{$statsCache->{$lid}})[-1];
#		# We should ALWAYS have one, unless the server just booted
#		if (defined($lastTimestamp)) {
#			# Loop with both directions
#			foreach my $direction ('tx','rx') {
#				# Get a easier to use handle on the stats
#				if (my $stats = $statsCache->{$lid}->{$lastTimestamp}->{$direction}) {
#					# Setup the statistics hash
#					$statistics->{$direction} = {
#						'current_rate' => $stats->{'current_rate'},
#						'current_pps' => $stats->{'current_pps'},
#					};
#				}
#			}
#		}
#	}

	return $statistics;
}

# Return userstats
sub getStats
{
	my $lid = shift;


	my $now = time();

	# Max entries
	my $entriesLeft = 100;

	# Grab stats ID from LID
	my $userid = _getCachedStatsIDFromLID($lid);

	my $sth = $dbi->prepare('
		SELECT
			`Timestamp`, `Direction`, `Rate`, `PPS`, `CIR`, `Limit`
		FROM
			stats
		WHERE
			`UserID` = ?
			AND `Key` = ?
			AND `Timestamp` > ?
			AND `Timestamp` < ?
		ORDER BY
			`Timestamp` DESC
		LIMIT 100
	');

	$sth->execute($userid,0,$now - 900, $now);

	my $statistics;
	while (my $item = $sth->fetchrow_hashref()) {
		# Make direction a bit easier to use
		my $direction;
		if ($item->{'direction'} eq STATISTICS_DIR_TX) {
			$direction = 'tx';
		} elsif ($item->{'direction'} eq STATISTICS_DIR_RX) {
			$direction = 'rx';
# FIXME
		} else {
			next;
		}

		# Loop with both directions
		$statistics->{$item->{'timestamp'}}->{$direction} = {
			'rate' => $item->{'rate'},
			'pps' => $item->{'pps'},
			'cir' => $item->{'cir'},
			'limit' => $item->{'limit'},
		}
	}

#	# Do we have stats for this user in the cache?
#	if (defined($statsCache->{$lid})) {
#		# Loop with cache entries
#		foreach my $timestamp (reverse sort keys %{$statsCache->{$lid}}) {
#			# Loop with both directions
#			foreach my $direction ('tx','rx') {
#				# Get a easier to use handle on the stats
#				if (my $stats = $statsCache->{$lid}->{$timestamp}->{$direction}) {
#					# Setup the statistics hash
#					$statistics->{$timestamp}->{$direction} = {
#						'current_rate' => $stats->{'current_rate'},
#						'current_pps' => $stats->{'current_pps'},
#					};
#				}
#			}
#
#			$entriesLeft--;
#
#			# If we hit 0, break out the loop
#			last if (!$entriesLeft);
#		}
#	}

	return $statistics;
}


#
# Internal Functions
#

sub _getCachedStatsIDFromLID
{
	my $lid = shift;


	# If we don't have a user mapped
	if (defined(my $statsID = $statsDBLIDMap->{$lid})) {
		return $statsID;
	}

	return undef;
}


sub _getStatsIDFromLID
{
	my $lid = shift;


	# Check if we have it cached
	if (my $userid = _getCachedStatsIDFromLID($lid)) {
		return $userid;
	}

	# Check if we got a limit username
	my $username;
	if (!defined($username = getLimitUsername($lid))) {
		# If not ... just exit?
		return undef;
	}

	# Try grab it from DB
	my $userGetSTH = $statsPreparedStatements->{'user_get'};
	if (my $res = $userGetSTH->execute($username)) {
		# Grab first row and return
		if (my $row = $userGetSTH->fetchrow_hashref()) {
			return $statsDBLIDMap->{$lid} = $row->{'id'};
		}
	} else {
# FIXME
warn "FAILED TO EXECUTE GETUSER: ".$userGetSTH->errstr;
	}

	# Try add it to the DB
	my $userAddSTH = $statsPreparedStatements->{'user_add'};
	if (my $res = $userAddSTH->execute($username)) {
		return $statsDBLIDMap->{$lid} = $dbi->last_insert_id("","","","");
	} else {
warn "DB ADD USER ERROR: ".$userAddSTH->errstr;
	}
}


# Get aligned time on a Precision
sub _getAlignedTime
{
	my ($time,$precision) = @_;
	return $time - ($time % $precision);
}



1;
# vim: ts=4
