package Plugins::xAP::Plugin;

#
# xAP Home Automation Protocol plugin v2 for SqueezeCenter v7.0+ by Edward Pearson
# http://www.erspearson.com/xAP
#
# http://www.xapautomation.org
#
#
#
#

use strict;
use base qw(Slim::Plugin::Base);
use Plugins::xAP::Settings;

use IO::Socket;
use Scalar::Util qw(blessed);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Slim::Utils::Misc;
use Slim::Music::Info;
use Sys::Hostname;
use Slim::Buttons::Common;

require Plugins::xAP::Comm;
require Plugins::xAP::Display;
require Plugins::xAP::BSC_Item;
require Plugins::xAP::Slim_Item;
require Plugins::xAP::SlimServer_Item;
require Plugins::xAP::API;

my $prefs = preferences('plugin.xap');
my $serverPrefs = preferences('server');

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.xap',
	'defaultLevel' => 'ERROR',
	'description'  => getDisplayName(),
});

my $requestLog = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.xap.request',
	'defaultLevel' => 'ERROR',
	'description'  => getDisplayName(),
});

my $localip;
my $xap_socket;
my $xap_port;
my $xap_slim_server_item;

# Prefs defaults
my $XAP_INTERVAL_DEFAULT = 60;
my $xap_interval;

my $XAP_SHORT_INTERVAL_DEFAULT = 5; # frequent checking during initialisation
my $xap_short_interval;

my $XAP_IR_DEFAULT = 0; # remote IR activity
my $xap_ir;

my $XAP_BUTTONS_DEFAULT = 0; # remote buttons
my $xap_buttons;

my $XAP_LEGACY_SCHEMA_NAMES_DEFAULT = 0; # backwards compatible 'sliMP3' rather than 'slim'
my $xap_legacy_schema_names;

my $XAP_USEHUB_DEFAULT = 1; # use external hub
my $xap_usehub;

my $xap_v13;
my $xap_device_id;
my $uid;
my $last_subuid;
my $XAP_DEVICE_ID_DEFAULT = 'AUTO'; # let xAP Comm choose the UID
my $xap_broadcast; # broadcast address for xAP transmission

my $xap_vendor_name = "ersp";
my $xap_device_name = "SlimServer";
my $xap_instance_name = "Unknown";

my %xap_subs = ();
my %xap_clients = ();

sub getDisplayName {
    return Slim::Utils::Strings::getString('PLUGIN_XAP');
}

sub enabled {
    return ($::VERSION ge '7.0');
}

$prefs->migrate(1, sub {
    $prefs->set('update_interval', Slim::Utils::Prefs::OldPrefs->get('plugin_xap_interval') || $XAP_INTERVAL_DEFAULT);
    $prefs->set('xAP_ir', Slim::Utils::Prefs::OldPrefs->get('plugin_xap_ir') || $XAP_IR_DEFAULT);
    $prefs->set('xAP_buttons', Slim::Utils::Prefs::OldPrefs->get('plugin_xap_buttons') || $XAP_BUTTONS_DEFAULT);
    $prefs->set('use_legacy_schema_names', Slim::Utils::Prefs::OldPrefs->get('plugin_xap_legacy_schema_names') || $XAP_LEGACY_SCHEMA_NAMES_DEFAULT);
    $prefs->set('uid', Slim::Utils::Prefs::OldPrefs->get('plugin_xap_uid') || $XAP_DEVICE_ID_DEFAULT);
    $prefs->set('broadcast', Slim::Utils::Prefs::OldPrefs->get('plugin_xap_broadcast') || inet_ntoa(INADDR_BROADCAST));
    1;
});

