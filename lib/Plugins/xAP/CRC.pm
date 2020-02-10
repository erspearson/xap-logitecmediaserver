package Plugins::xAP::CRC;
use strict;

###############################################################
# CRC Routines - adapted from Digest::CRC by Oliver Maul      #
#                                                             #
# CRC algorithm code taken from:                              #
# "A painless guide to crc error detection algorithms"        #
# Ross Williams http://www.ross.net/crc                       #
#                                                             #
###############################################################


sub _reflect {
  my ($in, $width) = @_;
  my $out = 0;
  for(my $i=1; $i < ($width+1); $i++) {
    $out |= 1 << ($width-$i) if ($in & 1);
    $in=$in>>1;
  }
  $out;
}

sub _tabinit {
  my ($width,$poly_in,$ref) = @_;
  my @crctab;
  my $poly = $poly_in;

  if ($ref) {
    $poly = _reflect($poly,$width);
  }

  for (my $i=0; $i<256; $i++) {
    my $r = $i<<($width-8);
    $r = $i if $ref;
    for (my $j=0; $j<8; $j++) {
      if ($ref) {
	$r = ($r>>1)^($r&1&&$poly)
      } else {
	if ($r&(1<<($width-1))) {
	  $r = ($r<<1)^$poly
	} else {
	  $r = ($r<<1)
	}
      }
    }
    push @crctab, $r&2**$width-1;
  }
  \@crctab;
}

sub _crc {
  my ($message,$width,$init,$xorout,$refin,$refout,$tab) = @_;
  my $crc = $init;
  $crc = _reflect($crc,$width) if $refin;
  my $pos = -length $message;
  my $mask = 2**$width-1;
  while ($pos) {
    if ($refin) {
      $crc = ($crc>>8)^$tab->[($crc^ord(substr($message, $pos++, 1)))&0xff]
    } else {
      $crc = (($crc<<8))^$tab->[(($crc>>($width-8))^ord(substr $message,$pos++,1))&0xff]
    }
  }

  if ($refout^$refin) {
    $crc = _reflect($crc,$width);
  }

  $crc = $crc ^ $xorout;
  $crc & $mask;
}

sub crc {
  my ($message,$width,$init,$xorout,$refout,$poly,$refin) = @_;
  _crc($message,$width,$init,$xorout,$refin,$refout,_tabinit($width,$poly,$refin));
}

# CRC8
# poly: 07, width: 8, init: 00, revin: no, revout: no, xorout: no

sub crc8 { crc($_[0],8,0,0,0,0x07,0) }

# CRC-CCITT standard
# poly: 1021, width: 16, init: ffff, refin: no, refout: no, xorout: no

sub crcccitt { crc($_[0],16,0xffff,0,0,0x1021,0) }

# CRC16
# poly: 8005, width: 16, init: 0000, revin: yes, revout: yes, xorout: no

sub crc16 { crc($_[0],16,0,0,1,0x8005,1) }

# CRC32
# poly: 04C11DB7, width: 32, init: FFFFFFFF, revin: yes, revout: yes,
# xorout: FFFFFFFF

sub crc32 { crc($_[0],32,0xffffffff,0xffffffff,1,0x04C11DB7,1) }




1;