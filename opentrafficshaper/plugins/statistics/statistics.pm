# OpenTrafficShaper Traffic shaping statistics
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



package opentrafficshaper::plugins::statistics;

use strict;
use warnings;

use POE;
use Storable qw( dclone );

use awitpt::db::dblayer;
use opentrafficshaper::constants;
use opentrafficshaper::logger;

use opentrafficshaper::plugins::configmanager qw(
		getPool
		getPools
		getPoolMembers

		getPoolTxInterface
		getPoolRxInterface
		getPoolTrafficClassID

		getTrafficClasses
		getAllTrafficClasses
);

# NK: TODO: Maybe we want to remove timing at some stage? maybe not?
use Time::HiRes qw( gettimeofday tv_interval );

# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
	STATISTICS_PERIOD

	STATISTICS_DIR_TX
	STATISTICS_DIR_RX
);
@EXPORT_OK = qw(
	getLastStats

	getStatsBySID
	getStatsBasicBySID

	getSIDFromCID
	getSIDFromPID
);

use constant {
	VERSION => '0.2.2',
	# How often our config check ticks
	TICK_PERIOD => 5,

	STATISTICS_PERIOD => 60,

	STATISTICS_DIR_TX => 1,
	STATISTICS_DIR_RX => 2,

	STATISTICS_MAXFLUSH_PER_PERIOD => 10000,

	# SQL Statements
	SQL_ADD_IDENTIFIER => 'INSERT INTO identifiers (`Identifier`) VALUES (?)',
	SQL_GET_IDENTIFIER => 'SELECT ID FROM identifiers WHERE `Identifier` = ?',
	SQL_CONSOLIDATE_STATS => '
		SELECT
			`IdentifierID`, `Timestamp` - (`Timestamp` % ?) AS Timestamp,
			`Direction`,
			MAX(`CIR`) AS `CIR`, MAX(`Limit`) AS `Limit`, MAX(`Rate`) AS `Rate`, MAX(`PPS`) AS `PPS`,
			MAX(`QueueLen`) AS `QueueLen`, MAX(`TotalBytes`) AS `TotalBytes`, MAX(`TotalPackets`) AS `TotalPackets`,
			MAX(`TotalOverlimits`) AS `TotalOverlimits`, MAX(`TotalDropped`) AS `TotalDropped`
		FROM
			stats
		WHERE
			`Key` = ?
			AND `Timestamp` > ?
			AND `Timestamp` < ?
		GROUP BY
			`IdentifierID`, `Timestamp`, `Direction`
	',
	SQL_CONSOLIDATE_STATS_BASIC => '
		SELECT
			`IdentifierID`, `Timestamp` - (`Timestamp` % ?) AS Timestamp,
			MAX(`Counter`) AS `Counter`
		FROM
			stats_basic
		WHERE
			`Key` = ?
			AND `Timestamp` > ?
			AND `Timestamp` < ?
		GROUP BY
			`IdentifierID`, `Timestamp`
	',
	SQL_GET_STATS => '
		SELECT
			`Timestamp`, `Direction`, `Rate`, `PPS`, `CIR`, `Limit`
		FROM
			stats
		WHERE
			`IdentifierID` = ?
			AND `Key` = ?
			AND `Timestamp` > ?
			AND `Timestamp` < ?
	',
	SQL_GET_STATS_BASIC => '
		SELECT
			`Timestamp`, `Counter`
		FROM
			stats_basic
		WHERE
			`IdentifierID` = ?
			AND `Key` = ?
			AND `Timestamp` > ?
			AND `Timestamp` < ?
	',
	SQL_CLEANUP_STATS => 'DELETE FROM stats WHERE `Key` = ? AND `Timestamp` < ?',
	SQL_CLEANUP_STATS_BASIC => 'DELETE FROM stats_basic WHERE `Key` = ? AND `Timestamp` < ?'

};

sub STATS_CONFIG
{
	{
		1 => {
			'precision' => 300, # 5min
			'retention' => 4, # 4 days
		},
		2 => {
			'precision' => 900, # 15min
			'retention' => 14, # 14 days
		},
		3 => {
			'precision' => 3600, # 1hr
			'retention' => 28 * 2, # 2 months
		},
		4 => {
			'precision' => 21600, # 6hr
			'retention' => 28 * 6, # 6 months
		},
		5 => {
			'precision' => 86400, # 24hr
			'retention' => 28 * 12 * 2, # 2 years
		}
	}
}


# Plugin info
our $pluginInfo = {
	Name => "Statistics Interface",
	Version => VERSION,

	Init => \&plugin_init,
	Start => \&plugin_start,
};


# Copy of system globals
my $globals;
my $logger;


