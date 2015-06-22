# POE::Filter::HybridHTTP::WebSocketFrame - Copyright 2013-2015, AllworldIT
# Hybrid HTTP filter support for WebSocketFrames
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
# Code originally based on Protocol::WebSocket::Frame
##
# CREDITS:
# Paul "LeoNerd" Evans
# Jon Gentle
# Lee Aylward
# Chia-liang Kao
# Atomer Ju
# Chuck Bredestege
# Matthew Lien (BlueT)
# AUTHOR:
# Viacheslav Tykhanovskyi, C<vti@cpan.org>.
# COPYRIGHT:
# Copyright (C) 2010-2012, Viacheslav Tykhanovskyi.
# This program is free software, you can redistribute it and/or modify it under
# the same terms as Perl 5.10.
##

package opentrafficshaper::POE::Filter::HybridHTTP::WebSocketFrame;

use bytes;

use strict;
use warnings;

use Config;
use Encode ();

# Random number generation
use constant MAX_RAND_INT => 2 ** 32;
use constant MATH_RANDOM_SECURE => eval "require Math::Random::Secure;";

our %TYPES = (
	text => 0x01,
	binary => 0x02,
	ping => 0x09,
	pong => 0x0a,
	close => 0x08
);

use constant {
	WS_MAX_FRAGMENTS => 1024,
	WS_MAX_PAYLOAD_SIZE => 131072,
};


sub new {
	my ($class,$buffer) = @_;


	if (my $classRef = ref $class) {
		$class = $classRef;
	}

	# If we don't have a buffer just use an empty string
	if (!defined($buffer)) {
		$buffer = "";
	}

	# Setup ourself
	my $self = {
		'buffer' => Encode::is_utf8($buffer) ? Encode::encode('UTF-8', $buffer) : $buffer,
		'fragments' => [ ],
		'max_payload_size' => WS_MAX_PAYLOAD_SIZE,
		'max_fragments' => WS_MAX_FRAGMENTS,
	};

	bless($self,$class);

	return $self;
}


sub append {
	my ($self,$data) = @_;

	# If there is no data just return
	if (!defined($data)) {
		return;
	}

	$self->{'buffer'} .= $data;

	return $self;
}


sub next {
	my $self = shift;

	# If we have next_bytes return
	if (defined(my $bytes = $self->next_bytes)) {
		return Encode::decode('UTF-8', $bytes);
	}

	return; 
}

sub fin	{ @_ > 1 ? $_[0]->{fin}	= $_[1] : $_[0]->{fin} }
sub rsv	{ @_ > 1 ? $_[0]->{rsv}	= $_[1] : $_[0]->{rsv} }
sub opcode { @_ > 1 ? $_[0]->{opcode} = $_[1] : $_[0]->{opcode} || 1 }
sub masked { @_ > 1 ? $_[0]->{masked} = $_[1] : $_[0]->{masked} }

sub is_ping   { $_[0]->opcode == 9 }
sub is_pong   { $_[0]->opcode == 10 }
sub is_close  { $_[0]->opcode == 8 }
sub is_text   { $_[0]->opcode == 1 }
sub is_binary { $_[0]->opcode == 2 }


