#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Experiment: turn on MediaTek's handsfree echo suppression (DMNR) for calls.
#
# Background
# ----------
# On this device the vendor's tuning file says:
#
#   MTK_DUAL_MIC_SUPPORT         yes   two microphones are present
#   MTK_HANDSFREE_DMNR_SUPPORT   yes   the chip can do handsfree DMNR
#   MTK_INCALL_HANDSFREE_DMNR    no    during a call it is TURNED OFF
#   MTK_VOIP_HANDSFREE_DMNR      no
#   MTK_VOIP_NORMAL_DMNR         no
#
# DMNR is MediaTek's dual-microphone method against ambient noise and echo.
# With it off, the far end hears itself - especially on speakerphone.
#
# There is more than one of those files
# -------------------------------------
# And that is why this used to change nothing at all. The parser
# (/vendor/lib64/libaudio_param_parser-vnd.so) names three files:
#
#   AudioParamOptions.xml        the base
#   AudioParamOptions_vext.xml   the vendor extension - and on this device it
#                                is the longer one, with entries the base does
#                                not have at all (VOW, A2DP offload, TTY)
#   AudioParamOptions_mgvi.xml   not present here
#
# Laying a copy over the base alone left the three switches on "no" in the
# vext file, which is the one a vendor extension exists to win with. So every
# options file that is there gets its own copy and its own bind mount, and
# "on" means all of them - a half state reports itself as off, because that is
# what it sounds like.
#
# MTK_INCALL_NORMAL_DMNR is set as well where the file has it (the vext file
# does, empty). "Handsfree" is the speakerphone; a call held to the ear runs
# the normal path, and the switch for that one is separate.
#
# Why a bind mount
# ----------------
# /android/vendor is mounted read-only and protected by dm-verity. Tampering
# with it can, in the worst case, leave the device unbootable. A bind mount
# instead lays a modified copy over the file - the partition stays untouched,
# and a reboot clears everything away.
#
# It only takes effect once the HAL re-reads the files, i.e. on the next start
# of the audio stack (which this script takes care of).
#
# The tuning never reached the modem
# ----------------------------------
# Found 2026-09-26 in the HAL's own log (logcat, which it writes to even under
# hybris): at every call, and again at every route change, it loads the right
# tuning - "Profile,Handsfree" for the speaker - and then fails to hand it over:
#
#   SpeechExtMemUSIP: open(/dev/usip) fail, errno: 13
#   SpeechDriverNormal: writeAllSpeechParametersToModem(), dataSize 49152,
#                       writeSphParamToShareMemory FAIIL!!
#   SpeechDriverNormal: configSpeechInfo(), ... param emi valid: 0, param size: 0x0
#
# /dev/usip is the memory the modem reads its speech tuning from - echo
# cancellation included - and it is root:root 0600 here, while Android's
# init.mt6877.rc makes it media:media 0660 for the audio server. The HAL runs
# inside PipeWire, as the phone's user, and is refused. So the modem ran every
# call on its built-in defaults, whatever the files above said: that is why
# turning DMNR on alone changed nothing that anyone could hear.
#
# "on" therefore also lets group audio (which PipeWire is in) open it, and
# "off" puts back the state the kernel creates it in. The HAL opens it once, at
# start, so this too needs the restart below.
#
# Remembering it across a reboot
# ------------------------------
# A bind mount is gone after a reboot by construction, so "set on" writes a
# marker and the boot unit lays the files over again. Two things about where
# things live follow from that, and neither is arbitrary:
#
#   - the marker is /etc/..., root-owned. It decides what the system mounts at
#     boot, so it must not be writable by the account whose audio it is.
#   - the copies are rebuilt from the vendor originals on every apply, into
#     /run, which is tmpfs and root-owned. They used to sit in
#     /var/lib/furios-audio, which this user can write: mounting that at boot
#     would have let anything running as that user put its own file over a
#     vendor one, automatically, without ever asking for a password.
#     Rebuilding costs a sed and closes it.
set -e

PARAMDIR=${DMNR_PARAMDIR:-/android/vendor/etc/audio_param}
RUNDIR=${DMNR_RUNDIR:-/run/furios-audio-dmnr}
MARKER=${DMNR_MARKER:-/etc/furios-audio-dmnr.persistent}
USIP=${DMNR_USIP:-/dev/usip}
USIP_GROUP=${DMNR_USIP_GROUP:-audio}
USIP_GROUP_OFF=${DMNR_USIP_GROUP_OFF:-root}

# Two families, four situations. MTK_* is the switch, VIR_*_SUPPORT is the
# same situation once more under the vendor's own name - and on this device
# they do not agree: VIR_INCALL_NORMAL_DMNR_SUPPORT is already "yes" while
# every other one is "no", which is exactly the shape of "a call held to the
# ear is fine, the speakerphone echoes". Both names are set, because which of
# them the HAL asks is not something this file can decide.
SWITCHES='MTK_INCALL_HANDSFREE_DMNR|MTK_INCALL_NORMAL_DMNR|MTK_VOIP_HANDSFREE_DMNR|MTK_VOIP_NORMAL_DMNR|VIR_INCALL_HANDSFREE_DMNR_SUPPORT|VIR_INCALL_NORMAL_DMNR_SUPPORT|VIR_VOIP_HANDSFREE_DMNR_SUPPORT|VIR_VOIP_NORMAL_DMNR_SUPPORT'
SHOWN_KEYS="$SWITCHES|MTK_HANDSFREE_DMNR_SUPPORT|MTK_DUAL_MIC_SUPPORT|MTK_AUDIO_NUMBER_OF_MIC"

