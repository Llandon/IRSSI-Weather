#!/usr/bin/perl

use strict;
use warnings;
use utf8;
use v5.14;
use feature 'switch';

use Time::Local;
use Time::Zone;
use POSIX qw(strftime tzset);
use LWP::Simple;
use Data::Dumper;
use JSON;
use URI::Escape;
use List::MoreUtils qw( minmax );

use File::Basename;
use lib dirname(__FILE__);
use APIVars qw($api_key);

my %ignoreList = ();
my $CALL_GRACETIME = 60;#10800;  # three hours
my $CALL_MAX       = 2;      # >2 => ignore

no warnings 'experimental::smartmatch';

binmode(STDOUT, ":utf8");

use vars qw($VERSION %IRSSI);

use Irssi;

sub autoIgnore($);             # ignore annoying people
sub irssiweather();            # main
sub ircsend($$$);              # send string to irc
sub render_forecast;           # generate fc output
sub renderTempForecast($@);    # render temperature forecast
sub renderRainForecast($\@;$;$);    # render rain forecast
sub replaceIcon($$);           # replace icon string
sub getLocation($);            # get geolocation
sub getForecast($);            # get weather forecast
sub getTemperatures($);        # get temperature array
sub getPrecipProbabilities($); # get temperature array
sub arrayToGraph(\@;$;$;$;$);           # visualize array

$VERSION = '0.3.2';
%IRSSI = (
	authors     => 'Andreas Schwarz',
	name        => 'irssiweather',
	description => 'Dark Sky API frontend'
);

Irssi::signal_add("message public", \&irssiweather);

sub autoIgnore($) {
	my $user = shift;
	return 0 if('llandon' eq $user);

	if(defined $ignoreList{$user}->{'time'}) {
		push($ignoreList{$user}->{'time'}, time);
	}else{
		$ignoreList{$user}->{'time'} = [time];
	}

	my $callsInTime=0;
	my $time = time;
	for(my $i=0; $i<scalar @{$ignoreList{$user}->{'time'}}; ++$i) {
		++$callsInTime if $ignoreList{$user}->{'time'}[$i]>$time-$CALL_GRACETIME;
	}
	for(my $i=0; $i<scalar @{$ignoreList{$user}->{'time'}}; ++$i) {
		if($ignoreList{$user}->{'time'}[$i]<=$time-$CALL_GRACETIME) {
			splice(@{$ignoreList{$user}->{'time'}}, $i, 1);
			--$i; # can/have to be negative (del elem 0)
		}
	}

	if($callsInTime>$CALL_MAX) {
		return 1;
	}else{
		return 0;
	}
}	

sub irssiweather() {
	my $callForecast     = '!wetter';
	my $callTempForecast = '!temp';
	my $callRainForecast = '!rain';
	my $defaultLocation  = '91058, Deutschland';

	## processing input
	my ($server, $data, $hunter, $mask, $chan) = @_;

	my $location = "";
	my $forecast = "";
	my $output   = "";
	my @temps;
	my @probabs;

	if($data =~ m/^$callForecast/ or $data =~ m/^$callTempForecast/ or $data =~ m/^$callRainForecast/) {
		if(autoIgnore($hunter)) {
			ircsend($server, $hunter, "I ignore your calls for a while because you're annoying other people.");
			return 0;
		}
	}
	
	if($data =~ m/^$callForecast.*$/) {
		if($data =~ m/^$callForecast \w+/) {
			$data =~ s/^$callForecast //;
		}else{
			$data     = $defaultLocation;
		}
		$location = getLocation($data);
		$forecast = getForecast($location);
		$output   = renderForecast($location, $forecast);
	}elsif($data =~ m/^$callTempForecast.*$/) {
		if($data =~ m/^$callTempForecast \w+/) {
			$data =~ s/^$callTempForecast //;
		}else{
			$data = $defaultLocation;
		}
		$location = getLocation($data);
		@temps    = getTemperatures($location);
		$output   = renderTempForecast($location, \@temps);
	}elsif($data =~ m/^$callRainForecast.*$/) {
		if($data =~ m/^$callRainForecast \w+/) {
			$data =~ s/^$callRainForecast //;
		}else{
			$data     = $defaultLocation;
		}
		$location = getLocation($data);
		@probabs  = getPrecipProbabilities($location);
		$output   = renderRainForecast($location, @probabs, '03', '02');
	}elsif($data =~ m/^!autoignorelist$/) {
#		autoIgnore($hunter);
		$Data::Dumper::Indent = 3;
		print Dumper(%ignoreList);
	}else{
		return 0;
	}
	
	ircsend($server,$chan,$output);
}

