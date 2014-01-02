# OpenTrafficShaper constants package
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

package opentrafficshaper::constants;

use strict;
use warnings;


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
	CFGM_NEW
	CFGM_OFFLINE
	CFGM_ONLINE
	CFGM_CHANGED

	SHAPER_NOTLIVE
	SHAPER_PENDING
	SHAPER_LIVE
);


# CFGM_NEW - New
# CFGM_OFFLINE - Offline
# CFGM_ONLINE - Online
# CFGM_CHANGED - Changed
use constant {
	CFGM_OFFLINE => 0,
	CFGM_CHANGED => 1,
	CFGM_ONLINE => 2,
	CFGM_NEW => 4,
};


# SHAPER_NOTLIVE - Nothing is going on yet, something should happen
# SHAPER_PENDING - Waiting on shaper to do a change
# SHAPER_LIVE - Shaper is up to date with our config
use constant {
	SHAPER_NOTLIVE => 0,
	SHAPER_PENDING => 1,
	SHAPER_LIVE => 2,
};



1;
# vim: ts=4
