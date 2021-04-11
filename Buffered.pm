package Plugins::MixCloud::Buffered;

use strict;
use base qw(Slim::Player::Protocols::HTTPS);

use File::Temp;

use Slim::Utils::Errno;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.mixcloud');
my $prefs = preferences('plugin.mixcloud');

sub new {
	my $class  = shift;
	my $self = $class->SUPER::new(@_);

	# HTTP headers have now been acquired in a blocking way by the above, we can 
	# now do fast download of body to a file from which we'll read further data
	if (Slim::Utils::Misc->can('getTempDir') { 
		${*$self}{'_fh'} = File::Temp->new( DIR => Slim::Utils::Misc::getTempDir );
	} else 
		${*$self}{'_fh'} = File::Temp->new;
	}
	open ${*$self}{'_rfh'}, '<', ${*$self}{'_fh'}->filename;
	binmode(${*$self}{'_rfh'});
	Slim::Networking::Select::addRead($self, \&saveStream);	
	
	return $self;
}

sub close {
	my $self = shift;

	# clean buffer file and all handlers
	Slim::Networking::Select::removeRead($self);	
	${*$self}{'_rfh'}->close;
	delete ${*$self}{'_fh'};
	
	$self->SUPER::close(@_);
}

# we need that call structure to make sure that SUPER calls the
# object's parent, not the package's parent
# see http://modernperlbooks.com/mt/2009/09/when-super-isnt.html
sub _sysread {
	my $self  = $_[0];
	my $rfh = ${*$self}{'_rfh'};
	
	return $self->SUPER::_sysread($_[1], $_[2], $_[3]) unless $rfh;
	my $readLength = read($rfh, $_[1], $_[2], $_[3]);

	return $readLength if $readLength;

	# assume that close() will be called for cleanup
	return 0 if ${*$self}{_done};
	
	# we should not be here because $fh should always be ahead of streaming. It only happens 
	# if download is slow and/or player has a very large buffer. As nextChunk will remove us
	# from the read loop, we need to re-insert ourselves(reset eof as well).
	Slim::Utils::Timers::setTimer($self, time(), sub { Slim::Networking::Select::addRead(shift, \&saveStream) });
	$rfh->seek(0, 2);
	
	$! = EINTR if main::ISWINDOWS;
	return undef;
}

sub saveStream {
    my $self = shift;
	
	my $bytes = $self->SUPER::_sysread(my $data, 32768);
	return unless defined $bytes;
	
	if ($bytes) {
		${*$self}{'_fh'}->write($data);
	} else {
		Slim::Networking::Select::removeRead($self);	
		${*$self}{_done} = 1;		
	}
}	