sub initPlugin
{
    my $class = shift;
    $class->SUPER::initPlugin();
    
    $log->info("Initialising xAP");
    
    Plugins::xAP::Settings->new;

    my $host = Slim::Utils::Network::hostName();
    if(defined($host))
    {
        $xap_instance_name = ucfirst $host;
        $localip = inet_ntoa((gethostbyname($host))[4]);
    }

    $xap_interval =	$prefs->get('update_interval');
    if (!defined($xap_interval)) {
        $xap_interval = $XAP_INTERVAL_DEFAULT;
        $log->debug("initialising update_interval");
        $prefs->set('update_interval', $xap_interval);
    }

    $xap_ir = $prefs->get('xAP_ir');
    if (!defined($xap_ir)) {
        $xap_ir = $XAP_IR_DEFAULT;
        $log->debug("initialising xAP IR enable");
        $prefs->set('xAP_ir', $xap_ir);
    }
    
    $xap_buttons = $prefs->get('xAP_buttons');
    if (!defined($xap_buttons)) {
        $xap_buttons = $XAP_BUTTONS_DEFAULT;
        $log->debug("initialising xAP buttons enable");
        $prefs->set('xAP_buttons', $xap_buttons);
    }
	
    $xap_usehub = $prefs->get('usehub');
    if (!defined($xap_usehub)) {
        $xap_usehub = $XAP_USEHUB_DEFAULT;
        $log->debug("initialising xAP use hub");
        $prefs->set('usehub', $xap_usehub);
    }
    
    $xap_legacy_schema_names = $prefs->get('use_legacy_schema_names');
    if (!defined($xap_legacy_schema_names)) {
        $xap_legacy_schema_names = $XAP_LEGACY_SCHEMA_NAMES_DEFAULT;
        $log->debug("initialising use legacy schema names");
        $prefs->set('use_legacy_schema_names', $xap_legacy_schema_names);
    }
    
    $xap_v13 = $prefs->get('xAP_v13');
    if (!defined($xap_v13)) {
        $xap_v13 = 1;
        $log->debug("initialising version");
        $prefs->set('xAP_v13', $xap_v13);
    }
   
    if($xap_v13)
    {
        $uid = Plugins::xAP::UID->new_v13();
    }
    else
    {
        $uid = Plugins::xAP::UID->new_v12();
    }

    $last_subuid = $prefs->get('last_subuid');
    if (!defined($last_subuid)) {
        $last_subuid = 0;
        $log->debug("initialising last sub uid");
        $prefs->set('last_subuid', $last_subuid);
    }
        
    $xap_device_id = validateDeviceID($prefs->get('uid'));
    if (!$xap_device_id || (length $xap_device_id != length $uid->getDev())) {
        $log->debug("initialising uid");
        $uid->generateDev();
        $xap_device_id = $uid->getDev();
        $prefs->set("uid", $xap_device_id);
    }
    else
    {
        $uid->setDev($xap_device_id);
    }
    
    $xap_broadcast = validateIP($prefs->get("broadcast"));
    if (!$xap_broadcast) {
        $xap_broadcast = inet_ntoa(INADDR_BROADCAST);
        $log->debug("initialising broadcast address");
        $prefs->set("broadcast", $xap_broadcast);
    }
    

    Plugins::xAP::Comm::init_device
    (
        $xap_vendor_name,
        $xap_device_name,
        $xap_instance_name,
        $uid->getUID(),
        $xap_interval/60,
        $last_subuid
    );
    
    # Create a SlimServer item to receive messages sent to the base address
    $xap_slim_server_item = new Plugins::xAP::SlimServer_Item(Plugins::xAP::Comm::GetBaseSource($xap_instance_name), $xap_legacy_schema_names);
    $xap_slim_server_item->setcallback('serverCmd', \&SlimServerCallback);
    
    # Initiate periodic client updates
	Slim::Utils::Timers::setTimer(undef, time() + 30, \&sendClientBSCUpdates);			
	Slim::Utils::Timers::setTimer(undef, time() + 30, \&sendPlayerUpdates);			

    # Set a request subscription so we're informed of slimserver activity
    Slim::Control::Request::subscribe(\&Plugins::xAP::Plugin::slimRequest);
}

sub shutdownPlugin {
    Slim::Control::Request::unsubscribe(\&Plugins::xAP::Plugin::slimRequest);
    
    # TODO - anything else?
}

sub addClient
{
    my ($client) = @_;
    my $sub;
    my $clientid = $client->id();

    if(!defined($xap_clients{$clientid}))
    {
        my $clientname = $client->name;
        $sub = &playerSub($client->name);
        $xap_clients{$clientid} = $sub;
        $xap_subs{$sub}{name} = $clientname;
        $xap_subs{$sub}{id} = $clientid;
		$xap_subs{$sub}{connected} = 1;
        
        my $source_instance = Plugins::xAP::Comm::GetBaseSource($xap_instance_name);
        my $source = $source_instance . ":$sub";
        
        $log->info("Create endpoint for $sub $clientid");
        
        my $xAPSubUID = $prefs->client($client)->get('xAPSubUID');
        
        my $bsc_item = new Plugins::xAP::BSC_Item($source, $xAPSubUID);
        if($$bsc_item{m_xap}{id} > $last_subuid)
        {
            $last_subuid = $$bsc_item{m_xap}{id};
            $prefs->set('last_subuid', $last_subuid);
        }
                
        $bsc_item->type('level');
        $bsc_item->mode('output');
        $bsc_item->max_level($client->maxVolume);
        $bsc_item->setcallback('cmd',\&BSCCmdCallback);
        $xap_subs{$sub}{bscitem} = $bsc_item;
        $$bsc_item{state} = &getClientBSCState($sub) || "?";
        $$bsc_item{level} = &getClientBSCLevel($sub) || "?";
        $$bsc_item{displaytext} = &getClientBSCPlayMode($sub) || "";
        
        my $slim_item = new Plugins::xAP::Slim_Item($source, $xAPSubUID, $xap_legacy_schema_names);
        $slim_item->setcallback('displayCmd', \&slimCmd);
        $slim_item->setcallback('controlCmd', \&slimCmd);
        $slim_item->setcallback('transportCmd', \&slimCmd);
        $slim_item->setcallback('audioCmd', \&slimCmd);
		$slim_item->setcallback('scheduleCmd', \&scheduleCmd);
        $slim_item->setcallback('audioQuery', \&slimQuery);
        $slim_item->setcallback('playlistCmd', \&slimPlaylistCmd);
        $slim_item->setcallback('prefCmd', \&slimPlayerPref);
        $xap_subs{$sub}{slimitem} = $slim_item;
        
        if(!$xAPSubUID)
        {
            $xAPSubUID = $$slim_item{m_xap}{id};
            $prefs->client($client)->set('xAPSubUID', $xAPSubUID);
        }
        
        $bsc_item->sendInfoOrEvent();
        $slim_item->sendPlaylistInfo() unless $client->isStopped;
    }
    return $sub;
}

