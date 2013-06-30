package opentrafficshaper::plugins::radius::Radius::Packet;

use strict;
require Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $VSA);
@ISA       = qw(Exporter);
@EXPORT    = qw(auth_resp auth_acct_verify auth_req_verify);
@EXPORT_OK = qw( );

$VERSION = '1.55';

$VSA = 26;			# Type assigned in RFC2138 to the 
				# Vendor-Specific Attributes

# Be sure our dictionaries are current
use opentrafficshaper::plugins::radius::Radius::Dictionary 1.50;
use Carp;
use Socket;
use Digest::MD5;

my (%unkvprinted, %unkgprinted);

sub new {
  my ($class, $dict, $data) = @_;
  my $self = { unknown_entries => 1 };
  bless $self, $class;
  $self->set_dict($dict) if defined($dict);
  $self->unpack($data) if defined($data);
  return $self;
}

# Set the dictionary
sub set_dict {
  my ($self, $dict) = @_;
  $self->{Dict} = $dict;
}

# Functions for accessing data structures
sub code          { $_[0]->{Code};          				}
sub identifier    { $_[0]->{Identifier};    				}
sub authenticator { $_[0]->{Authenticator}; 				}

sub set_code          { $_[0]->{Code} = $_[1];          		}
sub set_identifier    { $_[0]->{Identifier} = $_[1];    		}
sub set_authenticator { $_[0]->{Authenticator} = substr($_[1] 
							. "\x0" x 16, 
							0, 16); 	}

sub vendors      { keys %{$_[0]->{VSAttributes}};			}
sub vsattributes { keys %{$_[0]->{VSAttributes}->{$_[1]}};		}
sub vsattr       { $_[0]->{VSAttributes}->{$_[1]}->{$_[2]};		}
sub set_vsattr   { 
    my ($self, $vendor, $name, $value, $rewrite_flag, $rawValue) = @_;
    $self->{VSAttributes}->{$vendor} = {} unless exists($self->{VSAttributes}->{$vendor});
    my $attr = $self->{VSAttributes}->{$vendor};

    if ($rewrite_flag) {
	my $found = 0;

	if (exists($attr->{$name})) {
	    $found = $#{$attr->{$name}} + 1;
        }

	if ($found == 1) {
	    $attr->{$name}[0] = $value;
	    return;
	}    
    }

    # Check if we should be adding the raw value or not
    if (defined($rawValue)) {
	    push @{$attr->{$name}}, $value, $rawValue;
    } else {
	    push @{$attr->{$name}}, $value;
    }
}

sub unset_vsattr {
    my ($self, $vendor, $name) = @_;

    delete($self->{VSAttributes}->{$name});
}

sub show_unknown_entries { $_[0]->{unknown_entries} = $_[1]; 		}

sub set_attr 
{
    my ($self, $name, $value, $rewrite_flag, $rawValue) = @_;
    my ($push, $pos );

    $push = 1 unless $rewrite_flag;

    if ($rewrite_flag) {
        my $found = 0;
        my @attr = $self->_attributes;

        for (my $i = 0; $i <= $#attr; $i++ ) {
            if ($attr[$i][0] eq $name) {
                $found++;
                $pos = $i;
            }
        }

        if ($found > 1) {
            $push = 1;
        } elsif ($found) {
            $attr[$pos][0] = $name;
            $attr[$pos][1] = $value;
            $attr[$pos][2] = $rawValue;
            $self->_set_attributes( \@attr );
            return;
        } else {
            $push = 1;
        }
    }

    $self->_push_attr( $name, $value, $rawValue ) if $push;
}

sub attr
{
    my ($self, $name ) = @_;
    
    my @attr = $self->_attributes;
    
    for (my $i = $#attr; $i >= 0; $i-- ) {
        return $attr[$i][1] if $attr[$i][0] eq $name;
    }
    return;
}

sub rawattr
{
    my ($self, $name ) = @_;
    
    my @attr = $self->_attributes;
    
    for (my $i = $#attr; $i >= 0; $i-- ) {
	# Check if this is the attr we're after
	if ($attr[$i][0] eq $name) {
		# If it is, return the raw attribute if it exists, else return the nicer dict one
		return defined($attr[$i][2]) ? $attr[$i][2] : $attr[$i][1];
	}
    }
    return;
}

sub attributes {
    my ($self) = @_;
    
    my @attr = $self->_attributes;
    my @attriblist = ();
    for (my $i = $#attr; $i >= 0; $i-- ) {
        push @attriblist, $attr[$i][0];
    }
    return @attriblist;
}

