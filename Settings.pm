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
	return (preferences('plugin.mixcloud'), qw(apiKey playformat));
}

1;
