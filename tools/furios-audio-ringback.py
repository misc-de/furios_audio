#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""Play the ringback tone while an outgoing call rings at the other end.

Calls placed from this phone were silent until the other side picked up -
no "tuut ... tuut" at all. Nothing was broken in the audio path: the HAL is
in call mode 60 ms after dialing. The network simply sends no tone. On VoLTE
the modem says so itself - the radio log of a call on 2026-10-03 reads

    +ECPI: 1, 2, 0, 1, 0, 20, ...

message type 2 is "alerting", and the third field, is_ibt, is 0: no in-band
tone, the phone has to make its own. Android does. Here nobody did - neither
oFono nor gnome-calls look at it - although the tool for it is installed and
running: tonegend, the tone-generator service, plays CEPT call progress tones
on request.

So this asks it to. While a call is "alerting" (an outgoing call ringing at
the other end - oFono uses the state for nothing else) tonegend plays event
70, the RFC 4733 ringing tone; any other state stops it.

Two things measured on the phone shape the code:

- tonegend ignores the duration it is given and plays until told to stop.
  So every way out of "alerting" sends StopTone, including this service
  being stopped and oFono going away mid-ring.
- oFono does not pass on is_ibt. The modem's own report does reach the
  Android radio log, though, readable without root through logd's socket -
  so while a call is up this reads it, and a network that sends its own tone
  (early media: announcements, music instead of ringing) is left to play it.
  Only while a call is up: the radio log writes several lines a second, and
  a reader on it the rest of the time would wake the phone for each.
  Without the log (logd gone, the line format changed) it plays, as before.
"""

import re
import signal
import socket
import struct
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

# See furios-audio-sco-hold: the new spelling first, the old as fallback.
try:
    gi.require_version("GLibUnix", "2.0")
    from gi.repository import GLibUnix  # noqa: E402

    unix_signal_add = GLibUnix.signal_add
except (ValueError, ImportError):
    unix_signal_add = GLib.unix_signal_add

TONES_NAME = "com.Nokia.Telephony.Tones"
TONES_PATH = "/com/Nokia/Telephony/Tones"
# RFC 4733 event 70: ringing tone. With "-s cept" in tone-generator.service
# that is 425 Hz, one second on, four off - the European ringback.
RINGBACK_EVENT = 70
# Attenuation in dBm0, 0 being tonegend's own level. Heard at that level on
# the loudspeaker on 2026-10-04; in a call it goes to whatever plays the call.
RINGBACK_VOLUME = 0

# Android's logd, read the way logcat reads it. The radio buffer (id 1) holds
# what rild logs, among it every +ECPI the modem sends.
LOGDR = "/dev/socket/logdr"
RADIO_LOG = 1
# Lines from just before the call started still count: the first +ECPI can be
# logged before oFono's CallAdded reaches us.
LOG_LOOKBACK_S = 5
# +ECPI: <call id>, <message type>, <is_ibt>, ... Message types that carry a
# meaningful is_ibt: 2 alerting, 4 sync, 5 progress.
ECPI = re.compile(rb"\+ECPI:\s*(\d+),\s*(\d+),\s*(\d+)")
ECPI_WITH_TONE_INFO = (2, 4, 5)
# How long "alerting" waits for the modem's word on the tone before playing.
# Both arrive from the same modem report, by two roads, in either order.
SETTLE_MS = 300


def log(msg):
    print(msg, flush=True)


class Tones:
    """tonegend over the session bus."""

    def __init__(self, session):
        self.session = session

    def _call(self, method, args):
        try:
            self.session.call_sync(TONES_NAME, TONES_PATH, TONES_NAME, method,
                                   args, None, Gio.DBusCallFlags.NONE, 2000,
                                   None)
            return True
        except GLib.Error as err:
            log("tonegend %s: %s" % (method, err))
            return False

    def start(self):
        # The duration (last argument) is ignored by tonegend; 0 says so.
        return self._call("StartEventTone", GLib.Variant(
            "(uiu)", (RINGBACK_EVENT, RINGBACK_VOLUME, 0)))

    def stop(self):
        return self._call("StopTone", None)


def parse_ecpi(payload):
    """(call id, message type, is_ibt) from one log entry's text, or None."""
    m = ECPI.search(payload)
    return tuple(int(g) for g in m.groups()) if m else None


class Ringback:
    """Which calls are in which state, and whether the tone should play."""

    def __init__(self, tones, later=None):
        self.tones = tones
        self.states = {}
        self.playing = False
        # The network's own tone, as the modem reported it: None = unknown.
        self.network_tone = None
        # later(ms, fn): run fn after ms. Tests run it at once.
        self.later = later or (lambda _ms, fn: fn())
        self.pending = False

    def update(self, path, state):
        was = "alerting" in self.states.values()
        if state is None:
            self.states.pop(path, None)
        else:
            self.states[path] = state
        if not self.states:
            self.network_tone = None
        if not was and "alerting" in self.states.values():
            self._settle()
        else:
            self._apply()

    def reset(self, states):
        self.states = dict(states)
        if not self.states:
            self.network_tone = None
        self._apply()

    def ecpi(self, _call_id, msg_type, is_ibt):
        if msg_type in ECPI_WITH_TONE_INFO:
            self.network_tone = bool(is_ibt)
            log("the network sends %s" % ("its own ringback tone" if is_ibt
                                          else "no ringback tone"))
            self._apply()

    def _settle(self):
        if self.pending:
            return
        self.pending = True

        def go():
            self.pending = False
            self._apply()
            return False
        self.later(SETTLE_MS, go)

    def _apply(self):
        if self.pending:
            return
        want = ("alerting" in self.states.values()
                and self.network_tone is not True)
        if want and not self.playing:
            if self.tones.start():
                self.playing = True
                log("ringing at the other end - ringback on")
        elif not want and self.playing:
            # Stop even if it fails: a tonegend that is gone plays nothing.
            self.tones.stop()
            self.playing = False
            log("ringback off")

    def quiet(self):
        """Stop the tone whatever the calls say - on the way out."""
        if self.playing:
            self.tones.stop()
            self.playing = False


