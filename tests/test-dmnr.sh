#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
#
# What can be decided about the echo suppression without root and without the
# vendor's tuning file.
#
# What is NOT here, and cannot be: whether the far end stops hearing itself.
# That needs a call and somebody on the other side. What is here is everything
# around it - that the setting can be remembered, that the boot path keeps
# quiet when it was not, and that the thing laid over a vendor file is always
# one this script just built.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
. "$HERE/lib.sh"

TOOL=$ROOT/experiments/dmnr-handsfree.sh
UNIT=$ROOT/systemd/furios-audio-dmnr.service
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Nothing in here may touch the phone. The tool restarts the sound server
# with "audioctl restart" and bind-mounts with sudo - and this test used to let
# it: on a machine with a sudo ticket every run bind-mounted temp files as root
# and restarted the REAL audio stack through the installed audioctl. Found
# 2026-09-25 when a test run at 17:52:30 restarted PipeWire under a paired
# headset, and the next Bluetooth call had no audio in either direction.
# sudo runs the command as this user, the rest only records.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/sudo" <<'STUB'
#!/bin/sh
exec "$@"
STUB
for tool in audioctl mount umount; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\nexit 0\n' "$tool" "$TMP" > "$TMP/bin/$tool"
done
chmod +x "$TMP/bin/"*
PATH="$TMP/bin:$PATH"

# Stand-ins for the vendor's tuning files, with the switches in the state the
# device ships them in - and two of them, because that is the whole point: the
# parser reads a base file and a vendor extension, and a copy laid over the
# base alone leaves the extension saying "no".
mkdir -p "$TMP/param"
cat > "$TMP/param/AudioParamOptions.xml" <<'XML'
<Params>
<Param name="MTK_DUAL_MIC_SUPPORT" value="yes"/>
<Param name="MTK_HANDSFREE_DMNR_SUPPORT" value="yes"/>
<Param name="MTK_INCALL_HANDSFREE_DMNR" value="no"/>
<Param name="MTK_VOIP_HANDSFREE_DMNR" value="no"/>
<Param name="MTK_VOIP_NORMAL_DMNR" value="no"/>
</Params>
XML
cat > "$TMP/param/AudioParamOptions_vext.xml" <<'XML'
<Params>
<Param name="MTK_DUAL_MIC_SUPPORT" value="yes"/>
<Param name="MTK_HANDSFREE_DMNR_SUPPORT" value="yes"/>
<Param name="MTK_INCALL_HANDSFREE_DMNR" value="no"/>
<Param name="MTK_VOIP_HANDSFREE_DMNR" value="no"/>
<Param name="MTK_VOIP_NORMAL_DMNR" value="no"/>
<Param name="MTK_INCALL_NORMAL_DMNR" value=""/>
</Params>
XML
sed "s|^PARAMDIR=.*|PARAMDIR=$TMP/param|" "$TOOL" > "$TMP/dmnr.sh"

# The modem's tuning memory, as the kernel creates it: closed. A plain file
# stands in for the device, and both groups are this user's own, because
# chgrp to audio or root is not something an unprivileged test can do - what
# is checked is the mode, which is what the HAL runs into.
: > "$TMP/usip"
chmod 0600 "$TMP/usip"
MYGROUP=$(id -gn)
run_tool() {
    DMNR_RUNDIR="$TMP/run" DMNR_MARKER="$TMP/marker" DMNR_USIP="$TMP/usip" \
    DMNR_USIP_GROUP="$MYGROUP" DMNR_USIP_GROUP_OFF="$MYGROUP" \
        bash "$TMP/dmnr.sh" "$@" 2>&1
}

# The app reads these two lines and shows four states from them. Both have to
# be there, and on their own line, or it shows the wrong one.
check "status reports whether it is on" "1" "$(run_tool status | grep -c '^state=')"
check "and whether it is remembered" "1" "$(run_tool status | grep -c '^persistent=')"
check "nothing remembered to begin with" "persistent=no" "$(run_tool status | sed -n 2p)"

# The boot unit runs this on every boot, on every device. Without a marker it
# has to be a no-op that succeeds - a failure here would show up as a failed
# unit on a phone where nobody ever asked for echo suppression.
run_tool boot >/dev/null 2>&1
check "boot without a marker does nothing, successfully" "0" "$?"
check "and lays nothing over the files" "no" \
    "$(ls "$TMP/run" 2>/dev/null | grep -q . && echo yes || echo no)"

