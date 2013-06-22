# OpenTrafficShaper webserver module
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



package opentrafficshaper::plugins::webserver;

use strict;
use warnings;

use HTML::Entities;
use HTTP::Response;
use HTTP::Status qw(:constants :is status_message);
use POE qw(Component::Server::TCP Filter::HTTPD);

use opentrafficshaper::logger;

# Pages (this is used a little below)
use opentrafficshaper::plugins::webserver::pages::static;
use opentrafficshaper::plugins::webserver::pages::index;
use opentrafficshaper::plugins::webserver::pages::users;


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
);

use constant {
	VERSION => '0.0.1'
};


# Plugin info
our $pluginInfo = {
	Name => "Webserver",
	Version => VERSION,
	
	Init => \&init,
};


# Copy of system globals
my $globals;
my $logger;
# This is the mapping of our pages
my $pages = {
	'index' => {
		'_catchall' => \&opentrafficshaper::plugins::webserver::pages::index::_catchall,
	},
	'static' => {
		'_catchall' => \&opentrafficshaper::plugins::webserver::pages::static::_catchall,
	},
	'users' => {
		'default' => \&opentrafficshaper::plugins::webserver::pages::users::default,
	},
};



# Initialize plugin
sub init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	# Spawn a web server on port 8088 of all interfaces.
	POE::Component::Server::TCP->new(
		Alias => "webserver",
		Port => 8088,
		ClientFilter => 'POE::Filter::HTTPD',
		# Function to handle HTTP requests (as we passing through a filter)
		ClientInput => \&handle_request
	);

	$logger->log(LOG_NOTICE,"[WEBSERVER] OpenTrafficShaper Webserver Module v".VERSION." - Copyright (c) 2013, AllWorldIT")
}


