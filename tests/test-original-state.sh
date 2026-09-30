#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Is what was there before the first change what comes back - exactly?
#
# tests/test-uninstall.sh runs the whole install and uninstall in a sandbox.
# This one looks at the record underneath (tools/original-state.sh) and at
# audioctl's side of it, case by case, from outside: a snapshot of the tree,
# the change, the way back, the snapshot again. Each case is one the old
# uninstall.sh got wrong or could not tell apart - a file that was there with
# a mode of its own, a link, a directory somebody else put things in, a second
# install over the first, the user's edit after ours, an install from before
# there was a record.
#
# Nothing here touches the phone: every path is under a temporary directory,
# ORIG_SU is empty, and dpkg-query and apt-get are stand-ins.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=lib.sh
. "$HERE/lib.sh"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
STUBDIR=$T/bin
mkdir -p "$STUBDIR"
PATH="$STUBDIR:$PATH"

# type, mode, link target and content of everything under a directory
snap() {
    find "$1" -mindepth 1 2>/dev/null | LC_ALL=C sort | while IFS= read -r p; do
        if [ -L "$p" ]; then printf 'link %s -> %s\n' "${p#$1}" "$(readlink "$p")"
        elif [ -d "$p" ]; then printf 'dir  %s %s\n' "${p#$1}" "$(stat -c %a "$p")"
        else printf 'file %s %s %s\n' "${p#$1}" "$(stat -c %a "$p")" "$(md5sum < "$p" | cut -c1-12)"
        fi
    done
}

# shellcheck source=../tools/original-state.sh
. "$ROOT/tools/original-state.sh"
ORIG_SU=
ORIG_DIR=$T/record
F=$T/fs          # the "phone"
mkdir -p "$F"

echo "-- a file that was not there"
p=$F/etc/a.conf
orig_record_dir "$F/etc"
orig_record "$p"
mkdir -p "$F/etc"; echo ours > "$p"; orig_mark_ours "$p"
orig_restore "$p"; rc=$?
check "comes back as absent" "0 absent" "$rc $([ -e "$p" ] && echo there || echo absent)"
orig_restore "$F/etc"
check "and the directory we made for it goes too" absent "$([ -e "$F/etc" ] && echo there || echo absent)"

echo
echo "-- a file that was there, with a mode of its own"
mkdir -p "$F/etc"
printf 'mine\n' > "$F/etc/b.conf"; chmod 0600 "$F/etc/b.conf"
before=$(snap "$F")
orig_record_dir "$F/etc"
orig_record "$F/etc/b.conf"
printf 'ours\n' > "$F/etc/b.conf"; chmod 0644 "$F/etc/b.conf"; orig_mark_ours "$F/etc/b.conf"
# A second install records again - and must not take our file for the original.
orig_record "$F/etc/b.conf"
printf 'ours v2\n' > "$F/etc/b.conf"; orig_mark_ours "$F/etc/b.conf"
orig_restore_all >/dev/null
check "comes back byte for byte and with its mode, after two installs" "$before" "$(snap "$F")"

echo
echo "-- a link"
ln -s /somewhere/else "$F/etc/c.link"
before=$(snap "$F")
orig_record "$F/etc/c.link"
rm -f "$F/etc/c.link"; echo ours > "$F/etc/c.link"; orig_mark_ours "$F/etc/c.link"
orig_restore "$F/etc/c.link"
check "comes back as the same link" "$before" "$(snap "$F")"

echo
echo "-- changed by the user after we wrote it"
p=$F/etc/d.conf
orig_record "$p"
echo ours > "$p"; orig_mark_ours "$p"
echo theirs > "$p"
out=$(orig_restore "$p"); rc=$?
check "is left alone" "1 theirs" "$rc $(cat "$p")"
check "and the way out says so" yes \
    "$(printf '%s' "$out" | grep -q "left alone - changed since furios_audio wrote it: $p" && echo yes || echo no)"
rm -f "$p"

echo
echo "-- removed by somebody else, where we never wrote"
printf 'x\n' > "$F/etc/e.conf"
orig_record "$F/etc/e.conf"
rm -f "$F/etc/e.conf"
out=$(orig_restore "$F/etc/e.conf"); rc=$?
check "is not put back behind their back" "1 absent" \
    "$rc $([ -e "$F/etc/e.conf" ] && echo there || echo absent)"

echo
echo "-- an older install of ours was there first"
echo "old ours" > "$F/etc/f.conf"
orig_record "$F/etc/f.conf" --ours-if-present
check "is recorded as unknown, not as an original" unknown "$(orig_recorded "$F/etc/f.conf")"
echo ours > "$F/etc/f.conf"; orig_mark_ours "$F/etc/f.conf"
out=$(orig_restore "$F/etc/f.conf")
check "is removed on the way out, as before" absent "$([ -e "$F/etc/f.conf" ] && echo there || echo absent)"
check "and the way out says there was no record" yes \
    "$(printf '%s' "$out" | grep -q 'no record of what was there before' && echo yes || echo no)"

