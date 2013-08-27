# POE::Filter::HybridHTTP - Copyright 2013, AllworldIT
# Hybrid HTTP filter supporting websockets too.

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

package POE::Filter::HybridHTTP;

use warnings;
use strict;

use bytes;

use POE::Filter;
use POE::Filter::HybridHTTP::WebSocketFrame;

use vars qw($VERSION @ISA);
# NOTE - Should be #.### (three decimal places)
$VERSION = '1.000';
@ISA = qw(POE::Filter);


# States of the protocol
use constant {
	CRLF => "\r\n",
	# Protocol states
	ST_HTTP_HEADERS => 1, # Busy processing headers
	ST_HTTP_CONTENT => 2, # Busy processing the body
	ST_WEBSOCKET_STREAM => 3,
};

use Digest::SHA qw( sha1_base64 );
use HTTP::Date qw(time2str);
use HTTP::Request;
use HTTP::Response;
use HTTP::Status qw( :constants :is );
use URI;

my $HTTP_1_0 = _http_version("HTTP/1.0");
my $HTTP_1_1 = _http_version("HTTP/1.1");


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


	# Waiting for a complete suite of headers.
	if ($self->{'state'} == ST_HTTP_HEADERS) {
		return $self->_get_one_http_headers();

	# Waiting for content.
	} elsif ($self->{'state'} == ST_HTTP_CONTENT) {
		return $self->_get_one_http_content();
		
	# Websocket
	} elsif ($self->{'state'} == ST_WEBSOCKET_STREAM) {
		return $self->_get_one_websocket_record();

	# XXX - better handling?
	} else {
		die "Unknown state '".unpack("H*",$self->{'state'})."'";
	}
}


# Function to push data to the socket
sub put 
{
	my ($self, $responses) = @_;
	my @results;


	# Handle HTTP content
	if ($self->{'state'} == ST_HTTP_CONTENT || $self->{'state'} == ST_HTTP_HEADERS) {
		# Compile our list of results
		foreach my $response (@{$responses}) {
			# Check if we have a upgrade header
			if ((my $h_upgrade = $response->header("Upgrade")) && $response->code == HTTP_SWITCHING_PROTOCOLS) {
				# Check if its a websocket upgrade
				if (
						# Is it a request and do we have a original request?
						$h_upgrade eq "websocket" && defined($self->{'last_request'}) && 
						# If so was there a websocket-key?
						(my $websocketKey = $self->{'last_request'}->header('Sec-WebSocket-Key'))
				) {
					$self->{'state'} = ST_WEBSOCKET_STREAM;
					# GUID for this protocol as per RFC6455 Section 1.3
					my $websocketKeyResponseRaw = $websocketKey."258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
					my $websocketKeyResponse = sha1_base64($websocketKeyResponseRaw);
					# Pad up to base64 length   4[N/3] 
					$websocketKeyResponse .= "=" x ((length($websocketKeyResponse) * 3) % 4);
					$response->push_header('Sec-WebSocket-Accept',$websocketKeyResponse);
				}
			}

			push(@results,$self->_build_raw_response($response));
		}


	# Handle WebSocket data
	} elsif ($self->{'state'} == ST_WEBSOCKET_STREAM) {
		# Compile our list of results
		foreach my $response (@{$responses}) {
			# If we don't have a websocket write state, create one
			if (!$self->{'state_websocket_write'}) {
				$self->{'state_websocket_write'} = new POE::Filter::HybridHTTP::WebSocketFrame();
			}
			$self->{'state_websocket_write'}->append($response);

			push(@results,$self->{'state_websocket_write'}->to_bytes());
		}
	}

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
	$self->{'state'} = ST_HTTP_HEADERS;
	$self->{'state_websocket_read'} = undef;
	$self->{'state_websocket_write'} = undef;
	$self->{'last_request'} = $self->{'request'};
	$self->{'request'} = undef; # We want the last request always
	$self->{'content_len'} = 0;
	$self->{'content_added'} = 0;
}


# Internal function to parse an HTTP status line and return the HTTP
# protocol version.
sub _http_version 
{
	my $version = shift;

	# Rip off the version string
	if ($version =~ m,^(?:HTTP/)?(\d+)\.(\d+)$,i) {
		my $nversion = $1 * 1000 + $2;
		# Return a numerical version of it
		return $nversion;
	} else {
		# Or 0 if we did not match
		return 0;
	}
}


