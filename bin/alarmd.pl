#!/usr/bin/perl
# Instar2Lox - MQTT alarm listener.
# Subscribes to the INSTAR alarm topic on the LoxBerry broker and forwards
# every alarm as a UDP pulse "<prefix>.<camera>.alarm=<trigger>" followed by
# "<prefix>.<camera>.alarm=0" after alarm_pulse_sec.
#
# Topic layout of INSTAR Full HD: <prefix>/<MAC>/status/alarm/triggered
# with payload {"val":"<trigger>"}. The second topic level identifies the camera
# and is matched against the camera's MQTT ID (default: its MAC without colons).
#
# Started and watched by worker.pl; can also be run in the foreground for debugging.

use strict;
use warnings;
use JSON;
use Time::HiRes qw(time);
use LoxBerry::System;
use LoxBerry::Log;

require "$lbpbindir/Instar2Lox.pm";

my $log = LoxBerry::Log->new(
    name => 'alarmd', filename => "$lbplogdir/alarmd.log", append => 1, addtime => 1, stderr => 0,
);
truncate("$lbplogdir/alarmd.log", 0) if -s "$lbplogdir/alarmd.log" && -s _ > 1_000_000;

if (my $other = Instar2Lox::alarmd_pid()) {
    exit 0 if $other != $$;
}
open(my $pf, '>', $Instar2Lox::PID_FILE) or die "Cannot write pid file: $!";
print $pf $$; close $pf;

my $running = 1;
$SIG{TERM} = $SIG{INT} = sub { $running = 0; };
$SIG{__DIE__} = sub {
    return if $^S;    # inside eval
    LOGCRIT("Alarm listener crashed: $_[0]");
    unlink $Instar2Lox::PID_FILE;
};

eval { require Net::MQTT::Simple; 1 } or do {
    LOGCRIT("Perl module Net::MQTT::Simple not available - cannot listen for alarms");
    unlink $Instar2Lox::PID_FILE; exit 1;
};
$ENV{MQTT_SIMPLE_ALLOW_INSECURE_LOGIN} = 1;

my ($c, $cfg_mtime, %by_id, $map_time);
my %pending;     # cam_id => epoch when alarm=0 is due
my %last_sent;   # cam_id => epoch of the last alarm forwarded to Loxone
my %traffic;     # topic ID (2nd level) => { last, count, last_topic }
my ($traffic_dirty, $traffic_saved) = (0, 0);
my ($sub_topic, $alarm_re);

# Subscribe to the whole prefix (e.g. instar/#) so every camera that talks to the
# broker is visible in the UI; alarms are filtered with the configured pattern.
sub topics_from_cfg {
    my $at = $c->{global}{alarm_topic};
    my ($root) = split m{/}, $at;
    $sub_topic = "$root/#";
    my $re = join('/', map { $_ eq '+' ? '[^/]+' : $_ eq '#' ? '.*' : quotemeta($_) } split(m{/}, $at, -1));
    $alarm_re = qr{^$re$};
}

sub save_traffic {
    my $f = "$lbpdatadir/mqtt_traffic.json";
    my $old = Instar2Lox::load_json($f, {});
    $old->{ids}{$_} = $traffic{$_} for keys %traffic;
    Instar2Lox::save_json_atomic($f, $old);
    ($traffic_dirty, $traffic_saved) = (0, time());
}

