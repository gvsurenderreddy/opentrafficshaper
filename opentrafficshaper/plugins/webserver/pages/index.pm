# OpenTrafficShaper webserver module: index page
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

package opentrafficshaper::plugins::webserver::pages::index;

use strict;
use warnings;


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
);

use HTTP::Status qw( :constants );

use opentrafficshaper::plugins;


# Dashboard
sub _catchall
{
	my ($kernel,$globals,$client_session_id,$request) = @_;


	my ($res,$content,$opts);

	if (!isPluginLoaded('statistics')) {
		$content .= "No Statistics Plugin";
		$res = HTTP_OK;
		goto END;
	}

	return (HTTP_TEMPORARY_REDIRECT,"statistics/dashboard");
}



1;
# vim: ts=4
