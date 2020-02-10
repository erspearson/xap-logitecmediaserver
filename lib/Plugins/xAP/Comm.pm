package Plugins::xAP::Comm;

=begin comment
####################################################################################

File:
   Comm.pm

Description:
   xAP network communications

Author:
   Modified for SlimServer by Edward Pearson
   from code by Gregg Liming gregg@limings.net for ZoneMinder
   with special thanks to Bruce Winter - Misterhouse (misterhouse.sf.net)

License:
   This free software is licensed under the terms of the BSD license.

####################################################################################
=cut

require 5.008_001;
use strict;
use warnings;

use IO::Socket::INET;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::xAP::UID;
use Plugins::xAP::CRC;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.xap.comm',
	'defaultLevel' => 'ERROR',
	'description'  => 'xAP protocol level',
});

my $IANA_port = 3639; # The official xAP port

my $prefs = preferences('plugin.xap');


my %xap_uids;
my %xap_devices;

my $xap_send;
my $default_base_uid;
my @registered_xap_items;

my $xap_hbeat_interval;
my $xap_vendor;
my $xap_device;
my $xap_instance;
my $xap_version;
my $localIP = "127.0.0.1";

sub RegisterItem {
   my ($xap_item) = @_;
   push @registered_xap_items, $xap_item;
}

sub DeregisterItem {
    my $xap_item = shift;
    @registered_xap_items = grep {$_ != $xap_item} @registered_xap_items;
}

sub init_device
{
    my ($vendor, $device, $instance, $base_uid, $hbeat_interval, $last_subuid) = @_;
    
    $xap_vendor = $vendor;
    $xap_device = $device;
    $xap_instance = $instance;
    $default_base_uid = Plugins::xAP::UID->new($base_uid);
    $xap_version = $default_base_uid->getVersion();
    $xap_uids{$instance}{'last_sub_uid'} = $last_subuid;
    
    my $host = Slim::Utils::Network::hostName();
    if(defined($host))
    {
        $localIP = inet_ntoa((gethostbyname($host))[4]);
    }
   
    # init the hbeat intervals and counters
    $xap_hbeat_interval = $hbeat_interval if $hbeat_interval;
    $xap_hbeat_interval = 1 unless $xap_hbeat_interval;
    
    # open the sending port
    $xap_send = &OpenTransmitSocket();
    
    GetBaseUID($xap_instance); # reserve our UID
    my $socket = &OpenReceiveSocket();
    if ($socket)
    {
       $xap_devices{$xap_instance}{socket} = $socket;
       $xap_devices{$xap_instance}{port} = $socket->sockport();
       Slim::Utils::Network::blocking($socket,0);
       Slim::Networking::Select::addRead($socket, \&readxap);
       &send_xap_heartbeats();
    }    
}

sub OpenTransmitSocket
{
   # First try to open a socket to the user specified or
   # default broadcast address
   my $txAddress = $prefs->get("broadcast");
   if(!defined $txAddress) { $txAddress = inet_ntoa(INADDR_BROADCAST); }
   
   my $sock = new IO::Socket::INET->new(
                                  Proto => 'udp',
                                  PeerAddr => $txAddress,
                                  PeerPort => $IANA_port,
                                  Broadcast => 1
                               );
   
   if(!$sock)
   {
      # If that's not available then open a socket on the loopback
      # address. There's probably no network available at the moment.
      $log->warn("Cannot open socket to $txAddress, falling back to loopback.");
      $txAddress = inet_ntoa(INADDR_LOOPBACK);
      $sock = new IO::Socket::INET->new(
                                  Proto => 'udp',
                                  PeerAddr => $txAddress,
                                  PeerPort => $IANA_port,
                                  Broadcast => 1
                               );
   }
   if(!$sock)
   {
      $log->error("Could not open transmit socket.");
   }
   else
   {
      my $addr = $sock->sockhost();
      my $port = $sock->sockport();
      $log->info("xAP transmit from $addr:$port.");
   }  
   return $sock;
}