sub deleteClient
{
    my $client = shift;
    my $id = $client->id;
    my $sub = $xap_clients{$id};

    if(defined($sub))
    {
        $log->info("Delete endpoint for $sub.");
        my $bsc_item = $xap_subs{$sub}{bscitem};
        my $slim_item = $xap_subs{$sub}{slimitem};
        
        $$bsc_item{m_xap}->remove if $bsc_item;
        $$slim_item{m_xap}->remove if $slim_item;
        
        $xap_subs{$sub} = undef;
        $xap_clients{$id} = undef;
    }
}

# Ensure an xAP subaddress is valid by removing any unallowed characters
sub validSub
{
    my ($sub) = @_;
    $sub =~ s/(-|\.|!|;| )//g;
    return $sub;
}

# Generate a valid subaddress for a player ( :Player.<client> )
sub playerSub
{
    my ($player) = @_;
    #my $sub = 'Player.' . validSub($player); # ( :Player.<client> )
    my $sub = validSub($player); # ( :<client> )
    return $sub;
}

sub getClientInterface
{
    my ($client, $protocol) = @_;
    
    my $interface = undef;
    my $clientid = $client->id();
    my $sub = $xap_clients{$clientid};
    
    if($protocol eq 'player')
    {
        $interface = $xap_subs{$sub}{slimitem};
    }
    elsif($protocol eq 'BSC')
    {
        $interface = $xap_subs{$sub}{bscitem};
    }
    
    return $interface;
}

sub getServerInterface
{
    return $xap_slim_server_item;
}

sub getClientBSCState
{
    my $sub = shift;
    
  	if($xap_subs{$sub}{connected})
	{
		my $client = Slim::Player::Client::getClient($xap_subs{$sub}{id});
		if(defined($client))
		{
			return $client->power() ? 'on' : 'off';
		}
	}
    return "?";
}

sub getClientBSCLevel
{
    my $sub = shift;
   
  	if($xap_subs{$sub}{connected})
	{
		my $client = Slim::Player::Client::getClient($xap_subs{$sub}{id});
		if(defined($client))
		{
			return int getVolume($client);
		}
	}
    return "?";
}

sub getClientBSCPlayMode
{
    my $sub = shift;
	my $modeStr = "";
	
	if($xap_subs{$sub}{connected})
	{
		my $client = Slim::Player::Client::getClient($xap_subs{$sub}{id});
		if(defined($client))
		{
			if($client->power())
			{
				if ($client->isPlaying)     { $modeStr = 'Playing'; }
				elsif ($client->isStopped)  { $modeStr = 'Stopped'; }
				elsif ($client->isPaused)   { $modeStr = 'Paused'; }
				else { $log->error("Failed to determine BSC mode"); }
			}
			else
			{
				$modeStr = "Off";
			}
		}
	}
	else
	{
		my $server = $xap_subs{$sub}{server} || "unknown server";
		$modeStr = "Connected to $server";
	}
    return $modeStr;
}

sub updateClientServers
{
    my @players = Slim::Player::Client::clients();
	my $otherPlayers = Slim::Networking::Discovery::Players::getPlayerList();
	my @snPlayers = Slim::Networking::SqueezeNetwork::Players::get_players();
	
    foreach my $sub (keys %xap_subs)
    {
		# Try to find the location of a client that has disconnected
		if($sub && !$xap_subs{$sub}{connected}) {
			my $id = $xap_subs{$sub}{id};
			
			# Is the player connected to another server?
			my $other = $otherPlayers->{$id};
			if($other) {
				$xap_subs{$sub}{server} = $other->{server};
			}
			
			# Is the player connected to SqueezeNetwork?
			else
			{
				foreach my $snPlayer (@snPlayers) {
					if($snPlayer->{mac} eq $id) { $xap_subs{$sub}{server} = "SqueezeNetwork"; last;}
				}
			}
			$xap_subs{$sub}{bscitem}->display_text(getClientBSCPlayMode($sub));
			$xap_subs{$sub}{bscitem}->sendEventIfDirty();
		}
	}	
}

sub sendClientBSCUpdates
{
	updateClientServers();
	
    # Send BSC info for each player
    my $i = 0;
    foreach my $sub (keys %xap_subs)
    {
        my $bsc = $xap_subs{$sub}{bscitem};
        $bsc->sendInfoOrEvent() if(defined $bsc);
        $i++
    }
    
    # Repeat this after xap_interval
    Slim::Utils::Timers::setTimer("", time() + $xap_interval, \&sendClientBSCUpdates);
}

