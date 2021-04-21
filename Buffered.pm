package Plugins::MixCloud::Buffered;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use File::Temp;

use Slim::Utils::Errno;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;

my $log   = logger('plugin.mixcloud');
my $prefs = preferences('plugin.mixcloud');

sub canDirectStream { 0 }

sub new {
	my $class  = shift;
	my $self = $class->SUPER::new(@_);
	my $v = ${*$self}{'_mixcloud'} = {};

	# HTTP headers have now been acquired in a blocking way by the above, we can 
	# now enable fast download of body to a file from which we'll read further data
	# but the switch of socket handler can only be done within _sysread otherwise
	# we will timeout when there is a pipeline with a callback 
	if (Slim::Utils::Misc->can('getTempDir')) { 
		$v->{'fh'} = File::Temp->new( DIR => Slim::Utils::Misc::getTempDir() );
	} else {
		$v->{'fh'} = File::Temp->new;
	}
	open $v->{'rfh'}, '<', $v->{'fh'}->filename;
	binmode($v->{'rfh'});
	
	main::INFOLOG && $log->info("Using Mixcloud's own Buffered service for $_[0]->{'url'}");
	
	return $self;
}

sub close {
	my $self = shift;
	my $v = ${*$self}{'_mixcloud'};

	# clean buffer file and all handlers
	Slim::Networking::Select::removeRead($self);	
	$v->{'rfh'}->close;
	delete $v->{'fh'};
	
	$self->SUPER::close(@_);
}

# we need that call structure to make sure that SUPER calls the
# object's parent, not the package's parent
# see http://modernperlbooks.com/mt/2009/09/when-super-isnt.html
sub _sysread {
	my $self  = $_[0];
	my $v = ${*$self}{'_mixcloud'};
	
	# we are not ready to read body yet, read socket directly
	return $self->SUPER::_sysread($_[1], $_[2], $_[3]) unless $v->{'rfh'};

	# first, try to read from buffer file
	my $readLength = $v->{'rfh'}->read($_[1], $_[2], $_[3]);
	return $readLength if $readLength;
	
	# assume that close() will be called for cleanup
	return 0 if $v->{'done'};
	
	# empty file but not done yet, try to read directly
	$readLength = $self->SUPER::_sysread($_[1], $_[2], $_[3]);

	# if we now have data pending, likely we have been removed from the reading loop
	# so we have to re-insert ourselves (no need to store fresh data in buffer)
	if ($readLength) {
		Slim::Networking::Select::addRead($self, \&saveStream);
		return $readLength;
	}
		
	# use EINTR because EWOULDBLOCK (although faster) may overwrite our addRead()
	$! = EINTR;
	return undef;
}

sub saveStream {
    my $self = shift;
	my $v = ${*$self}{'_mixcloud'};
	
	my $bytes = $self->SUPER::_sysread(my $data, 32768);
	return unless defined $bytes;
	
	if ($bytes) {
		syswrite($v->{'fh'}, $data);
		$v->{'rfh'}->seek(0, 1);								
	} else {
		Slim::Networking::Select::removeRead($self);	
		$v->{'done'} = 1;		
	}
}	
