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
use HTTP::Status qw( :constants :is );
use JSON;
use POE qw( Component::Server::TCP );
use POE::Filter::HybridHTTP;
use URI;


use opentrafficshaper::logger;
use opentrafficshaper::plugins;

# Pages (this is used a little below)
use opentrafficshaper::plugins::webserver::pages::static;
use opentrafficshaper::plugins::webserver::pages::index;
use opentrafficshaper::plugins::webserver::pages::limits;
use opentrafficshaper::plugins::webserver::pages::configmanager;


# Exporter stuff
require Exporter;
our (@ISA,@EXPORT,@EXPORT_OK);
@ISA = qw(Exporter);
@EXPORT = qw(
);
@EXPORT_OK = qw(
	snapin_register
);

use constant {
	VERSION => '0.0.2'
};


# Plugin info
our $pluginInfo = {
	Name => "Webserver",
	Version => VERSION,

	Init => \&plugin_init,
	Start => \&plugin_start,
};


# Copy of system globals
my $globals;
my $logger;


# Client connections open
my $connections = { };

# Web resources
my $resources = {
	# HTTP
	'HTTP' => {
		'index' => {
			'_catchall' => \&opentrafficshaper::plugins::webserver::pages::index::_catchall,
		},
		'static' => {
			'_catchall' => \&opentrafficshaper::plugins::webserver::pages::static::_catchall,
		},
		'limits' => {
			'default' => \&opentrafficshaper::plugins::webserver::pages::limits::default,
			'limit-add' => \&opentrafficshaper::plugins::webserver::pages::limits::limit_addedit,
			'limit-remove' => \&opentrafficshaper::plugins::webserver::pages::limits::limit_remove,
			'limit-edit' => \&opentrafficshaper::plugins::webserver::pages::limits::limit_addedit,
		},
		'configmanager' => {
			'default' => \&opentrafficshaper::plugins::webserver::pages::configmanager::default,
			'override-add' => \&opentrafficshaper::plugins::webserver::pages::configmanager::override_addedit,
			'override-remove' => \&opentrafficshaper::plugins::webserver::pages::configmanager::override_remove,
			'override-edit' => \&opentrafficshaper::plugins::webserver::pages::configmanager::override_addedit,
		},
	},
};



# Add webserver snapin
sub snapin_register
{
	my ($protocol,$module,$action,$data) = @_;


	$logger->log(LOG_INFO,"[WEBSERVER] Registered snapin: protocol = $protocol, module = $module, action = $action");

	# Load resource
	$resources->{$protocol}->{$module}->{$action} = $data;
}




# Initialize plugin
sub plugin_init
{
	$globals = shift;


	# Setup our environment
	$logger = $globals->{'logger'};

	$logger->log(LOG_NOTICE,"[WEBSERVER] OpenTrafficShaper Webserver Module v".VERSION." - Copyright (c) 2013, AllWorldIT");

	# Spawn a web server on port 8088 of all interfaces.
	POE::Component::Server::TCP->new(
		Port => 8088,
		# Handle session connections & disconnections
		ClientConnected => \&server_client_connected,
		ClientDisconnected => \&server_client_disconnected,
		# Filter to handle HTTP
		ClientFilter => 'POE::Filter::HybridHTTP',
		# Function to handle HTTP requests (as we passing through a filter)
		ClientInput => \&server_request,
		# Setup the sever
		Started => \&server_session_start,
		Stopped => \&server_session_stop,
	);

	# Load statistics pages if the statistics module is enabled
	if (isPluginLoaded('statistics')) {
		# Check if we can actually load the pages
		eval("use opentrafficshaper::plugins::webserver::pages::statistics");
		if ($@) {
			$logger->log(LOG_INFO,"[WEBSERVER] Failed to load statistics pages: $@");
		} else {
			# Load resources
			$resources->{'HTTP'}->{'statistics'} = {
				'by-limit' => \&opentrafficshaper::plugins::webserver::pages::statistics::bylimit,
				'by-class' => \&opentrafficshaper::plugins::webserver::pages::statistics::byclass,

				'jsondata' => \&opentrafficshaper::plugins::webserver::pages::statistics::jsondata
			};
			$logger->log(LOG_INFO,"[WEBSERVER] Loaded statistics pages as statistics module is loaded");
		}
	}

	return 1;
}