sub unset_attr 
{
    my ($self, $name, $value ) = @_;
    
    my $found;
    my @attr = $self->_attributes;

    for (my $i = 0; $i <= $#attr; $i++ ) {
        if ( $name eq $attr[$i][0] && $value eq $attr[$i][1])
	{
            $found = 1;
	    if ( $#attr == 0 ) {
		# no more attributes left on the stack
		$self->_set_attributes( [ ] );
	    } else {
		splice @attr, $i, 1;
		$self->_set_attributes( \@attr );
	    }
            return 1;
        }
    }
    return 0;
}

# XXX - attr_slot is deprecated - Use attr_slot_* instead
sub attr_slot		{ attr_slot_val($@); }

sub attr_slots { scalar ($_[0]->_attributes); }

sub attr_slot_name
{ 
    my $self = shift;
    my $slot = shift;
    my @stack = $self->_attributes;

    return unless exists $stack[$slot];
    return unless exists $stack[$slot]->[0];
    $stack[$slot]->[0];
}

sub attr_slot_val
{ 
    my $self = shift;
    my $slot = shift;
    my @stack = $self->_attributes;

    return unless exists $stack[$slot];
    return unless exists $stack[$slot]->[0];
    $stack[$slot]->[1];
}

sub unset_attr_slot {
    my ($self, $position ) = @_;

    my @attr = $self->_attributes;

    if ( not $position > $#attr ) {
        splice @attr, $position, 1;
        $self->_set_attributes( \@attr );
        return 1;
    } else {
        return;
    }

}

# 'Attributes' is now array of arrays, so that we can have multiple
# Proxy-State values in the order in which they were added,
# as specified in RFC 2865
sub _attributes     { @{ $_[0]->{Attributes} || [] }; }
sub _set_attributes { $_[0]->{Attributes} = $_[1]; }
sub _push_attr      { push @{ $_[0]->{Attributes} }, [ $_[1], $_[2], $_[3] ]; }

# Decode the password
sub password {
  my ($self, $secret, $attr) = @_;
  my $lastround = $self->authenticator;
  my $pwdin = $self->attr($attr || "User-Password");
  my $pwdout = ""; # avoid possible undef warning
  for (my $i = 0; $i < length($pwdin); $i += 16) {
    $pwdout .= substr($pwdin, $i, 16) ^ Digest::MD5::md5($secret . $lastround);
    $lastround = substr($pwdin, $i, 16);
  }
  $pwdout =~ s/\000*$// if $pwdout;
    substr($pwdout,length($pwdin)) = "" 
	unless length($pwdout) <= length($pwdin);
  return $pwdout;
}

# Encode the password
sub set_password {
  my ($self, $pwdin, $secret, $attribute) = @_;
  $attribute ||= 'User-Password';
  my $lastround = $self->authenticator;
  my $pwdout = ""; # avoid possible undef warning
  $pwdin .= "\000" x (15-(15 + length $pwdin)%16);     # pad to 16n bytes

  for (my $i = 0; $i < length($pwdin); $i += 16) {
    $lastround = substr($pwdin, $i, 16) 
      ^ Digest::MD5::md5($secret . $lastround);
    $pwdout .= $lastround;
  }
  $self->set_attr($attribute => $pwdout, 1);
}

# Set response authenticator in binary packet
sub auth_resp {
  my $new = $_[0];
  substr($new, 4, 16) = Digest::MD5::md5($_[0] . $_[1]);
  return $new;
}

# Verify the authenticator in a packet
sub auth_acct_verify { auth_req_verify(@_, "\x0" x 16); }
sub auth_req_verify
{
    my ($packet, $secret, $prauth) = @_;

    return 1 if Digest::MD5::md5(substr($packet, 0, 4) . $prauth 
				 . substr($packet, 20) . $secret)
	eq substr($packet, 4, 16);
    return;
}

# Utility functions for printing/debugging
sub pdef { defined $_[0] ? $_[0] : "UNDEF"; }
sub pclean {
  my $str = $_[0];
  $str =~ s/([\044-\051\133-\136\140\173-\175])/'\\' . $1/ge;
  $str =~ s/([\000-\037\177-\377])/sprintf('\x{%x}', ord($1))/ge;
  return $str;
}

sub dump {
    print str_dump(@_);
}

