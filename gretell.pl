#!/usr/bin/perl

#
# ===========================================================================
# Copyright (C) 2007 Marc H. Thoben
# Copyright (C) 2008 Darshan Shaligram
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
# ===========================================================================
#

use strict;
use warnings;

use POE qw(Component::IRC);
use POSIX qw(setsid); # For daemonization.

my $nickname       = 'Gretell';
my $ircname        = 'Gretell the Crawl Bot';
my $ircserver      = 'kornbluth.freenode.net';
my $port           = 8001;
my $channel        = '##crawl';
my @stonefiles     = ('/var/lib/dgamelaunch/crawl-rel/saves/milestones',
                      '/var/lib/dgamelaunch/crawl-svn/saves/milestones',
                      '/var/lib/dgamelaunch/crawl-old/saves/milestones');
my @logfiles       = ('/var/lib/dgamelaunch/crawl-rel/saves/logfile',
                      '/var/lib/dgamelaunch/crawl-svn/saves/logfile',
                      '/var/lib/dgamelaunch/crawl-old/saves/logfile');
my @whereis_path   = ('/var/lib/dgamelaunch/crawl-rel/saves/',
                      '/var/lib/dgamelaunch/crawl-svn/saves/',
                      '/var/lib/dgamelaunch/crawl-old/saves/');

my $MAX_LENGTH = 500;

my %COMMANDS = (
  '@whereis' => \&cmd_whereis,
  '@?' => \&cmd_monsterinfo,
);

## Daemonify. http://www.webreference.com/perl/tutorial/9/3.html
#umask 0;
#defined(my $pid = fork) or die "Unable to fork: $!";
#exit if $pid;
#setsid or die "Unable to start a new session: $!";
## Done daemonifying.

my @stonehandles = open_handles(@stonefiles);
my @loghandles = open_handles(@logfiles);

# We create a new PoCo-IRC object and component.
my $irc = POE::Component::IRC->spawn( 
      nick    => $nickname,
      server  => $ircserver,
      port    => $port,
      ircname => $ircname,
) or die "Oh noooo! $!";

POE::Session->create(
      inline_states => {
        check_files => \&check_files,
        irc_public  => \&irc_public,
      },

      package_states => [
        'main' => [
          qw(_default _start irc_001 irc_255)
        ],
      ],
      heap => {
        irc => $irc
      },
);

$poe_kernel->run();
exit 0;

sub open_handles
{
  my (@files) = @_;
  my @handles;

  for my $file (@files) {
    open my $handle, '<', $file or do { 
	  warn "Unable to open $file for reading: $!";
	  next;
	};
    seek($handle, 0, 2); # EOF
    push @handles, [ $file, $handle, tell($handle) ];
  }
  return @handles;
}

sub newsworthy
{
  my $stone_ref = shift;

  return 0
    if $stone_ref->{type} eq 'enter'
      and grep {$stone_ref->{br} eq $_} qw/Temple/;

  return 0
    if $stone_ref->{type} eq 'unique'
      and grep {index($stone_ref->{milestone}, $_) > -1}
        qw/Terence Jessica Blork Edmund Psyche Donald Snorg Michael/;

  return 1;
}

sub parse_milestone_file
{
  my $href = shift;
  my $stonehandle = $href->[1];
  $href->[2] = tell($stonehandle);

  my $line = <$stonehandle>;
  # If the line isn't complete, seek back to where we were and wait for it
  # to be done.
  if (!defined($line) || $line !~ /\n$/) {
    seek($stonehandle, $href->[2], 0);
    return;
  }
  $href->[2] = tell($stonehandle);
  return unless defined($line) && $line =~ /\S/;

  my $game_ref = demunge_xlogline($line);

  return unless newsworthy($game_ref);

  my $placestring = " ($game_ref->{place})";
  if ($game_ref->{milestone} eq "escaped from the Abyss!")
  {
    $placestring = "";
  }

  $irc->yield(privmsg => $channel =>
    sprintf "%s (L%s %s) %s%s",
      $game_ref->{name},
      $game_ref->{xl},
      $game_ref->{char},
      $game_ref->{milestone},
      $placestring
  );

  seek($stonehandle, $href->[2], 0);
}

sub parse_log_file
{
  my $href = shift;
  my $loghandle = $href->[1];

  $href->[2] = tell($loghandle);
  my $line = <$loghandle>;
  if (!defined($line) || $line !~ /\n$/) {
    seek($loghandle, $href->[2], 0);
    return;
  }
  $href->[2] = tell($loghandle);
  return unless defined($line) && $line =~ /\S/;
  my $game_ref = demunge_xlogline($line);
  if ($game_ref->{sc} > 2000 || ($game_ref->{ktyp} ne 'quitting' && $game_ref->{ktyp} ne 'leaving' && $game_ref->{turn} >= 30))
  {
    my $output = pretty_print($game_ref);
    $output =~ s/ on \d{4}-\d{2}-\d{2}//;
    $irc->yield(privmsg => $channel => $output);
  }
  seek($loghandle, $href->[2], 0);
}

