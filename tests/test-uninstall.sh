#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# After install, use and uninstall, is the phone the phone it was before?
#
# test-install.sh checks that uninstall.sh MENTIONS every file install.sh
# names - it reads both scripts and so shares their idea of what there is. It
# could not see what nobody wrote down: the masks, copies, wants and drop-in
# audioctl leaves under ~/.config, WirePlumber's memory under ~/.local/state,
# an enable's alias link, the want "systemctl enable" writes for the echo
# unit. Those stayed behind, and a later install found a phone that was not
# new.
#
# So this one does not read the scripts at all. It runs them - install.sh,
# then audioctl through its profiles, then uninstall.sh - in a sandbox, and
# compares the file system before and after. Whatever is new, gone or changed
# is a finding, whoever wrote it and whether or not anybody thought of it.
#
# The sandbox (bubblewrap, unprivileged): the real root read-only, the places
# the scripts write to replaced by copies in a temporary directory, no network,
# no D-Bus, its own PIDs. sudo, systemctl, pactl and wpctl are stand-ins;
# systemctl's enable and disable write and remove the same links the real one
# does, because those links are part of what is being checked. Nothing on the
# phone can be changed from in there - which is checked first, not assumed.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=lib.sh
. "$HERE/lib.sh"

skip() { printf '  \033[33mskipped\033[0m - %s\n' "$1"; exit 0; }
command -v bwrap >/dev/null 2>&1 || skip "bubblewrap not installed (apt install bubblewrap)"
[ -r /usr/share/pipewire/pipewire-droid.conf ] || skip "no /usr/share/pipewire/pipewire-droid.conf - not a FuriOS phone"
bwrap --ro-bind / / --unshare-all true 2>/dev/null || skip "no unprivileged user namespaces here"

TRIPLET=$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo aarch64-linux-gnu)
SPA=/usr/lib/$TRIPLET/spa-0.2
W=$(mktemp -d)
trap 'chmod -R u+w "$W" 2>/dev/null; rm -rf "$W"' EXIT

# --- a phone as shipped, where the scripts write ----------------------------
# Kept pristine; every round below runs on a copy of it.
P=$W/pristine
# /etc/systemd as it is here: the FuriOS masks are the point of the restore.
mkdir -p "$P/etc-systemd" "$P/usr-local" "$P/var-lib" "$P/spa" "$P/run-user" \
         "$P/home/.config" "$P/home/.local/share" "$P/home/.local/state" "$P/home/.cache"
chmod 700 "$P/run-user"
cp -a /etc/systemd/. "$P/etc-systemd/" 2>/dev/null
# ...but without this repo: on the phone this runs on, it is usually
# installed, and "before" was then a phone with furios_audio on it. The
# uninstall took those files away and the check below counted each of them
# as something lost - 13 findings that were the test's, not the scripts'.
rm -rf "$P/etc-systemd/system/furios-audio-dmnr.service" \
       "$P/etc-systemd/system/multi-user.target.wants/furios-audio-dmnr.service" \
       "$P/etc-systemd/system/ofono.service.d/30-furios-audio-hfp.conf" \
       "$P/etc-systemd/user/wireplumber.service.d/furios-bluez5-fix.conf" \
       "$P/etc-systemd/user"/furios-audio-*.service "$P/etc-systemd/user/furios-pw-tunnel.service"
