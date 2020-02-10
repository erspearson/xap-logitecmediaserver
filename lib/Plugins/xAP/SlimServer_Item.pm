package Plugins::xAP::SlimServer_Item;
use strict;

=begin comment
####################################################################################

File:
	Slim_Item.pm

Description:
	xAP support for Audio and Slimserver schema
	
Author:
	Edward Pearson
	based on ZoneMinder xAP interface code by Gregg Liming gregg@limings.net
	with special thanks to Bruce Winter - MisterHouse

License:
	This free software is licensed under the terms of the GNU public license.


####################################################################################
=cut

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.xap.message',
	'defaultLevel' => 'ERROR',
	'description'  => 'xAP plugin message level',
});

require Plugins::xAP::Comm;
require Plugins::xAP::xAP_Item;

my $SLIM;

#Initialize class
sub new 
{
   my ($class, $instance, $xap_sliMP3_legacy_schema) = @_;
   my $self={};
   bless $self, $class;

   $SLIM = $xap_sliMP3_legacy_schema ? 'slimp3' : 'Slim';

   $$self{m_xap} = new Plugins::xAP::xAP_Item($instance, '', '*');
   $$self{m_xap}->is_local(1); # SlimServer item is always local
   $self->_initialize();

   $$self{m_xap}->tie_items($self);
	
   return $self;
}

sub _initialize
{
   my ($self) = @_;
   $$self{m_registered_objects} = ();
}

sub set_now 
{
   my ($self, $p_state, $p_setby) = @_;
   my $state = $p_state;
   # don't do anything if setby an inherited object
   if (($p_setby != $self)) {
        if ($p_setby eq $$self{m_xap} ) {
            my $class = lc $$self{m_xap}{received}{'xap-header'}{class};
            if (($class eq 'slimp3.server') || ($class eq 'slim.server')) {
                # handle server command
                $state = $self->rcvServerCmd();
            }
        }
    } else {
        Slim::Utils::Misc::msg("xAP: Unable to process state: $state\n");
    }
    return;
}

sub setcallback {
        my ($self, $event, $function) = @_;

        if (defined($function) && ref($function) eq 'CODE') {
                $self->{_EVENTCB}{$event} = $function;
        }
}

sub eventcallback {
        my ($self, $event, %data) = @_;

        my $callback;

        return if (!$event);

        if (defined($self->{_EVENTCB}{$event})) {
                $callback = $self->{_EVENTCB}{$event};
        } elsif (defined($self->{_EVENTCB}{DEFAULT})) {
                $callback = $self->{_EVENTCB}{DEFAULT};
        } else {
                return;
        }

        return &{$callback}($self, %data);
}

sub rcvServerCmd
{
   my ($self) = @_;
   for my $section_name (keys %{$$self{m_xap}{received}} ) {      
        next unless ($section_name =~ /^(server\.command|player\.query|pref\.query|pref\.set)$/i);
        my %data = ();
        $data{target} = $$self{m_xap}{received}{'xap-header'}{source};
        my $type = lc $1;
        for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
        my $value = $$self{m_xap}{received}{$section_name}{$field_name};
         
        if ((lc $field_name eq 'command') && ($type eq 'server.command')) {
            $data{$field_name} = $value if $value =~ /^(rescan|rescan playlists|wipecache)$/i;
            $data{type} = $type;
        }
        elsif (((lc $field_name eq 'command') || (lc $field_name eq 'playerindex')) && ($type eq 'player.query')){
            $data{$field_name} = $value;
            $data{type} = $type;
        }
        elsif ((lc $field_name eq 'pref') && ($type eq 'pref.query')) {
            $data{$field_name} = $value;
            $data{type} = $type;
        }
        elsif (((lc $field_name eq 'pref') || (lc $field_name eq 'value')) && ($type eq 'pref.set')){
            $data{$field_name} = $value;
            $data{type} = $type;
        }
      }
      $data{source} = $$self{m_xap}{received}{'xap-header'}{source};
      $self->eventcallback('serverCmd', %data) if $data{type};
    }
    return 'serverCmd';
}

sub sendPlayerQueryResponse
{
   my ($self, %data) = @_;
   my (@xap, $msg_block);
   $msg_block->{Command} = $data{command};
   $msg_block->{Status} = $data{status};
   push @xap, "Player.Notification", $msg_block;
   $$self{m_xap}->send_message("$SLIM\.Server", \@xap, $data{target});
}

sub sendPrefResponse
{
   my ($self, %data) = @_;
   my (@xap, $msg_block);
   $msg_block->{Pref} = $data{pref};
   $msg_block->{Status} = $data{status};
   push @xap, "Pref.Notification", $msg_block;
   $$self{m_xap}->send_message("$SLIM\.Server", \@xap, $data{target});
}



1;