# Handle of DBI
#
# $globals->{'Database'}->{'Handle'}
# $globals->{'Database'}->{'DSN'}
# $globals->{'Database'}->{'Username'}
# $globals->{'Database'}->{'Password'}

# DB identifier map
#
# $globals->{'IdentifierMap'}

# Stats queue
#
# $globals->{'StatsQueue'}
# $globals->{'LastCleanup'}
# $globals->{'LastConfigManagerStats'}

# Stats subscribers & counter
# $globals->{'SIDSubscribers'}
# $globals->{'SSIDMap'}
# $globals->{'SSIDCounter'}
# $globals->{'SSIDCounterFreeList'}



# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[STATISTICS] OpenTrafficShaper Statistics v%s - Copyright (c) 2007-2014, AllWorldIT",VERSION);

	# Initialize
	$globals->{'Database'} = undef;

	$globals->{'IdentifierMap'} = { };

	$globals->{'StatsQueue'} = [ ];
	$globals->{'LastCleanup'} = { };
	$globals->{'LastConfigManagerStats'} = { };

	$globals->{'SIDSubscribers'} = { };
	$globals->{'SSIDMap'} = { };
	$globals->{'SSIDCounter'} = 0;
	$globals->{'SSIDCounterFreeList'} = [ ];


	# Check our interfaces
	if (defined(my $dbdsn = $globals->{'file.config'}->{'plugin.statistics'}->{'db_dsn'})) {
		$logger->log(LOG_INFO,"[STATISTICS] Set database DSN to '%s'",$dbdsn);
		$globals->{'Database'}->{'DSN'} = $dbdsn;

		if (defined(my $dbuser = $globals->{'file.config'}->{'plugin.statistics'}->{'db_username'})) {
			$logger->log(LOG_INFO,"[STATISTICS] Set database username to '%s'",$dbuser);
			$globals->{'Database'}->{'Username'} = $dbuser;
		}
		if (defined(my $dbpass = $globals->{'file.config'}->{'plugin.statistics'}->{'db_password'})) {
			$logger->log(LOG_INFO,"[STATISTICS] Set database password to '%s'",$dbpass);
			$globals->{'Database'}->{'Password'} = $dbpass;
		}
	} else {
		$logger->log(LOG_WARN,"[STATISTICS] No database DSN to specified in configuration file. Stats storage disabled!");
	}

	# This is our main stats session
	POE::Session->create(
		inline_states => {
			_start => \&_session_start,
			_stop => \&_session_stop,
			_tick => \&_session_tick,

			# Stats update event
			update => \&_session_update,
		}
	);

	# Create DBI agent
	if (defined($globals->{'Database'})) {
		$globals->{'Database'}->{'Handle'} = DBInit({
			'DSN' => $globals->{'Database'}->{'DSN'},
			'Username' => $globals->{'Database'}->{'Username'},
			'Password' => $globals->{'Database'}->{'Password'}
		});
		# Check if handle is defined
		if (defined($globals->{'Database'}->{'Handle'})) {
			# Try connect (0 is success)
			if (!DBConnect()) {
				$logger->log(LOG_INFO,"[STATISTICS] Connected to database");
			} else {
				$logger->log(LOG_ERR,"[STATISTICS] Failed to connect to database: %s (DATABASE DISABLED)",
						awitpt::db::dblayer::Error());
				# Don't try again
				delete($globals->{'Database'});
			}
		# If the handle is not defined, the database won't work
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to initailize database: %s (DATABASE DISABLED)",
					awitpt::db::dblayer::Error());
		}

		# Set last cleanup to now
		my $now = time();
		foreach my $key (keys %{STATS_CONFIG()}) {
			# Get aligned time so we cleanup sooner
			$globals->{'LastCleanup'}->{$key} = _getAlignedTime($now,STATS_CONFIG()->{$key}->{'precision'});
		}
		$globals->{'LastConfigManagerStats'} = $now;
	}

	return 1;
}



# Start the plugin
sub plugin_start
{
	$logger->log(LOG_INFO,"[STATISTICS] Started");

}



# Initialize this plugins main POE session
sub _session_start
{
	my ($kernel,$heap) = @_[KERNEL, HEAP];


	# Set our alias
	$kernel->alias_set("statistics");

	# Set delay on config updates
	$kernel->delay('_tick' => TICK_PERIOD);

	$logger->log(LOG_DEBUG,"[STATISTICS] Initialized");
}



# Stop session
sub _session_stop
{
	my ($kernel,$heap) = @_[KERNEL, HEAP];


	# Remove our alias
	$kernel->alias_remove("statistics");

	# Tear down data
	$globals = undef;

	$logger->log(LOG_DEBUG,"[STATISTICS] Shutdown");

	$logger = undef;
}



