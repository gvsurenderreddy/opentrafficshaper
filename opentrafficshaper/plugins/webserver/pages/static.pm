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

package opentrafficshaper::plugins::webserver::pages::static;

use strict;
use warnings;


use Cwd qw(abs_path);
use Fcntl ':mode';
use File::Basename;
use File::stat;
use HTTP::Status qw(:constants :is status_message);
use LWP::MediaTypes;


use opentrafficshaper::logger;


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
);


sub _catchall
{
	my ($kernel,$globals,$client_session_id,$request) = @_;
	my $logger = $globals->{'logger'};


	# Else get our resource name
	(my $resource = $request->uri) =~ s/[^A-Za-z0-9\-\/\.]//g;
	# Just abort if the request contains a transversal
	return if ($resource =~ /\.\./);
	# Again if its odd, abort
	return if ($resource ne $request->uri);
	# We going to override this to get the full path
	my @pathComponents = split(/\//,$resource);
	# This should remove /static
	shift(@pathComponents); shift(@pathComponents);
	# Join it back up
	$resource = join('/',@pathComponents);

	$logger->log(LOG_DEBUG,"[WEBSEVER/STATIC] Access request for resource '%s'",$resource);

	# Check if this is a supported method
	return if ($request->method ne "GET");


	# Build filename
	my $filename = dirname(abs_path(__FILE__))."/static/$resource";

	# Check it exists...
	if (! -f $filename) {
		$logger->log(LOG_WARN,"[WEBSERVER/STATIC] Resource '%s' does not exist or is not a normal file",$resource);
		return;
	}

	# Stat file first of all
    my $stat = stat($filename);
	if (!$stat) {
		$logger->log(LOG_WARN,"[WEBSERVER/STATIC] Unable to stat '%s': %s",$resource,$!);
		return;
	}

	# Check this is a file
	if (!S_ISREG($stat->mode)) {
		$logger->log(LOG_WARN,"[WEBSERVER/STATIC] Not a file '%s'",$resource);
		return;
	}

	# Build our response
	my $response = HTTP::Response->new(HTTP_OK);

	# path is a regular file
	my $file_size = $stat->size;
	$response->header('Content-Length', $file_size);
	LWP::MediaTypes::guess_media_type($filename, $response);
	# Check if-modified-since
	my $ims = $request->header('If-Modified-Since');
	if (defined $ims) {
		my $time = HTTP::Date::str2time($ims);
		if (defined($time) && $time >= $stat->mtime) {
			return HTTP::Response->new(HTTP::Status::RC_NOT_MODIFIED,$request->method." ".$resource)
		}
	}
	# Set header for file modified
	$response->header('Last-Modified', HTTP::Date::time2str($stat->mtime));

	# Open file handle
    if (!open(FH, "< $filename")) {
		$logger->log(LOG_WARN,"[WEBSERVER/STATIC] Unable to open '%s': %s",$resource,$!);
	}
	# Set to binary mode
	binmode(FH);
	# Suck in file
	my $buffer = "";
	my $len;
	do {
		$len = read(FH,$buffer,4096,length($buffer));
	} while ($len > 0);

	# Close file
	close(FH);
	# Set content
	$response->content($buffer);

    return $response;
}


1;
