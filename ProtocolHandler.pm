package Plugins::MixCloud::ProtocolHandler;

# Plugin to stream audio from MixCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by Christian Müller
# 
# See file LICENSE for full license details

use strict;

use base qw(Slim::Player::Protocols::HTTPS);
use List::Util qw(min max);
use LWP::Simple;
use LWP::UserAgent;
use HTML::Parser;
use URI::Escape;
use JSON::XS::VersionOneAndTwo;
use XML::Simple;
use IO::Socket qw(:crlf);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Errno;
use Slim::Utils::Cache;
use Scalar::Util qw(blessed);

use constant PAGE_URL_REGEXP => qr{^https?://(?:www|m)\.mixcloud\.com/};

my $log   = logger('plugin.mixcloud');
my $prefs = preferences('plugin.mixcloud');

Slim::Player::ProtocolHandlers->registerURLHandler(PAGE_URL_REGEXP, __PACKAGE__);

$prefs->init({ apiKey => "", playformat => "mp4"});

sub new {
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};
	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;
	my $track     = $song->pluginData();
	$log->info( 'Remote streaming Mixcloud track: ' . $streamUrl );
	
	my $self = $class->open({
		url => $streamUrl,
		song    => $song,
		client  => $client,
	});

	return $self;
}
sub isPlaylistURL { 0 }

=comment
This plugin should be able to do direct streaming when the player accepts mp3/mp4 but the issue is 
that it requires a special user-agent to be set. The logical solution is to overload the requestString
method but it only works when using proxied streaming because Squeezebox.pm does call the protocol 
handler requestString method instead of the song's protocol handler method. I think this is incorrect 
but the result is that in direct streaming, there is no protocol handler created so the requestString
called is the base class of this package with fails as the player's request uses the wrong UA
=cut
sub canDirectStream { 0 };

