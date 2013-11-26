
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
	`Queue_Len`				MEDIUMINT UNSIGNED NOT NULL,
	`Total_Bytes`			BIGINT UNSIGNED NOT NULL,
	`Total_Packets`			BIGINT UNSIGNED NOT NULL,
	`Total_Overlimits`		BIGINT UNSIGNED NOT NULL,
	`Total_Dropped`			BIGINT UNSIGNED NOT NULL
) Engine=MyISAM;

/* For queries */
CREATE INDEX stats_idx1 ON stats (`IdentifierID`);
CREATE INDEX stats_idx2 ON stats (`IdentifierID`,`Key`);
CREATE INDEX stats_idx3 ON stats (`IdentifierID`,`Key`,`Timestamp`);
/* For cleanups */
CREATE INDEX stats_idx4 ON stats (`Key`,`Timestamp`);