sub OpenReceiveSocket
{
   my $sock;
   
   if($prefs->get('usehub'))
   {
	  # Look for a free ehemeral port on the loopback address
      my $rxAddress = inet_ntoa(INADDR_LOOPBACK);
	  while(!$sock)
      {
		 my $port = int(rand 10000) + 52000;
         $sock = new IO::Socket::INET->new(
                                 Proto => 'udp',
                                 LocalAddr => $rxAddress,
                                 LocalPort => $port,
                                 ReuseAddr => 0,
                                 ReusePort => 0
                              );
      }
   }
   else
   {
	  # Try to open the xAP port directly
	  my $rxAddress = inet_ntoa(INADDR_ANY);
	  $sock = new IO::Socket::INET->new(
								 Proto => 'udp',
								 LocalAddr => $rxAddress,
								 LocalPort => $IANA_port,
								 ReuseAddr => 0,
								 ReusePort => 0
							  );
   }
   if(!$sock)
   {
      $log->error("Could not open receive socket.");
   } else {
      my $addr = $sock->sockhost();
      my $port = $sock->sockport();
      $log->info("xAP listening on $addr:$port.");
   }
   return $sock;
}

#sub open_port {
#   my ($port, $send_listen, $local) = @_;
#   my $sock;
#   
#   if ($send_listen eq 'send')
#   {
#      my $dest_address;
#      my $xap_broadcast = $prefs->get("broadcast");
#      $dest_address = $local ? inet_ntoa(INADDR_LOOPBACK) : $xap_broadcast;
#      
#      $sock = new IO::Socket::INET->new(
#                                       PeerPort => $port,
#                                       Proto => 'udp',
#                                       PeerAddr => $dest_address,
#                                       Broadcast => 1
#                                    );
#   }
#   else
#   {
#      my $listen_address;
#      $listen_address = $local ? inet_ntoa(INADDR_LOOPBACK) : inet_ntoa(INADDR_ANY);
#      
#      $sock = new IO::Socket::INET->new(
#                                       LocalPort => $port,
#                                       Proto => 'udp',
#                                       LocalAddr => $listen_address,
#                                       Broadcast => 1,
#                                       ReuseAddr => 0,
#                                       ReusePort => 0
#                                    );
#   }
#   return $sock ? $sock : 0;
#}

# Parse incoming xAP records
sub parse_data {
    my ($data) = @_;
    my ($data_type, %d);
    for my $r (split /[\r\n]/, $data) {
        next if $r =~ /^[\{\} ]*$/;
         # Store xap-header, xap-heartbeat, and other data
        if (my ($key, $value) = $r =~ /(.+?)=(.*)/) {
            $key   = lc $key;
            $value = lc $value if ($data_type =~ /^xap/ || $data_type =~ /^xpl/); # Do not lc real data;
            $d{$data_type}{$key} = $value;
        }
         # data_type (e.g. xap-header, xap-heartbeat, source.instance
        else {
            $data_type = lc $r;
            $d{$data_type}{type} = $data_type;
        }
    }
    return \%d;
}

sub readxap {
	my $sock = shift;
    for my $device_name (keys %{xap_devices}) {
       my $xap_socket = $xap_devices{$device_name}{socket};
       if ($xap_socket == $sock) {
		 my $xap_data;
		 my $from_saddr = recv($xap_socket, $xap_data, 1500, 0);
		 if ($xap_data) { &_process_incoming_xap_data($xap_data, $device_name); }
	  }
    }
}

