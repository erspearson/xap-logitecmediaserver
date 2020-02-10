package Plugins::xAP::Slim_Item;
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
   my ($class, $p_source_name, $p_subuid, $xap_sliMP3_legacy_schema) = @_;
   my $self={};
   bless $self, $class;

   $SLIM = $xap_sliMP3_legacy_schema ? 'slimp3' : 'Slim';

   $$self{m_xap} = new Plugins::xAP::xAP_Item($p_source_name, $p_subuid, '*');
   $$self{m_xap}->is_local(1); # Slim item is always local
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
         
         if ($class =~ /^(xap-osd|slimp3|slim|squeeze|message)\.display$/) {
            # handle display command
            $state = $self->rcvDisplayCmd();
            
         } elsif ($class =~ /^(xap-audio|slimp3|slim)\.transport$/) {
            # handle transport command
            $state = $self->rcvTransportCmd();
            
         } elsif ($class eq 'xap-audio.audio') {
            # handle audio command
            $state = $self->rcvAudioCmd();
            
         } elsif ($class eq 'xap-audio.schedule') {
            # handle schedule command
            $state = $self->rcvScheduleCmd();
                        
         } elsif ($class eq 'xap-audio.query') {
            # handle audio query
            $state = $self->rcvAudioQuery();
            
         } elsif ($class eq 'xap-audio.playlist') {
            # handle playlist commands
            $state = $self->rcvPlaylistCmd();
            
         } elsif (($class eq 'slimp3.server') || ($class eq 'slim.server')) {
            # handle player preference commands
            $state = $self->rcvPrefCmd();
            
         } elsif (($class eq 'slimp3.button') || ($class eq 'slim.button')) {
            # handle player button command
            $state = $self->rcvControlCmd();
            
         } elsif (($class eq 'slimp3.ir') || ($class eq 'slim.ir')) {
            # handle player ir command
            $state = $self->rcvControlCmd();
         }
      } else {
         $log->error("xAP: Unable to process state: $state\n");
      }
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

sub idx
{
   $_ = shift;
   /\.(\d+)$/ ? $1 : $_;
}

sub rcvDisplayCmd
{
   my ($self) = @_;
   for my $section_name (sort { idx($a) <=> idx($b) } keys %{$$self{m_xap}{received}} ) {      
      my %data = ();
      $data{target} = $$self{m_xap}{received}{'xap-header'}{source};
      if(lc $section_name eq 'display.query')
      {
         $data{type} = 'display.query';
         $self->eventcallback('displayCmd', %data);
      }
      elsif($section_name =~ /^display\.(text|slim|slimp3|squeeze)(\.\d+)?/i) # display.* or indexed set
      {
         $data{type} = 'display.cmd';
         for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
            my $value = $$self{m_xap}{received}{$section_name}{$field_name};
            my $field = lc $field_name;
            $data{$field}       = $value if ($field =~ /^line[123456789]$/ );
            $value = lc $value;
            ($data{$field} = $value) =~ s/centre/center/ if ($field =~ /^align[12]$/) and ($value =~ /^(left|centre|center)$/i );
            $data{'queue_type'} = $value if ($field eq 'type') and ($value =~ /^(queue|immediate|permanent|delete)$/i );
            $data{'brightness'} = $value if ($field eq 'brightness') and ($value =~ /^(powerOn|powerOff|idle|off|dimmest|dim|bright|brightest|0|1|2|3|4)$/i );
            $data{'size'}       = $value if ($field eq 'size') and ($value =~ /^(small|medium|large|s|m|l)$/i );
            $data{'priority'}   = $value if ($field eq 'priority') and ($value =~ /^\d+$/ );
            $data{'ttl'}        = $value if ($field eq 'ttl') and ($value =~ /^\d+$/ );
            $data{'duration'}   = $value if ($field eq 'duration') and ($value =~ /^\d+(\.\d+)?$/ );
            $data{'screen'}     = $value if ($field eq 'screen') and ($value =~ /^(1|2)$/ );
            $data{'tag'}        = $value if ($field eq 'tag');
         }
         $self->eventcallback('displayCmd', %data);
      }
   }
   return 'displayCmd';
}

