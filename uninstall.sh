#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Removes everything and restores the shipped state.
#
# Everything means more than what install.sh copies. It is also what audioctl
# and the helpers write while they run - masks, copies of units, wants and a
# drop-in under ~/.config, WirePlumber's memory under ~/.local/state, the
# headsets seen under ~/.config/furios-audio - and what older versions and the
# old .deb left in places this version no longer uses. A later install has to
# find the phone as a new one would: a remembered route or a stale want is
# enough to make it behave differently, and nobody would look here for why.
# tests/test-uninstall.sh installs, switches and uninstalls in a sandbox and
# checks that nothing is left.
#
# "The phone as a new one would be" is not assumed any more, it is read: the
# install scripts and audioctl record every path before they first write it
# (tools/original-state.sh), and what is put back here is that record - for a
# path that is still what we made it. Something changed since is left alone
# and named. Only where there is no record, because an older version set the
# phone up, does this fall back to the old removal, and it says so.
set -e

# Not with sudo, for the same reason as install.sh: "systemctl --user" and
# everything under $HOME would reach root's session and root's home, and leave
# this user's untouched.
if [ "$(id -u)" = 0 ]; then
    echo "Please run this WITHOUT sudo - it asks for root where it needs it." >&2
    echo "  ./uninstall.sh" >&2
    exit 1
fi

# Whichever install is there. The package puts the tools under /usr/bin, and
# a revert that only looked in /usr/local did nothing on a package install -
# the phone then lost pw-hal's files while still being switched to it.
first_x() { local f; for f in "$@"; do [ -x "$f" ] && { printf '%s' "$f"; return 0; }; done; return 1; }
AUDIOCTL=$(first_x /usr/local/bin/audioctl /usr/bin/audioctl) || AUDIOCTL=
DMNR=$(first_x /usr/local/bin/furios-audio-dmnr /usr/bin/furios-audio-dmnr) || DMNR=
TRIPLET=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo aarch64-linux-gnu)
USERCFG=${XDG_CONFIG_HOME:-$HOME/.config}
USERUNITS=$USERCFG/systemd/user
HERE=$(cd "$(dirname "$0")" && pwd)

# The system record: root's, so it is read with sudo. Not created here.
# shellcheck source=tools/original-state.sh
. "$HERE/tools/original-state.sh"
ORIG_DIR=/var/lib/furios-audio-original
ORIG_SU=sudo
SYSREC=0
sudo test -d "$ORIG_DIR/meta" && SYSREC=1
[ "$SYSREC" = 1 ] || echo "No record of the system files as they were before furios_audio (installed by an older version) - removing them as before."
UNRECORDED=0

# The files below are removed by name only where there is no record of them;
# with a record, orig_restore_all further down has already put back what was
# there. Directories the same way: removed if empty, unless the record says
# they were there before us.
remove_ours() {
    local p
    for p in "$@"; do
        [ "$SYSREC" = 1 ] && orig_has_record "$p" && continue
        [ -e "$p" ] || [ -L "$p" ] || continue
        sudo rm -rf "$p"
        UNRECORDED=$((UNRECORDED + 1))
    done
}
rmdir_ours() {
    local d
    for d in "$@"; do
        [ "$SYSREC" = 1 ] && orig_has_record "$d" && { orig_restore "$d" || true; continue; }
        sudo rmdir "$d" 2>/dev/null || true
    done
}

# No record is taken on the way out - see record_originals in audioctl. Not
# only for the revert just below: "furios-audio-dmnr set off" further down
# restarts the stack through audioctl as well, and that once wrote a fresh
# record of our own state a moment before it was read back.
export AUDIOCTL_NO_RECORD=1

# Back to the shipped stack first, while audioctl is still there to do it.
[ -n "$AUDIOCTL" ] && "$AUDIOCTL" revert 2>/dev/null || true
# furios-audio-bt-pulse is gone since f81015c; an install from before that
# still has it enabled.
systemctl --user disable --now furios-audio-apply.service furios-audio-verify.service \
    furios-pw-tunnel.service furios-audio-pause-on-disconnect.service \
    furios-audio-callaudio-refresh.service furios-audio-sco-hold.service \
    furios-audio-bt-mic.service furios-audio-bt-reconnect.service \
    furios-audio-ringback.service furios-audio-bt-pulse.service \
    2>/dev/null || true
