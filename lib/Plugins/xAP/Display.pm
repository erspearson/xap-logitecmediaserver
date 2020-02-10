package Plugins::xAP::Display;

use strict;
use Slim::Utils::Log;
use Slim::Player::Client;
use Slim::Utils::Prefs;

my %displayQueues; # hash of messsage queues indexed by client id
my %displayPrefs; # hash of saved display prefs indexed by client id
my %currentMsg; # hash of current message pointers indexed by client id
my $queueCheckTimer; # callback timer for queue checking
my $nextQueueCheck; # when it will trigger

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.xap.display',
	'defaultLevel' => 'ERROR',
	'description'  => 'xAP message display',
});

#
# Message display routines
#
sub enqueueMessage
{
    my ($client, %msg) = @_;
    
    my $clientid = $client->id;
    my $clientName = $client->name;
    
    my $isImmediate = 0;
    my $active_queues = 0;
    # check if any queues active
    foreach my $id (keys %displayQueues)
    {
        $active_queues++ if (scalar @{$displayQueues{$id}} > 0);
    }
    
	#undefined lines are blank
	$msg{line1} = "" unless defined $msg{line1};
	$msg{line2} = "" unless defined $msg{line2};
	
	# For logging
	$msg{msgDesc} = "L1: " . ($msg{line1} || "(blank)") . " L2: " . ($msg{line2} || "(blank)");
	
    # default duration 5 seconds
    $msg{duration} = 5 unless defined $msg{duration};
	
	# duration can't be less than 200ms
	$msg{duration} = 0.2 if $msg{duration} < 0.2;
    
    # default time to live 10 mins
    $msg{ttl} = 600 unless defined $msg{ttl};
 
    # copy the duration for countdown
    $msg{remaining} = $msg{duration};
    
    # add a default priority of 1
    $msg{priority} = 1 unless defined $msg{priority};
    
    # add a default empty tag
    $msg{tag} = "" unless defined $msg{tag};
    
    # add a being displayed flag
    $msg{ondisplay} = 0;
    
    # add timing info
    $msg{enqueuetime} = Time::HiRes::time();
    $msg{displaytime} = 0;
    $msg{endtime} = 0;
    $msg{ttd} = $msg{enqueuetime} + $msg{ttl};
    
    my $qlen = 0;
    if (exists $displayQueues{$clientid}) { $qlen = scalar @{$displayQueues{$clientid}}; }
	
    # Disable auto brightness and visualisers while we're showing messages
    if($qlen == 0) {
	my $clientPrefs = preferences('server')->client($client);
	$displayPrefs{$clientid}{autobrightness} = $clientPrefs->get('autobrightness');
	$clientPrefs->set('autobrightness', 0);
	    
	if($client->display->can('hideVisu'))
	{
	    $displayPrefs{$clientid}{visu} = $client->modeParam('visu');;
	    $client->modeParam('visu', [0]); # hide
	}
    }

    $log->debug("Enqueue for $clientName at position $qlen : " . $msg{msgDesc});
    push @{$displayQueues{$clientid}}, \%msg;
    if(!defined $currentMsg{$clientid}) { $currentMsg{$clientid} = 0; }
    $qlen++;
    
    if ($qlen > 1) {
        # prioritise the queue - see sort function below
        my @pqueue = sort byQueueOrdering @{$displayQueues{$clientid}};
        $displayQueues{$clientid} = \@pqueue;
    }
    
    my $currMsg = $currentMsg{$clientid};
    my $headMsg = $displayQueues{$clientid}->[0];
    
    if($currMsg && $headMsg->{enqueuetime} != $currMsg->{enqueuetime})
    {
        # the item at the head of the queue is not the one on display
        unshowMessage($client, $currMsg);
        $currMsg = 0;
    }
    if(!$currMsg)
    {
        showMessage($client, $headMsg);
		
	# Check whether the next queue check timer event is no longer away than the duration of the new message
	my $newQueueCheck = Time::HiRes::time() + $msg{duration};
	if($queueCheckTimer && $nextQueueCheck && $newQueueCheck < $nextQueueCheck)
	{
	    Slim::Utils::Timers::killSpecific($queueCheckTimer);
	    $nextQueueCheck = $newQueueCheck;
	    $queueCheckTimer = Slim::Utils::Timers::setTimer('',$nextQueueCheck, \&updateMessages);
	}
    }
    
    if($active_queues == 0)
    {
        # If there were no active queues before this message was queued, there is (at least) one now
        # So start checking the queues
	updateMessages()
    }
}

