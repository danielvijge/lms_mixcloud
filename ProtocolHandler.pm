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
use JSON::XS::VersionOneAndTwo;
use XML::Simple;
use IO::Socket qw(:crlf);
use Data::Dump qw(dump);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Scalar::Util qw(blessed);
use Slim::Utils::Strings qw(string cstring);

use constant PAGE_URL_REGEXP => qr{^https?://(?:www|m)\.mixcloud\.com/};
use constant USER_AGENT => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.13; rv:56.0; SlimServer) Gecko/20100101 Firefox/56.0';
use constant META_CACHE_TTL => 86400 * 30; # 24 hours x 30 = 30 days

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
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

sub getFormatForURL {
	my ($class, $url) = @_;		
	my $meta = $cache->get('mixcloud_item_' . getId($url));
	return $meta ? $meta->{'format'} : $prefs->get('playformat');
}

sub new {
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

	$log->info( 'Remote streaming Mixcloud track: ' . $streamUrl );

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

	return $class->SUPER::new($params);
}

# Tweak user-agent for mixcloud to accept our request
sub requestString {
	my $self = shift;
	my $request = $self->SUPER::requestString(@_);
	my $ua = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.13; rv:56.0; SlimServer) Gecko/20100101 Firefox/56.0";

	$request =~ s/(User-Agent:)\s*.*/\1: $ua/;
	$request =~ s/Icy-MetaData:.+$CRLF//m;

	return $request; 
	
}

sub explodePlaylist {
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
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	my $client = $song->master();
	my $url = $song->currentTrack()->url;
	
	_fetchTrackExtra($url, sub {
			my $meta = shift;
			return $successCb->() unless $meta;
			
			$song->_streamFormat($meta->{'format'});
			$song->streamUrl($meta->{'url'});
			# See comments regarding bitrate and type in makeCacheItem.
			# $song->bitrate($meta->{'bitrate'} * 1000);
	
			if ($meta->{'format'} =~ /mp3|mp4|aac|m4a/i) {
				my $http = Slim::Networking::Async::HTTP->new;
				$http->send_request( {
					request     => HTTP::Request->new( GET => $meta->{'url'}, [ 'User-Agent' => USER_AGENT ] ),
					onStream    => $meta->{format} eq 'mp3' 
					               ? \&Slim::Utils::Scanner::Remote::parseAudioStream
								   : \&Slim::Utils::Scanner::Remote::parseMp4Header,
					onError     => sub {
						my ($self, $error) = @_;
						$log->error( "could not find $meta->{'url'} header with format $meta->{'format'} $error" );
						$successCb->();
					},
					passthrough => [ $song->track, 
					                 { cb => sub {
										# See comments regarding bitrate and type in makeCacheItem.
										# This line causes the actual bitrate of the stream to be cached.
										$meta->{bitrate} = int($song->track->bitrate/1000) . 'kbps';
										$cache->set('mixcloud_item_extra' . getId($url), $meta, META_CACHE_TTL);
								        $successCb->(); 
									 }},
									 $meta->{'url'} ],
				} );
			} else {
				$successCb->();
			}
		}
	);
}

