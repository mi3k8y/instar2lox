#!/usr/bin/perl
# Instar2Lox - shared library
# Used by index.cgi (web UI), worker.pl (cron) and alarmd.pl (MQTT listener).
# Supports INSTAR Full HD (1080p) cameras via their param.cgi HTTP API.

package Instar2Lox;

use strict;
use warnings;
use JSON;
use Fcntl qw(:flock);
use IO::Socket::INET;
use POSIX qw(strftime);
use LoxBerry::System;

our $CFG_FILE   = "$lbpconfigdir/instar2lox.json";
our $STATE_FILE = "$lbpdatadir/state.json";
our $ALARM_FILE = "$lbpdatadir/alarm_state.json";
our $LOCK_FILE  = "$lbpdatadir/state.lock";
our $PID_FILE   = "$lbpdatadir/alarmd.pid";

# Values sent to Loxone follow one rule: 0 = everything fine, so that the
# default value of a Virtual Input after a Miniserver restart is "no problem".

my %DEFAULT_GLOBAL = (
    user               => 'admin',
    pass               => '',
    ms_no              => 1,
    udp_port           => 7088,
    udp_prefix         => 'instar2lox',
    check_interval_min => 5,
    offline_threshold  => 2,
    reboot_grace_min   => 6,
    http_timeout       => 5,
    resend_hours       => 0,
    alarm_enable       => 1,
    alarm_topic        => 'instar/+/status/alarm/triggered',
    alarm_pulse_sec    => 2,
    alarm_cooldown_sec => 30,
    target_versions    => {},
);

# --------------------------------------------------------------------------
# JSON / config / state
# --------------------------------------------------------------------------

sub load_json {
    my ($f, $default) = @_;
    return $default unless -f $f;
    open(my $fh, '<', $f) or return $default;
    local $/; my $raw = <$fh>; close $fh;
    my $d = eval { decode_json($raw) };
    return defined $d ? $d : $default;
}

sub save_json_atomic {
    my ($f, $d) = @_;
    my $tmp = "$f.tmp.$$";
    open(my $fh, '>', $tmp) or return 0;
    print $fh JSON->new->utf8->canonical(1)->pretty->encode($d);
    close $fh;
    return rename($tmp, $f) ? 1 : 0;
}

sub load_cfg {
    my $c = load_json($CFG_FILE, {});
    $c->{global}  ||= {};
    $c->{cameras} ||= [];
    for my $k (keys %DEFAULT_GLOBAL) {
        $c->{global}{$k} = $DEFAULT_GLOBAL{$k} unless defined $c->{global}{$k};
    }
    for my $cam (@{ $c->{cameras} }) {
        $cam->{port}    ||= 80;
        $cam->{monitor} = 1 unless defined $cam->{monitor};
        $cam->{user}    //= '';
        $cam->{pass}    //= '';
        $cam->{mqtt_id} //= '';
        $cam->{reboot}  ||= { mode => 'off' };
        $cam->{reboot}{mode} ||= 'off';
        $cam->{reboot}{hour}   //= 3;
        $cam->{reboot}{minute} //= 30;
        $cam->{reboot}{dow}    //= 7;
        $cam->{reboot}{dom}    //= 1;
    }
    return $c;
}

sub save_cfg {
    my ($c) = @_;
    my $ok = save_json_atomic($CFG_FILE, $c);
    chmod 0600, $CFG_FILE;
    return $ok;
}

sub find_cam {
    my ($c, $id) = @_;
    for my $cam (@{ $c->{cameras} }) { return $cam if $cam->{id} eq $id; }
    return undef;
}

sub read_state { return load_json($STATE_FILE, {}); }

# Locked read-modify-write of state.json (worker and web UI both write it).
sub with_state {
    my ($code) = @_;
    open(my $lk, '>>', $LOCK_FILE) or return;
    flock($lk, LOCK_EX);
    my $st = load_json($STATE_FILE, {});
    $st->{cams} ||= {};
    $st->{meta} ||= {};
    my $ret = $code->($st);
    save_json_atomic($STATE_FILE, $st);
    flock($lk, LOCK_UN);
    close $lk;
    return $ret;
}

# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

sub slug {
    my ($s) = @_;
    $s = lc($s // '');
    $s =~ s/[^a-z0-9]+//g;
    return $s;
}

sub urlenc {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge;
    return $s;
}

sub html {
    my ($s) = @_;
    $s = '' unless defined $s;
    $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s =~ s/"/&quot;/g;
    return $s;
}

sub fmt_time {
    my ($t) = @_;
    return '-' unless $t;
    return strftime('%Y-%m-%d %H:%M', localtime($t));
}

# Parse INSTAR CGI responses: lines like  var softVersion="4.1.2.48";
# (Full HD) or  softVersion="v0.0.1";  (2K+). Returns hashref.
sub parse_vars {
    my ($text) = @_;
    my %v;
    return \%v unless defined $text;
    while ($text =~ /([A-Za-z0-9_]+)\s*=\s*"([^"]*)"/g) { $v{$1} = $2; }
    return \%v;
}

