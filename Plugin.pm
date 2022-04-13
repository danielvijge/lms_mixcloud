package Plugins::MixCloud::Plugin;

# Plugin to stream audio from Mixcloud
#
# Released under GNU General Public License version 2 (GPLv2)
#
# Written by Christian Mueller (first release), 
#   Daniel Vijge (improvements),
#   KwarkLabs (added functionality)
#
# See file LICENSE for full license details

use strict;

use base qw(Slim::Plugin::OPMLBased);
use utf8;

use URI::Escape;
use JSON::XS::VersionOneAndTwo;

use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);
use Date::Parse;
use Data::Dump qw(dump);

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Plugin::OPMLBased;

use Plugins::MixCloud::ProtocolHandler;

my $CLIENT_ID = "2aB9WjPEAButp4HSxY";
my $CLIENT_SECRET = "scDXfRbbTyDHHGgDhhSccHpNgYUa7QAW";
my $token = "";
my $cache;

my $prefs = preferences('plugin.mixcloud');
my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.mixcloud',
	'defaultLevel' => 'ERROR',
	'description'  => string('PLUGIN_MIXCLOUD'),
});

$prefs->init({ apiKey => "", playformat => "mp4", useBuffered => 1 });

sub getToken {
	my ($callback) = shift;
	if ($prefs->get('apiKey')) {
		my $tokenurl = "https://www.mixcloud.com/oauth/access_token?client_id=".$CLIENT_ID."&redirect_uri=https://danielvijge.github.io/lms_mixcloud/app.html&client_secret=".$CLIENT_SECRET."&code=".$prefs->get('apiKey');
		$log->debug("gettokenurl: ".$tokenurl);
		Slim::Networking::SimpleAsyncHTTP->new(			
				sub {
					my $http = shift;				
					my $json = eval { from_json($http->content) };
					if ($json->{"access_token"}) {
						$token = $json->{"access_token"};
						$log->debug("token: ".$token);
					}				
					$callback->({token=>$token});	
				},			
				sub {
					$log->error("Error: $_[1]");
					$callback->({});
				},			
		)->get($tokenurl);
	}else{
		$callback->({});	
	}
}

sub _provider {
	my ($client, $url, $args) = @_;
	return Plugins::MixCloud::ProtocolHandler::getMetadataFor($client, $url, $args);
}

sub _parseTracks {
	my ($client, $json, $menu) = @_;
	my $args = { params => {isPlugin => 1}};
	my $data = $json->{'data'}; 
	for my $entry (@$data) {
		push @$menu, Plugins::MixCloud::ProtocolHandler::makeCacheItem($client, $entry, $args);
	}
}

sub tracksHandler {
	my ($client, $callback, $args, $passDict) = @_;

	my $index    = ($args->{'index'} || 0); # ie, offset
    
	my $quantity = $args->{'quantity'} || 200;
	my $total = $args->{'total'} || '';
	my $searchType = $passDict->{'type'};

	my $parser = $passDict->{'parser'} || \&_parseTracks;
	my $params = $passDict->{'params'} || '';

	$log->debug('search type: ' . $searchType);
	$log->debug("index: " . $index);
	$log->debug("quantity: " . $quantity);
	$log->debug("params: " . $params);

	my $menu = [];

	my $max = min($quantity - scalar @$menu, 200); # api allows max of 200 items per response
	$log->debug("max: " . $max);
	my $method = "https";
	my $uid = $passDict->{'uid'} || '';
	my $resource = "";
	if ($searchType =~ /^categories/) {
		# limit on categories API call is not honored.
		if ($params eq "") {
			$resource = "categories";
		}else{
			# This gets the contents of a category.
			# Only categories 1 to 40 will be returned regardless of offset and limit parameters.
			$resource = $params;
			$params = "";
		}			
	}
	
	if ($searchType eq 'search') {
		$resource = "search";
		$params = "&q=".$args->{'search'}."&type=cloudcast"; 
	}
	
	if ($searchType eq 'usersearch') {
		$resource = "search";
		$params = "&q=".$args->{'search'}."&type=user"; 
	}
	
	if ($searchType eq 'tags') {
		if ($params eq "") {
			$resource = "search";
			$params = "&q=".$args->{'search'}."&type=tag";
		}else{
			$resource = $params;
			$params = "";
		}			 
	}
	if ($searchType eq 'following' || $searchType eq 'favorites' || $searchType eq 'cloudcasts' || $searchType eq 'user') {
		$resource = $params;
		$params = '';
		if (substr($resource,0,2) eq 'me') {
			if ($token ne "") {
				$method = "https";
				$params = "";
			}				
		}		
	}
	
	my $queryUrl;
	if ($quantity == 1) {
        $queryUrl = "$method://api.mixcloud.com/$resource?offset=$index&limit=$quantity" . $params;
    } else {
		$queryUrl = "$method://api.mixcloud.com/$resource?limit=$quantity" . $params;
	}
    
	# Adding the token to the end of each request returns more details
	if ($token ne '') {
        $queryUrl .=   "&access_token=" . $token;
    }
	
	$log->info("Fetching $queryUrl");
	
	_getTracks($client, $searchType, $index, $quantity, $queryUrl, 0, $parser, $callback, $menu, $total);
}
		
