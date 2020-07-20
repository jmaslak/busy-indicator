#!/usr/bin/env perl6
use v6;

#
# Copyright © 2019-2020 Joelle Maslak
# All Rights Reserved - See License
#

use Term::ReadKey;
use Term::termios;
use Terminal::ANSIColor;

my @GCAL-CMD = <gcalcli --nocolor --calendar _CALENDAR_ agenda --military --tsv --nodeclined>;
my @LUXAFOR-CMD  = <python luxafor-linux.py color>;
my $MODULES-FILE = "/proc/modules";
my $CAMERA-MOD   = "uvcvideo";

class Appointment {
    has DateTime:D $.start       is required;
    has DateTime:D $.end         is required;
    has Str:D      $.description is required;

    method in-meeting(UInt:D :$fuzz = 120 -->Bool) {
        my $fz = Duration.new($fuzz);
        if ($.start - $fz) ≤ DateTime.now ≤ ($.end + $fz) {
            return True;
        } else {
            return False;
        }
    }

    method future-meeting(UInt:D :$fuzz = 0 -->Bool) {
        my $fz = Duration.new($fuzz);
        if ($.start - $fz) ≥ DateTime.now {
            return True;
        } else {
            return False;
        }
    }

    method is-long-meeting(UInt:D :$long = 3600*4 -->Bool) {

        # We don't want to show the LED for the fake meeting used by the
        # pseudo-appointment the camera app adds.
        my $fake-long-meeting = 3600*24*365*1000; # 1000 years

        my $duration = $.end - $.start;
        return $long < $duration < $fake-long-meeting;
    }

    method Str(-->Str) { return "$.start $.end $.description" }

    method human-printable(-->Str) {
        return "%02d:%02d %s".sprintf($.start.hour, $.start.minute, $.description);
    }
}

sub MAIN(Str:D :$calendar, Int:D :$interval = 60) {
    my Channel:D $channel = Channel.new;
    my Str:D @calendar = $calendar.split(",");

    start-background(@calendar, $channel, $interval);

    time-note "Fetching meetings from Google";

    # Main loop
    react {
        my @appointments;
        my Bool:D $camera = False;
        my Bool:D $google-success = False;
        whenever $channel -> $key {
            if $key ~~ List {
                @appointments = $key<>;
                if ! $google-success {
                    $google-success = True;
                    display-future-meetings(@appointments);
                    display(@appointments, $camera);
                }
            } elsif $key eq 'tick' {
                display(@appointments, $camera) if $google-success;
            } elsif $key eq 'camera on' {
                $camera = True;
                display(@appointments, $camera);
            } elsif $key eq 'camera off' {
                $camera = False;
                display(@appointments, $camera);
            } elsif $key eq 'h'|'?' {
                display-help;
            } elsif $key eq 'b' {
                # Turn light on for (B)usy
                time-say 'red', "Setting indicator to BUSY";
                display(:red, @appointments, $camera);
            } elsif $key eq 'o' {
                # Turn light (O)ff for this meeting
                time-note "Turning indicator to OFF until next meeting";
                display(:off, @appointments, $camera);
            } elsif $key eq 'g' {
                # Turn light to (G)reen
                time-say 'green', "Turning indicator to GREEN";
                display(:green, @appointments, $camera);
            } elsif $key eq 'q' {
                time-note "Quitting";
                my $flags := Term::termios.new(:fd($*IN.native-descriptor)).getattr;
                $flags.set_lflags('ECHO');
                $flags.setattr(:NOW);
                exit;
            } elsif $key eq 'n' {
                display-next-meeting(@appointments);
            } elsif $key eq 'a' {
                display-future-meetings(@appointments);
            } elsif $key eq '.' {
                display(@appointments, $camera);
            } else {
                time-note "Unknown key press";
                display(@appointments, $camera);
            }
        }
    }
}

sub start-background(Str:D @calendar, Channel:D $channel, Int:D $interval --> Nil) {
    # Start ticks
    start {
        my $now = DateTime.now;
        if $now.second {
            # Start at 00:00
            sleep 60 - $now.second if $now.second; # Start at 00:00
        }

        react {
            whenever Supply.interval($interval) { $channel.send('tick') }
        }
    }

    # Google Monitor
    start {
        my @appointments = get-appointments-from-google(@calendar)<>;
        $channel.send(@appointments);
        
        react {
            whenever Supply.interval($interval) {
                @appointments = get-appointments-from-google(@calendar)<>;
                $channel.send(@appointments);
            }
        }
    }

    # Camera monitor
    start {
        my $camera = False;
        react {
            whenever Supply.interval(1) {
                my $new-camera = get-camera();
                if $new-camera ≠ $camera {
                    $camera = $new-camera;
                    $channel.send: 'camera ' ~ ( $camera ?? "on" !! "off" );
                }
            }
        }
    }

    # Key presses
    start {
        react {
            whenever key-pressed(:!echo) {
                $channel.send(.fc);
            }
        }
    }
}