rmdir "$P/etc-systemd/system/ofono.service.d" "$P/etc-systemd/user/wireplumber.service.d" 2>/dev/null
# /usr/local as a new phone has it: the standard directories and nothing in them.
for d in /usr/local/*/; do mkdir -p "$P/usr-local/$(basename "$d")"; done
# PipeWire's plugins, without what we would have put there: the droid plugin
# and the AAC module tools/build-bluez5-aac.sh builds. Debian ships neither.
cp -a "$SPA/." "$P/spa/"
rm -rf "$P/spa/droid" "$P/spa/bluez5/libspa-codec-bluez5-aac.so" "$P/spa/bluez5/aac-built-against"

# The work tree as it is, uncommitted changes included - but the plugin is not
# built here, that is a job of minutes and a network. A stand-in file is enough:
# what matters is where it goes and that it goes again.
mkdir -p "$W/repo"
# New files too: a file not yet added to git is part of the tree being tested,
# and without it the sandbox ran a tree that could not exist anywhere.
(cd "$ROOT" && git ls-files -z --cached --others --exclude-standard \
    | xargs -0 cp --parents -t "$W/repo")
cat > "$W/repo/tools/build-plugin.sh" <<'EOF'
#!/bin/sh
cd "$(dirname "$0")/.." && mkdir -p poc/spa-droid/build && : > poc/spa-droid/build/libspa-droid.so
EOF
chmod 755 "$W/repo/tools/build-plugin.sh"

# --- stand-ins --------------------------------------------------------------
S=$W/stubs
mkdir -p "$S"
# sudo: the sandbox already is the only place anything can be written.
cat > "$S/sudo" <<'EOF'
#!/bin/sh
STUB_ROOT=1 exec "$@"
EOF
# id: root under sudo (audioctl migrate insists on it), the real user elsewhere
# (install.sh refuses root).
cat > "$S/id" <<'EOF'
#!/bin/sh
if [ -n "${STUB_ROOT:-}" ]; then
    case "$*" in -u) echo 0; exit 0 ;; -un) echo root; exit 0 ;; esac
fi
exec /usr/bin/id "$@"
EOF
# systemctl: every call logged; enable/disable/is-enabled/cat on real files.
cat > "$S/systemctl" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
user=0 verb= units=()
for a in "$@"; do
    case "$a" in
    --user|--global) user=1 ;;
    -*) ;;
    *) if [ -z "$verb" ]; then verb=$a; else units+=("$a"); fi ;;
    esac
done
if [ "$user" = 1 ]; then
    cfg=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
    path="$cfg /etc/systemd/user /usr/local/lib/systemd/user /usr/lib/systemd/user"
else
    cfg=/etc/systemd/system
    path="/etc/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system"
fi
find_unit() {
    local d
    for d in $path; do
        if [ -L "$d/$1" ] && [ "$(readlink "$d/$1")" = /dev/null ]; then return 1; fi
        [ -f "$d/$1" ] && { printf '%s' "$d/$1"; return 0; }
    done
    return 1
}
do_disable() {
    local l
    for l in "$cfg"/*.wants/"$1" "$cfg"/*; do
        [ -L "$l" ] || continue
        case "$l" in */"$1") [ "$(readlink "$l")" = /dev/null ] && continue ;;
                     *) [ "$(basename "$(readlink "$l")")" = "$1" ] || continue ;; esac
        rm -f "$l"
    done
}
do_enable() {
    local f t
    f=$(find_unit "$1") || { echo "Unit $1 not found or masked." >&2; return 1; }
    for t in $(sed -n 's/^WantedBy=//p' "$f"); do
        mkdir -p "$cfg/$t.wants" && ln -sf "$f" "$cfg/$t.wants/$1"
    done
    for t in $(sed -n 's/^Alias=//p' "$f"); do
        mkdir -p "$cfg" && ln -sf "$f" "$cfg/$t"
    done
}
rc=0
case "$verb" in
enable)    for u in "${units[@]}"; do do_enable "$u" || rc=1; done ;;
disable)   for u in "${units[@]}"; do do_disable "$u"; done ;;
reenable)  for u in "${units[@]}"; do do_disable "$u"; do_enable "$u" || rc=1; done ;;
is-enabled) for u in "${units[@]}"; do ls "$cfg"/*.wants/"$u" >/dev/null 2>&1 || rc=1; done ;;
is-active) rc=3 ;;
cat)       for u in "${units[@]}"; do f=$(find_unit "$u") && cat "$f" || rc=1; done ;;
esac
exit $rc
EOF
cat > "$S/pactl" <<'EOF'
#!/bin/sh
case "$*" in
"list sinks short") printf '0\tdroid-sink\tPipeWire\ts16le 2ch 48000Hz\tRUNNING\n' ;;
info) echo "Server Name: PulseAudio (on PipeWire 1.6.6)" ;;
esac
exit 0
EOF
# wpctl: "settings --save" is written where WirePlumber writes it.
cat > "$S/wpctl" <<'EOF'
#!/bin/sh
[ "$1" = settings ] && [ "$2" = --save ] || exit 1
f=${XDG_STATE_HOME:-$HOME/.local/state}/wireplumber/sm-settings
mkdir -p "$(dirname "$f")"
[ -e "$f" ] || echo '[sm-settings]' > "$f"
{ grep -v "^$3=" "$f"; printf '%s=%s\n' "$3" "$4"; } > "$f.new" && mv "$f.new" "$f"
EOF
for t in busctl pkill logger; do printf '#!/bin/sh\nexit 0\n' > "$S/$t"; done
chmod 755 "$S"/*

# --- the run, inside -------------------------------------------------------
cat > "$W/scenario.sh" <<'EOF'
#!/bin/bash
snap() {
    # type, mode, link target and content of everything the scripts can reach
    find /etc/systemd /usr/local /var/lib "$SPA" "$HOME" "$XDG_RUNTIME_DIR" /tmp \
        \( -path /var/lib/dpkg -o -path "$W" \) -prune -o -print 2>/dev/null \
    | sort | while IFS= read -r p; do
        if [ -L "$p" ]; then printf 'link %s -> %s\n' "$p" "$(readlink "$p")"
        elif [ -d "$p" ]; then printf 'dir  %s\n' "$p"
        else printf 'file %s %s %s\n' "$p" "$(stat -c %a "$p")" "$(md5sum < "$p" | cut -c1-12)"
        fi
    done
}
# Nothing outside may be writable, or this is not a sandbox.
if touch "$REAL_ROOT/.sandbox-probe" 2>/dev/null; then
    rm -f "$REAL_ROOT/.sandbox-probe"; echo "SANDBOX LEAKS"; exit 99
fi
R=$W/$ROUND
# The phone is not always the one FuriOS shipped. "modified" is one that
# somebody has already made their own - and each of these is something the old
# uninstall.sh destroyed or invented, because it restored from what it believed
# a phone looks like rather than from what this one looked like:
#   - WirePlumber enabled by hand, want and alias under ~/.config
#   - pulseaudio.socket masked by the user
#   - WirePlumber state of their own under ~/.local/state
#   - another repository's want next to ours (the old glob took furios-*)
#   - FuriOS' own wireplumber mask in /etc not there
#   - someone else's files in the directories we put ours into
if [ "$ROUND" = modified ]; then
    U=$HOME/.config/systemd/user
    mkdir -p "$U/pipewire.service.wants" "$U/default.target.wants" "$HOME/.local/state/wireplumber"
    ln -s /usr/lib/systemd/user/wireplumber.service "$U/pipewire.service.wants/wireplumber.service"
    ln -s /usr/lib/systemd/user/wireplumber.service "$U/pipewire-session-manager.service"
    ln -s /dev/null "$U/pulseaudio.socket"
    printf '[default-nodes]\ndefault.configured.audio.sink=mine\n' > "$HOME/.local/state/wireplumber/default-nodes"
    printf '[Service]\nExecStart=/bin/true\n[Install]\nWantedBy=default.target\n' > "$U/furios-gps-contribute.service"
    ln -s "$U/furios-gps-contribute.service" "$U/default.target.wants/furios-gps-contribute.service"
    rm -f /etc/systemd/user/wireplumber.service
    mkdir -p /usr/local/share/wireplumber/wireplumber.conf.d /etc/systemd/system/ofono.service.d
    echo '# not ours' > /usr/local/share/wireplumber/wireplumber.conf.d/60-user.conf
    printf '[Service]\nEnvironment=NOT_OURS=1\n' > /etc/systemd/system/ofono.service.d/10-other.conf
fi
snap > "$R/before"
cd "$W/repo"
./install.sh > "$R/install.log" 2>&1 || { echo "install.sh failed"; tail -20 "$R/install.log"; exit 1; }
snap > "$R/installed"
# A second install must not replace the record with what the first one made.
if [ "$ROUND" = modified ]; then
    ./install.sh > "$R/install2.log" 2>&1 || { echo "second install.sh failed"; tail -20 "$R/install2.log"; exit 1; }
fi
# Use: every profile once, as a phone would see them, with the helpers
# switched off and on again and the Bluetooth plugin fix run as WirePlumber
# would run it.
export VERIFY_TRIES=1 CALL_CARD_TRIES=1 CALLAUDIO_WARMUP=0
{ audioctl set pw-hal; audioctl bt-extras off; audioctl try pw-tunnel
  audioctl set pw-hal; audioctl bt-extras on; audioctl boot
  furios-audio-bluez5-fix
  # What tools/build-bluez5-aac.sh leaves: the module under the user's own
  # data directory (building it takes minutes and a network - a stand-in),
  # and the link the helper makes to it at the next WirePlumber start.
  aac="$HOME/.local/share/furios-audio/spa-0.2/bluez5"; mkdir -p "$aac"
  : > "$aac/libspa-codec-bluez5-aac.so"
  printf 'bluez5-build-id=%s\n' "$(furios-audio-bluez5-fix --build-id \
      "$(ls /usr/lib/*/spa-0.2/bluez5/libspa-bluez5.so | head -1)")" > "$aac/aac-built-for"
  furios-audio-bluez5-fix; } > "$R/use.log" 2>&1