sub ircsend($$$) {
	my ($server, $target, $string) = @_;

    foreach(split(/\n/, $string)) {
		$server->command("msg $target $_");
	}
    return 0;
}

sub getLocation($) {
	my $query = uri_escape($_[0]);

	if($query eq "") {
		print "Kein Ort übergeben\n";
		return 0;
	}

	my $nominatim_opts = "?format=json&addressdetails=1&accept-language=de";
	my $nominatim_api  = "https://nominatim.openstreetmap.org/search/";
	my $nominatim_url  = $nominatim_api . $query . $nominatim_opts;

	my $locGet = get($nominatim_url);
	if(!defined $locGet or $locGet eq "") {
		print "Nominatim Fehler";
		return 0;
	}
	if($locGet eq "[]") {
		print "Ort nicht gefunden\n";
		return 0;
	}

	my @locations = decode_json( $locGet );
	if(!@locations) {
		print "konnte JSON nicht parsen\n$locGet\n";
		return 0;
	}

	return $locations[0][0];
}

sub getForecast($) {
	my $location = $_[0];
	return 0 if !$location;

	my $lat = $location->{lat};
	my $lon = $location->{lon};

	my $options  = 'lang=de&units=si&exclude=minutely,daily,flags&extend=hourly';
	my $api      = 'https://api.darksky.net/forecast';

	my $url = $api . '/' . $api_key . '/' . $lat . ',' . $lon . "?$options";
	my $response = get($url);
	my $forecast = decode_json( $response );

	return $forecast;
}

sub getTemperatures($) {
	my $location = $_[0];
	return 0 if !$location;

	my $lat = $location->{lat};
	my $lon = $location->{lon};

	my $options  = 'lang=de&units=si&exclude=currently,minutely,daily,alerts,flags&extend=hourly';

	my $offset   = tz_local_offset();
	my $timebase = time - (time%86400) - $offset;

	my $api      = 'https://api.darksky.net/forecast';
	my $urlfd = $api . '/' . $api_key . '/' . $lat . ',' . $lon . ',' . $timebase . "?$options";
	my $urlnd = $api . '/' . $api_key . '/' . $lat . ',' . $lon . "?$options";

	print "URL first day: $urlfd\nURL next days: $urlnd";

	my $responsefd = get($urlfd);
	my $forecastfd = decode_json( $responsefd );

	my $responsend = get($urlnd);
	my $forecastnd = decode_json( $responsend );

	my @temps;
	my $lastts = 0;
	for(my $i=0; defined $forecastfd->{hourly}->{data}[$i]; ++$i) {
		push(@temps, $forecastfd->{hourly}->{data}[$i]->{temperature});
		$lastts = $forecastfd->{hourly}->{data}[$i]->{time};
	}

	for(my $i=0; defined $forecastnd->{hourly}->{data}[$i]; ++$i) {
		next if $forecastnd->{hourly}->{data}[$i]->{time}<=$lastts;
		last if $forecastnd->{hourly}->{data}[$i]->{time} >=
			$timebase + 3*86400;
		push(@temps, $forecastnd->{hourly}->{data}[$i]->{temperature});
	}

	return @temps;
}

