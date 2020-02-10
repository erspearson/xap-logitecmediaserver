
package Plugins::xAP::xAP_Item;

=begin comment
####################################################################################

File:
    xAP_Item.pm

Description:
    Generic xAP support for receiving xAP messages

Author:
    Gregg Liming
    gregg@limings.net
    Modified for SlimServer by Edward Pearson

License:
	This free software is licensed under the terms of the BSD license.

Usage:


   state_now(): returns all current section data using the following form (unless otherwise
	set via state monitor):
	<section_name1> : <key1> = <value1> | <section_name_n> : <key_n> = <value_n>

   state_now(section_name): returns undef if not defined; otherwise, returns current data for
	section name using the following form (unless otherwise set via state_monitor):
	<key1> = <value1> | <key_n> = <value_n>

   current_section_names: returns the list of current section names delimitted by the pipe character

   tie_value_convertor(keyname, expr): ties the code reference in expr to keyname.  The returned
      value from expr is substituted into the key value. The reference in expr may use the variables
      $section and $value for processing (where $section is the section name and $value is the
      original value.

      e.g., $xap_obj->tie_value_convertor('temp','$main::convert_c_to_f_degrees($value');
      note: the reference to '$main::' allows access to the user code sub - convert_c_to_f_degrees

   class_name(class_name): Sets/Gets the classname.  Classname is actually the <classname>.<typename>
      for xAP and xPL.  It is also often referred to as the schema name.  Used to filter
      inbound messages.  Except for generic "monitors", this shoudl be set.

   source(source): Sets/Gets the source (name).  This is normally <vendor_id>.<device_id>.<instance_id>.
      It is used to filter inbound messages. Except for generic "monitors", this should be set.

   target_address(target_address): Sets/Gets the target (name).  Syntax is similar to source.  Used to direct (target)
      the message to a specific device.  Use "*" (default) for broadcast messages.

   app_status().  Gets the app status. Initially, set to "unknown" until receipt of first "alive"
      heartbeat (then, set to "alive"). Set to "dead" on first dead heart-beat.

   send_message(target, data).  Sends xAP message to target using data hash.


Special Thanks to: 
	Bruce Winter - Misterhouse (misterhouse.sf.net)
		
####################################################################################
=cut

use strict;
use Plugins::xAP::Comm;
use Plugins::xAP::UID;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.xap.message',
	'defaultLevel' => 'ERROR',
	'description'  => 'xAP plugin message level',
});

sub new
{
    my ($object, $xap_source, $sub_uid, $xap_class, @data) = @_;
    my $self = {};
    bless $self, $object;

	if($xap_source =~ /(.*):(.*)/)
	{
		$$self{source_device} = $1;
		$$self{source_sub} = $2;
		$$self{has_sub} = 1;
	}
	else {
		$$self{source_device} = $xap_source;
		$$self{has_sub} = 0;
	}
	
	my @source_device_parts = split /\./, $$self{source_device};
    
	$$self{source_device_parts} = \@source_device_parts;
    my $n = scalar @source_device_parts;
    my $instance = join '.', @source_device_parts[2 .. $n-1];
	$$self{m_device_name} = $instance;
    $$self{source} = $xap_source;
    
    my $uid;
    if($$self{has_sub})
    {
        if($sub_uid)
        {
            $uid = Plugins::xAP::UID->new(Plugins::xAP::Comm::AllocateUID($instance, $$self{source_sub}, $sub_uid));
        }
        else
        {
            $uid = Plugins::xAP::UID->new(Plugins::xAP::Comm::AllocateNextUID($instance, $$self{source_sub}));
        }
    } else {
		$uid = Plugins::xAP::UID->new(Plugins::xAP::Comm::GetBaseUID($instance));
    }
	$$self{uid} = $uid->getUID();
    $$self{id} = $uid->getSub();
    
    $xap_class  = '*' if !$xap_class;
    $$self{state}    = '';
    $$self{class}    = $xap_class;
    $$self{protocol} = 'xAP';
    $$self{target_address}   = '*';
    $$self{m_timeoutHeartBeat} = 0; # don't monitor heartbeats
    $$self{m_appStatus} = 'unknown';
    $$self{m_allow_empty_state} = 0;
    $$self{is_local} = 0;
    &store_data($self, @data);

    Plugins::xAP::Comm::RegisterItem($self);

    return $self;
}

sub class_name {

    my ($self, $p_strClassName) = @_;
    $$self{class} = $p_strClassName if defined $p_strClassName;
    return $$self{class};
}

sub source {

    my ($self, $p_strSource) = @_;
    $$self{source} = $p_strSource if defined $p_strSource;
    return $$self{source};
}

sub target_address {
    my ($self, $p_strTarget) = @_;
    $$self{target_address} = $p_strTarget if defined $p_strTarget;
    return $$self{target_address};
}

sub is_local {
    my ($self, $p_is_local) = @_;
    $$self{is_local} = $p_is_local if defined $p_is_local;
    return $$self{is_local};
}

