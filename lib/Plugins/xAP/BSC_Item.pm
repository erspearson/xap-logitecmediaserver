package Plugins::xAP::BSC_Item;

=begin comment
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@

File:
	BSC_Item.pm

Description:
	xAP support for Basic Status and Control (BSC) schema - www.xapautomation.org
	
Author:
	Gregg Liming gregg@limings.net with special thanks to Bruce Winter - Misterhouse
    Edward Pearson erspearon.com - Modified and extended for use with SlimServer

License:
	This free software is licensed under the terms of the GNU public license.

Usage:

	Example initialization:



Special Thanks to: 
	Bruce Winter - MH
		

@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
=cut

require Plugins::xAP::Comm;
require Plugins::xAP::xAP_Item;

use constant INPUT => 'input';
use constant OUTPUT => 'output';

# Subclass xAP_Item to model a BSC endpoint

sub new 
{
   my ($class, $p_source_name, $p_subuid, $p_target_name) = @_;
   my $self={};
   bless $self, $class;

   $$self{m_xap} = new Plugins::xAP::xAP_Item($p_source_name, $p_subuid, 'xAPBSC.*');
   $$self{m_xap}->target_address($p_target_name) if $p_target_name;
   $$self{m_xap}->is_local(1); # local by default
   
   #State
   $$self{mode} = 'input';
   $$self{type} = 'binary';
   $$self{state} = '?';
   $$self{level} = undef;
   $$self{maxlevel} = undef;
   $$self{text} = undef;
   $$self{dirty} = 1;

   $$self{m_xap}->tie_items($self);

   return $self;
}

sub mode
{
   my ($self, $p_mode) = @_;
   $$self{mode} = lc $p_mode if(defined($p_mode) && ($p_mode =~ /^(input|output)$/i ));
   return $$self{mode};
}

sub type
{
   my ($self, $p_type) = @_;
   $$self{type} = lc $p_type if(defined($p_type) && ($p_type =~ /^(binary|level|text)$/i ));
   return $$self{mode};
}

sub max_level
{
   my ($self, $p_max_level) = @_;
   $$self{maxlevel} = $p_max_level if(defined($p_max_level) && ($p_max_level =~ /^\d*$/));
   return $$self{maxlevel};
}

sub display_text
{
   my ($self, $p_text) = @_;
   $$self{dirty} = 1 if(defined($p_text) && $p_text ne $$self{displaytext});
   $$self{displaytext} = $p_text if(defined($p_text));
   return $$self{displaytext};
}

sub is_local
{
   my ($self, $p_is_local) = @_;
   $$self{m_xap}->is_local($p_is_local) if(defined($p_is_local) && ($p_is_local =~ /0|1/));
   return $$self{m_xap}->is_local();
}

sub state
{
   my ($self, $p_state) = @_;
   if(($$self{mode} eq 'output') && defined($p_state) && ($p_state =~ /^(on|off|\?)$/i ))
   {
      my $newState = lc $p_state;
      if($$self{state} ne $newState)
      {
         $$self{state} = $newState;
         $$self{dirty} = 1;
      }
   }
   return $$self{state};
}

sub level
{
   my ($self, $p_level) = @_;
   if($$self{type} eq 'level')
   {
      if(($$self{mode} eq 'output') && defined($p_level) && ((($p_level =~ /^\d+$/ ) && ($p_level <= $$self{maxlevel})) || $p_level eq "?"))
      {
         my $newLevel = $p_level eq "?" ? $p_level : int $p_level;
         if($$self{level} ne $newLevel)
         {
            $$self{level} = $newLevel;
            $$self{dirty} = 1;
         }
      }
      return $$self{level};
   }
   return undef;
}

sub text
{
   my ($self, $p_text) = @_;
   if($$self{type} eq 'text')
   {
      if(($$self{mode} eq 'output') && defined($p_text))
      {
         my $newText = $p_text;
         if($$self{text} != $newText)
         {
            $$self{text} = $newText;
            $$self{dirty} = 1;
         }
      }
      return $$self{text};
   }
   return undef;
}