# Function to handle HTTP headers
sub _get_one_http_headers
{
	my $self = shift;


	# Strip leading whitespace.
	$self->{'buffer'} =~ s/^\s+//;

	# If we've not found the HTTP headers, just return a blank arrayref
	if ($self->{'buffer'} !~ s/^(\S.*?(?:\r?\n){2})//s) {
		return [ ];
	}
	# Pull the headers as a string off the buffer 
	my $header_str = $1;

	# Parse the request line.
	if ($header_str !~ s/^(\w+)[ \t]+(\S+)(?:[ \t]+(HTTP\/\d+\.\d+))?[^\n]*\n//) {
		return [
			$self->_build_error(HTTP_BAD_REQUEST, "Request line parse failure. ($header_str)")
		];
	}
	# Create an HTTP::Request object from values in the request line.
	my ($method, $uri, $proto) = ($1, $2, $3);
	# Make sure proto is set
	if (!_http_version($proto)) {
		$proto = "HTTP/1.0";
	}
	$self->{'protocol'} = $proto;
	$proto = _http_version($proto);

	# Fix a double starting slash on the path.	It happens.
	$uri =~ s!^//+!/!;

	# Build our request object
	my $request = HTTP::Request->new($method, URI->new($uri));
	# Set protocol
	$request->protocol($self->{'protocol'});

	# Parse headers.
	my ($key, $val);
	HEADER: while ($header_str =~ s/^([^\012]*)\012//) {
		my $header = $1;
		$header =~ s/\015$//;
		if ($header =~ /^([\w\-~]+)\s*:\s*(.*)/) {
			# If we had a key, it means we must save this key/value pair
			if ($key) {
				$request->push_header($key, $val);
			}
			# Assign key and value pair from above regex
			($key, $val) = ($1, $2);
		# Multi-line header value
		} elsif ($header =~ /^\s+(.*)/) {
			$val .= " $1";
		# We no longer matching, so this is the last header?
		} else {
			last HEADER;
	 	}
	}
	# Push on the last header if we had one...
	$request->push_header($key, $val) if $key;

	# We got a full set of headers.	Fall through to content if we
	# have a content length.
	my $content_length = $request->content_length();
	if(defined($content_length)) {
		$content_length =~ s/\D//g;
		# If its invalid, it will be 0 anyway
		$content_length = int($content_length);
	}
	my $content_encoding = $request->content_encoding();
		
	# The presence of a message-body in a request is signaled by the
	# inclusion of a Content-Length or Transfer-Encoding header field in
	# the request's message-headers. A message-body MUST NOT be included in
	# a request if the specification of the request method (section 5.1.1)
	# does not allow sending an entity-body in requests. A server SHOULD
	# read and forward a message-body on any request; if the request method
	# does not include defined semantics for an entity-body, then the
	# message-body SHOULD be ignored when handling the request.
	# - RFC2616
	if (!defined($content_length) && !defined($content_encoding)) {
		$self->{'request'} = $request;
		$self->_reset();
		return [ $request ];
	}

	# PG- GET shouldn't have a body. But RFC2616 talks about Content-Length
	# for HEAD.	And My reading of RFC2616 is that HEAD is the same as GET.
	# So logically, GET can have a body.	And RFC2616 says we SHOULD ignore
	# it.
	#
	# What's more, in apache 1.3.28, a body on a GET or HEAD is read
	# and discarded.	See ap_discard_request_body() in http_protocol.c and
	# default_handler() in http_core.c
	#
	# Neither Firefox 2.0 nor Lynx 2.8.5 set Content-Length on a GET

	# For compatibility with HTTP/1.0 applications, HTTP/1.1 requests
	# containing a message-body MUST include a valid Content-Length header
	# field unless the server is known to be HTTP/1.1 compliant. If a
	# request contains a message-body and a Content-Length is not given,
	# the server SHOULD respond with 400 (bad request) if it cannot
	# determine the length of the message, or with 411 (length required) if
	# it wishes to insist on receiving a valid Content-Length.
	# - RFC2616 

	# PG- This seems to imply that we can either detect the length (but how
	# would one do that?) or require a Content-Length header.	We do the
	# latter.
	# 
	# PG- Dispite all the above, I'm not fully sure this implements RFC2616
	# properly.	There's something about transfer-coding that I don't fully
	# understand.

	if (!$content_length) {			
		# assume a Content-Length of 0 is valid pre 1.1
		if ($proto >= $HTTP_1_1 && !defined($content_length)) {
			# We have Content-Encoding, but not Content-Length.
			$request = $self->_build_error(HTTP_LENGTH_REQUIRED,"No content length found.",$request);
		}
		$self->_reset();
		return [ $request ];
	}

	$self->{'content_length'} = $content_length;
	$self->{'state'} = ST_HTTP_CONTENT;
	$self->{'request'} = $request; 

	$self->_get_one_http_content();
}