sub rcvTransportCmd
{
   my ($self) = @_;
   my %data = ();
   for my $section_name (keys %{$$self{m_xap}{received}} ) {      
      if($section_name =~ /^(audio\.transport|audio\.seek)$/i)
      {
         for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
            my $value = $$self{m_xap}{received}{$section_name}{$field_name};
            
            if (lc $field_name eq 'command') {
               $data{command} = lc $value;
               $data{type} = 'transport';
            }
            elsif (lc $field_name eq 'param') { # on or off (used by pause, play and stop)
               $data{param} = lc $value;
               $data{type} = 'transport';
            }
            elsif (lc $field_name eq 'seek') {
               $data{seek} = $value;
               $data{type} = 'transport.seek';
            }
         }
         $data{source} = $$self{m_xap}{received}{'xap-header'}{source};
         $self->eventcallback('transportCmd', %data) if defined $data{type};
      }
      elsif($section_name =~ /^(slimp3\.transport|slim\.transport)$/i)
      {
         for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
            my $value = $$self{m_xap}{received}{$section_name}{$field_name};
            
            if (lc $field_name eq 'command') {
               $data{command} = lc $value;
               $data{type} = 'power';
            }
         }
         $data{source} = $$self{m_xap}{received}{'xap-header'}{source};
         $self->eventcallback('transportCmd', %data) if defined $data{type};
      }
   }
   return 'transportCmd';
}

sub rcvAudioCmd
{
   my ($self) = @_;
   my (%data, %data2);
   for my $section_name (keys %{$$self{m_xap}{received}} ) {      
      if($section_name =~ /^(audio\.mute|audio\.mixer)$/i)
      {
         for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
            my $value = $$self{m_xap}{received}{$section_name}{$field_name};
            
            if (lc $field_name eq 'mute') {
               $data{param} = lc $value;
               $data{type} = 'mute';
            }
            elsif($field_name =~ /^(volume|balance|bass|treble)$/i)
            {
               $data2{lc $field_name} = lc $value;
               $data{param} = \%data2;
               $data{type} = 'mixer';
            }
          }
      }
   }
   $self->eventcallback('audioCmd', %data) if defined $data{type};
   return 'audioCmd';
}

sub rcvScheduleCmd
{
   my ($self) = @_;
   my (%data, %data2);
   for my $section_name (keys %{$$self{m_xap}{received}} ) {      
      if($section_name =~ /^schedule\.sleep$/)
      {
         for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
            my $value = $$self{m_xap}{received}{$section_name}{$field_name};
            
            if (lc $field_name eq 'sleep') {
               $data{param} = lc $value;
               $data{type} = 'sleep';
            }
         }
      }
      elsif($section_name =~ /^schedule\.alarm$/)
      {
         for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
            my $value = $$self{m_xap}{received}{$section_name}{$field_name};
            
            if ((lc $field_name eq 'command') && ($value =~ /^(enableall|disableall)$/i)) {
               $data{command} = lc $value;
               $data{type} = 'alarm';
            }
         }
      }      
   }
   $self->eventcallback('scheduleCmd', %data) if defined $data{type};
   return 'scheduleCmd';
}