sub on_any {
    my ($topic, $msg) = @_;
    my @parts = split m{/}, $topic;
    my $key = uc($parts[1] // '');
    if (length $key) {
        my $t = $traffic{$key} ||= { count => 0 };
        $t->{last} = int(time()); $t->{count}++; $t->{last_topic} = $topic;
        $traffic_dirty = 1;
    }
    on_message($topic, $msg) if $topic =~ $alarm_re;
}

sub load_map {
    $c = Instar2Lox::load_cfg();
    $cfg_mtime = (stat($Instar2Lox::CFG_FILE))[9] // 0;
    my $st = Instar2Lox::read_state();
    my $bl = Instar2Lox::broker_log_info();
    %by_id = ();
    for my $cam (@{ $c->{cameras} }) {
        $by_id{$_} = $cam for Instar2Lox::topic_ids($cam, $st, $bl);
    }
    $map_time = time();
}

sub save_alarm {
    my ($id, $val, $topic) = @_;
    my $as = Instar2Lox::load_json($Instar2Lox::ALARM_FILE, {});
    if (defined $id) {
        my $e = $as->{cams}{$id} ||= {};
        $e->{last} = int(time()); $e->{val} = $val; $e->{count} = ($e->{count} // 0) + 1;
    } else {
        my $u = $as->{unknown} ||= {};
        $u->{$topic} = int(time());
        my @k = sort { $u->{$b} <=> $u->{$a} } keys %$u;
        delete $u->{$_} for @k[20 .. $#k];
    }
    Instar2Lox::save_json_atomic($Instar2Lox::ALARM_FILE, $as);
}

sub on_message {
    my ($topic, $msg) = @_;
    my @parts = split m{/}, $topic;
    my $key = uc($parts[1] // '');
    my $val = 0;
    if (defined $msg && $msg =~ /^\s*\{/) {
        my $d = eval { decode_json($msg) } || {};
        $val = $d->{val} // 0;
    } elsif (defined $msg) {
        ($val) = $msg =~ /(\d+)/; $val //= 0;
    }
    $val = int($val);
    my $cam = $by_id{$key};
    unless ($cam) {
        LOGINF("Alarm from unknown camera ID '$key' (topic $topic, val=$val) - set its MQTT ID in the plugin");
        save_alarm(undef, $val, $topic);
        return;
    }
    return unless $val > 0;
    save_alarm($cam->{id}, $val, $topic);
    # Cooldown: a camera that triggers every few seconds (tree, insects, rain)
    # must not make the Intercom ring non-stop. Alarms are still counted.
    my $cd = $c->{global}{alarm_cooldown_sec} // 30;
    my $now = time();
    if ($cd && $last_sent{ $cam->{id} } && $now - $last_sent{ $cam->{id} } < $cd) {
        my $as = Instar2Lox::load_json($Instar2Lox::ALARM_FILE, {});
        $as->{cams}{ $cam->{id} }{suppressed}++;
        Instar2Lox::save_json_atomic($Instar2Lox::ALARM_FILE, $as);
        return;
    }
    $last_sent{ $cam->{id} } = $now;
    LOGINF("ALARM '$cam->{name}' trigger=$val");
    Instar2Lox::udp_send($c, [["$cam->{id}.alarm", $val]]) or LOGERR("UDP send failed");
    $pending{ $cam->{id} } = $now + ($c->{global}{alarm_pulse_sec} || 2);
    my $as = Instar2Lox::load_json($Instar2Lox::ALARM_FILE, {});
    $as->{cams}{ $cam->{id} }{sent}++;
    $as->{cams}{ $cam->{id} }{last_sent} = int($now);
    Instar2Lox::save_json_atomic($Instar2Lox::ALARM_FILE, $as);
}

load_map();
my $brk = Instar2Lox::broker_details();
my $host = $brk->{brokerhost} || 'localhost';
my $port = $brk->{brokerport} || 1883;
topics_from_cfg();
LOGOK("Alarm listener starting, broker $host:$port, listening on $sub_topic, alarms $c->{global}{alarm_topic}, " . scalar(keys %by_id) . " camera(s) mapped");

my $mqtt = Net::MQTT::Simple->new("$host:$port");
$mqtt->login($brk->{brokeruser}, $brk->{brokerpass}) if $brk->{brokeruser};
$mqtt->subscribe($sub_topic => \&on_any);

while ($running) {
    eval { $mqtt->tick(0.5); 1 } or do { LOGWARN("MQTT error: $@"); sleep 5; };
    my $t = time();
    for my $id (keys %pending) {
        next if $pending{$id} > $t;
        Instar2Lox::udp_send($c, [["$id.alarm", 0]]);
        delete $pending{$id};
    }
    # Reload mapping when config changed, otherwise once a minute (MACs may appear later).
    my $m = (stat($Instar2Lox::CFG_FILE))[9] // 0;
    if ($m != $cfg_mtime || $t - $map_time > 60) {
        my $old_topic = $c->{global}{alarm_topic};
        load_map();
        last unless $c->{global}{alarm_enable};
        if ($c->{global}{alarm_topic} ne $old_topic) {
            my $old_sub = $sub_topic;
            topics_from_cfg();
            if ($sub_topic ne $old_sub) {
                $mqtt->unsubscribe($old_sub);
                $mqtt->subscribe($sub_topic => \&on_any);
            }
            LOGINF("Alarm topic changed to $c->{global}{alarm_topic}");
        }
    }
    save_traffic() if $traffic_dirty && $t - $traffic_saved > 10;
}
save_traffic() if $traffic_dirty;

Instar2Lox::udp_send($c, [["$_.alarm", 0]]) for keys %pending;
eval { $mqtt->disconnect };
unlink $Instar2Lox::PID_FILE;
LOGINF("Alarm listener stopped");
exit 0;