echo
echo "-- a directory somebody else also uses"
mkdir -p "$F/share/wp"; echo 'not ours' > "$F/share/wp/60-user.conf"
before=$(snap "$F")
orig_record_dir "$F/share/wp"
orig_record "$F/share/wp/50-droid.conf"
echo ours > "$F/share/wp/50-droid.conf"; orig_mark_ours "$F/share/wp/50-droid.conf"
orig_restore_all >/dev/null
check "keeps what is theirs, loses what is ours" "$before" "$(snap "$F")"
orig_record_dir "$F/share/new"
mkdir -p "$F/share/new"; echo theirs > "$F/share/new/x"
out=$(orig_restore "$F/share/new")
check "one we made but somebody filled stays, and is named" "there yes" \
    "$([ -d "$F/share/new" ] && echo there || echo gone) $(printf '%s' "$out" | grep -q 'not empty' && echo yes || echo no)"
rm -rf "$F/share/new"

echo
echo "-- a directory that is state as a whole"
mkdir -p "$F/state/wp"; printf '[default-nodes]\nsink=mine\n' > "$F/state/wp/default-nodes"
before=$(snap "$F")
orig_record "$F/state/wp"
printf 'furios.x=1\n' > "$F/state/wp/sm-settings"; echo changed > "$F/state/wp/default-nodes"
always() { return 0; }
orig_restore "$F/state/wp" always
check "comes back as the tree it was" "$before" "$(snap "$F")"

