# instar2lox - INSTAR Full HD cameras for LoxBerry / Loxone

LoxBerry plugin to monitor, manage and integrate INSTAR Full HD (1080p) IP cameras with a Loxone Miniserver.

> **Tested on INSTAR Full HD 9 series cameras** (IN-9008 Full HD, firmware V4.1.2.48, WebUI 3.3),
> running 10 cameras in parallel. Other INSTAR Full HD models use the same HTTP API and should work,
> but are not tested. 2K+ / 4K cameras are **not** supported.
>
> **Works with MQTT:** camera alarms are received through the LoxBerry MQTT broker
> (`instar/#`) and forwarded to Loxone as UDP pulses. The plugin configures the MQTT settings
> in all cameras for you. Requires the LoxBerry MQTT broker (MQTT Gateway).

## Features

- **Camera discovery** - scans the LoxBerry subnet and adds all INSTAR cameras that accept the common login.
- **Overview** - model, firmware / WebUI version, uptime, SD card state, reboot plan, last alarm.
- **Monitoring** - offline detection (with grace period after reboots) and firmware currency
  (per-model target version, or the newest version found among your own cameras).
- **Reboots** - manual (single / all) and scheduled per camera: daily, weekly or monthly.
- **Bulk settings** - change settings on many cameras at once without touching CGI commands:
  alarm schedule (e.g. night only), alarm actions, motion zones and sensitivity, PIR, sound detection,
  SD card recording / auto-delete / format, e-mail and FTP, INSTAR Cloud upload, IR / day-night mode,
  image, OSD, status LEDs, NTP, time zone, UPnP, P2P. A matrix shows the current values of all cameras
  and highlights differences.
- **MQTT alarms** - writes the LoxBerry broker settings into the cameras, listens on `instar/#`,
  maps each camera by MQTT ID, client ID or MAC, and forwards alarms to Loxone as UDP pulses
  with a per-camera cool-down. Shows broker connection state, client IDs and duplicate IDs.
- **Loxone** - generated Virtual UDP Input template. UDP is sent only on change; 0 always means OK.

## UDP commands (Virtual UDP Input, default port 7088)

| Command | Meaning |
|---|---|
| `instar2lox.<id>.offline` | 1 = camera not reachable |
| `instar2lox.<id>.outdated` | 1 = firmware outdated |
| `instar2lox.<id>.alarm` | alarm pulse, value = trigger (1-4 zone, 5 PIR, 6 sound, 7-10 zone + PIR) |
| `instar2lox.offline_count` | number of offline cameras |
| `instar2lox.outdated_count` | number of cameras with outdated firmware |

## Installation

1. Download the ZIP from the latest release.
2. LoxBerry -> Plugin Management -> Install.
3. Settings: enter the common camera login and choose the Miniserver.
4. Cameras: **Search network for cameras** -> **Add all**.
5. MQTT & Alarms: **Configure all cameras** (requires the LoxBerry MQTT broker).
6. Loxone: download the VIU template, import it in Loxone Config.

## Files

- Config: `$LBPCONFIG/instar2lox/instar2lox.json` (mode 600, contains camera passwords)
- State: `$LBPDATA/instar2lox/`
- Logs: `$LBPLOG/instar2lox/` (worker, alarmd, webui)

## Notes

- All commands follow the public INSTAR 1080p CGI documentation. The INSTAR Cloud alarm action is
  not documented for Full HD; the plugin probes for it read-only and only writes where the camera answers.
- INSTAR is a trademark of INSTAR Deutschland GmbH. This is an independent community plugin,
  not affiliated with or endorsed by INSTAR.

## License

MIT