sub _getTracks {
	$log->debug('_getTracks started.');
	my ($client, $searchType, $index, $quantity, $queryUrl, $cursor, $parser, $callback, $menu, $total) = @_;
	
	Slim::Networking::SimpleAsyncHTTP->new(
		
		sub {
			my $http = shift;				
			my $json = eval { from_json($http->content) };
			
			my $nextPage = $json->{'paging'}->{'next'} || '';
			$log->debug('_getTracks next page: ' . $nextPage);

			$parser->($client, $json, $menu, $searchType);

			if ($total eq '') {
				# This limits search results to 400
				$total = 400;
            } elsif ($searchType =~ /^categories/) {
                $total = @$menu;
            } elsif (scalar @$menu <= $quantity ) {
				$total = $index + @$menu;
				$log->debug("short page, truncate total to $total");
			}
			
			$log->debug("this page: " . scalar @$menu . " total: $total" . " quantity: " . $quantity);
			
			# Unless fetching just one track then we need to recursively call _getTracks to calculate the total number.
			if ((($total >= $quantity || $total % $quantity != 0) && $nextPage eq '') || $quantity == 1 || scalar @$menu >= $total) {
				if ($searchType eq 'user') {
					$callback->($menu);
				}else{
					_callbackTracks($menu, $index, $quantity, $callback);
				}
			} else {
				$cursor = $total + 1;
				_getTracks($client, $searchType, $index, $quantity, $nextPage, $cursor, $parser, $callback, $menu, $total);
			}
		},			
		sub {
			$log->error("error: $_[1]");
			$callback->([ { name => $_[1], type => 'text' } ]);
		},
		
	)->get($queryUrl);
	
	$log->debug('_getTracks ended.');
}

sub _callbackTracks {
	$log->debug('_callbackTracks started.');
	my ( $menu, $index, $quantity, $callback ) = @_;

	my $total = scalar @$menu;
	if ($quantity ne 1) {
        $quantity = min($quantity, $total - $index);
    }	
	
	my $returnMenu = [];
	
	if (scalar @$menu == 1) {
        $returnMenu = $menu;
    } else {	
		my $i = 0;
		my $count = 0;
		for my $entry (@$menu) {
			if ($i >= $index && $count < $quantity) {
				push @$returnMenu, $entry;
				$count++;
			}
			$i++;
		}
	}
	$callback->({
		items  => $returnMenu,
		offset => $index,
		total  => $total,
	});
    $log->debug('_callbackTracks ended.');
}