sub str_dump {
  my $self = shift;
  my $ret = '';
  $ret .= "*** DUMP OF RADIUS PACKET ($self)\n";
  $ret .= "Code:       ". pdef($self->{Code}). "\n";
  $ret .= "Identifier: ". pdef($self->{Identifier}). "\n";
  $ret .= "Authentic:  ". pclean(pdef($self->{Authenticator})). "\n";
  $ret .= "Attributes:\n";

  for (my $i = 0; $i < $self->attr_slots; ++$i)
  {
      $ret .= sprintf("  %-20s %s\n", $self->attr_slot_name($i) . ":" , 
		    pclean(pdef($self->attr_slot_val($i))));
  }

  foreach my $vendor ($self->vendors) {
    $ret .= "VSA for vendor $vendor\n";
    foreach my $attr ($self->vsattributes($vendor)) {
      $ret .= sprintf("    %-20s %s\n", $attr . ":" ,
		      pclean(join("|", @{$self->vsattr($vendor, $attr)})));
    }
  }
  $ret .= "*** END DUMP\n";
  return $ret;
}

sub pack {
  my $self = shift;
  my $hdrlen = 1 + 1 + 2 + 16;    # Size of packet header
  my $p_hdr  = "C C n a16 a*";    # Pack template for header
  my $p_attr = "C C a*";          # Pack template for attribute
  my $p_vsa  = "C C N C C a*";	  # VSA

  # XXX - The spec says that a
  # 'Vendor-Type' must be included
  # but there are no documented definitions
  # for this! We'll simply skip this value

  my $p_vsa_3com  = "C C N N a*";    

  my %codes  = $self->{Dict}->packet_numbers();
  my $attstr = "";                # To hold attribute structure
  # Define a hash of subroutine references to pack the various data types
  my %packer = (
		"octets" => sub { return $_[0]; },
		"string" => sub { return $_[0]; },
		"ipv6addr" => sub { return $_[0]; },
		"date" => sub { return $_[0]; },
		"ifid" => sub { return $_[0]; },
		"integer" => sub {
		    return pack "N",
		    (
		     defined $self->{Dict}->attr_has_val($_[1]) &&
		     defined $self->{Dict}->val_num(@_[1, 0])
		     ) 
			? $self->{Dict}->val_num(@_[1, 0]) 
			: $_[0];
		},
		"ipaddr" => sub {
		    return inet_aton($_[0]);
		},
		"time" => sub {
		    return pack "N", $_[0];
		},
		"date" => sub {
		    return pack "N", $_[0];
		},
		"tagged-string" => sub { 
		    return $_[0]; 
		},
		"tagged-integer" => sub {
		    return $_[0];
		},
		"tagged-ipaddr" => sub {
		    my ($tag,$val)=unpack "C a*",$_[0];
		    return pack "C N" , $tag , inet_aton($val);
		});

  my %vsapacker = (
		   "octets" => sub { return $_[0]; },
		   "string" => sub { return $_[0]; },
		   "ipv6addr" => sub { return $_[0]; },
		   "date" => sub { return $_[0]; },
		   "ifid" => sub { return $_[0]; },
		   "integer" => sub {
		       my $vid = $self->{Dict}->vendor_num($_[2]) || $_[2];
		       return pack "N", 
		       (defined $self->{Dict}->vsattr_has_val($vid, $_[1])
			&& defined $self->{Dict}->vsaval_num($vid, @_[1, 0]) 
			) ?  $self->{Dict}->vsaval_num($vid, @_[1, 0]) : $_[0];
		   },
		   "ipaddr" => sub {
		       return inet_aton($_[0]);
		   },
		   "time" => sub {
		       return pack "N", $_[0];
		   },
		   "date" => sub {
		       return pack "N", $_[0];
		   },
		   "tagged-string" => sub { 
		       return $_[0]; 
		   },
		   "tagged-integer" => sub {
		       return $_[0];
		   },
		   "tagged-ipaddr" => sub {
		       my ($tag,$val)=unpack "C a*",$_[0];
		       return pack "C a*" , $tag , inet_aton($val);
		   });
    
  # Pack the attributes
  for (my $i = 0; $i < $self->attr_slots; ++$i)
  {
      my $attr = $self->attr_slot_name($i);
      if (! defined $self->{Dict}->attr_num($attr))
      {
	  carp("Unknown RADIUS tuple $attr => " . $self->attr_slot_val($i) 
	       . "\n")
	      if ($self->{unknown_entries});
	  next;
      }
      
      next unless ref($packer{$self->{Dict}->attr_type($attr)}) eq 'CODE';

      my $val = &{$packer{$self->{Dict}->attr_type($attr)}}
      ($self->attr_slot_val($i), $self->{Dict} ->attr_num($attr));

      $attstr .= pack $p_attr, $self->{Dict}->attr_num($attr),
      length($val)+2, $val;
  }

  # Pack the Vendor-Specific Attributes

  foreach my $vendor ($self->vendors) 
  {
      my $vid = $self->{Dict}->vendor_num($vendor) || $vendor;
      foreach my $attr ($self->vsattributes($vendor)) {
	next unless ref($vsapacker{$self->{Dict}
				   ->vsattr_type($vid, $attr)}) 
            eq 'CODE';
      foreach my $datum (@{$self->vsattr($vendor, $attr)}) {
        my $vval = &{$vsapacker{$self->{'Dict'}->vsattr_type($vid, $attr)}}
        ($datum, $self->{'Dict'}->vsattr_num($vid, $attr), $vendor);

        if ($vid == 429) {

      		# As pointed out by Quan Choi,
      		# we need special code to handle the
      		# 3Com case - See RFC-2882, sec 2.3.1

	    $attstr .= pack $p_vsa_3com, 26, 
	    length($vval) + 10, $vid,
	    $self->{'Dict'}->vsattr_num($vid, $attr),
	    $vval;
        } 
	else 
	{
	    $attstr .= pack $p_vsa, 26, length($vval) + 8, $vid,
	    $self->{'Dict'}->vsattr_num($vid, $attr),
	    length($vval) + 2, $vval;
        }
      }
    }
  }

  # Prepend the header and return the complete binary packet
  return pack $p_hdr, $codes{$self->code}, $self->identifier,
  length($attstr) + $hdrlen, $self->authenticator,
  $attstr;
}

