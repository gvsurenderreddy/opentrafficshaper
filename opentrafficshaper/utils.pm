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
);
@EXPORT_OK = qw(
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

1;
# vim: ts=4
