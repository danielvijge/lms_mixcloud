package Plugins::MixCloud::ProtocolHandler;

# Plugin to stream audio from MixCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by Christian Müller
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

use constant PAGE_URL_REGEXP => qr{^https?://(?:www|m)\.mixcloud\.com/};
use constant USER_AGENT => 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10.13; rv:56.0; SlimServer) Gecko/20100101 Firefox/56.0';

my $log   = logger('plugin.mixcloud');
my $prefs = preferences('plugin.mixcloud');
my $cache = Slim::Utils::Cache->new;

Slim::Player::ProtocolHandlers->registerURLHandler(PAGE_URL_REGEXP, __PACKAGE__);

sub isPlaylistURL { 0 }

sub canDirectStream { 
	return 0 if $prefs->get('useBuffered') && !Slim::Player::Protocols::HTTP->can('response');
	return shift->SUPER::canDirectStream(@_);
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
	my $streamUrl = $song->streamUrl() || return;
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
	my $url = $song->currentTrack()->url;
	
	_fetchTrackExtra($url, sub {
			my $meta = shift;
			return $successCb->() unless $meta;
			
			$song->_streamFormat($meta->{'format'});
			$song->streamUrl($meta->{'url'});
			$song->bitrate($meta->{'bitrate'} * 1000);			
	
			if ($meta->{'format'} =~ /mp3|mp4|aac/i) {
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
			                             $meta->{bitrate} = int($song->track->bitrate/1000) . 'k';
			                             $cache->set('mixcloud_item_' . getId($url), $meta, '1day');
			                             $successCb->(); 
									 } },
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
	my $meta = $cache->get("mixcloud_item_$id") || {};
	
	$log->debug("Getting complement for $url => $id");	
	
	# we already have everything
	if ( $meta->{'url'} ) {
		$log->debug("Got play URL $meta->{'url'} for $url from cache");
		$cb->($meta) if $cb;
		return $meta;
	}
	
	my $mixcloud_url = "https://www.mixcloud.com/$id";
	my $http = Slim::Networking::Async::HTTP->new;
	
	$log->info("Fetching complement with downloader $url $mixcloud_url");
	
	$http->send_request( {
		request => HTTP::Request->new( POST => 'https://www.dlmixcloud.com/ajax.php', 
		                               [ 'User-Agent' => USER_AGENT, 'Content-Type' => 'application/x-www-form-urlencoded' ], 
									   "url=$mixcloud_url" ),
		Timeout => 30, 								
		onBody  => sub {
				my $content = shift->response->content;
				my $json = eval { from_json($content) };

				if ($json && $json->{'url'}) {
					my $format = ($json->{url} =~ /.mp3/ ? "mp3" : "mp4");

					# need to re-read from cache in case TrackDetails have been updated
					$meta = $cache->get("mixcloud_item_$id") || {};
					$meta->{'bitrate'} = $format eq 'mp3' ? '320k' : '70k';
					$meta->{'format'} = $format;
					$meta->{'type'} = "$format";
					$meta->{'url'} = $json->{'url'};
					$cache->set("mixcloud_item_$id", $meta, '1day');

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
	my ($class, $client, $url) = @_;
	
	my $id = getId($url);
	my $item = $cache->get("mixcloud_item_$id");
	
	return $item if $item && $item->{'play'};
	
	if (!$client->pluginData('fetchingMeta')) {
		my $fetchURL = "https://api.mixcloud.com/$id";

		$client->pluginData( fetchingMeta => 1 ) if $client;
		$log->info("Getting track details for $url", dump($item));
	
		Slim::Networking::SimpleAsyncHTTP->new(
		
			sub {
				my $track = eval { from_json($_[0]->content) };
				$log->warn($@) if ($@);
				$client->pluginData( fetchingMeta => 0 ) if $client;
				makeCacheItem($track, '1day');
			}, 
		
			sub {
				$client->pluginData( fetchingMeta => 0 ) if $client;
				$log->error("Error fetching track metadata for $url => $_[1]");
			},
		
			{ timeout => 30 },
		
		)->get($fetchURL);
	}	

	return {
		bitrate => '320kbps/70kbps',
		type => 'MP3/MP4 (Mixcloud)',
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
	my ($json, $cache_duration) = @_;

	my $icon = __PACKAGE__->getIcon;
	my ($id) = ($json->{'key'} =~ /(?:\/)*(\S*)/);	
	
	if (defined $json->{'pictures'}->{'large'}) {
		$icon = $json->{'pictures'}->{'large'};
	} elsif (defined $json->{'pictures'}->{'medium'}) {
		$icon = $json->{'pictures'}->{'medium'};
	}
	
	my $item = {
		duration => $json->{'audio_length'},
		name => $json->{'name'},
		title => $json->{'name'},
		artist => $json->{'user'}->{'username'},
		play => "mixcloud://$id",
		bitrate => '320kbps/70kbps',
		type => 'mp3/mp4 (mixcloud)',
		passthrough => [ { key => $json->{'key'}} ],
		icon => $icon,
		image => $icon,
		cover => $icon,
		on_select => 'play',
	};

	# Set meta cache here, so that playlist does not have to query each track 
	# individually althoughsmall risk to overwrite the trackDetail query
	$log->debug("Caching mixcloud_item_$id", dump($item));
	$cache->set("mixcloud_item_$id", $item, $cache_duration || '10min');

	return $item;
}


1;