sub unpack {
  my ($self, $data) = @_;
  my $dict = $self->{Dict};
  my $p_hdr  = "C C n a16 a*";    # Pack template for header
  my $p_attr = "C C a*";          # Pack template for attribute
  my $p_taggedattr = "C C C a*";  # Pack template for tagged-attribute
  my %rcodes = $dict->packet_names();

  # Decode the header
  my ($code, $id, $len, $auth, $attrdat) = unpack $p_hdr, $data;

  # Generate a skeleton data structure to be filled in
  $self->set_code($rcodes{$code});
  $self->set_identifier($id);
  $self->set_authenticator($auth);

  # Functions for the various data types
  my %unpacker = 
	(
	 "string" => sub {
	     return $_[0];
	 },
	 "ipv6addr" => sub { return $_[0]; },
	 "date" => sub { return $_[0]; },
	 "ifid" => sub { return $_[0]; },
	 "octets" => sub {
	     return $_[0];
	 },
	 "integer" => sub {
	     my $num=unpack("N", $_[0]);
	     return ( defined $dict->val_has_name($_[1]) &&
		      defined $dict->val_name($_[1],$num) ) ?
		      ($dict->val_name($_[1],$num),undef,$num) : $num ;
	 },
	 "ipaddr" => sub {
	     return length($_[0]) == 4 ? inet_ntoa($_[0]) : $_[0];
	 },
	 "address" => sub {
	     return length($_[0]) == 4 ? inet_ntoa($_[0]) : $_[0];
	 },
	 "time" => sub {
	     return unpack "N", $_[0];
	 },
	 "date" => sub {
	     return unpack "N", $_[0];
	 },
	 "tagged-string" => sub { 
	     my ($tag,$val) = unpack "a a*", $_[0]; 
	     return $val, $tag;
	 },
	 "tagged-integer" => sub {
	     my ($tag,$num) = unpack "a a*", $_[0];
	     return ( defined $dict->val_has_name($_[1]) &&
		      defined $dict->val_name($_[1],$num) ) ?
		      $dict->val_name($_[1],$num) : $num
		      ,$tag ;
	 },
	 "tagged-ipaddr" => sub {
	     my ( $tag, $num ) = unpack "a a*", $_[0];
	     return inet_ntoa($num), $tag;
	 });

  my %vsaunpacker = 
      ( 
	"octets" => sub {
	    return $_[0];
	},
	"string" => sub {
	    return $_[0];
	},
	"ipv6addr" => sub { return $_[0]; },
	"date" => sub { return $_[0]; },
	"ifid" => sub { return $_[0]; },
	"integer" => sub {
	    my $num=unpack("N", $_[0]);
	    return ( $dict->vsaval_has_name($_[2], $_[1]) 
		     && $dict->vsaval_name($_[2], $_[1],$num) )  
		? ( $dict->vsaval_name($_[2], $_[1], $num ), undef, $num)
		: $num;
	},
	"ipaddr" => sub {
	    return length($_[0]) == 4 ? inet_ntoa($_[0]) : $_[0];
	},
	"address" => sub {
	    return length($_[0]) == 4 ? inet_ntoa($_[0]) : $_[0];
	},
	"time" => sub {
	    return unpack "N", $_[0];
	},
	"date" => sub {
	    return unpack "N", $_[0];
	},
	"tagged-string" => sub { 
	    my ($tag,$val) = unpack "a a*", $_[0]; 
	    return $val, $tag;
	},
	"tagged-integer" => sub {
	    my ( $tag, $num ) = unpack "a a*", $_[0];
	    return  ($dict->vsaval_has_name($_[2], $_[1]) 
		     && $dict->vsaval_name($_[2], $_[1],$num) 
		     )?$dict->vsaval_name($_[2], $_[1],$num):$num 
		     , $tag ;
	    
	},
	"tagged-ipaddr" => sub {
	    my ( $tag, $num ) = unpack "a a*", $_[0];
	    return inet_ntoa($num), $tag;
	});
  
  # Unpack the attributes
  while (length($attrdat)) 
  {
      my $length = unpack "x C", $attrdat;
      my ($type, $value) = unpack "C x a${\($length-2)}", $attrdat;
      if ($type == $VSA) {    # Vendor-Specific Attribute
	  my ($vid) = unpack "N", $value;
	  substr ($value, 0, 4) = "";
	  
	  while (length($value))
	  {
	      my ($vtype, $vlength) = unpack "C C", $value;
	      
	      # XXX - How do we calculate the length
	      # of the VSA? It's not defined!
	      
	      # XXX - 3COM seems to do things a bit differently. 
	      # The IF below takes care of that. This was contributed by 
	      # Ian Smith. Check the file CHANGES on this distribution for 
	      # more information.

	      my $vvalue;
	      if ($vid == 429)
	      {
		  ($vtype) = unpack "N", $value;
		  $vvalue = unpack "xxxx a${\($length-10)}", $value;
	      }
	      else
	      {
		  $vvalue = unpack "x x a${\($vlength-2)}", $value;
	      }

	      if ((not defined $dict->vsattr_numtype($vid, $vtype)) or 
		  (ref $vsaunpacker{$dict->vsattr_numtype($vid, $vtype)} 
		   ne 'CODE')) 
	      {
		  my $whicherr 
		      = (defined $dict->vsattr_numtype($vid, $vtype)) ?
		      "Garbled":"Unknown";
		  warn "$whicherr vendor attribute $vid/$vtype for unpack()\n"
		      unless $unkvprinted{"$vid/$vtype"};
		  $unkvprinted{"$vid/$vtype"} = 1;
		  substr($value, 0, $vlength) = ""; # Skip this section
		  next;
	      }
	      my ($val, $tag, $rawValue) = 
		  &{$vsaunpacker{$dict->vsattr_numtype($vid, $vtype)}}($vvalue,
								       $vtype,
								       $vid);
	      if ( defined $tag ) 
	      {
		  $val = "-emtpy-" unless defined $val;
		  $self->set_taggedvsattr($vid,
					  $dict->vsattr_name($vid, $vtype),
					  $val, 
					  $tag);
	      }
	      else 
	      {
		  $self->set_vsattr($vid, $dict->vsattr_name($vid, $vtype), 
				    $val, undef, $rawValue);
	      }
	      substr($value, 0, $vlength) = "";
	  }
      }
      else 
      {            # Normal attribute
	  if ((not defined $dict->attr_numtype($type)) or
	      (ref ($unpacker{$dict->attr_numtype($type)}) ne 'CODE')) 
	  {
	      my $whicherr = (defined $dict->attr_numtype($type)) ?
		  "Garbled":"Unknown";
	      warn "$whicherr general attribute $type for unpack()\n"
		  unless $unkgprinted{$type};
	      $unkgprinted{$type} = 1;
	      substr($attrdat, 0, $length) = ""; # Skip this section
	      next;
	  }
	  my ($val,$tag,$rawValue) = &{$unpacker{$dict->attr_numtype($type)}}($value, 
								    $type);
	  if ( defined $tag ) {
	      if ( ! defined $val ) { $val = "-emtpy-" };
	      $self->set_taggedattr($dict->attr_name($type), $val , $tag);
	  }
	  else {
	      $self->set_attr($dict->attr_name($type), $val, undef, $rawValue);
	  }
      }
      substr($attrdat, 0, $length) = ""; # Skip this section
  }
}

1;
