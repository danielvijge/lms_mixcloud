package Plugins::MixCloud::ProtocolHandler;

# Plugin to stream audio from MixCloud streams
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by Christian Müller
# 
# See file LICENSE for full license details

use strict;

use base qw(Slim::Formats::RemoteStream);
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
use Data::Dumper;
use Scalar::Util qw(blessed);

my $log   = logger('plugin.mixcloud');


use strict;
Slim::Player::ProtocolHandlers->registerHandler('mixcloud', __PACKAGE__);
Slim::Player::ProtocolHandlers->registerHandler('mixcloudd' => 'Plugins::MixCloud::ProtocolHandlerDirect');
my $prefs = preferences('plugin.mixcloud');
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
sub isRemote { 1 }

sub getFormatForURL {
	my ($class, $url) = @_;		
	my $trackinfo = getTrackUrl($url);
	return $trackinfo->{'format'};	
}

#sub formatOverride {
#	my ($class, $song) = @_;
#	my $url = $song->currentTrack()->url;
#	$log->debug("-----------------------------------------------------Format Override Songurl: ".$song->_streamFormat()."-----".$url);
#	return $song->_streamFormat();
#}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
		
	my $client = $song->master();
	my $url    = $song->currentTrack()->url;
	my $trackinfo = getTrackUrl($url);
	$log->debug("formaturl: ".$trackinfo->{'url'});
	$song->bitrate($trackinfo->{'bitrate'});
	$song->_streamFormat($trackinfo->{'format'});
	$song->streamUrl($trackinfo->{'url'});
	$successCb->();
}