sub deleteMessage
{
    my ($client, %msg) = @_;
    
    my $clientid = $client->id;
    my $clientName = $client->name;
    my $n = 0;
    
    if(defined $msg{tag} and $msg{tag} ne "")
    {
	my $tag = $msg{tag};
	$log->debug("Looking for message with tag '$tag' on $clientName display queue");
	foreach my $qMsg (@{$displayQueues{$clientid}})
	{
	    # look for messages with the given tag value
	    if(defined $qMsg->{tag} and $qMsg->{tag} eq $msg{tag})
	    {
		$qMsg->{duration} = 0; # don't actually delete, just set its duration to zero
		$log->debug("Deleted message");
		$n++;
	    }
	}
	if($n == 0) {
	    $log->debug("Message with tag '$tag' not found on $clientName display queue");
	} else {
	    Slim::Utils::Timers::killSpecific($queueCheckTimer) if($queueCheckTimer);
	    updateMessages()
	}
    }
}

sub byQueueOrdering
{
    # Sort the message queue by:
    #  Immediate messages first,
    #  Priority (decreasing),
    #  Arrival time (increasing).
    
   ($b->{queue_type} eq 'immediate') <=> ($a->{queue_type} eq 'immediate')
    ||
    $b->{priority} <=> $a->{priority}
    ||
    $a->{enqueuetime} <=> $b->{enqueuetime};
}

sub updateMessages
{
    my $active_queues = 0;
    my $now = Time::HiRes::time();
    my $minRemaining = 5; # update again in 5 or fewer seconds
    
	# Check for players no longer connected
    foreach my $clientid (keys %displayQueues)
    {
		my $client = Slim::Player::Client::getClient($clientid);
		if(!$client) {
			delete $displayQueues{$clientid};
			$log->debug("Discarding queue for disconnected client $clientid");
		}
	}
	
	foreach my $clientid (keys %displayQueues)
    {
        my $qref = $displayQueues{$clientid};
        
        if ($qref && scalar @{$qref} > 0)
        {
            my $headMsg = $qref->[0];
            my $client = Slim::Player::Client::getClient($clientid);
            my $clientName = $client->name;
            my $clientDisplay = $client->display;
            my $now = Time::HiRes::time();
            
            if($headMsg->{remaining} > 0 and $headMsg->{ttd} > $now and !$headMsg->{ondisplay})
            {
                # message at front of queue not displayed, with time remaining => show it
                $log->debug("Display queued message on $clientName");
                showMessage($client, $headMsg);
            }
            
            my $msg = $currentMsg{$clientid};
            
            if($msg and $msg->{ondisplay} and $msg->{remaining} > 0 and $msg->{displaytime} > 0)
            {
                # decrease the time remaining
                $msg->{remaining} = $msg->{displaytime} + $msg->{duration} - $now;
                $log->debug(sprintf("%s %.2fs remaining: %s", $clientName, $msg->{remaining}, $msg->{msgDesc}));
                
                # simulate a button press to fend off the screensaver timeout - is there a better way?
                Slim::Hardware::IR::setLastIRTime($client, $now);
				
		# when to check next?
		if($msg->{remaining} > 0 && $msg->{remaining} < $minRemaining) { $minRemaining = $msg->{remaining}; }
            }
            
            if($msg and $msg->{remaining} <= 0)
            {
                # stop displaying it
                unshowMessage($client, $msg);
                
                # remove the message from the queue
                $log->debug("Dequeue message from $clientName queue: " . $msg->{msgDesc});
                splice(@{$qref}, 0, 1);
                
                # remove any following messgages that have completed their duration or passed their ttl
                while(scalar @{$qref} > 0 and ($qref->[0]->{duration} <= 0 or $qref->[0]->{ttd} < $now))
                {
                    splice(@{$qref}, 0, 1);
                }
                
                # show the next message if there is one
                if(scalar @{$qref} > 0)
                {
		    my $nextMsg = $qref->[0];
                    $log->debug("Display next message on $clientName");
                    showMessage($client, $nextMsg);
		    if($nextMsg->{duration} < $minRemaining) { $minRemaining = $nextMsg->{duration}; }
                }
                else
		{
		    # Restore the user auto brightness setting
		    my $clientPrefs = preferences('server')->client($client);
		    $clientPrefs->set('autobrightness', $displayPrefs{$clientid}{autobrightness});
		    
		    # Restore visualiser setting
		    if($client->display->can('hideVisu'))
		    {
			$client->modeParam('visu', $displayPrefs{$clientid}{visu});
		    }
		    
		    # ensure state is showBriefly and end animation
                    $clientDisplay->animateState(5);
                    $clientDisplay->endAnimation;
                }
            }
            
            # count the queues still active after update
            $active_queues++ if scalar @{$qref} > 0;
        }
    }
    $log->debug("$active_queues active display " . ($active_queues == 1 ? "queue" : "queues"));

    # set a timer to run this again if there are queues still active
    if($active_queues)
    {
        $nextQueueCheck = Time::HiRes::time() + $minRemaining;
        $queueCheckTimer = Slim::Utils::Timers::setTimer('',$nextQueueCheck, \&updateMessages);
        $log->debug("Next queue check in $minRemaining secs");
    }
    else
    {
        $nextQueueCheck = 0;
        $queueCheckTimer = 0;
    }
}