# complement track details (url, format, bitrate) using dmixcloud
sub _fetchTrackExtra {
	my ($url, $cb) = @_;
	my $id = getId($url);
	my $simpleMeta = $cache->get("mixcloud_item_$id") || {};
	my $meta = $cache->get("mixcloud_item_extra_$id") || {};
	
	$log->debug("Getting complement for $url => $id");	
	
	# we already have everything
	if ($cache->{'url'} && $simpleMeta->{'updated_time'} eq $meta->{'updated_time'}) {
		$log->debug("Got play URL $meta->{'url'} for $url from cache");
		$cb->($meta) if $cb;
		return $meta;
	}
	
	my $mixcloud_url = "https://www.mixcloud.com/$id";
	my $http = Slim::Networking::Async::HTTP->new;
	
	$log->info("Fetching complement with downloader $url $mixcloud_url");
	
	$http->send_request( {
		request => HTTP::Request->new( POST => 'https://www.savelink.info/input', 
		                               [ 'User-Agent' => USER_AGENT, 'X-Requested-With' => 'XMLHttpRequest', 'Content-Type' => 'application/x-www-form-urlencoded' ], 
									   "url=$mixcloud_url" ),
		Timeout => 30,
		onBody  => sub {
				my $content = shift->response->content;
				my $json = eval { from_json($content) };

				if ($json && $json->{'link'}) {
					my $format = ($json->{'link'} =~ /.mp3/ ? "mp3" : "mp4");
					# need to re-read from cache in case TrackDetails have been updated
					$meta = $cache->get("mixcloud_item_$id") || {};
					# See comments regarding bitrate and type in makeCacheItem.
					# $meta->{'bitrate'} = $format eq 'mp3' ? '128k' : '64k';
					$meta->{'format'} = $format;
					$meta->{'type'} = "$format";
					$meta->{'url'} = $json->{'link'};
					$cache->set("mixcloud_item_extra_$id", $meta, META_CACHE_TTL);
					$meta->{'album'} = 'Mixcloud';
					
					$log->info("Got play URL $meta->{'url'} for $url from download");
				} else {
					$log->error("Empty response for play URL for $url", dump($json));
				}	
					
				$cb->($meta) if $cb;
		    },
		onError => sub {
				my ($self, $error) = @_;
				$log->error("Error getting play URL for $url => $error");
				$cb->() if $cb;
			},
		}
	);
	
	return $meta;
}

sub getMetadataFor {
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
		$log->info("Getting track details for $url", dump($item));
	
		Slim::Networking::SimpleAsyncHTTP->new(
		
			sub {
				my $track = eval { from_json($_[0]->content) };
				$log->warn($@) if ($@);
				makeCacheItem($client, $track, $args);
				$client->pluginData( fetchingMeta => 0 ) if $client;
			}, 
		
			sub {
				$client->pluginData( fetchingMeta => 0 ) if $client;
				$log->error("Error fetching track metadata for $url => $_[1]");
			},
		
			{ timeout => 30 },
		
		)->get($fetchURL);
	}	

	return {
		bitrate => '128kbps/64kbps',
		type => 'mp3/mp4 (Mixcloud)',
		icon => __PACKAGE__->getIcon,
	};
}

# Track Info menu
sub trackInfo {
	my ( $class, $client, $track ) = @_;

	my $url = $track->url;
	$log->debug("trackInfo: " . $url);
	return undef;
}

# Track Info menu
sub trackInfoURL {
	my ( $class, $client, $url ) = @_;
	$log->debug("trackInfoURL: " . $url);
	return undef;
}

# If an audio stream fails, keep playing
sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;

	main::INFOLOG && $log->info("Direct stream failed: $url [$response] $status_line");

	$client->controller()->playerStreamingFailed( $client, 'PLUGIN_MIXCLOUD_STREAM_FAILED' );
}

sub getIcon {
	my ( $class, $url, $noFallback ) = @_;

	my $handler;

	if ( ($handler = Slim::Player::ProtocolHandlers->iconHandlerForURL($url)) && ref $handler eq 'CODE' ) {
		return &{$handler};
	}

	return $noFallback ? '' : 'html/images/radio.png';
}

