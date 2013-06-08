use vars qw($VERSION %IRSSI);
use strict;
use warnings;

#use Irssi;
use utf8;
use Time::Local;
use LWP::Simple;
use XML::Simple;
use Data::Dumper;
use HTML::Entities;
use Digest::MD5 qw(md5);

sub irssiweather;
sub ircsend;

my $api_pid = 'INSERTAPIPID';
my $api_key = 'INSERTAPIKEY';

$VERSION = '0.2.0';
%IRSSI = (
	authors     => 'Andreas (llandon) Schwarz',
	name        => 'irssiweather',
	description => 'wetter.com frontend'
);

Irssi::signal_add("message public", \&irssiweather);

sub irssiweather {
	my ($server, $data, $hunter, $mask, $cha) = @_;
	my @l_arr = split(/ /, $data);

	my $search_string = $l_arr[0];
	my $checksum = md5($api_pid . $api_key . $search_string);

	my $url = "http://api.wetter.com/location/index/search/$search_string/project/<Projektname>/cs/$checksum";

	ircsend($server, $hunter, $search_string);
	ircsend($server, $hunter, $checksum);
	ircsend($server, $hunter, $url);
}

sub ircsend(@) {
    if($#_ != 2) { return 1; }
    my $server = $_[0];
    my $target = $_[1];
    my $string = $_[2];
    $server->command("msg $target $string");
    return 0;
}

