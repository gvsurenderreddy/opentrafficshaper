
/* Identifiers used for our statistics */
DROP TABLE IF EXISTS identifiers;

CREATE TABLE identifiers (
	`ID`					SERIAL,
	`Identifier`			VARCHAR(255) NOT NULL
) Engine=MyISAM;

/* For queries */
CREATE INDEX identifiers_idx1 ON identifiers (`Identifier`);



/* Limit statistics */
DROP TABLE IF EXISTS stats;

CREATE TABLE stats (
	`ID`					SERIAL,

	`IdentifierID`			BIGINT UNSIGNED NOT NULL,
	`Key`					TINYINT UNSIGNED NOT NULL,  /* 1 = < 5min, 2 = 5min, 3 = 15min, 4 = 1hr, 5 = 6hr, 6 = 1 day */

	`Timestamp`				INTEGER UNSIGNED NOT NULL,
	`Direction`				TINYINT UNSIGNED NOT NULL,

	`CIR`					MEDIUMINT UNSIGNED NOT NULL,
	`Limit`					MEDIUMINT UNSIGNED NOT NULL,
	`Rate`					MEDIUMINT UNSIGNED NOT NULL,
	`PPS`					MEDIUMINT UNSIGNED NOT NULL,
	`QueueLen`				MEDIUMINT UNSIGNED NOT NULL,
	`TotalBytes`			BIGINT UNSIGNED NOT NULL,
	`TotalPackets`			BIGINT UNSIGNED NOT NULL,
	`TotalOverlimits`		BIGINT UNSIGNED NOT NULL,
	`TotalDropped`			BIGINT UNSIGNED NOT NULL
) Engine=MyISAM;

/* For queries */
CREATE INDEX stats_idx1 ON stats (`IdentifierID`);
CREATE INDEX stats_idx2 ON stats (`IdentifierID`,`Key`);
CREATE INDEX stats_idx3 ON stats (`IdentifierID`,`Key`,`Timestamp`);
/* For cleanups */
CREATE INDEX stats_idx4 ON stats (`Key`,`Timestamp`);



/* Basic statistics */
DROP TABLE IF EXISTS stats_basic;

CREATE TABLE stats_basic (
	`ID`					SERIAL,

	`IdentifierID`			BIGINT UNSIGNED NOT NULL,
	`Key`					TINYINT UNSIGNED NOT NULL,  /* 1 = < 5min, 2 = 5min, 3 = 15min, 4 = 1hr, 5 = 6hr, 6 = 1 day */

	`Timestamp`				INTEGER UNSIGNED NOT NULL,

	`Counter`				BIGINT UNSIGNED NOT NULL
) Engine=MyISAM;

/* For queries */
CREATE INDEX stats_basic_idx1 ON stats (`IdentifierID`);
CREATE INDEX stats_basic_idx2 ON stats (`IdentifierID`,`Key`);
CREATE INDEX stats_basic_idx3 ON stats (`IdentifierID`,`Key`,`Timestamp`);
/* For cleanups */
CREATE INDEX stats_basic_idx4 ON stats (`Key`,`Timestamp`);

