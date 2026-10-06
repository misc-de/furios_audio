#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Builds the AAC codec module that Debian's libspa-0.2-bluetooth leaves out.
#
# Why this exists
# ---------------
# Most earbuds offer AAC and SBC and nothing else. Without an AAC module
# PipeWire falls back to SBC - and the headset decides how good that can get:
# the soundcore Liberty 4 Pro caps SBC at bitpool 39, so even SBC-XQ runs into
# a ceiling. AAC is what such devices are tuned for.
#
# Debian omits the module because it needs fdk-aac, whose licence Debian keeps
# at arm's length. Building it locally is a different matter.
#
# Where it goes, and why not beside Debian's codecs
# -------------------------------------------------
# It used to be installed with sudo into .../spa-0.2/bluez5/, beside the
# modules libspa-0.2-bluetooth ships. Two things were wrong with that. A path
# there can become dpkg's at any update (Debian may ship this very module one
# day), and "sudo install" over it would leave dpkg -V dirty. And the module
# speaks libspa-bluez5's internal codec interface: after a PipeWire update
# WirePlumber went on loading the old build, whose ABI nobody promised -
# audioctl could only print a note.
#
# Now it goes into the user's own ~/.local/share/furios-audio/spa-0.2/bluez5/,
# with the GNU build-id of the libspa-bluez5.so it was built for. No sudo, no
# dpkg-divert needed, because nothing under /usr is touched at all. Before
# every WirePlumber start furios-audio-bluez5-fix links it into the overlay
# directory WirePlumber searches first - only while that build-id is still the
# installed one. After a PipeWire update the module is simply not offered:
# Bluetooth music falls back to SBC, "audioctl status" says the module is
# stale, and running this script again brings AAC back.
set -e

# Root would build into /root and leave the phone's user without the module.
[ "$(id -u)" -ne 0 ] || { echo "run this as the phone's user, not as root - it needs no sudo" >&2; exit 1; }

PWVER=$(pkg-config --modversion libpipewire-0.3)
SPADIR=$(pkg-config --variable=libdir libpipewire-0.3)/spa-0.2/bluez5
DEST=${XDG_DATA_HOME:-$HOME/.local/share}/furios-audio/spa-0.2/bluez5
# NOT /tmp: whoever controls the source tree controls a file that every
# WirePlumber of this user then loads. A predictable path under /tmp lets
# anyone on the machine put one there first - this script would find it
# ("sources already in ...") and build it. The default lives in the user's own
# cache, and a path handed in through SRC is checked before it is trusted.
SRC=${SRC:-${XDG_CACHE_HOME:-$HOME/.cache}/furios-audio/pipewire-$PWVER-src}

# The helper that reads build-ids, next to this script in the repo or where
# either install put it.
FIX=
for f in "$(dirname "$0")/furios-audio-bluez5-fix.py" \
         /usr/local/bin/furios-audio-bluez5-fix /usr/bin/furios-audio-bluez5-fix; do
    [ -e "$f" ] && { FIX=$f; break; }
done
[ -n "$FIX" ] || { echo "furios-audio-bluez5-fix not found - install furios_audio first" >&2; exit 1; }
case "$FIX" in
*.py) BUILD_ID=$(python3 "$FIX" --build-id "$SPADIR/libspa-bluez5.so") ;;
*)    BUILD_ID=$("$FIX" --build-id "$SPADIR/libspa-bluez5.so") ;;
esac
[ -n "$BUILD_ID" ] || { echo "$SPADIR/libspa-bluez5.so has no build-id - refusing" >&2; exit 1; }

echo "PipeWire $PWVER (libspa-bluez5 $BUILD_ID), module goes to $DEST"

MISSING=
for p in libfdk-aac-dev libdbus-1-dev libsbc-dev; do
    dpkg -s "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done
for p in meson ninja git; do
    command -v "$p" >/dev/null 2>&1 || MISSING="$MISSING $p"
done
if [ -n "$MISSING" ]; then
    echo "missing build dependencies:$MISSING" >&2
    echo "  sudo apt install libfdk-aac-dev libdbus-1-dev libsbc-dev meson ninja-build git" >&2
    exit 1
fi

