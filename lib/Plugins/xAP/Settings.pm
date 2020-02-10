package Plugins::xAP::Settings;

use strict;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;
use Slim::Utils::Log;

my $log = Slim::Utils::Log->addLogCategory(
{
	'category'     => 'plugin.xap.settings',
	'defaultLevel' => 'ERROR',
	'description'  => 'xAP plugin settings',
});

my $page = 'plugins/xAP/settings/basic.html';

my $prefs = preferences('plugin.xap');

$prefs->setValidate({'validator' => 'intlimit', 'low' => 15, 'high' => 600 }, 'update_interval');

$prefs->setValidate({'validator' => sub { Plugins::xAP::Plugin::validateDeviceID($_[1]); } }, 'uid');

$prefs->setValidate({'validator' => sub { Plugins::xAP::Plugin::validateIP($_[1]) } }, 'broadcast');


sub name
{
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_XAP');
}

# Return the settings page file
sub page
{
	$log->debug($page);
	return Slim::Web::HTTP::CSRF->protectURI($page);
}

# Return the set of preferences to be edited
sub prefs
{
	return ($prefs, qw(update_interval xAP_buttons xAP_ir use_legacy_schema_names usehub uid broadcast xAP_v13));
}

# This handler is called whenever the webpage is displayed as well as when a setting is "applied."
sub handler {
	my ($class, $client, $params) = @_;
	
	$log->debug("Enter handler");
	
	$params->{is70} = $::VERSION lt '7.1';
	
	if ($params->{saveSettings}) {
		$log->debug("Save setings");
	}
	return $class->SUPER::handler($client, $params);
}

1;

__END__
