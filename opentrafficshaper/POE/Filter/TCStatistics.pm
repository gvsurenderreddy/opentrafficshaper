# OpenTrafficShaper POE::Filter::TCStatistics TC stats filter
# OpenTrafficShaper webserver module: limits page
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


##
# Code originally based on POE::Filter::HTTPD
##
# Filter::HTTPD Copyright 1998 Artur Bergman <artur@vogon.se>.
# Thanks go to Gisle Aas for his excellent HTTP::Daemon.	Some of the
# get code was copied out if, unfortunately HTTP::Daemon is not easily
# subclassed for POE because of the blocking nature.

# 2001-07-27 RCC: This filter will not support the newer get_one()
# interface.	It gets single things by default, and it does not
# support filter switching.	If someone absolutely needs to switch to
# and from HTTPD filters, they should submit their request as a patch.
##

package opentrafficshaper::POE::Filter::TCStatistics;

use warnings;
use strict;

use POE::Filter;

use vars qw($VERSION @ISA);
# NOTE - Should be #.### (three decimal places)
$VERSION = '1.300';
@ISA = qw(POE::Filter);



# Class instantiation
sub new
{
	my $class = shift;

	 # These are our internal properties
	my $self = { };
	# Build our class
	bless($self, $class);

	# And initialize
	$self->_reset();

	return $self;
}



# From the docs:
# get_one_start() accepts an array reference containing unprocessed stream chunks. The chunks are added to the filter's Internal
# buffer for parsing by get_one().
sub get_one_start
{
	my ($self, $stream) = @_;


	# Join all the blocks of data and add to our buffer
	$self->{'buffer'} .= join('',@{$stream});

	return $self;
}



# This is called to see if we can grab records/items
sub get_one
{
	my $self = shift;
	my @results = ();


	# Pull of blocks of class info's
	while ($self->{'buffer'} =~ s/^(class.+)\n\s+(.+\n\s+.+)\n.+\n.+\n\n//m) {
		my $curstat;

		my ($classStr,$statsStr) = ($1,$2);
		# Strip off the line into an array
		my @classArray = split(/\s+/,$classStr);
		my @statsArray = split(/[\s,\(\)]+/,$statsStr);
		# Pull in all the items
		# class htb 1:1 root rate 100000Kbit ceil 100000Kbit burst 51800b cburst 51800b
		if (@classArray == 12) {
			$curstat->{'CIR'} = _getKNumber($classArray[5]);
			$curstat->{'Limit'} = _getKNumber($classArray[7]);
		# class htb 1:d parent 1:1 rate 10000Kbit ceil 100000Kbit burst 6620b cburst 51800b
		} elsif (@classArray == 13) {
			$curstat->{'CIR'} = _getKNumber($classArray[6]);
			$curstat->{'Limit'} = _getKNumber($classArray[8]);
		# class htb 1:3 parent 1:1 prio 7 rate 10000Kbit ceil 100000Kbit burst 6620b cburst 51800b
		} elsif (@classArray == 15) {
			$curstat->{'Priority'} = int($classArray[6]);
			$curstat->{'CIR'} = _getKNumber($classArray[8]);
			$curstat->{'Limit'} = _getKNumber($classArray[10]);
		# class htb 1:3 parent 1:1 leaf 3: prio 7 rate 10000Kbit ceil 100000Kbit burst 6620b cburst 51800b
		} elsif (@classArray == 17) {
			$curstat->{'Priority'} = int($classArray[8]);
			$curstat->{'CIR'} = _getKNumber($classArray[10]);
			$curstat->{'Limit'} = _getKNumber($classArray[12]);
		} else {
			next;
		}
		($curstat->{'TCClassParent'},$curstat->{'TCClassChild'}) = split(/:/,$classArray[2]);

		#   Sent 0 bytes 0 pkt (dropped 0, overlimits 0 requeues 0)
		#   rate 0bit 0pps backlog 0b 0p requeues 0
		if (@statsArray == 19) {
			$curstat->{'TotalBytes'} = int($statsArray[1]);
			$curstat->{'TotalPackets'} = int($statsArray[3]);
			$curstat->{'TotalDropped'} = int($statsArray[6]);
			$curstat->{'TotalOverlimits'} = int($statsArray[8]);

			$curstat->{'Rate'} = _getKNumber($statsArray[12]);
			$curstat->{'PPS'} = int(substr($statsArray[13],0,-3));
			$curstat->{'QueueSize'} = int(substr($statsArray[15],0,-1));
			$curstat->{'QueueLen'} = int(substr($statsArray[16],0,-1));
		} else {
			next;
		}

		push(@results,$curstat);
	}


	return [ @results ];
}



# Function to push data to the socket
sub put
{
	my ($self, $data) = @_;

	my @results = [ $data ];

	return \@results;
}



#
# Internal functions
#

# Prepare for next request
sub _reset
{
	my $self = shift;


	# Reset our filter state
	$self->{'buffer'} = '';
}



# Get rate...
sub _getKNumber
{
	my $str = shift;

	my ($num,$multiplier) = ($str =~ /([0-9]+)([KMG])?/);

	# We only work in Kbit
	if (!defined($multiplier)) {
		$num /= 1000;
	} elsif ($multiplier eq "K") {
		# noop
	} elsif ($multiplier eq "M") {
		$num *= 1000;
	} elsif ($multiplier eq "G") {
		$num *= 1000000;
	}

	return int($num);
}



1;