# Time ticker for processing changes
sub _session_tick
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# If we don't have a database, just skip...
	if (!$globals->{'Database'}) {
		return;
	}

	my $now = time();
	my $timer1 = [gettimeofday];

	# Even out flushing over 10s to absorb spikes
	my $totalFlush = @{$globals->{'StatsQueue'}};
	my $maxFlush = int($totalFlush / 10) + 100;
	my $numFlush = 0;

	# Make sure we don't write more than 10k entries per pass
	if ($maxFlush > STATISTICS_MAXFLUSH_PER_PERIOD) {
		$maxFlush = STATISTICS_MAXFLUSH_PER_PERIOD;
	}

	# Loop and build the data to create our multi-insert
	my (@insertHolders,@insertBasicHolders);
	my (@insertData,@insertBasicData);
	while (defined(my $stat = shift(@{$globals->{'StatsQueue'}})) && $numFlush < $maxFlush) {
		# This is a basic counter
		if (defined($stat->{'Counter'})) {
			push(@insertBasicHolders,"(?,?,?,?)");
			push(@insertBasicData,
				$stat->{'IdentifierID'}, $stat->{'Key'}, $stat->{'Timestamp'},
				$stat->{'Counter'}
			);
		# Full stats counter
		} else {
			push(@insertHolders,"(?,?,?,?,?,?,?,?,?,?,?,?,?)");
			push(@insertData,
				$stat->{'IdentifierID'}, $stat->{'Key'}, $stat->{'Timestamp'},
				$stat->{'Direction'},
				$stat->{'CIR'}, $stat->{'Limit'}, $stat->{'Rate'}, $stat->{'PPS'}, $stat->{'QueueLen'},
				$stat->{'TotalBytes'}, $stat->{'TotalPackets'}, $stat->{'TotalOverlimits'}, $stat->{'TotalDropped'}
			);
		}

		$numFlush++;
	}

	# If we got things to insert, do it
	if (@insertBasicHolders > 0) {
		my $res = DBDo('
			INSERT DELAYED INTO stats_basic
				(
					`IdentifierID`, `Key`, `Timestamp`,
					`Counter`
				)
			VALUES
				'.join(',',@insertBasicHolders),@insertBasicData
		);
		# Check for error
		if (!defined($res)) {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute delayed stats_basic insert: %s",awitpt::db::dblayer::Error());
		}
	}
	# And normal stats...
	if (@insertHolders > 0) {
		my $res = DBDo('
			INSERT DELAYED INTO stats
				(
					`IdentifierID`, `Key`, `Timestamp`,
					`Direction`,
					`CIR`, `Limit`, `Rate`, `PPS`, `QueueLen`,
					`TotalBytes`, `TotalPackets`, `TotalOverlimits`, `TotalDropped`
				)
			VALUES
				'.join(',',@insertHolders),@insertData
		);
		# Check for error
		if (!defined($res)) {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute delayed stats insert: %s",awitpt::db::dblayer::Error());
		}
	}

	my $timer2 = [gettimeofday];
	# We only need stats if we did something, right?
	if ($numFlush) {
		my $timediff2 = tv_interval($timer1,$timer2);
		$logger->log(LOG_INFO,"[STATISTICS] Total stats flush time %s/%s records: %s",
			$numFlush,
			$totalFlush,
			sprintf('%.3fs',$timediff2)
		);
	}

	my $res;

	# Loop with our stats consolidation configuration
	foreach my $key (sort keys %{STATS_CONFIG()}) {
		my $timerA = [gettimeofday];

		my $precision = STATS_CONFIG()->{$key}->{'precision'};
		my $thisPeriod = _getAlignedTime($now,$precision);
		my $lastPeriod = $thisPeriod - $precision;
		my $prevKey = $key - 1;
		# If we havn't exited the last period, then skip
		if ($globals->{'LastCleanup'}->{$key} > $lastPeriod) {
			next;
		}

		# Stats
		my $numStatsBasicConsolidated = 0;
		my $numStatsConsolidated = 0;

		my $consolidateFrom = $lastPeriod - $precision * 2;
		my $consolidateUpTo = $lastPeriod - $precision;

		# Execute and pull in consolidated stats
		$res = DBSelect(SQL_CONSOLIDATE_STATS_BASIC,$precision,$prevKey,$consolidateFrom,$consolidateUpTo);
		if ($res) {
			# Loop with items returned
			while (my $item = hashifyLCtoMC($res->fetchrow_hashref(),'IdentifierID','Timestamp','Counter')) {
				$item->{'Key'} = $key;

				# Queue for insert
				push(@{$globals->{'StatsQueue'}},$item);

				$numStatsBasicConsolidated++;
			}
			DBFreeRes($res);
		# If there was an error, make sure we report it
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats_basic consolidation statement: %s",
					awitpt::db::dblayer::Error());
		}
		# And the normal stats...
		$res = DBSelect(SQL_CONSOLIDATE_STATS,$precision,$prevKey,$consolidateFrom,$consolidateUpTo);
		if ($res) {
			# Loop with items returned
			while (my $item = hashifyLCtoMC(
				$res->fetchrow_hashref(),
				'IdentifierID','Timestamp','Direction','CIR','Limit','Rate','PPS','QueueLen','TotalBytes','TotalPackets',
				'TotalOverLimits','TotalDropped'
			)) {
				$item->{'Key'} = $key;

				# Queue for insert
				push(@{$globals->{'StatsQueue'}},$item);

				$numStatsConsolidated++;
			}
			DBFreeRes($res);
		# If there was an error, make sure we report it
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats consolidation statement: %s",
					awitpt::db::dblayer::Error());
		}

		# Set last cleanup to now
		$globals->{'LastCleanup'}->{$key} = $now;

		my $timerB = [gettimeofday];
		my $timediffB = tv_interval($timerA,$timerB);

		$logger->log(LOG_INFO,"[STATISTICS] Stats consolidation: key %s in %s (%s basic, %s normal), period %s - %s [%s - %s]",
			$key,
			sprintf('%.3fs',$timediffB),
			$numStatsBasicConsolidated,
			$numStatsConsolidated,
			$consolidateFrom,
			$consolidateUpTo,
			scalar(localtime($consolidateFrom)),
			scalar(localtime($consolidateUpTo))
		);
	}

	# Setup another timer
	my $timer3 = [gettimeofday];

	# We only need to run as often as the first precision
	# - If cleanup has not yet run?
	# - or if the 0 cleanup plus precision of the first key is in the past (data is now stale?)
	if (!defined($globals->{'LastCleanup'}->{'0'}) || $globals->{'LastCleanup'}->{'0'} + STATS_CONFIG()->{1}->{'precision'} < $now) {
		# We're going to clean up for the first stats precision * 3, which should be enough
		my $cleanUpTo = $now - (STATS_CONFIG()->{1}->{'precision'} * 3);

		# Streamed stats is removed 3 time periods past the first precision
		my $timerA = [gettimeofday];
		if ($res = DBDo(SQL_CLEANUP_STATS_BASIC,0,$cleanUpTo)) {
			my $timerB = [gettimeofday];
			my $timerdiffA = tv_interval($timerA,$timerB);

			# We get 0E0 for 0 when none were removed
			if ($res ne "0E0") {
				$logger->log(LOG_INFO,"[STATISTICS] Cleanup streamed stats_basic, %s items in %s, up to %s [%s]",
					$res,
					sprintf('%.3fs',$timerdiffA),
					$cleanUpTo,
					scalar(localtime($cleanUpTo)),
				);
			}
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats_basic cleanup statement: %s",
					awitpt::db::dblayer::Error());
		}

		# And the normal stats...
		$timerA = [gettimeofday];
		if ($res = DBDo(SQL_CLEANUP_STATS,0,$cleanUpTo)) {
			my $timerB = [gettimeofday];
			my $timerdiffA = tv_interval($timerA,$timerB);

			# We get 0E0 for 0 when none were removed
			if ($res ne "0E0") {
				$logger->log(LOG_INFO,"[STATISTICS] Cleanup streamed stats, %s items in %s, up to %s [%s]",
					$res,
					sprintf('%.3fs',$timerdiffA),
					$cleanUpTo,scalar(localtime($cleanUpTo))
				);
			}
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats cleanup statement: %s",
				awitpt::db::dblayer::Error()
			);
		}

		# Loop and remove retained stats
		foreach my $key (keys %{STATS_CONFIG()}) {
			# Work out timestamp to clean up to by multiplying the retention period by days
			$cleanUpTo = $now - (STATS_CONFIG()->{$key}->{'retention'} * 86400);

			# Retention period is in # days
			my $timerA = [gettimeofday];
			if ($res = DBDo(SQL_CLEANUP_STATS_BASIC,$key,$cleanUpTo)) {
				# We get 0E0 for 0 when none were removed
				if ($res ne "0E0") {
					my $timerB = [gettimeofday];
					my $timerdiffA = tv_interval($timerA,$timerB);

					$logger->log(LOG_INFO,"[STATISTICS] Cleanup stats_basic key %s in %s, %s items up to %s [%s]",
						$key,
						sprintf('%.3fs',$timerdiffA),
						$res,
						$cleanUpTo,
						scalar(localtime($cleanUpTo))
					);
				}
			} else {
				$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats_basic cleanup statement for key %s: %s",
					$key,
					awitpt::db::dblayer::Error()
				);
			}
			# And normal stats...
			$timerA = [gettimeofday];
			if ($res = DBDo(SQL_CLEANUP_STATS,$key,$cleanUpTo)) {
				# We get 0E0 for 0 when none were removed
				if ($res ne "0E0") {
					my $timerB = [gettimeofday];
					my $timerdiffA = tv_interval($timerA,$timerB);

					$logger->log(LOG_INFO,"[STATISTICS] Cleanup stats key %s in %s, %s items up to %s [%s]",
						$key,
						sprintf('%.3fs',$timerdiffA),
						$res,
						$cleanUpTo,
						scalar(localtime($cleanUpTo))
					);
				}
			} else {
				$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats cleanup statement for key %s: %s",
					$key,
					awitpt::db::dblayer::Error()
				);
			}
		}

		# Set last main cleanup to now
		$globals->{'LastCleanup'}->{'0'} = $now;

		my $timer4 = [gettimeofday];
		my $timediff4 = tv_interval($timer3,$timer4);
		$logger->log(LOG_INFO,"[STATISTICS] Total stats cleanup time: %s",
			sprintf('%.3fs',$timediff4)
		);
	}

	# Check if we need to pull config manager stats
	if ($now - $globals->{'LastConfigManagerStats'} > STATISTICS_PERIOD) {
		my $configManagerStats = _getConfigManagerStats();
		_processStatistics($kernel,$configManagerStats);
		$globals->{'LastConfigManagerStats'} = $now;
	}

	# Set delay on config updates
	$kernel->delay('_tick' => TICK_PERIOD);
}