snap > "$R/used"
case "$ROUND" in
modified)
    # The user edits one of ours after it was installed. It is theirs now.
    printf '[Service]\nExecStart=\nExecStart=/usr/sbin/ofonod --nodetach -d\n' \
        > /etc/systemd/system/ofono.service.d/30-furios-audio-hfp.conf ;;
norecord)
    # A phone set up by a version from before the record.
    rm -rf /var/lib/furios-audio-original "$HOME/.config/furios-audio/original" ;;
esac
./uninstall.sh > "$R/uninstall.log" 2>&1 || { echo "uninstall.sh failed"; tail -20 "$R/uninstall.log"; exit 1; }
snap > "$R/after"
EOF
chmod 755 "$W/scenario.sh"

# One round: a fresh copy of the pristine phone, the scenario inside it.
round() {
    local R=$W/$1
    mkdir -p "$R"
    cp -a "$P/." "$R/"
    bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /run --tmpfs /tmp \
        --bind "$W" "$W" \
        --bind "$R/etc-systemd" /etc/systemd \
        --bind "$R/usr-local" /usr/local \
        --bind "$R/var-lib" /var/lib --ro-bind /var/lib/dpkg /var/lib/dpkg \
        --bind "$R/spa" "$SPA" \
        --unshare-all --die-with-parent \
        --setenv HOME "$R/home" --setenv XDG_RUNTIME_DIR "$R/run-user" \
        --unsetenv XDG_CONFIG_HOME --unsetenv XDG_STATE_HOME --unsetenv XDG_CACHE_HOME \
        --unsetenv DBUS_SESSION_BUS_ADDRESS \
        --setenv PATH "$S:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        --setenv STUB_LOG "$R/systemctl.log" --setenv W "$W" --setenv SPA "$SPA" \
        --setenv REAL_ROOT "$ROOT" --setenv ROUND "$1" \
        --setenv DMNR_MARKER "$R/dmnr.persistent" \
        bash "$W/scenario.sh" 2>&1
}

