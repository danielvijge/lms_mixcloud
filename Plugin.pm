package Plugins::MixCloud::Plugin;

# Plugin to stream audio from Mixcloud
#
# Released under GNU General Public License version 2 (GPLv2)
# Written by Christian Mueller,
# See file LICENSE for full license details

use strict;

use base qw(Slim::Plugin::OPMLBased);
use utf8;

use URI::Escape;
use JSON::XS::VersionOneAndTwo;

use File::Spec::Functions qw(:ALL);
use List::Util qw(min max);
use Date::Parse;

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Plugin::OPMLBased;

use Plugins::MixCloud::ProtocolHandler;

my $CLIENT_ID = "2aB9WjPEAButp4HSxY";
my $CLIENT_SECRET = "scDXfRbbTyDHHGgDhhSccHpNgYUa7QAW";
my $token = "";

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
	my ($client, $url) = @_;
	return Plugins::MixCloud::ProtocolHandler::fetchTrackDetail($client, $url);
}

sub _parseTracks {
	my ($json, $menu) = @_;
	my $data = $json->{'data'}; 
	for my $entry (@$data) {
		push @$menu, Plugins::MixCloud::ProtocolHandler::makeCacheItem($entry);
	}
}

sub tracksHandler {
	my ($client, $callback, $args, $passDict) = @_;

	my $index    = ($args->{'index'} || 0); # ie, offset
	my $quantity = $args->{'quantity'} || 200;
	my $searchType = $passDict->{'type'};

	my $parser = $passDict->{'parser'} || \&_parseTracks;
	my $params = $passDict->{'params'} || '';

	$log->debug('search type: ' . $searchType);
	$log->debug("index: " . $index);
	$log->debug("quantity: " . $quantity);
	$log->debug("params: " . $params);

	my $menu = [];
	
	# fetch in stages as api only allows 50 items per response, cli clients require $quantity responses which can be more than 50
	my $fetch;
	
	# FIXME: this could be sped up by performing parallel requests once the number of responses is known??

	$fetch = sub {
		# in case we've already fetched some of this page, keep going
		my $i = $index + scalar @$menu;
		$log->debug("i: " . $i);
		my $max = min($quantity - scalar @$menu, 200); # api allows max of 200 items per response
		$log->debug("max: " . $max);
		my $method = "http";
		my $uid = $passDict->{'uid'} || '';
		my $resource = "";
		if ($searchType eq 'categories') {
			if ($params eq "") {
				$resource = "categories";
			}else{
				$resource = $params;
				$params = "";
			}			
		}
		
		if ($searchType eq 'search') {
			$resource = "search";
			$params = "q=".$args->{'search'}."&type=cloudcast"; 
		}
		
		if ($searchType eq 'usersearch') {
			$resource = "search";
			$params = "q=".$args->{'search'}."&type=user"; 
		}
		
		if ($searchType eq 'tags') {
			if ($params eq "") {
				$resource = "search";
				$params = "q=".$args->{'search'}."&type=tag";
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
					$params .= "&access_token=" . $token;
				}				
			}		
		}
		
		my $queryUrl = "$method://api.mixcloud.com/$resource?offset=$i&limit=$quantity&" . $params;
		$log->info("Fetching $queryUrl");
		
		Slim::Networking::SimpleAsyncHTTP->new(
			
			sub {
				my $http = shift;				
				my $json = eval { from_json($http->content) };
				
				# Special logic for retrieving a category, because the limit
                # and offset parameters are not supported by the API
                if ($searchType eq 'categories' && $quantity == 1) {
                    my $data = $json->{'data'};
                    my $i = 0;
                    for my $entry (@$data) {
                        if ($i == $index) {
                            $json = { data => [$entry]};
                        }
                        $i++;
                    }
                } 

				$parser->($json, $menu);
	
				# max offset = 8000, max index = 200 sez 
				my $total = 8000 + $quantity;
				if (exists $passDict->{'total'}) {
					$total = $passDict->{'total'}
				}
				
				$log->debug("this page: " . scalar @$menu . " total: $total");

				# TODO: check this logic makes sense
				if (scalar @$menu < $quantity) {
					$total = $index + @$menu;
					$log->debug("short page, truncate total to $total");
				}
				if ($searchType eq 'user') {
					$callback->($menu);
				}else{
					$callback->({
						items  => $menu,
						offset => $index,
						total  => $total,
					});
				}
			},			
			sub {
				$log->error("error: $_[1]");
				$callback->([ { name => $_[1], type => 'text' } ]);
			},
			
		)->get($queryUrl);
	};
		
	$fetch->();
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
				$callback->( { items => [ Plugins::MixCloud::ProtocolHandler::makeCacheItem($item) ] } );
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
	my ($json, $menu) = @_;
	my $i = 0;
	my $data = $json->{'data'};
	for my $entry (@$data) {
		my $name = $entry->{'name'};
		my $format = $entry->{'format'};
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

sub _parseTags {
	my ($json, $menu) = @_;
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

sub _parseUsers {
	my ($json, $menu) = @_;
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
			passthrough => [ { type=>'user', params => $key,parser=>\&_parseUser} ]
		};
	}
}

sub _parseUser {
	my ($json, $menu) = @_;
	my $key = substr($json->{'key'},1);

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
}

sub _tagHandler {
	my ($client, $callback, $args, $passDict) = @_;
	my $params = $passDict->{'params'} || '';
	my $callbacks = [
		{ name => string('PLUGIN_MIXCLOUD_POPULAR'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'tags'  ,params=>$params.'popular/'} ], },
		
		{ name => string('PLUGIN_MIXCLOUD_LATEST'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'tags' ,params=>$params.'latest/' } ], },

	];
	$callback->($callbacks);
}

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed   => \&toplevel,
		tag    => 'mixcloud',
		menu   => 'radios',
		is_app => $class->can('nonSNApps') ? 1 : undef,
		weight => 10,
	);

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
		
		{ name => string('PLUGIN_MIXCLOUD_CATEGORIES'), type => 'link',   
			url  => \&tracksHandler, passthrough => [ {type=>'categories',parser => \&_parseCategories } ], },
		
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
