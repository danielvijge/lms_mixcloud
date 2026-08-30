package Plugins::MixCloud::ProtocolHandler;

# Plugin to stream audio from MixCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
#
# Written by Christian Mueller (first release), 
#   Daniel Vijge (improvements),
#   KwarkLabs (added functionality)
#
# See file LICENSE for full license details

use strict;

use vars qw(@ISA);
use base qw(Slim::Player::Protocols::HTTPS);

use List::Util qw(min max);
use HTML::Parser;
use URI::Escape;
use JSON::XS qw(decode_json);
use XML::Simple;
use IO::Socket qw(:crlf);
use Data::Dump qw(dump);
use HTTP::Request;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Scalar::Util qw(blessed);
use Slim::Utils::Strings qw(string cstring);

use constant PAGE_URL_REGEXP => qr{^https?://(?:www|m)\.mixcloud\.com/};
use constant USER_AGENT => 'Mozilla/5.0 (X11; Linux x86_64; rv:124.0; SlimServer) Gecko/20100101 Firefox/124.0';
use constant META_CACHE_TTL => 86400 * 30; # 24 hours x 30 = 30 days

use constant EXEC => 'yt-dlp';
use constant EXEC_OPTIONS => '--skip-download --no-warnings --dump-json';

my $log   = logger('plugin.mixcloud');
my $prefs = preferences('plugin.mixcloud');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerURLHandler(PAGE_URL_REGEXP, __PACKAGE__);

sub isPlaylistURL { 0 }

sub canDirectStream { 
	return 0 if $prefs->get('useBuffered') && !Slim::Player::Protocols::HTTP->can('response');
	return shift->SUPER::canDirectStream(@_);
}

# MixCloud streams must use Persistent mode streaming, else they fail after a few minutes
sub canEnhanceHTTP {
	return 1;
}

sub scanUrl {
	$log->debug('scanUrl started');
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
	$log->debug('scanUrl ended');
}

sub getFormatForURL {
	return 'mixcloud' # custom-convert type
}

sub canSeek { 1 }

sub canTranscodeSeek { 1 }

sub getSeekData {
	$log->debug('getSeekData started');
	my ($class, $client, $song, $newtime) = @_;
	$log->debug('getSeekData ended');
	return { timeOffset => $newtime };
}

sub new {
	$log->debug('new started');
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};
	my $song      = $args->{song};
	# When the stream URL is a redirect and the socket closes between chunks.
	# The HTTP code is 206 - Partial Content - so not keep-alive mode.
	# This only happens on some clients (e.g. SqueezePlay on Windows).
	my $streamUrl = $args->{'url'} =~ /^mixcloud/ ? $song->streamUrl() : $args->{'url'};
	# my $streamUrl = $song->streamUrl() || return;
	my $track     = $song->pluginData();

	my $params = {
		url     => $streamUrl,
		song    => $song,
		client  => $client,
	};	
	
	# this may be a bit dangerous if another track is streaming...
	if (Slim::Player::Protocols::HTTP->can('canEnhanceHTTP') || !$prefs->get('useBuffered')) {
		require Slim::Player::Protocols::HTTPS;
		@ISA = qw(Slim::Player::Protocols::HTTPS);
	} else {	
		require Plugins::MixCloud::Buffered;
		@ISA = qw(Plugins::MixCloud::Buffered);
	}

	$log->debug('new ended');
	return $class->SUPER::new($params);
}

# Tweak user-agent for mixcloud to accept our request
sub requestString {
	$log->debug('requestString started');
	my $self = shift;
	my $request = $self->SUPER::requestString(@_);
	my $ua = USER_AGENT;

	$request =~ s/(User-Agent:)\s*.*/\1: $ua/;
	$request =~ s/Icy-MetaData:.+$CRLF//m;

	$log->debug('requestString ended');
	return $request; 
	
}

sub explodePlaylist {
	$log->debug('explodePlaylist started');
	my ( $class, $client, $uri, $callback ) = @_;

	if ( $uri =~ PAGE_URL_REGEXP ) {
		Plugins::MixCloud::Plugin::urlHandler(
			$client,
			sub { $callback->([map {$_->{'play'}} @{$_[0]->{'items'}}]) },
			{'search' => $uri},
		);
	}
	else {
		$callback->([$uri]);
	}
	$log->debug('explodePlaylist ended');
}