sub getFormatForURL {
	my ($class, $url) = @_;		
	my $trackinfo = getTrackUrl($url);
	return $trackinfo->{'format'};	
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
		
	my $client = $song->master();
	my $url    = $song->currentTrack()->url;
	my $trackinfo = getTrackUrl($url);
	$log->debug("formaturl: ".$trackinfo->{'url'});
	$song->bitrate($trackinfo->{'bitrate'});
	$song->_streamFormat($trackinfo->{'format'});
	$song->streamUrl($trackinfo->{'url'});
	
	if ($trackinfo->{'format'} =~ /mp4|aac/i) {
		my $http = Slim::Networking::Async::HTTP->new;
		$http->send_request( {
			request     => HTTP::Request->new( GET => $trackinfo->{'url'}, [ 'User-Agent' => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.13; rv:56.0; SlimServer) Gecko/20100101 Firefox/56.0" ] ),
			onStream    => \&Slim::Utils::Scanner::Remote::parseMp4Header,
			onError     => sub {
				my ($self, $error) = @_;
				$log->warn( "could not find $trackinfo->{'url'} header with format $trackinfo->{'format'} $error" );
				$successCb->();
			},
			passthrough => [ $song->track, { cb => sub {
			                                    my $cache = Slim::Utils::Cache->new;
			                                    my $meta = $cache->get('mixcloud_meta_' . $song->track->url);
			                                    $meta->{bitrate} = sprintf("%.0f" . Slim::Utils::Strings::string('KBPS'), $song->track->bitrate/1000);
			                                    $cache->set( 'mixcloud_meta_' . $song->track->url, $meta, 86400 );
			                                    $successCb->(); 
											} },						  
			                 $trackinfo->{'url'} ],
		} );
	} else {
		$successCb->();
	}
}

sub getTrackUrl{
	my $url = shift;
	my ($trackhome) = $url =~ m{^(?:mixcloud)://(.*)$};
	$log->debug("Fetching Trackhome: $trackhome for $url");	
	return unless $trackhome;
	
	my $cache = Slim::Utils::Cache->new;
	my $trackurl = "";
	my $format = $prefs->get('playformat');
	my $meta = $cache->get( 'mixcloud_meta_' . $url );
	if ( $meta->{'url'} ) {
		$log->debug("Got play URL from cache, not retrieving again");
		$trackurl = $meta->{'url'};
	}

	if ($trackurl eq "") {
		my $ua = LWP::UserAgent->new;
		$ua->agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10.13; rv:56.0; SlimServer) Gecko/20100101 Firefox/56.0");
		my $url = "https://www.dlmixcloud.com/ajax.php";
		my $mixcloud_url = "https://www.mixcloud.com/$trackhome";
		$log->debug("Fetching for downloader $url");
		my $response = $ua->post($url, ["url" => $mixcloud_url]);
		my $content = $response->decoded_content;
		$log->debug($content);
		my $json = eval { from_json($content) };
		$trackurl = $json->{"url"};
		$log->debug("Mixcloud URL from downloader: $trackurl");
		if ( $trackurl eq '' ) {
			$log->error("Error: Cannot get play URL for $trackhome from $url");
			return;
		}
	}

	my $format = "mp4";
	if (index($trackurl, '.mp3') != -1) {
		$format = "mp3";
	}
	
	my $trackdata = {url=>$trackurl,format=>$format,bitrate=>$format eq "mp3"?320000:70000};

	$meta->{'bitrate'} = ($trackdata->{'bitrate'}/1000).'kbps';
	$meta->{'type'} = uc($trackdata->{'format'}).' (Mixcloud)';
	$meta->{'url'} = $trackdata->{'url'};
	$log->debug("updating ". 'mixcloud_meta_' . $url);
	$cache->set( 'mixcloud_meta_' . $url, $meta, 3600 );

	return $trackdata;
}
sub getMetadataFor {
	my ($class, $client, $url, undef, $fetch) = @_;
	
	my $cache = Slim::Utils::Cache->new;
	$log->debug("getting ". 'mixcloud_meta_' . $url);
	my $meta = $cache->get( 'mixcloud_meta_' . $url );

	return $meta if $meta;

	$log->debug('mixcloud_meta_' . $url .' not in cache. Fetching metadata...');
	_fetchMeta($url);

	return {};
}

sub _fetchMeta {
	my $url    = shift;
	
	my ($trackhome) = $url =~ m{^mixcloud://(.*)$};
	my $fetchURL = "http://api.mixcloud.com/" . $trackhome ;
	$log->debug("fetching meta for $url with $fetchURL");
	Slim::Networking::SimpleAsyncHTTP->new(
		
		sub {
			my $track = eval { from_json($_[0]->content) };
			
			if ($@) {
				$log->warn($@);
			}

			my $icon = "";
			if (defined $track->{'pictures'}->{'large'}) {
				$icon = $track->{'pictures'}->{'large'};
			}else{
				if (defined $track->{'pictures'}->{'medium'}) {
					$icon = $track->{'pictures'}->{'medium'};
				}
			}

			my $DATA = {
				duration => $track->{'audio_length'},
				name => $track->{'name'},
				title => $track->{'name'},
				artist => $track->{'user'}->{'username'},
				album => " ",
				play => "mixcloud:/" . $track->{'key'},
				bitrate => '320kbps/70kbps',
				type => 'MP3/MP4 (Mixcloud)',
				passthrough => [ { key => $track->{'key'}} ],
				icon => $icon,
				image => $icon,
				cover => $icon,
				on_select => 'play',
			};

			# Already set meta cache here, so that playlist does not have to
			# query each track individually
			my $cache = Slim::Utils::Cache->new;
			$log->debug("setting ". 'mixcloud_meta_' . $DATA->{'play'});
			$cache->set( 'mixcloud_meta_' . $DATA->{'play'}, $DATA, 3600 );
		}, 
		
		sub {
			$log->error("error fetching track data: $_[1]");
		},
		
		{ timeout => 35 },
		
	)->get($fetchURL);
}
sub scanUrl {
	my ($class, $url, $args) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
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

1;