# A tree that is already there is only reused when it is ours and nobody else
# can write to it. Anything else is refused rather than built: the result of
# this build goes into a system directory.
check_tree() {
    [ -L "$1" ] && { echo "$1 is a symlink - refusing to build from it" >&2; exit 1; }
    owner=$(stat -c %u "$1" 2>/dev/null) || return 0
    [ "$owner" = "$(id -u)" ] || {
        echo "$1 belongs to uid $owner, not to you - refusing to build from it" >&2
        exit 1; }
    perms=$(stat -c %a "$1" 2>/dev/null)
    case "$perms" in
    *[2367])  echo "$1 is writable by others ($perms) - refusing" >&2; exit 1 ;;
    esac
}

if [ ! -d "$SRC" ]; then
    echo "1) fetching the matching sources"
    mkdir -p "$(dirname "$SRC")"
    git clone -q --depth 1 --branch "$PWVER" \
        https://gitlab.freedesktop.org/pipewire/pipewire.git "$SRC"
    check_tree "$SRC"
else
    check_tree "$SRC"
    echo "1) sources already in $SRC"
fi

echo "2) configuring - everything off except bluez5 and AAC"
rm -rf "$SRC/build-aac"
meson setup "$SRC/build-aac" "$SRC" \
    -Dbluez5=enabled -Dbluez5-codec-aac=enabled \
    -Dbluez5-codec-aptx=disabled -Dbluez5-codec-ldac=disabled \
    -Dbluez5-codec-lc3plus=disabled -Dbluez5-codec-opus=disabled \
    -Dbluez5-codec-lc3=disabled -Dbluez5-codec-g722=disabled \
    -Dalsa=disabled -Dpipewire-alsa=disabled -Dpipewire-jack=disabled -Djack=disabled \
    -Dv4l2=disabled -Dpipewire-v4l2=disabled -Dlibcamera=disabled -Dgstreamer=disabled \
    -Dlibsystemd=disabled -Dsystemd-system-service=disabled -Dsystemd-user-service=disabled \
    -Dtests=disabled -Dexamples=disabled -Dman=disabled -Ddocs=disabled -Dsdl2=disabled \
    -Dsndfile=disabled -Dpw-cat=disabled -Dvulkan=disabled -Dvolume=disabled \
    -Draop=disabled -Davahi=disabled -Decho-cancel-webrtc=disabled -Dlibpulse=disabled \
    -Dlibusb=disabled -Dudev=disabled -Dlibcanberra=disabled -Dcompress-offload=disabled \
    -Dx11=disabled -Dflatpak=disabled -Dreadline=disabled -Dgsettings=disabled \
    -Dlv2=disabled >/dev/null

echo "3) building the one module"
ninja -C "$SRC/build-aac" spa/plugins/bluez5/libspa-codec-bluez5-aac.so

echo "4) installing, for this user only"
mkdir -p "$DEST"
# Atomically: a WirePlumber starting now sees the old pair or the new one.
install -m644 "$SRC/build-aac/spa/plugins/bluez5/libspa-codec-bluez5-aac.so" \
    "$DEST/.libspa-codec-bluez5-aac.so.new"
printf 'bluez5-build-id=%s\npipewire=%s\n' "$BUILD_ID" "$PWVER" > "$DEST/.aac-built-for.new"
mv -f "$DEST/.libspa-codec-bluez5-aac.so.new" "$DEST/libspa-codec-bluez5-aac.so"
mv -f "$DEST/.aac-built-for.new" "$DEST/aac-built-for"

# The system copy an older version of this script installed would still be
# loaded, whatever PipeWire it was built for.
if [ -e "$SPADIR/libspa-codec-bluez5-aac.so" ] \
   && ! dpkg -S "$SPADIR/libspa-codec-bluez5-aac.so" >/dev/null 2>&1; then
    echo
    echo "An older build is still in $SPADIR - remove it once:"
    echo "   sudo audioctl migrate"
fi

echo
echo "Done. Restart the audio stack and reconnect the headset:"
echo "   audioctl restart"
echo "   bluetoothctl disconnect <mac> && bluetoothctl connect <mac>"
echo "The card then offers \"High Fidelity Playback (A2DP Sink, codec AAC)\"."
echo "After a PipeWire update it is left out until this is run again."
