#
# API for other plugins to use xAP Protocol functionality
#

package Plugins::xAP::API;
use strict;

require Plugins::xAP::Plugin;
require Plugins::xAP::Comm;
require Plugins::xAP::BSC_Item;
require Plugins::xAP::Slim_Item;
require Plugins::xAP::SlimServer_Item;

sub GetPlayerInterface
{
    my ($client, $protocol) = @_;
    
    my $item = Plugins::xAP::Plugin::getClientInterface($client, $protocol);
    
    return $item;
}

1;