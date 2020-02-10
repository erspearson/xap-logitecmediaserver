package Plugins::xAP::UID;

use strict;
use Plugins::xAP::CRC;

my $legacy_uid_picture = "NNDDDDSS"; # xAP v1.2 UID format
my $default_uid_picture = "NN.DDDDDDDD:SSSS"; # typical xAP v1.3 UID format

sub new
{
    my ($class, $uid) = @_;
    $uid = "FF123400" unless $uid;
    my $self = {};
    bless $self, $class;
    $$self{uid} = $uid;
    $self->_initialise();
    return $self;
}

sub new_v12
{
    return new($_[0], $legacy_uid_picture);
}

sub new_v13
{
    return new($_[0], $default_uid_picture);
}

sub isValid {
    my $self = shift;
    return $$self{valid};
}

sub getNet {
    my $self = shift;
    return $$self{net};
}

sub getDev {
    my $self = shift;
    return $$self{dev};
}

sub getSub {
    my $self = shift;
    return $$self{sub};
}

sub getUID {
    my $self = shift;
    return $$self{uid};
}

sub getVersion {
    my $self = shift;
    return $$self{v};
}

sub setNet {
    my ($self, $val) = @_;
    my $fmt = "%0" . length($$self{net}) . "X";
    $$self{net} = sprintf($fmt, hex $val);
    $self->_setUID();
}

sub setDev {
    my ($self, $val) = @_;
    my $fmt = "%0" . length($$self{dev}) . "X";
    $$self{dev} = sprintf($fmt, hex $val);
    $self->_setUID();
}

sub setSub {
    my ($self, $val) = @_;
    my $fmt = "%0" . length($$self{sub}) . "X";
    $$self{sub} = sprintf($fmt, hex $val);
    $self->_setUID();
}

sub generateDev {
    my ($self, $source) = @_;
    return unless $self->isValid;
    my $s1 = ord('A') + int(rand 26); # salt
    my $s2 = ord('A') + int(rand 26); # salt
    my $seed = chr($s1) . chr($s2) . $source;
    my $len = length($$self{dev});
    my $fmt = "%0" . $len . "X";
    my $crc = sprintf($fmt, Plugins::xAP::CRC::crc32($seed));
    $$self{dev} = "0" . substr($crc, 0, $len-1);
    $self->_setUID();
}

sub _initialise
{
    my $self = shift;

    if ($$self{uid} =~ /^((?:[0-9A-F][0-9A-F]){1,})\.((?:[0-9A-F][0-9A-F]){2,}):((?:[0-9A-F][0-9A-F]){1,})$/)
    {
        # v1.3 UID
        $$self{v} = "13";
        $$self{net} = $1;
        $$self{dev} = $2;
        $$self{sub} = $3;        
        $$self{valid} = 1;
    }
    elsif ($$self{uid} =~ /^([0-9A-F]{2})([0-9A-F]{4})([0-9A-F]{2})$/)
    {
        # v1.2 UID
        $$self{v} = "12";
        $$self{net} = $1;
        $$self{dev} = $2;
        $$self{sub} = $3;        
        $$self{valid} = 1;
    }
    elsif ($$self{uid} =~ /^((?:NN){1,})\.((?:DD){2,}):((?:SS){1,})$/)
    {
        # v1.3 UID picture
        $$self{v} = "13";
        $$self{net} = "F" x length $1;
        $$self{dev} = "0" x length $2;
        $$self{sub} = "0" x length $3;
        $$self{valid} = 1;
        $self->_setUID;
    }
    elsif ($$self{uid} =~ /^(N{2})(D{4})(S{2})$/)
    {
        # v1.2 UID picture
        $$self{v} = "12";
        $$self{net} = "F" x length $1;
        $$self{dev} = "0" x length $2;
        $$self{sub} = "0" x length $3;
        $$self{valid} = 1;
        $self->_setUID;
    }
    else
    {
        $$self{v} = "";
        $$self{net} = "";
        $$self{dev} = "";
        $$self{sub} = "";        
        $$self{valid} = 0;
    }
}

sub _setUID
{
    my $self = shift;
    if($self->isValid())
    {
        if($$self{v} eq "12") { $$self{uid} = $$self{net} . $$self{dev} . $$self{sub}; }
        if($$self{v} eq "13") { $$self{uid} = $$self{net} . "." . $$self{dev} . ":" . $$self{sub}; }
    }
    else
    {
        $$self{uid} = "";
    }
}

sub test
{
    my $u1 = Plugins::xAP::UID->new("FF123400");
    my $u2 = Plugins::xAP::UID->new("FF.1234:00");
    my $u3 = Plugins::xAP::UID->new("FFFF.12345678:0000");
    
    my $du1 = Plugins::xAP::UID->new_v12();
    my $du2 = Plugins::xAP::UID->new_v13();
    
    my $pu1 = Plugins::xAP::UID->new("NNDDDDSS");
    my $pu2 = Plugins::xAP::UID->new("NN.DDDD:SS");
    my $pu3 = Plugins::xAP::UID->new("NNNN.DDDDDDDD:SSSS");
    
    $pu1->generateDev("ersp.device.foo");
    $pu2->generateDev("ersp.device.foo");
    $pu3->generateDev("ersp.device.foo");
    
    my $nu1 = Plugins::xAP::UID->new("FF12340");
    my $nu2 = Plugins::xAP::UID->new("FF.12345:00");
    my $nu3 = Plugins::xAP::UID->new("FFFF.123456780000");
}
1;