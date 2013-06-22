#!/usr/bin/perl

use 5.014_000; # backward compatibility v5.14.0
use vars qw($VERSION %IRSSI);
use strict;
use warnings;
use utf8;

use Irssi;

use Time::Local;
use POSIX qw(strftime);

use LWP::Simple;
use XML::Simple;

use Data::Dumper;
use Digest::MD5 qw(md5_hex);

use File::Basename;
use lib dirname(__FILE__);
use APIVars qw($api_pid $api_key);

sub irssiweather;    # main
sub ircsend;         # send string to irc
sub get_href;        # get hash ref from api 
sub render_forecast; # generate fc output
sub render_options;  # generate options output
sub render_credit;   # generate credit output

my $max_options = 10;

$VERSION = '0.2.3';
%IRSSI = (
	authors     => 'Andreas (llandon) Schwarz',
	name        => 'irssiweather',
	description => 'wetter.com frontend'
);

Irssi::signal_add("message public", \&irssiweather);

sub irssiweather {
	## processing input
	my ($server, $data, $hunter, $mask, $chan) = @_;
	my $cmd = substr($data, 0, index($data, ' '), '');
	$data =~ s/.//; # remove leading space

	if($cmd !~ m/!wetter|!weather|!wcom/) {
		return 0;
	}

	## acquire citycode
	my $checksum = md5_hex($api_pid, $api_key, $data);
	my $url = "http://api.wetter.com/location/index/search/$data/project/$api_pid/cs/$checksum";
	my $search_xml_href = get_href($url);
#	print Dumper $search_xml_href;
	my $result = $search_xml_href->{result}->{item};
	my $hits = $search_xml_href->{hits};

	if($hits==0) {
		print "WCOM-ZERO: $url";
		ircsend($server, $hunter, "\x02Kein Suchergebnis");
		return 0;
	}elsif($hits > $max_options) {
		print "WCOM-OVER: $url";
		ircsend($server, $hunter, render_options($result));
		ircsend($server, $hunter, "\x02Mehr als $max_options Ergebnisse. (restlichen werden nicht angezeigt)");
		return 0;
	}elsif($hits > 1) {
		## output options
		print "WCOM-MULTI: $url";
		ircsend($server, $hunter, render_options($result)
		);	
		return 0;
	}elsif($hits==1){
		my $city_code = $result->{city_code};
		## acquire forecast
		$checksum = md5_hex($api_pid, $api_key, $city_code);
		$url = "http://api.wetter.com/forecast/weather/city/$city_code/project/$api_pid/cs/$checksum";
		my $fc_xml_href = get_href($url);

		## output forecast
		print "WCOM-SINGLE: $url";
		ircsend($server, $chan, render_forecast($fc_xml_href));
		ircsend($server, $hunter, render_credit($search_xml_href));
	}else{
		ircsend($server, $chan, "Schnittstellenfehler");
		print "WCOM-ERROR: $url";
	}
}

sub ircsend(@) {
    if($#_ != 2) { return 1; }
    my $server = $_[0];
    my $target = $_[1];
    my $string = $_[2];
    foreach(split(/\n/, $string)) {
		$server->command("msg $target $_");
	}
    return 0;
}

sub get_href {
	my $url = shift;
	my $api_data = get($url);
	my $xml = new XML::Simple;
	my $result_href = $xml->XMLin(
		$api_data, 
		SuppressEmpty => undef,
#		KeyAttr => { item => '+city_code' }
		KeyAttr => { item => 'value' }
	);
	return $result_href;
}

sub render_forecast {
	my $fc_xml_href     = shift;
	my $output          = "";

	my $city      = $fc_xml_href->{name};
	my $post_code = $fc_xml_href->{post_code};
	my $city_code = $fc_xml_href->{city_code};
	
	if(defined $city) {
		$output .= "\x02Wetter für $city";
	}else{
		return 0;
	}
	$output .= " ($post_code)" if(defined $post_code);
	$output .= " $city_code" if(defined $city_code);
	$output .= "\n";

	my @fc = $fc_xml_href->{forecast}->{date};
	for(my $i=0; $i<3; $i++) {
		my @mint; my @maxt; my @text;
		my $day = strftime("%a",localtime(time+24*60*60*$i));
		$output .= "    \x02$day:\x02 ";
		for(my $j=0; $j<4; $j++) { # Tagesabschnitte
			$mint[$j] = $fc[0][$i]->{time}[$j]->{tn};
			$maxt[$j] = $fc[0][$i]->{time}[$j]->{tx};
			$text[$j] = $fc[0][$i]->{time}[$j]->{w_txt};
			$output .= "\x0303$mint[$j]\x03/\x0305$maxt[$j]\x03°C $text[$j] ";
		}
		$output .= "\n";
	}
	return $output;
}

sub render_options {
	my $options = shift;
	my $output = "\x02Kein eindeutiges Suchergebnis, bitte den Suchstring konkretisieren\n";
	my ($name, $city_code, $plz, $adm1, $adm2, $adm4, $quarter);

	my $count = 0;
	foreach my $key (keys $options) {
		return $output if($count >= $max_options);

		$name = $options->{$key}->{name};
		$city_code = $options->{$key}->{city_code};
		$plz = $options->{$key}->{plz};
		$adm4 = $options->{$key}->{adm_4_name};
		$adm1 = $options->{$key}->{adm_1_code};
		$adm2 = $options->{$key}->{adm_2_name};
		$quarter = $options->{$key}->{quarter};

		if(defined $name and defined $city_code) {
			$output .= "    \x02$name:\x02 ";
			$output .= "\x0305" if(!defined $plz);
			$output .= "$city_code";
			$output .= "\x03" if(!defined $plz);
		}else{
			return "Fehler";
		}
		$output .= " (" if(defined $quarter or defined $plz);
		$output .= $quarter if(defined $quarter);
		$output .= " " if(defined $quarter and defined $plz);
		$output .= "\x0305$plz\x03" if(defined $plz);
		$output .= ")" if(defined $quarter or defined $plz);
		$output .= " $adm4" if(defined $adm4 and !defined $quarter);
		$output .= " $adm2" if(defined $adm2);
		$output .= " $adm1" if(defined $adm1);
		$output .= "\n";
		++$count;
	}
	return $output;
}

sub render_credit {
	my $search_xml_href = shift;
	my $credit_href = $search_xml_href->{credit};
	my $credit = "Die Verwendung der API verlangt leider die Nennung der Quelle:"
		." $credit_href->{text} $credit_href->{link}."
		." Um nicht länger von dieser Meldung genervt zu werden einfach im Client"
		." Zeilen welche wa2aal8Ieth1laeD enthalten ignorieren."
		." Es ist nicht sinnvoll alle Queries zu ignorieren,"
		." denn hierüber werden auch die Optionen bei nicht eindeutigen Anfragen"
		." aufgelistet.\nFür irssi-Nutzer wäre das die Zeile:"
		." /ignore -pattern \"wa2aal8Ieth1laeD\" * MSGS";
	return $credit;
}