sub getNextTrack {
	$log->debug('getNextTrack started');
	my ($class, $song, $successCb, $errorCb) = @_;
	my $client = $song->master();
	my $url = $song->currentTrack()->url;

	_fetchTrackExtra($url, sub {
			my $meta = shift;
			return $successCb->() unless $meta;

			$song->streamUrl($meta->{'url'});
			# See comments regarding bitrate and type in makeCacheItem.
			Slim::Music::Info::setBitrate( $song->track, $meta->{'bitrate'} );
			Slim::Music::Info::setContentType( $song->track, $meta->{'type' });
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );

			$successCb->();
		}
	);
	$log->debug('getNextTrack ended');
}

sub findExec {
	$log->debug('findExec started');
	my $exec = EXEC;
	if ($^O eq 'MSWin32') {
		$exec = "$exec.exe";
	}
	if ($prefs->get('helper_application') eq 'custom') {
		if ($prefs->get('helper_application_custom_path') eq '') {
			return $exec;
		}
		else {
			return $prefs->get('helper_application_custom_path');
		}
		return
	}
	else {
		my %paths = Slim::Utils::Misc::getBinPaths();

		for my $path (%paths) {
			if (index($path, 'MixCloud') != -1) {
				$log->debug("Use bin path $path/$exec");
				return "$path/$exec";
			}
		}
		$log->error("Error: Cannot find bin path for yt-dlp");
	}
	$log->debug('findExec ended');
}

# complement track details (url, format, bitrate)
sub _fetchTrackExtra {
	$log->debug('_fetchTrackExtra started');
	my ($url, $cb) = @_;
	my $id = getId($url);
	my $simpleMeta = $cache->get("mixcloud_item_$id") || {};
	my $meta = $cache->get("mixcloud_item_extra_$id") || {};
	
	# we already have everything
	if ($cache->{'url'} && $simpleMeta->{'updated_time'} eq $meta->{'updated_time'}) {
		$log->debug("Got play URL $meta->{'url'} for $url from cache");
		$cb->($meta) if $cb;
		$log->debug('_fetchTrackExtra ended (cached response)');
		return $meta;
	}
	
	my $mixcloud_url = "https://www.mixcloud.com/$id";

	# use yt-dlp to extract stream URL
	my $exec = findExec();
    my $exec_options = EXEC_OPTIONS;
	my $yt_dlp_cmd = "$exec $exec_options $mixcloud_url 2>&1"; # pipe STDERR to STDOUT
	$log->info("Executing helper binary: $yt_dlp_cmd");
	my $info_json_str = `$yt_dlp_cmd`;
	$log->debug('yt-dlp command returned: '.$info_json_str);
	my $json = eval { decode_json($info_json_str) };
	$log->warn($@) if ($@);

	if ($json) {
		my $mixcloud_stream_url;
		my $mixcloud_stream_formats = $json->{'formats'};

		# we're interested in only some formats, in order of preference
		foreach ('hls-192', 'hls-', 'http') {
			my $format = $_;
			foreach my $mixcloud_format (@$mixcloud_stream_formats) {
				if ($mixcloud_format->{'format_id'} =~ $format) {
					$log->info("Found matching format for stream: $mixcloud_format->{'format_id'}");
					$mixcloud_stream_url = $mixcloud_format->{'url'};
					
					# need to re-read from cache in case TrackDetails have been updated
					$meta = $cache->get("mixcloud_item_$id") || {};
					$meta->{'bitrate'} = $mixcloud_format->{'tbr'} * 1_000;
					$meta->{'type'} = $mixcloud_format->{'audio_ext'} eq 'mp3' ? 'audio/mpeg' : 'audio/aac';
					$meta->{'url'} = $mixcloud_stream_url;
					$cache->set("mixcloud_item_extra_$id", $meta, META_CACHE_TTL);
					$meta->{'album'} = 'Mixcloud';
					
					$log->info("Got play URL $meta->{'url'} for $url");

					$cb->($meta) if $cb;

					$log->debug('_fetchTrackExtra ended');
					return $meta;
				}
			}
		}

		my @available_formats = ();
		foreach my $mixcloud_format (@$mixcloud_stream_formats) {
			push(@available_formats, $mixcloud_format->{'format_id'});
		}
		$log->error('Error: correct format could not be found in formats. Only available formats are ' .  join(', ', @available_formats));
		return;		

	} else {
		$log->error("Failed to determine stream URL for $url");
		$log->error("Tried to execute command: $yt_dlp_cmd");
		$log->error("$info_json_str");
	}
}