# Start the plugin
sub plugin_start
{
	$logger->log(LOG_INFO,"[WEBSERVER] Started");
}



# Server session started
sub server_session_start
{
	my $kernel = $_[KERNEL];

	$logger->log(LOG_DEBUG,"[WEBSERVER] Initialized");
}


# Server session stopped
sub server_session_stop
{
	my $kernel = $_[KERNEL];

	$logger->log(LOG_DEBUG,"[WEBSERVER] Shutdown");
}


# Signal that the client has connected
sub server_client_connected
{
	my ($kernel,$heap,$session,$request) = @_[KERNEL, HEAP, SESSION, ARG0];
	my $client_session_id = $session->ID;


	# Save our socket on the client
	$connections->{$client_session_id}->{'socket'} = $heap->{'client'};
	$connections->{$client_session_id}->{'protocol'} = 'HTTP';
}


# Signal that the client has disconnected
sub server_client_disconnected
{
	my ($kernel,$heap,$session,$request) = @_[KERNEL, HEAP, SESSION, ARG0];
	my $client_session_id = $session->ID;


	# Check if we have a disconnection function to call
	if (
			defined($connections->{$client_session_id}->{'resource'}) &&
			defined($connections->{$client_session_id}->{'resource'}->{'handler'}) &&
			ref($connections->{$client_session_id}->{'resource'}->{'handler'}) eq 'HASH' &&
			defined($connections->{$client_session_id}->{'resource'}->{'handler'}->{'on_disconnect'})
	) {
		# Call disconnection function
		$connections->{$client_session_id}->{'resource'}->{'handler'}->{'on_disconnect'}->($kernel,$globals,$client_session_id);
	}

	# Remove client session
	delete($connections->{$client_session_id});
}


# Handle the HTTP request
sub server_request
{
	my ($kernel,$heap,$session,$request) = @_[KERNEL, HEAP, SESSION, ARG0];
	my $client_session_id = $session->ID;
	my $conn = $connections->{$client_session_id};


	# Our response back if one, and if we should just close the connection or not
	my $response;
	my $closeWhenDone = 0;

	# Its HTTP
	if ($conn->{'protocol'} eq "HTTP") {
		# Check the protocol we're currently handling
		# We may have a response from the filter indicating an error
		if (ref($request) eq "HTTP::Response") {
			$response = $request;

		# Its a normal HTTP request
		} elsif (ref($request) eq "HTTP::Request") {
			$response = _server_request_http($kernel,$client_session_id,$request);
		}

		# Support for HTTP/1.1 "Connection: close" header...
		if ($request->header('Connection') eq "close") {
			$closeWhenDone = 1;
		}

	# Its a websocket
	} elsif ($conn->{'protocol'} eq "WebSocket") {
		# XXX - this should call the callback
	}

	# If there is a response send it
	if (defined($response)) {
		$conn->{'socket'}->put($response);
	}

	# Check if connection must be closed
	if ($closeWhenDone) {
		$kernel->yield("shutdown");
	}
}


# Display fault
sub httpDisplayFault
{
	my ($code,$message,$description) = @_;


	# Throw out message to client to authenticate first
	my $headers = HTTP::Headers->new;
	$headers->content_type("text/html");

	my $response = HTTP::Response->new(
			$code,$message,
			$headers,
			<<EOF);
<!DOCTYPE html>
<html>
	<head>
		<title>$code $message</title>
	</head>

	<body>
		<h1>$message</h1>
		<p>$description</p>
	</body>
</html>
EOF
	return $response;
}


# Do a redirect
sub httpRedirect
{
	my $url = shift;

	return HTTP::Response->new(HTTP_FOUND, 'Redirect', [Location => $url]);
}