sub next_bytes {
	my $self = shift;

	return unless length $self->{'buffer'} >= 2;

	while (my $buffer_len = length($self->{'buffer'})) {
		my $offset = 0;


		# Grab first byte
		my $hdr = substr($self->{'buffer'}, $offset, 1);
		# Reduce first hdr byte to bits
		my @bits = split //, unpack("B*", $hdr);
		# Set the FIN attribute
		$self->fin($bits[0]);
		# And the RSV (reserved)
		$self->rsv([@bits[1 .. 3]]);

		# Pull off the opcode & update offset
		my $opcode = unpack('C', $hdr) & 0b00001111;
		$offset += 1;	# FIN,RSV[1-3],OPCODE

		# Grab payload length
		my $payload_len = unpack('C',substr($self->{'buffer'}, $offset, 1));

		# Check if the payload is masked, if it is flag it internally
		my $masked = ($payload_len & 0b10000000) >> 7;
		$self->masked($masked);
		$offset += 1;	  # + MASKED,PAYLOAD_LEN

		$payload_len = $payload_len & 0b01111111;
		if ($payload_len == 126) {
			# Not enough data
			if ($buffer_len < $offset + 2) {
				return;
			}
			# Unpack the payload_len into its actual value & bump the offset
			$payload_len = unpack('n',substr($self->{'buffer'},$offset,2));
			$offset += 2;

		} elsif ($payload_len > 126) {
			# Not enough data
			if ($buffer_len < $offset + 4) {
				return;
			}

			# Map off the first 8 bits
			my $bits = unpack('B*',substr($self->{'buffer'},$offset,8));
			# Most significant bit must be 0
			substr($bits,0,1,0);

			# Can we not handle 64bit numbers?
			if ($Config{'ivsize'} <= 4 || $Config{longsize} < 8) {
				# If not, just use 32 bits
				$bits = substr($bits, 32);
				$payload_len = unpack('N',pack('B*',$bits));
			# If we can use everything we have
			} else {
				$payload_len = unpack('Q>',pack('B*',$bits));
			}
			# Bump offset
			$offset += 8;
		}
		# XXX - not sure how to return this sanely
        if ($payload_len > $self->{'max_payload_size'}) {
			$self->{'buffer'} = '';
			return;
		}

		# Grab the mask
		my $mask;
		if ($self->masked) {
			# Not enough data
			if ($buffer_len < $offset + 4) {
				return;
			}
			# Pull it off
			$mask = substr($self->{'buffer'}, $offset, 4);
			$offset += 4;
		}

		# Check if we have enough data to satisfy our payload_len
		if ($buffer_len < $offset + $payload_len) {
			return;
		}

		# If we do, rip it all off and shove it into $payload
		my $payload = substr($self->{'buffer'}, $offset, $payload_len);

		# If our data is masked, unmask it
		if ($self->masked) {
			$payload = $self->_mask($payload, $mask);
		}

		substr($self->{'buffer'}, 0, $offset + $payload_len, '');

		# Injected control frame
		if (@{$self->{'fragments'}} && $opcode & 0b1000) {
			$self->opcode($opcode);
			return $payload;
		}

		# Check if this is the last packet in a set of fragments, if it is combine everything
		if ($self->fin) {
			if (@{$self->{'fragments'}}) {
				$self->opcode(shift @{$self->{'fragments'}});
			} else {
				$self->opcode($opcode);
			}
			# Join everything up
			$payload = join('',@{$self->{'fragments'}},$payload);
			$self->{'fragments'} = [];
			# And return
			return $payload;

		} else {
			# Remember first fragment opcode
			if (!@{$self->{'fragments'}}) {
				push @{$self->{'fragments'}}, $opcode;
			}

			push(@{$self->{'fragments'}},$payload);

			# XXX - Handle sanely?
			if (@{$self->{'fragments'}} > $self->{'max_fragments'}) {
				$self->{'fragments'} = [];
				$self->{'buffer'} = '';
				return;
			}
		}
	}

	return;
}


sub to_bytes {
	my $self = shift;


	my $string = '';

	my $opcode;
	if (my $type = $self->{'type'}) {
		$opcode = $TYPES{$type};
	}
	else {
		$opcode = $self->opcode || 1;
	}

	# Set FIN + black RSV + set OPCODE in the first 8 bites
	$string .= pack('C',($opcode | 0b10000000) & 0b10001111);

	my $payload_len = length($self->{'buffer'});
	if ($payload_len <= 125) {
		# Flip masked bit if we're masked
		$payload_len |= 0b10000000 if $self->masked;
		# Encode the payload length and add to string
		$string .= pack('C',$payload_len);
	}
	elsif ($payload_len <= 0xffff) {
		my $bits = 0b01111110;
		$bits |= 0b10000000 if $self->masked;

		$string .= pack('C',$bits);
		$string .= pack('n',$payload_len);
	}
	else {
		my $bits = 0b01111111;
		$bits |= 0b10000000 if $self->masked;

		$string .= pack('C',$bits);

		# Shifting by an amount >= to the system wordsize is undefined
		$string .= pack('N',$Config{'ivsize'} <= 4 ? 0 : $payload_len >> 32);
		$string .= pack('N',($payload_len & 0xffffffff));
	}
	if ($self->masked) {
		my $mask = $self->{mask} || ( MATH_RANDOM_SECURE ? Math::Random::Secure::irand(MAX_RAND_INT) : int(rand(MAX_RAND_INT)) );

		$mask = pack('N',$mask);

		$string .= $mask;
		$string .= $self->_mask($self->{'buffer'},$mask);
	}
	else {
		$string .= $self->{'buffer'};
	}

	# Wipe buffer
	$self->{'buffer'} = '';

	return $string;
}


sub _mask {
	my $self = shift;
	my ($payload, $mask) = @_;

	$mask = $mask x (int(length($payload) / 4) + 1);
	$mask = substr($mask, 0, length($payload));
	$payload ^= $mask;

	return $payload;
}

1;
# vim: ts=4