class RadioLog:
    """The radio log, read while a call is up."""

    def __init__(self, on_line):
        self.on_line = on_line
        self.sock = None
        self.watch = 0

    def open(self):
        if self.sock:
            return
        try:
            sock = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
            sock.connect(LOGDR)
            start = time.time() - LOG_LOOKBACK_S
            sock.send(b"stream lids=%d start=%d.%09d"
                      % (RADIO_LOG, int(start), int(start % 1 * 1e9)))
            sock.setblocking(False)
        except OSError as err:
            log("radio log not readable - ringback without the modem's word: %s"
                % err)
            return
        self.sock = sock
        self.watch = GLib.io_add_watch(sock.fileno(), GLib.PRIORITY_DEFAULT,
                                       GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR,
                                       self._readable)

    def close(self):
        if self.watch:
            GLib.source_remove(self.watch)
            self.watch = 0
        if self.sock:
            self.sock.close()
            self.sock = None

    def _readable(self, _fd, cond):
        if cond & (GLib.IO_HUP | GLib.IO_ERR):
            self.watch = 0
            self.close()
            return False
        while True:
            try:
                entry = self.sock.recv(5 * 1024 + 64)
            except BlockingIOError:
                return True
            except OSError:
                self.watch = 0
                self.close()
                return False
            if not entry:
                self.watch = 0
                self.close()
                return False
            if len(entry) < 20:
                continue
            header = struct.unpack("<H", entry[2:4])[0]
            found = parse_ecpi(entry[header:])
            if found:
                self.on_line(*found)


def existing_calls(system):
    """{path: state} of the calls already up - a restart mid-call."""
    found = {}
    try:
        modems = system.call_sync(
            "org.ofono", "/", "org.ofono.Manager", "GetModems", None,
            GLib.VariantType("(a(oa{sv}))"), Gio.DBusCallFlags.NONE, 5000, None,
        ).unpack()[0]
    except GLib.Error as err:
        log("could not ask ofono for modems: %s" % err)
        return found
    for path, _props in modems:
        try:
            calls = system.call_sync(
                "org.ofono", path, "org.ofono.VoiceCallManager", "GetCalls",
                None, GLib.VariantType("(a(oa{sv}))"),
                Gio.DBusCallFlags.NONE, 5000, None,
            ).unpack()[0]
        except GLib.Error:
            continue
        for call_path, props in calls:
            found[call_path] = str(props.get("State", ""))
    return found


def main():
    system = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    session = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    ring = Ringback(Tones(session), later=GLib.timeout_add)
    radio = RadioLog(ring.ecpi)

    def follow_calls():
        # The radio log only while there is a call to read it for.
        if ring.states:
            radio.open()
        else:
            radio.close()

    def on_added(_conn, _sender, _path, _iface, _signal, params):
        path, props = params.unpack()
        ring.update(path, str(props.get("State", "")))
        follow_calls()

    def on_removed(_conn, _sender, _path, _iface, _signal, params):
        ring.update(params.unpack()[0], None)
        follow_calls()

    def on_property(_conn, _sender, path, _iface, _signal, params):
        name, value = params.unpack()
        if name == "State":
            ring.update(path, str(value))

    # Subscribed before asking what is up - see furios-audio-sco-hold.
    system.signal_subscribe("org.ofono", "org.ofono.VoiceCallManager",
                            "CallAdded", None, None, Gio.DBusSignalFlags.NONE,
                            on_added)
    system.signal_subscribe("org.ofono", "org.ofono.VoiceCallManager",
                            "CallRemoved", None, None,
                            Gio.DBusSignalFlags.NONE, on_removed)
    system.signal_subscribe("org.ofono", "org.ofono.VoiceCall",
                            "PropertyChanged", None, None,
                            Gio.DBusSignalFlags.NONE, on_property)

    def ofono_appeared(_conn, _name, _owner):
        ring.reset(existing_calls(system))
        follow_calls()
        log("watching ofono for outgoing calls")

    def ofono_vanished(_conn, _name):
        # No state change is coming for a call that was ringing.
        ring.reset({})
        follow_calls()

    Gio.bus_watch_name_on_connection(
        system, "org.ofono", Gio.BusNameWatcherFlags.NONE,
        ofono_appeared, ofono_vanished)

    loop = GLib.MainLoop()

    def bye(*_):
        ring.quiet()
        radio.close()
        loop.quit()
        return GLib.SOURCE_REMOVE

    unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGTERM, bye)
    unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGINT, bye)

    loop.run()


if __name__ == "__main__":
    main()
