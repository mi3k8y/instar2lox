#!/usr/bin/perl
# Instar2Lox - Web interface
# Pages: cams (default), edit, mqtt, settings, loxone, logs

use strict;
use warnings;
use CGI;
use JSON;
use POSIX qw(strftime);
use Encode qw(decode);
use LoxBerry::System;
use LoxBerry::Web;
use LoxBerry::Log;

require "$lbpbindir/Instar2Lox.pm";

# Camera names may contain Czech characters: input is decoded in P(), output of
# this plugin's own content is encoded. LoxBerry header/footer are printed raw,
# otherwise their (already UTF-8) menu texts get double-encoded.

my $plugin  = LoxBerry::System::plugindata();
my $version = $plugin->{PLUGINDB_VERSION} // '0.1.0';

my $log = LoxBerry::Log->new(
    name => 'webui', filename => "$lbplogdir/webui.log", append => 1, addtime => 1, stderr => 0,
);

my $q      = CGI->new;
my $page   = $q->param('page')   // 'cams';
my $action = $q->param('action') // '';
my $id     = $q->param('id')     // '';
my $c      = Instar2Lox::load_cfg();
my (@ok, @err);

sub H { return Instar2Lox::html(@_); }
sub P {
    my $v = $q->param($_[0]);
    return '' unless defined $v;
    return utf8::is_utf8($v) ? $v : decode('UTF-8', $v);
}

# ------------------------------------------------------------------------------
# Downloads (must run before any HTML output)
# ------------------------------------------------------------------------------

if ($action eq 'download_viu') {
    my $pre  = $c->{global}{udp_prefix};
    my $port = $c->{global}{udp_port};
    my $attrs = ' Signed="true" Analog="true" SourceValLow="0" DestValLow="0" SourceValHigh="100" DestValHigh="100" DefVal="0" MinVal="-2147483647" MaxVal="2147483647"';
    my $xml = qq{<?xml version="1.0" encoding="utf-8"?>\n};
    $xml .= qq{<VirtualInUdp Title="INSTAR cameras" Comment="instar2lox" Address="" Port="$port">\n};
    $xml .= qq{  <VirtualInUdpCmd Title="INSTAR offline count" Comment="Number of offline cameras" Address="" Check="$pre.offline_count=\\v"$attrs/>\n};
    $xml .= qq{  <VirtualInUdpCmd Title="INSTAR outdated count" Comment="Number of cameras with outdated firmware" Address="" Check="$pre.outdated_count=\\v"$attrs/>\n};
    for my $cam (@{ $c->{cameras} }) {
        my $n = H($cam->{name});
        for my $f (['offline', '1 = camera not reachable'], ['outdated', '1 = firmware outdated'], ['alarm', 'Alarm pulse, value = INSTAR trigger code']) {
            $xml .= qq{  <VirtualInUdpCmd Title="$n $f->[0]" Comment="$f->[1]" Address="" Check="$pre.$cam->{id}.$f->[0]=\\v"$attrs/>\n};
        }
    }
    $xml .= "</VirtualInUdp>\n";
    binmode(STDOUT, ':encoding(UTF-8)');
    print "Content-Type: application/xml; charset=utf-8\n";
    print "Content-Disposition: attachment; filename=\"VIU_instar2lox.xml\"\n\n";
    print $xml;
    exit;
}

# ------------------------------------------------------------------------------
# Actions
# ------------------------------------------------------------------------------