# As root an override that moves where this reads or writes would be a way of
# mounting anything over a vendor file at boot. The tests need them and
# therefore run unprivileged.
if [ "$(id -u)" -eq 0 ]; then
    for _v in DMNR_PARAMDIR DMNR_RUNDIR DMNR_MARKER DMNR_USIP DMNR_USIP_GROUP DMNR_USIP_GROUP_OFF; do
        if [ -n "$(eval echo "\${$_v:-}")" ]; then
            echo "refusing to honour $_v as root" >&2
            exit 3
        fi
    done
fi

# Every options file the parser reads, in the order it names them. Missing
# ones are not an error: _mgvi does not exist on this device, and a device
# with only the base file is just as valid.
option_files() {
    local f
    for f in "$PARAMDIR"/AudioParamOptions.xml \
             "$PARAMDIR"/AudioParamOptions_vext.xml \
             "$PARAMDIR"/AudioParamOptions_mgvi.xml; do
        [ -f "$f" ] && printf '%s\n' "$f"
    done
    return 0
}

copy_of() { printf '%s/%s.dmnr.xml\n' "$RUNDIR" "$(basename "$1" .xml)"; }

is_mounted() { grep -q " $1 " /proc/mounts 2>/dev/null; }

# The copies are built here and nowhere else, always from the vendor original,
# into a root-owned directory on tmpfs. Never from a file left lying around:
# what gets laid over a vendor file has to be something this script made.
#
# The value is replaced whatever it is rather than only where it reads "no":
# the vext file carries MTK_INCALL_NORMAL_DMNR with an empty value, which is
# off as surely as "no" is, and a file that is already right simply comes out
# unchanged - which is how "nothing to do" is decided one line further down.
build_copy() {
    local orig="$1" copy
    copy=$(copy_of "$orig")
    [ -r "$orig" ] || return 1
    sudo mkdir -p "$RUNDIR"
    sudo chmod 0755 "$RUNDIR"
    sed -E 's@(<Param name="('"$SWITCHES"')" value=")[^"]*"@\1yes"@g' \
        "$orig" | sudo tee "$copy" >/dev/null
    if sudo cmp -s "$orig" "$copy"; then
        sudo rm -f "$copy"
        return 2                      # nothing to change in this one
    fi
    return 0
}

# True while any file still has a switch that is off. Once a copy is mounted
# the file reads "yes" through the mount, so this is also what says whether
# turning it on is finished.
any_switch_off() {
    local f
    for f in $(option_files); do
        grep -qE '<Param name="('"$SWITCHES"')" value="(no)?"' "$f" && return 0
    done
    return 1
}

# The modem's speech tuning memory. A device without it has nothing to open and
# counts as open, so that it cannot hold the switch at "off" forever.
usip_open() {
    [ -e "$USIP" ] || return 0
    [ "$(stat -c '%G %a' "$USIP" 2>/dev/null)" = "$USIP_GROUP 660" ]
}

# What the node looked like before "on" first opened it - group and mode -
# so that "off" puts back exactly that rather than what the kernel is assumed
# to create it with. In the root-owned run directory: the node is made anew at
# every boot, and so is this record. The first one counts; a second "on" finds
# it and leaves it.
USIP_ORIGINAL=$RUNDIR/usip.original

# Both return true only when they changed something.
usip_grant() {
    [ -e "$USIP" ] || return 1
    usip_open && return 1
    if [ ! -e "$USIP_ORIGINAL" ]; then
        sudo mkdir -p "$RUNDIR"
        sudo chmod 0755 "$RUNDIR"
        stat -c '%G %a' "$USIP" | sudo tee "$USIP_ORIGINAL" >/dev/null
    fi
    sudo chgrp "$USIP_GROUP" "$USIP"
    sudo chmod 0660 "$USIP"
}

# Only while it is still as "on" left it. Somebody who changed it since
# changed it on purpose, and it stays as they made it.
usip_close() {
    local group=$USIP_GROUP_OFF mode=0600
    [ -e "$USIP" ] || return 1
    usip_open || { [ -e "$USIP_ORIGINAL" ] && echo "usip:  $USIP was changed since - left as it is" >&2; return 1; }
    if [ -r "$USIP_ORIGINAL" ]; then
        read -r group mode < "$USIP_ORIGINAL"
    else
        echo "usip:  no record of $USIP before it was opened - closing it to $USIP_GROUP_OFF 0600" >&2
    fi
    sudo chmod "$mode" "$USIP"
    sudo chgrp "$group" "$USIP"
    sudo rm -f "$USIP_ORIGINAL"
}

