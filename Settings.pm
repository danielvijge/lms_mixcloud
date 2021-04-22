package Plugins::MixCloud::Settings;

# Plugin to stream audio from SoundCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written Christian Mueller
# See file LICENSE for full license details

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

sub name {
	return 'PLUGIN_MIXCLOUD';
}

sub page {
	return 'plugins/MixCloud/settings/basic.html';
}

sub prefs {
	my $class = shift;
	# playformat not used for now
	my @prefs = ( preferences('plugin.mixcloud'), qw(apiKey) );
	push @prefs, qw(useBuffered) unless Slim::Player::Protocols::HTTP->can('canEnhanceHTTP');
	return @prefs;
}

sub handler {
	my ($class, $client, $params) = @_;
	$params->{"pref_useBuffered"} = 0 unless defined $params->{"pref_useBuffered"};	
	return $class->SUPER::handler( $client, $params );
}

1;