# The echo suppression first, and in this order: take the mount down and drop
# the marker while the tool is still there to do it. Removing the binary first
# would leave a marker nothing reads and a mount nothing undoes.
sudo systemctl disable --now furios-audio-dmnr.service >/dev/null 2>&1 || true
[ -n "$DMNR" ] && "$DMNR" set off >/dev/null 2>&1 || true
remove_ours /etc/systemd/system/furios-audio-dmnr.service \
            /etc/systemd/system/multi-user.target.wants/furios-audio-dmnr.service
# Written by "furios-audio-dmnr set on", a name nobody else uses, and removed
# by "set off" just above - this only catches a tool that is gone already.
sudo rm -f "${DMNR_MARKER:-/etc/furios-audio-dmnr.persistent}"
sudo rm -rf /run/furios-audio-dmnr

# The old package, if dpkg still knows it - also as "config-files" only.
# After the revert and the disable above: both still needed its audioctl and
# its units.
if dpkg-query -W -f='${Status}' furios-audio-pipewire 2>/dev/null \
        | grep -qE ' (installed|config-files)$'; then
    sudo dpkg --purge furios-audio-pipewire
fi

# --- the record: the user's files, then the system's -----------------------
#
# Before the system side: audioctl is still installed, and the revert above
# has just left standard's masks in place. The copy of audioctl in this work
# tree does it, not the installed one - it is this version that knows the
# record, whatever version is installed.
USERREC=0
rc=0
"$HERE/audioctl" original restore || rc=$?
case "$rc" in
0) USERREC=1 ;;
3) echo "No record of your own files as they were before audioctl (set up by an older version) - removing what it wrote, as before." ;;
*) USERREC=1; echo "Some of your own files were left alone - see above." ;;
esac

# Everything the record knows: files first, then the directories we made,
# deepest first. Paths that are still ours are put back exactly as recorded -
# absent, the file that was there, the link that was there.
if [ "$SYSREC" = 1 ]; then
    # Our state directory holds files audioctl writes at runtime and nobody
    # recorded (profile.try, fell-back, bt-extras). It is ours by name and
    # was recorded as such - it goes whole, before the record is walked.
    [ "$(orig_recorded /var/lib/furios-audio)" = container ] || sudo rm -rf /var/lib/furios-audio
    orig_restore_all || echo "Some system files were left alone - see above."
fi

remove_ours /usr/local/bin/audioctl \
           /usr/local/bin/furios-audio-dmnr \
           /usr/local/bin/furios-audio-pause-on-disconnect \
           /usr/local/bin/furios-audio-callaudio-refresh \
           /usr/local/bin/furios-audio-sco-hold \
           /usr/local/bin/furios-audio-ringback \
           /usr/local/bin/furios-audio-bt-mic \
           /usr/local/bin/furios-audio-bt-reconnect \
           /usr/local/bin/furios-audio-bluez5-fix \
           /usr/local/libexec/furios-audio-helper \
           /etc/systemd/user/wireplumber.service.d/furios-bluez5-fix.conf \
           /etc/systemd/user/furios-pw-tunnel.service \
           /etc/systemd/user/furios-audio-apply.service \
           /etc/systemd/user/furios-audio-verify.service \
           /etc/systemd/user/furios-audio-pause-on-disconnect.service \
           /etc/systemd/user/furios-audio-callaudio-refresh.service \
           /etc/systemd/user/furios-audio-sco-hold.service \
           /etc/systemd/user/furios-audio-ringback.service \
           /etc/systemd/user/furios-audio-bt-mic.service \
           /etc/systemd/user/furios-audio-bt-reconnect.service \
           /etc/systemd/user/furios-audio-bt-pulse.service \
           /etc/systemd/user/pipewire.service.d/50-furios-audio.conf