# Send playlist and transport updates for each player
sub sendPlayerUpdates
{
    my $now = Time::HiRes::time();
    my $period = 0.2;
    
    foreach my $sub (keys %xap_subs)
    {
		# Don't send updates for a disconnected client
		next if(!$xap_subs{$sub}{connected});
		
        my $slim = $xap_subs{$sub}{slimitem};
        my $clientid = $xap_subs{$sub}{id};
       
		my $client = Slim::Player::Client::getClient($clientid);
	   
        if($client && $client->power())
        {
            my $transport_interval = ($client->isPlaying) ? 1 : 10;
            my $playlist_interval = 10;
            
            if(($xap_subs{$sub}{lasttransupdate} + $transport_interval) <= ($now + ($period / 2.0)))
            {
                my %transportdata = transportData($client);
                $slim->sendTransportEvent(\%transportdata);
                $xap_subs{$sub}{lasttransupdate} = $now;
            }
            
            if(($xap_subs{$sub}{lastplupdate} + $playlist_interval) <= ($now + ($period / 2.0)))
            {
                my %songdata = songData($client);
                $slim->sendPlaylistInfo(\%songdata) if $songdata{title};
                $xap_subs{$sub}{lastplupdate} = $now;
            }
        }
    }
    Slim::Utils::Timers::setTimer("", $now + $period, \&sendPlayerUpdates);
}

# Called by a subscription made to the Slim Request/Notification subsystem
sub slimRequest
{
    my $request = shift;
	
	if($request->isCommand([['client'], ['forget']]))
	{
		my $id = $request->clientid();
		my $sub = $xap_clients{$id};
		my $clientName = $xap_subs{$sub}{name} || $id;
		$requestLog->info("$clientName: client forget");
		return;
	}
	
    my $client = $request->client();

	if($client)
	{
		if($requestLog->is_debug()) {
			$requestLog->debug($request->client()->name() . ": " . $request->getRequestString());
			while (my ($key, $val) = each %{$request->{'_params'}}) { $requestLog->info("   Param: [$key] = [$val]"); }
		}
		
		if($request->isCommand([['client'], ['new']]))
		{
			if(!defined($xap_clients{$client->id()}))
			{
				addClient($client);
			}
			else
			{
				my $sub = $xap_clients{$client->id()};
				$xap_subs{$sub}{connected} = 1;
				$xap_subs{$sub}{server} = Slim::Utils::Network::hostName();
				$xap_subs{$sub}{bscitem}->state(getClientBSCState($sub));
				$xap_subs{$sub}{bscitem}->level(getClientBSCLevel($sub));
				$xap_subs{$sub}{bscitem}->display_text(getClientBSCPlayMode($sub));
				$xap_subs{$sub}{bscitem}->sendEventIfDirty();
			}
			return;
		}

		my $id = $client->id();
		my $sub = $xap_clients{$id};
		
		if($sub)
		{
			if($request->isCommand([['client'], ['reconnect']]))
			{
				$xap_subs{$sub}{connected} = 1;
				$xap_subs{$sub}{server} = Slim::Utils::Network::hostName();
				$xap_subs{$sub}{bscitem}->state(getClientBSCState($sub));
				$xap_subs{$sub}{bscitem}->level(getClientBSCLevel($sub));
				$xap_subs{$sub}{bscitem}->display_text(getClientBSCPlayMode($sub));
				$xap_subs{$sub}{bscitem}->sendEventIfDirty();
			}
	
			elsif($request->isCommand([['client'], ['disconnect']]))
			{
				$xap_subs{$sub}{connected} = 0;
				$xap_subs{$sub}{server} ="";
				$xap_subs{$sub}{bscitem}->state(getClientBSCState($sub));
				$xap_subs{$sub}{bscitem}->level(getClientBSCLevel($sub));
				$xap_subs{$sub}{bscitem}->display_text(getClientBSCPlayMode($sub));
				$xap_subs{$sub}{bscitem}->sendEventIfDirty();
				Slim::Utils::Timers::setTimer("", time() + 5, \&updateClientServers);
			}

			# check the client name against the sub in case it has been changed (via the UI)
			if($xap_subs{$sub}{name} ne $client->name())
			{
				# if it has changed, delete the old xAP client and create a new one
				my $newName = $client->name();
				$log->info("Player $id changed name from $xap_subs{$sub}{name} to $newName.");
				$requestLog->info("Player $id changed name from $xap_subs{$sub}{name} to $newName.");
				deleteClient($client);
				$sub = addClient($client);
			}
			
			my $clientname = $client->name();
			
			my $slim = $xap_subs{$sub}{slimitem};
			
			if($request->isCommand([['power']]))
			{
				$xap_subs{$sub}{bscitem}->display_text(getClientBSCPlayMode($sub));
				$xap_subs{$sub}{bscitem}->state(&getClientBSCState($sub));
				$xap_subs{$sub}{bscitem}->sendInfoOrEvent();
			}
			elsif($request->isCommand([['sleep']]))
			{
				my $sleep = $request->getParam('_newvalue');
				$slim->sendSleepEvent($sleep) if $sleep;

			}
			elsif($request->isCommand([['mixer'], ['volume', 'muting', 'treble', 'bass', 'pitch']]))
			{
				my $command = $request->getRequest(1);
				
				my $oldVol = $xap_subs{$sub}{bscitem}->level;
				my $newVol = int getVolume($client);
				my $deltaVol = $newVol - $oldVol;
				my $delta = $command eq 'volume' ? $deltaVol : int $request->getParam('_newvalue');
				
				if($delta != 0)
				{
					$xap_subs{$sub}{bscitem}->display_text(getClientBSCPlayMode($sub));
					$xap_subs{$sub}{bscitem}->level($newVol);
					$xap_subs{$sub}{bscitem}->sendEventIfDirty();
					
					my %mixerdata;
					$mixerdata{command} = $command;
					$mixerdata{delta} = $delta;
					$mixerdata{volume} = getVolume($client);
					$mixerdata{balance} = $client->balance() if($client->can('balance'));
					$mixerdata{bass} = $client->bass();
					$mixerdata{treble} = $client->treble();
					$slim->sendMixerEvent(%mixerdata);
				}
			}
			elsif($request->isCommand([['alarm']]))
			{
				my $action = $request->getRequest(1) || $request->getParam('_cmd');
				my $id = $request->getParam('_id');
				$slim->sendAlarmEvent($id, $action);
			}
			elsif($request->isCommand([['play', 'pause', 'stop']])
				  || $request->isCommand([['mode'], ['play', 'pause', 'stop']])
				  || $request->isCommand([['playlist'], ['clear']])
				  || $request->isCommand([['playlist'], ['newsong']]))
			{
				$xap_subs{$sub}{bscitem}->display_text(getClientBSCPlayMode($sub));
				$xap_subs{$sub}{bscitem}->state(&getClientBSCState($sub));
				$xap_subs{$sub}{bscitem}->sendEventIfDirty();
				
				my %transportdata = transportData($client);
				$slim->sendTransportEvent(\%transportdata);
				
				my %songdata = songData($client);
				$slim->sendPlaylistEvent(\%songdata);
			}
			elsif($request->isCommand([['display']]))
			{
				$slim->sendDisplayEvent(
					$request->getParam('_line1'),
					$request->getParam('_line2'),
					$request->getParam('_duration')
				);
			}
			elsif($xap_buttons && $request->isCommand([['button']]))
			{
				my $button = $request->getParam('_buttoncode');
				$slim->sendButtonEvent($button);
			}
			elsif($xap_ir && $request->isCommand([['ir']]))
			{
				my %data;
				$data{code} = $request->getParam('_ircode');
				$data{time} = $request->getParam('_time');
				$data{name} = Slim::Hardware::IR::lookup($client, $request->getParam('_ircode'));
				$slim->sendIREvent(%data);
			}
		}
    } else {
		if($requestLog->is_debug()) {
			$requestLog->debug("Request: " . $request->getRequestString());
			while (my ($key, $val) = each %{$request->{'_params'}}) { $requestLog->info("   Param: [$key] = [$val]"); }
		}
	}
}

