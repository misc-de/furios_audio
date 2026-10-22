#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""Pause playback when a Bluetooth audio device disconnects.

Earbuds run out of battery, or you put one back in its case, and without this
the audio simply moves to the next best output - which on a phone is the
loudspeaker, in whatever room you happen to be standing in.

So this pauses instead of rerouting. It watches BlueZ for an AUDIO device
losing its connection and asks every MPRIS player that is currently playing to
pause. That is the same thing Android does, and it leaves nothing behind: no
muted sink, no changed default, nothing to undo later. The next press of play
works normally.

"Audio device" is asked of BlueZ, not assumed: a watch, a keyboard or a car's
data link going out of range must not stop a podcast, and on a phone those drop
off far more often than earbuds run flat. Where the answer cannot be had, the
device counts as audio - see carries_audio().

A player without MPRIS cannot be paused this way. That is a real limit and not
worth papering over with a mute, which would be a trap of its own - a phone
that is silent for reasons nobody remembers is worse than one that was briefly
too loud.

One look at the moment of the signal is not enough, though, and that is not a
theory: on 2026-09-12 earbuds ran out of battery at 06:31:30 with a podcast
playing, this service reported "nothing was playing", and the podcast moved to
the loudspeaker and played on for 66 minutes until its owner woke up and
pressed the power key. Reproduced afterwards with the service stopped: the
player stays "Playing" throughout and simply follows the stream onto the
speaker. So the disconnect is not a moment to inspect but a few seconds to
watch - the player may report "Paused" for an instant while its sink is gone,
or be too slow to answer at all on a phone that has just woken up.