sub _process_incoming_xap_data {
    my ($data, $device_name) = @_;
    
    my $xap_data = &parse_data($data);
    my ($protocol, $source, $class, $target);
    
    if ($$xap_data{'xap-header'} or $$xap_data{'xap-hbeat'}) {
        $protocol = 'xAP';
        $source   = $$xap_data{'xap-header'}{source};
        $class    = $$xap_data{'xap-header'}{class};
        $target   = $$xap_data{'xap-header'}{target};
        $source   = $$xap_data{'xap-hbeat'}{source} unless $source;
        $class    = $$xap_data{'xap-hbeat'}{class}  unless $class;
    }

    if($source && $class && $target)
    {
        $log->debug("xAP receive: source=$source class=$class target=$target\n");
    }
    $log->debug(flat_str($data));
    return unless $source;

   my $source_device;
   if( $source =~ /:/ ) {
      # remove the subaddress
      ($source_device) = $source =~ /(.*):/;
   } else {
      $source_device = $source;
   }
   
   # stop processing if we are the source
   return if ($source_device eq GetBaseSource());
    
   # Set states in matching xAP objects
   foreach my $o (@registered_xap_items) {
      # only process objects bound to this device
      next unless $o->device_name() eq $device_name; 

      my $regex_obj_source = &wildcard_2_regex($$o{source});
      my $regex_obj_target = &wildcard_2_regex($$o{target_address});
      my $regex_source = &wildcard_2_regex($source);
      my $regex_target = &wildcard_2_regex($target);
      
      if (!($o->is_local())) {
         # For remote devices, don't continue if the message source is not one we are mirroring
         next unless $source  =~ /$regex_obj_source/i;
      }
         
      # For local devices, if the inbound message is targetted, don't continue if it's not for us
      if(($o->is_local()) && ($target))
      {
         $$o{target_matched} = 0;
         my $regex_target = &wildcard_2_regex($target);
         next unless $$o{source} =~ /$regex_target/i;
         $$o{target_matched} = 1;
      }
       
      # Filter by message class
      my $regex_class = &wildcard_2_regex($$o{class});
      next unless lc $class   =~ /$regex_class/i;

      # For local devices, pass on the xAP data received
      if($o->is_local())
      {
         $$o{received} = $xap_data;
         $o->set_now('receive', 'xAP');
      }
      # For remote devices, process the changed state
      else
      {
         my $state_value;
         $$o{changed} = '';
         for my $section (keys %{$xap_data}) {
            $$o{sections}{$section} = 'received' unless $$o{sections}{$section};
            for my $key (keys %{$$xap_data{$section}}) {
               my $value = $$xap_data{$section}{$key};
               $$o{$section}{$key} = $value;
               # Monitor what changed (real data, not hbeat).
               $$o{changed} .= "$section : $key = $value | "
                  unless $section eq 'xap-header'; # or ($section eq 'xap-hbeat' and !($$o{class} =~ /^xap-hbeat/i));
               if ($$o{state_monitor} and "$section : $key" eq $$o{state_monitor} and defined $value) {
                  $state_value = $value;
               }
            }
         }
         $state_value = $$o{changed} unless defined $state_value;
         if ($o->allow_empty_state() || (defined $state_value and $state_value ne '')) {
            $o->set_now($state_value, 'xAP') ;
         }
      }
   }
}

sub AllocateUID
{
    my ($instance, $sub_source, $sub_uid) = @_;
    my $uid = Plugins::xAP::UID->new(GetBaseUID($instance));
    my $sub_uid_num = hex $sub_uid;
    
    my $last_sub = $xap_uids{$instance}{'last_sub_uid'};
    if($sub_uid_num > $last_sub) { $xap_uids{$instance}{'last_sub_uid'} = $sub_uid_num; }

    $uid->setSub($sub_uid_num);
    my $sub = $uid->getSub();
    # and, store it in the forward map
    $xap_uids{$instance}{'sub-fwd-map'}{$sub_source} = $sub;
    # as well as the reverse map
    $xap_uids{$instance}{'sub-rvs-map'}{$sub} = $sub_source;
    
    return $uid->getUID();
}

sub AllocateNextUID
{
    my ($instance, $sub_source) = @_;
    my $uid = Plugins::xAP::UID->new(GetBaseUID($instance));
    my $sub = "";
    if (exists($xap_uids{$instance}) && exists($xap_uids{$instance}{'sub-fwd-map'}{$sub_source})) {
        # already allocated
        $sub = $xap_uids{$instance}{'sub-fwd-map'}{$sub_source};
        $uid->setSub($sub);
    }
    else
    {
        my $sub_num = $xap_uids{$instance}{'last_sub_uid'};
        $sub_num++;
        $xap_uids{$instance}{'last_sub_uid'} = $sub_num;
        $uid->setSub($sub_num);
        $sub = $uid->getSub();
        # and, store it in the forward map
        $xap_uids{$instance}{'sub-fwd-map'}{$sub_source} = $sub;
        # as well as the reverse map
        $xap_uids{$instance}{'sub-rvs-map'}{$sub} = $sub_source;
    }
    return $uid->getUID();
}

sub get_xap_subaddress_devname {
   my ($p_type_name, $p_subaddress_uid) = @_;
   my $devname = '';
   if (exists($xap_uids{$p_type_name}{'sub-rvs-map'}{$p_subaddress_uid})) {
      $devname = $xap_uids{$p_type_name}{'sub-rvs-map'}{$p_subaddress_uid};
   }
   return $devname;
}

sub GetBaseUID {
    my $p_instance = shift;
    $p_instance = $xap_instance unless $p_instance;
    
    if (exists($xap_uids{$p_instance}) && exists($xap_uids{$p_instance}{'base'})) {
        return $xap_uids{$p_instance}{'base'};
    } else {
        my $uid;
        if ($default_base_uid && ($default_base_uid->isValid())) {
           # allow an override via the default
           $uid = $default_base_uid;
        } else {
           # generate the id from the source name
           $uid = Plugins::xAP::UID->new_v13();
           $uid->generateDev(GetBaseSource());
        }
        # store it
        $xap_uids{$p_instance}{'base'} = $uid->getUID();
        
        return $xap_uids{$p_instance}{'base'};
    }
}