# What a .deb of ours ever put under /usr, for as long as no package owns it
# any more. An early one (13.9.2026) was removed from dpkg while two of its
# files stayed - found on 30.9.2026 in a clean-install test - and the helper,
# the polkit policy, bt-pulse and the takes-over script belong to versions
# that are gone from this repo altogether. Asking dpkg first keeps this from
# ever taking a file that another package now ships under the same name.
remove_unowned() {
    local p
    for p in "$@"; do
        [ -e "$p" ] || [ -L "$p" ] || continue
        if dpkg -S "$p" >/dev/null 2>&1; then
            echo "left in place - a package owns it: $p"
            continue
        fi
        sudo rm -rf "$p"
    done
}
remove_unowned \
    /usr/bin/audioctl \
    /usr/bin/furios-audio-dmnr \
    /usr/bin/furios-audio-pause-on-disconnect \
    /usr/bin/furios-audio-callaudio-refresh \
    /usr/bin/furios-audio-sco-hold \
    /usr/bin/furios-audio-ringback \
    /usr/bin/furios-audio-bt-mic \
    /usr/bin/furios-audio-bt-reconnect \
    /usr/bin/furios-audio-bluez5-fix \
    /usr/bin/furios-audio-switch \
    /usr/bin/misc-de \
    /usr/libexec/furios-audio-helper \
    /usr/share/polkit-1/actions/de.furios.audioctl.policy \
    /usr/lib/systemd/user/furios-pw-tunnel.service \
    /usr/lib/systemd/user/furios-audio-apply.service \
    /usr/lib/systemd/user/furios-audio-verify.service \
    /usr/lib/systemd/user/furios-audio-pause-on-disconnect.service \
    /usr/lib/systemd/user/furios-audio-callaudio-refresh.service \
    /usr/lib/systemd/user/furios-audio-sco-hold.service \
    /usr/lib/systemd/user/furios-audio-ringback.service \
    /usr/lib/systemd/user/furios-audio-bt-mic.service \
    /usr/lib/systemd/user/furios-audio-bt-reconnect.service \
    /usr/lib/systemd/user/furios-audio-bt-pulse.service \
    /usr/lib/systemd/user/wireplumber.service.d/furios-bluez5-fix.conf \
    /usr/lib/systemd/system/furios-audio-dmnr.service \
    /usr/lib/systemd/system/ofono.service.d/30-furios-audio-hfp.conf \
    /usr/share/furios-audio \
    /usr/share/doc/furios-audio-pipewire \
    /usr/share/wireplumber/scripts/monitors/droid.lua \
    /usr/share/wireplumber/scripts/monitors/droid-input-follows-output.lua \
    /usr/share/wireplumber/scripts/monitors/droid-default-sink-policy.lua \
    /usr/share/wireplumber/scripts/monitors/droid-bluetooth-call.lua \
    /usr/share/wireplumber/scripts/monitors/droid-bluetooth-codec.lua \
    /usr/share/wireplumber/scripts/monitors/droid-bluetooth-takes-over.lua \
    /usr/share/wireplumber/wireplumber.conf.d/50-droid.conf \
    /usr/share/wireplumber/wireplumber.conf.d/50-droid.conf.off \
    /usr/share/wireplumber/wireplumber.conf.d/50-droid.conf.aus \
    /usr/share/wireplumber/wireplumber.conf.d/51-bluez-ofono.conf \
    /usr/share/applications/de.furios.audioswitch.desktop \
    /usr/share/applications/de.misc-de.tools.desktop \
    /usr/share/icons/hicolor/scalable/apps/de.furios.audioswitch.svg \
    /usr/share/icons/hicolor/scalable/apps/de.misc-de.tools.svg
sudo rmdir /usr/lib/systemd/user/wireplumber.service.d 2>/dev/null || true
sudo rmdir /usr/lib/systemd/system/ofono.service.d 2>/dev/null || true

# The AAC codec module an older tools/build-bluez5-aac.sh built into
# PipeWire's own plugin directory (it now goes under the user's
# ~/.local/share, removed further down), and the sources it fetched - now in
# the user's cache, before that under a fixed name in /tmp.
# With a record (that older script took one) it was put back above.
for f in "/usr/lib/$TRIPLET/spa-0.2/bluez5/libspa-codec-bluez5-aac.so" \
         "/usr/lib/$TRIPLET/spa-0.2/bluez5/aac-built-against"; do
    [ "$SYSREC" = 1 ] && orig_has_record "$f" && continue
    remove_unowned "$f"
done
rm -rf "${XDG_CACHE_HOME:-$HOME/.cache}/furios-audio"
find /tmp -maxdepth 1 -name 'pipewire-*-src' -user "$(id -u)" \
    -exec rm -rf {} + 2>/dev/null || true