mounted_count() {
    local f n=0
    for f in $(option_files); do
        is_mounted "$f" && n=$((n + 1))
    done
    printf '%s\n' "$n"
}

show() {
    local f n
    n=$(mounted_count)
    # First line deliberately machine-readable - the switcher app reads it.
    # A half state is not "on": it is what the base-file-only version of this
    # script left behind, and it sounds exactly like off on a call.
    if [ "$n" -gt 0 ] && ! any_switch_off && usip_open; then
        printf 'state=on\n'
    else
        printf 'state=off\n'
    fi
    # Second machine-readable line, same reason as the first: the app shows
    # whether this survives a reboot, and guessing from state= would be wrong.
    if [ -e "$MARKER" ]; then
        printf 'persistent=yes\n'
    else
        printf 'persistent=no\n'
    fi
    if [ ! -e "$USIP" ]; then
        printf 'usip:  %s not present - nothing to open\n' "$USIP"
    elif usip_open; then
        printf 'usip:  %s open to group %s - the tuning reaches the modem\n' "$USIP" "$USIP_GROUP"
    else
        printf 'usip:  %s closed - the HAL cannot hand the tuning to the modem\n' "$USIP"
    fi
    for f in $(option_files); do
        printf 'file:  %s\n' "$f"
        if is_mounted "$f"; then
            printf 'state: modified copy is laid over it\n'
        else
            printf 'state: vendor original\n'
        fi
        printf 'current values:\n'
        grep -oE '<Param name="('"$SHOWN_KEYS"')" value="[^"]*"' "$f" \
            | sed 's/<Param name="/  /; s/" value="/ = /; s/"$//'
    done
}

turn_on() {
    local f rc changed=0
    usip_grant && changed=$((changed + 1))
    for f in $(option_files); do
        is_mounted "$f" && { changed=$((changed + 1)); continue; }
        rc=0; build_copy "$f" || rc=$?
        case $rc in
        0) sudo mount --bind "$(copy_of "$f")" "$f"; changed=$((changed + 1)) ;;
        2) : ;;                       # already says yes - leave it alone
        *) echo "tuning file not readable - wrong device?" >&2; return 1 ;;
        esac
    done
    [ "$changed" -gt 0 ] || { echo "nothing to change - the switches are not off." >&2; return 1; }
    return 0
}

turn_off() {
    local f changed=0
    usip_close && changed=$((changed + 1))
    for f in $(option_files); do
        if is_mounted "$f"; then
            sudo umount "$f"
            changed=$((changed + 1))
        fi
    done
    [ "$changed" -gt 0 ]
}

# Ask sudo once, before anything is touched. Every step below has its own
# sudo, and several of them sit where a failure is not fatal ("a || b" turns
# set -e off), so without a way to ask - no terminal, no askpass, which is how
# the app starts this on a phone whose sudoers wants a password - they would
# fail one by one and leave a half-laid state. This way sudo's own words ("a
# terminal is required ... askpass helper") come out first and nothing has
# changed; the app reads them as "ask for the password".
root_first() {
    sudo true || { echo "sudo could not be asked - nothing was changed" >&2; exit 1; }
}

case "${1:-status}" in
status) show ;;

on)
    root_first
    turn_on || exit 1
    echo "Modified copies mounted. Restarting the audio stack so the HAL reads them:"
    audioctl restart >/dev/null 2>&1 || true
    echo
    show
    echo
    echo "Now place a call and ask the far end whether the echo is gone."
    echo "Back: $0 off   (or simply reboot)"
    ;;

set)
    # Same words as audioctl and gpsctl: "on"/"off" is now, "set" is now and
    # after the next reboot as well.
    case "${2:-}" in
    on|off) root_first ;;
    esac
    case "${2:-}" in
    on)
        turn_on || exit 1
        printf 'on\n' | sudo tee "$MARKER" >/dev/null
        sudo chmod 0644 "$MARKER"
        audioctl restart >/dev/null 2>&1 || true
        echo "On, and remembered - the boot unit lays them over again."
        ;;
    off)
        turn_off || true
        sudo rm -f "$MARKER"
        audioctl restart >/dev/null 2>&1 || true
        echo "Off, and remembered - nothing is laid over at boot."
        ;;
    *) echo "usage: $0 set on|off" >&2; exit 1 ;;
    esac
    show
    ;;

boot)
    # What the boot unit runs. Quiet and never fatal: echo suppression that
    # cannot be put in place is not a reason to hold up the boot, and this
    # runs before anybody could be in a call anyway.
    [ -e "$MARKER" ] || exit 0
    turn_on || exit 0
    ;;

off)
    root_first
    if turn_off; then
        echo "Originals restored."
    else
        echo "Nothing was laid over them."
    fi
    # The marker is left alone on purpose: "off" is for now, "set off" is for
    # good. Say so, rather than let the next boot look like it undid this.
    [ -e "$MARKER" ] && echo "Still remembered - it comes back at the next boot ($0 set off)."
    audioctl restart >/dev/null 2>&1 || true
    show
    ;;

*) echo "usage: $0 [status|on|off|set on|set off|boot]" >&2; exit 1 ;;
esac
