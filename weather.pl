use strict;
use warnings;
use Irssi;
use LWP::Simple;   # get()
use vars qw($VERSION %IRSSI);
$VERSION = '0.1';
%IRSSI = (
	authors     => 'Andreas (llandon) Schwarz',
	name        => 'GWAF',
	description => 'GWAF Google Weather API Frontend');

Irssi::signal_add("message public", \&gwaf);

sub gwaf;               # main
sub ircsend;            # send irc message
sub gwafout;            # parse and send gwa output
sub xmlcheck;           # check gwa output

my @error   = ( 'der Web-Service konnte zu den Argumenten keine Daten liefern (bei Ausland Land angeben!)', 
              'Parameter im falschem Format angegeben',
              'falsche Anzahl Parameter [0,1]');
my $gwa     = 'http://www.google.com/ig/api?weather';
my $lang    = 'de';     # output language
my $country = 'de';     # std. country

sub gwaf {
	my ($server, $data, $hunter, $mask, $chan) = @_;
	$data =~ s/ +/ /g;
	my @l_arr = split(/ /,$data);
	my $xmldata;

	if(1 < $#l_arr) { # alles nach dem ersten leerzeichen wieder verbinden
		my $anz = $#l_arr;
		for(my $i=1; $i<$anz; ++$i) {
			$l_arr[$anz-$i] = $l_arr[$anz-$i] . " " . $l_arr[$anz-$i+1];
			pop(@l_arr);
		}
	}
	
	if($l_arr[0] =~ /(^!gwaf$)|(^!weather$)/) { # |(^!wetter$)/) { # Aufrufparameter
		if(0 == $#l_arr) {
			$xmldata = get("$gwa=91058-$country&hl=$lang");
			gwafout($server, $chan, $xmldata);
		}
		elsif(1 == $#l_arr) {
			if($l_arr[1] =~ /^[0-9]{5}$|^[a-zA-Zaöüß() ]{2,}$/) {
				# nur PLZ, oder Ort (Standard de)
				$xmldata = get("$gwa=$l_arr[1]-$country&hl=$lang");
				if(1 == xmlcheck($xmldata)) {
					ircsend($server, $hunter, $error[0]);
				}
				else {
					gwafout($server, $chan, $xmldata);
				}
			}
			elsif($l_arr[1] =~ /^(([0-9]{5})|([a-zA-Zaöüß() -]{2,}))-[a-zA-Z]{2,}$/) {
				# PLZ, oder Ort mit Land
				$xmldata = get("$gwa=$l_arr[1]&hl=$lang");
				if(1 == xmlcheck($xmldata)) {
					ircsend($server, $hunter, $error[0]);
				}
				else {
					gwafout($server, $chan, $xmldata);
				}
			}
			else {
				# Schmarn
				ircsend($server, $hunter, $error[1]);
				ircsend($server, $hunter, '(PLZ|Ort)[-Land]');
			}
		}
		else {
			# falsche Parameter - Anzahl
			ircsend($server, $hunter, $error[2]);
		}
	}
	else { return ; }
}

sub ircsend(@) {
	if($#_ != 2) { return 1; }
	my $server = $_[0];
	my $target = $_[1];
	my $string = $_[2];
	$server->command("msg $target $string");
	return 0;
}

sub gwafout(@) {
	my $von = 0;           # pos-variable
	my $bis = 0;           # pos-variable
	my $i   = 0;           # element-counter
	my @elements;          # data-array
	my $server = $_[0];    # irc-server
	my $chan = $_[1];      # irc-chan
	my $xmldata = $_[2];   # google weather output
	my $message = '';      # irc message
	my @splitstr = ('<city data="', '<forecast_date data="', '<current_date_time data="', 
		'<current_conditions><condition data="', '<temp_c data="', '<humidity data="Luftfeuchtigkeit: ',
		'<wind_condition data="');                # parse strings (current cond)
	my @vhsplits = ('<forecast_conditions><day_of_week data="', '<low data="',
		'<high data="', '<condition data="');     # parse strings (forecast)

	for($i=0; $i<$#splitstr+1; ++$i) {
		$von = index($xmldata, $splitstr[$i],$von)+length($splitstr[$i]);
		$bis = index($xmldata,'"/>',$von);
		$elements[$i] = substr($xmldata,$von,$bis-$von);
	}

	$message = "Wetter fuer $elements[0] ($elements[1]) $elements[4] \xB0".
	           "C $elements[6] r.F. $elements[5] ($elements[3])";
	ircsend($server, $chan, $message); # [2] date + time

	for(my $j=0; $j<4; ++$j) {
		for(;$i<($#splitstr+1)+(($j+1)*($#vhsplits+1)); ++$i) {
			$von = index($xmldata, $vhsplits[$i-$#splitstr-1-($j*4)],$von)
			       +length($vhsplits[$i-$#splitstr-1-($j*4)]);
			$bis = index($xmldata,'"/>',$von);
			$elements[$i] = substr($xmldata,$von,$bis-$von);
		}
		$message = "       \x02$elements[$i-4]:\x02 min: " . 
		           substr('   ',0 , 3-length($elements[$i-3])) . # Ausgleich fuer unterschiedliche temp-laengen (max. 3 (-99))
		           "$elements[$i-3] \xB0" .
		           "C max: " .
		           substr('   ',0 , 3-length($elements[$i-2])) . 
		           "$elements[$i-2] \xB0"."C ($elements[$i-1])";
		ircsend($server, $chan, $message);
	}
}

sub xmlcheck($) {
	if(($_[0] =~ /problem_cause/) || ($_[0] !~ /forecast_information/)) {
		return 1;
	}   
	else {
		return 0;
	}  
}