# Create a response object
sub httpCreateResponse
{
	my ($module,$content,$options) = @_;


	# Throw out message to client to authenticate first
	my $headers = HTTP::Headers->new;
	my $payload = "";

	# Check if we have a specific return type, if not set default
	if (!defined($options->{'type'})) {
		$options->{'type'} = 'webpage';
	}

	# If we returning a webpage, handle it that way
	if ($options->{'type'} eq 'webpage') {
		# Set header
		$headers->content_type("text/html");

		# Bootstrap stuff
		my $mainCols = 12;

		# Check if we have a menu structure, if we do, display the sidebar
		my $styleStr = "";
		my $menuStr = "";
		my $javascriptStr = "";
		if (defined($options)) {
			# Check if style snippet exists
			if (defined(my $style = $options->{'style'})) {
				$styleStr .= $style;
			}

			# Check if menu exists
			if (my $menu = $options->{'menu'}) {
				$menuStr =<<EOF;
					<div class="col-xs-2">
						<ul class="nav nav-pills nav-stacked">
EOF
				# Loop with sub menu sections
				foreach my $section (@{$menu}) {
					my $sectionName = encode_entities($section->{'name'});
					$menuStr .=<<EOF;
							<li class="nav-header">$sectionName</li>
EOF
					# Loop with menu items
					foreach my $item (@{$section->{'items'}}) {
						my $itemName = encode_entities($item->{'name'});
						# Sanitize link
						my $itemLink = "/" . $module . "/" . $item->{'link'};
						$itemLink =~ s,/+$,,;

						# Build sections
						$menuStr .=<<EOF;
								<li><a href="$itemLink">$itemName</a></li>
EOF
					}
				}
				$menuStr .=<<EOF;
						</ul>
					</div>
EOF

				# Reduce number of main cols to make way for menu
				$mainCols = 10;
			}

			# Check if we have a list of javascript assets
			if (defined(my $javascripts = $options->{'javascripts'})) {
				foreach my $script (@{$javascripts}) {
					$javascriptStr .=<<EOF;
						<script type="text/javascript" src="$script"></script>
EOF
				}
			}
			# Check if javascript snippet exists
			if (defined(my $javascript = $options->{'javascript'})) {
				$javascriptStr .=<<EOF;
					<script type="text/javascript">
$javascript
					</script>
EOF
			}
		}

		# Create the payload we returning
		$payload = <<EOF;
<!DOCTYPE html>
	<head>
		<title>OpenTrafficShaper - Enterprise Traffic Shaper</title>
		<meta name="viewport" content="width=device-width, initial-scale=1.0">
		<!-- Assets -->
		<link href="/static/favicon.ico" rel="icon" />
		<link href="/static/jquery-ui/css/ui-lightness/jquery-ui.min.css" rel="stylesheet">
		<link href="/static/bootstrap/css/bootstrap.min.css" rel="stylesheet">

		<style type="text/css">
			body {
				padding-top: 50px;
			}
$styleStr
		</style>
		<!-- End Assets -->
	</head>

	<body>
		<div class="navbar navbar-inverse navbar-fixed-top">
			<a class="navbar-brand" href="/"><img src="/static/logo-inverted-short.png" alt="Open Traffic Shaper" width="100%" height="auto" /></a>
			<div class="container">
				<div class="navbar-header">
					<button type="button" class="navbar-toggle" data-toggle="collapse" data-target=".navbar-collapse">
						<span class="icon-bar"></span>
						<span class="icon-bar"></span>
						<span class="icon-bar"></span>
					</button>
				</div>
				<div class="collapse navbar-collapse">
					<ul class="nav navbar-nav">
						<li class="active"><a href="/">Home</a></li>
						<li><a href="/limits">Limits</a></li>
						<li><a href="/configmanager">ConfigManager</a></li>
					</ul>
				</div>
			</div>
		</div>

		<div style="padding: 15px 15px">
			<div class="row">
$menuStr
				<div class="col-xs-$mainCols">
$content
				</div>
			</div>
		</div>
		<div style="padding: 0 15px">
			<hr />
			<footer>
				<p class="muted">v$globals->{'version'} - Copyright &copy; 2013,  <a href="http://www.allworldit.com">AllWorldIT</a></p>
			</footer>
		</div>
	</body>


	<script type="text/javascript" src="/static/jquery/js/jquery.min.js"></script>
	<script type="text/javascript" src="/static/jquery-ui/js/jquery-ui.min.js"></script>
	<script type="text/javascript" src="/static/bootstrap/js/bootstrap.min.js"></script>
$javascriptStr

</html>
EOF

	# Maybe we're json?
	} elsif ($options->{'type'} eq 'json') {
		# Set header
		$headers->content_type("application/json");
		$payload = encode_json($content);
	}

	# Build action response
	my $resp = HTTP::Response->new(
			HTTP_OK,"Ok",
			$headers,
			$payload
	);

	return $resp;
}


