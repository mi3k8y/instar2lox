#!/usr/bin/perl
# Instar2Lox - worker, called every minute by cron.
#  1. Executes scheduled reboots.
#  2. Every <check_interval_min> polls all cameras (online state, versions).
#  3. Sends UDP to the Miniserver ONLY when a value changes
#     (offline / outdated per camera, plus counters).
#  4. Keeps the MQTT alarm listener (alarmd.pl) running.
#
# Usage: worker.pl            normal cron run
#        worker.pl --force    poll all cameras now and resend every value

use strict;
use warnings;
use LoxBerry::System;
use LoxBerry::Log;

require "$lbpbindir/Instar2Lox.pm";

my $force = (@ARGV && $ARGV[0] eq '--force') ? 1 : 0;

my $log = LoxBerry::Log->new(
    name => 'worker', filename => "$lbplogdir/worker.log", append => 1, addtime => 1, stderr => 0,
);
# Keep the log small - this runs every minute.
truncate("$lbplogdir/worker.log", 0) if -s "$lbplogdir/worker.log" && -s _ > 1_000_000;

my $c   = Instar2Lox::load_cfg();
my $now = time();

# Heartbeat (log dir is tmpfs): lets the UI show that the cron job runs.
if (open(my $hb, '>', "$lbplogdir/worker.heartbeat")) { print $hb $now; close $hb; }

# -- alarm daemon watchdog ------------------------------------------------------
if ($c->{global}{alarm_enable}) {
    unless (Instar2Lox::alarmd_pid()) {
        if (Instar2Lox::start_alarmd()) { LOGOK("Alarm listener was not running - started"); }
        else                            { LOGERR("Alarm listener could not be started - see alarmd log"); }
    }
} else {
    Instar2Lox::stop_alarmd() if Instar2Lox::alarmd_pid();
}

exit 0 unless @{ $c->{cameras} };

# -- scheduled reboots ------------------------------------------------------------
for my $cam (@{ $c->{cameras} }) {
    my $stamp = Instar2Lox::reboot_due($cam, $now) or next;
    my $done = Instar2Lox::read_state()->{cams}{ $cam->{id} }{last_reboot_slot} // '';
    next if $done eq $stamp;
    my ($ok, $err) = Instar2Lox::reboot_cam($c, $cam);
    if ($ok) { LOGOK("Scheduled reboot sent to '$cam->{name}' ($cam->{ip})"); }
    else     { LOGWARN("Scheduled reboot of '$cam->{name}' ($cam->{ip}) failed: $err"); }
    Instar2Lox::with_state(sub {
        my $s = $_[0]{cams}{ $cam->{id} } ||= {};
        $s->{last_reboot_slot} = $stamp;
        $s->{last_reboot}      = $now;
        $s->{last_reboot_ok}   = $ok ? 1 : 0;
        $s->{grace_until}      = $now + 60 * $c->{global}{reboot_grace_min} if $ok;
    });
}

# -- health / version poll --------------------------------------------------------
my $st0      = Instar2Lox::read_state();
my $last     = $st0->{meta}{last_poll} // 0;
my $interval = 60 * ($c->{global}{check_interval_min} || 5);
my $resend   = 3600 * ($c->{global}{resend_hours} || 0);
my $do_poll  = $force || ($now - $last >= $interval - 5);
my $do_full  = $force || ($resend && $now - ($st0->{meta}{last_full_send} // 0) >= $resend);
exit 0 unless $do_poll || $do_full;

my %result;
if ($do_poll) {
    for my $cam (@{ $c->{cameras} }) {
        next unless $cam->{monitor};
        my $have_mac = $st0->{cams}{ $cam->{id} }{info}{mac} ? 1 : 0;
        my ($ok, $info, $err) = Instar2Lox::fetch_info($c, $cam, $have_mac);
        $result{ $cam->{id} } = { ok => $ok, info => $info, err => $err };
    }
}

my @udp;
Instar2Lox::with_state(sub {
    my ($st) = @_;
    $st->{meta}{last_poll} = $now if $do_poll;
    my $thr = $c->{global}{offline_threshold} || 2;

    for my $cam (@{ $c->{cameras} }) {
        my $id = $cam->{id};
        my $s  = $st->{cams}{$id} ||= {};
        my $r  = $result{$id} or next;
        $s->{last_check} = $now;
        if ($r->{ok}) {
            my $mac = $s->{info}{mac};
            $s->{info} = $r->{info};
            $s->{info}{mac} //= $mac if $mac;
            $s->{last_ok} = $now;
            $s->{fails}   = 0;
            $s->{error}   = '';
            if ($s->{offline}) { LOGOK("'$cam->{name}' is back online"); }
            $s->{offline} = 0;
        } else {
            $s->{fails} = ($s->{fails} // 0) + 1;
            $s->{error} = $r->{err};
            my $in_grace = ($s->{grace_until} // 0) > $now;
            if (!$s->{offline} && $s->{fails} >= $thr && !$in_grace) {
                $s->{offline} = 1;
                LOGWARN("'$cam->{name}' ($cam->{ip}) is OFFLINE: $r->{err}");
            }
        }
    }

    my $od = Instar2Lox::compute_outdated($c, $st);
    my ($n_off, $n_od) = (0, 0);
    for my $cam (@{ $c->{cameras} }) {
        my $id = $cam->{id};
        my $s  = $st->{cams}{$id} ||= {};
        my $o  = $od->{$id} || {};
        if (($s->{outdated} // 0) != ($o->{outdated} // 0)) {
            LOGINF("'$cam->{name}' firmware " . ($o->{outdated} ? "OUTDATED ($s->{info}{softVersion} < $o->{latest})" : "up to date"));
        }
        $s->{outdated} = $o->{outdated} // 0;
        $s->{latest}   = $o->{latest}   // '';
        $s->{latest_source} = $o->{source} // '';
        $n_off++ if $s->{offline};
        $n_od++  if $s->{outdated};

        my $sent = $s->{sent} ||= {};
        for my $k (qw(offline outdated)) {
            my $v = $s->{$k} ? 1 : 0;
            if ($do_full || !defined $sent->{$k} || $sent->{$k} != $v) {
                # First run: only report problems, not a wall of zeros.
                push @udp, ["$id.$k", $v] if $do_full || defined $sent->{$k} || $v;
                $sent->{$k} = $v;
            }
        }
    }
    my $ms = $st->{meta}{sent} ||= {};
    for my $p (['offline_count', $n_off], ['outdated_count', $n_od]) {
        if ($do_full || !defined $ms->{ $p->[0] } || $ms->{ $p->[0] } != $p->[1]) {
            push @udp, [$p->[0], $p->[1]];
            $ms->{ $p->[0] } = $p->[1];
        }
    }
    $st->{meta}{last_full_send} = $now if $do_full;
});

if (@udp) {
    my $n = Instar2Lox::udp_send($c, \@udp);
    if ($n) { LOGINF("UDP sent: " . join(', ', map { "$_->[0]=$_->[1]" } @udp)); }
    else    { LOGERR("UDP send failed - check Miniserver selection and UDP port"); }
}

exit 0;