echo
echo "-- packages the plugin build installed"
cat > "$STUBDIR/dpkg-query" <<'EOF'
#!/bin/sh
cat "$PKGS"
EOF
cat > "$STUBDIR/apt-get" <<'EOF'
#!/bin/sh
echo "$*" >> "$APTLOG"
case "$1" in
-s) shift 2; for p in "$@" $APT_EXTRA; do echo "Purg $p [1.0]"; done ;;
esac
exit 0
EOF
chmod +x "$STUBDIR"/*
export PKGS=$T/pkgs APTLOG=$T/apt.log APT_EXTRA=
printf 'ii  base\nii  meson\nrc  ninja-build\n' > "$PKGS"
orig_packages_snapshot "$T/before"
printf 'ii  base\nii  meson\nii  ninja-build\nii  libspa-0.2-dev\nii  libspa-dep\n' > "$PKGS"
orig_packages_added "$T/before"
orig_packages_added "$T/before"
check "what was added is recorded once, with what dpkg had before" \
    "libspa-0.2-dev absent libspa-dep absent ninja-build config-files" \
    "$(LC_ALL=C sort "$ORIG_DIR/packages" | paste -sd' ' -)"
APT_EXTRA=user-tool
out=$(orig_restore_packages); rc=$?
check "nothing is removed if apt would take something else along" "1 no" \
    "$rc $(grep -q '^purge -y' "$APTLOG" && echo yes || echo no)"
check "and it says what" yes "$(printf '%s' "$out" | grep -q 'user-tool' && echo yes || echo no)"
APT_EXTRA=
: > "$APTLOG"
orig_restore_packages >/dev/null
check "otherwise exactly those go: purged if they were absent" \
    "purge -y -q libspa-0.2-dev libspa-dep" "$(grep '^purge -y' "$APTLOG")"
check "and only removed if dpkg kept their configuration before" \
    "remove -y -q ninja-build" "$(grep '^remove -y' "$APTLOG")"

# --- audioctl's side, under $HOME -------------------------------------------
H=$T/home
setup_home() {
    rm -rf "$H" "$T/urecord"
    mkdir -p "$H/.config/systemd/user" "$H/legacy-etc" "$H/vendor"
    printf '[Unit]\nDescription=wp\n[Install]\nWantedBy=pipewire.service\n' > "$H/vendor/wireplumber.service"
}
in_audioctl() {
    ( export HOME=$H XDG_CONFIG_HOME=$H/.config AUDIOCTL_ETCU=$H/.config/systemd/user \
             AUDIOCTL_WPCONF_DIR=$H/.config/wireplumber/wireplumber.conf.d \
             AUDIOCTL_ORIGINAL_DIR=$T/urecord AUDIOCTL_WPSTATE_DIR=$H/.local/state/wireplumber \
             AUDIOCTL_STATE_DIR=$H/state AUDIOCTL_LEGACY_ETCU=$H/legacy-etc \
             AUDIOCTL_VENDOR_UNITS=$H/vendor
      AUDIOCTL_LIB=1 . "$ROOT/audioctl"
      "$@" )
}
# What audioctl writes across the three profiles, in the order it writes it.
audioctl_writes() {
    do_mask pipewire-pulse.service pipewire-pulse.socket wireplumber.service
    do_unmask pulseaudio.service pulseaudio.socket
    droid_monitor_off_file
    mkdir -p "$(dirname "$DROPIN")"
    printf '[Service]\nExecStart=\nExecStart=/usr/bin/pipewire -c /x/pipewire-hal.conf\n' > "$DROPIN"
    # "systemctl --user disable wireplumber.service" and our enables
    rm -f "$ETCU/pipewire.service.wants/wireplumber.service" "$ETCU/pipewire-session-manager.service"
    mkdir -p "$ETCU/default.target.wants"
    ln -sf /etc/systemd/user/furios-audio-apply.service "$ETCU/default.target.wants/furios-audio-apply.service"
    mkdir -p "$WPSTATE"; printf 'furios.bluetooth-codec=aac\n' >> "$WPSTATE/sm-settings"
}

echo
echo "-- audioctl on a phone somebody had made their own"
setup_home
U=$H/.config/systemd/user
mkdir -p "$U/pipewire.service.wants" "$U/default.target.wants" "$H/.local/state/wireplumber"
ln -s /dev/null "$U/pulseaudio.socket"
ln -s "$H/vendor/wireplumber.service" "$U/pipewire.service.wants/wireplumber.service"
ln -s "$H/vendor/wireplumber.service" "$U/pipewire-session-manager.service"
ln -s /x/furios-gps-contribute.service "$U/default.target.wants/furios-gps-contribute.service"
printf '[default-nodes]\nsink=mine\n' > "$H/.local/state/wireplumber/default-nodes"
before=$(snap "$H")
in_audioctl record_originals >/dev/null
check "the user's own mask is recorded as theirs, not as an old install of ours" "link" \
    "$(in_audioctl original status | awk -v p="$U/pulseaudio.socket" '$2 == p {print $1}')"
in_audioctl audioctl_writes
in_audioctl record_originals >/dev/null      # a second switch
check "the switches changed something" yes "$([ "$(snap "$H")" != "$before" ] && echo yes || echo no)"
in_audioctl original restore >/dev/null
rm -rf "$T/urecord"
check "and the way back is exactly what was there" "$before" "$(snap "$H")"

echo
echo "-- audioctl: the user edits one of ours afterwards"
setup_home
in_audioctl record_originals >/dev/null
in_audioctl droid_monitor_off_file
WPOFF=$H/.config/wireplumber/wireplumber.conf.d/99-furios-droid-off.conf
echo '# mine now' > "$WPOFF"
out=$(in_audioctl original restore 2>&1); rc=$?
check "it is left alone, and the restore says it left something" "1 # mine now" "$rc $(cat "$WPOFF")"
check "naming the file" yes \
    "$(printf '%s' "$out" | grep -q "left alone.*$WPOFF" && echo yes || echo no)"

echo
echo "-- audioctl: set up by an older version, no record"
setup_home
in_audioctl audioctl_writes
out=$(in_audioctl original restore 2>&1); rc=$?
check "the way back says there is no record" "3 yes" \
    "$rc $(printf '%s' "$out" | grep -q 'no record' && echo yes || echo no)"
in_audioctl record_originals >/dev/null
check "a record taken now calls our old files unknown" unknown \
    "$(in_audioctl original status | awk -v p="$H/.config/wireplumber/wireplumber.conf.d/99-furios-droid-off.conf" '$2 == p {print $1}')"
check "and so is WirePlumber's state from that time" unknown \
    "$(in_audioctl original status | awk -v p="$H/.local/state/wireplumber" '$2 == p {print $1}')"

echo
echo "-- audioctl records nothing when told not to, or in a dry run"
setup_home
( AUDIOCTL_NO_RECORD=1 in_audioctl record_originals ) >/dev/null
check "AUDIOCTL_NO_RECORD (what uninstall.sh sets)" no "$([ -d "$T/urecord" ] && echo yes || echo no)"
( in_audioctl eval 'DRY=1; record_originals' ) >/dev/null
check "--dry-run" no "$([ -d "$T/urecord" ] && echo yes || echo no)"
# The other tests move where audioctl writes but know nothing of the record.
# Their switches must not leave a record of temporary paths in the real
# ~/.config - an uninstall would take it for this phone's.
( export HOME=$T/elsewhere XDG_CONFIG_HOME=$T/elsewhere/.config AUDIOCTL_ETCU=$T/elsewhere/etcu
  unset AUDIOCTL_ORIGINAL_DIR
  AUDIOCTL_LIB=1 . "$ROOT/audioctl"; record_originals ) >/dev/null 2>&1
check "a caller that moved ETCU but not the record records nothing" no \
    "$([ -e "$T/elsewhere/.config/furios-audio" ] && echo yes || echo no)"

summary