sub getPrecipProbabilities($) {
	my $location = $_[0];
	return 0 if !$location;

	my $lat = $location->{lat};
	my $lon = $location->{lon};

	my $options  = 'lang=de&units=si&exclude=currently,minutely,daily,alerts,flags&extend=hourly';

	my $offset   = tz_local_offset();
	my $timebase = time - (time%86400) - $offset;

	my $api      = 'https://api.darksky.net/forecast';
	my $urlfd = $api . '/' . $api_key . '/' . $lat . ',' . $lon . ',' . $timebase . "?$options";
	my $urlnd = $api . '/' . $api_key . '/' . $lat . ',' . $lon . "?$options";

	print "URL first day: $urlfd\nURL next days: $urlnd";

	my $responsefd = get($urlfd);
	my $forecastfd = decode_json( $responsefd );

	my $responsend = get($urlnd);
	my $forecastnd = decode_json( $responsend );

	my @probabs;
	my $lastts = 0;
	for(my $i=0; defined $forecastfd->{hourly}->{data}[$i]; ++$i) {
		push(@probabs, $forecastfd->{hourly}->{data}[$i]->{precipProbability});
		$lastts = $forecastfd->{hourly}->{data}[$i]->{time};
	}

	for(my $i=0; defined $forecastnd->{hourly}->{data}[$i]; ++$i) {
		next if $forecastnd->{hourly}->{data}[$i]->{time}<=$lastts;
		last if $forecastnd->{hourly}->{data}[$i]->{time} >=
			$timebase + 3*86400;
		push(@probabs, $forecastnd->{hourly}->{data}[$i]->{precipProbability});
	}

	return @probabs;
}

sub renderForecast($$) {
	my $location = $_[0];
	return "Geolokation nicht möglich" if !$location;
	my $forecast = $_[1];

	my $postcode = $location->{address}->{postcode};
	my $town     = $location->{address}->{town};
	my $city     = $location->{address}->{city};
	my $country  = $location->{address}->{country};
	my $dispname = $location->{display_name};

	my $place = "";
	if($town or $city) {
		if($town) {
			$place .= $town;
		}else{
			$place .= $city;
		}
		$place .= " ($postcode)" if $postcode;
		$place .= ' ' . $country if $country;
	}else{
		$place = $dispname;
	}

	my $output = "\x02Wetter für $place ";
	$output .= "\x0305" . "!\x03" if defined $forecast->{alerts};
	my $alert = '';
	$alert = $forecast->{alerts}[0]->{description} if defined $forecast->{alerts};
	$output .= "\n";

	my $hourly = $forecast->{hourly};

	my $day = strftime("%a",localtime($hourly->{data}[0]->{time}));
	$output .= "\x02$day:\x02 ";

	my $i=0;
	my $multi = 0;
	
	# fast forward to first relevant data point
	while( 
		!( strftime("%H", localtime($hourly->{data}[$i]->{time})) 
		~~ [ 6, 12, 18, 0]) 
		) {
		++$i;
		last if $i > 10; # full brake
	}

	# how far we have to intend the first value
	my $hour = strftime("%H", localtime($hourly->{data}[$i]->{time}));
	if($hour==6) {     # 06 12 18 00
		$multi = 0;
	}elsif($hour==12){ # ...12 18 00
		$multi = 1;
	}elsif($hour==18){ # ......18 00
		$multi = 2;
	}else{             # .........00
		$multi = 3;
	}

	my $fill = "                         ";

	my $line=0;
	my $first = 1;
	while(1) { # Zeilen
		$hour=strftime("%H", localtime($hourly->{data}[$i]->{time}));

		if( $hour ~~ [6, 12, 18, 0] ) {
			if($first) {
				for(my $f=0; $f<$multi; ++$f) {
					print $f;
					$output .= $fill;
				}
			}

			$day = strftime("%a",localtime($hourly->{data}[$i]->{time}));
			$output .= "\x02$day:\x02 " if $hour == 6 and $line != 0;
			
			my $temp = sprintf("%3.0f",$hourly->{data}[$i]->{temperature});
			$temp =~ s/ / /g;
			my $rain = sprintf("%3.0f",
				$hourly->{data}[$i]->{precipProbability}*100);
			$rain =~ s/ / /g;
			my $icon = sprintf("%-13s", 
				replaceIcon($hourly->{data}[$i]->{icon},0));
			$icon =~ s/ / /g;

			$output .= 
				"\x0303" . $temp . "\x03°C " . # "℃ / ".
				"\x0310" . $rain . "\x03% " .
				$icon;
				$output .= " ";
		}

		last if !defined $hourly->{data}[$i];
		last if(strftime("%j",localtime($hourly->{data}[$i]->{time})) - strftime("%j",localtime(time)) >= 3);

		++$i;
		$output .= "\n" if $hour == 0;
		++$line if $hour == 0;
		$first = 0;
	}
	$output .= "\n" . $alert if $alert ne '';
	return $output;
}