sub getTrackUrl{
	my $url = shift;
	my ($trackhome) = $url =~ m{^mixcloud://(.*)$};
	$log->debug("Fetching Trackhome: ".$trackhome);	
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
		my $url = "http://www.mixcloud-downloader.com/".$trackhome;
		$log->debug("Fetching for downloader ".$url);
		my $response = $ua->get($url);
		my $content = $response->decoded_content;
		#$log->debug($content);
		my @regex = ( $content =~ m/\"(https?:\/\/stream[\s\S]+)\"/is );
		$log->debug("Mixcloud URL from downloader: " . $regex[0] );
		if ( $regex[0] eq '' ) {
			$log->error('Error: Cannot get play URL for '.$trackhome.' from '.$url);
			return;
		}
		$trackurl = $regex[0];
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

sub canDirectStreamSong{
	my ($classOrSelf, $client, $song, $inType) = @_;
	
	# When synced, we don't direct stream so that the server can proxy a single
	# stream for all players
	if ( $client->isSynced(1) ) {

		if ( main::INFOLOG && $log->is_info ) {
			$log->info(sprintf(
				"[%s] Not direct streaming because player is synced", $client->id
			));
		}

		return 0;
	}

	# Allow user pref to select the method for streaming
	if ( my $method = $prefs->client($client)->get('mp3StreamingMethod') ) {
		if ( $method == 1 ) {
			main::DEBUGLOG && $log->debug("Not direct streaming because of mp3StreamingMethod pref");
			return 0;
		}
	}
	my $ret = $song->streamUrl();
	my ($server, $port, $path, $user, $password) = Slim::Utils::Misc::crackURL($ret);
	my $host = $port == 80 ? $server : "$server:$port";
	#$song->currentTrack()->url = $ret;
	#return 0;
	return "mixcloudd://$host:$port$path";
}
# If an audio stream fails, keep playing
sub handleDirectError {
	my ( $class, $client, $url, $response, $status_line ) = @_;

	main::INFOLOG && $log->info("Direct stream failed: $url [$response] $status_line");

	$client->controller()->playerStreamingFailed( $client, 'PLUGIN_SQUEEZECLOUD_STREAM_FAILED' );
}
sub getIcon {
	my ( $class, $url, $noFallback ) = @_;

	my $handler;

	if ( ($handler = Slim::Player::ProtocolHandlers->iconHandlerForURL($url)) && ref $handler eq 'CODE' ) {
		return &{$handler};
	}

	return $noFallback ? '' : 'html/images/radio.png';
}
sub parseDirectHeaders {
	my ($class, $client, $url, @headers) = @_;
	my ($redir, $contentType, $length,$bitrate);
	foreach my $header (@headers) {
	
		# Tidy up header to make no stray nulls or \n have been left by caller.
		$header =~ s/[\0]*$//;
		$header =~ s/\r/\n/g;
		$header =~ s/\n\n/\n/g;

		$log->debug("header-ds: $header");
	
		if ($header =~ /^Location:\s*(.*)/i) {
			$redir = $1;
		}
		
		elsif ($header =~ /^Content-Type:\s*(.*)/i) {
			$contentType = $1;
		}
		
		elsif ($header =~ /^Content-Length:\s*(.*)/i) {
			$length = $1;
		}
	}
	
	$contentType = Slim::Music::Info::mimeToType($contentType);
	$log->debug("DIRECT HEADER: ".$contentType);
	if ( !$contentType ) {
		$contentType = 'mp3';
	}elsif($contentType eq 'mp4'){
		$contentType = 'aac';	
	}
	$bitrate = $contentType eq "mp3"?320000:70000;
	return (undef, $bitrate, undef, undef, $contentType,$length);
}
sub parseHeaders {
	my ($class, $client, $url, @headers) = @_;
	my ($title, $bitrate, $metaint, $redir, $contentType, $length, $body) = $class->parseDirectHeaders($client, $url, @_);
	return (undef, undef, undef, undef, $contentType);
}

sub requestString {
	my $self   = shift;
	my $client = shift;
	my $url    = shift;
	my $post   = shift;
	my $seekdata = shift;

	my ($server, $port, $path, $user, $password) = Slim::Utils::Misc::crackURL($url);

	# Although the port can be part of the Host: header, some hosts (such
	# as online.wsj.com don't like it, and will infinitely redirect.
	# According to the spec, http://www.w3.org/Protocols/rfc2616/rfc2616-sec14.html
	# The port is optional if it's 80, so follow that rule.
	my $host = $port == 80 ? $server : "$server:$port";
	# make the request
	my $request = join($CRLF, (
		"GET $path HTTP/1.1",
		"Accept: */*",
		#"Cache-Control: no-cache",
		"User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10.13; rv:56.0; SlimServer) Gecko/20100101 Firefox/56.0" , 
		#"Icy-MetaData: $want_icy",
		"Connection: close",
		"Host: $host",
	));
	
	# If seeking, add Range header
	if ($client && $seekdata) {
		$request .= $CRLF . 'Range: bytes=' . int( $seekdata->{sourceStreamOffset} +  $seekdata->{restartOffset}) . '-';
		
		if (defined $seekdata->{timeOffset}) {
			# Fix progress bar
			$client->playingSong()->startOffset($seekdata->{timeOffset});
			$client->master()->remoteStreamStartTime( Time::HiRes::time() - $seekdata->{timeOffset} );
		}

		$client->songBytes(int( $seekdata->{sourceStreamOffset} ));
	}
	$request .= $CRLF . $CRLF;		
	$log->debug($request);
	return $request;
}

sub canSeek {
	my ( $class, $client, $song ) = @_;

	my $url = $song->currentTrack()->url;
	my $ct = Slim::Music::Info::contentType($url);

	if ( $ct eq 'mp3') {
		return 1;
	}
	else {
		return 0;
	}
}

sub canSeekError {
	my ( $class, $client, $song ) = @_;
	
	my $url = $song->currentTrack()->url;
	
	my $ct = Slim::Music::Info::contentType($url);
	
	if ( $ct ne 'mp3' ) {
		return ( 'SEEK_ERROR_TYPE_NOT_SUPPORTED', $ct );
	} 
	
	if ( !$song->bitrate() ) {
		main::INFOLOG && $log->info("bitrate unknown for: " . $url);
		return 'SEEK_ERROR_MP3_UNKNOWN_BITRATE';
	}
	elsif ( !$song->duration() ) {
		return 'SEEK_ERROR_MP3_UNKNOWN_DURATION';
	}
	
	return 'SEEK_ERROR_MP3';
}

sub getSeekData {
	my ( $class, $client, $song, $newtime ) = @_;
	
	# Determine byte offset and song length in bytes
	my $bitrate = $song->bitrate() || return;
		
	$bitrate /= 1000;
		
	main::INFOLOG && $log->info( "Trying to seek $newtime seconds into $bitrate kbps" );
	
	return {
		sourceStreamOffset   => (( $bitrate * 1000 ) / 8 ) * $newtime,
		timeOffset           => $newtime,
	};
}

sub getSeekDataByPosition {
	my ($class, $client, $song, $bytesReceived) = @_;
	
	my $seekdata = $song->seekdata() || {};
	
	return {%$seekdata, restartOffset => $bytesReceived};
}

1;