sub handle_request
{
	my ($kernel, $heap, $request) = @_[KERNEL, HEAP, ARG0];


	# We going to init these as system so we know whats a parsing issue
	my $module = "system";
	my $action = "parse";
	# This is our response
	my $response;

	# We may have a response from the filter indicating an error
	if ($request->isa("HTTP::Response")) {
		$heap->{client}->put($request);
		goto END;
	}

	# Split off the URL into a module and action
	my (undef,$dmodule,$daction,@dparams) = split(/\//,$request->uri);
	# If any is blank, set it to the default
	$dmodule = "index" if (!defined($dmodule));
	$daction = "default" if (!defined($daction));
	# Sanitize
	($module = $dmodule) =~ s/[^A-Za-z0-9]//g;	
	($action = $daction) =~ s/[^A-Za-z0-9]//g;	
	# If module name is sneaky? then just block it
	if ($module ne $dmodule) {
		$response = httpDisplayFault(HTTP_FORBIDDEN,"Method Not Allowed","The requested resource '".encode_entities($module)."' is not allowed.");
		goto END;
	}

	# This is the function we going to call
	# If we have a function name, try use it
	if (defined($pages->{$module})) {
		# If there is no specific action for this use the catchall
		if (!defined($pages->{$module}->{$action}) && defined($pages->{$module}->{'_catchall'})) {
			$action = "_catchall";
		}

		# Check if it exists first
		if (defined($pages->{$module}->{$action})) {
			my ($res,$content,$extra) = $pages->{$module}->{$action}->($globals,$module,$daction,$request);

			# Module return undef if they don't want to handle the request
			if (!defined($res)) {
				$response = httpDisplayFault(HTTP_NOT_FOUND,"Resource Not found","The requested resource '".encode_entities($daction)."' cannot be found");
			} elsif (ref($res) eq "HTTP::Response") {
				$response = $res;
			# TODO: This is a bit dirty
			} elsif ($res == HTTP_OK) {
				$response = httpCreateResponse($content);
			# TODO - redirect?
			} else {
				httpDisplayFault($res,$content,$extra);
			}
		} else {
			$response = httpDisplayFault(HTTP_NOT_FOUND,"Method Not found","The requested method '".encode_entities($action)."' cannot be found in '".encode_entities($module)."'");
		}
	}

	if (!defined($response)) {
		$response = httpDisplayFault(HTTP_NOT_FOUND,"Resource Not found","The requested resource '".encode_entities($module)."' cannot be found");
	}


END:
	$logger->log(LOG_INFO,"[WEBSERVER] Access: ".$response->code." [$module/$action] - ".$request->method." ".$request->uri." ".$request->protocol);
	$heap->{client}->put($response);
	$kernel->yield("shutdown");
}



# Display fault
sub httpDisplayFault
{
	my ($code,$msg,$description) = @_;


	# Throw out message to client to authenticate first
	my $headers = HTTP::Headers->new;
	$headers->content_type("text/html");

	my $resp = HTTP::Response->new(
			$code,$msg,
			$headers,
			<<EOF);
<!DOCTYPE html>
<html>
	<head>
		<title>$code $msg</title>
	</head>

	<body>
		<h1>$msg</h1>
		<p>$description</p>
	</body>
</html>
EOF
	return $resp;
}



# Create a response object
sub httpCreateResponse
{
	my ($msg) = @_;


	# Throw out message to client to authenticate first
	my $headers = HTTP::Headers->new;
	$headers->content_type("text/html");

	my $resp = HTTP::Response->new(
			HTTP_OK,"Ok",
			$headers,
			<<EOF);
<!DOCTYPE html>
	<head>
		<title>OpenTrafficShaper - Enterprise Traffic Shaper</title>
		<meta name="viewport" content="width=device-width, initial-scale=1.0">
		<!-- Assets -->
		<link href="/static/jquery-ui/css/ui-lightness/jquery-ui.min.css" rel="stylesheet" media="screen">
		<link href="/static/bootstrap/css/bootstrap.min.css" rel="stylesheet" media="screen">

		<style type="text/css">
			body {
				padding-top: 60px;
				padding-bottom: 40px;
			}
			.sidebar-nav {
				padding: 9px 0;
			}
			\@media (max-width: 980px) {
				/* Enable use of floated navbar text */
				.navbar-text.pull-right {
					float: none;
					padding-left: 5px;
					padding-right: 5px;
				}
			}
		</style>

		<!-- End Assets -->
		<link href="/static/bootstrap/css/bootstrap-responsive.min.css" rel="stylesheet" media="screen">
	</head>
	<body>

		<div class="navbar navbar-inverse navbar-fixed-top">
			<div class="navbar-inner">
				<div class="container-fluid">
					<button type="button" class="btn btn-navbar" data-toggle="collapse" data-target=".nav-collapse">
						<span class="icon-bar"></span>
						<span class="icon-bar"></span>
						<span class="icon-bar"></span>
					</button>
   					<a class="brand" href="/">OpenTrafficShaper</a>
					<div class="nav-collapse collapse">
						<p class="navbar-text pull-right">Logged in as <a href="#" class="navbar-link">Username</a>	</p>
						<ul class="nav">
							<li class="active"><a href="#">Home</a></li>
							<li><a href="/users">Users</a></li>
						</ul>
					</div><!--/.nav-collapse -->
				</div>
			</div>
		</div>

		<div class="container-fluid">
			<div class="row-fluid">
				<div class="span1">
					<div class="well sidebar-nav">
						<ul class="nav nav-list">
							<li class="nav-header">Sidebar</li>
							<li class="active"><a href="#">Link</a></li>
							<li><a href="#">Link</a></li>
							<li class="nav-header">Sidebar</li>
							<li><a href="#">Link</a></li>
						</ul>
					</div><!--/.well -->
				</div><!--/span-->
				<div class="span10">
					$msg
				</div><!--/span-->
			</div><!--/row-->
			<hr>
			<footer>
				<p>v$globals->{'version'} - Copyright &copy; 2013,  <a href="http://www.allworldit.com">AllWorldIT</a></p>
			</footer>
		</div><!--/.fluid-container-->

		<!-- Javascript -->
		<script src="/static/jquery/js/jquery.min.js"></script>
		<script src="/static/jquery-ui/js/jquery-ui.min.js"></script>
		<script src="/static/bootstrap/js/bootstrap.min.js"></script>
  </body>
</html>
EOF
	return $resp;
}



1;
# vim: ts=4