# Compare dotted version strings numerically ("4.1.2.48" vs "4.1.10").
# Non-numeric prefixes such as "v" are ignored. Returns -1/0/1.
sub vcmp {
    my ($a, $b) = @_;
    my @a = ((defined $a ? $a : '') =~ /(\d+)/g);
    my @b = ((defined $b ? $b : '') =~ /(\d+)/g);
    my $n = @a > @b ? scalar @a : scalar @b;
    for my $i (0 .. $n - 1) {
        my $x = $a[$i] // 0; my $y = $b[$i] // 0;
        return -1 if $x < $y;
        return 1  if $x > $y;
    }
    return 0;
}

sub mac_id {
    my ($mac) = @_;
    $mac = uc($mac // '');
    $mac =~ s/[^0-9A-F]//g;
    return $mac;
}

# --------------------------------------------------------------------------
# Camera HTTP API
# --------------------------------------------------------------------------

sub cam_creds {
    my ($c, $cam) = @_;
    my $u = length($cam->{user}) ? $cam->{user} : $c->{global}{user};
    my $p = length($cam->{pass}) ? $cam->{pass} : $c->{global}{pass};
    return ($u, $p);
}

sub cam_base {
    my ($cam) = @_;
    my $port = $cam->{port} || 80;
    return "http://$cam->{ip}" . ($port == 80 ? '' : ":$port");
}

# Calls /param.cgi?<query> with -usr/-pwd. Returns (ok, vars, error, raw).
sub cgi_call {
    my ($c, $cam, $query, $timeout) = @_;
    require LWP::UserAgent;
    my ($u, $p) = cam_creds($c, $cam);
    my $url = cam_base($cam) . "/param.cgi?$query&-usr=" . urlenc($u) . "&-pwd=" . urlenc($p);
    my $ua = LWP::UserAgent->new(timeout => $timeout || $c->{global}{http_timeout} || 5);
    $ua->agent('instar2lox');
    my $res = $ua->get($url);
    return (0, {}, 'HTTP ' . $res->status_line, '') unless $res->is_success;
    my $raw  = $res->decoded_content // '';
    my $vars = parse_vars($raw);
    if ($raw =~ /unauthori[sz]ed|401 /i && !%$vars) {
        return (0, {}, 'Authentication failed', $raw);
    }
    return (1, $vars, '', $raw);
}

# Reads the camera's identity and versions. Fetches MAC only when missing.
sub fetch_info {
    my ($c, $cam, $have_mac) = @_;
    my ($ok, $v, $err) = cgi_call($c, $cam, 'cmd=getserverinfo');
    return (0, undef, $err) unless $ok;
    return (0, undef, 'Unexpected answer (no softVersion)') unless defined $v->{softVersion};
    my %info = map { $_ => $v->{$_} }
        grep { defined $v->{$_} }
        qw(model hardVersion softVersion webVersion name startdate sdstatus sdfreespace sdtotalspace upnpstatus facddnsstatus);
    unless ($have_mac) {
        my ($ok2, $n) = cgi_call($c, $cam, 'cmd=getnetattr');
        if ($ok2) {
            $info{mac}         = $n->{macaddress} if $n->{macaddress};
            $info{networktype} = $n->{networktype} if $n->{networktype};
        }
    }
    return (1, \%info, '');
}

sub reboot_cam {
    my ($c, $cam) = @_;
    my ($ok, $v, $err, $raw) = cgi_call($c, $cam, 'cmd=sysreboot');
    # Some firmwares close the connection immediately; treat an empty 200 as success.
    return ($ok, $err);
}

# MQTT settings live in get_instar_admin index 32:
# enable;external;address;port;sslport;auth;user;password[;more...]
sub get_mqtt_cfg {
    my ($c, $cam) = @_;
    my ($ok, $v, $err) = cgi_call($c, $cam, 'cmd=get_instar_admin&-index=32');
    return (0, undef, $err) unless $ok;
    my $raw = $v->{admin_value32};
    return (0, undef, 'Camera does not report MQTT settings (admin_value32)') unless defined $raw;
    my @f = split /;/, $raw, -1;
    my %m = (
        enable => $f[0] // '', external => $f[1] // '', address => $f[2] // '',
        port   => $f[3] // '', sslport  => $f[4] // '', auth    => $f[5] // '',
        user   => $f[6] // '', pass     => $f[7] // '', fields  => \@f,
    );
    return (1, \%m, '');
}

# Writes broker settings, keeping any trailing fields the firmware may add.
sub set_mqtt_cfg {
    my ($c, $cam, $addr, $port, $user, $pass) = @_;
    for my $x ($addr, $user, $pass) {
        return (0, 'Semicolon is not allowed in broker address, user or password') if $x =~ /;/;
    }
    my ($ok, $m, $err) = get_mqtt_cfg($c, $cam);
    return (0, "Cannot read current MQTT settings: $err") unless $ok;
    my @f = @{ $m->{fields} };
    $f[$_] //= '' for 0 .. 7;
    $f[0] = 1; $f[1] = 1; $f[2] = $addr; $f[3] = $port; $f[5] = 1; $f[6] = $user; $f[7] = $pass;
    $f[4] = 8883 unless length $f[4];
    my $value = join(';', @f);
    my ($ok2, $v, $err2) = cgi_call($c, $cam, 'cmd=set_instar_admin&-index=32&-value=' . urlenc($value));
    return (0, $err2) unless $ok2;
    # Verify by reading back.
    my ($ok3, $m3) = get_mqtt_cfg($c, $cam);
    return (0, 'Written, but read-back failed') unless $ok3;
    return (0, 'Written, but camera still reports different settings')
        unless $m3->{external} eq '1' && $m3->{address} eq $addr && $m3->{user} eq $user && $m3->{pass} eq $pass;
    return (1, '');
}

# --------------------------------------------------------------------------
# Firmware currency
# --------------------------------------------------------------------------

# Returns { cam_id => { outdated => 0/1, latest => 'x', source => 'target'|'fleet'|'' } }
# A configured target version per model wins; otherwise the highest version
# seen on cameras of the same model is the reference.
sub compute_outdated {
    my ($c, $st) = @_;
    my %best;
    for my $cam (@{ $c->{cameras} }) {
        my $i = $st->{cams}{ $cam->{id} }{info} or next;
        my $m = $i->{model} // ''; my $v = $i->{softVersion} // '';
        next unless length $m && length $v;
        $best{$m} = $v if !defined $best{$m} || vcmp($v, $best{$m}) > 0;
    }
    my %out;
    my $tv = $c->{global}{target_versions} || {};
    for my $cam (@{ $c->{cameras} }) {
        my $i = $st->{cams}{ $cam->{id} }{info};
        unless ($i && $i->{softVersion}) { $out{ $cam->{id} } = { outdated => 0, latest => '', source => '' }; next; }
        my $m = $i->{model} // '';
        my ($ref, $src) = defined $tv->{$m} && length $tv->{$m} ? ($tv->{$m}, 'target') : ($best{$m}, 'fleet');
        my $od = (defined $ref && vcmp($i->{softVersion}, $ref) < 0) ? 1 : 0;
        $out{ $cam->{id} } = { outdated => $od, latest => $ref // '', source => $src };
    }
    return \%out;
}

# --------------------------------------------------------------------------
# Reboot schedule
# --------------------------------------------------------------------------

# Returns a stamp identifying the due slot (e.g. "2026-11-12") when a reboot
# is due now, otherwise undef. A slot fires once within a 5-minute window.
sub reboot_due {
    my ($cam, $now) = @_;
    my $r = $cam->{reboot} || {};
    my $mode = $r->{mode} || 'off';
    return undef if $mode eq 'off';
    my @t = localtime($now);
    my ($min, $hour, $mday, $wday) = @t[1, 2, 3, 6];
    my $dow = $wday == 0 ? 7 : $wday;    # 1 = Monday .. 7 = Sunday
    return undef if $mode eq 'weekly'  && $dow  != ($r->{dow} || 7);
    return undef if $mode eq 'monthly' && $mday != ($r->{dom} || 1);
    my $sched = ($r->{hour} // 3) * 60 + ($r->{minute} // 0);
    my $cur   = $hour * 60 + $min;
    return undef unless $cur >= $sched && $cur < $sched + 5;
    return strftime('%Y-%m-%d', @t);
}

my @DOW = qw(- Mon Tue Wed Thu Fri Sat Sun);

sub schedule_text {
    my ($cam) = @_;
    my $r = $cam->{reboot} || {};
    my $m = $r->{mode} || 'off';
    return 'off' if $m eq 'off';
    my $hm = sprintf('%02d:%02d', $r->{hour} // 3, $r->{minute} // 0);
    return "daily $hm"                                  if $m eq 'daily';
    return "weekly $DOW[$r->{dow} || 7] $hm"            if $m eq 'weekly';
    return "monthly day " . ($r->{dom} || 1) . " $hm"   if $m eq 'monthly';
    return $m;
}

# --------------------------------------------------------------------------
# Loxone UDP
# --------------------------------------------------------------------------

sub ms_ip {
    my ($c) = @_;
    my %ms = LoxBerry::System::get_miniservers();
    my $no = $c->{global}{ms_no} || 1;
    return $ms{$no}{IPAddress} if $ms{$no} && $ms{$no}{IPAddress};
    for my $k (sort keys %ms) { return $ms{$k}{IPAddress} if $ms{$k}{IPAddress}; }
    return undef;
}

# Sends "prefix.key=value" datagrams. $pairs is an arrayref of [key, value].
sub udp_send {
    my ($c, $pairs) = @_;
    return 0 unless @$pairs;
    my $ip = ms_ip($c) or return 0;
    my $sock = IO::Socket::INET->new(PeerAddr => $ip, PeerPort => $c->{global}{udp_port}, Proto => 'udp')
        or return 0;
    my $pre = $c->{global}{udp_prefix};
    for my $p (@$pairs) { $sock->send("$pre.$p->[0]=$p->[1]"); }
    $sock->close;
    return scalar @$pairs;
}

# --------------------------------------------------------------------------
# Network discovery
# --------------------------------------------------------------------------

sub find_cam_ip {
    my ($c, $ip) = @_;
    for my $cam (@{ $c->{cameras} }) { return $cam if $cam->{ip} eq $ip; }
    return undef;
}

sub subnet_prefix {
    my $ip = LoxBerry::System::get_localip() // '';
    return $ip =~ /^(\d+\.\d+\.\d+)\.\d+$/ ? $1 : '';
}

# Scans <LoxBerry subnet>.1-254 for INSTAR cameras: TCP port 80 open, then
# param.cgi?cmd=getserverinfo with the common login. Runs 32 parallel workers
# (about 10 s for a /24). Returns arrayref of
#   { ip, name, info, auth_failed, known }
sub scan_subnet {
    my ($c) = @_;
    my $pre = subnet_prefix() or return [];
    my $self = LoxBerry::System::get_localip();
    my @ips = grep { $_ ne $self } map { "$pre.$_" } 1 .. 254;
    my $out = "$lbpdatadir/scan.tmp.$$";
    unlink $out;
    my $workers = 32;
    my @pids;
    for my $w (0 .. $workers - 1) {
        my $pid = fork();
        next unless defined $pid;
        if ($pid == 0) {
            for (my $i = $w; $i < @ips; $i += $workers) {
                my $ip = $ips[$i];
                my $s = IO::Socket::INET->new(PeerAddr => $ip, PeerPort => 80, Proto => 'tcp', Timeout => 0.6) or next;
                close $s;
                my $cam = { ip => $ip, port => 80, user => '', pass => '' };
                my ($ok, $info, $err) = fetch_info($c, $cam, 0);
                my $rec;
                if ($ok) { $rec = { ip => $ip, name => $info->{name} // '', info => $info }; }
                elsif ($err =~ /^HTTP 401/) {
                    # param.cgi exists but rejects the login: almost certainly an INSTAR
                    # camera with a different password. Report it so it can be added manually.
                    $rec = { ip => $ip, name => '', info => {}, auth_failed => 1 };
                }
                next unless $rec;
                if (open(my $fh, '>>', $out)) {
                    flock($fh, LOCK_EX);
                    print $fh JSON->new->utf8->encode($rec), "\n";
                    close $fh;
                }
            }
            POSIX::_exit(0);
        }
        push @pids, $pid;
    }
    waitpid($_, 0) for @pids;
    my @found;
    if (open(my $fh, '<', $out)) {
        while (my $l = <$fh>) { my $r = eval { JSON->new->utf8->decode($l) } or next; push @found, $r; }
        close $fh;
    }
    unlink $out;
    for my $f (@found) { $f->{known} = find_cam_ip($c, $f->{ip}) ? 1 : 0; }
    @found = sort { (split /\./, $a->{ip})[3] <=> (split /\./, $b->{ip})[3] } @found;
    return \@found;
}

# --------------------------------------------------------------------------
# Mosquitto log: MQTT client IDs and rejected logins per camera IP
# --------------------------------------------------------------------------

sub broker_log_file {
    my $h = $LoxBerry::System::lbhomedir // '/opt/loxberry';
    my @c = (glob("$h/log/system_tmpfs/mosquitto/*.log"), glob("$h/log/system/mosquitto/*.log"),
             glob("$h/log/plugins/mqttgateway/*mosquitto*"), glob("$h/log/*/*mosquitto*.log"),
             glob("$h/log/*/*/*mosquitto*.log"), '/var/log/mosquitto/mosquitto.log');
    my @ok = sort { (stat($b))[9] <=> (stat($a))[9] } grep { -f $_ && -r _ && -s _ } @c;
    return $ok[0];
}

# Returns { file, by_ip => { ip => { client_id, connected, rejected, rejected_count } },
#           kicks => { client_id => n } }  ("kicks" = same client ID connected twice)
sub broker_log_info {
    my $f = broker_log_file();
    my %r = (file => $f, by_ip => {}, kicks => {});
    return \%r unless $f;
    open(my $fh, '<', $f) or return \%r;
    my $size = -s $fh;
    if ($size > 3_000_000) { seek($fh, $size - 3_000_000, 0); <$fh>; }
    my $last_ip;
    while (my $l = <$fh>) {
        my ($ts) = $l =~ /^(\S+?):\s/;
        if ($l =~ /New connection from ([\d.]+):\d+/) { $last_ip = $1; next; }
        if ($l =~ /New client connected from ([\d.]+):\d+ as (\S+)/) {
            my $e = $r{by_ip}{$1} ||= {};
            $e->{client_id} = $2; $e->{connected} = $ts;
            next;
        }
        if ($l =~ /not authori[sz]ed/ && $last_ip) {
            my $e = $r{by_ip}{$last_ip} ||= {};
            $e->{rejected} = $ts; $e->{rejected_count} = ($e->{rejected_count} // 0) + 1;
            next;
        }
        if ($l =~ /Client (\S+) already connected, closing old connection/) { $r{kicks}{$1}++; next; }
        if ($l =~ /Client (\S+) (?:disconnected|has exceeded timeout)/) { $r{gone}{$1} = $ts; }
    }
    close $fh;
    return \%r;
}

# --------------------------------------------------------------------------
# Bulk settings (Full HD CGI, documented in the INSTAR 1080p CGI list)
# --------------------------------------------------------------------------

# Bulk settings shown to the user as plain options; the camera commands stay
# internal. All commands and variable names are taken from the public INSTAR
# 1080p CGI documentation (wiki.instar.com/en/1080p_Series_CGI_List).
#
# Each entry:
#   key, label, group, hint
#   get  => query whose answer holds the current value ('' = cannot be read)
#   var  => variable name in that answer, or code ref ($vars) -> value
#   set  => code ref ($value) -> list of queries
#   opts => [value => label, ...]   (value is what 'var' returns)
#   warn => text for an extra confirmation (destructive actions)

sub _u { return urlenc($_[0]); }

# Alarm schedule: 7 strings (Sun..Sat) of 48 half-hour slots, P = active.
sub sched_string {
    my ($v) = @_;
    return 'P' x 48 if $v eq 'always';
    return 'N' x 48 if $v eq 'never';
    my ($f, $t) = split /-/, $v;
    my $str = '';
    for my $slot (0 .. 47) {
        my $h = $slot / 2;
        my $on = $f > $t ? ($h >= $f || $h < $t) : ($h >= $f && $h < $t);
        $str .= $on ? 'P' : 'N';
    }
    return $str;
}

sub sched_value {
    my ($v) = @_;
    my @w = grep { defined } map { $v->{"week$_"} // $v->{"week${_}_md"} } 0 .. 6;
    return undef unless @w;
    my %u = map { $_ => 1 } @w;
    return 'per day' if keys %u > 1;
    my $s = $w[0];
    return 'always' if $s =~ /^P+$/;
    return 'never'  if $s =~ /^N+$/;
    for my $f (0 .. 23) {
        for my $t (0 .. 23) {
            next if $f == $t;
            return "$f-$t" if sched_string("$f-$t") eq $s;
        }
    }
    return 'custom';
}

my @ONOFF = (on => 'on', off => 'off');
my @ONE0  = (1 => 'on', 0 => 'off');
my @SCHED = (always => 'always', (map { my ($f, $t) = @$_; ("$f-$t" => sprintf('%02d:00 - %02d:00', $f, $t)) }
             [18, 6], [19, 6], [20, 6], [21, 6], [22, 6], [18, 7], [20, 7], [22, 5], [8, 18]), never => 'never (alarm off)');

sub _mdalarm {
    my ($key, $label, $group, $aname, $hint) = @_;
    return { key => $key, label => $label, group => $group, hint => $hint,
             get => "cmd=getmdalarm&-aname=$aname", var => "md_${aname}_switch",
             set => sub { ("cmd=setmdalarm&-aname=$aname&-switch=" . _u($_[0])) }, opts => [@ONOFF] };
}

our @BULK = (
    # ---- Alarm
    { key => 'schedule', label => 'Alarm active', group => 'Alarm', hint => 'same time window every day',
      get => 'cmd=getscheduleex&-ename=md', var => \&sched_value, opts => [@SCHED],
      set => sub { my $w = sched_string($_[0]); my $d = join('', map { "&-week$_=$w" } 0 .. 6);
                   ("cmd=setscheduleex&-ename=md$d", "cmd=setbackupschedule&-ename=md$d") } },
    { key => 'pause', label => 'Alarm actions', group => 'Alarm', hint => 'pause all actions without changing anything else',
      get => '', opts => [70467841 => 'active', 70467840 => 'paused'], set => sub { ("cmd=insu&-arg=" . _u($_[0])) } },
    _mdalarm('server', 'HTTP alarm server', 'Alarm', 'server', 'calls the alarm server URL set in the camera (e.g. Loxone virtual input)'),
    { key => 'serverint', label => 'HTTP alarm server: min. pause', group => 'Alarm',
      get => 'cmd=getmdalarm&-aname=server', var => 'md_server_interval', opts => [map { ($_ => "$_ s") } 1, 5, 10, 15, 30, 45, 60],
      set => sub { ("cmd=setmdalarm&-aname=server&-switch=on&-interval=" . _u($_[0])) }, hint => 'also switches the alarm server on' },
    _mdalarm('sound', 'Siren / alarm sound', 'Alarm', 'sound'),
    _mdalarm('relay', 'Alarm output relay', 'Alarm', 'relay'),

    # ---- Detection
    (map { my $n = $_; { key => "md$n", label => "Motion zone $n", group => 'Detection',
        get => 'cmd=getmdattr', var => "m${n}_enable", opts => [@ONE0],
        set => sub { ("cmd=setmdattr&-name=$n&-enable=" . _u($_[0])) } } } 1 .. 4),
    { key => 'mdsens', label => 'Motion sensitivity', group => 'Detection', hint => 'all 4 zones',
      get => 'cmd=getmdattr', opts => [map { ($_ * 10 => ($_ * 10) . ' %') } 1 .. 10],
      var => sub { my $v = shift; my %u = map { $_ => 1 } grep { defined } map { $v->{"m${_}_sensitivity"} } 1 .. 4;
                   return keys %u == 1 ? (keys %u)[0] : (keys %u ? 'mixed' : undef) },
      set => sub { my $x = _u($_[0]); map { "cmd=setmdattr&-name=$_&-s=$x" } 1 .. 4 } },
    { key => 'pir', label => 'PIR sensor', group => 'Detection', get => 'cmd=getpirattr', var => 'pir_enable', opts => [@ONE0],
      set => sub { ("cmd=setpirattr&-pir_enable=" . _u($_[0])) } },
    { key => 'io', label => 'Alarm input (terminal)', group => 'Detection', get => 'cmd=getioattr', var => 'io_enable', opts => [@ONE0],
      set => sub { ("cmd=setioattr&-io_enable=" . _u($_[0])) } },
    { key => 'audio', label => 'Sound detection', group => 'Detection', get => 'cmd=getaudioalarmattr', var => 'aa_enable', opts => [@ONE0],
      set => sub { ("cmd=setaudioalarmattr&-aa_enable=" . _u($_[0])) } },
    { key => 'audiosens', label => 'Sound sensitivity', group => 'Detection', get => 'cmd=getaudioalarmattr', var => 'aa_value',
      opts => [map { ($_ * 10 => ($_ * 10) . ' %') } 1 .. 10], set => sub { ("cmd=setaudioalarmattr&-aa_value=" . _u($_[0])) } },

    # ---- SD card
    _mdalarm('record', 'Alarm video to SD card', 'SD card', 'record'),
    _mdalarm('snap', 'Alarm snapshots to SD card', 'SD card', 'snap'),
    { key => 'snapcount', label => 'Snapshots per alarm', group => 'SD card', get => 'cmd=getalarmsnapattr', var => 'snap_count',
      opts => [map { ($_ => $_) } 1 .. 15], set => sub { ("cmd=setalarmsnapattr&-snap_count=" . _u($_[0])) } },
    { key => 'snapres', label => 'Snapshot resolution', group => 'SD card', get => 'cmd=getalarmsnapattr', var => 'snap_chn',
      opts => [11 => 'Full HD', 12 => 'medium', 13 => 'small'], set => sub { ("cmd=setalarmsnapattr&-snap_chn=" . _u($_[0])) } },
    { key => 'sddelete', label => 'Delete old recordings', group => 'SD card',
      get => 'cmd=get_instar_admin&-index=48', var => 'admin_value48',
      opts => [0 => 'when card is full', 2 => 'after 2 days', 7 => 'after 7 days', 14 => 'after 14 days', 28 => 'after 28 days'],
      set => sub { my $d = int($_[0]); ("cmd=set_instar_admin&-index=48&-value=$d", "cmd=setplancgi&-plancgi_enable_5=" . ($d ? 1 : 0)) } },
    { key => 'sdformat', label => 'Format SD card', group => 'SD card', get => '', opts => [format => 'FORMAT NOW'],
      warn => 'Formatting deletes ALL recordings on the SD card of every selected camera. Continue?',
      set => sub { ('cmd=sdfrmt') } },

    # ---- Notifications
    _mdalarm('emailsnap', 'E-mail with snapshot', 'Notifications', 'emailsnap'),
    { key => 'emailcount', label => 'Snapshots per e-mail', group => 'Notifications', get => 'cmd=getalarmsnapattr', var => 'email_snap_count',
      opts => [map { ($_ => $_) } 1 .. 15], set => sub { ("cmd=setalarmsnapattr&-email_snap_count=" . _u($_[0])) } },
    _mdalarm('ftpsnap', 'Snapshot to FTP', 'Notifications', 'ftpsnap'),
    { key => 'ftpcount', label => 'Snapshots per FTP upload', group => 'Notifications', get => 'cmd=getalarmsnapattr', var => 'ftp_snap_count',
      opts => [map { ($_ => $_) } 1 .. 15], set => sub { ("cmd=setalarmsnapattr&-ftp_snap_count=" . _u($_[0])) } },
    _mdalarm('ftprec', 'Video to FTP', 'Notifications', 'ftprec'),
    { key => 'cloud', label => 'Alarm video to INSTAR Cloud', group => 'Notifications',
      hint => 'needs an INSTAR Cloud account with this camera added', opts => [@ONOFF],
      read => sub { my ($c, $cam) = @_; my ($an, $v) = cloud_aname($c, $cam); return $an ? $v : 'n/a' },
      set  => sub { my ($val, $c, $cam) = @_; my ($an) = cloud_aname($c, $cam);
                    return $an ? ("cmd=setmdalarm&-aname=$an&-switch=" . _u($val)) : () },
      unsupported => 'this camera does not report a cloud alarm action' },

    # ---- Image & night vision
    { key => 'ir', label => 'IR LEDs', group => 'Image & night', get => 'cmd=getinfrared', var => 'infraredstat',
      opts => [auto => 'auto', close => 'off'], set => sub { ("cmd=setinfrared&-infraredstat=" . _u($_[0])) } },
    { key => 'daynight', label => 'Day / night mode', group => 'Image & night',
      get => 'cmd=get_instar_admin&-index=2', var => 'admin_value2', opts => [auto => 'auto', open => 'always colour', close => 'always black & white'],
      set => sub { my %t = (auto => [208, 190], open => [270, 270], close => [1, 1]); my $x = $t{ $_[0] } or return ();
                   ("cmd=set_instar_admin&-index=2&-value=" . _u($_[0]), "cmd=setircutattr&-saradc_switch_value=$x->[0]&-saradc_b2c_switch_value=$x->[1]") } },
    { key => 'wdr', label => 'WDR (backlight)', group => 'Image & night', get => 'cmd=getimageattr', var => 'wdr', opts => [@ONOFF],
      set => sub { ("cmd=setimageattr&-wdr=" . _u($_[0])) } },
    { key => 'brightness', label => 'Brightness', group => 'Image & night', get => 'cmd=getimageattr', var => 'brightness',
      opts => [map { ($_ * 10 => $_ * 10) } 0 .. 10], set => sub { ("cmd=setimageattr&-brightness=" . _u($_[0])) } },
    { key => 'contrast', label => 'Contrast', group => 'Image & night', get => 'cmd=getimageattr', var => 'contrast',
      opts => [map { ($_ * 10 => $_ * 10) } 0 .. 10], set => sub { ("cmd=setimageattr&-contrast=" . _u($_[0])) } },
    { key => 'flip', label => 'Flip image', group => 'Image & night', get => 'cmd=getimageattr', var => 'flip', opts => [@ONOFF],
      set => sub { ("cmd=setimageattr&-flip=" . _u($_[0])) } },
    { key => 'mirror', label => 'Mirror image', group => 'Image & night', get => 'cmd=getimageattr', var => 'mirror', opts => [@ONOFF],
      set => sub { ("cmd=setimageattr&-mirror=" . _u($_[0])) } },
    { key => 'osdtime', label => 'Show date / time', group => 'Image & night', get => 'cmd=getoverlayattr&-region=0', var => 'show_0', opts => [@ONE0],
      set => sub { ("cmd=setoverlayattr&-region=0&-show=" . _u($_[0])) } },
    { key => 'osdname', label => 'Show camera name', group => 'Image & night', get => 'cmd=getoverlayattr&-region=1', var => 'show_1', opts => [@ONE0],
      set => sub { ("cmd=setoverlayattr&-region=1&-show=" . _u($_[0])) } },

    # ---- System & network
    { key => 'leds', label => 'Status LEDs', group => 'System & network', get => 'cmd=getlightattr', opts => [@ONOFF],
      var => sub { my $v = shift; my %u = map { $_ => 1 } grep { defined } ($v->{light1_enable}, $v->{light2_enable}); keys %u == 1 ? (keys %u)[0] : (keys %u ? 'mixed' : undef) },
      set => sub { my $x = _u($_[0]); ("cmd=setlightattr&-light_index=1&-light_enable=$x", "cmd=setlightattr&-light_index=2&-light_enable=$x") } },
    { key => 'ntp', label => 'Time sync (NTP)', group => 'System & network', get => 'cmd=getntpattr',
      var => sub { my $v = shift; return undef unless defined $v->{ntpenable}; $v->{ntpenable} ? ($v->{ntpserver} // 'on') : 'off' },
      opts => ['tik.cesnet.cz' => 'tik.cesnet.cz', 'cz.pool.ntp.org' => 'cz.pool.ntp.org', 'pool.ntp.org' => 'pool.ntp.org', off => 'off'],
      set => sub { $_[0] eq 'off' ? ('cmd=setntpattr&-ntpenable=0') : ('cmd=setntpattr&-ntpenable=1&-ntpserver=' . _u($_[0]) . '&-ntpinterval=1') } },
    { key => 'tz', label => 'Time zone', group => 'System & network', get => 'cmd=getservertime',
      var => sub { my $v = shift; my $z = $v->{timeZone} // $v->{timezone}; return undef unless defined $z; $z =~ s/%2F/\//gi; $z . '|' . ($v->{dstmode} // '') },
      opts => ['Europe/Prague|on' => 'Prague, summer time on', 'Europe/Prague|off' => 'Prague, summer time off'],
      set => sub { my ($z, $d) = split /\|/, $_[0]; ("cmd=setservertime&-dstmode=" . _u($d) . "&-timezone=" . _u($z)) } },
    { key => 'upnp', label => 'UPnP port forwarding', group => 'System & network', get => '', opts => [@ONE0],
      hint => 'off is recommended inside a LAN', set => sub { ("cmd=setupnpattr&-upm_enable=" . _u($_[0])) } },
    { key => 'p2p', label => 'P2P cloud access', group => 'System & network', get => '', opts => [@ONE0],
      hint => 'needed for the INSTAR app outside your network and for INSTAR Cloud', set => sub { ("cmd=setsmartp2pattr&-smartp2p_enable=" . _u($_[0])) } },
);

# The Full HD cloud alarm action is in the WebUI but not in the public CGI list.
# Probe read-only for the action names the firmware may use and remember the
# one the camera answers with a switch value. Returns (aname, current value).
my %CLOUD_CACHE;
sub cloud_aname {
    my ($c, $cam) = @_;
    my $k = $cam->{ip};
    return @{ $CLOUD_CACHE{$k} } if $CLOUD_CACHE{$k};
    for my $an (qw(cloud cloudrec cloudsnap)) {
        my ($ok, $v) = cgi_call($c, $cam, "cmd=getmdalarm&-aname=$an");
        next unless $ok;
        my $val = $v->{"md_${an}_switch"};
        if (defined $val) { $CLOUD_CACHE{$k} = [$an, $val]; return ($an, $val); }
    }
    $CLOUD_CACHE{$k} = [];
    return ();
}

sub bulk_value {
    my ($b, $v) = @_;
    return ref $b->{var} ? $b->{var}->($v) : $v->{ $b->{var} };
}

sub bulk_read {
    my ($c, $cam) = @_;
    my (%out, %cache);
    for my $b (@BULK) {
        if ($b->{read}) { $out{ $b->{key} } = $b->{read}->($c, $cam) unless $out{_down}; next; }
        next unless $b->{get};
        $cache{ $b->{get} } ||= [ cgi_call($c, $cam, $b->{get}) ];
        my ($ok, $v, $err) = @{ $cache{ $b->{get} } };
        $out{ $b->{key} } = $ok ? bulk_value($b, $v) : undef;
        $out{_error} = $err if !$ok && !$out{_error};
        if (!$ok && $err =~ /^HTTP 5|timeout|connect/i) { $out{_down} = 1; last; }    # camera down - do not wait for every command
    }
    return \%out;
}

# Sends any param.cgi query; ok when HTTP 200 and no error text in the answer.
sub cgi_set {
    my ($c, $cam, $query) = @_;
    my ($ok, $v, $err, $raw) = cgi_call($c, $cam, $query);
    return (0, $err, $raw) unless $ok;
    return (0, 'Camera answered with an error', $raw) if $raw =~ /error|fail/i && $raw !~ /succeed/i;
    return (1, '', $raw);
}

# INSTAR Full HD alarm trigger codes (payload of status/alarm/triggered).
sub trigger_text {
    my ($v) = @_;
    my %t = (1 => 'zone 1', 2 => 'zone 2', 3 => 'zone 3', 4 => 'zone 4', 5 => 'PIR / alarm input', 6 => 'sound',
             7 => 'zone 1 + PIR', 8 => 'zone 2 + PIR', 9 => 'zone 3 + PIR', 10 => 'zone 4 + PIR', 99 => 'test alarm');
    return defined $v && $t{$v} ? $t{$v} : 'trigger ' . ($v // '?');
}

# All IDs under which a camera may appear as 2nd topic level, upper-case:
# manual MQTT ID, MQTT client ID (from the broker log), MAC without colons.
# Full HD firmwares differ in which one they use, so all are accepted.
sub topic_ids {
    my ($cam, $st, $bl) = @_;
    my @ids;
    push @ids, uc $cam->{mqtt_id} if length($cam->{mqtt_id} // '');
    my $cid = $bl && $bl->{by_ip}{ $cam->{ip} } ? $bl->{by_ip}{ $cam->{ip} }{client_id} : '';
    push @ids, uc $cid if length($cid // '');
    my $mac = mac_id($st->{cams}{ $cam->{id} }{info}{mac});
    push @ids, $mac if length $mac;
    my %seen;
    return grep { !$seen{$_}++ } @ids;
}

# Triggers an alarm on the camera (Full HD: cmd=pushhostalarm). The camera then
# runs its alarm actions - including the MQTT alarm topic - if they are active.
sub test_alarm {
    my ($c, $cam) = @_;
    my ($ok, $v, $err) = cgi_call($c, $cam, 'cmd=pushhostalarm');
    return ($ok, $err);
}

# --------------------------------------------------------------------------
# LoxBerry broker / alarm daemon
# --------------------------------------------------------------------------

sub broker_details {
    my $d = eval { require LoxBerry::IO; LoxBerry::IO::mqtt_connectiondetails() };
    return $d || {};
}

sub alarmd_pid {
    return 0 unless -f $PID_FILE;
    open(my $fh, '<', $PID_FILE) or return 0;
    my $pid = <$fh>; close $fh;
    $pid = int($pid // 0);
    return ($pid && kill(0, $pid)) ? $pid : 0;
}

sub start_alarmd {
    return 1 if alarmd_pid();
    my $script = "$lbpbindir/alarmd.pl";
    my $pid = fork();
    return 0 unless defined $pid;
    if ($pid == 0) {
        POSIX::setsid();
        # Keep STDERR in the log, so a crash at start (missing module, broker
        # error) is visible in the Logs tab instead of disappearing.
        open(STDIN, '<', '/dev/null'); open(STDOUT, '>>', "$lbplogdir/alarmd.log"); open(STDERR, '>>', "$lbplogdir/alarmd.log");
        exec('/usr/bin/perl', $script) or POSIX::_exit(1);
    }
    # Give it a moment and confirm it is alive.
    for (1 .. 6) { select(undef, undef, undef, 0.5); return 1 if alarmd_pid(); }
    return 0;
}

sub alarmd_log_tail {
    my ($n) = @_;
    open(my $fh, '<', "$lbplogdir/alarmd.log") or return '';
    my @l = <$fh>; close $fh;
    @l = @l[-$n .. -1] if @l > $n;
    return join('', @l);
}

sub stop_alarmd {
    my $pid = alarmd_pid() or return 1;
    kill('TERM', $pid);
    return 1;
}

1;
