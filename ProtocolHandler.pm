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

	#if (defined($self)) {
	#	${*$self}{'client'}  = $client;
	#	${*$self}{'song'}  = $song;
	#	${*$self}{'url'}     = $streamUrl;
	#}

	return $self;
}
sub isPlaylistURL { 0 }
sub isRemote { 1 }

sub getFormatForURL {
	my ($class, $url) = @_;		
	my ($trackId) = $url =~ m{^mixcloud://(.*)$};
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
	my ($trackhome) = $url =~ m{^mixcloud:/(.*)$};
	#$log->debug("Fetching Trackhome:".$trackhome);	
	my $cache = Slim::Utils::Cache->new;	
	my $trackurl = "";
	my $urldata = $cache->get('mixcloud_meta_urls' . $trackhome);
	my $format = $prefs->get('playformat');
	my $firstFormat = $prefs->get('playformat');
	if ($urldata) {
		#$log->debug ("got cache url". 'mixcloud_meta_urls ' . $trackhome);
		if (defined $urldata->{$firstFormat."_url"}) {
			$trackurl = $urldata->{$firstFormat."_url"};
			$format = $firstFormat;
		}else{
			my $secondFormat = ($firstFormat eq "mp3"?"mp4":"mp3");
			if (defined $urldata->{$secondFormat."_url"}) {
				$trackurl = $urldata->{$secondFormat."_url"};
				$format = $secondFormat;
			}
		}
	}
	if ($trackurl eq "") {
		my $ua = LWP::UserAgent->new;
		$ua->agent("Mozilla/5.0 (Windows NT 6.3; WOW64; rv:33.0) Gecko/20100101 Firefox/33.0");
		my $url = "https://www.mixcloud.com/".$trackhome;
		#my $content = get($url);
		my $response = $ua->get($url);
		#$log->debug($response->decoded_content);
		my $content = $response->decoded_content;
		$content =~ m/(?<=\.mixcloud\.com\/previews\/)([^\.]+\.mp3)/i;			
		my $trackid = substr($1,0,-4);
		$ua->timeout(5);
		$log->debug("Mixcloud TrackId: ".$1);
		my $found = 0;
		my $m4aurl = "/c/m4a/64/".$trackid.".m4a";
		my $mp3url = "/c/originals/".$trackid.".mp3";
		for (my $i=1; $i <= 50; $i++) {
			$trackurl = "http://stream".$i.".mixcloud.com";
			if($firstFormat eq "mp3"){
				$trackurl = $trackurl.$mp3url;
			}else{
				$trackurl = $trackurl.$m4aurl;
			}
			$log->debug("Trying TrackUrl: ".$trackurl);
			my $response = $ua->head($trackurl);
			if ($response->is_success) {
				$found = 1;
				$log->debug("Got Mixcloud TrackUrl: ".$trackurl);
				last;
			} else {
				#print "Does not exist or timeout\n";;
			}
		}
		if ($found == 0) {			
			$log->warn("Failed to find track in perfered format $firstFormat. Trying ".($firstFormat eq "mp3" ? "mp4" : "mp3")." format");
			for (my $i=1; $i <= 50; $i++) {
				$trackurl = "http://stream".$i.".mixcloud.com";
				if($firstFormat eq "mp4"){
					$format = "mp3";
					$trackurl = $trackurl.$mp3url;
				}else{
					$format = "mp4";
					$trackurl = $trackurl.$m4aurl;
				}
				$log->debug("Trying TrackUrl: ".$trackurl);
				my $response = $ua->head($trackurl);
				if ($response->is_success) {
					$found = 1;
					$log->debug("Got Mixcloud TrackUrl: ".$trackurl);
					last;
				} else {
					#print "Does not exist or timeout\n";;
				}
			}	
		}
		if ($found == 1) {		
			$log->debug("setting cache ". 'mixcloud_meta_urls ' . $trackhome);
			if ($urldata) {
				$urldata->{$format."_url"}=$trackurl;
			}else{
				$urldata = {
					$format."_url" => $trackurl
				}
			}		
			$cache->set( 'mixcloud_meta_urls' . $trackhome, $urldata, 86400 );
			$log->info("Found track format $format at URL: $trackurl");
		}
	}
	
	my $trackdata = {url=>$trackurl,format=>$format,bitrate=>$format eq "mp3"?320000:70000};
	my $track = Slim::Schema::RemoteTrack->fetch($url);
	if ($track) {
		my $obj = Slim::Schema::RemoteTrack->updateOrCreate($url, {
					bitrate   => ($trackdata->{'bitrate'}/1000).'kbps',
					type      => uc($trackdata->{'format'}).' (Mixcloud)',
					stash => {format => $trackdata->{'format'},formaturl=>$trackdata->{'url'},bitrate=>$trackdata->{'bitrate'}}
				});
	}
	return $trackdata;
}
sub getMetadataFor {
	my ($class, $client, $url, undef, $fetch) = @_;
	$log->debug("getMetadataFor: ".$url);
	my $track = Slim::Schema::RemoteTrack->fetch($url);	
	if ($track && $track->stash->{'meta'}) {
		$log->debug("known getMetadataFor for track: ".$track->title);
		my $ret = {
			title    => $track->title,
			artist   => $track->artist,
			album    => " ",
			duration => $track->secs,
			icon     => $track->cover,
			image => $track->cover,
			cover    => $track->cover,
			bitrate  => $track->bitrate,
			type     => $track->type,
			#albumuri => $track->stash->{'albumuri'},
			#artistA  => $track->stash->{'artists'},
		};
		return $ret;
	} else {
		$log->debug("need to fetch meta for $url");
		_fetchMeta($url);
	}
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

			my $obj;
			my $format = "MP3 (Mixcloud)";
			my $trackurl = "";
			my $bitrate = 70000;		
			$log->debug("caching meta for $format with URL $url new track url ".$trackurl);
			my $secs = int($track->{'audio_length'});
			my $icon = "";
			if (defined $track->{'pictures'}->{'large'}) {
				$icon = $track->{'pictures'}->{'large'};
			}else{
				if (defined $track->{'pictures'}->{'medium'}) {
					$icon = $track->{'pictures'}->{'medium'};
				}
			}
			$obj = Slim::Schema::RemoteTrack->updateOrCreate($url, {
				title   => $track->{'name'}.($track->{'created_time'}?" : ".substr($track->{'created_time'},0,10):""),
				artist  => $track->{'user'}->{'username'},
				album   => " ",
				secs    => $secs,
				cover   => $icon,
				stash => {meta => 1}
			});			
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
		"User-Agent: Mozilla/5.0 (Windows NT 6.3; WOW64; rv:33.0) Gecko/20100101 Firefox/33.0" , 
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