sub urlHandler {
	my ($client, $callback, $args) = @_;

	my $url = $args->{'search'};
	
	$url =~ s/ com/.com/;
	$url =~ s/www /www./;
	$url =~ s/http:\/\/ /https:\/\//;
	my ($id) = $url =~ m{^https://(?:www|m).mixcloud.com/(.*)$};
	my $queryUrl = "https://api.mixcloud.com/" . $id ;
	return unless $id;

	$log->debug("fetching $queryUrl");

	my $fetch = sub {
		Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $http = shift;
				my $item = eval { from_json($http->content) };
				$log->warn($@) if $@;
				my $args = { params => {isPlugin => 1}};
				$callback->( { items => [ Plugins::MixCloud::ProtocolHandler::makeCacheItem($client, $item, $args) ] } );
			},
			sub {
				$log->error("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},
		)->get($queryUrl);
	};
		
	$fetch->();
}

sub _parseCategories {
	my ($client, $json, $menu, $searchType) = @_;
	my $i = 0;
	my $data = $json->{'data'};
	# Ensure that categories are sorted by name.
	$data = [ sort { uc($a->{name}) cmp uc($b->{name}) } @$data ];
	for my $entry (@$data) {
		my $format = $entry->{'format'};
		if ($searchType =~ /$format$/) {
			my $name = $entry->{'name'};
			my $slug = $entry->{'slug'};
			my $url = $entry->{'url'};
			my $key = substr($entry->{'key'},1)."cloudcasts/";
	
			push @$menu, {
				name => $name,
				type => 'link',
				url => \&tracksHandler,
				passthrough => [ { type => 'categories', params => $key} ]
			};
        }        
	}
}

sub _parseTags {
	my ($client, $json, $menu) = @_;
	my $i = 0;
	my $data = $json->{'data'};	
	for my $entry (@$data) {
		my $name = $entry->{'name'};
		my $format = $entry->{'format'};
		my $slug = $entry->{'slug'};
		my $url = $entry->{'url'};
		my $key = substr($entry->{'key'},1);
		push @$menu, {
			name => $name,
			type => 'link',
			url => \&_tagHandler,
			passthrough => [ { params => $key} ]
		};
	}
}

sub favoriteTrack {
	$log->debug('favoriteTrack started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $key = $passDict->{'key'} || '';
	my $url = $method . "://api.mixcloud.com" . $key . "favorite/?access_token=" . $token;
    $log->debug("Favoriting: $url");

	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::POST($url);
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Favorite Track Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_MIXCLOUD_FAVORITED'), type => 'text' } ]);
		} else {
			$log->warn("Favorite Track Error: " . $response->status_line());
			# $callback->([ { name => $response->status_line(), type => 'text' } ]);
			$callback->([ { name => string('PLUGIN_MIXCLOUD_TRACK') . ' ' . string('PLUGIN_MIXCLOUD_NOT_FOUND'), type => 'text' } ]);
		}
	};
		
	$fetch->();
	
	$log->debug('favoriteTrack ended.');
}

sub unfavoriteTrack {
	$log->debug('unfavoriteTrack started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $key = $passDict->{'key'} || '';
	my $url = $method . "://api.mixcloud.com" . $key . "favorite/?access_token=" . $token;
    $log->debug("Unfavorite: $url");

	
	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::DELETE($url);
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Unfavorite Track Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_MIXCLOUD_UNFAVORITED'), type => 'text' } ]);
		} elsif ( $response->code() eq 404 ) {
			$log->warn("Unfavorite Track Error: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_MIXCLOUD_FAVORITE') . ' ' . string('PLUGIN_MIXCLOUD_NOT_FOUND') } ]);
		} else {
			$log->warn("Unfavorite Track Error: " . $response->status_line());
			$callback->([ { name => $response->status_line(), type => 'text' } ]);
		}
		
		# $log->debug('response: ' . $response->as_string);
	};
		
	$fetch->();
	
	$log->debug('unfavoriteTrack ended.');
}

sub repostTrack {
	$log->debug('repostTrack started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $key = $passDict->{'key'} || '';
	my $url = $method . "://api.mixcloud.com" . $key . "repost/?access_token=" . $token;
    $log->debug("Reposting: $url");

	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::POST($url);
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Favorite Track Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_MIXCLOUD_REPOSTED'), type => 'text' } ]);
		} else {
			$log->warn("Favorite Track Error: " . $response->status_line());
			# $callback->([ { name => $response->status_line(), type => 'text' } ]);
			$callback->([ { name => string('PLUGIN_MIXCLOUD_TRACK') . ' ' . string('PLUGIN_MIXCLOUD_NOT_FOUND'), type => 'text' } ]);	
		}
	};
		
	$fetch->();
	
	$log->debug('repostTrack ended.');
}

sub unrepostTrack {
	$log->debug('unrepostTrack started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $key = $passDict->{'key'} || '';
	my $url = $method . "://api.mixcloud.com" . $key . "repost/?access_token=" . $token;
    $log->debug("Unrepost: $url");

	
	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::DELETE($url);
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Unrepost Track Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_MIXCLOUD_UNREPOSTED'), type => 'text' } ]);
		} elsif ( $response->code() eq 404 ) {
			$log->warn("Unrepost Track Error: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_MIXCLOUD_REPOST') . ' ' . string('PLUGIN_MIXCLOUD_NOT_FOUND'), type => 'text' } ]);
		} else {
			$log->warn("Unrepost Track Error: " . $response->status_line());
			$callback->([ { name => $response->status_line(), type => 'text' } ]);
		}
		
		# $log->debug('response: ' . $response->as_string);
	};
		
	$fetch->();
	
	$log->debug('unrepostTrack ended.');
}