# compare <round>: what is new after it, and what is gone or changed
compare() {
    left=$(comm -13 <(sort "$W/$1/before") <(sort "$W/$1/after"))
    gone=$(comm -23 <(sort "$W/$1/before") <(sort "$W/$1/after"))
}
show() {
    # show <label> <lines>
    [ -n "$2" ] && printf '%s\n' "$2" \
        | sed "s|$W/[a-z]*/home|~|; s|$W/[a-z]*/run-user|\$XDG_RUNTIME_DIR|; s/^/       $1 /"
    return 0
}
# a round that did not finish is the only finding worth reading
ran() {
    check "the sandbox ran the whole round" 0 "$1"
    [ "$1" = 0 ] && return 0
    printf '%s\n' "$out" | sed 's/^/       /'
    summary
    exit
}

echo "-- a phone as shipped: install, use, uninstall, in a sandbox"
out=$(round shipped)
ran $?

# Not vacuous: something has to have been installed and written for the
# comparison below to mean anything.
check "install.sh put audioctl in place" yes \
    "$(grep -q ' /usr/local/bin/audioctl ' "$W/shipped/installed" && echo yes || echo no)"
check "and audioctl wrote under \$HOME" yes \
    "$(grep -q "$W/shipped/home/.config/systemd/user" "$W/shipped/used" && echo yes || echo no)"
check "and the install took a record" yes \
    "$(grep -q ' /var/lib/furios-audio-original/meta/etc/systemd/user/furios-audio-apply.service.@ ' \
        "$W/shipped/installed" && echo yes || echo no)"

compare shipped
check "nothing install or use created is left behind" 0 "$(printf '%s' "$left" | grep -c .)"
show "left:" "$left"
check "nothing that was there before is gone or changed" 0 "$(printf '%s' "$gone" | grep -c .)"
show "was: " "$gone"

echo
echo "-- a phone somebody has made their own, installed twice"
out=$(round modified)
ran $?
compare modified
# Exactly one difference is expected: the drop-in the user rewrote after the
# install. It is theirs now, and the uninstall has to say so.
ours=/etc/systemd/system/ofono.service.d/30-furios-audio-hfp.conf
check "only the file the user changed after us is new" "$ours" \
    "$(printf '%s\n' "$left" | grep . | awk '{print $2}' | paste -sd' ' -)"
check "and the uninstall said it left it alone" yes \
    "$(grep -q "left alone - changed since furios_audio wrote it: $ours" "$W/modified/uninstall.log" \
       && echo yes || echo no)"
check "everything else is exactly as before - put back, not guessed" 0 "$(printf '%s' "$gone" | grep -c .)"
show "was: " "$gone"
show "left:" "$(printf '%s\n' "$left" | grep -v " $ours ")"

echo
echo "-- a phone an older version set up, without a record"
out=$(round norecord)
ran $?
compare norecord
check "the uninstall says there is no record, for the system" yes \
    "$(grep -q '^No record of the system files' "$W/norecord/uninstall.log" && echo yes || echo no)"
check "and for the user's own files" yes \
    "$(grep -q '^No record of your own files' "$W/norecord/uninstall.log" && echo yes || echo no)"
check "and still leaves nothing behind" 0 "$(printf '%s' "$left" | grep -c .)"
show "left:" "$left"
check "and takes nothing that was there" 0 "$(printf '%s' "$gone" | grep -c .)"
show "was: " "$gone"

summary