sub rcvAudioQuery
{
   my ($self) = @_;
      
   for my $section_name (keys %{$$self{m_xap}{received}} ) {      
      if($section_name =~ /^(audio|track|playlist)\.query$/i)
      {
         my $queryType = lc $1;
         
         my %data;
         $data{target} = $$self{m_xap}{received}{'xap-header'}{source};
         
         for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
            my $value = $$self{m_xap}{received}{$section_name}{$field_name};
            
            if(lc $field_name eq 'query')
            {
               if(($queryType eq 'audio') && ($value =~ /^(mode|sleep|power|volume|balance|bass|treble)$/i))
               {
                  $data{type} = $queryType;
                  $data{subtype} = lc $value;
               }
               elsif(($queryType eq 'track') && ($value =~ /^(time|genre|artist|album|title|duration|path)$/i))
               {
                  $data{type} = $queryType;
                  $data{subtype} = lc $value;
               }
               elsif(($queryType eq 'playlist') && ($value =~ /^(index|genre|artist|album|title|duration|path|tracks|shuffle|repeat)$/i))
               {
                  $data{type} = $queryType;
                  $data{subtype} = lc $value;
               }
            }
            elsif(lc $field_name eq 'index')
            {
                  $data{index} = $value;
            }
         }
         $self->eventcallback('audioQuery', %data) if defined $data{type};
      }
   }
   return 'audioQuery';
}

sub rcvPlaylistCmd
{
   my ($self) = @_;
      
   for my $section_name (keys %{$$self{m_xap}{received}} ) {      
      if($section_name =~ /^playlist\.(track|move|edit|album|shuffle|repeat)$/i)
      {
         my $queryType = lc $1;
         
         my %data;
         $data{target} = $$self{m_xap}{received}{'xap-header'}{source};
         
         for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
            my $value = lc $$self{m_xap}{received}{$section_name}{$field_name};
            
            if(($queryType eq 'track') && ($field_name =~ /^(command|track)$/i))
            {
               $data{type} = $queryType;
               if($field_name eq 'command') {
                  $data{$field_name} = $value if ($value =~ /^(play|append|delete|index)$/i);
               } else {
                  $data{$field_name} = $value
               }
            }
            elsif(($queryType eq 'move') && ($field_name =~ /^(from|to)$/i))
            {
               $data{type} = $queryType;
               $data{$field_name} = $value;
            }
            elsif(($queryType eq 'edit') && ($field_name =~ /^(edit|playlist)$/i))
            {
               $data{type} = $queryType;
               if($field_name eq 'edit') {
                  $data{$field_name} = $value if ($value =~ /^(load|add|clear)$/i);
               } else {
                  $data{$field_name} = $value
               }
            }
            elsif(($queryType eq 'album') && ($field_name =~ /^(command|genre|artist|album)$/i))
            {
               $data{type} = $queryType;
               if($field_name eq 'command') {
                  $data{$field_name} = $value if ($value =~ /^(load|append)$/i);
               } else {
                  $data{$field_name} = $value
               }
            }
            elsif(($queryType eq 'repeat') && ($field_name =~ /^(repeat)$/i) && ($value =~ /^(stop|track|playlist)$/i))
            {
               $data{type} = $queryType;
               $data{$field_name} = $value;
            }
            elsif(($queryType eq 'shuffle') && ($field_name =~ /^(shuffle)$/i) && ($value =~ /^(on|off)$/i))
            {
               $data{type} = $queryType;
               $data{$field_name} = $value;
            }
         }
         $self->eventcallback('playlistCmd', %data) if defined $data{type};
      }
   }
   return 'playlistCmd';
}

sub rcvPrefCmd
{
   my ($self) = @_;
   for my $section_name (keys %{$$self{m_xap}{received}} ) {      
      next unless ($section_name =~ /^(playerpref\.query|playerpref\.set)$/i);
      my %data = ();
      $data{target} = $$self{m_xap}{received}{'xap-header'}{source};
      for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
         my $value = $$self{m_xap}{received}{$section_name}{$field_name};
         if (lc $field_name eq 'pref') {
            $data{pref} = $value;
         }
         elsif (lc $field_name eq 'value') {
            $data{value} = $value;
         }
      }
      $data{type} = lc $section_name;
      $data{source} = $$self{m_xap}{received}{'xap-header'}{source};
      $self->eventcallback('prefCmd', %data);
   }
   return 'prefCmd';
}