sub _get_one_http_content
{
	my $self = shift;


	my $request = $self->{'request'};
	my $content_needed = $self->{'content_length'} - $self->{'content_added'};
	if ($content_needed < 1) {
		# We somehow got too much content
		$request = $self->_build_error(HTTP_BAD_REQUEST, "Too much content received");
		$self->_reset();
		return [ $request ];
	}

	# Not enough content to complete the request. Add it to the
	# request content, and return an incomplete status.
	if ((my $buflen = length($self->{'buffer'})) < $content_needed) {
		$request->add_content($self->{'buffer'});
		$self->{'content_added'} += $buflen;
		$self->{'buffer'} = '';
		return [ ];
	}

	# Enough data.	Add it to the request content.
	# PG- CGI.pm only reads Content-Length: bytes from STDIN.

	# Four-argument substr() would be ideal here, but it's not
	# entirely backward compatible.
	$request->add_content(substr($self->{'buffer'}, 0, $content_needed));
	substr($self->{'buffer'}, 0, $content_needed) = "";

	# Some browsers (like MSIE 5.01) send extra CRLFs after the
	# content.	Shame on them.
	$self->{'buffer'} =~ s/^\s+//;

	# XXX Should we throw the body away on a GET or HEAD? Probably not.

	# XXX Should we parse Multipart Types bodies?

	# Prepare for the next request, and return this one.
	$self->_reset();

	return [ $request ];
}


# Function to get a websocket record set
sub _get_one_websocket_record
{
	my $self = shift;


	# If we don't have a websocket state, create one
	if (!$self->{'state_websocket_read'}) {
		$self->{'state_websocket_read'} = new POE::Filter::HybridHTTP::WebSocketFrame();
	}
	$self->{'state_websocket_read'}->append($self->{'buffer'});
	# Blank our buffer
	$self->{'buffer'} = '';

	# Loop with records and push onto result set
	my @results;
	while (my $item = $self->{'state_websocket_read'}->next()) {
		push(@results,$item);
	}

	return \@results;
}


# Build a basic error to return
sub _build_error
{
	my($self, $status, $details, $request) = @_;


	# Setup defaults
	if (!defined($status)) {
		$status	= HTTP_BAD_REQUEST;
	}
	if (!defined($details)) {
		$details = '';
	}
	my $message = "Unknown Error";
	if (my $msg = status_message($status)) {
		$message = $msg;
	}

	# Build the response object
	my $response = new HTTP::Response->new($status,$message);
	$response->content(<<EOF);
<!DOCTYPE html>
<html>
	<head>
		<title>$status $message</title>
	</head>

	<body>
		<h1>$message</h1>
		<p>$details</p>
	</body>
</html>
EOF

	# If we have a request set it
	if ($request) {
		$response->request($request);
	}

	return $response;
}


# Build a socket friendly response
sub _build_raw_response
{
	my ($self,$response) = @_;


	# Check for headers we should return
	if (!defined($response->header("Date"))) {
		$response->push_header("Date",time2str(time));
	}
	if (!defined($response->header("Server"))) {
		$response->push_header("Server","POE Hybrid HTTP Server v$VERSION");
	}
	# Set our content Length
	if (my $length = length($response->content)) {
	    $response->push_header("Content-Length",$length);
	}

	# Setup our output
	my $output = sprintf("%s %s",$self->{'protocol'},$response->status_line);
	$output .= CRLF;
	$output .= $response->headers_as_string(CRLF);
	$output .= CRLF;
	$output .= $response->content;

	return $output;
}


1;
