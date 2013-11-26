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

use opentrafficshaper::plugins::configmanager qw(
		getLimitUsername

		getLimitTxInterface
		getLimitRxInterface
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

	getStatsByClass
	getStatsByCounter

	getSIDFromCID
	getSIDFromLID
);

use constant {
	VERSION => '0.1.1',
	# How often our config check ticks
	TICK_PERIOD => 5,

	STATISTICS_PERIOD => 60,

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
my $dbh;
# DB user mappings
my $statsDBIdentifierMap = { };
# Stats queue
my $statsQueue = [ ];
# Stats ubscribers
my $subscribers;
# Prepared statements we need...
my $statsPreparedStatements = { };
# Last cleanup time
my $lastCleanup = { };
# Last config manager stats pull
my $lastConfigManagerStats = 0;


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
		$dbh = DBI->connect(
				$config->{'db_dsn'}, $config->{'db_username'}, $config->{'db_password'},
				{
					'AutoCommit' => 1,
					'RaiseError' => 1,
					'FetchHashKeyName' => 'NAME_lc'
				}
		);
		if (!defined($dbh)) {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to connect to database: %s",$DBI::errstr);
		}

		# Prepare identifier add statement
		if ($dbh && (my $res = $dbh->prepare('INSERT INTO identifiers (`Identifier`) VALUES (?)'))) {
			$statsPreparedStatements->{'identifier_add'} = $res;
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to prepare statement 'identifier_add': %s",$DBI::errstr);
			$dbh->disconnect();
			$dbh = undef;
		}
		# Prepare identifier get statement
		if ($dbh && (my $res = $dbh->prepare('SELECT ID FROM identifiers WHERE `Identifier` = ?'))) {
			$statsPreparedStatements->{'identifier_get'} = $res;
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to prepare statement 'identifier_get': %s",$DBI::errstr);
			$dbh->disconnect();
			$dbh = undef;
		}

		# Prepare stats consolidation statements
		if ($dbh && (my $res = $dbh->prepare('
			SELECT
				`IdentifierID`, `Timestamp` - (`Timestamp` % ?) AS TimestampM,
				`Direction`,
				MAX(`CIR`) AS `CIR`, MAX(`Limit`) AS `Limit`, MAX(`Rate`) AS `Rate`, MAX(`PPS`) AS `PPS`, MAX(`Queue_Len`) AS `Queue_Len`,
				AVG(`Total_Bytes`) AS `Total_Bytes`, AVG(`Total_Packets`) AS `Total_Packets`, AVG(`Total_Overlimits`) AS `Total_Overlimits`, AVG(`Total_Dropped`) AS `Total_Dropped`
			FROM
				stats
			WHERE
				`Key` = ?
				AND `Timestamp` < ?
			GROUP BY
				`IdentifierID`, `TimestampM`, `Direction`
		'))) {
			$statsPreparedStatements->{'stats_consolidate'} = $res;
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to prepare statement 'stats_consolidate': %s",$DBI::errstr);
			$dbh->disconnect();
			$dbh = undef;
		}
		if ($dbh && (my $res = $dbh->prepare('
			SELECT
				`IdentifierID`, `Timestamp` - (`Timestamp` % ?) AS TimestampM,
				MAX(`Counter`) AS `Counter`
			FROM
				stats_basic
			WHERE
				`Key` = ?
				AND `Timestamp` < ?
			GROUP BY
				`IdentifierID`, `TimestampM`
		'))) {
			$statsPreparedStatements->{'stats_basic_consolidate'} = $res;
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to prepare statement 'stats_basic_consolidate': %s",$DBI::errstr);
			$dbh->disconnect();
			$dbh = undef;
		}

		# Prepare stats cleanup statements
		if ($dbh && (my $res = $dbh->prepare('DELETE FROM stats WHERE `Key` = ? AND `Timestamp` < ?'))) {
			$statsPreparedStatements->{'stats_cleanup'} = $res;
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to prepare statement 'stats_cleanup': %s",$DBI::errstr);
			$dbh->disconnect();
			$dbh = undef;
		}
		if ($dbh && (my $res = $dbh->prepare('DELETE FROM stats_basic WHERE `Key` = ? AND `Timestamp` < ?'))) {
			$statsPreparedStatements->{'stats_basic_cleanup'} = $res;
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to prepare statement 'stats_basic_cleanup': %s",$DBI::errstr);
			$dbh->disconnect();
			$dbh = undef;
		}

		# Set last cleanup to now
		my $now = time();
		foreach my $key (keys %{$statsConfig}) {
			$lastCleanup->{$key} = $now;
		}
		$lastConfigManagerStats = $now;
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
	$dbh = undef;
	$statsDBIdentifierMap = { };
	$statsQueue = [ ];
	$subscribers = undef;
	$statsPreparedStatements = { };
	$lastCleanup = { };
	$lastConfigManagerStats = 0;

	$logger->log(LOG_DEBUG,"[STATISTICS] Shutdown");

	$logger = undef;
}


# Time ticker for processing changes
sub session_tick
{
	my ($kernel,$heap) = @_[KERNEL,HEAP];


	# If we don't have a DB handle, just skip...
	if (!$dbh) {
		return;
	}

	my $now = time();
	my $timer1 = [gettimeofday];

	# Pull in statements
	my $sthStatsConsolidate = $statsPreparedStatements->{'stats_consolidate'};
	my $sthStatsCleanup = $statsPreparedStatements->{'stats_cleanup'};
	my $sthStatsBasicConsolidate = $statsPreparedStatements->{'stats_basic_consolidate'};
	my $sthStatsBasicCleanup = $statsPreparedStatements->{'stats_basic_cleanup'};

	# Even out flushing over 10s to absorb spikes
	my $maxFlush = int(@{$statsQueue} / 10) + 100;
	my $numFlush = 0;

	# Loop and build the data to create our multi-insert
	my (@insertHolders,@insertBasicHolders);
	my (@insertData,@insertBasicData);
	while (defined(my $stat = shift(@{$statsQueue})) && $numFlush < $maxFlush) {
		# This is a basic counter
		if (defined($stat->{'counter'})) {
			push(@insertBasicHolders,"(?,?,?,?)");
			push(@insertBasicData,
				$stat->{'identifierid'}, $stat->{'key'}, $stat->{'timestamp'},
				$stat->{'counter'}
			);
		# Full stats counter
		} else {
			push(@insertHolders,"(?,?,?,?,?,?,?,?,?,?,?,?,?)");
			push(@insertData,
				$stat->{'identifierid'}, $stat->{'key'}, $stat->{'timestamp'},
				$stat->{'direction'},
				$stat->{'cir'}, $stat->{'limit'}, $stat->{'rate'}, $stat->{'pps'}, $stat->{'queue_len'},
				$stat->{'total_bytes'}, $stat->{'total_packets'}, $stat->{'total_overlimits'}, $stat->{'total_dropped'}
			);
		}

		$numFlush++;
	}

	# If we got things to insert, do it
	if (@insertBasicHolders > 0) {
		my $res = $dbh->do('
			INSERT DELAYED INTO stats_basic
				(
					`IdentifierID`, `Key`, `Timestamp`,
					`Counter`
				)
			VALUES
				'.join(',',@insertBasicHolders),undef,@insertBasicData
		);
		# Check for error
		if (!defined($res)) {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute delayed stats_basic insert: %s",$DBI::errstr);
		}
	}
	# And normal stats...
	if (@insertHolders > 0) {
		my $res = $dbh->do('
			INSERT DELAYED INTO stats
				(
					`IdentifierID`, `Key`, `Timestamp`,
					`Direction`,
					`CIR`, `Limit`, `Rate`, `PPS`, `Queue_Len`,
					`Total_Bytes`, `Total_Packets`, `Total_Overlimits`, `Total_Dropped`
				)
			VALUES
				'.join(',',@insertHolders),undef,@insertData
		);
		# Check for error
		if (!defined($res)) {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute delayed stats insert: %s",$DBI::errstr);
		}
	}

	my $timer2 = [gettimeofday];
	# We only need stats if we did something, right?
	if ($numFlush) {
		my $timediff2 = tv_interval($timer1,$timer2);
		$logger->log(LOG_INFO,"[STATISTICS] Total stats flush time %s/%s records: %s",$numFlush,$maxFlush,sprintf('%.3fs',$timediff2));
	}

	my $res;

	# Loop with our stats consolidation configuration
	foreach my $key (sort keys %{$statsConfig}) {
		my $timerA = [gettimeofday];

		my $precision = $statsConfig->{$key}->{'precision'};
		my $thisPeriod = _getAlignedTime($now,$precision);
		my $lastPeriod = $thisPeriod - $precision;
		my $prevKey = $key - 1;
		# If we havn't exited the last period, then skip
		if ($lastCleanup->{$key} > $lastPeriod) {
			next;
		}

		# Stats
		my $numStatsBasicConsolidated = 0;
		my $numStatsConsolidated = 0;

		my $consolidateUpTo = $lastPeriod - $precision;

		# Execute and pull in consolidated stats
		$res = $sthStatsBasicConsolidate->execute($precision,$prevKey,$consolidateUpTo);
		if ($res) {
			# Loop with items returned
			while (my $item = $sthStatsBasicConsolidate->fetchrow_hashref()) {
				$item->{'key'} = $key;
				$item->{'timestamp'} = $item->{'timestampm'};

				# Queue for insert
				push(@{$statsQueue},$item);

				$numStatsBasicConsolidated++;
			}
		# If there was an error, make sure we report it
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats_basic consolidation statement: %s",$sthStatsBasicConsolidate->errstr());
		}
		# And the normal stats...
		$res = $sthStatsConsolidate->execute($precision,$prevKey,$consolidateUpTo);
		if ($res) {
			# Loop with items returned
			while (my $item = $sthStatsConsolidate->fetchrow_hashref()) {
				$item->{'key'} = $key;
				$item->{'timestamp'} = $item->{'timestampm'};

				# Queue for insert
				push(@{$statsQueue},$item);

				$numStatsConsolidated++;
			}
		# If there was an error, make sure we report it
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats consolidation statement: %s",$sthStatsConsolidate->errstr());
		}

		# Set last cleanup to now
		$lastCleanup->{$key} = $now;

		my $timerB = [gettimeofday];
		my $timediffB = tv_interval($timerA,$timerB);

		$logger->log(LOG_INFO,"[STATISTICS] Stats consolidation time for key %s: %s (%s basic, %s normal), up to %s [%s]",$key,
				sprintf('%.3fs',$timediffB),$numStatsBasicConsolidated,$numStatsConsolidated,$consolidateUpTo,scalar(localtime($consolidateUpTo)));
	}

	# Setup another timer
	my $timer3 = [gettimeofday];

	# We only need to run as often as the first precision
	# - If cleanup has not yet run?
	# - or if the 0 cleanup plus precision of the first key is in the past (data is now stale?)
	if (!defined($lastCleanup->{'0'}) || $lastCleanup->{'0'} + $statsConfig->{1}->{'precision'} < $now) {
		# We're going to clean up for the first stats precision * 3, which should be enough
		my $cleanUpTo = $now - ($statsConfig->{1}->{'precision'} * 3);

		# Streamed stats is removed 3 time periods past the first precision
		if ($res = $sthStatsBasicCleanup->execute(0, $cleanUpTo)) {
			# We get 0E0 for 0 when none were removed
			if ($res ne "0E0") {
				$logger->log(LOG_INFO,"[STATISTICS] Cleanup streamed stats_basic %s, up to %s [%s]",$res,$cleanUpTo,
						scalar(localtime($cleanUpTo)));
			}
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats_basic cleanup statement: %s",
					$sthStatsBasicCleanup->errstr());
		}
		# And the normal stats...
		if ($res = $sthStatsCleanup->execute(0, $cleanUpTo)) {
			# We get 0E0 for 0 when none were removed
			if ($res ne "0E0") {
				$logger->log(LOG_INFO,"[STATISTICS] Cleanup streamed stats %s, up to %s [%s]",$res,$cleanUpTo,
						scalar(localtime($cleanUpTo)));
			}
		} else {
			$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats cleanup statement: %s",$sthStatsCleanup->errstr());
		}

		# Loop and remove retained stats
		foreach my $key (keys %{$statsConfig}) {
			# Work out timestamp to clean up to by multiplying the retention period by days
			$cleanUpTo = $now - ($statsConfig->{$key}->{'retention'} * 86400);

			# Retention period is in # days
			if ($res = $sthStatsBasicCleanup->execute($key, $cleanUpTo)) {
				# We get 0E0 for 0 when none were removed
				if ($res ne "0E0") {
					$logger->log(LOG_INFO,"[STATISTICS] Cleanup key %s stats_basic %s, up to %s [%s]",$key,$res,$cleanUpTo,
							scalar(localtime($cleanUpTo)));
				}
			} else {
				$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats_basic cleanup statement for key %s: %s",$key,
						$sthStatsBasicCleanup->errstr());
			}
			# And normal stats...
			if ($res = $sthStatsCleanup->execute($key, $cleanUpTo)) {
				# We get 0E0 for 0 when none were removed
				if ($res ne "0E0") {
					$logger->log(LOG_INFO,"[STATISTICS] Cleanup key %s stats %s, up to %s [%s]",$key,$res,$cleanUpTo,
							scalar(localtime($cleanUpTo)));
				}
			} else {
				$logger->log(LOG_ERR,"[STATISTICS] Failed to execute stats cleanup statement for key %s: %s",$key,$sthStatsCleanup->errstr());
			}
		}

		# Set last main cleanup to now
		$lastCleanup->{'0'} = $now;

		my $timer4 = [gettimeofday];
		my $timediff4 = tv_interval($timer3,$timer4);
		$logger->log(LOG_INFO,"[STATISTICS] Stats cleanup time: %s",sprintf('%.3fs',$timediff4));
	}

	# Check if we need to pull config manager stats
	if ($now - $lastConfigManagerStats > STATISTICS_PERIOD) {
		my $configManagerStats = _getConfigManagerStats();
		_processStatistics($kernel,$configManagerStats);
		$lastConfigManagerStats = $now;
	}

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


	# TODO? This requires DB access
	if (!$dbh) {
		return;
	}

	_processStatistics($kernel,$statsData);
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


# Return stats based on a LID
sub getStatsByLID
{
	my $lid = shift;


	# Max entries
	my $entriesLeft = 100;

	# Grab stats ID from LID
	my $sid = getSIDFromLID($lid);
	if (!defined($sid)) {
		return { };
	}

	return _getStatsBySID($sid);
}


# Return stats based on an interface
sub getStatsByClass
{
	my ($iface,$cid) = @_;


	# Grab stats ID from LID
	my $sid = getSIDFromCID($iface,$cid);
	if (!defined($sid)) {
		return { };
	}

	return _getStatsBySID($sid);
}


# Get the stats ID from Class ID
sub getSIDFromCID
{
	my ($iface,$cid) = @_;

	my $identifier = "Class:$iface:$cid";
	return _getSIDFromIdentifier($identifier);
}


# Get the stats ID from a LID
sub getSIDFromLID
{
	my ($lid) = @_;

	if (defined(my $username = getLimitUsername($lid))) {
		my $identifier = "Username:$username";
		return _getSIDFromIdentifier($identifier);
	}

	return undef;
}


# Return traffic direction
sub getTrafficDirection
{
	my ($lid,$interface) = @_;


	# Grab the interfaces for this limit
	my $txInterface = getLimitTxInterface($lid);
	my $rxInterface = getLimitRxInterface($lid);

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
	my @limits = getLimits();
	my $classes = getTrafficClasses();

	# Grab user count
	my %counters;

	$counters{"ConfigManager:TotalUsers"} = @limits;

	# Start off with 0's
	foreach my $cid (keys %{$classes}) {
		$counters{"ConfigManager:ClassUsers:$cid"} = 0;
	}
	# Generate ClassID counts
	foreach my $lid (@limits) {
		my $limit = getLimit($lid);
		my $cid = $limit->{'ClassID'};
		# Bump the class counter
		$counters{"ConfigManager:ClassUsers:$cid"}++;
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


	# Loop through stats data we got
	while ((my $sid, my $stat) = each(%{$statsData})) {

		$stat->{'identifierid'} = $sid;
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
}


# Generate ConfigManager stats
sub _getConfigManagerStats
{
	my $counters = getConfigManagerCounters();


	my $now = time();
	my $statsData = { };

	# Loop through counters and create stats items
	foreach my $item (%{$counters}) {
		my $identifierID = getSIDFromCounter($item);
		my $stat = {
			'identifierid' => $identifierID,
			'timestamp' => $now,
			'counter' => $counters->{$item}
		};
		$statsData->{$identifierID} = $stat;
	}

	return $statsData;
}


# Return a cached SID if its cached
sub _getCachedSIDFromIdentifier
{
	my $identifier = shift;


	# If we don't have a user mapped
	if (defined(my $sid = $statsDBIdentifierMap->{$identifier})) {
		return $sid;
	}

	return undef;
}


# Grab or add the identifier to the DB
sub _getSIDFromIdentifier
{
	my $identifier = shift;


	# Check if we have it cached
	if (my $sid = _getCachedSIDFromIdentifier($identifier)) {
		return $sid;
	}

	# Try grab it from DB
	my $identifierGetSTH = $statsPreparedStatements->{'identifier_get'};
	if (my $res = $identifierGetSTH->execute($identifier)) {
		# Grab first row and return
		if (my $row = $identifierGetSTH->fetchrow_hashref()) {
			return $statsDBIdentifierMap->{$identifier} = $row->{'id'};
		}
	} else {
# FIXME
warn "FAILED TO EXECUTE GETUSER: ".$identifierGetSTH->errstr;
	}

	# Try add it to the DB
	my $identifierAddSTH = $statsPreparedStatements->{'identifier_add'};
	if (my $res = $identifierAddSTH->execute($identifier)) {
		return $statsDBIdentifierMap->{$identifier} = $dbh->last_insert_id("","","","");
	} else {
warn "DB ADD IDENTIFIER ERROR: ".$identifierAddSTH->errstr;
	}
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
	my $sid = shift;


	my $now = time();

	# Prepare query
	my $sth = $dbh->prepare('
		SELECT
			`Timestamp`, `Direction`, `Rate`, `PPS`, `CIR`, `Limit`
		FROM
			stats
		WHERE
			`IdentifierID` = ?
			AND `Key` = ?
			AND `Timestamp` > ?
			AND `Timestamp` < ?
		ORDER BY
			`Timestamp` DESC
		LIMIT 100
	');
	# Grab last 60 mins of data
	$sth->execute($sid,0,$now - 3600, $now);

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

	return $statistics;
}


# Internal function to get basic stats by SID
sub _getStatsBasicBySID
{
	my $sid = shift;


	my $now = time();

	# Prepare query
	my $sth = $dbh->prepare('
		SELECT
			`Timestamp`, `Counter`
		FROM
			stats_basic
		WHERE
			`IdentifierID` = ?
			AND `Key` = ?
			AND `Timestamp` > ?
			AND `Timestamp` < ?
		ORDER BY
			`Timestamp` DESC
		LIMIT 100
	');
	# Grab last 60 mins of data
	$sth->execute($sid,0,$now - 3600, $now);

	my $statistics;
	while (my $item = $sth->fetchrow_hashref()) {
		$statistics->{$item->{'timestamp'}} = {
			'counter' => $item->{'counter'},
		}
	}

	return $statistics;
}




1;
# vim: ts=4