sub renderTempForecast($@) {
	my $location = $_[0];
	return "Geolokation nicht möglich" if !$location;
	my @temps = @{$_[1]};

	return "unzureichende Temperaturdaten ($#temps)" if $#temps<71;

	my $minTempColor = "\x0303"; # green
	my $maxTempColor = "\x0305"; # red

	my $postcode = $location->{address}->{postcode};
	my $town     = $location->{address}->{town};
	my $city     = $location->{address}->{city};
	my $country  = $location->{address}->{country};
	my $dispname = $location->{display_name};

	my $place = "";
	if($town or $city) {
		if($town) {
			$place .= $town;
		}else{
			$place .= $city;
		}
		$place .= " ($postcode)" if $postcode;
		$place .= ' ' . $country if $country;
	}else{
		$place = $dispname;
	}

	my $output = "\x02Temperaturverlauf für $place\n";

	for(my $i=0; $i<3; ++$i) { # Zeilen
		my $day = strftime("%a",localtime(time+24*60*60*$i));
		$output .= "    \x02$day:\x02 ";
		
		my @dayTemps;
		for(my $j=0; $j<24; ++$j) {
			my $val = shift(@temps);
			push(@dayTemps, $val);
		}
		
		my ($min, $max) = minmax(@dayTemps);
		
		$output .= arrayToGraph(@dayTemps) . 
			sprintf(
				$minTempColor . " %.0f°C " . 
				$maxTempColor . "%.0f°C\n", 
				$min, $max
			);
	}
	return $output;
}

sub renderRainForecast($\@;$;$) {
	my $location = $_[0];
	return "Geolokation nicht möglich" if !$location;
	my @probabs = @{$_[1]};

	return "unzureichende Niederschlagsdaten ($#probabs)" if $#probabs<71;

	my $minRainColor = "3"; # green
	my $maxRainColor = "05"; # red

	$minRainColor = "$_[2]" if defined $_[2];
	$maxRainColor = "$_[3]" if defined $_[3];

	print "min: $minRainColor max: $maxRainColor";

	my $postcode = $location->{address}->{postcode};
	my $town     = $location->{address}->{town};
	my $city     = $location->{address}->{city};
	my $country  = $location->{address}->{country};
	my $dispname = $location->{display_name};

	my $place = "";
	if($town or $city) {
		if($town) {
			$place .= $town;
		}else{
			$place .= $city;
		}
		$place .= " ($postcode)" if $postcode;
		$place .= ' ' . $country if $country;
	}else{
		$place = $dispname;
	}

	my $output = "\x02Niederschlagswahrscheinlichkeit für $place\n";

	for(my $i=0; $i<3; ++$i) { # Zeilen
		my $day = strftime("%a",localtime(time+24*60*60*$i));
		$output .= "    \x02$day:\x02 ";
		
		my @dayProbabs;
		for(my $j=0; $j<24; ++$j) {
			my $val = shift(@probabs);
			push(@dayProbabs, $val);
		}
		
		my ($min, $max) = minmax(@dayProbabs);
		
		$output .= arrayToGraph(@dayProbabs,'03','02','11','14') . 
			sprintf(
				"\x03$minRainColor" . " %d%% \x03" . 
				"\x03$maxRainColor" . "%d%%\x03\n", 
				$min*100, $max*100
			);
	}
	return $output;
}