# Ours by name, and what is still in them after the record was walked is
# ours too (the plugin's version note from an older install, say).
remove_ours /usr/local/share/furios-audio /var/lib/furios-audio "/usr/lib/$TRIPLET/spa-0.2/droid"
# Only an older, root-based audioctl wrote here.
sudo rmdir /etc/systemd/user/pipewire.service.d 2>/dev/null || true
rmdir_ours /etc/systemd/user/wireplumber.service.d
# switcher app
# Both names: the app was called furios-audio-switch until it grew a second
# page, and an uninstall that only knows the new name leaves the old launcher
# in the app grid pointing at a program that is gone.
sudo rm -f /usr/local/bin/furios-audio-switch \
           /usr/local/share/applications/de.furios.audioswitch.desktop \
           /usr/local/share/icons/hicolor/scalable/apps/de.furios.audioswitch.svg
# misc-de under the same paths is furios_app's since 14.9.2026, and that
# installer also puts its modules under /usr/local/lib/misc-de. Where those
# are, the app is not ours to take: removing its launcher and program would
# leave the other repo's install half there. Without them it is the copy this
# repo's gui/install.sh once put in place.
if [ ! -d /usr/local/lib/misc-de ]; then
    sudo rm -f /usr/local/bin/misc-de \
               /usr/local/share/applications/de.misc-de.tools.desktop \
               /usr/local/share/icons/hicolor/scalable/apps/de.misc-de.tools.svg
fi

# WirePlumber monitor and Bluetooth configuration
remove_ours /usr/local/share/wireplumber/scripts/monitors/droid.lua \
           /usr/local/share/wireplumber/scripts/monitors/droid-input-follows-output.lua \
           /usr/local/share/wireplumber/scripts/monitors/droid-default-sink-policy.lua \
           /usr/local/share/wireplumber/scripts/monitors/droid-bluetooth-call.lua \
           /usr/local/share/wireplumber/scripts/monitors/droid-bluetooth-codec.lua \
           /usr/local/share/wireplumber/scripts/monitors/droid-bluetooth-takes-over.lua \
           /usr/local/share/wireplumber/wireplumber.conf.d/50-droid.conf \
           /usr/local/share/wireplumber/wireplumber.conf.d/50-droid.conf.off \
           /usr/local/share/wireplumber/wireplumber.conf.d/50-droid.conf.aus \
           /usr/local/share/wireplumber/wireplumber.conf.d/51-bluez-ofono.conf
remove_ours /etc/systemd/system/ofono.service.d/30-furios-audio-hfp.conf
rmdir_ours /etc/systemd/system/ofono.service.d \
    /usr/local/share/wireplumber/scripts/monitors \
    /usr/local/share/wireplumber/scripts \
    /usr/local/share/wireplumber/wireplumber.conf.d \
    /usr/local/share/wireplumber
sudo systemctl daemon-reload 2>/dev/null || true