sub display(@appointments is copy, Bool $camera, :$off, :$red, :$green --> Nil) {
    state @ignores;
    state $manual;
    state $last-green;

    my $next = @appointments.grep(*.future-meeting).first;

    # Add fake appointment if we're in a call.
    if $camera {
        my $start = DateTime.new("1900-01-01T00:00:00Z");
        my $end   = DateTime.new("9999-01-01T00:00:00Z");
        @appointments.push: Appointment.new( :$start, :$end, :description("In video call") );
    }

    my @current = @appointments.grep(*.in-meeting).grep(! *.is-long-meeting);
    
    if $off {
        @ignores    = @current;
        $manual     = False;
        $last-green = False;
    }

    if @current.elems == 0 and @ignores.elems {
        @ignores = ();
    }
    
    @current = @current.grep(*.Str ∉  @ignores».Str);

    if $red {
        $manual     = True;
        $last-green = False;
    } elsif $green {
        $manual     = False;
        $last-green = True;
    }

    if $manual {
        time-say 'red', "Busy indicator turned on manually";
        light-red;
    } elsif $last-green {
        time-say 'green', "Indicator turned green manually";
        light-green;
    } elsif @current.elems {
        my @active      = @current.grep(*.in-meeting(:fuzz(0)));
        my $now-meeting = @active.elems ?? @active[0] !! @current[0];

        time-say 'red', "In meeting: {$now-meeting.description}";
        light-red;
    } else {
        if @ignores.elems {
            time-note "Not in a meeting (manual override)";
        } else {
            if $next.defined {
                time-note "Not in a meeting (next: {$next.human-printable})";
            } else {
                time-note "Not in a meeting";
            }
        }
        light-off;
    }

    CATCH: {
        return; # Just vaccum up the errors
    }
}

sub display-future-meetings(@appointments is copy --> Nil) {
    my @future = @appointments.grep(*.future-meeting)<>;
    if @future.elems > 0 {
        time-note "Today's meetings:";
        for @future -> $meeting {
            time-note "    " ~ $meeting.human-printable;
        }
    } else {
        time-note "Today's meetings: no meetings today";
    }
}

sub display-next-meeting(@appointments is copy --> Nil) {
    my $next = @appointments.grep(*.future-meeting).first;
    if $next.defined {
        time-note "Next meeting: " ~ $next.human-printable;
    } else {
        time-note "Next meeting: No more meetings today";
    }
}

sub display-help(--> Nil) {
    time-note "HELP:";
    time-note "  a = display all future meetings";
    time-note "  b = set light to busy (red)";
    time-note "  g = set light to green";
    time-note "  o = turn light to off (until next meeting)";
    time-note "  n = display next meeting";
    time-note "  q = quit";
    time-note "  . = refresh";
}

sub get-camera(-->Bool:D) {
    my @modules = $MODULES-FILE.IO.lines».split(" ");
    for @modules -> $module {
        if $module[0] eq $CAMERA-MOD {
            return $module[2] ≠ 0;
        }
    }
    return False;
}

sub get-appointments-from-google(Str:D @calendar) {
    my $now      = DateTime.now;
    my $offset   = S/^.* <?before <[ + \- ]> >// with ~$now;
    my $tomorrow = $now.later(:1day);

    my @output = gather {
        for @calendar -> $calendar {
            my @gcal = @GCAL-CMD.map: { $^a eq '_CALENDAR_' ?? $calendar !! $^a };

            my $proc = run @gcal, $now.yyyy-mm-dd, $tomorrow.yyyy-mm-dd, :out;
            my @appts = $proc.out.slurp(:close).lines;
            for @appts -> $appt-line {
                my ($startdt, $starttm, $enddt, $endtm, $desc) = $appt-line.split("\t");
                my $start = DateTime.new("{$startdt}T{$starttm}:00{$offset}");
                my $end   = DateTime.new("{$enddt}T{$endtm}:00{$offset}");

                take Appointment.new( :$start, :$end, :description($desc) );
            }
        }
    }

    return @output.sort.unique;
}

sub light-red()   { light-command(20,  0, 0) }
sub light-green() { light-command( 0, 20, 0) }
sub light-off()   { light-command( 0,  0, 0) }

sub light-command($r, $g, $b) {
    state $last = '';
    state $sent-times = 0;

    if "$r $g $b" eq $last {
        $sent-times++;
        return if $sent-times > 2;
    } else {
        $sent-times = 1;
    }

    my $proc = run :out, :err, @LUXAFOR-CMD, '-r', $r, '-g', $g, '-b', $b;
    
    time-say 'red', "ERROR: LED not responding" unless $proc.so;
    return;
}

sub time-say(Str:D $color, +@args --> Nil) {
    my $now = DateTime.now;
    print color($color);
    say "{$now.yyyy-mm-dd} {$now.hh-mm-ss} ", |@args;
    print color($color);
}

sub time-note(+@args --> Nil) { time-say "white", |@args }