#
# Internals
#


# Handle the normal HTTP protocol
sub _server_request_http
{
	my ($kernel,$client_session_id,$request) = @_;
	my $conn = $connections->{$client_session_id};


	my $protocol = "HTTP"; # By default we're HTTP

	# Pull off connection attributes
	my $header_connection;
	if (my $h_connection = $request->header('Connection')) {
		foreach my $param (split(/[ ,]+/,$h_connection)) {
			$header_connection->{lc($param)} = 1;
		}

		# Identify and split off upgrades
		if (defined($header_connection->{'upgrade'}) && (my $h_upgrade = $request->header('upgrade'))) {
			$h_upgrade = lc($h_upgrade);
			if ($h_upgrade eq "websocket") {
				$protocol = "HTTP=>WebSocket";
			}
		}
	}

	# XXX: Check method & encoding, in all protocols??
	if ($request->method eq "POST") {
		# We currently only accept form data
		if ($request->content_type ne "application/x-www-form-urlencoded") {
			return httpDisplayFault(HTTP_FORBIDDEN,"Method Not Allowed","The requested method and content type is not allowed.");
		}
	}

	# This is going to be our response back
	my $response;

	# Parse our protocol into a module & action
	my ($handler,$module,$action) = _parse_http_resource($request,$protocol);
	# Short circuit if we had an error
	if (ref($handler) eq "HTTP::Response") {
		# There is no module or action
		$module = ""; $action = "";
		# Set our response
		$response = $handler;
		goto END;
	}

	# Function we need to call
	my $function = $handler;

	# Check if we're a hash... override if we are
	if (ref($handler) eq "HASH") {
		$function = $handler->{'on_request'};
	}
	# If its something else, blow up
	if (ref($function) ne "CODE") {
		return httpDisplayFault(HTTP_INTERNAL_SERVER_ERROR,"Internal server error","Server configuration error");
	}

	$logger->log(LOG_DEBUG,"[WEBSERVER] Parsed HTTP request into: module='$module', action='$action'");

	# Save what resource we just accessed
	$connections->{$client_session_id}->{'resource'} = {
		'module' => $module,
		'action' => $action,
		'handler' => $handler,
	};

	# This is normal HTTP request
	if ($protocol eq "HTTP") {
		# Do the function call now
		my ($res,$content,$extra) = $function->($kernel,$globals,$client_session_id,$request);


		# Module return undef if they don't want to handle the request
		if (!defined($res)) {
			$response = httpDisplayFault(HTTP_NOT_FOUND,"Resource Not found","The requested resource '$action' cannot be found");
		} elsif (ref($res) eq "HTTP::Response") {
			$response = $res;
		# TODO: This is a bit dirty
		# Extra in this case is the sidebar menu items
		} elsif ($res == HTTP_OK) {
			$response = httpCreateResponse($module,$content,$extra);
		# The content in a redirect is the URL
		} elsif ($res == HTTP_TEMPORARY_REDIRECT) {
			$response = httpRedirect("//".$request->header('host')."/" . $content);
		# Extra in this case is the error description
		} else {
			$response = httpDisplayFault($res,$content,$extra);
		}


	# Its a websocket upgrade request
	} elsif ($protocol eq "HTTP=>WebSocket") {
		# Do the function call now
		my ($res,$ret1,$ret2) = $function->($kernel,$globals,$client_session_id,$request,$conn->{'socket'});

		# If we have a response defined, we rejected the upgrade
		if (defined($res)) {
			$response = httpDisplayFault($res,$ret1,$ret2);
		} else {
			# Return our upgrade response
			$response = _server_request_http_wsupgrade($request,$module,$action);
			# Upgrade the protocol
			$connections->{$client_session_id}->{'protocol'} = 'WebSocket';
		}
	}

END:

	$logger->log(LOG_INFO,"[WEBSERVER] $protocol Request: ".$response->code." [$module/$action] - ".encode_entities($request->method)." ".
			encode_entities($request->uri)." ".encode_entities($request->protocol));

	return $response;
}