sub songData
{
    my $client = shift;
    my %songdata;
    
    my $track = Slim::Player::Playlist::song($client);
    my $url   = blessed($track) ? $track->url : $track;
    
    # Protocol Handlers can setup their own track info
    my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);

    my $remoteMeta;
    if ($track && $track->remote) {
		if ($handler && $handler->can('getMetadataFor')) {
			$remoteMeta = $handler->getMetadataFor($client, $url);
		}
    }

    if (blessed($track)) {
        $songdata{trackid} = $track->id;
        $songdata{albumid} = $track->album->id if $track->album;
        $songdata{duration} = $track->duration;
        $songdata{album} = $track->album->name if $track->album;
		$songdata{album} = $remoteMeta->{album} if $remoteMeta;
        $songdata{artist} = $track->artist->name if $track->artist;
		$songdata{artist} = $remoteMeta->{artist} if $remoteMeta;
        $songdata{title} = $track->name;
		$songdata{title} = $remoteMeta->{title} if $remoteMeta;
        $songdata{genre} = 'None';
        $songdata{genre} = $track->genre->name if $track->genre;
    } else {
		my $duration = Slim::Player::Source::playingSongDuration($client) || 0;
		$songdata{duration} = $duration ? durationToText($duration) : '';
    }
    $songdata{index} = Slim::Player::Source::playingSongIndex($client) + 1;
    $songdata{tracks} = Slim::Player::Playlist::count($client);
    $songdata{path} = $url;
    
    return %songdata;
}

sub transportData
{
    my ($client) = @_;
    
    my %transportdata;

	my $controller = $client->controller();
	if($controller) {
		my $durationKnown = Slim::Player::StreamingController::playingSongDuration($controller) || 0;
		my $elapsed  = Slim::Player::StreamingController::playingSongElapsed($controller) || 0;
		
		$transportdata{id} = $client->id;
		$transportdata{mode} = getClientBSCPlayMode();
		$transportdata{elapsed} = $elapsed ? durationToText($elapsed) : '';
		$transportdata{remaining} = $durationKnown ? Slim::Player::Player::textSongTime($client, 1) : '';
		$transportdata{remaining} =~ s/^-//; #remove -ve sign
		$transportdata{shuffle} = Slim::Player::Playlist::shuffle($client);
		$transportdata{repeat} = Slim::Player::Playlist::repeat($client);
	}
    
    return %transportdata;
}