sub arrayToGraph(\@;$;$;$;$) {
	my @vals = @{$_[0]};
	my @bars = ( '▁','▂','▃','▄','▅','▆','▇','█' );
	my ($min, $max) = minmax(@vals);
	my $delta = abs($max - $min);
	my $step = ($delta / $#bars);

	my $minColor = "03"; # green
	my $maxColor = "05"; # red
	my $negColor = "10"; # cyan
	my $sepColor = "14"; # grey

	$minColor = $_[1] if defined $_[1];
	$maxColor = $_[2] if defined $_[2];
	$negColor = $_[3] if defined $_[3];
	$sepColor = $_[4] if defined $_[4];

	my @limits;
	for(my $i=0; $i<=$#bars; ++$i) {
		$limits[$i] = ($min + $i * $step); 
	}

	my $outstr = "";
	my $count=0;
	foreach my $val (@vals) {
		if($count%6 or $count==0) {
		#	$outstr .= "\x0315|\x03";
		#	$outstr .= '|';
		}else{
			$outstr .= "\x03$sepColor|\x03";
		}
		++$count;
		for(my $i=0; $i<=$#bars; ++$i) {
			next if($i+1<$#bars+1 and $val > $limits[$i+1]);
			if($val == $min) {
				$outstr .= "\x03$minColor" . $bars[$i] . "\x03";
			}elsif($val == $max) {
				$outstr .= "\x03$maxColor" . $bars[$i] . "\x03";
			}elsif($val < 0) {
				$outstr .= "\x03$negColor" . $bars[$i] . "\x03";
			}else{
				$outstr .= $bars[$i];
			}
			last;
		}
	}
	return $outstr;
}

sub replaceIcon($$) {
	my $icon = $_[0];
	my $iconize = $_[1];

	if($iconize) {
		given($icon) {
			when(/^clear-day$/)           { return "🌣"; }
			when(/^clear-night$/)         { return "☾"; }
			when(/^rain$/)                { return "🌧"; }
			when(/^snow$/)                { return "🌨"; }
			when(/^sleet$/)               { return "🌨"; }
			when(/^wind$/)                { return "🌬"; }
			when(/^fog&/)                 { return "🌫"; }
			when(/^cloudy&/)              { return "🌥"; }
			when(/^partly-cloudy-day$/)   { return "🌤"; }
			when(/^partly-cloudy-night$/) { return "🌤"; }
			when(/^hail$/)                { return "🌨"; }
			when(/^thunderstorm$/)        { return "🌩"; }
			when(/^tornado$/)             { return "🌪"; }
			default { return "?" }
		}
	}else{
		given($icon) {
			when(/^clear-day$/)           { return "heiter"; }
			when(/^clear-night$/)         { return "heiter"; }
			when(/^rain$/)                { return "Regen"; }
			when(/^snow$/)                { return "Schnee"; }
			when(/^sleet$/)               { return "Schneeregen"; }
			when(/^wind$/)                { return "windig"; }
			when(/^fog$/)                 { return "nebelig"; }
			when(/^cloudy$/)              { return "bewölkt"; }
			when(/^partly-cloudy-day$/)   { return "teils bewölkt"; }
			when(/^partly-cloudy-night$/) { return "teils bewölkt"; }
			when(/^hail$/)                { return "Hagel"; }
			when(/^thunderstorm$/)        { return "Gewitter"; }
			when(/^tornado$/)             { return "Tornado"; }
			default { return $icon }
		}
	}
}

