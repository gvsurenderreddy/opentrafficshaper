# Utility functions
# Copyright (C) 2013, AllWorldIT
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


package opentrafficshaper::utils;

use strict;
use warnings;


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
	prettyUndef
	toHex
	isVariable
	isUsername
	isIP
	isNumber

	booleanize
);
@EXPORT_OK = qw(
	parseFormContent
	parseURIQuery
);


# Print a undef in a pretty fashion
sub prettyUndef
{
	my $var = shift;
	if (!defined($var)) {
		return "-undef-";
	} else {
		return $var;
	}
}


# Return hex representation of a decimal
sub toHex
{
	my $decimal = shift;
	return sprintf('%x',$decimal);
}


# Parse form post data from HTTP content
sub parseFormContent
{
	my $data = shift;
	my %res;

	# Split information into name/value pairs
	my @pairs = split(/&/, $data);
	foreach my $pair (@pairs) {
		my ($name, $value) = split(/=/, $pair);
		$value =~ tr/+/ /;
		$value =~ s/%(..)/pack("C", hex($1))/eg;
		$res{$name} = $value;
	}

	return \%res;
}

# Parse query data
sub parseURIQuery
{
	my $request = shift;
	my %res;

	use URI::QueryParam;

	# Pull in URL params
	foreach my $key ($request->uri->query_param) {
		$res{$key} = $request->uri->query_param($key);
	}

	return \%res;
}



# Check if variable is normal
sub isVariable
{
	my $var = shift;


	# A variable cannot be undef?
	if (!defined($var)) {
		return undef;
	}

	return (ref($var) eq "");
}


# Check if variable is a username
sub isUsername
{
	my $var = shift;


	# Make sure we're not a ref
	if (!isVariable($var)) {
		return undef;
	}

	# Lowercase it
	$var = lc($var);

	# Normal username
	if ($var =~ /^[a-z0-9_\-\.]+$/) {
		return $var;
	}

	# Username with domain
	if ($var =~ /^[a-z0-9_\-\.]+\@[a-z0-9\-\.]+$/) {
		return $var;
	}

	return undef;
}


# Check if variable is an IP
sub isIP
{
	my $var = shift;


	# Make sure we're not a ref
	if (!isVariable($var)) {
		return undef;
	}

	# Lowercase it
	$var = lc($var);

	# Normal IP
	if ($var =~ /^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/) {
		return $var;
	}

	return undef;
}


# Check if variable is a number
sub isNumber
{
	my $var = shift;


	# Make sure we're not a ref
	if (!isVariable($var)) {
		return undef;
	}

	# Strip leading 0's
	if ($var =~ /^0*([0-9]+)$/) {
		my $val = int($1);

		# Check we not 0 or negative
		if ($val > 0) {
			return $val;
		}

		# Check if we allow 0's
		if ($val == 0) {
			return $val;
		}
	}

	return undef;
}


# Booleanize the variable depending on its contents
sub booleanize
{
	my $var = shift;


	# Check if we're defined
	if (!isVariable($var)) {
		return undef;
	}

	# If we're a number
	if (my $val = isNumber($var)) {
		if ($val == 0) {
			return 0;
		} else {
			return 1;
		}
	}

	# Nuke whitespaces
	$var =~ s/\s//g;

	# Allow true, on, set, enabled, 1
	if ($var =~ /^(?:true|on|set|enabled|1|yes)$/i) {
		return 1;
	}

	# Invalid or unknown
	return 0;
}


1;
# vim: ts=4