sub rcvControlCmd
{
   my ($self) = @_;
   for my $section_name (keys %{$$self{m_xap}{received}} ) {      
      next unless ($section_name =~ /^(button\.command|ir\.command)$/i);
      my %data = ();
      for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
         my $value = $$self{m_xap}{received}{$section_name}{$field_name};
         if (lc $field_name eq 'button') {
            $data{button} = lc $value;
         } elsif (lc $field_name eq 'code') {
            $data{code} = lc $value;
         }
      }
      $data{type} = lc $section_name;
      $data{source} = $$self{m_xap}{received}{'xap-header'}{source};
      $self->eventcallback('controlCmd', %data);
   }
   return 'prefCmd';
}

sub sendQueryResponse
{
   my ($self, %data) = @_;
   my (@xap, $msg_block);
   $msg_block->{Query} = $data{subtype};
   $msg_block->{Status} = $data{value};
   $msg_block->{Index} = $data{index} if defined $data{index};
   push @xap, "$data{type}.Notification", $msg_block;
   $$self{m_xap}->send_message('xAP-Audio.Query', \@xap, $data{target});
}

sub sendPrefResponse
{
   my ($self, %data) = @_;
   my (@xap, $msg_block);
   $msg_block->{Pref} = $data{pref};
   $msg_block->{Status} = $data{status};
   push @xap, "PlayPref.Notification", $msg_block;
   $$self{m_xap}->send_message("$SLIM\.Server", \@xap, $data{target});
}

sub sendDisplayResponse
{
   my ($self, %data) = @_;
   my (@xap, $msg_block);
   $msg_block->{Line1} = $data{line1};
   $msg_block->{Line2} = $data{line2};
   push @xap, "Display.Notification", $msg_block;
   $$self{m_xap}->send_message("$SLIM\.Display", \@xap, $data{target});
}

sub sendAlarmEvent
{
   my ($self, $id, $action) = @_;
   my (@xap, $msg_block);
   $msg_block->{ID} = $id;
   $msg_block->{Action} = $action;
   push @xap, "Schedule.Alarm", $msg_block;
   $$self{m_xap}->send_message("xAP-Audio.Schedule.Event", \@xap);
}

sub sendSleepEvent
{
   my ($self, $secs) = @_;
   my (@xap, $msg_block);
   $msg_block->{Sleep} = $secs;
   push @xap, "Schedule.Sleep", $msg_block;
   $$self{m_xap}->send_message("xAP-Audio.Schedule.Event", \@xap);
}

sub sendTransportEvent
{
   my ($self, $transportPtr) = @_;
   my (@xap, $transport_block);
   
   return if(ref $transportPtr ne 'HASH');
   
   # State=[playing | paused | stopped]
   # Elapsed="elapsed time"
   # Remaining="remaining time"
   # Duration="total time"       
   # Shuffle=[off | tracks | albums]
   # Repeat=[off | one | all]
   
   $transport_block->{PlayerID} = $transportPtr->{id};
   
   my $mode = $transportPtr->{mode};
   $transport_block->{State} = 'playing' if ($mode =~ /^play/i);
   $transport_block->{State} = 'paused' if ($mode =~ /^pause/i);
   $transport_block->{State} = 'stopped' if ($mode =~ /^stop/i);

   my $shuffle = $transportPtr->{shuffle};
   $transport_block->{Shuffle} = 'none' if $shuffle == 0;
   $transport_block->{Shuffle} = 'track' if $shuffle == 1;
   $transport_block->{Shuffle} = 'album' if $shuffle == 2;
   
   my $repeat = $transportPtr->{repeat};
   $transport_block->{Repeat} = 'off' if $repeat == 0;
   $transport_block->{Repeat} = 'one' if $repeat == 1;
   $transport_block->{Repeat} = 'all' if $repeat == 2;

   $transport_block->{Duration} = $transportPtr->{duration} if exists $transportPtr->{duration};
   $transport_block->{Elapsed} = $transportPtr->{elapsed} if exists $transportPtr->{elapsed};
   $transport_block->{Remaining} = $transportPtr->{remaining} if exists $transportPtr->{remaining};
   
   push @xap, 'Audio.Transport', $transport_block;
   $$self{m_xap}->send_message('xAP-Audio.Transport.Event', \@xap);
}

