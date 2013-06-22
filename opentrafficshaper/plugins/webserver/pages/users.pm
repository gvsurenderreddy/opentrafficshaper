# OpenTrafficShaper webserver module: users page
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

package opentrafficshaper::plugins::webserver::pages::users;

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



sub default
{
	my ($globals,$module,$daction,$request) = @_;

	# If we not passed default by the main app, just return
	return if ($daction ne "default");


	# Build content
	my $content = "";

	# Header
	$content .=<<EOF;
<table class="table">
	<caption>User List</caption>
	<thead>
		<tr>
			<th>#</th>
			<th>User</th>
			<th>IP</th>
			<th>Group</th>
			<th>Class</th>
			<th>Limits</th>
		</tr>
	</thead>
	<tbody>
EOF
	# Body
	foreach my $userid (keys %{$globals->{'users'}}) {
		my $user = $globals->{'users'}->{$userid};

		# Make style a bit pretty
		my $style = "";
		if ($user->{'Status'} eq "offline") {
			$style = "warning";
		} elsif ($user->{'Status'} eq "new") {
			$style = "info";
		}

		$content .=<<EOF;
		<tr class="$style">
			<td>X</td>
			<td>$user->{'Username'}</td>
			<td>$user->{'IP'}</td>
			<td>$user->{'GroupName'}</td>
			<td>$user->{'ClassName'}</td>
			<td>$user->{'Limits'}</td>
		</tr>
EOF
	}
	# No results
	if (keys %{$globals->{'users'}} < 1) {
		$content .=<<EOF;
		<tr class="info">
			<td colspan="6"><p class="text-center">No Results</p></td>
		</tr>
EOF
	}

	# Footer
	$content .=<<EOF;
	</tbody>
</table>
EOF


	return (200,$content);
}


1;