# Update limit Statistics
# $item has some special use cases:
#	main:$iface:all	- Interface total stats
#	main:$iface:classes	- Interface classified traffic
#	main:$iface:besteffort	- Interface best effort traffic
sub _session_update
{
	my ($kernel, $statsData) = @_[KERNEL, ARG0];


	_processStatistics($kernel,$statsData);
}



# Handle subscriptions to updates
sub subscribe
{
	my ($sid,$conversions,$handler,$event) = @_;


	$logger->log(LOG_INFO,"[STATISTICS] Got subscription request for '%s': handler='%s', event='%s'",
		$sid,
		$handler,
		$event
	);

	# Grab next SSID
	my $ssid = shift(@{$globals->{'SSIDCounterFreeList'}});
	if (!defined($ssid)) {
		$ssid = $globals->{'SSIDCounter'}++;
	}

	# Setup data and conversions
	$globals->{'SSIDMap'}->{$ssid} = $globals->{'SIDSubscribers'}->{$sid}->{$ssid} = {
		'SID' => $sid,
		'SSID' => $ssid,
		'Conversions' => $conversions,
		'Handler' => $handler,
		'Event' => $event
	};

	# Return the SID we subscribed
	return $ssid;
}



# Handle unsubscribes
sub unsubscribe
{
	my $ssid = shift;


	# Grab item, and check if it doesnt exist
	my $item = $globals->{'SSIDMap'}->{$ssid};
	if (!defined($item)) {
		$logger->log(LOG_ERR,"[STATISTICS] Got unsubscription request for SSID '%s' that doesn't exist",
			$ssid
		);
		return
	}

	$logger->log(LOG_INFO,"[STATISTICS] Got unsubscription request for SSID '%s'",
		$ssid
	);

	# Remove subscriber
	delete($globals->{'SIDSubscribers'}->{$item->{'SID'}}->{$ssid});
	# If SID is now empty, remove it too
	if (! keys %{$globals->{'SIDSubscribers'}->{$item->{'SID'}}}) {
		delete($globals->{'SIDSubscribers'}->{$item->{'SID'}});
	}
	# Remove mapping
	delete($globals->{'SSIDMap'}->{$ssid});

	# Push onto list of free ID's
	push(@{$globals->{'SSIDCounterFreeList'}},$ssid);
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



# Return stats by SID
sub getStatsBySID
{
	my ($sid,$conversions,$startTimestamp,$endTimestamp) = @_;


	my $statistics = _getStatsBySID($sid,$startTimestamp,$endTimestamp);
	if (!defined($statistics)) {
		return;
	}

	# Loop and convert
	foreach my $timestamp (keys %{$statistics}) {
		my $stat = $statistics->{$timestamp};
		# Use new item
		$statistics->{$timestamp} = _fixStatDirection($stat,$conversions);
	}

	return $statistics;
}



# Return basic stats by SID
sub getStatsBasicBySID
{
	my ($sid,$conversions) = @_;


	my $statistics = _getStatsBasicBySID($sid);
	if (!defined($statistics)) {
		return;
	}

	# Loop and convert
	foreach my $timestamp (keys %{$statistics}) {
		my $stat = $statistics->{$timestamp};
		# Use new item
		$statistics->{$timestamp} = _fixCounterName($stat,$conversions);
	}

	return $statistics;
}



# Get the stats ID from Class ID
sub getSIDFromCID
{
	my ($iface,$cid) = @_;


	# Grab identifier based on class ID
	my $identifier = _getIdentifierFromCID($iface,$cid);
	if (!defined($identifier)) {
		return undef;
	}

	# Return the SID fo the identifier
	return _getSIDFromIdentifier($identifier);
}



# Set the stats ID from Class ID
sub setSIDFromCID
{
	my ($iface,$cid) = @_;


	# See if we can get a SID from the CID
	my $sid = getSIDFromCID($iface,$cid);
	if (!defined($sid)) {
		# If not, grab the identifier
		my $identifier = _getIdentifierFromCID($iface,$cid);
		if (!defined($identifier)) {
			return undef;
		}
		# And setup a new SID
		$sid = _setSIDFromIdentifier($identifier);
	}

	return $sid;
}



# Get the stats ID from a PID
sub getSIDFromPID
{
	my $pid = shift;


	# Grab identifier from a PID
	my $identifier = _getIdentifierFromPID($pid);
	if (!defined($identifier)) {
		return undef;
	}

	# Return the SID for the PID
	return _getSIDFromIdentifier($identifier);
}


# Set the stats ID from a PID
sub setSIDFromPID
{
	my $pid = shift;


	# Try grab the SID for the PID
	my $sid = getSIDFromPID($pid);
	if (!defined($sid)) {
		# If we can't, grab the identifier instead
		my $identifier = _getIdentifierFromPID($pid);
		if (!defined($identifier)) {
			return undef;
		}
		# And setup the SID
		$sid = _setSIDFromIdentifier($identifier);
	}

	return $sid;
}



# Get the stats ID from a counter
sub getSIDFromCounter
{
	my $counter = shift;


	# Grab identifier from a counter
	my $identifier = _getIdentifierFromCounter($counter);
	if (!defined($identifier)) {
		return undef;
	}

	# Return the SID for the counter
	return _getSIDFromIdentifier($identifier);
}



# Set the stats ID from a counter
sub setSIDFromCounter
{
	my $counter = shift;


	# Try grab the SID for the counter
	my $sid = getSIDFromCounter($counter);
	if (!defined($sid)) {
		# If we can't, grab the identifier instead
		my $identifier = _getIdentifierFromCounter($counter);
		if (!defined($identifier)) {
			return undef;
		}
		# And setup the SID
		$sid = _setSIDFromIdentifier($identifier);
	}

	return $sid;
}



# Return traffic direction
sub getTrafficDirection
{
	my ($pid,$interface) = @_;


	# Grab the interfaces for this limit
	my $txInterface = getPoolTxInterface($pid);
	my $rxInterface = getPoolRxInterface($pid);

	# Check what it matches...
	if ($interface eq $txInterface) {
		return STATISTICS_DIR_TX;
	} elsif ($interface eq $rxInterface) {
		return STATISTICS_DIR_RX;
	}

	return undef;
}



# Generate ConfigManager counters
sub getConfigManagerCounters
{
	my @poolList = getPools();
	my @classes = getAllTrafficClasses();


	# Grab user count
	my %counters;

	$counters{"configmanager.totalpools"} = @poolList;

	# Zero this counter
	$counters{"configmanager.totalpoolmembers"} = 0;

	# Zero the number of pools in each class to start off with
	foreach my $cid (@classes) {
		$counters{"configmanager.classpools.$cid"} = 0;
		$counters{"configmanager.classpoolmembers.$cid"} = 0;
	}

	# Pull in each pool and bump up the class counter
	foreach my $pid (@poolList) {
		my $pool = getPool($pid);
		my $cid = getPoolTrafficClassID($pid);
		my @poolMembers = getPoolMembers($pid);
		# Bump the class counters
		$counters{"configmanager.classpools.$cid"}++;
		$counters{"configmanager.classpoolmembers.$cid"} += @poolMembers;
		# Bump the pool member counter
		$counters{"configmanager.totalpoolmembers"} += @poolMembers;
		# Set pool member count
		$counters{"configmanager.poolmembers.$pool->{'InterfaceGroupID'}/$pool->{'Name'}"} = @poolMembers;
	}

	return \%counters;
}


#
# Internal Functions
#


# Function to process a bunch of statistics
sub _processStatistics
{
	my ($kernel,$statsData) = @_;


	my $queuedEvents;

	# Loop through stats data we got
	while ((my $sid, my $stat) = each(%{$statsData})) {

		$stat->{'IdentifierID'} = $sid;
		$stat->{'Key'} = 0;

		# Add to main queue
		push(@{$globals->{'StatsQueue'}},$stat);

		# Check if we have an event handler subscriber for this item
		if (defined(my $subscribers = $globals->{'SIDSubscribers'}->{$sid})) {

			# Build the stat that our conversions understands
			my $eventStat;
			# This is a basic counter
			if (defined($stat->{'Counter'})) {
				$eventStat = {
					'counter' => $stat->{'Counter'}
				};
			} else {
				$eventStat->{$stat->{'Direction'}} = {
					'rate' => $stat->{'Rate'},
					'pps' => $stat->{'PPS'},
					'cir' => $stat->{'CIR'},
					'limit' => $stat->{'Limit'}
				};
			}

			# If we do, loop with them
			foreach my $ssid (keys %{$subscribers}) {
				my $subscriber = $subscribers->{$ssid};
				my $handler = $subscriber->{'Handler'};
				my $event = $subscriber->{'Event'};
				my $conversions = $subscriber->{'Conversions'};

				# Get temp stat, this still refs the original one
				my $tempStat;
				# This is a basic counter
				if (defined($eventStat->{'counter'})) {
					$tempStat = _fixCounterName($eventStat,$conversions);
				} else {
					$tempStat = _fixStatDirection($eventStat,$conversions);
				}
				# Send a copy! so we don't send refs to data used elsewhere
				$queuedEvents->{$handler}->{$event}->{$ssid}->{$stat->{'Timestamp'}} = dclone($tempStat);
			}
		}
	}

	# Loop with events we need to dispatch
	foreach my $handler (keys %{$queuedEvents}) {
		my $events = $queuedEvents->{$handler};

		foreach my $event (keys %{$events}) {
			$kernel->post($handler => $event => $queuedEvents->{$handler}->{$event});
		}
	}
}



# Generate ConfigManager stats
sub _getConfigManagerStats
{
	my $counters = getConfigManagerCounters();


	my $now = time();
	my $statsData = { };

	# Loop through counters and create stats items
	foreach my $item (keys %{$counters}) {
		my $identifierID = setSIDFromCounter($item);
		my $stat = {
			'IdentifierID' => $identifierID,
			'Timestamp' => $now,
			'Counter' => $counters->{$item}
		};
		$statsData->{$identifierID} = $stat;
	}

	return $statsData;
}



# Function to get a SID identifier from a class ID
sub _getIdentifierFromCID
{
	my ($iface,$cid) = @_;


	return sprintf("Class:%s:%s",$iface,$cid);
}



# Function to get a SID identifier from a pool ID
sub _getIdentifierFromPID
{
	my $pid = shift;


	my $pool = getPool($pid);
	if (!defined($pool)) {
		return undef;
	}

	return sprintf("Pool:%s/%s",$pool->{'InterfaceGroupID'},$pool->{'Name'});
}



# Function to get a SID identifier from a counter
sub _getIdentifierFromCounter
{
	my $counter = shift;

	return sprintf("Counter:%s",$counter);
}



# Return a cached SID if its cached
sub _getCachedSIDFromIdentifier
{
	my $identifier = shift;


	return $globals->{'IdentifierMap'}->{$identifier};
}



# Grab or add the identifier to the DB
sub _getSIDFromIdentifier
{
	my $identifier = shift;


	# Check if we have it cached
	if (my $sid = _getCachedSIDFromIdentifier($identifier)) {
		return $sid;
	}

	# We need the DB to be alive to do this...
	if (!defined($globals->{'Database'})) {
		return undef;
	}

	# Try grab it from DB
	if (my $res = DBSelect(SQL_GET_IDENTIFIER,$identifier)) {
		# Grab first row and return
		if (my $row = $res->fetchrow_hashref()) {
			DBFreeRes($res);
			return $globals->{'IdentifierMap'}->{$identifier} = $row->{'id'};
		}
		DBFreeRes($res);
	} else {
		$logger->log(LOG_ERR,"[STATISTICS] Failed to get SID from identifier '%s': %s",$identifier,awitpt::db::dblayer::Error());
	}

	return undef;
}



# Set SID from identifier in DB
sub _setSIDFromIdentifier
{
	my $identifier = shift;


	# We need the DB to be alive to do this...
	if (!defined($globals->{'Database'})) {
		return undef;
	}

	# Try add it to the DB
	if (my $res = DBDo(SQL_ADD_IDENTIFIER,$identifier)) {
		return $globals->{'IdentifierMap'}->{$identifier} = DBLastInsertID("","");
	} else {
		$logger->log(LOG_ERR,"[STATISTICS] Failed to set SID from identifier '%s': %s",$identifier,awitpt::db::dblayer::Error());
	}

	return undef;
}



# Get aligned time on a Precision
sub _getAlignedTime
{
	my ($time,$precision) = @_;
	return $time - ($time % $precision);
}



# Internal function to get stats by SID
sub _getStatsBySID
{
	my ($sid,$startTimestamp,$endTimestamp) = @_;


	my $now = time();

	# Setup our timestamps if we need to
	if (!defined($startTimestamp)) {
		$startTimestamp = $now - 3600;
	}
	if (!defined($endTimestamp)) {
		$endTimestamp = $now;
	}

	# Work out the timestamp
	my $timespan = $endTimestamp - $startTimestamp;

	# Find the best key to use...
	my $statsKey = 0;
	foreach my $key (sort {$b <=> $a} keys %{STATS_CONFIG()}) {
		# Grab first key that will hve 50+ entries
		if ($timespan / STATS_CONFIG()->{$key}->{'precision'} > 50) {
			$statsKey = $key;
			last;
		}
	}

	my $statistics = { };

	# We need the DB below this point
	if (!defined($globals->{'Database'})) {
		return $statistics;
	}

	# Grab last 60 mins of data
	my $res = DBSelect(SQL_GET_STATS,$sid,$statsKey,$startTimestamp,$endTimestamp);
	if (!defined($res)) {
		$logger->log(LOG_ERR,"[STATISTICS] Failed to get stats for SID '%s': %s",$sid,awitpt::db::dblayer::Error());
		return $statistics;
	}

	while (my $item = $res->fetchrow_hashref()) {
		$statistics->{$item->{'timestamp'}}->{$item->{'direction'}} = {
			'rate' => $item->{'rate'},
			'pps' => $item->{'pps'},
			'cir' => $item->{'cir'},
			'limit' => $item->{'limit'},
		}
	}
	DBFreeRes($res);

	return $statistics;
}



# Internal function to get basic stats by SID
sub _getStatsBasicBySID
{
	my ($sid,$startTimestamp,$endTimestamp) = @_;


	my $now = time();

	# Setup our timestamps if we need to
	if (!defined($startTimestamp)) {
		$startTimestamp = $now - 3600;
	}
	if (!defined($endTimestamp)) {
		$endTimestamp = $now;
	}

	# Work out the timestamp
	my $timespan = $endTimestamp - $startTimestamp;

	# Find the best key to use...
	my $statsKey = 0;
	foreach my $key (sort {$b <=> $a} keys %{STATS_CONFIG()}) {
		# Grab first key that will hve 50+ entries
		if ($timespan / STATS_CONFIG()->{$key}->{'precision'} > 50) {
			$statsKey = $key;
			last;
		}
	}

	my $statistics = { };

	# We need the DB below this point
	if (!defined($globals->{'Database'})) {
		return $statistics;
	}

	# Prepare query
	my $res = DBSelect(SQL_GET_STATS_BASIC,$sid,$statsKey,$startTimestamp,$endTimestamp);

	while (my $item = $res->fetchrow_hashref()) {
		$statistics->{$item->{'timestamp'}} = {
			'counter' => $item->{'counter'},
		}
	}
	DBFreeRes($res);

	return $statistics;
}



# Function to transform stats before sending them
sub _fixStatDirection
{
	my ($stat,$conversions) = @_;


	my $res;

	# Loop with directions, maybe we have more than one with this stat
	while ((my $direction, my $oldStat) = each(%{$stat})) {
		# Depending which direction, grab the key to use below
		my $oldKey;
		if ($direction == STATISTICS_DIR_TX) {
			$oldKey = 'tx';
		} elsif ($direction == STATISTICS_DIR_RX) {
			$oldKey = 'rx';
		}

		# Loop and remove the direction, instead, adding it to the item
		foreach my $item (keys %{$oldStat}) {
			# If we have conversions defined...
			my $newKey;
			if (defined($conversions) && defined($conversions->{'Direction'})) {
				$newKey = sprintf("%s.%s",$conversions->{'Direction'},$item);
			} else {
				$newKey = sprintf("%s.%s",$oldKey,$item);
			}
			$res->{$newKey} = $oldStat->{$item};
		}
	}

	return $res;
}



# Function to transform stats before sending them
sub _fixCounterName
{
	my ($stat,$conversions) = @_;


	# Loop and set the identifier
	my $newStat;

	# If we have conversions defined...
	my $newKey = 'counter';
	if (defined($conversions) && defined($conversions->{'Name'})) {
		$newKey = sprintf('%s',$conversions->{'Name'});
	}

	$newStat->{$newKey} = $stat->{'counter'};

	return $newStat;
}



1;
# vim: ts=4