Pausing is half of a handover, though. On 2026-10-22 a podcast played on the
earbuds, they came out on the way to the car - and the earbuds paused it
themselves (in-ear detection sends an AVRCP pause before the link drops), so
this service saw "nothing was playing" and was right. The car connected 12 s
later with its audio link ready, and nothing pressed play: silence until its
owner did it by hand. So a pause that belongs to a disconnect - ours, or the
player's own within HANDOVER_LOOKBACK_S before it - is remembered, and if a
DIFFERENT audio device connects within HANDOVER_WINDOW_S and brings up an A2DP
transport, the player is told to play again. The same earbuds coming back do
not resume anything: that is somebody who took them out on purpose and may
put them back in for a call. Pressing play or pause yourself in between ends
the handover - the player is then doing what you told it.
"""

import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib  # noqa: E402

MPRIS_PREFIX = "org.mpris.MediaPlayer2."

# The Bluetooth profiles that actually carry sound: A2DP source and sink, the
# headset profiles, hands-free and its gateway. A device that has none of them
# cannot have been playing anything - a watch, a keyboard, a fitness tracker,
# a car's data link. Pausing a podcast because a smartwatch went out of range
# is its own kind of haunted phone, and it happens far more often than earbuds
# running out of battery.
AUDIO_UUID_PREFIXES = (
    "0000110a",   # AudioSource   (A2DP)
    "0000110b",   # AudioSink     (A2DP)
    "00001108",   # Headset
    "00001112",   # Headset AG
    "0000111e",   # Handsfree
    "0000111f",   # Handsfree AG
)

# When to look again after a device is gone, in milliseconds from the signal.
# The first look happens immediately; these are the ones that catch a player
# which was between states, or too slow to answer, when the first one asked.
# It ends well before a podcast could become a nuisance, and long before
# anyone would reconnect their earbuds and press play again on purpose.
RETRY_DELAYS_MS = (400, 900, 1800, 3000, 5000, 8000, 12000)

# A player that paused this long before an audio device dropped is taken to
# have paused BECAUSE of it: earbuds pause on leaving the ear, then take a few
# seconds more to be put in the case and drop the link. Longer than that and
# it was a pause of its own, which nothing should undo.
HANDOVER_LOOKBACK_S = 30
# How long after the disconnect another audio device may take over and have
# the playback resumed on it - the walk from the door to the car.
HANDOVER_WINDOW_S = 10 * 60
# After the new device's A2DP transport appears, give WirePlumber a moment to
# make it the output - playing before that would start on the loudspeaker.
RESUME_DELAY_MS = 2000
# A device that connects but brings up no A2DP within this long (a headset
# that only does calls, a car that only does the phone book) gets nothing.
TRANSPORT_WAIT_S = 30

TRANSPORT_IFACE = "org.bluez.MediaTransport1"


def carries_audio(system, path):
    """Is this BlueZ device one that could have been playing?

    Deliberately generous: it answers True whenever the question cannot be
    settled - the device is already gone from the bus, BlueZ does not answer,
    the property is not what it should be. Pausing something that was not on
    those earbuds costs a press of play; NOT pausing costs a podcast on the
    loudspeaker of a phone nobody is holding, which is the failure this whole
    service exists for. So doubt resolves towards pausing, every time.
    """
    try:
        uuids = system.call_sync(
            "org.bluez", path, "org.freedesktop.DBus.Properties", "Get",
            GLib.Variant("(ss)", ("org.bluez.Device1", "UUIDs")),
            GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 1000, None,
        ).unpack()[0]
    except GLib.Error as err:
        print("could not read what %s is: %s - treating it as audio"
              % (path.rsplit("/", 1)[-1], err), flush=True)
        return True
    if not isinstance(uuids, (list, tuple)) or not uuids:
        return True
    return any(str(u)[:8].lower() in AUDIO_UUID_PREFIXES for u in uuids)


def playing_players(session):
    """Names of MPRIS players that are playing right now."""
    try:
        names = session.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "ListNames", None,
            GLib.VariantType("(as)"), Gio.DBusCallFlags.NONE, 2000, None,
        ).unpack()[0]
    except GLib.Error as err:
        print("could not list bus names: %s" % err, flush=True)
        return []

    out = []
    for name in names:
        if not name.startswith(MPRIS_PREFIX):
            continue
        try:
            status = session.call_sync(
                name, "/org/mpris/MediaPlayer2",
                "org.freedesktop.DBus.Properties", "Get",
                GLib.Variant("(ss)", ("org.mpris.MediaPlayer2.Player",
                                      "PlaybackStatus")),
                GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 2000, None,
            ).unpack()[0]
        except GLib.Error as err:
            # NOT silent: a player that fails to answer within the timeout
            # looks exactly like one that is not playing, and that is how a
            # podcast once ran all morning on the loudspeaker. Say so, and
            # leave it to the retries to ask again.
            print("could not ask %s: %s" % (name[len(MPRIS_PREFIX):], err),
                  flush=True)
            continue
        if status == "Playing":
            out.append(name)
    return out


def owner_of(session, name):
    """The unique bus name behind a player's well-known one.

    PropertiesChanged arrives from the unique name, Pause goes to the
    well-known one - the handover needs both to mean the same player. Falls
    back to the name itself, which is still a valid address to call.
    """
    if name.startswith(":"):
        return name
    try:
        return session.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus",
            "org.freedesktop.DBus", "GetNameOwner", GLib.Variant("(s)", (name,)),
            GLib.VariantType("(s)"), Gio.DBusCallFlags.NONE, 2000, None,
        ).unpack()[0]
    except GLib.Error:
        return name


def pause_all(session, again=False):
    """Pause every player that is playing right now.

    `again` only changes what is printed: the retries would otherwise write
    "nothing was playing" eight times per disconnect, which would bury the one
    line that matters. Returns the players it paused.
    """
    players = playing_players(session)
    paused = []
    if not players:
        if not again:
            print("bluetooth gone, nothing was playing yet - still watching",
                  flush=True)
        return paused
    for name in players:
        try:
            session.call_sync(
                name, "/org/mpris/MediaPlayer2",
                "org.mpris.MediaPlayer2.Player", "Pause", None, None,
                Gio.DBusCallFlags.NONE, 2000, None,
            )
            print("bluetooth gone, paused %s%s" % (name[len(MPRIS_PREFIX):],
                  " (on a second look)" if again else ""), flush=True)
            paused.append(name)
        except GLib.Error as err:
            print("could not pause %s: %s" % (name, err), flush=True)
    return paused


class Handover:
    """Remembers who was paused by a disconnect, and plays them on the next device.

    Players are kept by their unique bus name, the one their signals carry.
    """

    def __init__(self, session, clock=time.monotonic):
        self.session = session
        self.clock = clock
        self.last_pause = {}   # unique name -> when it last reported Paused
        self.players = set()   # unique names waiting for the next device
        self.left = None       # path of the device that took them away
        self.since = None      # when it did
        self.waiting = None    # path of the device we are waiting on

    def player_status(self, sender, status):
        """A player reported a new PlaybackStatus."""
        if status == "Paused":
            self.last_pause[sender] = self.clock()
            return
        # Playing or Stopped: whatever happens now was somebody's own doing,
        # or the player's - resuming it later would undo that.
        self.last_pause.pop(sender, None)
        if sender in self.players:
            self.players.discard(sender)
            print("handover off for %s - it %s on its own"
                  % (sender, "plays" if status == "Playing" else "stopped"),
                  flush=True)

    def device_left(self, path, paused_by_us):
        """An audio device dropped. Who goes with the handover?"""
        now = self.clock()
        players = {owner_of(self.session, n) for n in paused_by_us}
        players |= {s for s, at in self.last_pause.items()
                    if now - at <= HANDOVER_LOOKBACK_S}
        if not players and self.left is not None and self.players:
            return   # a second device dropping keeps the first handover
        self.players, self.left, self.since = players, path, now
        self.waiting = None

    def add_paused(self, paused_by_us):
        """A retry paused something after all - it goes with the handover."""
        if self.left is not None:
            self.players |= {owner_of(self.session, n) for n in paused_by_us}

    def armed(self):
        return (bool(self.players) and self.since is not None
                and self.clock() - self.since <= HANDOVER_WINDOW_S)

    def device_came(self, path):
        """An audio device connected. True if we now wait for its A2DP."""
        if not self.armed():
            self.players.clear()
            return False
        if path == self.left:
            print("the same device is back - the handover is off", flush=True)
            self.players.clear()
            return False
        self.waiting = path
        return True

    def transport_up(self, path):
        """A MediaTransport appeared. True if it is the one we wait for."""
        if self.waiting is None or not path.startswith(self.waiting + "/"):
            return False
        return self.armed()

    def resume(self):
        """Play everything that is still paused from the handover."""
        players, self.players = self.players, set()
        self.waiting = None
        if self.since is None or self.clock() - self.since > HANDOVER_WINDOW_S:
            return []
        resumed = []
        for name in sorted(players):
            try:
                status = self.session.call_sync(
                    name, "/org/mpris/MediaPlayer2",
                    "org.freedesktop.DBus.Properties", "Get",
                    GLib.Variant("(ss)", ("org.mpris.MediaPlayer2.Player",
                                          "PlaybackStatus")),
                    GLib.VariantType("(v)"), Gio.DBusCallFlags.NONE, 2000, None,
                ).unpack()[0]
                if status != "Paused":
                    print("not resuming %s - it is %s now" % (name, status),
                          flush=True)
                    continue
                self.session.call_sync(
                    name, "/org/mpris/MediaPlayer2",
                    "org.mpris.MediaPlayer2.Player", "Play", None, None,
                    Gio.DBusCallFlags.NONE, 2000, None,
                )
                print("handed over: playing %s on the new device" % name,
                      flush=True)
                resumed.append(name)
            except GLib.Error as err:
                print("could not resume %s: %s" % (name, err), flush=True)
        return resumed


class Retry:
    """Keeps looking for a moment after a Bluetooth device disconnects.

    Every look pauses whatever plays right now. Pausing an already paused
    player is harmless, so repeating costs nothing - while missing the one
    instant the player was readable costs a morning.

    It gives up as soon as something connects again: that is somebody putting
    their earbuds back in, and pausing their music a few seconds later would
    be its own kind of haunted phone.
    """

    def __init__(self, session, handover=None):
        self.session = session
        self.handover = handover
        self.left = len(RETRY_DELAYS_MS)
        self.cancelled = False

    def cancel(self):
        self.cancelled = True

    def tick(self):
        """One more look. True while another one is still due."""
        if self.cancelled:
            return False
        paused = pause_all(self.session, again=True)
        if paused and self.handover is not None:
            self.handover.add_paused(paused)
        self.left -= 1
        return self.left > 0


def main():
    system = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    session = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    pending = []   # at most one Retry, in a list so the closure can replace it
    handover = Handover(session)

    def schedule(retry):
        for delay in RETRY_DELAYS_MS:
            GLib.timeout_add(delay, lambda r=retry: (r.tick(), False)[1])

    def on_props(_conn, _sender, path, _iface, _signal, params):
        iface, changed, _invalidated = params.unpack()
        if iface != "org.bluez.Device1":
            return
        connected = changed.get("Connected")
        if connected is False:
            name = path.rsplit("/", 1)[-1]
            if not carries_audio(system, path):
                print("device %s disconnected - carries no audio, "
                      "playback is left alone" % name, flush=True)
                return
            print("device %s disconnected" % name, flush=True)
            for old_retry in pending:
                old_retry.cancel()
            pending.clear()
            handover.device_left(path, pause_all(session))
            retry = Retry(session, handover)
            pending.append(retry)
            schedule(retry)
        elif connected is True:
            # Earbuds are back in. Whatever we were still watching for, stop -
            # pausing their music seconds after they pressed play would be
            # worse than the problem this service exists for.
            for old_retry in pending:
                old_retry.cancel()
            pending.clear()
            if handover.armed() and carries_audio(system, path):
                if handover.device_came(path):
                    print("device %s connected - waiting for its audio link "
                          "to hand playback over" % path.rsplit("/", 1)[-1],
                          flush=True)
                    if has_transport(system, path):
                        resume_soon()
                    else:
                        GLib.timeout_add(TRANSPORT_WAIT_S * 1000,
                                         lambda p=path: (give_up(p), False)[1])

    def has_transport(system_bus, path):
        try:
            objects = system_bus.call_sync(
                "org.bluez", "/", "org.freedesktop.DBus.ObjectManager",
                "GetManagedObjects", None, None, Gio.DBusCallFlags.NONE,
                2000, None,
            ).unpack()[0]
        except GLib.Error:
            return False
        return any(p.startswith(path + "/") and TRANSPORT_IFACE in ifaces
                   for p, ifaces in objects.items())

    def resume_soon():
        handover.waiting = None   # one resume per handover, however many links
        GLib.timeout_add(RESUME_DELAY_MS, lambda: (handover.resume(), False)[1])

    def give_up(path):
        if handover.waiting == path:
            print("%s brought no audio link - the handover is off"
                  % path.rsplit("/", 1)[-1], flush=True)
            handover.players.clear()
            handover.waiting = None

    def on_added(_conn, _sender, _path, _iface, _signal, params):
        path, ifaces = params.unpack()
        if TRANSPORT_IFACE in ifaces and handover.transport_up(path):
            resume_soon()

    def on_player(_conn, sender, _path, _iface, _signal, params):
        iface, changed, _invalidated = params.unpack()
        if iface == "org.mpris.MediaPlayer2.Player" and "PlaybackStatus" in changed:
            handover.player_status(sender, changed["PlaybackStatus"])

    system.signal_subscribe(
        "org.bluez", "org.freedesktop.DBus.Properties", "PropertiesChanged",
        None, None, Gio.DBusSignalFlags.NONE, on_props,
    )
    system.signal_subscribe(
        "org.bluez", "org.freedesktop.DBus.ObjectManager", "InterfacesAdded",
        "/", None, Gio.DBusSignalFlags.NONE, on_added,
    )
    session.signal_subscribe(
        None, "org.freedesktop.DBus.Properties", "PropertiesChanged",
        "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player",
        Gio.DBusSignalFlags.NONE, on_player,
    )
    print("watching BlueZ for disconnects", flush=True)
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