# The regression this file exists for: the first version of the tool changed
# AudioParamOptions.xml and nothing else, the HAL went on reading "no" out of
# AudioParamOptions_vext.xml, and the switch in the app did nothing that could
# be heard. Both files have to be seen, and a half state has to say off.
check "every options file the parser reads is seen" "2" \
    "$(run_tool status | grep -c '^file:')"
check "the vendor extension is one of them" "1" \
    "$(run_tool status | grep -c 'AudioParamOptions_vext.xml')"
check "with nothing laid over, that is off" "state=off" "$(run_tool status | sed -n 1p)"
check "the switch for a call held to the ear is set too" "yes" \
    "$(grep -q 'MTK_INCALL_NORMAL_DMNR' "$TOOL" && echo yes || echo no)"

touch "$TMP/marker"
check "a marker is seen" "persistent=yes" "$(run_tool status | sed -n 2p)"

# "off" is for now and "set off" is for good. If "off" dropped the marker, the
# two would be the same command and the distinction the app relies on would
# not exist.
check "'off' leaves the marker alone" "yes" \
    "$([ -e "$TMP/marker" ] && echo yes || echo no)"
check "and says the reboot will bring it back" "1" \
    "$(run_tool off | grep -c 'comes back at the next boot')"

check "an unknown word is refused" "1" \
    "$(run_tool nonsense >/dev/null 2>&1; echo $?)"
check "and 'set' without on/off too" "1" \
    "$(run_tool set >/dev/null 2>&1; echo $?)"

# The copy is rebuilt from the vendor original every time, into a root-owned
# directory on tmpfs. It used to be written into /var/lib/furios-audio, which
# this user can write - and with a boot unit mounting it, anything running as
# this user could have put its own file over a vendor one at the next boot,
# without a password ever being asked for.
check "the copy is built in /run, not somewhere this user owns" "yes" \
    "$(grep -q 'RUNDIR=${DMNR_RUNDIR:-/run/' "$TOOL" && echo yes || echo no)"
check "and always rebuilt from the vendor file, never reused" "yes" \
    "$(grep -q 'build_copy()' "$TOOL" && grep -q 'turn_on()' "$TOOL" && echo yes || echo no)"
check "the marker lives where this user cannot write it" "yes" \
    "$(grep -q 'MARKER=${DMNR_MARKER:-/etc/' "$TOOL" && echo yes || echo no)"
check "as root the overrides are refused" "yes" \
    "$(grep -q 'refusing to honour' "$TOOL" && echo yes || echo no)"

# The unit is what makes "remembered" true, so it has to exist, be valid, and
# be ordered before anything reads the file it lays over.
check "there is a boot unit" "yes" "$([ -f "$UNIT" ] && echo yes || echo no)"
check "it runs before the session starts the audio stack" "1" \
    "$(grep -c '^Before=graphical.target' "$UNIT")"
check "it does nothing on a device without the vendor file" "1" \
    "$(grep -c '^ConditionPathExists=' "$UNIT")"

# The condition and the mount, in that order - and the order is the whole
# point. A ConditionPathExists is checked when the unit is about to start, so
# without this the unit was skipped at every boot: the path it asks about is
# inside the vendor image, which android-mount.service was still mounting.
# Measured 2026-09-19: unmet at 12:52:20, mounted at 12:52:56, the setting
# gone while status still said persistent=yes.
check "it waits for the vendor image before asking whether the file is there" "1" \
    "$(grep -c '^After=android-mount.service' "$UNIT")"
# ... and the condition is about a path under that very mount, which is what
# ties the two lines together.
check "and the path it asks about is under that mount" "yes" \
    "$(grep '^ConditionPathExists=' "$UNIT" | grep -q '=/android/' && echo yes || echo no)"
if command -v systemd-analyze >/dev/null 2>&1; then
    check "and systemd accepts every key in it" "" \
        "$(systemd-analyze verify "$UNIT" 2>&1 | grep -iE 'unknown key|unknown lvalue' | head -1)"
fi

# The tuning has to reach the modem. The HAL hands it over through /dev/usip,
# which the kernel creates root-only; PipeWire runs as the phone's user, so
# every call ran on the modem's defaults whatever the files said (HAL log,
# 2026-09-26: "open(/dev/usip) fail, errno: 13").
run_tool off >/dev/null
chmod 0600 "$TMP/usip"
run_tool on >/dev/null
check "on opens the modem's tuning memory to the audio group" "660" \
    "$(stat -c %a "$TMP/usip")"
check "and status says the tuning reaches the modem" "yes" \
    "$(run_tool status | grep -q '^usip: .*reaches the modem' && echo yes || echo no)"