sub showMessage
{
    my ($client, $msg) = @_;
    
    my $display = $client->display;
    my $dur = $msg->{duration};
    my $size = defined($msg->{size}) ? lc $msg->{size} : "medium";
    my $line1 = defined($msg->{line1}) ? $msg->{line1} : "";
    my $line2 = defined($msg->{line2}) ? $msg->{line2} : "";
    my $align1 = defined($msg->{align1}) ? lc $msg->{align1} : "left";
    my $align2 = defined($msg->{align2}) ? lc $msg->{align2} : "left";
    my $brightness = defined($msg->{brightness}) ? $msg->{brightness} : "powerOn";
    my $screenNo = $msg->{screen} || 1;
    my $screen = "screen$screenNo";
    
    my (@line, @center);
    $line[0] = $line1 if $align1 eq "left";
    $line[1] = $line2 if $align2 eq "left";
    $center[0] = $line1 if $align1 eq "center";
    $center[1] = $line2 if $align2 eq "center";
    
    $brightness =~ s/off/0/i;
    $brightness =~ s/dimmest/2/i;
    $brightness =~ s/dim/2/i;
    $brightness =~ s/bright/3/i;
    $brightness =~ s/brightest/4/i;
    
    $size =~ s/small/s/i;
    $size =~ s/medium/m/i;
    $size =~ s/large/l/i;
    
    # sizes
    # graphic-280x16: small medium large huge
    # graphic-320x32: light standard full
    # text: 0 (small) 1 (large)
    
    my $sizes = {
            'graphic-320x32' => { 's' => 'light', 'm' => 'standard', 'l' => 'full' },
            'graphic-280x16' => { 's' => 'small', 'm' => 'medium', 'l' => 'huge' },
            'text' =>           { 's' => 0, 'm' => 0, 'l' => 1 },
    };
    
    my $parts = {
        $screen => {
            'line'   => \@line,
            'center' => \@center,
            'fonts'  => {
                'graphic-320x32' => $$sizes{'graphic-320x32'}{$size},
                'graphic-280x16' => $$sizes{'graphic-280x16'}{$size},
                'text'           => $$sizes{'text'}{$size},
            }
        }
    };
    
    $log->debug($msg->{msgDesc} . ", Dur $dur s");
    
    # simulate a button press to stop the screensaver timeout re-dimming the display
    Slim::Hardware::IR::setLastIRTime($client, Time::HiRes::time());
    
    $msg->{ondisplay} = 1;
    
    $client->showBriefly($parts, {'duration'     => $dur,
                                  'brightness'   => $brightness,
                                  'firstline'    => $msg->{size} eq 'l',
                                  'block'        => 0,
                                  'callback'     => \&endShowCallback,
                                  'callbackargs' => { 'client' => $client->id, 'message' => $msg },
                                  'name'         => 'xAP', } );
    
    # kill the show briefly end animation timer - we'll deal with that here
    Slim::Utils::Timers::killTimers($display, \&Slim::Display::Display::endAnimation);
    
    $msg->{displaytime} = Time::HiRes::time();
    $currentMsg{$client->id} = $msg;
}

sub unshowMessage
{
    my $client = shift;
    my $msg = shift;
    
    my $clientDisplay = $client->display;
    $msg->{ondisplay} = 0;
    $log->debug($msg->{msgDesc});
    $currentMsg{$client->id} = 0;
    $clientDisplay->endShowBriefly; 
}

sub endShowCallback
{
    my $callbackargs = shift;
    
    my $now = Time::HiRes::time();
    my $clientid = $callbackargs->{client};
    my $msg = $callbackargs->{message};
    my $client = Slim::Player::Client::getClient($clientid);
    my $clientName = $client->name;
        
    $msg->{endtime} = $now;
    if($msg->{ondisplay})
    {
        # endShow caused by something else other than this package - eg, remote press
        # kill the message off
        $log->debug("$clientName message removed " . $msg->{msgDesc});
        $msg->{remaining} = 0;
    }
    else
    {
        # we triggered the endShow (via unshow)
        my $showntime = $msg->{endtime} - $msg->{displaytime};
        if($showntime >= $msg->{duration})
        {
            # kill the message as it's done its time
            $log->debug("$clientName message ended " . $msg->{msgDesc});
            $msg->{remaining} = 0;
        }
        else
        {
            # or adjust its shown time so it can be shown again
            $log->debug("$clientName message suspended " . $msg->{msgDesc});
            $msg->{remaining} -= $showntime;
        }
    }
    # Slim::Utils::Log::logBacktrace();
}

1