sub _parseUsers {
	my ($client, $json, $menu) = @_;
	my $i = 0;
	my $data = $json->{'data'};
	for my $entry (@$data) {
		my $name = $entry->{'name'};
		my $username = $entry->{'username'};
		my $key = substr($entry->{'key'},1);
		my $icon = "";
		if (defined $entry->{'pictures'}->{'large'}) {
			$icon = $entry->{'pictures'}->{'large'};
		}else{
			if (defined $entry->{'pictures'}->{'medium'}) {
				$icon = $entry->{'pictures'}->{'medium'};
			}
		}
		push @$menu, {
			name => $name,
			type => 'link',
			url => \&tracksHandler,
			icon => $icon,
			image => $icon,
			cover => $icon,
			passthrough => [ { type=>'user', params => $key, parser=>\&_parseUser} ]
		};
	}
}

sub _parseUser {
	my ($client, $json, $menu) = @_;
	my $key = substr($json->{'key'},1);
	my $isCurrentUser = ($json->{'is_current_user'} ne '');

	if ($json->{'following_count'} > 0) {
		push(@$menu, 
			{ name => string('PLUGIN_MIXCLOUD_FOLLOWING'), type => 'link',
				url  => \&tracksHandler, passthrough => [ { total => $json->{'following_count'},type => 'following',params => $key."following",parser => \&_parseUsers } ] }
		);
	}

	if ($json->{'favorite_count'} > 0) {
		push(@$menu, 
			{ name => string('PLUGIN_MIXCLOUD_FAVORITES'), type => 'playlist',
				url  => \&tracksHandler, passthrough => [ { total => $json->{'favorite_count'},type => 'favorites',params => $key."favorites" } ] }
		);
	}

	if ($json->{'cloudcast_count'} > 0) {
		push(@$menu, 
			{ name => string('PLUGIN_MIXCLOUD_CLOUDCASTS'), type => 'playlist',
				url  => \&tracksHandler, passthrough => [ { total => $json->{'cloudcast_count'},type => 'cloudcasts',params => $key."cloudcasts"} ] }
		);
	}
	
	push @$menu, {
		type => 'link',
		name => string('PLUGIN_MIXCLOUD_FOLLOW'),
		url  => \&followUser,
		passthrough => [ { key => $key, type => 'text' } ]
	} if (!$isCurrentUser);
	
	push @$menu, {
		type => 'link',
		name => string('PLUGIN_MIXCLOUD_UNFOLLOW'),
		url  => \&unfollowUser,
		passthrough => [ { key => $key, type => 'text' } ]
	} if (!$isCurrentUser);
}

sub followUser {
	$log->debug('followUser started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $key = $passDict->{'key'} || '';
	my $url = $method . "://api.mixcloud.com/" . $key . "follow/?access_token=" . $token;
    $log->debug("Following: $url");

	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::POST($url);
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Follow User Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_MIXCLOUD_FOLLOWED'), type => 'text', showBriefly => 1, refresh => 1 } ]);
		} else {
			$log->warn("Follow User Error: " . $response->status_line());
			# $callback->([ { name => $response->status_line(), type => 'text' } ]);
			$callback->([ { name => string('PLUGIN_MIXCLOUD_USER') . ' ' . string('PLUGIN_MIXCLOUD_NOT_FOUND'), type => 'text', showBriefly => 1, refresh => 1 } ]);	
		}
	};
		
	$fetch->();
	
	$log->debug('followUser ended.');
}