run_tool off >/dev/null
check "off closes it again, as the kernel made it" "600" \
    "$(stat -c %a "$TMP/usip")"
check "and status says the HAL cannot hand it over" "yes" \
    "$(run_tool status | grep -q '^usip: .*closed' && echo yes || echo no)"
check "the boot unit opens it too when the setting is remembered" "660" \
    "$(touch "$TMP/marker"; run_tool boot >/dev/null; stat -c %a "$TMP/usip")"
rm -f "$TMP/marker"
run_tool off >/dev/null
mv "$TMP/usip" "$TMP/usip.away"
check "a device without it is told so, not failed" "yes" \
    "$(run_tool status | grep -q '^usip: .*not present' && echo yes || echo no)"
mv "$TMP/usip.away" "$TMP/usip"
check "as root the device path cannot be moved" "3" \
    "$(grep -q 'DMNR_USIP DMNR_USIP_GROUP DMNR_USIP_GROUP_OFF' "$TOOL" && echo 3 || echo 0)"

# Without a way to ask for the password, stop before anything is touched. The
# app starts this with no terminal; on a phone whose sudoers wants a password
# every sudo below failed on its own, several of them where set -e is off.
cat > "$TMP/bin/sudo-refuses" <<'STUB'
#!/bin/sh
echo "sudo: a terminal is required to read the password; either use the -S option to read from standard input or configure an askpass helper" >&2
exit 1
STUB
chmod +x "$TMP/bin/sudo-refuses"
cp "$TMP/bin/sudo" "$TMP/bin/sudo-works"
cp "$TMP/bin/sudo-refuses" "$TMP/bin/sudo"
: > "$TMP/calls"
chmod 0600 "$TMP/usip"
out=$(run_tool on; echo "rc=$?")
cp "$TMP/bin/sudo-works" "$TMP/bin/sudo"
check "without a way to ask, on fails" "yes" \
    "$(printf '%s' "$out" | grep -q 'rc=1' && echo yes || echo no)"
check "and says sudo's own words, which the app reads as 'ask'" "yes" \
    "$(printf '%s' "$out" | grep -q 'askpass' && echo yes || echo no)"
check "and nothing was mounted or restarted" "" "$(cat "$TMP/calls")"
check "and the tuning memory was not touched" "600" "$(stat -c %a "$TMP/usip")"

# Installed and removed as a pair. A marker left behind by an uninstall would
# mount a file at boot that nothing on the system knows about any more.
check "install-hal.sh installs the unit" "yes" \
    "$(grep -q 'furios-audio-dmnr.service' "$ROOT/install-hal.sh" && echo yes || echo no)"
check "the package ships it too" "yes" \
    "$(grep -q 'furios-audio-dmnr.service' "$ROOT/packaging/build-deb.sh" && echo yes || echo no)"
check "uninstall.sh removes the unit" "yes" \
    "$(grep -q 'furios-audio-dmnr.service' "$ROOT/uninstall.sh" && echo yes || echo no)"
check "and the marker with it" "yes" \
    "$(grep -q 'furios-audio-dmnr.persistent' "$ROOT/uninstall.sh" && echo yes || echo no)"

# "off" used to close the node to root 0600 - what the kernel was assumed to
# create it with. It puts back what was there before "on" instead, and leaves
# it alone when somebody changed it since.
run_tool off >/dev/null
chmod 0640 "$TMP/usip"
run_tool on >/dev/null
check "a node that was not as assumed is opened" "660" "$(stat -c %a "$TMP/usip")"
run_tool off >/dev/null
check "and off puts back what it was, not what it was assumed to be" "640" "$(stat -c %a "$TMP/usip")"
run_tool on >/dev/null
run_tool on >/dev/null
check "a second on keeps the first record" "640" \
    "$(run_tool off >/dev/null; stat -c %a "$TMP/usip")"
run_tool on >/dev/null
chmod 0664 "$TMP/usip"
out=$(run_tool off)
check "changed by somebody after on: left as they made it" "664" "$(stat -c %a "$TMP/usip")"
check "and off says so" yes "$(printf '%s' "$out" | grep -q 'changed since - left as it is' && echo yes || echo no)"
rm -f "$TMP/run/usip.original"
chmod 0660 "$TMP/usip"
out=$(run_tool off)
check "no record (opened by an older version): closed as before, and said" "600 yes" \
    "$(stat -c %a "$TMP/usip") $(printf '%s' "$out" | grep -q 'no record' && echo yes || echo no)"

summary