# --- the user's own files, where there is no record ------------------------
#
# The way this worked before the record, and still does for a phone that an
# older version set up. The revert above leaves standard's masks under
# ~/.config (that is what standard IS) and every "enable" left a want there.
# Only our own kind is taken: a mask is a link to /dev/null for one of the
# five units audioctl may mask, a copy carries audioctl's marker in its first
# line.
if [ "$USERREC" = 0 ]; then
    for u in pipewire-pulse.service pipewire-pulse.socket wireplumber.service \
             pulseaudio.service pulseaudio.socket; do
        f=$USERUNITS/$u
        if [ -L "$f" ] && [ "$(readlink "$f")" = /dev/null ]; then
            rm -f "$f"
        elif [ -f "$f" ] && head -n1 "$f" 2>/dev/null | grep -q '^# furios-audio: copy of '; then
            rm -f "$f"
        fi
    done
    rm -f "$USERUNITS/pipewire.service.d/50-furios-audio.conf"
    # Wants, also dangling ones: "disable" above finds nothing to undo once the
    # unit file is gone - a second run of this script, or a unit renamed. And
    # WirePlumber's own want and alias, which audioctl enables under pw-hal and
    # pw-tunnel: FuriOS masks WirePlumber, so on a phone as shipped nobody else
    # enables it.
    #
    # Our units by name, not "furios-*": furios_gps and the battery plugin
    # put their own wants in the same directories, and the old glob took
    # theirs as well.
    for f in "$USERUNITS"/*.wants/furios-audio-*.service \
             "$USERUNITS"/*.wants/furios-pw-tunnel.service \
             "$USERUNITS"/*.wants/wireplumber.service \
             "$USERUNITS/pipewire-session-manager.service"; do
        [ -L "$f" ] && rm -f "$f"
    done
    for d in "$USERUNITS"/*.wants "$USERUNITS/pipewire.service.d" "$USERUNITS" "$USERCFG/systemd"; do
        [ -d "$d" ] && rmdir "$d" 2>/dev/null || true
    done
    # The droid monitor switched off for pw-tunnel.
    rm -f "$USERCFG/wireplumber/wireplumber.conf.d/99-furios-droid-off.conf"
    rmdir "$USERCFG/wireplumber/wireplumber.conf.d" "$USERCFG/wireplumber" 2>/dev/null || true
    # WirePlumber's memory: our furios.* settings ("wpctl settings --save"), and
    # default nodes, routes and volumes from a stack that only ran because of us -
    # FuriOS ships WirePlumber masked. Left in place, a later install would start
    # with the routes and volumes of this one.
    rm -rf "${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber"
fi
# The headsets and codecs audioctl has seen, and the record itself - both
# ours by name, and the record has done its work.
rm -rf "$USERCFG/furios-audio"
# The AAC module tools/build-bluez5-aac.sh builds for this user, and its note.
# Only our subdirectory: ~/.local/share/furios-audio is ours by name, but
# nothing says another tool of ours will never put something beside it.
USERDATA=${XDG_DATA_HOME:-$HOME/.local/share}
rm -rf "$USERDATA/furios-audio/spa-0.2"
rmdir "$USERDATA/furios-audio" 2>/dev/null || true
# Gone at logout anyway, but a reinstall in the same session would find them:
# the patched Bluetooth plugin, the SCO hold's pid, bt-pulse's marker.
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    rm -rf "$XDG_RUNTIME_DIR/furios-audio" \
           "$XDG_RUNTIME_DIR/furios-audio-sco-hold.pid" \
           "$XDG_RUNTIME_DIR/furios-audio-bt-pulse-tried"
fi

# --- the masks in /etc/systemd/user -----------------------------------------
#
# Nothing of this version writes them. The first three are furios-quirks-
# device's, and an older, root-based audioctl deleted them; the other two
# only that older audioctl ever made. This used to recreate the first three
# and delete the other two without looking - right on the phone it was
# written on, a guess on any other.
if [ "$SYSREC" = 1 ] && orig_has_record /etc/systemd/user/wireplumber.service; then
    # Put back above if they were ours; otherwise they are as the user or a
    # package left them. Only say what is missing, and whose it is.
    for u in pipewire-pulse.service pipewire-pulse.socket wireplumber.service; do
        f=/etc/systemd/user/$u
        if [ ! -e "$f" ] && [ ! -L "$f" ] && pkg=$(dpkg -S "$f" 2>/dev/null); then
            echo "  missing, and ${pkg%%:*} ships it - reinstall that package to get it back: $f"
        fi
    done
else
    echo "No record of the masks in /etc/systemd/user (installed by an older version) - putting back what a package ships, removing what only an older audioctl made."
    for u in pipewire-pulse.service pipewire-pulse.socket wireplumber.service; do
        f=/etc/systemd/user/$u
        [ -e "$f" ] || [ -L "$f" ] && continue
        # What the package ships, not what we believe it ships.
        if dpkg -S "$f" >/dev/null 2>&1; then
            sudo ln -sf /dev/null "$f"
        else
            echo "  not recreated - no package ships it: $f"
        fi
    done
    for u in pulseaudio.service pulseaudio.socket; do
      [ "$(readlink "/etc/systemd/user/$u" 2>/dev/null)" = /dev/null ] && sudo rm -f "/etc/systemd/user/$u"
    done
fi

# The packages the plugin build installed, and nothing apt would take along.
[ "$SYSREC" = 1 ] && { orig_restore_packages || true; }
[ "$UNRECORDED" -gt 0 ] && echo "$UNRECORDED file(s) had no record of what was there before furios_audio (installed by an older version) - removed, as before."
# The record has done its work. What was left alone was named above.
sudo rm -rf "$ORIG_DIR"

systemctl --user daemon-reload
systemctl --user start pulseaudio.socket pulseaudio.service 2>/dev/null || true
echo "Shipped state restored."