sub GetBaseSource
{
   my ($instance) = @_;
   $instance = $xap_instance unless $instance;
   return "$xap_vendor.$xap_device.$instance";
}

sub wildcard_2_regex {
   my ($expr) = @_;
   return unless $expr;
   # convert all '.' to '\.'
   $expr =~ s/\./(\\\.)/g;
   # convert all asterisks
   $expr =~ s/\*/(\.\*)/g;
   # treat all :> as asterisks
   $expr =~ s/:>/(\.\*)/g;
   # convert all greater than symbols
   $expr =~ s/>/(\.\*)/g;

   return $expr;
}

sub sendXap {
      my ($target, $class_name, @data) = @_;
      my ($headerVars,@data2);
      $headerVars->{'class'} = $class_name;
      $headerVars->{'target'} = $target if defined $target;
      push @data2, $headerVars;
      while (@data) {
         my $section = shift @data;
         push @data2, $section, shift @data;
      }
      &sendXapWithHeaderVars(@data2);    
}

sub sendXapWithHeaderVars {
    if (defined($xap_send)) {
       my (@data) = @_;
       my ($parms, $msg, $headerVarsPtr, %headerVars);
   
       $headerVarsPtr = shift @data;
       %headerVars = %$headerVarsPtr;
       $msg  = "xap-header\n{\n";
       $msg .= "v=$xap_version\n";
       $msg .= "hop=1\n";
       if (exists($headerVars{'uid'})) {
          $msg .= "uid=" . $headerVars{'uid'} . "\n";
       } else {
          $msg .= "uid=" . &get_xap_base_uid() . "\n";
       }
       $msg .= "class=" . $headerVars{'class'} . "\n";
       if (exists($headerVars{'source'})) {
          $msg .= "source=" . $headerVars{'source'} . "\n";
       } else {
          $msg .= "source=" . GetBaseSource() . "\n";
       }
       if (exists($headerVars{'target'}) && ($headerVars{'target'} ne '*')) {
          $msg .= "target=" . $headerVars{'target'} . "\n";
       }
       $msg .= "}\n";
       
       while (@data) {
          my $section = shift @data;
          $msg .= "$section\n{\n";
          my $ptr = shift @data;
          my %parms = %$ptr;
          for my $key (sort keys %parms) {
            if(defined($parms{$key}))
            {
                $msg .= "$key=$parms{$key}\n";
            }
            else
            {
                # $log->debug("value undefined for key $key");
            }
          }
          $msg .= "}\n";
       }
      $log->debug(flat_str($msg));
      if ($xap_send)
      {
         $xap_send->send($msg);
      } else {
         $log->error("xAP socket is not available for sending!\n");
       }
   } else {
      $log->error("xAP is disabled and you are trying to send xAP data!\n");
   }
}

sub send_xap_heartbeats
{
    for my $instance (keys %{xap_devices})
    {
    	send_xap_heartbeat('alive', $instance);
    }

	Slim::Utils::Timers::setTimer("", Time::HiRes::time() + ($xap_hbeat_interval*60), \&send_xap_heartbeats);
}

sub send_xap_heartbeat
{
    my ($hbeat_type, $instance) = @_;
    $instance = $xap_instance unless $instance;

    my $port = $xap_devices{$instance}{port};
    my $xap_hbeat_interval_in_secs = $xap_hbeat_interval * 60;
    my $msg = "xap-hbeat\n{\nv=$xap_version\nhop=1\n";
    $msg .= "uid=" . GetBaseUID($instance) . "\n";
    $msg .= "class=xap-hbeat.$hbeat_type\n";
    $msg .= "source=" . GetBaseSource($instance) . "\n";
    $msg .= "interval=$xap_hbeat_interval_in_secs\n";
    $msg .= "port=$port\n";
    $msg .= "pid=$localIP:$$\n}\n";
    if($xap_send)
    {
        $xap_send->send($msg);
        $msg = flat_str($msg);
        $log->debug("xAP heartbeat");
        $log->debug(flat_str($msg));
    }
}

sub flat_str
{
   my ($msg) = @_;
   $msg =~ s/\r/\\r/g;
   $msg =~ s/\n/\\n/g;
   return $msg;
}


1