sub unfollowUser {
	$log->debug('unfollowUser started.');
	my ($client, $callback, $args, $passDict) = @_;

	my $method = "https";
	my $key = $passDict->{'key'} || '';
	my $url = $method . "://api.mixcloud.com/" . $key . "follow/?access_token=" . $token;
    $log->debug("Unfollowing: $url");

	
	my $fetch = sub {
		my $ua = LWP::UserAgent->new;
		my $request = HTTP::Request::Common::DELETE($url);
		my $response =  $ua->request($request);
		
		if ( $response->is_success() ) {
			$log->warn("Unfollow User Success: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_MIXCLOUD_UNFOLLOWED'), type => 'text', showBriefly => 1, refresh => 1 } ]);
		} elsif ( $response->code() eq 404 ) {
			$log->warn("Unfollow User Error: " . $response->status_line());
			$callback->([ { name => string('PLUGIN_MIXCLOUD_FOLLOW') . ' ' . string('PLUGIN_MIXCLOUD_NOT_FOUND'), type => 'text', showBriefly => 1, refresh => 1 } ]);
		} else {
			$log->warn("Unfollow User Error: " . $response->status_line());
			$callback->([ { name => $response->status_line(), type => 'text', showBriefly => 1, refresh => 1 } ]);
		}
		
		# $log->debug('response: ' . $response->as_string);
	};
		
	$fetch->();
	
	$log->debug('unfollowUser ended.');
}

sub _tagHandler {
	my ($client, $callback, $args, $passDict) = @_;
	my $params = $passDict->{'params'} || '';
	my $callbacks = [
		{ name => string('PLUGIN_MIXCLOUD_POPULAR'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'tags', params=>$params.'popular/'} ], },
		
		{ name => string('PLUGIN_MIXCLOUD_LATEST'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'tags', params=>$params.'latest/' } ], },

	];
	$callback->($callbacks);
}

sub initPlugin {
	my $class = shift;

	$cache = Slim::Utils::Cache->new('mixcloud', $class->_pluginDataFor('cacheVersion'));
	
	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'mixcloud',
		menu   => 'radios',
		is_app => $class->can('nonSNApps') ? 1 : undef,
		weight => 10,
	);
	
	# clear the cache when user enters an apiKey
	$prefs->setChange(sub {
		my ($pref, $new, $obj, $old) = @_;
		$cache->clear;
	}, 'apiKey');
	
	if (!$::noweb) {
		require Plugins::MixCloud::Settings;
		Plugins::MixCloud::Settings->new;
	}

	Slim::Formats::RemoteMetadata->registerProvider(
		match => qr/mixcloud/,
		func => \&_provider,
	);

	Slim::Player::ProtocolHandlers->registerHandler(
		mixcloud => 'Plugins::MixCloud::ProtocolHandler'
	);
}

sub shutdownPlugin {
	my $class = shift;
}

sub getDisplayName { 'PLUGIN_MIXCLOUD' }

sub playerMenu { shift->can('nonSNApps') ? undef : 'RADIO' }

sub toplevel {
	my ($client, $callback, $args) = @_;

	my $callbacks = [
		
		{ name => string('PLUGIN_MIXCLOUD_MUSIC') . ' ' . string('PLUGIN_MIXCLOUD_CATEGORIES'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'categories_music', parser => \&_parseCategories } ], },
				 
		{ name => string('PLUGIN_MIXCLOUD_TALK') . ' ' . string('PLUGIN_MIXCLOUD_CATEGORIES'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'categories_talk', parser => \&_parseCategories } ], },
		
		{ name => string('PLUGIN_MIXCLOUD_MYSEARCH'), type => 'link',   
			url  =>sub{
				my ($client, $callback, $args) = @_;
				my $searchcallbacks = [
						{ name => string('PLUGIN_MIXCLOUD_SEARCH'), type => 'search',   
							url  => \&tracksHandler, passthrough => [ { type => 'search' } ], },
				
						{ name => string('PLUGIN_MIXCLOUD_TAGS'), type => 'search',   
							url  => \&tracksHandler, passthrough => [ { type => 'tags',parser => \&_parseTags } ], },
						
						{ name => string('PLUGIN_MIXCLOUD_SEARCH_USER'), type => 'search',   
							url  => \&tracksHandler, passthrough => [ { type => 'usersearch',parser => \&_parseUsers } ], }
				];				
				$callback->($searchcallbacks);							
			}, passthrough => [ { type => 'search' } ], }		
	];
	
	getToken(
			 sub{
				if ($token ne '') {
					unshift(@$callbacks, 
						{ name => string('PLUGIN_MIXCLOUD_MYMIXCLOUD'), type => 'link',
						url  => \&tracksHandler, passthrough => [ { type=>'user', params => 'me/',parser=>\&_parseUser} ] }						
					);
					
				}
				push(@$callbacks, 
					{ name => string('PLUGIN_MIXCLOUD_URL'), type => 'search', url  => \&urlHandler }
				);
				$callback->($callbacks);
			}
	)
	
}

1;