sub device_name {
    my ($self, $p_strDeviceName) = @_;
    $$self{m_device_name} = $p_strDeviceName if $p_strDeviceName;
    return $$self{m_device_name};
}

sub allow_empty_state {
    my ($self, $p_allowEmptyState) = @_;
    $$self{m_allow_empty_state} = $p_allowEmptyState if defined($p_allowEmptyState);
    return $$self{m_allow_empty_state};
}

sub app_status {
    my ($self) = @_;
    return $$self{m_appStatus};
}

sub set_now {
    my ($self, $p_state, $p_setby) = @_;
    $$self{state} = $p_state;
    $$self{setby} = $p_setby;

    # process any tied items
    for my $key (keys %{$$self{tied_objects}}) {
       my $state_key = $p_state;
       $state_key = 'all_states' unless $$self{tied_objects}{$key}{$state_key};
       if ($$self{tied_objects}{$key}{$state_key}) {
          for my $state2 (sort keys %{$$self{tied_objects}{$key}{$state_key}}) {
             my ($tied_object, $log_msg) = @{$$self{tied_objects}{$key}{$state_key}{$state2}};
             # synch the tied object's state w/ our own
             $tied_object->set_now($$self{state}, $self);
          }
       }
    }
}

sub send_message {
    my $self = shift @_;
    my $p_class = shift @_;
    my $p_data = shift @_;
    my $p_strTarget = shift @_;

    my ($headerVars, @data);
	
    $$headerVars{class} = $p_class;
	$$headerVars{target} = $p_strTarget if defined $p_strTarget;
	$headerVars->{source} = $$self{source};
	$headerVars->{uid} = $$self{uid};	
    push @data, $headerVars;
    while (@{$p_data}) {
        my $section = shift @$p_data;
        push @data, $section, shift @$p_data;
    }
    &Plugins::xAP::Comm::sendXapWithHeaderVars(@data);
}

sub store_data {
    my ($self, @data) = @_;
    while (@data) {
        my $section = shift @data;
        $$self{sections}{$section} = 'send';
        my $ptr = shift @data;
        my %parms = %$ptr;
        for my $key (sort keys %parms) {
            my $value = $parms{$key};
            $$self{$section}{$key} = $value;
            $$self{state_monitor} = "$section : $key" if $value eq '$state';
        }
    }
}

sub default_setstate {
    my ($self, $state, $substate, $set_by) = @_;

    # Send data, unless we are processing incoming data
    return if $set_by eq 'xAP';

    my ($section, $key) = $$self{state_monitor} =~ /(.+) : (.+)/;
    $$self{$section}{$key} = $state;

    my @parms;
    for my $section (sort keys %{$$self{sections}}) {
        next unless $$self{sections}{$section} eq 'send'; # Do not echo received data
        push @parms, $section, $$self{$section};
    }

    # sending stat info about ourselves?
    if (lc $$self{source} eq GetBaseSource()) {
        &Plugins::xAP::Comm::sendXap('*', @parms, $$self{class});
    } else {
	# must be cmnd info to another device addressed by source
        &Plugins::xAP::Comm::sendXap($$self{source}, @parms, $$self{class});
    }
}

sub state_now {
	my ($self, $section_name) = @_;
	my $state_now = $$self{state}; #$self->SUPER::state_now();
	if ($section_name) {
		# default section_state_now to undef unless it actually exists
		my $section_state_now = undef;
		for my $section (split(/\s+\|\s+/,$state_now)) {
			my @section_data = split(/\s+:\s+/,$section);
			my $section_ref = $section_data[0];
			next if $section_ref eq '';
			if ($section_ref eq $section_name) {
				if (defined($section_state_now)) {
					$section_state_now .= " | $section_data[1]";
				} else {
					$section_state_now = $section_data[1];
				}
			}
		}
		$state_now = $section_state_now;
	}
	return $state_now;
}

sub current_section_names {
	my ($self) = @_;
	my $changed = $$self{changed};
	my $current_section_names = undef;
	if ($changed) {
		for my $section (split(/\s+\|\s+/,$changed)) {
			my @section_data = split(/\s+:\s+/,$section);
			if (defined($current_section_names)) {
				$current_section_names .= " | $section_data[0]";
			} else {
				$current_section_names = $section_data[0];
			}
		}

	}
	return $current_section_names;
}

sub tie_value_convertor {
	my ($self, $key_name, $convertor) = @_;
	$$self{_value_convertors}{$key_name} = $convertor if (defined($key_name) && defined($convertor));
}


sub tie_items {
#   return unless $main::Reload;
    my ($self, $object, $state, $desiredstate, $log_msg) = @_;
    $state         = 'all_states' unless defined $state;
    $desiredstate  = $state       unless defined $desiredstate;
    $log_msg = 1                  unless $log_msg;
    return if $$self{tied_objects}{$object}{$state}{$desiredstate};
    $$self{tied_objects}{$object}{$state}{$desiredstate} = [$object, $log_msg];
}

sub remove {
    my $self = shift;
    Plugins::xAP::Comm::DeregisterItem($self);
}

1