sub durationToText {
	my $dur = shift;
	
	my $hrs = int($dur / (60 * 60));
	my $min = int(($dur - $hrs * 60 * 60) / 60);
	my $sec = $dur - ($hrs * 60 * 60 + $min * 60);
	
	if ($hrs) {
	    return sprintf("%d:%02d:%02d", $hrs, $min, $sec);
	} else {
	    return sprintf("%02d:%02d", $min, $sec);
	}
}

sub SlimServerCallback
{
    my ($obj, %data) = @_;
    my $type = $data{type};
    if($type eq 'server.command')
    {
		Slim::Control::Request::executeRequest( undef, [ $data{command} ] ) if($data{command});
    }
    elsif($type eq 'player.query')
    {
        my $command = $data{command};
        if($command eq 'count')
        {
            $data{status} = Slim::Player::Client::clientCount();
        }
        elsif($command eq 'name')
        {
            my $index = $data{playerindex};
            my @players = Slim::Player::Client::clients();
            $data{status} =  $players[$index]->name() if ($index < Slim::Player::Client::clientCount());
        }
        elsif($command eq 'address')
        {
            my $index = $data{playerindex};
            my @players = Slim::Player::Client::clients();
            $data{status} =  $players[$index]->ipport() if ($index < Slim::Player::Client::clientCount());
        }
        $obj->sendPlayerQueryResponse(%data) if $data{status};
    }
    elsif($type eq 'pref.query')
    {
        my $pref = $data{pref};
        $data{status} = Slim::Utils::Prefs::get($pref);
        $obj->sendPrefResponse(%data) if($data{status});
    }
    elsif($type eq 'pref.set')
    {
        my $pref = $data{pref};
        my $value = $data{value};
        Slim::Utils::Prefs::set($pref, $value);
        $data{status} = Slim::Utils::Prefs::get($pref);
        $obj->sendPrefResponse(%data) if($data{status});
    }
}

sub BSCCmdCallback
{
    my ($obj, %changed) = @_;
    my $sub = $obj->{m_xap}{source_sub};
    my $client = Slim::Player::Client::getClient($xap_subs{$sub}{id}) || return;
    
	if(defined($changed{state}{after}))
	{
		my $newState = $changed{state}{after};
		my $newPower = ($newState eq 'on');
		if($newPower != $client->power())
		{
			Slim::Control::Request::executeRequest( $client, ["power", $newPower]);
		}
	}
	
	if(defined($changed{level}{after}))
	{
		my $newLevel = $changed{level}{after};
		my $newVolume = $newLevel;
		if ($newVolume != int getVolume($client))
		{
			Slim::Control::Request::executeRequest( $client, ["mixer", "volume", $newVolume]);
		}
	}
}


sub slimCmd
{
    my ($obj, %data) = @_;
    my $sub = $obj->{m_xap}{source_sub};
    my $client = Slim::Player::Client::getClient($xap_subs{$sub}{id}) || return;
    my $type = $data{type};

    if($type eq 'display.cmd')
    {
        $data{queue_type} = 'queue' unless exists($data{queue_type});
        $data{duration} = 5 unless exists($data{duration});
        
        # append additional lines to line 2
        for(my $i = 3; $i <= 9; $i++) {
            if(exists $data{"line$i"}) {
                $data{line2} .= ' ' . $data{"line$i"};
                delete $data{"line$i"};
            } else {
                last
            }
        }
        if(exists $data{queue_type} and $data{queue_type} eq "delete")
        {
            # Delete a previously enqueued message
            Plugins::xAP::Display::deleteMessage($client, %data);
        }
        else
        {
            # Enqueue the display request
            Plugins::xAP::Display::enqueueMessage($client, %data);
        }
    }
    elsif($type eq 'display.query')
    {
        $data{line1} = $client->prevline1();
        $data{line2} = $client->prevline2();
        $obj->sendDisplayResponse(%data);
    }
    elsif($type eq 'button.command')
    {
        my $button = $data{button};
        # xapExecuteCmd("button $button", $client->id);
		Slim::Control::Request::executeRequest( $client, ["button", $button]);
		
    }
    elsif($type eq 'ir.command')
    {
        my $ir = $data{code};
        # xapExecuteCmd("ir $ir", $client->id);
		Slim::Control::Request::executeRequest( $client, ["ir", $ir]);
    }
    elsif($type eq 'transport')
    {
        if(defined($data{command})) {
            my $cmd = $data{command};
			my $param;
            
            if($cmd =~ /^(play|pause|stop)$/)
            {
                if(defined($data{param}))
                {
                    if($data{param} eq 'off') {
                        if($cmd eq 'play') { $cmd = 'stop'; }
                        elsif($cmd eq 'stop') { $cmd = 'play'; }
                        elsif($cmd eq 'pause') { $param = "0"; }
                    }
                    elsif($data{param} eq 'on') {
                        if($cmd eq 'pause') { $param = "1"; }
                    }
                }
				Slim::Control::Request::executeRequest( $client, [$cmd, $param]);
            }
            elsif($cmd eq 'next')
            {
				Slim::Control::Request::executeRequest( $client, ["playlist", "jump", "+1"]);
            }
            elsif($cmd eq 'prev')
            {
				Slim::Control::Request::executeRequest( $client, ["playlist", "jump", "-1"]);
            }
        }
    }
    elsif($type eq 'transport.seek')
    {
        my $param = $data{seek};
        # &xapExecuteCmd("gototime $param", $client->id);
		Slim::Control::Request::executeRequest( $client, ["gototime", $param]);
    }
    elsif($type eq 'mute')
    {
        my $param = $data{param};
        my $vol = $client->volume;
        if(!$param || (lc $param eq 'toggle') || ((lc $param eq 'on') && ($vol >= 0)) || ((lc $param eq 'off') && ($vol < 0)))
        {
			Slim::Control::Request::executeRequest( $client, ["mixer", "muting"]);
        }
    }
    elsif($type eq 'mixer')
    {
        my $params = $data{param};
        foreach my $channel ( keys %{$params} )
        {
            my $param = $params->{$channel};
			Slim::Control::Request::executeRequest( $client, ["mixer", $channel, $param]);
        }
    }
    elsif($type eq 'power')
    {
        my $power = $data{command};
        $power = 0 if $power eq 'off';
        $power = 1 if $power eq 'on';
		Slim::Control::Request::executeRequest( $client, ["power", $power]);
    }
}