sub set_now 
{
   my ($self, $p_state, $p_setby) = @_;
   my $state = $p_state;
   if ($p_setby eq $$self{m_xap} ) {
      my $class = lc $$self{m_xap}{received}{'xap-header'}{class};
      if ($self->is_local()) {
      # then we're interested in cmd and query messages targetted at us
         if($$self{m_xap}{target_matched})
         {
            if ($class eq 'xapbsc.cmd') {
               # handle command
               $state = $self->rcvCmd();
            } elsif ($class eq 'xapbsc.query') {
               # handle query
               $state = $self->rcvQuery();
            }
         }
      } else {
         # is remote and therefore care about state updates from others
         if ($class eq 'xapbsc.event') {
            # handle event
            $state = $self->rcvEvent($p_setby);
         } elsif ($class eq 'xapbsc.info') {
            # handle info
            $state = $self->rcvInfo($p_setby);
         }
      }
   }
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

sub rcvQuery
{
   my ($self) = @_;
   $self->eventcallback('query');
   $self->sendInfoOrEvent;
}

sub rcvCmd
{
   my ($self) = @_;
   for my $section_name (keys %{$$self{m_xap}{received}} ) {      
      next unless ($section_name =~ /^(output)\.state\.\d+/);
      my %changed = ();
      my ($id, $state);
      for my $field_name (keys %{$$self{m_xap}{received}{$section_name}}) {
         my $value = $$self{m_xap}{received}{$section_name}{$field_name};
         
         # ID=
         if (lc $field_name eq 'id') {
            $id = $value if $value =~ /^(([\dA-F][\dA-F])+)|\*$/; # 1 or more hex digit pairs or *
         }
         
         # State=
         elsif (lc $field_name eq 'state') {
            $state = lc $value if $value =~ /^(on|off)$/i;
            $state = 'on'  if((lc $value eq 'toggle') && ($$self{state} eq 'off'));
            $state = 'off' if((lc $value eq 'toggle') && ($$self{state} eq 'on'));
            
            if($state ne $$self{state}) {
               $changed{state}{before} = $$self{state};
               $changed{state}{after} = $state;
            }
         }
         
         # Level=
         elsif ((lc $field_name eq 'level') && ($$self{type} eq 'level')) {
            my $level = $$self{level};
            my $max = $$self{maxlevel};
            
            # Absolute level
            if($value =~ /^(\d+)$/) {
               $level = $1 if $1 >= 0 && $1 <= $max;
            }
            # Percentage level
            elsif($value =~ /^(\d+)%$/) { 
               $level = int (($max * $1) / 100) if $1 >= 0 && $1 <= $max;
            }
            # x/y level
            elsif($value =~ /(\d+)\/(\d+)/) {
               $level = int (($max * $1) / $2) if $2 != 0 && $1 >= 0 && $1 <= $max;
            }
            
            if($level != $$self{level}) {
               $changed{level}{before} = $$self{level};
               $changed{level}{after} = $level;
            }
         }
         
         # Text=
         elsif ((lc $field_name eq 'text') && ($$self{type} eq 'text')) {
            if($value ne $$self{text}) {
               $changed{text}{before} = $$self{text};
               $changed{text}{after} = $value;
            }
         }
      }
      
      if($id) {
         if(((hex $id) == (hex $$self{m_xap}{id})) || ($id eq '*')) {            
            $self->eventcallback('cmd', %changed);
         }
      }
   }
   return 'cmd';
}

sub rcvEvent {
   my ($self, $p_xap) = @_;
   $self->eventcallback('event');
   return 'event';
}

sub rcvInfo {
   my ($self, $p_xap) = @_;
   $self->eventcallback('info');
   return 'info';
}

sub sendQuery {
   my ($self);
   my (@data, $msg_block);
   return unless $$self{m_xap}{target}; # need a remote target
   return if is_local(); # local items don't do queries
   
   push @data, 'request', $msg_block;
   $$self{m_xap}->send_message('xAPBSC.Query', \@data, $$self{m_xap}{target});
}

sub sendInfoOrEvent {  
   my ($self) = @_;
   my (@data, $msg_block);
   $msg_block->{State} = $$self{state};
   $msg_block->{Level} = $$self{level} . '/' . $$self{maxlevel} if $$self{type} eq 'level';
   $msg_block->{Text} = $$self{text} if $$self{type} eq 'text';
   $msg_block->{DisplayText} = $$self{displaytext} if defined $$self{displaytext};
   my $block_name = $$self{mode} . '.state';
   push @data, $block_name, $msg_block;
   $$self{m_xap}->send_message($$self{dirty} ? 'xAPBSC.Event' : 'xAPBSC.Info', \@data);
   $$self{dirty} = 0;
}

sub sendEventIfDirty {
   my ($self) = @_;
   $self->sendInfoOrEvent() if ($$self{dirty});
}
1;
