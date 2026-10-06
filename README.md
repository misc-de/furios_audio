# furios_audio

Lets PipeWire drive the audio hardware on the FuriPhone FLX1 directly, and
switches between that and the shipped setup at any time.

Out of the box, sound on this phone belongs to **PulseAudio**, which owns the
Android audio HAL; the PipeWire that ships alongside it is limited to camera
and screencast. That works, but it keeps the phone on a sound server the rest
of the desktop stack has moved away from.

This repository contains two things:

1. **`audioctl`** — switching between audio profiles, reversible at any time.
2. **`poc/spa-droid/`** — an SPA plugin that connects the Android audio HAL
   directly to PipeWire, so PulseAudio can be dropped entirely.

Playback, recording, phone calls and Bluetooth — music, calls and the headset
microphone — all work through it on the device.

## Install

    ./packaging/build-deb.sh
    sudo dpkg -i packaging/furios-audio-pipewire_*.deb

The package ships the plugin, the WirePlumber monitor and configuration,
`audioctl` and the systemd units. Remove it with
`sudo dpkg -r furios-audio-pipewire`.

The dependency on a specific PipeWire version is deliberate: the plugin is
built against one SPA interface, and an update that broke it would otherwise
take the sound with it silently.

From the work tree instead: `./install.sh` (asks for root where it needs it)
and `./uninstall.sh`, which also removes the package if one is installed and
puts back what `audioctl` changed in your own configuration - `dpkg -r` alone
cannot reach that.

### What an uninstall puts back

Every path this repository changes is written down once, before the first
change: absent, or the file, link or directory that was there, with its mode.
A second install or a later switch never replaces that record - the first
original counts. The uninstall puts back exactly that, and only where the
path is still what we made it; something you changed since is left alone and
named in the output. Nothing is restored from what a shipped phone is assumed
to look like.

| Record | Written by | What it covers |
|---|---|---|
| `/var/lib/furios-audio-original/` (root, 0700) | `install.sh`, `install-hal.sh`, `tools/build-plugin.sh` (and `tools/build-bluez5-aac.sh` before 6.10.2026; it now writes only under `~/.local/share/furios-audio`) | files and directories under `/usr/local`, `/usr/lib/…/spa-0.2`, `/etc/systemd` (units, drop-ins for ofono and WirePlumber, the echo unit's want), the masks in `/etc/systemd/user`, `/var/lib/furios-audio`, and the packages the plugin build installed |
| `~/.config/furios-audio/original/` | `audioctl` (first switch, `bt-extras`, `bt-codec`, `boot`) and `install.sh` before its first `systemctl --user enable` | masks and copies of five units, the pipewire drop-in, the droid-off file, the wants of our units and of WirePlumber under `~/.config/systemd/user`, and `~/.local/state/wireplumber` |
| `/run/furios-audio-dmnr/usip.original` | `furios-audio-dmnr on` | group and mode of `/dev/usip` before it was opened (the node is recreated at every boot, and so is this) |

The system record is root's on purpose: it decides what is written into
`/etc` and `/usr` on the way out, and `/var/lib/furios-audio` belongs to the
user. `audioctl original status` shows the user's record. A phone set up by a
version from before the record has none; the uninstall then removes our files
as it always did and says so. The packages are removed only if apt would take
nothing else along with them. The mechanism is `tools/original-state.sh`;
`tests/test-original-state.sh` and `tests/test-uninstall.sh` check it from
outside (snapshot, install, switch, uninstall, snapshot).

`audioctl revert` is not an uninstall: it switches to the `standard`
profile, which has to give working PulseAudio sound whatever the record says,
and so it keeps its own masks under `~/.config`.

## Usage

| Profile | What it means |
|---|---|
| `standard` | shipped state: PulseAudio owns the HAL |
| `pw-tunnel` | PipeWire gets a sink through PulseAudio, which stays the owner |
| `pw-hal` | PipeWire talks to the HAL directly |

    audioctl status              show the current state
    audioctl try <profile>       switch until the next reboot
    audioctl set <profile>       switch and remember it
    audioctl revert              back to standard immediately
    audioctl rescue              make sound audible again: shipped state,
                                 speaker, unmuted, 65 %
    audioctl bt-call watch       put a call on the Bluetooth headset and
                                 hold it there
    audioctl bt-mic on|off       record from the headset outside a call
    audioctl bt-codec [codec]    music codec for Bluetooth headsets: auto,
                                 sbc, sbc_xq, aac, aptx, aptx_hd or ldac
    audioctl original [status]   what was in your configuration before
                                 audioctl first changed it

Nothing here needs root.

`bt-codec` is a WirePlumber setting (`furios.bluetooth-codec`), held by
`droid-bluetooth-codec.lua` when a headset connects, after a call and at once
when it changes; `auto` leaves WirePlumber's own choice. Measured here while
music plays (bluebinder plus wireplumber): AAC 7.2 %, SBC-XQ 7.0 %, SBC 4.3 %
of a core - SBC saves 40 % and sounds audibly worse, SBC-XQ sounds like AAC.

The Bluetooth helpers - held SCO link, headset microphone, reconnect, pause on
disconnect - run under `pw-hal` only. Under `standard` the phone behaves
exactly as shipped: the units stay enabled but skip themselves
(`ExecCondition`, `audioctl is pw-hal`), and a switch stops or starts them.

There are two safety nets: `try` drops the profile at the next reboot, and if
no sink appears within 15 s of a switch, `audioctl` falls back to `standard` by
itself. Note that this checks whether a sink *exists*, not whether sound comes
out — **after switching, play something.**

## Building the plugin

The upstream sources are not versioned here:

    mkdir -p src && git clone https://github.com/FuriLabs/pulseaudio-modules-droid-modern \
        src/pulseaudio-modules-droid-modern

    meson setup poc/spa-droid/build poc/spa-droid
    ninja -C poc/spa-droid/build
    ./install-hal.sh        # needs sudo, does not change the active profile

Point `-Ddroid_src=` at an existing checkout to use one you already have.
Building the package instead is the way that survives a system update.

## Tests

    ./tests/run-tests.sh

Everything that can be decided at a desk: how a port is ranked, what the card
does with a volume, when the safety net fires. Whether sound actually comes out
is not something to assert — it has to be measured on the device.

## Licence

Our own code is MIT (see [LICENSE](LICENSE)). The built plugin compiles six
LGPL-2.1 source files from *pulseaudio-modules-droid-modern* into itself, so
**the plugin and the package are LGPL-2.1**. What this builds on, and under
which licence, is in [NOTICE](NOTICE).

Why it is built this way, and the measurements behind each decision, are in
[FINDINGS.md](FINDINGS.md).