sub scheduleCmd
{
    my ($obj, %data) = @_;
    my $sub = $obj->{m_xap}{source_sub};
    my $client = Slim::Player::Client::getClient($xap_subs{$sub}{id}) || return;
    my $type = $data{type};

    if($type eq 'sleep')
    {
        my $secs = $data{param};
		Slim::Control::Request::executeRequest( $client, ["sleep", $secs]);
    }
	elsif($type eq 'alarm')
	{
		my $command = $data{command};
		Slim::Control::Request::executeRequest( $client, ["alarm", $command]);	}
}

sub slimQuery
{
    my ($obj, %data) = @_;
    my $sub = $obj->{m_xap}{source_sub};
    my $client = Slim::Player::Client::getClient($xap_subs{$sub}{id}) || return;
    my $type = $data{type};
    my $subType = $data{subtype};
    my $slim = $xap_subs{$sub}{slimitem};

    return unless $client;
    return unless $slim;
    return unless $type;
    return unless $subType;
    
    
    if($type eq 'audio')
    {
        if($subType eq 'mode') {
            $data{value} = getClientBSCPlayMode();
        }
        elsif($subType eq 'sleep') {
            my $sleep = $client->sleepTime();
            $data{value} = Slim::Utils::Misc::timeF($sleep) if $sleep;
            $data{value} = 'No sleep time' unless $sleep;
        }
        elsif($subType eq 'power') {
            $data{value} = $client->power() ? 'On' : 'Off';
        }
        elsif($subType eq 'volume') {
            $data{value} = getVolume($client);
        }
        elsif($subType eq 'balance') {
            if($client->can('balance')) {
                $data{value} = $client->balance();
            } else {
                $data{value} = 'Not implemented';
            }
        }
        elsif($subType eq 'bass') {
            $data{value} = $client->bass();
        }
        elsif($subType eq 'treble') {
            $data{value} = $client->treble();
        }
    }
    elsif($type eq 'track')
    {
        my $track  = Slim::Player::Playlist::song($client);

        if (blessed($track)) {
            my $artistObj = $track->artist;
            my $albumObj = $track->album;

            if($subType eq 'time') {
                $data{value} = Slim::Player::Player::textSongTime($client);
            }
            elsif($subType eq 'genre') {
                $data{value} = $track->{genre} || 'None';
            }
            elsif($subType eq 'artist') {
                if (blessed($artistObj) && $artistObj->can('name')) {
                    $data{value}= $artistObj->name;
                }
            }
            elsif($subType eq 'album') {
                my $albumObj = $track->album;
                if (blessed($albumObj) && $albumObj->can('title')) {
                    $data{value} = $albumObj->title;
                }
            }
            elsif($subType eq 'title') {
                $data{value} = $track->{title} || 'None';
            }
            elsif($subType eq 'duration') {
                $data{value} = $track->duration();
            }
        }
        if($subType eq 'path') {
            $data{value} = Slim::Player::Playlist::url($client);
        }
    }
    elsif($type eq 'playlist')
    {
        if($subType eq 'index') {
            $data{value} = Slim::Player::Source::playingSongIndex($client) + 1;
        }
        elsif($subType eq 'tracks') {
            $data{value} = Slim::Player::Playlist::count($client);
        }
        elsif($subType eq 'shuffle') {
            $data{value} = Slim::Player::Playlist::shuffleType($client);
        }
        elsif($subType eq 'repeat') {
            my @repeat = qw(Off Track Playlist);
            $data{value} = $repeat[Slim::Player::Playlist::repeat($client)];
        }
        else
        {	
            my $index = $data{index};
            my $tracks = Slim::Player::Playlist::count($client);
            if($index <= $tracks)
            {
                my $playlist = Slim::Player::Playlist::playList($client);
                my $track = $playlist->[$index];
                if(blessed($track))
                {
                    my $artistObj = $track->artist;
                    my $albumObj = $track->album;

                    my $url = $track->{url};

                    if($subType eq 'genre') {
                        $data{value} = $track->{genre} || 'None';
                    }
                    elsif($subType eq 'artist') {
                        if (blessed($artistObj) && $artistObj->can('name')) {
                            $data{value}= $artistObj->name;
                        }
                    }
                    elsif($subType eq 'album') {
                        if (blessed($albumObj) && $albumObj->can('title')) {
                            $data{value} = $albumObj->title;
                        }
                    }
                    elsif($subType eq 'title') {
                        $data{value} = $track->{title} || 'Unknown';
                    }
                    elsif($subType eq 'duration') {
                        $data{value} = $track->duration();
                    }
                    elsif($subType eq 'path') {
                        $data{value} = $url;
                    }
                }
            }
        }
    }
    $slim->sendQueryResponse(%data) if defined $data{value};
}