# Function to parse a HTTP resource
sub _parse_http_resource
{
	my ($request,$protocol) = @_;
	my $resource = $resources->{$protocol};


	# No resource defined
	if (!defined($resource)) {
		return httpDisplayFault(HTTP_FORBIDDEN,"Protocol Not Available","The requested protocol is not available.");
	}

	# Split off the URL into a module and action
	my (undef,$dmodule,$daction) = $request->uri->path_segments();
	# If any is blank, set it to the default
	$dmodule = "index" if (!defined($dmodule) || $dmodule eq "");
	$daction = "default" if (!defined($daction) || $daction eq "");
	# Sanitize
	(my $module = $dmodule) =~ s/[^A-Za-z0-9]//g;
	(my $action = $daction) =~ s/[^A-Za-z0-9\-]//g;

	# If module name is sneaky? then just block it
	if ($module ne $dmodule) {
		return httpDisplayFault(HTTP_FORBIDDEN,"Method Not Allowed","The requested resource '$module' is not allowed.");
	}

	# If there is no resource to handle this return
	if (!defined($resource->{$module})) {
		return httpDisplayFault(HTTP_NOT_FOUND,"Resource Not found","The requested resource '$module' cannot be found");
	}

	# If there is no specific action for this use the catchall
	if (!defined($resource->{$module}->{$action}) && defined($resource->{$module}->{'_catchall'})) {
		$action = "_catchall";
	}

	# Check if it exists first
	if (!defined($resource->{$module}->{$action})) {
		return httpDisplayFault(HTTP_NOT_FOUND,"Method Not found","The requested method '$action' cannot be found in '$module'");
	}

	# This is the handler data, either a CODE ref or a HASH
	my $handler = $resource->{$module}->{$action};

	# Check if the destination is a hash containing stuff we can treat specially
	if (ref($handler) eq "HASH") {
		# If we have a list of requires, check them
		if (defined($handler->{'requires'})) {
			foreach my $require (@{$handler->{'requires'}}) {
				if (!isPluginLoaded($require)) {
					return httpDisplayFault(HTTP_NOT_IMPLEMENTED,"Method Not Available","The requested method '$action' in '$module' is not currently available");
				}
			}
		}
	}

	return ($handler,$module,$action);
}


# Handle Websocket
sub _server_request_http_wsupgrade
{
	my ($request,$module,$action) = @_;
	my $response;



	# Build handshake reply
	my $headers = HTTP::Headers->new(
		'Upgrade' => "websocket",
		'Connection' => "upgrade",
	);

	# Build response switching protocols
	$response = HTTP::Response->new(
			HTTP_SWITCHING_PROTOCOLS,"Switching Protocols",
			$headers
	);

	$logger->log(LOG_INFO,"[WEBSERVER] WebSocket Upgrade: ".$response->code." [$module/$action] - ".encode_entities($request->method)." ".
			encode_entities($request->uri)." ".encode_entities($request->protocol));

	return $response;
}



1;
# vim: ts=4