sub check_stonefiles
{
  for my $stoneh (@stonehandles) {
    parse_milestone_file($stoneh);
  }
}

sub check_logfiles
{
  for my $logh (@loghandles) {
    parse_log_file($logh);
  }
}

sub check_files
{
  $_[KERNEL]->delay('check_files' => 1);

  check_stonefiles();
  check_logfiles();
}

# We registered for all events, this will produce some debug info.
sub _default
{
  my ($event, $args) = @_[ARG0 .. $#_];
  my @output = ( "$event: " );

  foreach my $arg ( @$args ) {
      if ( ref($arg) eq 'ARRAY' ) {
              push( @output, "[" . join(" ,", @$arg ) . "]" );
      } else {
              push ( @output, "'$arg'" );
      }
  }
  print STDOUT join ' ', @output, "\n";
  return 0;
}

sub _start
{
  my ($kernel,$heap) = @_[KERNEL,HEAP];

  # We get the session ID of the component from the object
  # and register and connect to the specified server.
  my $irc_session = $heap->{irc}->session_id();
  $kernel->post( $irc_session => register => 'all' );
  $kernel->post( $irc_session => connect => { } );
  undef;
}

sub irc_001
{
  my ($kernel,$sender) = @_[KERNEL,SENDER];

  # Get the component's object at any time by accessing the heap of
  # the SENDER
  my $poco_object = $sender->get_heap();
  print "Connected to ", $poco_object->server_name(), "\n";

  # In any irc_* events SENDER will be the PoCo-IRC session
  $kernel->post( $sender => join => $channel );
  undef;
}

sub irc_255
{
  $_[KERNEL]->yield("check_files");

  open(my $handle, '<', 'password') or warn "Unable to read password: $!";
  my $password = <$handle>;
  chomp $password;

  $irc->yield(privmsg => "nickserv" => "identify $password");
}

sub irc_public {
  my ($kernel,$sender,$who,$where,$verbatim) = 
        @_[KERNEL,SENDER,ARG0,ARG1,ARG2];
  return unless $kernel && $sender && $who && $where && $verbatim;

  my $nick = get_nick($who) or return;
  my $command = get_command($verbatim) or return;
  my $channel = $where->[0] or return;

  process_command($command, $kernel, $sender, $nick, $channel, $verbatim);

  undef;
}

sub sanitise_nick {
  my $nick = shift;
  return unless $nick;
  $nick =~ tr/a-zA-Z_0-9-//cd;
  return $nick;
}

sub get_nick {
  my $who = shift;
  my ($nick) = $who =~ /(.*?)!/;
  return $nick? sanitise_nick($nick) : undef;
}

sub get_command {
  my $verbatim_input = shift;
  my ($command) = $verbatim_input =~ /^(\S+)/;
  return $command;
}

sub post_message {
  my ($kernel, $sender, $channel, $msg) = @_;
  $kernel->post($sender => privmsg => $channel => $msg);
}

#######################################################################
# Commands

sub process_command {
  my ($command, $kernel, $sender, $nick, $channel, $verbatim) = @_;
  if (substr($command, 0, 2) eq '@?')
  {
	$command = "@?";
  }
  my $proc = $COMMANDS{$command} or return;
  &$proc($kernel, $sender, $nick, $channel, $verbatim);
}

sub find_named_nick {
  my ($default, $command) = @_;
  $default = sanitise_nick($default);
  my $named = (split ' ', $command)[1] or return $default;
  return sanitise_nick($named) || $default;
}

sub cmd_monsterinfo {
  my ($kernel, $sender, $nick, $channel, $verbatim) = @_;

  my $monster_name = substr($verbatim, 2);
  my $monster_info = `monster $monster_name`;
  $monster_info = substr($monster_info, 0, $MAX_LENGTH) if length($monster_info) > $MAX_LENGTH;
  post_message($kernel, $sender, $channel, $monster_info);
}

sub cmd_whereis {
  my ($kernel, $sender, $nick, $channel, $verbatim) = @_;
  
  # Get the nick to act on.
  my $realnick = find_named_nick($nick, $verbatim);
  my $where_file;
  my $final_where;

  for my $where_path (@whereis_path) {
    my $where_file = "$where_path/$realnick.where";
    if (-r $where_file) {
      if (defined($final_where) && length($final_where) > 0) {
        if ((stat($final_where))[9] < (stat($where_file))[9]) {
          $final_where = $where_file;
        }
      }
      else {
        $final_where = $where_file;
      }
    }
  }

  unless (defined($final_where) && length($final_where) > 0) {
    post_message($kernel, $sender, $channel,
                 "No where information for $realnick ($final_where).");
    return;
  }

  open my $in, '<', $final_where
    or do {
      post_message($kernel, $sender, $channel, 
                   "Couldn't fetch where information for $realnick.");
      return;
    };

  chomp( my $where = <$in> );
  close $in;

  show_where_information($kernel, $sender, $channel, $where);
}

sub format_crawl_date {
  my $date = shift;
  return '' unless $date;
  my ($year, $mon, $day) = $date =~ /(.{4})(.{2})(.{2})/;
  return '' unless $year && $mon && $day;
  $mon++;
  return sprintf("%04d-%02d-%02d", $year, $mon, $day);
}

sub show_where_information {
  my ($kernel, $sender, $channel, $where) = @_;
  my $wref = demunge_xlogline($where);
  return unless $wref;

  my %wref = %$wref;

  my $place = $wref{place};
  my $preposition = index($place, ':') != -1? " on" : " in";
  $place = "the $place" if $place eq 'Abyss' || $place eq 'Temple';
  $place = " $place";

  my $punctuation = '.';
  my $date = ' on ' . format_crawl_date($wref{time});

  my $turn = " after $wref{turn} turns";
  chop $turn if $wref{turn} == 1;

  my $what = $wref{status};
  my $msg;
  if ($what eq 'active') {
    $what = 'is currently';
    $date = '';
  }
  elsif ($what eq 'won') {
    $punctuation = '!';
    $preposition = $place = '';
  }
  elsif ($what eq 'bailed out') {
    $what = 'got out of the dungeon alive';
    $preposition = $place = '';
  }
  $what = " $what";

  my $god = $wref{god}? ", a worshipper of $wref{god}," : "";
  unless ($msg) {
    $msg = "$wref{name} the $wref{title} (L$wref{xl} $wref{char})" . 
           "$god$what$preposition$place$date$turn$punctuation";
  }
  post_message($kernel, $sender, $channel, $msg);
}

#######################################################################
# Imports

sub pretty_print
{
  my $game_ref = shift;

  my $loc_string = "";
  if ($game_ref->{ltyp} ne 'D')
  {
    $loc_string = " in $game_ref->{place}";
  }
  else
  {
    if ($game_ref->{br} eq 'blade' or $game_ref->{br} eq 'temple' or $game_ref->{br} eq 'hell')
    {
      $loc_string = " in $game_ref->{place}";
    }
    else
    {
      $loc_string = " on $game_ref->{place}";
    }
  }
  $loc_string = "" # For escapes of the dungeon, so it doesn't print the loc
    if $game_ref->{ktyp} eq 'winning' or $game_ref->{ktyp} eq 'leaving';

  $game_ref->{end} =~ /^(\d{4})(\d{2})(\d{2})/;
  my $death_date = " on " . $1 . "-" . sprintf("%02d", $2 + 1) . "-" . $3;

  my $deathmsg = $game_ref->{vmsg} || $game_ref->{tmsg};
  $deathmsg =~ s/!$//;
  sprintf '%s the %s (L%d %s)%s, %s%s%s, with %d point%s after %d turn%s and %s.',
      $game_ref->{name},
      $game_ref->{title},
      $game_ref->{xl},
      $game_ref->{char},
      exists $game_ref->{god} ? ", worshipper of $game_ref->{god}" : '',
      $deathmsg,
      $loc_string,
      $death_date,
      $game_ref->{sc},
      $game_ref->{sc} == 1 ? '' : 's',
      $game_ref->{turn},
      $game_ref->{turn} == 1 ? '' : 's',
      serialize_time($game_ref->{dur})
}

sub demunge_xlogline
{
  my $line = shift;
  return {} if $line eq '';
  my %game;

  chomp $line;
  die "Unable to handle internal newlines." if $line =~ y/\n//;
  $line =~ s/::/\n\n/g;
  
  while ($line =~ /\G(\w+)=([^:]*)(?::(?=[^:])|$)/cg)
  {
    my ($key, $value) = ($1, $2);
    $value =~ s/\n\n/:/g;
    $game{$key} = $value;
  }

  if (!defined(pos($line)) || pos($line) != length($line))
  {
    my $pos = defined(pos($line)) ? "Problem started at position " . pos($line) . "." : "Regex doesn't match.";
    die "Unable to demunge_xlogline($line).\n$pos";
  }

  return \%game;
}

sub serialize_time
{
  my $seconds = int shift;
  my $long = shift;

  if (not $long)
  {
    my $hours = int($seconds/3600);
    $seconds %= 3600;
    my $minutes = int($seconds/60);
    $seconds %= 60;

    return sprintf "%d:%02d:%02d", $hours, $minutes, $seconds;
  }
  
  my $minutes = int($seconds / 60);
  $seconds %= 60;
  my $hours = int($minutes / 60);
  $minutes %= 60;
  my $days = int($hours / 24);
  $hours %= 24;
  my $weeks = int($days / 7);
  $days %= 7;
  my $years = int($weeks / 52);
  $weeks %= 52;

  my @fields;
  push @fields, "about ${years}y" if $years;
  push @fields, "${weeks}w"       if $weeks;
  push @fields, "${days}d"        if $days;
  push @fields, "${hours}h"       if $hours;
  push @fields, "${minutes}m"     if $minutes;
  push @fields, "${seconds}s"     if $seconds;

  return join ' ', @fields if @fields;
  return '0s';
}

