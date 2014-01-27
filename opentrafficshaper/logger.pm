# Logging functionality
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


package opentrafficshaper::logger;

use strict;
use warnings;


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
	LOG_ERR
	LOG_WARN
	LOG_NOTICE
	LOG_INFO
	LOG_DEBUG
);
@EXPORT_OK = qw(
);


use constant {
	LOG_ERR		=> 0,
	LOG_WARN	=> 1,
	LOG_NOTICE	=> 2,
	LOG_INFO	=> 3,
	LOG_DEBUG	=> 4
};


use IO::Handle;
use POSIX qw( strftime );



# Instantiate
sub new {
	my ($class) = @_;
	my $self = {
		'handle' => \*STDERR,
		'level' => 2,
	};
	bless $self, $class;
	return $self;
}



# Logging function
sub log
{
	my ($self,$level,$msg,@args) = @_;

	# Check log level and set text
	my $logtxt = "UNKNOWN";
	if ($level == LOG_DEBUG) {
		$logtxt = "DEBUG";
	} elsif ($level == LOG_INFO) {
		$logtxt = "INFO";
	} elsif ($level == LOG_NOTICE) {
		$logtxt = "NOTICE";
	} elsif ($level == LOG_WARN) {
		$logtxt = "WARNING";
	} elsif ($level == LOG_ERR) {
		$logtxt = "ERROR";
	}

	# Parse message nicely
	if ($msg =~ /^(\[[^\]]+\]) (.*)/s) {
		$msg = sprintf("%s %s: %s",$1,$logtxt,$2);
	} else {
		$msg = sprintf("[UNKNOWN] %s: %s",$logtxt,$msg);
	}

	# If we have args, this is more than likely a format string & args
	if (@args > 0) {
		$msg = sprintf($msg,@args);
	}
	# Check if we need to log this
	if ($level <= $self->{'level'}) {
		local *FH = $self->{'handle'};
		printf(FH "[%s - %s] %s\n",strftime('%F %T',localtime),$$,$msg);
	}
}



# Set log file & open it
sub open
{
	my ($self, $file) = @_;


	# Try open logfile
	my $fh;
	open($fh,">>",$file)
		or die("Failed to open log file '$file': $!");
	# Make sure its flushed
	$fh->autoflush();
	# And set it
	$self->{'handle'} = $fh;
}



# Set log level
sub setLevel
{
	my ($self, $level) = @_;


	# And set it
	$self->{'level'} = $level;
}



1;
# vim: ts=4