sub slimPlayerPref
{
    my ($obj, %data) = @_;
    my $sub = $obj->{m_xap}{source_sub};
    my $client = Slim::Player::Client::getClient($xap_subs{$sub}{id}) || return;
    my $type = $data{type};
    my $pref = $data{pref};

    return unless $client;
    return unless $type;	
    return unless $pref;	
    
    if($type eq 'playerpref.query')
    {
        $data{status} = $prefs->client($client)->get($pref);
    }
    elsif($type eq 'playerpref.set')
    {
        my $value = $data{value};
        $prefs->client($client)->set($pref, $value);
        $data{status} = $prefs->client($client)->get($pref);
    }
    $obj->sendPrefResponse(%data) if defined $data{status};
}

sub slimPlaylistCmd
{
    my ($obj, %data) = @_;
    my $sub = $obj->{m_xap}{source_sub};
    my $client = Slim::Player::Client::getClient($xap_subs{$sub}{id}) || return;
    my $type = $data{type};
    my $slim = $xap_subs{$sub}{slimitem};

    return unless $client;
    return unless $slim;
    return unless $type;
    
    if(($type eq 'track') && defined($data{command}) && defined($data{track}))
    {
        my $command = $data{command};
        my $track = $data{track};
		Slim::Control::Request::executeRequest( $client, ["playlist", $command, $track]);
    }
    elsif(($type eq 'move') && defined($data{from}) && defined($data{to}))
    {
        my $from = $data{from};
        my $to = $data{to};
		Slim::Control::Request::executeRequest( $client, ["playlist", "move", $from, $to]);
    }
    elsif(($type eq 'edit') && defined($data{edit}))
    {
        if($data{edit} eq 'clear')
        {
			Slim::Control::Request::executeRequest( $client, ["playlist", "clear"]);
        }
        elsif(defined($data{playlist}))
        {
            my $command = $data{edit};
            my $playlist = $data{playlist};
			Slim::Control::Request::executeRequest( $client, ["playlist", $command, $playlist]);
        }
    }
    elsif(($type eq 'album') && defined($data{command}) && defined($data{genre}) && defined($data{artist}))
    {
        my $command = $data{command};
        $command = 'loadalbum' if $command eq 'load';
        $command = 'addalbum' if $command eq 'append';
        my $genre = $data{genre};
        my $artist = $data{artist};
        my $album = $data{album};
		Slim::Control::Request::executeRequest( $client, ["playlist", $command, $genre, $artist, $album]);
    }
    elsif(($type eq 'repeat') && defined($data{repeat}))
    {
        my $repeat = $data{repeat};
        my $cmd;
        $cmd = 0 if ($repeat eq 'stop');
        $cmd = 1 if ($repeat eq 'track');
        $cmd = 2 if ($repeat eq 'playlist');
		Slim::Control::Request::executeRequest( $client, ["playlist", "repeat", $cmd]);
    }
    elsif(($type eq 'shuffle') && defined($data{shuffle}))
    {
        my $shuffle = $data{shuffle};
        my $cmd;
        $cmd = 0 if ($shuffle eq 'off');
        $cmd = 1 if ($shuffle eq 'on');
		Slim::Control::Request::executeRequest( $client, ["playlist", "shuffle", $cmd]);
    }
}


sub validateDeviceID
{
    my $val = shift @_;
    return 0 unless $val =~ /^([0-9A-F][0-9A-F]){2,}$/; # even number (=>4) UC hex digits
    return 0 if $val =~ /^0+$/; # reject reserved value
    return 0 if $val =~ /^F+$/; # reject reserved value
    return $val;
}

sub validateIP {
    my $val = shift;

    if (length($val) == 0) {
        return $val;
    }
    
    if ($val !~ /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/) { 
        #not formatted properly
        return 0;
    }

    if (
        ($1 < 0) || ($2 < 0) || ($3 < 0) || ($4 < 0) || ($5 < 0) ||
        ($1 > 255) || ($2 > 255) || ($3 > 255) || ($4 > 255)
        ) {
        # bad number
        return 0;
    }

    return $val;
}

# get persisted volume not the 'temp' volume
# which fades to zero on pause and mute
sub getVolume
{
    my $client = shift;
    return int $serverPrefs->client($client)->get('volume');
}
1;