if ($action eq 'save_cam') {
    my $orig = P('orig_id');
    my $name = P('name'); $name =~ s/^\s+|\s+$//g;
    my $nid  = Instar2Lox::slug(P('cid') ne '' ? P('cid') : $name);
    my $ip   = P('ip');   $ip =~ s/\s+//g;
    if ($name eq '' || $nid eq '') { push @err, 'Name is required.'; }
    elsif ($ip !~ /^[A-Za-z0-9.\-]+$/) { push @err, 'Invalid IP address or host name.'; }
    elsif ($nid ne $orig && Instar2Lox::find_cam($c, $nid)) { push @err, "Camera ID '$nid' already exists."; }
    else {
        my $cam = $orig ne '' ? Instar2Lox::find_cam($c, $orig) : undef;
        unless ($cam) { $cam = {}; push @{ $c->{cameras} }, $cam; }
        my $old_pass = $cam->{pass} // '';
        %$cam = (
            %$cam,
            id      => $nid,
            name    => $name,
            ip      => $ip,
            port    => int(P('port') || 80),
            user    => P('user'),
            pass    => (P('pass') ne '' ? P('pass') : (P('clear_pass') eq '1' ? '' : $old_pass)),
            mqtt_id => uc(P('mqtt_id') =~ s/[^A-Za-z0-9_\-]//gr),
            monitor => P('monitor') eq '0' ? 0 : 1,
            reboot  => {
                mode   => P('r_mode') || 'off',
                dow    => int(P('r_dow') || 7),
                dom    => int(P('r_dom') || 1),
                hour   => int(P('r_hour') || 0),
                minute => int(P('r_minute') || 0),
            },
        );
        if ($orig ne '' && $orig ne $nid) {
            Instar2Lox::with_state(sub { $_[0]{cams}{$nid} = delete $_[0]{cams}{$orig} if $_[0]{cams}{$orig}; });
        }
        Instar2Lox::save_cfg($c);
        LOGINF("Camera '$name' ($ip) saved");
        my ($ok, $info, $e) = Instar2Lox::fetch_info($c, $cam, 0);
        if ($ok) {
            Instar2Lox::with_state(sub { my $s = $_[0]{cams}{$nid} ||= {}; $s->{info} = $info; $s->{last_ok} = time(); $s->{fails} = 0; $s->{error} = ''; });
            push @ok, "Camera '$name' saved and reachable: $info->{model}, firmware $info->{softVersion}.";
        } else {
            push @err, "Camera '$name' saved, but test call failed: $e";
        }
        $page = 'cams';
    }
    $page = 'edit' if @err && !@ok;
}
elsif ($action eq 'scan') {
    if (!length $c->{global}{pass}) { push @err, 'Set the common camera login in Settings first - the scan uses it.'; }
    else {
        my $found = Instar2Lox::scan_subnet($c);
        Instar2Lox::save_json_atomic("$lbpdatadir/scan.json", { time => time(), found => $found });
        my $new = grep { !$_->{known} } @$found;
        push @ok, scalar(@$found) . ' INSTAR camera(s) found on ' . Instar2Lox::subnet_prefix() . ".0/24, $new not yet added.";
    }
}
elsif ($action eq 'add_found' || $action eq 'add_all_found') {
    my $scan = Instar2Lox::load_json("$lbpdatadir/scan.json", {});
    my @list = grep { !$_->{auth_failed} && !Instar2Lox::find_cam_ip($c, $_->{ip}) } @{ $scan->{found} || [] };
    @list = grep { $_->{ip} eq P('ip') } @list if $action eq 'add_found';
    for my $f (@list) {
        my $name = $f->{name};
        $name = "Cam " . (split /\./, $f->{ip})[-1] unless defined $name && length $name;
        my $nid = Instar2Lox::slug($name) || 'cam';
        my ($base, $k) = ($nid, 2);
        $nid = $base . $k++ while Instar2Lox::find_cam($c, $nid);
        push @{ $c->{cameras} }, { id => $nid, name => $name, ip => $f->{ip}, port => 80, user => '', pass => '', mqtt_id => '',
                                   monitor => 1, reboot => { mode => 'off', dow => 7, dom => 1, hour => 3, minute => 30 } };
        Instar2Lox::with_state(sub { my $s = $_[0]{cams}{$nid} ||= {}; $s->{info} = $f->{info}; $s->{last_ok} = time(); $s->{fails} = 0; });
        push @ok, "Added '$name' ($f->{ip}) as ID '$nid'.";
    }
    Instar2Lox::save_cfg($c) if @list;
    push @err, 'Nothing to add.' unless @list;
}
elsif ($action eq 'delete_cam') {
    my $cam = Instar2Lox::find_cam($c, $id);
    if ($cam) {
        $c->{cameras} = [ grep { $_->{id} ne $id } @{ $c->{cameras} } ];
        Instar2Lox::save_cfg($c);
        Instar2Lox::with_state(sub { delete $_[0]{cams}{$id}; });
        push @ok, "Camera '$cam->{name}' removed.";
    }
}
elsif ($action eq 'refresh_all') {
    my $rc = system('/usr/bin/perl', "$lbpbindir/worker.pl", '--force');
    if ($rc == 0) { push @ok, 'All cameras polled, all values resent to the Miniserver.'; }
    else          { push @err, 'Poll run failed - see worker log.'; }
}
elsif ($action eq 'refresh') {
    my $cam = Instar2Lox::find_cam($c, $id);
    if ($cam) {
        my ($ok, $info, $e) = Instar2Lox::fetch_info($c, $cam, 0);
        if ($ok) {
            Instar2Lox::with_state(sub { my $s = $_[0]{cams}{$id} ||= {}; $s->{info} = $info; $s->{last_ok} = time(); $s->{fails} = 0; $s->{error} = ''; });
            push @ok, "'$cam->{name}': $info->{model}, firmware $info->{softVersion}, WebUI $info->{webVersion}.";
        } else { push @err, "'$cam->{name}': $e"; }
    }
}
elsif ($action eq 'reboot' || $action eq 'reboot_all') {
    my @list = $action eq 'reboot_all' ? @{ $c->{cameras} } : grep { $_ } (Instar2Lox::find_cam($c, $id));
    for my $cam (@list) {
        my ($ok, $e) = Instar2Lox::reboot_cam($c, $cam);
        if ($ok) {
            push @ok, "Reboot sent to '$cam->{name}'.";
            LOGINF("Manual reboot of '$cam->{name}'");
            Instar2Lox::with_state(sub { my $s = $_[0]{cams}{ $cam->{id} } ||= {}; $s->{last_reboot} = time(); $s->{last_reboot_ok} = 1;
                $s->{grace_until} = time() + 60 * $c->{global}{reboot_grace_min}; });
        } else { push @err, "Reboot of '$cam->{name}' failed: $e"; }
    }
}
elsif ($action eq 'schedule_all') {
    my $r = { mode => P('r_mode') || 'off', dow => int(P('r_dow') || 7), dom => int(P('r_dom') || 1),
              hour => int(P('r_hour') || 0), minute => int(P('r_minute') || 0) };
    $_->{reboot} = { %$r } for @{ $c->{cameras} };
    Instar2Lox::save_cfg($c);
    push @ok, 'Reboot schedule applied to all cameras: ' . Instar2Lox::schedule_text({ reboot => $r }) . '.';
}
elsif ($action eq 'save_settings') {
    my $g = $c->{global};
    $g->{user} = P('g_user');
    $g->{pass} = P('g_pass') if P('g_pass') ne '';
    $g->{ms_no}              = int(P('ms_no') || 1);
    $g->{udp_port}           = int(P('udp_port') || 7088);
    my $pre = P('udp_prefix'); $pre =~ s/[^A-Za-z0-9_]//g; $g->{udp_prefix} = $pre || 'instar2lox';
    $g->{check_interval_min} = (int(P('check_interval_min')) || 5);
    $g->{check_interval_min} = 1 if $g->{check_interval_min} < 1;
    $g->{offline_threshold}  = (int(P('offline_threshold')) || 2);
    $g->{reboot_grace_min}   = (int(P('reboot_grace_min')) || 6);
    $g->{http_timeout}       = (int(P('http_timeout')) || 5);
    $g->{resend_hours}       = int(P('resend_hours') || 0);
    $g->{alarm_enable}       = P('alarm_enable') eq '0' ? 0 : 1;
    $g->{alarm_topic}        = P('alarm_topic') || 'instar/+/status/alarm/triggered';
    $g->{alarm_pulse_sec}    = (int(P('alarm_pulse_sec')) || 2);
    $g->{alarm_cooldown_sec} = int(P('alarm_cooldown_sec') || 0);
    my %tv;
    for my $line (split /\r?\n/, P('target_versions')) {
        next unless $line =~ /^\s*(.+?)\s*=\s*(\S+)\s*$/;
        $tv{$1} = $2;
    }
    $g->{target_versions} = \%tv;
    Instar2Lox::save_cfg($c);
    Instar2Lox::start_alarmd() if $g->{alarm_enable};
    push @ok, 'Settings saved.';
    $page = 'settings';
}
elsif ($action eq 'udp_test') {
    my $n = Instar2Lox::udp_send($c, [['test', time() % 1000]]);
    my $ip = Instar2Lox::ms_ip($c) // 'none';
    if ($n) { push @ok, "Test datagram '$c->{global}{udp_prefix}.test=...' sent to $ip:$c->{global}{udp_port}. Check the Loxone UDP monitor."; }
    else    { push @err, "UDP send failed (Miniserver: $ip)."; }
    $page = 'loxone';
}
elsif ($action eq 'mqtt_setup' || $action eq 'mqtt_setup_all') {
    my $brk  = Instar2Lox::broker_details();
    my $addr = LoxBerry::System::get_localip();
    my $port = $brk->{brokerport} || 1883;
    if (!$brk->{brokeruser}) { push @err, 'Cannot read LoxBerry broker credentials (is the MQTT broker installed?).'; }
    else {
        my @list = $action eq 'mqtt_setup_all' ? @{ $c->{cameras} } : grep { $_ } (Instar2Lox::find_cam($c, $id));
        for my $cam (@list) {
            my ($ok, $e) = Instar2Lox::set_mqtt_cfg($c, $cam, $addr, $port, $brk->{brokeruser}, $brk->{brokerpass} // '');
            if ($ok) { push @ok, "'$cam->{name}': MQTT now points to $addr:$port with LoxBerry broker login."; LOGOK("MQTT configured on '$cam->{name}'"); }
            else     { push @err, "'$cam->{name}': $e"; }
        }
    }
    $page = 'mqtt';
}
elsif ($action eq 'bulk_read') {
    my %res;
    for my $cam (@{ $c->{cameras} }) { $res{ $cam->{id} } = Instar2Lox::bulk_read($c, $cam); }
    Instar2Lox::save_json_atomic("$lbpdatadir/bulk_read.json", { time => time(), cams => \%res });
    push @ok, 'Current settings read from ' . scalar(keys %res) . ' camera(s).';
    $page = 'bulk';
}
elsif ($action eq 'bulk_apply') {
    my @cams = grep { P("cam_$_->{id}") eq '1' } @{ $c->{cameras} };
    my @q;
    for my $b (@Instar2Lox::BULK) {
        my $v = P("set_$b->{key}");
        next if $v eq '';
        my %allowed = @{ $b->{opts} };
        next unless exists $allowed{$v};
        push @q, [ "$b->{label}: $allowed{$v}", $b, $v ];
    }
    if (!@cams) { push @err, 'No camera selected.'; }
    elsif (!@q) { push @err, 'Nothing to change - all settings are on "no change".'; }
    else {
        my @rows;
        for my $cam (@cams) {
            for my $x (@q) {
                my ($ok, $e) = (1, '');
                my @queries = $x->[1]{set}->($x->[2], $c, $cam);
                ($ok, $e) = (0, $x->[1]{unsupported} // 'not supported by this camera') unless @queries;
                for my $query (@queries) {
                    my ($o, $er) = Instar2Lox::cgi_set($c, $cam, $query);
                    ($ok, $e) = (0, $er) unless $o;
                    last unless $o;
                }
                push @rows, [ $cam->{name} . ' (' . $cam->{ip} . ')', $x->[0], $ok, $e ];
            }
            LOGINF("Bulk change on '$cam->{name}': " . join('; ', map { $_->[0] } @q));
        }
        my $fail = grep { !$_->[2] } @rows;
        push @ok,  (scalar(@rows) - $fail) . ' change(s) applied.' if @rows > $fail;
        push @err, "$fail change(s) failed - see the table below." if $fail;
        Instar2Lox::save_json_atomic("$lbpdatadir/bulk_last.json", { time => time(), rows => \@rows });
    }
    $page = 'bulk';
}
elsif ($action eq 'clear_unknown') {
    my $as = Instar2Lox::load_json($Instar2Lox::ALARM_FILE, {});
    delete $as->{unknown};
    Instar2Lox::save_json_atomic($Instar2Lox::ALARM_FILE, $as);
    push @ok, 'List of unknown camera IDs cleared.';
    $page = 'mqtt';
}
elsif ($action eq 'test_alarm') {
    my $cam = Instar2Lox::find_cam($c, $id);
    if ($cam) {
        my ($ok, $e) = Instar2Lox::test_alarm($c, $cam);
        if ($ok) { push @ok, "Alarm triggered on '$cam->{name}'. If the camera's alarm actions are active, 'Last alarm' updates within a few seconds - reload the page."; }
        else     { push @err, "'$cam->{name}': $e"; }
    }
    $page = 'mqtt';
}
elsif ($action eq 'alarmd_restart') {
    Instar2Lox::stop_alarmd();
    sleep 2;
    if (Instar2Lox::start_alarmd()) { push @ok, 'Alarm listener restarted.'; }
    else { push @err, 'Alarm listener did not start - see the log excerpt below.'; }
    $page = 'mqtt';
}

$c = Instar2Lox::load_cfg();
my $st = Instar2Lox::read_state();

# ------------------------------------------------------------------------------
# Output
# ------------------------------------------------------------------------------

LoxBerry::Web::lbheader("INSTAR2Lox V$version", '', 'help.html');
binmode(STDOUT, ':encoding(UTF-8)');
print css();
my %tabs = (cams => 'Cameras', bulk => 'Bulk settings', mqtt => 'MQTT &amp; Alarms', settings => 'Settings', loxone => 'Loxone', logs => 'Logs');
print '<div class="i2l-nav">';
for my $t (qw(cams bulk mqtt settings loxone logs)) {
    my $cls = ($page eq $t || ($t eq 'cams' && $page eq 'edit')) ? ' class="active"' : '';
    print qq{<a href="index.cgi?page=$t"$cls>$tabs{$t}</a>};
}
print '</div>';
print qq{<div class="i2l-msg ok">} . H($_) . '</div>' for @ok;
print qq{<div class="i2l-msg err">} . H($_) . '</div>' for @err;

if    ($page eq 'edit')     { page_edit(); }
elsif ($page eq 'bulk')     { page_bulk(); }
elsif ($page eq 'mqtt')     { page_mqtt(); }
elsif ($page eq 'settings') { page_settings(); }
elsif ($page eq 'loxone')   { page_loxone(); }
elsif ($page eq 'logs')     { page_logs(); }
else                        { page_cams(); }

print qq{<p class="i2l-foot">instar2lox $version</p>};
binmode(STDOUT, ':raw');
LoxBerry::Web::lbfooter();
exit;

# ------------------------------------------------------------------------------

sub form_start { return qq{<form method="post" action="index.cgi" data-ajax="false" style="display:inline">}; }

sub btn {
    my ($act, $label, $extra, $confirm) = @_;
    my $hid = '';
    for my $k (sort keys %{ $extra || {} }) { $hid .= qq{<input type="hidden" name="$k" value="} . H($extra->{$k}) . '">'; }
    my $onc = $confirm ? q{ onclick="return confirm('} . H($confirm) . q{');"} : '';
    return form_start() . qq{<input type="hidden" name="action" value="$act">$hid<button type="submit" class="i2l-btn" data-role="none"$onc>$label</button></form>};
}

sub page_cams {
    my $od = Instar2Lox::compute_outdated($c, $st);
    my $al = Instar2Lox::load_json($Instar2Lox::ALARM_FILE, {});
    print '<div class="i2l-bar">';
    print btn('refresh_all', 'Poll all now');
    print btn('scan', 'Search network for cameras');
    print qq{<a class="i2l-btn" href="index.cgi?page=edit" data-ajax="false">+ Add camera manually</a>};
    print btn('reboot_all', 'Reboot all', {}, 'Reboot ALL cameras now?') if @{ $c->{cameras} };
    print '</div>';
    my $scan = Instar2Lox::load_json("$lbpdatadir/scan.json", {});
    my @new = grep { !Instar2Lox::find_cam_ip($c, $_->{ip}) } @{ $scan->{found} || [] };
    if (@new) {
        print '<h3>Found in the network, not added yet</h3><table class="i2l-tab"><tr><th>IP</th><th>Name in camera</th><th>Model</th><th>Firmware</th><th></th></tr>';
        for my $f (@new) {
            if ($f->{auth_failed}) {
                print '<tr><td>' . H($f->{ip}) . '</td><td colspan="3"><span class="b amber">login rejected</span> <small>camera uses a different user/password than the common login</small></td><td>'
                    . qq{<a class="i2l-btn" href="index.cgi?page=edit&amp;ip=} . H($f->{ip}) . '" data-ajax="false">Add with own login</a></td></tr>';
                next;
            }
            print '<tr><td>' . H($f->{ip}) . '</td><td>' . H($f->{name} || '-') . '</td><td>' . H($f->{info}{model} // '') . '</td><td>' . H($f->{info}{softVersion} // '') . '</td><td>'
                . btn('add_found', 'Add', { ip => $f->{ip} }) . '</td></tr>';
        }
        my $n_ok = grep { !$_->{auth_failed} } @new;
        print '</table><p>' . ($n_ok > 1 ? btn('add_all_found', "Add all $n_ok") : '') . ' <span class="i2l-hint">scanned ' . Instar2Lox::fmt_time($scan->{time}) . '. Cameras are added without a reboot plan - set it via Edit or "Same reboot plan for all cameras".</span></p>';
    }
    unless (@{ $c->{cameras} }) {
        print '<p>No cameras yet. Set the common camera login under <a href="index.cgi?page=settings">Settings</a>, then use <b>Search network for cameras</b>.</p>' unless @new;
        return;
    }
    print '<table class="i2l-tab"><tr><th>Camera</th><th>Status</th><th>Model</th><th>Firmware</th><th>WebUI</th><th>Up since</th><th>SD</th><th>Reboot plan</th><th>Last alarm</th><th></th></tr>';
    for my $cam (@{ $c->{cameras} }) {
        my $s = $st->{cams}{ $cam->{id} } || {};
        my $i = $s->{info} || {};
        my $o = $od->{ $cam->{id} } || {};
        my $status = !$cam->{monitor} ? '<span class="b grey">not monitored</span>'
                   : $s->{offline}    ? '<span class="b red">OFFLINE</span>'
                   : ($s->{fails} // 0) > 0 ? '<span class="b amber">no answer</span>'
                   : $s->{last_ok}    ? '<span class="b green">online</span>'
                   : '<span class="b grey">unknown</span>';
        $status .= '<br><small>' . H($s->{error}) . '</small>' if $s->{error};
        my $fw = H($i->{softVersion} // '-');
        if ($o->{outdated}) { $fw .= ' <span class="b amber" title="Reference: ' . H($o->{latest}) . ' (' . ($o->{source} eq 'target' ? 'target version' : 'newest in your cameras') . ')">update ' . H($o->{latest}) . '</span>'; }
        elsif ($i->{softVersion}) { $fw .= ' <span class="b green">current</span>'; }
        my $ae = $al->{cams}{ $cam->{id} };
        my $alarm = $ae ? Instar2Lox::fmt_time($ae->{last}) . ' (' . Instar2Lox::trigger_text($ae->{val}) . ', ' . ($ae->{count} // 0) . 'x)' : '-';
        my $sd = $i->{sdstatus} ? H($i->{sdstatus}) . ($i->{sdtotalspace} ? sprintf(' %.0f%% free', 100 * ($i->{sdfreespace} // 0) / ($i->{sdtotalspace} || 1)) : '') : '-';
        my $web = H(Instar2Lox::cam_base($cam));
        my $rb  = H(Instar2Lox::schedule_text($cam));
        $rb .= '<br><small>last ' . Instar2Lox::fmt_time($s->{last_reboot}) . ($s->{last_reboot_ok} ? '' : ' FAILED') . '</small>' if $s->{last_reboot};
        print '<tr>';
        print '<td><b>' . H($cam->{name}) . qq{</b><br><small><a href="$web" target="_blank">} . H($cam->{ip}) . '</a> &middot; ' . H($cam->{id}) . '</small></td>';
        print "<td>$status</td><td>" . H($i->{model} // '-') . "</td><td>$fw</td><td>" . H($i->{webVersion} // '-') . '</td>';
        print '<td>' . H($i->{startdate} // '-') . "</td><td>$sd</td><td>$rb</td><td>$alarm</td>";
        print '<td class="act">' . btn('refresh', 'Refresh', { id => $cam->{id} })
            . qq{<a class="i2l-btn" href="index.cgi?page=edit&amp;id=} . H($cam->{id}) . '" data-ajax="false">Edit</a>'
            . btn('reboot', 'Reboot', { id => $cam->{id} }, "Reboot $cam->{name} now?") . '</td>';
        print '</tr>';
    }
    print '</table>';
    print '<p class="i2l-hint">Last poll: ' . Instar2Lox::fmt_time($st->{meta}{last_poll}) . " &middot; interval $c->{global}{check_interval_min} min &middot; a camera is reported offline after $c->{global}{offline_threshold} failed polls (not during $c->{global}{reboot_grace_min} min after a reboot).</p>";

    print '<h3>Same reboot plan for all cameras</h3>';
    print form_start() . '<input type="hidden" name="action" value="schedule_all">';
    print schedule_fields({ mode => 'monthly', dow => 7, dom => 1, hour => 3, minute => 30 });
    print qq{ <button type="submit" class="i2l-btn" data-role="none" onclick="return confirm('Overwrite the reboot plan of all cameras?');">Apply to all</button></form>};
}

sub sel {
    my ($name, $cur, @opts) = @_;
    my $h = qq{<select name="$name" data-role="none">};
    while (@opts) {
        my ($v, $l) = splice(@opts, 0, 2);
        my $s = (defined $cur && "$cur" eq "$v") ? ' selected' : '';
        $h .= qq{<option value="} . H($v) . qq{"$s>} . H($l) . '</option>';
    }
    return $h . '</select>';
}

sub schedule_fields {
    my ($r) = @_;
    my @dow = map { ($_ => (qw(- Monday Tuesday Wednesday Thursday Friday Saturday Sunday))[$_]) } 1 .. 7;
    return sel('r_mode', $r->{mode}, off => 'no automatic reboot', daily => 'daily', weekly => 'weekly', monthly => 'monthly')
         . ' weekday ' . sel('r_dow', $r->{dow}, @dow)
         . ' day of month ' . sel('r_dom', $r->{dom}, map { ($_ => $_) } 1 .. 28)
         . ' at ' . sel('r_hour', $r->{hour}, map { ($_ => sprintf('%02d', $_)) } 0 .. 23)
         . ':' . sel('r_minute', $r->{minute}, map { ($_ => sprintf('%02d', $_)) } grep { $_ % 5 == 0 } 0 .. 55);
}

sub page_edit {
    my $cam = $id ne '' ? Instar2Lox::find_cam($c, $id) : undef;
    if (@err && !$cam) {
        $cam = { name => P('name'), id => P('cid'), ip => P('ip'), port => P('port'), user => P('user'), mqtt_id => P('mqtt_id'), monitor => P('monitor'),
                 reboot => { mode => P('r_mode'), dow => P('r_dow'), dom => P('r_dom'), hour => P('r_hour'), minute => P('r_minute') } };
    }
    $cam ||= { ip => P('ip'), port => 80, monitor => 1, reboot => { mode => 'off', dow => 7, dom => 1, hour => 3, minute => 30 } };
    my $mac = $st->{cams}{ $cam->{id} // '' }{info}{mac} // '';
    print '<h2>' . ($id ne '' ? 'Edit camera' : 'Add camera') . '</h2>';
    print qq{<form method="post" action="index.cgi" data-ajax="false"><input type="hidden" name="action" value="save_cam">};
    print '<input type="hidden" name="orig_id" value="' . H($id) . '">';
    print '<table class="i2l-form">';
    print '<tr><td>Name</td><td><input name="name" value="' . H($cam->{name}) . '" data-role="none" required></td><td>e.g. Vchod</td></tr>';
    print '<tr><td>ID</td><td><input name="cid" value="' . H($cam->{id}) . '" data-role="none"></td><td>a-z, 0-9 only; used in UDP commands. Empty = derived from name.</td></tr>';
    print '<tr><td>IP address</td><td><input name="ip" value="' . H($cam->{ip}) . '" data-role="none" required></td><td></td></tr>';
    print '<tr><td>HTTP port</td><td><input name="port" value="' . H($cam->{port}) . '" data-role="none" size="6"></td><td></td></tr>';
    print '<tr><td>User</td><td><input name="user" value="' . H($cam->{user}) . '" data-role="none" autocomplete="off"></td><td>empty = common login from Settings</td></tr>';
    print '<tr><td>Password</td><td><input type="password" name="pass" value="" data-role="none" autocomplete="new-password"></td><td>'
        . (length($cam->{pass} // '') ? 'own password stored - leave empty to keep, ' . sel('clear_pass', '0', 0 => 'keep', 1 => 'remove (use common)') : 'empty = common password') . '</td></tr>';
    print '<tr><td>MQTT ID</td><td><input name="mqtt_id" value="' . H($cam->{mqtt_id}) . '" data-role="none"></td><td>second level of the alarm topic. Empty = camera MAC'
        . ($mac ? ' (<code>' . H(Instar2Lox::mac_id($mac)) . '</code>)' : ' (read automatically)') . '</td></tr>';
    print '<tr><td>Monitoring</td><td>' . sel('monitor', $cam->{monitor} ? 1 : 0, 1 => 'yes', 0 => 'no') . '</td><td>offline / firmware check</td></tr>';
    print '<tr><td>Automatic reboot</td><td colspan="2">' . schedule_fields($cam->{reboot}) . '</td></tr>';
    print '</table>';
    print '<button type="submit" class="i2l-btn" data-role="none">Save and test</button> <a class="i2l-btn" href="index.cgi" data-ajax="false">Cancel</a></form>';
    if ($id ne '') {
        print '<p style="margin-top:20px">' . btn('delete_cam', 'Delete camera', { id => $id }, 'Delete this camera from the plugin?') . '</p>';
    }
}

sub page_bulk {
    my $rd = Instar2Lox::load_json("$lbpdatadir/bulk_read.json", {});
    my @B  = @Instar2Lox::BULK;
    my @cams = @{ $c->{cameras} };
    unless (@cams) { print '<p>No cameras yet.</p>'; return; }

    my $last = Instar2Lox::load_json("$lbpdatadir/bulk_last.json", {});
    if ($action eq 'bulk_apply' && $last->{rows} && @{ $last->{rows} }) {
        my @f = grep { !$_->[2] } @{ $last->{rows} };
        if (@f) {
            print '<h3>Not applied</h3><table class="i2l-tab"><tr><th>Camera</th><th>Setting</th><th>Reason</th></tr>';
            print '<tr><td>' . H($_->[0]) . '</td><td>' . H($_->[1]) . '</td><td>' . H($_->[3]) . '</td></tr>' for @f;
            print '</table>';
        }
    }

    print qq{<form method="post" action="index.cgi" data-ajax="false"><input type="hidden" name="action" value="bulk_apply">};
    print '<h2>Change settings on several cameras</h2><p class="i2l-hint">Leave "no change" where nothing should change. Only the chosen settings are written.</p>';
    print '<div class="i2l-groups">';
    my $grp = '';
    for my $b (@B) {
        if ($b->{group} ne $grp) {
            print '</table></div>' if $grp ne '';
            $grp = $b->{group};
            print '<div class="i2l-group"><h3>' . H($grp) . '</h3><table class="i2l-form">';
        }
        my $s = sel("set_$b->{key}", '', '' => 'no change', @{ $b->{opts} });
        $s =~ s/<select /<select data-warn="@{[ H($b->{warn}) ]}" / if $b->{warn};
        print '<tr><td>' . H($b->{label}) . ($b->{hint} ? '<br><small class="i2l-hint">' . H($b->{hint}) . '</small>' : '') . "</td><td>$s</td></tr>";
    }
    print '</table></div></div>';

    print '<h3>Cameras</h3><p><label><input type="checkbox" data-role="none" checked onclick="var f=this.form;for(var i=0;i<f.elements.length;i++){if(f.elements[i].name.indexOf(\'cam_\')==0)f.elements[i].checked=this.checked;}"> <b>all</b></label></p><div class="i2l-camsel">';
    for my $cam (@cams) {
        print '<label><input type="checkbox" data-role="none" name="cam_' . H($cam->{id}) . '" value="1" checked> ' . H($cam->{name}) . ' <small>' . H($cam->{ip}) . '</small></label>';
    }
    print '</div>';
    print q{<p><button type="submit" class="i2l-btn" data-role="none" onclick="var f=this.form,w=[];for(var i=0;i<f.elements.length;i++){var e=f.elements[i];if(e.getAttribute&&e.getAttribute('data-warn')&&e.value)w.push(e.getAttribute('data-warn'));}if(w.length&&!confirm(w.join('\\n')))return false;return confirm('Apply the chosen settings to the selected cameras?');">Apply to selected cameras</button></p></form>};

    print '<h2>Current settings</h2><p>' . btn('bulk_read', 'Read from all cameras')
        . ' <span class="i2l-hint">' . ($rd->{time} ? 'read ' . Instar2Lox::fmt_time($rd->{time}) : 'not read yet') . '</span></p>';
    if ($rd->{cams}) {
        my @rb = grep { $_->{get} || $_->{read} } @B;
        my @rc = grep { $rd->{cams}{ $_->{id} } } @cams;
        print '<div style="overflow-x:auto"><table class="i2l-tab i2l-matrix"><tr><th>Setting</th>'
            . join('', map { '<th>' . H($_->{name}) . '<br><small>' . H((split /\./, $_->{ip})[-1]) . '</small></th>' } @rc) . '</tr>';
        my $grp = '';
        for my $b (@rb) {
            if ($b->{group} ne $grp) {
                $grp = $b->{group};
                print '<tr class="i2l-grp"><td colspan="' . (1 + @rc) . '">' . H($grp) . '</td></tr>';
            }
            my %lab = @{ $b->{opts} };
            my @txt = map { my $v = $rd->{cams}{ $_->{id} }{ $b->{key} }; defined $v ? ($lab{$v} // $v) : '?' } @rc;
            my %u = map { $_ => 1 } grep { $_ ne '?' && $_ ne 'n/a' } @txt;
            my $diff = keys %u > 1;
            print '<tr' . ($diff ? ' class="i2l-diff"' : '') . '><td>' . H($b->{label}) . ($diff ? ' <span class="b amber">differs</span>' : '') . '</td>';
            for my $t (@txt) {
                my $cls = $t eq 'on' ? 'green' : $t eq 'off' ? 'grey' : '';
                print '<td>' . ($cls ? qq{<span class="b $cls">} . H($t) . '</span>' : H($t)) . '</td>';
            }
            print '</tr>';
        }
        print '</table></div><p class="i2l-hint">"?" = the camera did not report this value. "n/a" = the camera does not offer this function.</p>';
    }
}

sub page_mqtt {
    my $brk = Instar2Lox::broker_details();
    my $lip = LoxBerry::System::get_localip();
    my $pid = Instar2Lox::alarmd_pid();
    my $al  = Instar2Lox::load_json($Instar2Lox::ALARM_FILE, {});
    print '<h2>Alarm listener</h2><table class="i2l-form">';
    print '<tr><td>Status</td><td>' . ($pid ? qq{<span class="b green">running</span> (PID $pid)} : ($c->{global}{alarm_enable} ? '<span class="b red">not running</span>' : '<span class="b grey">disabled</span>')) . ' ' . btn('alarmd_restart', 'Restart') . '</td></tr>';
    my $hb = (stat("$lbplogdir/worker.heartbeat"))[9];
    print '<tr><td>Cron worker</td><td>' . ($hb && time() - $hb < 180 ? '<span class="b green">running</span> last run ' . Instar2Lox::fmt_time($hb)
        : '<span class="b red">not running</span>' . ($hb ? ' last run ' . Instar2Lox::fmt_time($hb) : ' never ran') . ' <small>(it starts and watches the alarm listener every minute)</small>') . '</td></tr>';
    print '<tr><td>Broker</td><td>' . H(($brk->{brokerhost} // '?') . ':' . ($brk->{brokerport} // '?')) . ', user <code>' . H($brk->{brokeruser} // '-') . '</code></td></tr>';
    print '<tr><td>Topic</td><td><code>' . H($c->{global}{alarm_topic}) . '</code></td></tr>';
    print '<tr><td>UDP</td><td><code>' . H($c->{global}{udp_prefix}) . '.&lt;camera&gt;.alarm=&lt;trigger&gt;</code>, back to 0 after ' . H($c->{global}{alarm_pulse_sec}) . ' s, at most one alarm per camera every '
        . H($c->{global}{alarm_cooldown_sec} || 0) . ' s</td></tr></table>';
    if (!$pid && $c->{global}{alarm_enable}) {
        my $tail = Instar2Lox::alarmd_log_tail(15);
        print '<p><b>Last lines of the alarm listener log:</b></p><pre class="i2l-log">' . (length $tail ? H($tail) : '(empty - the listener never wrote anything)') . '</pre>';
    }

    my $tr  = Instar2Lox::load_json("$lbpdatadir/mqtt_traffic.json", {})->{ids} || {};
    my $bl  = Instar2Lox::broker_log_info();
    my %cid_count;
    $cid_count{$_}++ for grep { length } map { $bl->{by_ip}{ $_->{ip} }{client_id} // "" } @{ $c->{cameras} };
    print '<h2>Cameras on the MQTT broker</h2>';
    print '<p class="i2l-hint">Camera settings are read live from each camera. Client ID and rejected logins come from the broker log'
        . ($bl->{file} ? ' (<code>' . H($bl->{file}) . '</code>)' : ' (<b>broker log not found</b>)')
        . ', last message from the plugin\'s own subscription to <code>' . H((split m{/}, $c->{global}{alarm_topic})[0]) . '/#</code>. '
        . '"Configure" writes LoxBerry IP <code>' . H($lip) . '</code>, port <code>' . H($brk->{brokerport} // 1883) . '</code> and the broker login into the camera via its HTTP API.</p>';
    print '<table class="i2l-tab"><tr><th>Camera</th><th>MQTT settings in camera</th><th>Client ID</th><th>Topic ID</th><th>Last MQTT message</th><th>Last alarm</th><th>Status</th><th>Actions</th></tr>';
    my $now = time();
    for my $cam (@{ $c->{cameras} }) {
        my ($ok, $m, $e) = Instar2Lox::get_mqtt_cfg($c, $cam);
        my $s   = $st->{cams}{ $cam->{id} } || {};
        my @ids = Instar2Lox::topic_ids($cam, $st, $bl);
        my ($tid) = sort { ($tr->{$b}{last} // 0) <=> ($tr->{$a}{last} // 0) } grep { $tr->{$_} } @ids;
        $tid //= $ids[0] // '';
        my $ae  = $al->{cams}{ $cam->{id} };
        my $t   = $tr->{$tid};
        my $bi  = $bl->{by_ip}{ $cam->{ip} } || {};
        my $cid = $bi->{client_id} // '';
        print '<tr><td><b>' . H($cam->{name}) . '</b><br><small>' . H($cam->{ip}) . '</small></td>';
        my ($status, $good) = ('', 0);
        if ($ok) {
            my $pw_ok = $m->{pass} eq ($brk->{brokerpass} // "\x00");
            $good = ($m->{enable} eq '1' && $m->{external} eq '1' && $m->{address} eq $lip && $m->{auth} eq '1'
                     && $m->{user} eq ($brk->{brokeruser} // '') && $pw_ok);
            print '<td>' . ($m->{enable} eq '1' ? 'on' : '<b>off</b>') . ', ' . ($m->{external} eq '1' ? 'external' : '<b>internal</b>')
                . '<br><small>' . H("$m->{address}:$m->{port}") . ', user ' . ($m->{auth} eq '1' ? H($m->{user}) : 'none')
                . ', password ' . ($pw_ok ? 'matches' : '<b>differs</b> (' . length($m->{pass}) . ' chars)') . '</small></td>';
        } else {
            print '<td><span class="b red">cannot read</span><br><small>' . H($e) . '</small></td>';
        }
        print '<td>' . (length $cid ? '<code>' . H($cid) . '</code>' . ($bi->{connected} ? '<br><small>' . H($bi->{connected}) . '</small>' : '') : '-') . '</td>';
        print '<td><code>' . H($tid || '?') . '</code></td>';
        print '<td>' . ($t ? Instar2Lox::fmt_time($t->{last}) . '<br><small>' . H($t->{count}) . ' msgs</small>' : '-') . '</td>';
        my $flood = $ae && ($ae->{suppressed} // 0) > 20;
        print '<td>' . ($ae ? Instar2Lox::fmt_time($ae->{last}) . '<br><small>' . H(Instar2Lox::trigger_text($ae->{val})) . "<br>$ae->{count}x detected, " . ($ae->{sent} // 0) . 'x sent to Loxone</small>'
            . ($flood ? '<br><span class="b amber">very frequent</span>' : '') : '-') . '</td>';
        my $rejected_recent = $bi->{rejected} && (!$bi->{connected} || $bi->{rejected} gt $bi->{connected});
        my $gone = length $cid && $bl->{gone}{$cid} && (!$bi->{connected} || $bl->{gone}{$cid} gt $bi->{connected});
        if (!$ok)                                        { $status = '<span class="b red">camera not readable</span>'; }
        elsif (!$good)                                   { $status = '<span class="b red">settings differ</span>'; }
        elsif ($rejected_recent)                         { $status = '<span class="b red">login rejected</span>'; }
        elsif (length $cid && $cid_count{$cid} > 1)      { $status = '<span class="b red">duplicate client ID</span><br><small>cameras disconnect each other</small>'; }
        elsif ($gone)                                    { $status = '<span class="b red">disconnected</span><br><small>since ' . H($bl->{gone}{$cid}) . '</small>'; }
        elsif (length $cid || $t)                        { $status = '<span class="b green">connected</span>'; }
        else                                             { $status = '<span class="b amber">not seen yet</span>'; }
        if (length $cid && $bl->{kicks}{$cid} && $cid_count{$cid} == 1) {
            $status .= '<br><small>reconnected ' . $bl->{kicks}{$cid} . 'x</small>';
        }
        print "<td>$status</td><td class=\"act\">"
            . ($ok && !$good ? btn('mqtt_setup', 'Configure', { id => $cam->{id} }, "Write LoxBerry broker settings into $cam->{name}?") : '')
            . btn('test_alarm', 'Test alarm', { id => $cam->{id} }) . '</td></tr>';
    }
    print '</table>';
    print '<p>' . btn('mqtt_setup_all', 'Configure all cameras', {}, 'Write LoxBerry broker settings into ALL cameras?') . '</p>' if @{ $c->{cameras} };
    if (grep { $_ > 1 } values %cid_count) {
        print '<div class="i2l-msg err">Several cameras use the same MQTT client ID. The broker allows one connection per client ID, so these cameras keep '
            . 'throwing each other off and alarms get lost. Give each camera a unique <b>MQTT client ID</b> in its web interface (Smarthome &rarr; MQTT), e.g. its name.</div>';
    }
    my %known = map { ($_ => 1) } map { Instar2Lox::topic_ids($_, $st, $bl) } @{ $c->{cameras} };
    my @foreign = grep { !$known{$_} } sort keys %$tr;
    if (@foreign) {
        print '<h3>MQTT topic IDs not assigned to a camera</h3><table class="i2l-tab"><tr><th>Topic ID</th><th>Last message</th><th>Last topic</th></tr>';
        print '<tr><td><code>' . H($_) . '</code></td><td>' . Instar2Lox::fmt_time($tr->{$_}{last}) . '</td><td><code>' . H($tr->{$_}{last_topic}) . '</code></td></tr>' for @foreign;
        print '</table>';
    }

    # Unknown IDs: hide those that now belong to a camera and those older than 7 days.
    my %now_known = map { ($_ => 1) } map { Instar2Lox::topic_ids($_, $st, $bl) } @{ $c->{cameras} };
    my @unk = grep { my ($id) = (split m{/}, $_)[1]; !$now_known{ uc($id // '') } && time() - $al->{unknown}{$_} < 7 * 86400 }
              keys %{ $al->{unknown} || {} };
    if (@unk) {
        print '<h3>Alarms from unknown camera IDs</h3><p class="i2l-hint">Copy the ID (second topic level) into the camera\'s MQTT ID field. '
            . btn('clear_unknown', 'Clear list') . '</p><ul>';
        for my $t (sort { $al->{unknown}{$b} <=> $al->{unknown}{$a} } @unk) {
            print '<li><code>' . H($t) . '</code> - ' . Instar2Lox::fmt_time($al->{unknown}{$t}) . '</li>';
        }
        print '</ul>';
    }
}

sub page_settings {
    my $g  = $c->{global};
    my %ms = LoxBerry::System::get_miniservers();
    my @msopts = map { ($_ => ($ms{$_}{Name} // "Miniserver $_") . ' (' . ($ms{$_}{IPAddress} // '?') . ')') } sort { $a <=> $b } keys %ms;
    @msopts = (1 => 'Miniserver 1') unless @msopts;
    my $tv = join("\n", map { "$_=$g->{target_versions}{$_}" } sort keys %{ $g->{target_versions} || {} });
    my %models;
    for my $s (values %{ $st->{cams} || {} }) {
        my $m = $s->{info}{model} or next;
        $models{$m} = $s->{info}{softVersion} if !$models{$m} || Instar2Lox::vcmp($s->{info}{softVersion}, $models{$m}) > 0;
    }
    print qq{<form method="post" action="index.cgi" data-ajax="false"><input type="hidden" name="action" value="save_settings">};
    print '<h2>Common camera login</h2><table class="i2l-form">';
    print '<tr><td>User</td><td><input name="g_user" value="' . H($g->{user}) . '" data-role="none" autocomplete="off"></td><td>used for every camera without its own login</td></tr>';
    print '<tr><td>Password</td><td><input type="password" name="g_pass" value="" data-role="none" autocomplete="new-password"></td><td>' . (length $g->{pass} ? 'stored - leave empty to keep' : '<b>not set</b>') . '</td></tr></table>';
    print '<h2>Loxone</h2><table class="i2l-form">';
    print '<tr><td>Miniserver</td><td>' . sel('ms_no', $g->{ms_no}, @msopts) . '</td><td></td></tr>';
    print '<tr><td>UDP port</td><td><input name="udp_port" value="' . H($g->{udp_port}) . '" data-role="none" size="6"></td><td>port of the Virtual UDP Input</td></tr>';
    print '<tr><td>UDP prefix</td><td><input name="udp_prefix" value="' . H($g->{udp_prefix}) . '" data-role="none"></td><td></td></tr>';
    print '<tr><td>Resend all values</td><td>' . sel('resend_hours', $g->{resend_hours}, 0 => 'never (changes only)', 1 => 'every hour', 6 => 'every 6 hours', 24 => 'once a day') . '</td><td>refreshes Loxone after a Miniserver restart</td></tr></table>';
    print '<h2>Monitoring</h2><table class="i2l-form">';
    print '<tr><td>Poll interval</td><td>' . sel('check_interval_min', $g->{check_interval_min}, map { ($_ => "$_ min") } 1, 2, 5, 10, 15, 30, 60) . '</td><td></td></tr>';
    print '<tr><td>Offline after</td><td>' . sel('offline_threshold', $g->{offline_threshold}, map { ($_ => "$_ failed poll(s)") } 1 .. 5) . '</td><td></td></tr>';
    print '<tr><td>Grace after reboot</td><td>' . sel('reboot_grace_min', $g->{reboot_grace_min}, map { ($_ => "$_ min") } 3, 6, 10, 15) . '</td><td>no offline alert while the camera restarts</td></tr>';
    print '<tr><td>HTTP timeout</td><td>' . sel('http_timeout', $g->{http_timeout}, map { ($_ => "$_ s") } 3, 5, 10) . '</td><td></td></tr>';
    print '<tr><td>Target firmware</td><td><textarea name="target_versions" rows="3" cols="40" data-role="none">' . H($tv) . '</textarea></td><td>one line per model: <code>MODEL=VERSION</code>. Without a line the newest version found among your cameras of that model is the reference.';
    if (%models) { print '<br>Detected: ' . join(', ', map { '<code>' . H("$_=$models{$_}") . '</code>' } sort keys %models); }
    print '</td></tr></table>';
    print '<h2>Alarms (MQTT)</h2><table class="i2l-form">';
    print '<tr><td>Alarm listener</td><td>' . sel('alarm_enable', $g->{alarm_enable}, 1 => 'enabled', 0 => 'disabled') . '</td><td></td></tr>';
    print '<tr><td>Topic</td><td><input name="alarm_topic" value="' . H($g->{alarm_topic}) . '" data-role="none" size="40"></td><td>default <code>instar/+/status/alarm/triggered</code></td></tr>';
    print '<tr><td>Pulse length</td><td>' . sel('alarm_pulse_sec', $g->{alarm_pulse_sec}, map { ($_ => "$_ s") } 1, 2, 3, 5, 10) . '</td><td></td></tr>';
    print '<tr><td>Pause between alarms</td><td>' . sel('alarm_cooldown_sec', $g->{alarm_cooldown_sec}, 0 => 'none', 10 => '10 s', 30 => '30 s', 60 => '1 min', 120 => '2 min', 300 => '5 min', 600 => '10 min')
        . '</td><td>per camera: further alarms within this time are counted but not sent to Loxone (stops the tablet from ringing non-stop)</td></tr></table>';
    print '<button type="submit" class="i2l-btn" data-role="none">Save settings</button></form>';
}

sub page_loxone {
    my $pre = H($c->{global}{udp_prefix});
    print '<h2>Virtual UDP Input</h2>';
    print '<p>Create a <b>Virtual UDP Input</b> on port <b>' . H($c->{global}{udp_port}) . '</b> (sender address empty), or import the generated template:</p>';
    print '<p><a class="i2l-btn" href="index.cgi?action=download_viu" data-ajax="false">Download VIU template (XML)</a> ' . btn('udp_test', 'Send UDP test') . '</p>';
    print '<p class="i2l-hint">All values use 0 = fine, so the default after a Miniserver restart never raises a false alarm. Offline and outdated are sent only when they change.</p>';
    print '<table class="i2l-tab"><tr><th>Command recognition</th><th>Meaning</th></tr>';
    print "<tr><td><code>$pre.offline_count=\\v</code></td><td>number of offline cameras</td></tr>";
    print "<tr><td><code>$pre.outdated_count=\\v</code></td><td>number of cameras with outdated firmware</td></tr>";
    for my $cam (@{ $c->{cameras} }) {
        my $i = H($cam->{id}); my $n = H($cam->{name});
        print "<tr><td><code>$pre.$i.offline=\\v</code></td><td>$n: 1 = not reachable</td></tr>";
        print "<tr><td><code>$pre.$i.outdated=\\v</code></td><td>$n: 1 = firmware outdated</td></tr>";
        print "<tr><td><code>$pre.$i.alarm=\\v</code></td><td>$n: alarm pulse, value = trigger (1-4 zone, 5 PIR, 6 sound, 7-10 zone 1-4 + PIR)</td></tr>";
    }
    print '</table>';
    print '<h3>Kitchen tablet pop-up</h3><p>Connect <code>' . $pre . '.&lt;camera&gt;.alarm</code> through a comparator (&gt; 0) to the bell input of that camera\'s Intercom block. Night-only behaviour can stay in the camera alarm schedule or move into Loxone logic.</p>';
}

sub page_logs {
    for my $l (['worker', 'Worker (polls, reboots, UDP)'], ['alarmd', 'Alarm listener'], ['webui', 'Web UI']) {
        my $f = "$lbplogdir/$l->[0].log";
        my @lines;
        if (open(my $fh, '<', $f)) { @lines = <$fh>; close $fh; }
        @lines = @lines[-80 .. -1] if @lines > 80;
        print "<h3>$l->[1]</h3><pre class=\"i2l-log\">" . (@lines ? H(join('', @lines)) : '(empty)') . '</pre>';
    }
}

sub css {
    return <<'CSS';
<style>
.i2l-nav{margin-bottom:16px}
.i2l-nav a{display:inline-block;padding:7px 16px;margin-right:4px;background:#e8e8e8;border:1px solid #ccc;border-radius:4px 4px 0 0;text-decoration:none;color:#333;font-size:.9em}
.i2l-nav a.active{background:#fff;border-bottom-color:#fff;font-weight:bold;color:#000}
.i2l-msg{padding:8px 12px;margin:0 0 10px;border-radius:4px}
.i2l-msg.ok{background:#e6f4e6;border:1px solid #9c9}.i2l-msg.err{background:#fbe9e9;border:1px solid #d99}
.i2l-bar{margin-bottom:10px}
.i2l-btn{display:inline-block;padding:4px 12px;margin:0 4px 4px 0;font-size:.85em;background:#e8e8e8;border:1px solid #bbb;border-radius:3px;color:#222 !important;text-decoration:none;cursor:pointer;font-weight:normal}
.i2l-btn:hover{background:#d4d4d4}
.i2l-tab{border-collapse:collapse;width:100%;font-size:.86em}
.i2l-tab th,.i2l-tab td{border-bottom:1px solid #ddd;padding:6px 6px;text-align:left;vertical-align:top}
.i2l-tab th{background:#f2f2f2}
.i2l-tab td.act{white-space:nowrap}
.i2l-form td{padding:4px 8px;vertical-align:top;font-size:.9em}
.i2l-form td:first-child{font-weight:bold;white-space:nowrap}
.i2l-form input,.i2l-form select,.i2l-form textarea,.i2l-tab select{padding:3px;font-size:.95em}
.b{display:inline-block;padding:1px 7px;border-radius:9px;font-size:.85em;color:#fff}
.b.green{background:#3a8a3a}.b.red{background:#c03030}.b.amber{background:#c88a10}.b.grey{background:#999}
.i2l-hint{font-size:.85em;color:#666}
.i2l-log{font-size:.75em;background:#f4f4f4;border:1px solid #ddd;padding:8px;max-height:300px;overflow:auto;white-space:pre-wrap}
.i2l-groups{display:flex;flex-wrap:wrap;gap:8px 40px}.i2l-group h3{margin:10px 0 4px}
.i2l-camsel label{display:inline-block;min-width:260px;margin:0 12px 6px 0;white-space:nowrap}
.i2l-matrix td,.i2l-matrix th{white-space:nowrap}.i2l-grp td{background:#eef3e8;font-weight:bold}.i2l-diff td{background:#fff7e6}
.i2l-foot{font-size:.75em;color:#aaa;margin-top:24px}
</style>
CSS
}