sub sendPlaylistInfo
{
   my ($self, $songPtr) = @_;
   return if(ref $songPtr ne 'HASH');
   my @xap = &songBlock($songPtr);
   $$self{m_xap}->send_message('xAP-Audio.Playlist.Info', \@xap);   
}

sub sendPlaylistEvent
{
   my ($self, $songPtr) = @_;
   return if(ref $songPtr ne 'HASH');
   my @xap = &songBlock($songPtr);
   $$self{m_xap}->send_message('xAP-Audio.Playlist.Event', \@xap);   
}

sub songBlock
{
   my ($songPtr) = @_;
   my (@xap, $song_block);
   
   $song_block->{TrackID} = $songPtr->{trackid};
   $song_block->{AlbumID} = $songPtr->{albumid};
   $song_block->{Title} = $songPtr->{title};
   $song_block->{Artist} = $songPtr->{artist};
   $song_block->{Album} = $songPtr->{album};
   $song_block->{Duration} = $songPtr->{duration};
   $song_block->{Genre} = $songPtr->{genre};
   $song_block->{Index} = $songPtr->{index};
   $song_block->{Tracks} = $songPtr->{tracks};
   $song_block->{Path} = Slim::Utils::Misc::unescape($songPtr->{path});
   push @xap, 'Now.Playing', $song_block;
   return @xap;
}

sub sendMixerEvent
{
   my ($self, %mixer) = @_;
   my (@xap, $mixer_block, $cmd_block);
   
   if($mixer{mute})
   {
      $mixer_block->{mute} = $mixer{mute};
      push @xap, 'Audio.Mute', $mixer_block;
      $$self{m_xap}->send_message('xAP-Audio.Audio.Event', \@xap);
   }
   elsif($mixer{volume})
   {
      $mixer_block->{volume} = $mixer{volume};
      $mixer_block->{balance} = $mixer{balance} if defined($mixer{balance});
      $mixer_block->{bass} = $mixer{bass} if defined($mixer{bass});
      $mixer_block->{treble} = $mixer{treble} if defined($mixer{treble});
      push @xap, 'Audio.Mixer', $mixer_block;
      
      $cmd_block->{command} = $mixer{command};
      $cmd_block->{delta} = $mixer{delta};
      push @xap, 'Mixer.Cmd', $cmd_block;

      $$self{m_xap}->send_message('xAP-Audio.Audio.Event', \@xap);
   }
}

sub sendDisplayEvent
{
   my ($self, $line1, $line2, $dur) = @_;
   my (@xap, $msg_block);
   $msg_block->{Line1} = $line1 if $line1;
   $msg_block->{Line2} = $line2 if $line2;
   $msg_block->{Duration} = $dur if $dur;
   push @xap, 'Display.Event', $msg_block;
   $$self{m_xap}->send_message("$SLIM\.Event", \@xap) if ($line1 or $line2);
}

sub sendButtonEvent
{
   my ($self, $button) = @_;
   my (@xap, $msg_block);
   $msg_block->{Button} = $button;
   push @xap, 'Button.Event', $msg_block;
   $$self{m_xap}->send_message("$SLIM\.Event", \@xap);
}

sub sendIREvent
{
   my ($self, %data) = @_;
   my (@xap, $msg_block);
   $msg_block->{Code} = $data{code};
   $msg_block->{Time} = $data{time};
   $msg_block->{Name} = $data{name} if $data{name};
   push @xap, 'IR.Event', $msg_block;
   $$self{m_xap}->send_message("$SLIM\.Event", \@xap);
}

sub sendMessage
{
   my ($self, $class, $block, $target) = @_;
   $$self{m_xap}->send_message($class, $block, $target);
}

1;