sub getId {
	my $url = shift;
	my ($id) = $url =~ m{^(?:mixcloud)://(.*)$};
	return $id;
}

sub makeCacheItem {
	my ($client, $json, $args) = @_;
	
	my $icon = __PACKAGE__->getIcon;
	my ($id) = ($json->{'key'} =~ /(?:\/)*(\S*)/);
	my $trackInfo = [];
	
	my $duration;
	if ($json->{'audio_length'}) {
		$duration = sprintf('%s:%02s:%02s', int($json->{'audio_length'} / 3600), int($json->{'audio_length'} / 60 % 60), int($json->{'audio_length'} % 60));
	}
	
	my $year;
	if ($json->{'updated_time'}) {
		$year = substr $json->{'updated_time'}, 0 , 4;
	} elsif ($json->{'created_time'}) {
		$year = substr $json->{'created_time'}, 0, 4;
	}
	
	push @$trackInfo, {
		name => cstring($client, 'TITLE') . cstring($client, 'COLON') . ' ' . $json->{'name'},
		play => "mixcloud://$id",
		type => 'text',
	};
	
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
		type => 'text',
	} if $json->{'url'};
	
	push @$trackInfo, {
		name => string('PLUGIN_MIXCLOUD_EXCLUSIVE') . cstring($client, 'COLON') . ' ' . ($json->{'is_exclusive'} eq 1 ? string('PLUGIN_MIXCLOUD_TRUE') : string('PLUGIN_MIXCLOUD_FALSE')),
		type => 'text',
	};
	
	push @$trackInfo, {
		type => 'link',
		name => cstring($client, 'ARTIST') . cstring($client, 'COLON') . ' ' . $json->{'user'}->{'name'},
		url  => \&Plugins::MixCloud::Plugin::tracksHandler,
		passthrough => [ { params => substr($json->{'user'}->{'key'},1) , type => 'user', parser => \&Plugins::MixCloud::Plugin::_parseUser } ]
	} if $json->{'user'}->{'key'};

	push @$trackInfo, {
		type => 'link',
		name => string('PLUGIN_MIXCLOUD_FAVORITE') . ' ' . string('PLUGIN_MIXCLOUD_TRACK'),
		url  => \&Plugins::MixCloud::Plugin::favoriteTrack,
		passthrough => [ { key => $json->{'key'}, type => 'text' } ]
	} if ($json->{'favorited'} =~ /0/);

	push @$trackInfo, {
		type => 'link',
		name => string('PLUGIN_MIXCLOUD_UNFAVORITE') . ' ' . string('PLUGIN_MIXCLOUD_TRACK'),
		url  => \&Plugins::MixCloud::Plugin::unfavoriteTrack,
		passthrough => [ { key => $json->{'key'}, type => 'text' } ]
	} if ($json->{'favorited'} =~ /1/);
	
	push @$trackInfo, {
		type => 'link',
		name => string('PLUGIN_MIXCLOUD_REPOST') . ' ' . string('PLUGIN_MIXCLOUD_TRACK'),
		url  => \&Plugins::MixCloud::Plugin::repostTrack,
		passthrough => [ { key => $json->{'key'}, type => 'text' } ]
	} if ($json->{'reposted'} =~ /0/);

	push @$trackInfo, {
		type => 'link',
		name => string('PLUGIN_MIXCLOUD_UNREPOST') . ' ' . string('PLUGIN_MIXCLOUD_TRACK'),
		url  => \&Plugins::MixCloud::Plugin::unrepostTrack,
		passthrough => [ { key => $json->{'key'}, type => 'text' } ]
	} if ($json->{'reposted'} =~ /1/);
	
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
		# There's no way to derive bitrate and type until the stream headers are read.
		# If bitrate and type fields are set here then they are not updated correctly with data from the headers.
		# The web UI doesn't update these fields until after the stream starts and the user interacts but cannot be fixed here.
		# bitrate => '128kbps/64kbps',
		# type => 'mp3/mp4',
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
	my $simpleTracks = (($args->{params} && $args->{params}->{isWeb} && preferences('server')->get('skin')=~ /Classic|EN/i) ? 1 : 0);
	if (!$simpleTracks) {
        $item->{'items'} = $trackInfo;
    }
	
	# Replace some fields if the call comes from Plugin.pm but do not cache.
	if ($args->{params} && $args->{params}->{isPlugin}) {
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