sub getMetadataFor {
	$log->debug('getMetadataFor started');
	my ($class, $client, $url, $args) = @_;
	
	my $id = getId($url);
	my $item = $cache->get("mixcloud_item_$id");
	
	# this is ugly... for whatever reason the EN/Classic skins can't handle tracks with an items element
	if ($args ne 'forceCurrent' && ($args->{params} && $args->{params}->{isWeb} && preferences('server')->get('skin')=~ /Classic|EN/i)) {
		delete @$item{'items'};
	} 
	
	return $item if $item && $item->{'play'};
	
	if (!$client->pluginData('fetchingMeta')) {
		my $fetchURL = "https://api.mixcloud.com/$id";

		$client->pluginData( fetchingMeta => 1 ) if $client;

		my $request = HTTP::Request->new( 'GET' => $fetchURL );
		$request->protocol('HTTP/1.1');	# Force request because, since May 2026, seen destination rejecting HTTP/1.0 which is LMS default
		my $params->{request} = $request;
		my %headers;
		$headers{'Connection'} = 'close';	# BAD BAD force close to try to prevent keep-alive in http/1.1
		
		$log->info("Mixcloud API call to ".$fetchURL);

		Slim::Networking::SimpleAsyncHTTP->new(
		
			sub {
				my $track = eval { decode_json($_[0]->content) };
				$log->warn($@) if ($@);
				makeCacheItem($client, $track, $args);
				$client->pluginData( fetchingMeta => 0 ) if $client;
			}, 
		
			sub {
				$client->pluginData( fetchingMeta => 0 ) if $client;
				$log->error("Error fetching track metadata for $url => $_[1]");
			},
			$params
		
		)->get($fetchURL, %headers);
	}	

	return {
		# bitrate => '192bps/64kbps',
		# type => 'aac/mp3',
		icon => __PACKAGE__->getIcon,
	};
}

# Track Info menu
sub trackInfo {
	$log->debug('trackInfo started');
	my ( $class, $client, $track ) = @_;

	my $url = $track->url;
	return undef;
}

# Track Info menu
sub trackInfoURL {
	$log->debug('trackInfoURL started');
	my ( $class, $client, $url ) = @_;

	return undef;
}

# If an audio stream fails, keep playing
sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;

	$log->warn("Direct stream failed: $url [$response] $status_line");

	$client->controller()->playerStreamingFailed( $client, 'PLUGIN_MIXCLOUD_STREAM_FAILED' );
}

sub getIcon {
	$log->debug('getIcon started');
	my ( $class, $url, $noFallback ) = @_;

	my $handler;

	if ( ($handler = Slim::Player::ProtocolHandlers->iconHandlerForURL($url)) && ref $handler eq 'CODE' ) {
		return &{$handler};
	}

	return $noFallback ? '' : 'html/images/radio.png';
}

sub getId {
	$log->debug('getId started');
	my $url = shift;
	my ($id) = $url =~ m{^(?:mixcloud)://(.*)$};
	return $id;
}

sub makeCacheItem {
	$log->debug('makeCacheItem started');
	my ($client, $json, $args) = @_;
	
	my $icon = __PACKAGE__->getIcon;
	my ($id) = ($json->{'key'} =~ /(?:\/)*(\S*)/);
	my $trackInfo = [];
	
	my $duration;
	if ($json->{'audio_length'}) {
		$duration = sprintf('%s:%02s:%02s', int($json->{'audio_length'} / 3600), int($json->{'audio_length'} / 60 % 60), int($json->{'audio_length'} % 60));
	}
	
	my $year;
	if ($json->{'created_time'}) {
		$year = substr $json->{'created_time'}, 0, 4;
	}
	
	push @$trackInfo, {
		name => cstring($client, 'TITLE') . cstring($client, 'COLON') . ' ' . $json->{'name'},
		play => "mixcloud://$id",
		type => 'text',
	};

	push @$trackInfo, {
		type => 'link',
		name => cstring($client, 'ARTIST') . cstring($client, 'COLON') . ' ' . $json->{'user'}->{'name'},
		url  => \&Plugins::MixCloud::Plugin::tracksHandler,
		passthrough => [ { params => substr($json->{'user'}->{'key'},1) , type => 'user', parser => \&Plugins::MixCloud::Plugin::_parseUser } ]
	} if $json->{'user'}->{'key'};
	
	push @$trackInfo, {
		name => cstring($client, 'LENGTH') . cstring($client, 'COLON') . ' ' . $duration,
		type => 'text',
	} if $duration;

	push @$trackInfo, {
		name => cstring($client, 'YEAR') . cstring($client, 'COLON') . ' ' . $year,
		type => 'text',
	} if $year;

	push @$trackInfo, {
		name => string('PLUGIN_MIXCLOUD_LINK') . cstring($client, 'COLON') . ' ' . $json->{'url'},
		weblink => $json->{'url'},
		type => 'text',
	} if $json->{'url'};

	push @$trackInfo, {
		name => cstring($client, 'GENRE') . cstring($client, 'COLON') . ' ' . join(', ', map { $_->{'name'} } @{$json->{'tags'}}),
		type => 'text',
	} if @{$json->{'tags'}} > 0;
	
	push @$trackInfo, {
		name => string('PLUGIN_MIXCLOUD_EXCLUSIVE') . cstring($client, 'COLON') . ' ' . ($json->{'is_exclusive'} eq 1 ? string('PLUGIN_MIXCLOUD_TRUE') : string('PLUGIN_MIXCLOUD_FALSE')),
		type => 'text',
	};
	
	if (defined $json->{'pictures'}->{'large'}) {
		$icon = $json->{'pictures'}->{'large'};
	} elsif (defined $json->{'pictures'}->{'medium'}) {
		$icon = $json->{'pictures'}->{'medium'};
	}
	
	my $item = {
		id => $id,
		duration => $json->{'audio_length'},
		name => $json->{'name'} . ($json->{'is_exclusive'} eq 1 ? (' (' . string('PLUGIN_MIXCLOUD_EXCLUSIVE_SHORT') . ')') : ''),
		title => $json->{'name'} . ($json->{'is_exclusive'} eq 1 ? (' (' . string('PLUGIN_MIXCLOUD_EXCLUSIVE_SHORT') . ')') : ''),
		artist => ($json->{'user'}->{'name'} ? $json->{'user'}->{'name'} : $json->{'user'}->{'username'}),
		album => "Mixcloud",
		play => "mixcloud://$id",
		genre => join(', ', map { $_->{'name'} } @{$json->{'tags'}}),
		# There's no way to derive bitrate and type until the stream headers are read.
		# If bitrate and type fields are set here then they are not updated correctly with data from the headers.
		# The web UI doesn't update these fields until after the stream starts and the user interacts but cannot be fixed here.
		# bitrate => '192/64kbps',
		# type => 'aac/mp3',
		passthrough => [ { key => $json->{'key'}} ],
		updated_time => $json->{'updated_time'},
		icon => $icon,
		image => $icon,
		cover => $icon,
		on_select => 'play',
	};

	
	# Set meta cache here, so that playlist does not have to query each track 
	# individually although small risk to overwrite the trackDetail query
	$log->debug("Caching mixcloud_item_$id", dump($item));
	$cache->set("mixcloud_item_$id", $item, META_CACHE_TTL);
	
	# this is ugly... for whatever reason the EN/Classic skins can't handle tracks with an items element
	my $simpleTracks = ( (ref($args) eq 'HASH' && $args->{params} && $args->{params}->{isWeb} && preferences('server')->get('skin') =~ /Classic|EN/i) ? 1 : 0);
	if (!$simpleTracks) {
		$item->{'items'} = $trackInfo;
	}

	# Replace some fields if the call comes from Plugin.pm but do not cache.
	if (ref($args) eq 'HASH' && $args->{params} && $args->{params}->{isPlugin}) {
		# line1 and line2 are used in browse view
		# artist and title are used in the now playing and playlist views
		$item->{name} = $json->{'name'} . ' by ' . ($json->{'user'}->{'name'} ? $json->{'user'}->{'name'} : $json->{'user'}->{'username'}) . ($duration ? ' (' . $duration . ')': '') .
				($json->{'is_exclusive'} eq 1 ? (' (' . string('PLUGIN_MIXCLOUD_EXCLUSIVE_SHORT') . ')') : ''),
		$item->{title} = $json->{'name'} . ' by ' . ($json->{'user'}->{'name'} ? $json->{'user'}->{'name'} : $json->{'user'}->{'username'}) . ($duration ? ' (' . $duration . ')': '') .
				($json->{'is_exclusive'} eq 1 ? (' (' . string('PLUGIN_MIXCLOUD_EXCLUSIVE_SHORT') . ')') : ''),
		$item->{line1} = $json->{'name'} . ($duration ? ' (' . $duration . ')': '') .
				($json->{'is_exclusive'} eq 1 ? (' (' . string('PLUGIN_MIXCLOUD_EXCLUSIVE_SHORT') . ')') : ''),
		$item->{line2} = $json->{'user'}->{'name'} . ($year ? ' (' . $year . ')' : ''),        
	}
	
	return $item;
}

1;
