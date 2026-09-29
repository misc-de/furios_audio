#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# What audioctl decides, given what the system tells it.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"

STUBDIR=$(mktemp -d)
trap 'rm -rf "$STUBDIR"' EXIT
export PATH="$STUBDIR:$PATH"

# When the coverage script asks for it, record which lines of audioctl run.
if [ -n "${AUDIOCTL_TRACE:-}" ]; then
    exec {trace_fd}>>"$AUDIOCTL_TRACE"
    export BASH_XTRACEFD=$trace_fd
    export PS4='+ ${BASH_SOURCE}:${LINENO}: '
    set -x
fi

# Source audioctl once, with tracing on if it was asked for. Every test that
# calls into it does so through this shell.
load_audioctl() {
    AUDIOCTL_LIB=1 . "$HERE/../audioctl"
}

# Nothing here is privileged any more: audioctl masks units and writes its
# drop-in under $HOME, and the tests point that at a temporary directory. What
# used to be a stand-in for pkexec plus furios-audio-helper is simply the real
# code now, running where it can do no harm.
export STUBDIR

# --- verify(): the safety net -----------------------------------------------
#
# This is the check that decides whether a profile switch stands or is rolled
# back. It used to accept any sink at all, including PipeWire's fallback
# auto_null - which exists precisely when no real device came up, so a plugin
# that failed to load passed the check and left the phone silent.

run_verify() {
    # run_verify <what pactl prints>
    make_stub pactl 0 "$1"
    ( AUDIOCTL_LIB=1 . "$HERE/../audioctl"
      # The real one waits 15 s for a sink; one pass is enough to test the
      # decision, and nobody wants a test suite that sleeps.
      verify_once() {
          pactl list sinks short 2>/dev/null | awk 'NF {print $2}' | grep -qvx auto_null
      }
      verify_once )
}

check_status "a real sink passes" 0 \
    run_verify "60	droid-sink	PipeWire	s16le 2ch 48000Hz	SUSPENDED"
check_status "the shipped PulseAudio sink passes" 0 \
    run_verify "1	sink.primary_output	module-droid-card.c	s16le 2ch 48000Hz	IDLE"
check_status "auto_null alone fails - it means no real device came up" 1 \
    run_verify "35	auto_null	PipeWire	float32le 2ch 48000Hz	SUSPENDED"
check_status "auto_null next to a real sink passes" 0 \
    run_verify "35	auto_null	PipeWire	float32le 2ch 48000Hz	SUSPENDED
60	droid-sink	PipeWire	s16le 2ch 48000Hz	SUSPENDED"
check_status "no sink at all fails" 1 run_verify ""
check_status "a stray blank line is not a sink" 1 run_verify "
"

# The system grep, not whatever the shell has aliased. A previous version of
# this check was tested against ugrep, whose -q -v means something else, and
# the result looked fine while being backwards.
check "audioctl uses plain grep, and /bin/grep is GNU grep" "ok" \
    "$(/bin/grep --version | head -1 | grep -q GNU && echo ok || echo "not GNU grep")"

# --- effective_profile(): what is actually running --------------------------
#
# The recorded profile can go stale - that once sent a call test at the wrong
# stack entirely. This reads reality off the running services instead.

run_effective() {
    # run_effective <active service name or "none">
    cat > "$STUBDIR/systemctl" <<STUB
#!/bin/sh
# systemctl --user is-active <unit>
[ "\$3" = "$1" ] && exit 0
exit 3
STUB
    chmod +x "$STUBDIR/systemctl"
    ( AUDIOCTL_LIB=1 . "$HERE/../audioctl"; effective_profile )
}

check "PulseAudio running means standard" "standard" "$(run_effective pulseaudio.service)"
check "pipewire-pulse running means pw-hal" "pw-hal" "$(run_effective pipewire-pulse.service)"
check "neither running is reported as unclear" "unclear" "$(run_effective none)"

# PulseAudio plus the tunnel service is the third profile, and the only case
# where two services have to be looked at rather than one.
cat > "$STUBDIR/systemctl" <<'STUB'
#!/bin/sh
case "$3" in
pulseaudio.service|furios-pw-tunnel.service) exit 0 ;;
esac
exit 3
STUB
chmod +x "$STUBDIR/systemctl"
check "PulseAudio with the tunnel running is pw-tunnel" "pw-tunnel" \
    "$( AUDIOCTL_LIB=1 . "$HERE/../audioctl"; effective_profile )"

# --- the profile list -------------------------------------------------------
check "the known profiles are exactly the three documented ones" \
    "standard pw-tunnel pw-hal" \
    "$( AUDIOCTL_LIB=1 . "$HERE/../audioctl"; printf '%s' "$PROFILES" )"


# --- everything below runs against stubs -----------------------------------
#
# audioctl only ever touches the system through a handful of commands, so the
# tests give it a PATH where those are scripts that answer whatever the case
# under test needs. Where it changes something, --dry-run is used: run() then
# prints the command instead of running it, which is exactly the seam a test
# wants.

stub_systemctl() {
    # stub_systemctl <unit that is active> [unit that is enabled]
    cat > "$STUBDIR/systemctl" <<STUB
#!/bin/sh
case "\$2" in
is-active)   [ "\$3" = "$1" ] && exit 0; exit 3 ;;
is-enabled)  [ "\$3" = "${2:-none}" ] && exit 0; exit 1 ;;
cat)         exit 0 ;;
esac
exit 0
STUB
    chmod +x "$STUBDIR/systemctl"
}

stub() {
    # stub <name> <exit> [output...]
    make_stub "$@"
}

# Run a snippet and keep all of its output, then look at it.
#
# Piping straight into "grep -q" would be shorter and wrong: grep leaves as
# soon as it matches, the writer gets SIGPIPE, and the rest of the function
# under test never runs. That has bitten this project once already, when
# piping audioctl through head killed it before it wrote its state.
says() {
    # says <snippet> <text it should contain>
    local out
    out=$(with_audioctl "$1" 2>&1)
    case "$out" in *"$2"*) echo yes ;; *) echo no ;; esac
}

with_audioctl() {
    # Run a snippet with audioctl's functions in scope and a temporary state
    # directory, so nothing writes to /var/lib.
    local snippet=$1
    ( set +u
      BT_HOLD_INTERVAL=0
      VERIFY_TRIES=1
      CALL_CARD_TRIES=1
      CALLAUDIO_WARMUP=0
      AUDIOCTL_LIB=1 . "$HERE/../audioctl"
      STATE_DIR="$STUBDIR/state"; STICKY="$STATE_DIR/profile"; TRY="$STATE_DIR/profile.try"
      # Derived from STATE_DIR when audioctl was read, so it would still name
      # the phone's own /var/lib/furios-audio - which is "on" here.
      BT_EXTRAS="$STATE_DIR/bt-extras"
      ETCU="$STUBDIR/etc"; DROPIN="$ETCU/pipewire.service.d/50-furios-audio.conf"
      WPUSER="$STUBDIR/wpuser"; WPOFF="$WPUSER/99-furios-droid-off.conf"
      LOCAL="$STUBDIR/local"
      BT_CODEC_SEEN="$STUBDIR/bt-codecs"
      BT_CODEC_PULSE="$STUBDIR/bt-codec-pulse"
      # The built plugin and PipeWire's modules, as a directory this suite
      # owns. Without them preflight refuses the pw-hal profile, and every
      # switch test below would only ever pass on a phone that happens to
      # have the real ones installed - which is how they failed on a runner
      # while passing here.
      PLUGIN_DIR="$STUBDIR/plugin"; PWMODULE_DIR="$PLUGIN_DIR"
      export AUDIOCTL_ETCU="$ETCU" AUDIOCTL_DROPIN="$DROPIN" \
             AUDIOCTL_WPCONF_DIR="$WPUSER" \
             AUDIOCTL_PLUGIN_DIR="$PLUGIN_DIR" AUDIOCTL_PW_MODULE_DIR="$PLUGIN_DIR"
      mkdir -p "$STATE_DIR" "$ETCU" "$WPUSER" "$LOCAL" "$PLUGIN_DIR"
      : > "$LOCAL/pipewire-hal.conf"
      : > "$PLUGIN_DIR/libspa-droid.so"
      : > "$PLUGIN_DIR/libpipewire-module-pulse-tunnel.so"
      eval "$snippet" )
}

# --- finding the files, wherever they were installed -----------------------
stub systemctl 0 ""
touch "$STUBDIR/exists"
check "it takes the first path that is there" "$STUBDIR/exists" \
    "$(with_audioctl 'first_existing /nowhere/a '"$STUBDIR"'/exists')"
check "and falls back to the first name when none is" "/nowhere/a" \
    "$(with_audioctl 'first_existing /nowhere/a /nowhere/b')"

# --- which profile is recorded ---------------------------------------------
check "with nothing recorded it is standard" "standard" \
    "$(with_audioctl 'current_profile')"
check "a persistent profile is read back" "pw-hal" \
    "$(with_audioctl 'echo pw-hal > "$STICKY"; current_profile')"
check "and a test profile wins over it" "pw-tunnel" \
    "$(with_audioctl 'echo pw-hal > "$STICKY"; echo pw-tunnel > "$TRY"; current_profile')"

# What comes out of a state file is not trusted. It used to be passed straight
# on to preflight(), which dies on a name it does not know - and the command
# that reads it is "audioctl boot", the one that runs at every single boot.
# A file that was truncated, half-written or left by an older version would
# have taken the safety net down with it.
check "a damaged state file falls back to standard" "standard" \
    "$(with_audioctl 'rm -f "$TRY"; echo "pw-h" > "$STICKY"; current_profile 2>/dev/null')"
check "and it says so rather than failing quietly" "yes" \
    "$(with_audioctl 'rm -f "$TRY"; echo "; rm -rf /" > "$STICKY"
                      current_profile 2>&1 >/dev/null | grep -q "not one of ours" && echo yes')"
check "an empty state file is standard, not the empty string" "standard" \
    "$(with_audioctl 'rm -f "$TRY"; : > "$STICKY"; current_profile')"
check "an empty test marker falls through to the stored profile" "pw-hal" \
    "$(with_audioctl 'echo pw-hal > "$STICKY"; : > "$TRY"; current_profile')"
check "apply() refuses anything that is not a profile" "yes" \
    "$(with_audioctl 'apply "nonsense" 2>&1 >/dev/null | grep -q "not a profile" && echo yes')"

# --- who holds the Pulse socket --------------------------------------------
stub pactl 0 "Server Name: PulseAudio (on PipeWire 1.6.6)"
check "the server names itself" "PulseAudio (on PipeWire 1.6.6)" \
    "$(with_audioctl 'pulse_owner')"
stub pactl 1 ""
check "and when nothing answers it says so" "not reachable" \
    "$(with_audioctl 'pulse_owner')"

# --- the version guards ----------------------------------------------------
#
# The plugin is built against one SPA interface. If an update moves past it,
# pw-hal goes silent with no message at all - so audioctl says so first.
stub pkg-config 0 "1.6.6"
check "a matching plugin version says nothing" "" \
    "$(with_audioctl 'plugin_version_check 2>&1')"
check "and a missing marker file is not an error" "" \
    "$(with_audioctl 'aac_version_check 2>&1')"

# --- the droid monitor is turned off in the user's own configuration --------
#
# The system file that declares the components is never touched - which is why
# none of this needs root. Turning the monitor off is a file of ours read after
# it; turning it on again is removing that file.
check "switching the monitor off writes a file of our own" "yes" \
    "$(with_audioctl 'droid_monitor off; [ -e "$WPOFF" ] && echo yes || echo no')"
check "and it disables the components rather than the file" "yes" \
    "$(with_audioctl 'droid_monitor off
        grep -q "monitor.droid = disabled" "$WPOFF" && echo yes || echo no')"
check "switching it on removes the file again" "no" \
    "$(with_audioctl 'droid_monitor off; droid_monitor on
        [ -e "$WPOFF" ] && echo yes || echo no')"
check "and switching off twice is not an error" "yes" \
    "$(with_audioctl 'droid_monitor off; droid_monitor off && echo yes || echo no')"

# --- preconditions ---------------------------------------------------------
check "standard needs nothing in place" "0" \
    "$(with_audioctl 'preflight standard >/dev/null 2>&1; echo $?')"
check "an unknown profile is refused by name" "yes" \
    "$(with_audioctl 'preflight nonsense 2>&1 | grep -q "unknown profile" && echo yes || echo no')"

# --- clients that must be restarted ----------------------------------------
#
# callaudiod and feedbackd hold a connection to the audio server; after a
# switch they find no card and the ringtone stays silent.
stub pkill 0 ""
# The phone card is there, as it is after every switch that works; what
# happens without one is checked further down.
stub pactl 0 "Card #61
	Name: droid
		voicecall: Voice Call (sinks: 1, sources: 1, priority: 50, available: yes)"
check "restarting the clients reports what it killed" "yes" \
    "$(with_audioctl 'restart_audio_clients | grep -q callaudiod && echo yes || echo no')"
stub pkill 1 ""
check "and says nothing when there was nothing to kill" "" \
    "$(with_audioctl 'restart_audio_clients')"

# callaudiod must not be restarted before the phone card is there: started
# early it finds no card and runs on without one (2026-09-25 18:14:45).
stub pactl 0 "Card #61
	Name: droid
	Profiles:
		default: Playback and Capture (sinks: 1, sources: 1, priority: 100, available: yes)
		voicecall: Voice Call (sinks: 1, sources: 1, priority: 50, available: yes)"
check "a card with a call profile is seen" "yes" \
    "$(with_audioctl 'wait_for_call_card && echo yes || echo no')"
check "and then it restarts without a word about waiting" "no" \
    "$(says 'restart_audio_clients' 'no card with a call profile')"
stub pactl 0 "Card #81
	Name: bluez_card.F4_9D_8A_00_00_01
	Profiles:
		a2dp-sink: High Fidelity Playback (A2DP Sink, codec AAC) (sinks: 1, sources: 1, priority: 133, available: yes)"
check "a headset alone is not a card callaudiod can use" "no" \
    "$(with_audioctl 'wait_for_call_card && echo yes || echo no')"
check "without one it says so, and still restarts" "yes" \
    "$(says 'restart_audio_clients' 'restarting callaudiod anyway')"

# Killing callaudiod is not enough: the call that starts it again must not be
# SelectMode, or it blocks for 25 seconds and the first call after a switch has
# no audio at all. So it is started here, with a method that asks nothing of
# it.
stub pkill 0 ""
make_recording_stub busctl 0 "u 0"
rm -f "$STUBDIR/busctl.args"
check "callaudiod is started again before anyone calls" "yes" \
    "$(with_audioctl 'restart_audio_clients >/dev/null; grep -q AudioMode "$STUBDIR/busctl.args" && echo yes || echo no')"
check "and it is only asked for its state, nothing more" "yes" \
    "$(with_audioctl 'restart_audio_clients >/dev/null; grep -q SelectMode "$STUBDIR/busctl.args" && echo no || echo yes')"
rm -f "$STUBDIR/busctl"
check "a phone without busctl is not held up by it" "yes" \
    "$(with_audioctl 'restart_audio_clients >/dev/null 2>&1 && echo yes || echo no')"
make_recording_stub busctl 1 ""
check "and neither is one where the service will not start" "yes" \
    "$(with_audioctl 'restart_audio_clients >/dev/null 2>&1 && echo yes || echo no')"

# --- what a switch writes, and where ---------------------------------------
#
# Nothing here asks for a password any more, because nothing here needs root:
# masks and the drop-in go under $HOME, which systemd reads before /etc. These
# used to be a stand-in for pkexec and a second one for the sudo fallback at
# boot; what is left is checking that the files land where they should.

check "masking writes a link to /dev/null under our own configuration" "yes" \
    "$(with_audioctl 'do_mask pulseaudio.service
        [ "$(readlink "$ETCU/pulseaudio.service")" = /dev/null ] && echo yes || echo no')"
check "and unmasking takes it away again" "no" \
    "$(with_audioctl 'do_mask pulseaudio.service; do_unmask pulseaudio.service
        [ -e "$ETCU/pulseaudio.service" ] && echo yes || echo no')"
check "a unit that is not ours is refused" "no" \
    "$(with_audioctl 'do_mask sshd.service 2>/dev/null && echo yes || echo no')"
check "and refusing it masks nothing" "no" \
    "$(with_audioctl 'do_mask sshd.service 2>/dev/null
        [ -e "$ETCU/sshd.service" ] && echo yes || echo no')"
check "unmasking leaves a real file somebody else put there alone" "yes" \
    "$(with_audioctl 'echo real > "$ETCU/pulseaudio.service"
        do_unmask pulseaudio.service
        [ -f "$ETCU/pulseaudio.service" ] && echo yes || echo no')"

check "the drop-in is written under our own configuration" "yes" \
    "$(with_audioctl 'dropin_write; grep -q "pipewire -c" "$DROPIN" && echo yes || echo no')"
check "and names the configuration it was told about" "yes" \
    "$(with_audioctl 'dropin_write
        grep -q "$LOCAL/pipewire-hal.conf" "$DROPIN" && echo yes || echo no')"
check "removing it is removing a file" "no" \
    "$(with_audioctl 'dropin_write; dropin_remove; [ -e "$DROPIN" ] && echo yes || echo no')"
check "without a configuration to point at, it refuses" "no" \
    "$(with_audioctl 'rm -f "$LOCAL/pipewire-hal.conf"
        dropin_write 2>/dev/null && echo yes || echo no')"

# --- what an older version left behind -------------------------------------
#
# A drop-in still sitting in /etc/systemd/user keeps applying, and audioctl can
# no longer remove it. It has to say so rather than quietly fight it.
check "leftovers in /etc are noticed" "yes" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/legacy"; mkdir -p "$LEGACY_ETCU/pipewire.service.d"
        : > "$LEGACY_ETCU/pipewire.service.d/50-furios-audio.conf"
        warn_about_legacy 2>&1 | grep -q "still wins" && echo yes || echo no')"
# A mask is not a leftover: FuriOS ships three of them, and a copy under $HOME
# gets past any mask. Calling them leftovers is what had them deleted.
check "a mask in /etc is not called a leftover" "" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/legacy-mask"; mkdir -p "$LEGACY_ETCU"
        ln -sf /dev/null "$LEGACY_ETCU/wireplumber.service"
        warn_about_legacy 2>&1')"
check "and a clean system says nothing" "" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/nothing-here"; warn_about_legacy 2>&1')"
check "migrating without root is refused" "yes" \
    "$(with_audioctl 'migrate_legacy 2>&1 | grep -q "as root" && echo yes || echo no')"

# And what it does when it IS root. "id" is a stub here: the alternative is a
# test that only runs for somebody who is willing to run a test suite as root,
# which is nobody, which is how this path would stay untested.
# "id -u" and "id -un" have to answer differently, which make_stub cannot do.
cat > "$STUBDIR/id" <<'IDEOF'
#!/bin/sh
case "${1:-}" in
-un) echo root ;;
-u)  echo 0 ;;
*)   echo "uid=0(root)" ;;
esac
IDEOF
chmod +x "$STUBDIR/id"
check "as root it still leaves a mask alone - it may be a package file" "yes" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/lg1"; mkdir -p "$LEGACY_ETCU"
        ln -sf /dev/null "$LEGACY_ETCU/pulseaudio.service"
        migrate_legacy >/dev/null 2>&1
        [ -e "$LEGACY_ETCU/pulseaudio.service" ] && echo yes || echo no')"
check "and the drop-in with it" "no" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/lg2"
        mkdir -p "$LEGACY_ETCU/pipewire.service.d"
        : > "$LEGACY_ETCU/pipewire.service.d/50-furios-audio.conf"
        migrate_legacy >/dev/null 2>&1
        [ -e "$LEGACY_ETCU/pipewire.service.d/50-furios-audio.conf" ] && echo yes || echo no')"
check "a monitor file moved aside is put back rather than deleted" "yes" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/lg3"; mkdir -p "$LEGACY_ETCU"
        d="$STUBDIR/usr/share/wireplumber/wireplumber.conf.d"; mkdir -p "$d"
        : > "$d/50-droid.conf.off"
        legacy_leftovers() { printf "%s" "$d/50-droid.conf.off"; }
        migrate_legacy >/dev/null 2>&1
        [ -e "$d/50-droid.conf" ] && echo yes || echo no')"
check "anything else is refused rather than removed" "yes" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/lg4"; mkdir -p "$LEGACY_ETCU"
        : > "$STUBDIR/innocent"
        legacy_leftovers() { printf "%s" "$STUBDIR/innocent"; }
        migrate_legacy >/dev/null 2>&1
        [ -e "$STUBDIR/innocent" ] && echo yes || echo no')"
check "with nothing left over it says so" "yes" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/lg5"
        migrate_legacy 2>&1 | grep -q "already migrated" && echo yes || echo no')"
rm -f "$STUBDIR/id"

# --- which leftovers actually defeat WHICH switch ---------------------------
#
# The distinction the first version of this did not make. "Is there anything
# left over" is the wrong question: standard masks pipewire-pulse and
# wireplumber itself, so finding those masked in /etc is what standard wants
# anyway. Refusing over them would block "audioctl revert" and "audioctl
# rescue" - the two commands that exist to get sound back - on a phone that
# had a leftover and no sound. The list below is therefore per profile.
lg_mask() {
    # lg_mask <dir> <unit>...  - a stub /etc/systemd/user with those masks
    local d=$1; shift
    mkdir -p "$d"
    local u; for u in "$@"; do ln -sf /dev/null "$d/$u"; done
}
lg_mask "$STUBDIR/b_std" pipewire-pulse.service pipewire-pulse.socket wireplumber.service
lg_mask "$STUBDIR/b_pul" pulseaudio.service pulseaudio.socket
lg_mask "$STUBDIR/b_none"

check "standard is not blocked by the masks FuriOS ships" "" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_std"; blocking_leftovers standard')"
check "and neither is pw-hal - a copy gets past them" "" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_std"; blocking_leftovers pw-hal')"
check "a masked pulseaudio does not block standard either" "" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_pul"; blocking_leftovers standard')"
check "a clean /etc blocks nothing" "" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_none"; blocking_leftovers pw-hal')"

# The drop-in keeps applying to pipewire from /etc. standard and pw-tunnel
# remove theirs and would be left with it; pw-hal writes its own under $HOME,
# which systemd reads first.
check "the drop-in in /etc blocks standard" "yes" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_dropin"
        mkdir -p "$LEGACY_ETCU/pipewire.service.d"
        : > "$LEGACY_ETCU/pipewire.service.d/50-furios-audio.conf"
        blocking_leftovers standard | grep -q 50-furios-audio && echo yes || echo no')"
check "and not pw-hal, which writes its own over it" "" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_dropin"; blocking_leftovers pw-hal')"

# A monitor renamed to .off is missing for pw-hal alone.
check "a droid monitor moved aside blocks pw-hal" "yes" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_none"
        d="$STUBDIR/wp-off/wireplumber.conf.d"; mkdir -p "$d"
        : > "$d/50-droid.conf.off"
        LEGACY_WP="$STUBDIR/wp-off"
        blocking_leftovers pw-hal | grep -q 50-droid && echo yes || echo no')"
check "and not standard, which masks wireplumber" "" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_none"
        d="$STUBDIR/wp-off/wireplumber.conf.d"; mkdir -p "$d"
        : > "$d/50-droid.conf.off"
        LEGACY_WP="$STUBDIR/wp-off"
        blocking_leftovers standard')"

# One source of truth: the check asks for the same list apply() unmasks. If
# these ever came apart, the check would pass and the switch would still fail.
check "every profile names the units it has to be able to start" "yes" \
    "$(with_audioctl 'ok=yes
        for p in $PROFILES; do [ -n "$(profile_unmasks "$p")" ] || ok=no; done
        echo $ok')"
check "and apply() takes its unmask list from there, not a second copy" "0" \
    "$(grep -c "^        unmask [a-z]" "$HERE/../audioctl")"

# --- and what a blocked switch does ----------------------------------------
#
# It used to warn and go ahead anyway: fifteen seconds of waiting for a sink
# that could not appear, then "standard restored" as the closing line. The
# cause was in the output, twelve lines above the part that looked like the
# verdict.
check "a blocked switch refuses" "1" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_none"
        d="$STUBDIR/wp-off/wireplumber.conf.d"; mkdir -p "$d"; : > "$d/50-droid.conf.off"
        LEGACY_WP="$STUBDIR/wp-off"
        check_legacy pw-hal sticky >/dev/null 2>&1; echo $?')"
check "and says what to run" "yes" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_none"
        d="$STUBDIR/wp-off/wireplumber.conf.d"; mkdir -p "$d"; : > "$d/50-droid.conf.off"
        LEGACY_WP="$STUBDIR/wp-off"
        check_legacy pw-hal sticky 2>&1 | grep -q "sudo audioctl migrate" && echo yes || echo no')"
check "and that it changed nothing" "yes" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_none"
        d="$STUBDIR/wp-off/wireplumber.conf.d"; mkdir -p "$d"; : > "$d/50-droid.conf.off"
        LEGACY_WP="$STUBDIR/wp-off"
        check_legacy pw-hal sticky 2>&1 | grep -q "Nothing has been changed" && echo yes || echo no')"
check "an unblocked switch is let through" "0" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_none"; LEGACY_WP="$STUBDIR/wp-none"
        check_legacy pw-hal sticky >/dev/null 2>&1; echo $?')"

# Never at boot. This runs at every login from furios-audio-apply.service and
# has to write the stored profile whatever is lying around - a phone that
# refuses to configure itself until somebody runs a command over ssh is worse
# off than one that warns.
check "boot is never refused, only warned" "0" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_none"
        d="$STUBDIR/wp-off/wireplumber.conf.d"; mkdir -p "$d"; : > "$d/50-droid.conf.off"
        LEGACY_WP="$STUBDIR/wp-off"
        check_legacy pw-hal boot >/dev/null 2>&1; echo $?')"
check "and it does warn" "yes" \
    "$(with_audioctl 'LEGACY_ETCU="$STUBDIR/b_none"
        d="$STUBDIR/wp-off/wireplumber.conf.d"; mkdir -p "$d"; : > "$d/50-droid.conf.off"
        LEGACY_WP="$STUBDIR/wp-off"
        check_legacy pw-hal boot 2>&1 | grep -q "still wins" && echo yes || echo no')"

# --- getting past a mask we must not remove --------------------------------
#
# furios-quirks-device ships wireplumber and pipewire-pulse masked in
# /etc/systemd/user. pw-hal gets past that with a plain copy under $HOME -
# a link does not work (systemd follows it into the mask), so a copy it is,
# marked, and rewritten from the original every time.
sh_setup='ETCU="$STUBDIR/sh-$1/home"; LEGACY_ETCU="$STUBDIR/sh-$1/etc"; mkdir -p "$ETCU" "$LEGACY_ETCU"
        VENDOR_UNITS="$STUBDIR/sh-$1/vendor"; mkdir -p "$VENDOR_UNITS"
        printf "[Service]\nExecStart=/usr/bin/wireplumber\n" > "$VENDOR_UNITS/wireplumber.service"'
shadow_case() { with_audioctl "set -- $1; $sh_setup
        $2"; }
check "a unit masked in /etc gets a copy under \$HOME" "yes" \
    "$(shadow_case a 'ln -sf /dev/null "$LEGACY_ETCU/wireplumber.service"
        do_unmask wireplumber.service
        [ -f "$ETCU/wireplumber.service" ] && [ ! -L "$ETCU/wireplumber.service" ] \
            && grep -q "^ExecStart=/usr/bin/wireplumber" "$ETCU/wireplumber.service" && echo yes || echo no')"
check "marked as ours" "yes" \
    "$(shadow_case b 'ln -sf /dev/null "$LEGACY_ETCU/wireplumber.service"
        do_unmask wireplumber.service
        is_shadow "$ETCU/wireplumber.service" && echo yes || echo no')"
check "and the mask in /etc is left where it is" "/dev/null" \
    "$(shadow_case c 'ln -sf /dev/null "$LEGACY_ETCU/wireplumber.service"
        do_unmask wireplumber.service; readlink "$LEGACY_ETCU/wireplumber.service"')"
check "an unmasked system gets no copy" "no" \
    "$(shadow_case d 'do_unmask wireplumber.service
        [ -e "$ETCU/wireplumber.service" ] && echo yes || echo no')"
check "the copy follows the original after an update" "yes" \
    "$(shadow_case e 'ln -sf /dev/null "$LEGACY_ETCU/wireplumber.service"
        do_unmask wireplumber.service
        printf "[Service]\nExecStart=/usr/bin/wireplumber --new\n" > "$VENDOR_UNITS/wireplumber.service"
        do_unmask wireplumber.service
        grep -q -- "--new" "$ETCU/wireplumber.service" && echo yes || echo no')"
check "a file somebody else put there is refused and kept" "mine" \
    "$(shadow_case f 'ln -sf /dev/null "$LEGACY_ETCU/wireplumber.service"
        echo mine > "$ETCU/wireplumber.service"
        do_unmask wireplumber.service 2>/dev/null; cat "$ETCU/wireplumber.service"')"
check "without an original to copy it fails rather than pretending" "1" \
    "$(shadow_case g 'ln -sf /dev/null "$LEGACY_ETCU/wireplumber.service"
        rm -f "$VENDOR_UNITS/wireplumber.service"
        do_unmask wireplumber.service 2>/dev/null; echo $?')"
check "masking again replaces the copy with our own mask" "/dev/null" \
    "$(shadow_case h 'ln -sf /dev/null "$LEGACY_ETCU/wireplumber.service"
        do_unmask wireplumber.service; do_mask wireplumber.service
        readlink "$ETCU/wireplumber.service"')"

# --- the safety net --------------------------------------------------------
stub_systemctl none none
check "the safety net is enabled on the first switch" "yes" \
    "$(with_audioctl 'ensure_safety_net | grep -q "safety net" && echo yes || echo no')"
stub_systemctl none furios-audio-apply.service
check "and left alone once it is" "" "$(with_audioctl 'ensure_safety_net')"
stub_systemctl none none
check "pausing on disconnect is enabled the same way" "yes" \
    "$(with_audioctl 'ensure_pause_on_disconnect | grep -q pauses && echo yes || echo no')"

# --- applying a profile ----------------------------------------------------
#
# With --dry-run nothing is executed, so what the switch *would* do can be read
# off instead of done.
apply_dry() {
    with_audioctl "DRY=1; apply $1 2>&1"
}
check "standard unmasks PulseAudio" "yes" \
    "$(apply_dry standard | grep -q 'pulseaudio.socket' && echo yes || echo no)"
check "standard masks pipewire-pulse" "yes" \
    "$(apply_dry standard | grep -q 'pipewire-pulse.service' && echo yes || echo no)"
check "pw-hal stops PulseAudio" "yes" \
    "$(apply_dry pw-hal | grep -q 'stop pulseaudio' && echo yes || echo no)"
check "pw-hal writes the systemd drop-in" "yes" \
    "$(apply_dry pw-hal | grep -q 'pipewire-hal.conf' && echo yes || echo no)"
check "pw-tunnel keeps PulseAudio and starts the tunnel" "yes" \
    "$(apply_dry pw-tunnel | grep -q 'furios-pw-tunnel' && echo yes || echo no)"

# WirePlumber is WantedBy=pipewire.service, so it only ever comes up at a boot
# if the want has been written. Starting it by hand looks identical for as long
# as the session lasts and leaves the next boot without a session manager.
check "pw-hal enables WirePlumber and does not only start it" "yes" \
    "$(apply_dry pw-hal | grep -q 'enable wireplumber.service' && echo yes || echo no)"
check "the tunnel needs the session manager just as much" "yes" \
    "$(apply_dry pw-tunnel | grep -q 'enable wireplumber.service' && echo yes || echo no)"
check "and standard takes the want away again" "yes" \
    "$(apply_dry standard | grep -q 'disable wireplumber.service' && echo yes || echo no)"

# --- the ports of whichever stack is running -------------------------------
stub pactl 0 "Sink #1
	Name: droid-sink
	Active Port: output-speaker

Source #2
	Name: droid-source
	Active Port: input-builtin_mic
"
check "the active output port is read" "output-speaker" \
    "$(with_audioctl 'port_of sinks "droid-sink sink.primary_output"')"
check "an unknown node reports a question mark" "?" \
    "$(with_audioctl 'port_of sinks "nothing-here"')"
check "and both directions are reported together" "output-speaker / input-builtin_mic" \
    "$(with_audioctl 'active_ports')"

stub pactl 0 "Card #1
	Name: droid
	Active Profile: voicecall
"
check "the card profile is read" "voicecall" "$(with_audioctl 'droid_profile')"

# --- the emergency handle --------------------------------------------------
#
# Born from a failed Bluetooth test that left the phone on the earpiece at
# 18 %: everything running, nothing audible.
stub pactl 0 ""
check "rescue reports what it restored" "yes" \
    "$(with_audioctl 'rescue no | grep -q "speaker, 65" && echo yes || echo no')"

# --- putting a call on a headset -------------------------------------------
stub logger 0 ""
stub pactl 0 ""
check "bt-call refuses a word it does not know" "yes" \
    "$(with_audioctl 'bt_call nonsense 2>&1 | grep -q "needs" && echo yes || echo no')"
check "with no headset connected it says so" "yes" \
    "$(with_audioctl 'bt_call on 2>&1 | grep -q "no Bluetooth device" && echo yes || echo no')"

stub pactl 0 "1	bluez_card.AA_BB	module-bluez5-device.c"
check "the headset profile is set when one is there" "yes" \
    "$(with_audioctl 'bt_headset_profile bluez_card.AA_BB headset 2>&1 | grep -q "headset profile" && echo yes || echo no')"
check "and a card that is not there is refused" "1" \
    "$(with_audioctl 'bt_headset_profile "" headset >/dev/null 2>&1; echo $?')"

# --- switching, end to end -------------------------------------------------
#
# preflight wants a wireplumber before it lets pw-hal through. On the phone
# there is one; on a runner there is not, and without this stub every check
# below was answering a question about the machine rather than about audioctl.
stub wireplumber 0 ""
#
# switch_to is where the safety net actually fires: it applies a profile, waits
# for a sink, and rolls back to standard if none appears. Both endings matter.

stub_systemctl none none
stub pactl 0 "60	droid-sink	PipeWire	s16le 2ch 48000Hz	SUSPENDED"
stub pkill 1 ""
check "a switch that finds a sink records the profile" "pw-hal" \
    "$(with_audioctl 'switch_to pw-hal sticky >/dev/null 2>&1; cat "$STICKY"')"
check "a test switch records it as temporary instead" "yes" \
    "$(with_audioctl 'switch_to pw-hal try >/dev/null 2>&1; [ -f "$TRY" ] && echo yes || echo no')"
check "and it says what to check afterwards" "yes" \
    "$(with_audioctl 'switch_to pw-hal try 2>&1 | grep -q "check telephony" && echo yes || echo no')"
check "a dry run changes nothing" "yes" \
    "$(with_audioctl 'DRY=1; switch_to pw-hal sticky 2>&1 | grep -q "nothing changed" && echo yes || echo no')"
# The package leaves the state directory root's when it finds nobody to give
# it to. The switch still happens; what must not happen is "set persistently"
# over a file that was never written.
persist_out=$(with_audioctl 'mkdir -p "$STATE_DIR"; rm -f "$TRY"; echo standard > "$STICKY"; chmod 555 "$STATE_DIR"; chmod 444 "$STICKY"
    switch_to pw-hal sticky 2>&1; echo "rc=$?"; chmod 755 "$STATE_DIR"; chmod 644 "$STICKY"')
check "a profile that cannot be stored is not reported as stored" "no" \
    "$(printf '%s' "$persist_out" | grep -q "set persistently" && echo yes || echo no)"
check "it says the next reboot goes back" "yes" \
    "$(printf '%s' "$persist_out" | grep -q "next reboot goes back to 'standard'" && echo yes || echo no)"
check "and the command fails" "yes" \
    "$(printf '%s' "$persist_out" | grep -q "rc=1" && echo yes || echo no)"

# No sink at all: the switch has to undo itself rather than leave a silent
# phone behind. This is the one path nobody wants to discover in the field.

# rescue returning to its caller, rather than through the fallback path.
check "rescue comes back when it is done" "0" \
    "$(with_audioctl 'rescue no >/dev/null 2>&1; echo $?')"

stub pactl 0 "35	auto_null	PipeWire	float32le 2ch 48000Hz	SUSPENDED"
check "a switch that produces only auto_null falls back" "yes" \
    "$(with_audioctl 'VERIFY_TRIES=1; switch_to pw-hal try 2>&1 | grep -q "Falling back" && echo yes || echo no')"
check "and the test marker is cleared when it does" "no" \
    "$(with_audioctl 'VERIFY_TRIES=1; switch_to pw-hal try >/dev/null 2>&1; [ -f "$TRY" ] && echo yes || echo no')"

# --- the version guards, when they disagree --------------------------------
stub pkg-config 0 "1.7.0"
check "a plugin built against another PipeWire is called out" "yes" \
    "$(with_audioctl 'PLUGIN_DIR="$STUBDIR"; echo 1.6.6 > "$STUBDIR/built-against"
        plugin_version_check 2>&1 | grep -q "WARNING" && echo yes || echo no')"
# The AAC module lives wherever pkg-config says PipeWire's libdir is, so the
# stub points that at the temporary directory.
cat > "$STUBDIR/pkg-config" <<STUB
#!/bin/sh
case "\$1" in
--variable=libdir) echo "$STUBDIR" ;;
*) echo 1.7.0 ;;
esac
STUB
chmod +x "$STUBDIR/pkg-config"
mkdir -p "$STUBDIR/spa-0.2/bluez5"
echo 1.6.6 > "$STUBDIR/spa-0.2/bluez5/aac-built-against"
check "and so is the AAC module" "yes" \
    "$(with_audioctl 'aac_version_check 2>&1 | grep -q "NOTE" && echo yes || echo no')"

# --- holding a route against callaudiod ------------------------------------
stub logger 0 ""
stub pactl 0 "Sink #1
	Name: droid-sink
	Active Port: output-bluetooth_sco
"
# The waiting half of watch: the call has not started yet, so it sleeps and
# looks again. The stub reports an ordinary profile twice, then the call.
cat > "$STUBDIR/pactl" <<STUB
#!/bin/sh
COUNT=\$(cat "$STUBDIR/waitcount" 2>/dev/null || echo 0)
echo \$((COUNT + 1)) > "$STUBDIR/waitcount"
case "\$*" in
*"list short cards"*) printf '1\tbluez_card.AA_BB\tmodule-bluez5-device.c\n' ;;
*"list cards"*)
    if [ "\$COUNT" -lt 2 ]; then
        printf 'Card #1\n\tName: droid\n\tActive Profile: default\n'
    elif [ "\$COUNT" -lt 4 ]; then
        printf 'Card #1\n\tName: droid\n\tActive Profile: voicecall\n'
    else
        printf 'Card #1\n\tName: droid\n\tActive Profile: default\n'
    fi ;;
*"list sinks"*)   printf 'Sink #1\n\tName: droid-sink\n\tActive Port: output-bluetooth_sco\n' ;;
*"list sources"*) printf 'Source #2\n\tName: droid-source\n\tActive Port: input-bluetooth_sco_headset\n' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/pactl"
rm -f "$STUBDIR/waitcount"
check "watch waits for the call rather than acting at once" "yes" \
    "$(says 'bt_call watch' 'waiting for a call')"

check "a route that is still where it belongs is left alone" "0" \
    "$(with_audioctl 'bt_hold output-bluetooth_sco input-bluetooth_sco_headset 1 >/dev/null 2>&1; echo $?')"
check "setting both ports reports what took" "yes" \
    "$(with_audioctl 'bt_set_ports output-bluetooth_sco input-bluetooth_sco_headset 2>&1 | grep -q "actually active" && echo yes || echo no')"

# --- bt-call, all three words ----------------------------------------------
#
# The card and the profile come from pactl, so the stub decides what the call
# sees. "watch" waits for the phone card to enter the voicecall profile - here
# it already has, so it goes straight through.
cat > "$STUBDIR/pactl" <<'STUB'
#!/bin/sh
case "$*" in
*"list short cards"*) printf '1	bluez_card.AA_BB	module-bluez5-device.c
' ;;
*"list cards"*)       printf 'Card #1
	Name: droid
	Active Profile: voicecall
' ;;
*"list sinks"*)       printf 'Sink #1
	Name: droid-sink
	Active Port: output-bluetooth_sco
' ;;
*"list sources"*)     printf 'Source #2
	Name: droid-source
	Active Port: input-bluetooth_sco_headset
' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/pactl"

check "bt-call on puts the call on the headset" "yes" \
    "$(says 'bt_call on' 'Back with')"
check "bt-call off brings it back to the phone" "yes" \
    "$(says 'bt_call off' 'output-earpiece set')"
check "bt-call watch acts as soon as the call is there" "yes" \
    "$(says 'bt_call watch' 'call detected')"

# A route that has moved away is set again - callaudiod does that mid-call.
cat > "$STUBDIR/pactl" <<'STUB'
#!/bin/sh
case "$*" in
*"list short cards"*) printf '1	bluez_card.AA_BB	module-bluez5-device.c
' ;;
*"list cards"*)       printf 'Card #1
	Name: droid
	Active Profile: voicecall
' ;;
*"list sinks"*)       printf 'Sink #1
	Name: droid-sink
	Active Port: output-earpiece
' ;;
*"list sources"*)     printf 'Source #2
	Name: droid-source
	Active Port: input-builtin_mic
' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/pactl"
check "a route pulled back to the earpiece is set again" "yes" \
    "$(with_audioctl 'bt_hold output-bluetooth_sco input-bluetooth_sco_headset 1 2>&1 | grep -q "setting it again" && echo yes || echo no')"

# The headset offers no wideband profile: the narrowband one is taken instead.
cat > "$STUBDIR/pactl" <<'STUB'
#!/bin/sh
case "$*" in
*"set-card-profile"*headset-head-unit-cvsd*) exit 0 ;;
*"set-card-profile"*headset-head-unit*)      exit 1 ;;
*"list cards"*) printf 'Card #1
	Name: bluez_card.AA_BB
	Active Profile: a2dp-sink
' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/pactl"
check "the narrowband profile is used when the other is refused" "yes" \
    "$(with_audioctl 'bt_headset_profile bluez_card.AA_BB headset 2>&1 | grep -q narrowband && echo yes || echo no')"

cat > "$STUBDIR/pactl" <<'STUB'
#!/bin/sh
case "$*" in
*"set-card-profile"*) exit 1 ;;
*"list cards"*) printf 'Card #1
	Name: bluez_card.AA_BB
	Active Profile: off
' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/pactl"
check "and a headset that refuses both is reported" "yes" \
    "$(with_audioctl 'bt_headset_profile bluez_card.AA_BB headset 2>&1 | grep -q "WARNING" && echo yes || echo no')"

# The way back used to be assumed. A card that has lost its A2DP profiles -
# which happens when WirePlumber restarts while Bluetooth is connected -
# answers "No such entity" here, and this returned 0 anyway: the headset stays
# hands-free, every later track plays mono at 16 kHz, and nothing says why.
cat > "$STUBDIR/pactl" <<'STUB'
#!/bin/sh
case "$*" in
*"set-card-profile"*a2dp-sink*) exit 1 ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/pactl"
check "a headset that cannot go back to A2DP says so" "yes" \
    "$(with_audioctl 'bt_headset_profile bluez_card.AA_BB a2dp 2>&1 | grep -q "stays in hands-free" && echo yes || echo no')"
check "and names the cure with the address filled in" "yes" \
    "$(with_audioctl 'bt_headset_profile bluez_card.AA_BB a2dp 2>&1 | grep -q "bluetoothctl connect AA:BB" && echo yes || echo no')"
check "and reports the failure rather than a quiet success" "1" \
    "$(with_audioctl 'bt_headset_profile bluez_card.AA_BB a2dp >/dev/null 2>&1; echo $?')"

cat > "$STUBDIR/pactl" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$STUBDIR/pactl"
check "a headset that does go back says nothing" "0" \
    "$(with_audioctl 'bt_headset_profile bluez_card.AA_BB a2dp >/dev/null 2>&1; echo $?')"
cat > "$STUBDIR/pactl" <<'STUB'
#!/bin/sh
case "$*" in
*set-sink-port*|*set-source-port*) exit 1 ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/pactl"
check "setting a port that will not take is reported too" "yes" \
    "$(with_audioctl 'bt_set_ports output-bluetooth_sco input-x 2>&1 | grep -q "ERROR" && echo yes || echo no')"

# --- bt-mic: the headset's microphone outside a call -----------------------
#
# The sequence has three steps that all have to land, and the order matters:
# the codec goes to the NODES (the card cannot carry it) and it has to be
# there before the route, because the route is what makes the HAL open the
# stream and read it.

# The Bluetooth node carries the codec BlueZ negotiated; $BT_CODEC is what
# this stub says it is, so a test can be a wide-band headset or a narrow-band
# car without either being present.
cat > "$STUBDIR/pw-cli" <<'STUB'
#!/bin/sh
case "$*" in
*"ls Node"*) printf '	id 60, type PipeWire:Interface:Node/3
 		node.name = "droid-sink"
	id 61, type PipeWire:Interface:Node/3
 		node.name = "droid-source"
	id 62, type PipeWire:Interface:Node/3
 		node.name = "bluez_output.AA_BB.1"
 		api.bluez5.codec = "%s"
' "${BT_CODEC:-}" ;;
*"set-param"*) printf '%s\n' "$*" >> "$STUBDIR/setparam.log" ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/pw-cli"

check "a node is found by name, not by position" "61" \
    "$(with_audioctl 'bt_node_id droid-source')"
check "and a name that is not there comes back empty" "" \
    "$(with_audioctl 'bt_node_id droid-nothing')"

rm -f "$STUBDIR/setparam.log"
export BT_CODEC=msbc
check "a wide-band link tells the HAL bt_wbs=on" "yes" \
    "$(with_audioctl 'bt_tell_codec headset-head-unit 2>&1 | grep -q "bt_wbs=on" && echo yes || echo no')"
check "and it tells both nodes, because either may open the stream" "2" \
    "$(grep -c 'droid.bt-wbs' "$STUBDIR/setparam.log" 2>/dev/null || echo 0)"
BT_CODEC=cvsd
check "a narrow-band link tells it off instead" "yes" \
    "$(with_audioctl 'bt_tell_codec headset-head-unit 2>&1 | grep -q "bt_wbs=off" && echo yes || echo no')"
unset BT_CODEC

# The name of the plain hands-free profile says nothing about the codec - it
# is whichever one the two ends agreed on. Reading it as wide-band is what
# left a call in a car silent in both directions on 2026-09-18.
rm -f "$STUBDIR/setparam.log"
check "the plain profile name alone is not read as wide-band" "yes" \
    "$(with_audioctl 'bt_tell_codec headset-head-unit 2>&1 | grep -q "keeps its default" && echo yes || echo no')"
check "and nothing is sent when the codec is unknown" "0" \
    "$(grep -c 'droid.bt-wbs' "$STUBDIR/setparam.log" 2>/dev/null || echo 0)"

# A per-codec profile does carry it in its name, and that is the last resort
# when the link cannot be read.
check "a profile that names its codec is read from its name" "yes" \
    "$(with_audioctl 'bt_tell_codec headset-head-unit-cvsd 2>&1 | grep -q "bt_wbs=off" && echo yes || echo no')"

# A codec bt_wbs has no word for is not rounded to the nearest one.
rm -f "$STUBDIR/setparam.log"
export BT_CODEC=lc3_swb
check "a codec bt_wbs cannot express is not guessed at" "yes" \
    "$(with_audioctl 'bt_tell_codec headset-head-unit 2>&1 | grep -q "keeps its default" && echo yes || echo no')"
unset BT_CODEC
check "and nothing is sent for it either" "0" \
    "$(grep -c 'droid.bt-wbs' "$STUBDIR/setparam.log" 2>/dev/null || echo 0)"

# The hold has to outlive the audioctl that starts it - without setsid it dies
# with the command and the recording comes back silent.
check "the hold is started detached from this shell" "yes" \
    "$(grep -q 'setsid timeout' "$HERE/../audioctl" && echo yes || echo no)"

cat > "$STUBDIR/pactl" <<'STUB'
#!/bin/sh
case "$*" in
*"list short cards"*) printf '1	bluez_card.AA_BB	module-bluez5-device.c
' ;;
*"list short sinks"*) printf '1	bluez_output.AA_BB.1	PipeWire	s16le 2ch 48000Hz	SUSPENDED
' ;;
*"list cards"*) printf 'Card #1
	Name: bluez_card.AA_BB
	Active Profile: headset-head-unit
' ;;
*"list sinks"*)   printf 'Sink #1
	Name: droid-sink
	Active Port: output-speaker
' ;;
*"list sources"*) printf 'Source #2
	Name: droid-source
	Active Port: input-bluetooth_sco_headset
' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/pactl"
stub paplay 0 ""

check "the active profile is read off the card" "headset-head-unit" \
    "$(with_audioctl 'bt_active_profile bluez_card.AA_BB')"

check "the hold writes down the pid it started" "yes" \
    "$(with_audioctl 'XDG_RUNTIME_DIR="$STUBDIR"; bt_sco_hold_start 1 >/dev/null 2>&1; [ -s "$STUBDIR/furios-audio-sco-hold.pid" ] && echo yes || echo no')"
check "and stopping it takes the file away again" "no" \
    "$(with_audioctl 'XDG_RUNTIME_DIR="$STUBDIR"; bt_sco_hold_start 1 >/dev/null 2>&1; bt_sco_hold_stop >/dev/null 2>&1; [ -e "$STUBDIR/furios-audio-sco-hold.pid" ] && echo yes || echo no')"
check "a hold with nowhere to write its pid says so" "yes" \
    "$(with_audioctl 'unset XDG_RUNTIME_DIR; bt_sco_hold_start 1 2>&1 | grep -q "XDG_RUNTIME_DIR" && echo yes || echo no')"

# No Bluetooth sink means nothing can hold the link open, and the recording
# would be silence - better said out loud than found in the numbers.
cat > "$STUBDIR/pactl.nosink" <<'STUB'
#!/bin/sh
case "$*" in
*"list short sinks"*) exit 0 ;;
esac
exit 0
STUB
check "a hold with no Bluetooth sink to play into says so" "yes" \
    "$(cp "$STUBDIR/pactl.nosink" "$STUBDIR/pactl"; chmod +x "$STUBDIR/pactl"
       with_audioctl 'XDG_RUNTIME_DIR="$STUBDIR"; bt_sco_hold_start 1 2>&1 | grep -q "no Bluetooth sink" && echo yes || echo no')"

cat > "$STUBDIR/pactl" <<'STUB'
#!/bin/sh
case "$*" in
*"list short cards"*) printf '1	bluez_card.AA_BB	module-bluez5-device.c
' ;;
*"list short sinks"*) printf '1	bluez_output.AA_BB.1	PipeWire	s16le 2ch 48000Hz	SUSPENDED
' ;;
*"list cards"*) printf 'Card #1
	Name: bluez_card.AA_BB
	Active Profile: headset-head-unit
' ;;
*"list sinks"*)   printf 'Sink #1
	Name: droid-sink
	Active Port: output-speaker
' ;;
*"list sources"*) printf 'Source #2
	Name: droid-source
	Active Port: input-bluetooth_sco_headset
' ;;
esac
exit 0
STUB
chmod +x "$STUBDIR/pactl"

check "bt-mic on routes the phone's input to the headset" "yes" \
    "$(with_audioctl 'XDG_RUNTIME_DIR="$STUBDIR"; bt_mic on 2>&1 | grep -q "input-bluetooth_sco_headset set" && echo yes || echo no')"
check "and says how to get back" "yes" \
    "$(with_audioctl 'XDG_RUNTIME_DIR="$STUBDIR"; bt_mic on 2>&1 | grep -q "bt-mic off" && echo yes || echo no')"
check "bt-mic off gives the phone its own microphone again" "yes" \
    "$(with_audioctl 'XDG_RUNTIME_DIR="$STUBDIR"; bt_mic off 2>&1 | grep -q "input-builtin_mic set" && echo yes || echo no')"
check "its log lines name bt-mic, not the call path they share" "yes" \
    "$(with_audioctl 'XDG_RUNTIME_DIR="$STUBDIR"; bt_mic on 2>&1 | grep -q "bt-mic: headset profile" && echo yes || echo no')"
check "and bt-call still names itself in the same helpers" "yes" \
    "$(with_audioctl 'bt_headset_profile bluez_card.AA_BB headset 2>&1 | grep -q "bt-call: headset profile" && echo yes || echo no')"

stub pactl 0 ""
check "bt-mic on without a headset connected says so" "yes" \
    "$(with_audioctl 'bt_mic on 2>&1 | grep -q "no Bluetooth device" && echo yes || echo no')"
check "and a word it does not know is refused" "yes" \
    "$(with_audioctl 'bt_mic nonsense 2>&1 | grep -q "needs" && echo yes || echo no')"

# --- the measurement, which is the only thing that settles it --------------
#
# A route can land on the wrong device and the recording still runs, over
# silence, looking like success. So the number that decides is how many
# distinct sample values came back.
cat > "$STUBDIR/pw-record" <<'STUB'
#!/bin/sh
# Write to the last argument whatever MIC_FIXTURE says: silence or speech.
out=""
for a in "$@"; do out=$a; done
if [ "${MIC_FIXTURE:-silence}" = silence ]; then
    head -c 3200 /dev/zero > "$out"
else
    head -c 3200 /dev/urandom > "$out"
fi
exit 0
STUB
chmod +x "$STUBDIR/pw-record"

check "digital silence is called what it is" "yes" \
    "$(with_audioctl 'MIC_FIXTURE=silence bt_mic_measure 1 2>&1 | grep -q "digital silence" && echo yes || echo no')"
check "and it fails, so a script cannot mistake it for a recording" "2" \
    "$(with_audioctl 'MIC_FIXTURE=silence bt_mic_measure 1 >/dev/null 2>&1; echo $?')"
check "a real signal is reported with its level" "yes" \
    "$(with_audioctl 'MIC_FIXTURE=speech bt_mic_measure 1 2>&1 | grep -q "distinct values" && echo yes || echo no')"
check "and a real signal succeeds" "0" \
    "$(with_audioctl 'MIC_FIXTURE=speech bt_mic_measure 1 >/dev/null 2>&1; echo $?')"

# A test taken with no hold is silence whatever the microphone does, and it
# looks exactly like a broken headset. Say so before the number appears.
# Collected whole and then searched, rather than piped into grep -q: -q closes
# the pipe on its first match, bt_mic dies of SIGPIPE right after the warning,
# and the measurement below it never runs - so the warning would be all this
# test ever proved.
mic_out=$(with_audioctl 'XDG_RUNTIME_DIR="$STUBDIR"; rm -f "$STUBDIR/furios-audio-sco-hold.pid"; MIC_FIXTURE=silence bt_mic test 1 2>&1')
check "a test with no hold warns before it measures" "yes" \
    "$(printf '%s' "$mic_out" | grep -q "nothing is holding the link open" && echo yes || echo no)"
# And it measures anyway. The warning explains a silent recording; refusing to
# record would leave nothing to explain.
check "and it measures all the same" "yes" \
    "$(printf '%s' "$mic_out" | grep -q "Recording 1 s" && echo yes || echo no)"
check "the number arrives after the warning" "yes" \
    "$(printf '%s' "$mic_out" | grep -qE "digital silence|distinct value" && echo yes || echo no)"
# bt_mic_measure fails on silence so that a script can tell; the command that
# wraps it used to clear its trap first and then return that trap's 0.
check "and bt-mic test fails on silence as the measurement does" "2" \
    "$(with_audioctl 'XDG_RUNTIME_DIR="$STUBDIR"; MIC_FIXTURE=silence bt_mic test 1 >/dev/null 2>&1; echo $?')"
check "while a real signal passes" "0" \
    "$(with_audioctl 'XDG_RUNTIME_DIR="$STUBDIR"; MIC_FIXTURE=speech bt_mic test 1 >/dev/null 2>&1; echo $?')"

# --- preflight, when something is missing ----------------------------------
check "pw-tunnel without its module is refused" "yes" \
    "$(with_audioctl 'LOCAL=/nowhere; preflight pw-tunnel 2>&1 | grep -q "missing" && echo yes || echo no')"

# --- what it tells the user ------------------------------------------------
stub pactl 0 "Server Name: pulseaudio"
stub_systemctl pulseaudio.service none
check "status names the running profile" "yes" \
    "$(with_audioctl 'status | grep -q "Profile (active):   standard" && echo yes || echo no')"
check "and warns when the record disagrees" "yes" \
    "$(with_audioctl 'echo pw-hal > "$STICKY"; status | grep -q "WARNING" && echo yes || echo no')"
check "the help lists every profile" "yes" \
    "$(with_audioctl 'usage | grep -c "pw-hal" | grep -q "[1-9]" && echo yes || echo no')"

# --- the dispatcher, run as the program ------------------------------------
#
# Everything above calls into audioctl's functions. This runs it the way a
# person does, with the state directory pointed somewhere harmless and
# --dry-run wherever it would change something.

run_audioctl() {
    # -x only when a trace is being collected: a new bash does not inherit it,
    # and without it the dispatcher would run untraced and read as uncovered.
    # The legacy paths are stubbed too. Without that the dispatcher reads the
    # real /etc/systemd/user while the test believes it set everything through
    # AUDIOCTL_ETCU - and "migrate" then reports whatever leftovers the machine
    # running the suite happens to have, which is a verdict about the phone and
    # not about the code.
    # The plugin and PipeWire's modules are stubbed for the same reason the
    # paths above are: preflight refuses pw-hal without them, and a dispatcher
    # that only gets past it on a phone with the real installation is a
    # verdict about the machine again.
    AUDIOCTL_STATE_DIR="$STUBDIR/state" AUDIOCTL_ETCU="$STUBDIR/etc" \
        AUDIOCTL_LEGACY_ETCU="$STUBDIR/legacy-etc" \
        AUDIOCTL_LEGACY_WP="$STUBDIR/legacy-wp" \
        AUDIOCTL_PLUGIN_DIR="$STUBDIR/plugin" \
        AUDIOCTL_PW_MODULE_DIR="$STUBDIR/plugin" \
        VERIFY_TRIES=1 BT_HOLD_INTERVAL=0 bash ${AUDIOCTL_TRACE:+-x} "$HERE/../audioctl" "$@" 2>&1
}
mkdir -p "$STUBDIR/plugin"
: > "$STUBDIR/plugin/libspa-droid.so"
: > "$STUBDIR/plugin/libpipewire-module-pulse-tunnel.so"
# Earlier tests wrote profiles into this directory; the dispatcher reads them,
# so it starts clean.
rm -rf "$STUBDIR/state" "$STUBDIR/legacy-etc" "$STUBDIR/legacy-wp"
mkdir -p "$STUBDIR/state" "$STUBDIR/etc" "$STUBDIR/legacy-etc" "$STUBDIR/legacy-wp"

stub_systemctl pulseaudio.service furios-audio-apply.service
stub pactl 0 "60	droid-sink	PipeWire	s16le 2ch 48000Hz	SUSPENDED"

check "with no arguments it reports the state" "yes" \
    "$(run_audioctl | grep -q "Profile (active)" && echo yes || echo no)"
check "list names the three profiles" "3" \
    "$(run_audioctl list | wc -l)"
check "help explains itself" "yes" \
    "$(run_audioctl --help | grep -q "switch the audio stack" && echo yes || echo no)"
check "a word it does not know gets the help and a failure" "1" \
    "$(run_audioctl nonsense >/dev/null 2>&1; echo $?)"
check "verify answers when a sink is there" "yes" \
    "$(run_audioctl verify | grep -q "sink present" && echo yes || echo no)"
check "try without a profile is refused" "yes" \
    "$(run_audioctl try | grep -q "profile missing" && echo yes || echo no)"
check "set without a profile too" "yes" \
    "$(run_audioctl set | grep -q "profile missing" && echo yes || echo no)"
check "bt-call without a word is refused" "yes" \
    "$(run_audioctl bt-call | grep -q "needs" && echo yes || echo no)"
check "a dry run says what it would do and stops" "yes" \
    "$(run_audioctl --dry-run set pw-hal | grep -q "nothing changed" && echo yes || echo no)"
# The line names the recorded profile on the left and the target on the right;
# the decision is made from the running one, so the target is what to check.
check "toggle from standard goes to pw-hal, in test mode" "yes" \
    "$(run_audioctl --dry-run toggle | grep -q -- '-> pw-hal (try)' && echo yes || echo no)"
check "restart keeps the profile it is in" "yes" \
    "$(run_audioctl --dry-run restart | grep -q "profile standard" && echo yes || echo no)"

stub pactl 0 "35	auto_null	PipeWire	float32le 2ch 48000Hz	SUSPENDED"
check "verify says no when only the fallback sink is there" "1" \
    "$(run_audioctl verify >/dev/null 2>&1; echo $?)"

# restart, with nothing to show for it: the fallback sink is not a sink, so it
# says so rather than reporting success.
check "restart says so when no sink appears" "yes" \
    "$(run_audioctl --dry-run restart | grep -q "no sink after the restart" && echo yes || echo no)"

# status with a test profile in place, so the line about it is printed too.
check "status says when a profile is only temporary" "yes" \
    "$(echo pw-hal > "$STUBDIR/state/profile.try"
       run_audioctl status | grep -c "Test mode" >/dev/null && \
       run_audioctl status | grep -q "falls back" && echo yes || echo no)"
rm -f "$STUBDIR/state/profile.try"

check "rescue is reachable from the command line" "yes" \
    "$(run_audioctl --dry-run rescue | grep -q "sound restored" && echo yes || echo no)"
check "revert goes straight back to standard" "yes" \
    "$(run_audioctl --dry-run revert | grep -q -- '-> standard (sticky)' && echo yes || echo no)"
check "and bt-call reaches the handler from the command line" "yes" \
    "$(run_audioctl bt-call off | grep -q "bt-call" && echo yes || echo no)"
check "bt-mic without a word is refused" "yes" \
    "$(run_audioctl bt-mic | grep -q "needs" && echo yes || echo no)"
# Read the whole thing into a variable rather than piping it into grep -q:
# grep -q closes the pipe the moment it matches, audioctl dies of SIGPIPE after
# its first line, and every line below that looks untested because it never
# ran. The status block is five lines and each one is a thing somebody needs.
bt_status=$(run_audioctl bt-mic status 2>/dev/null)
check "and bt-mic reaches the handler from the command line" "yes" \
    "$(printf '%s' "$bt_status" | grep -q "Bluetooth card" && echo yes || echo no)"
check "bt-mic status names the phone ports" "yes" \
    "$(printf '%s' "$bt_status" | grep -q "Phone ports:" && echo yes || echo no)"
# The hold is the difference between a working headset microphone and silence
# that measures like a broken one, so status has to say which it is.
check "bt-mic status says whether the link is held" "yes" \
    "$(printf '%s' "$bt_status" | grep -qE "Link hold: +(running|not running)" && echo yes || echo no)"
check "bt-mic status reports the HAL Bluetooth PCM" "yes" \
    "$(printf '%s' "$bt_status" | grep -q "HAL Bluetooth PCM:" && echo yes || echo no)"
# With a pid file naming a process that is alive, the same line has to read
# "running" - the branch that says so is the one nobody sees until it is wrong.
# A process that looks like the hold: the real one is "timeout N paplay ...".
bash -c 'exec -a paplay sleep 30' &
fake_hold=$!
mkdir -p "$STUBDIR/run"
printf '%s\n' "$fake_hold" > "$STUBDIR/run/furios-audio-sco-hold.pid"
check "a live hold is reported as running" "yes" \
    "$(XDG_RUNTIME_DIR="$STUBDIR/run" run_audioctl bt-mic status 2>/dev/null |
           grep -q "Link hold:          running" && echo yes || echo no)"
kill "$fake_hold" 2>/dev/null; wait "$fake_hold" 2>/dev/null

# The file outlives a hold that ran out, and its pid goes to somebody else.
# That process is alive, but it is not ours: not reported as the hold, and
# above all not sent the SIGTERM that "bt-mic off" sends the hold.
sleep 30 &
stranger=$!
printf '%s\n' "$stranger" > "$STUBDIR/run/furios-audio-sco-hold.pid"
check "a pid that went to another process is not a hold" "yes" \
    "$(XDG_RUNTIME_DIR="$STUBDIR/run" run_audioctl bt-mic status 2>/dev/null |
           grep -q "Link hold:          not running" && echo yes || echo no)"
with_audioctl "XDG_RUNTIME_DIR=\"$STUBDIR/run\"; bt_sco_hold_stop" >/dev/null 2>&1
check "and stopping the hold leaves that process alone" "yes" \
    "$(kill -0 "$stranger" 2>/dev/null && echo yes || echo no)"
check "while the stale file is gone" "no" \
    "$([ -e "$STUBDIR/run/furios-audio-sco-hold.pid" ] && echo yes || echo no)"
kill "$stranger" 2>/dev/null; wait "$stranger" 2>/dev/null


stub_systemctl pipewire-pulse.service furios-audio-apply.service
check "toggle from pw-hal goes back to standard, and stays" "yes" \
    "$(run_audioctl --dry-run toggle | grep -q -- '-> standard (sticky)' && echo yes || echo no)"

# --- "boot": the one run that must not start anything ------------------------
#
# furios-audio-apply.service runs Before= pipewire and pulseaudio, and it runs
# audioctl. When audioctl asked systemd to restart those units from there, the
# restart queued behind a job that was waiting for this very unit to finish -
# a deadlock that reached the whole session: pipewire never started, and the
# phone came up with no sound at all. Seen on the device, twice over, because
# a switch attempted afterwards queued behind the same job and got half-way
# through: PulseAudio masked, PipeWire not running.
#
# So the boot run writes configuration and nothing else. These checks read the
# calls it makes to systemctl.

# A systemctl that writes down every call it gets. is-enabled fails, so the
# ensure_* helpers take their enabling path rather than returning early.
stub_logging_systemctl() {
    : > "$STUBDIR/systemctl.log"
    cat > "$STUBDIR/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$STUBDIR/systemctl.log"
case "\$2" in
is-active)  exit 3 ;;
is-enabled) exit 1 ;;
cat)        exit 0 ;;
esac
exit 0
STUB
    chmod +x "$STUBDIR/systemctl"
}

run_boot() {
    AUDIOCTL_STATE_DIR="$STUBDIR/state" AUDIOCTL_ETCU="$STUBDIR/etc" \
        AUDIOCTL_WPCONF_DIR="$STUBDIR/wp" \
        VERIFY_TRIES=1 bash ${AUDIOCTL_TRACE:+-x} "$HERE/../audioctl" boot 2>&1
}

stub_logging_systemctl
stub pactl 0 ""
echo standard > "$STUBDIR/state/profile"
run_boot >/dev/null 2>&1

# The deadlock itself: not one of these verbs may be asked for at boot. Every
# logged line begins with the --user that uctl puts there, so the verb is the
# second word - matching it at the start of the line would pass on anything.
check "boot asks systemd to start, stop or restart nothing" "" \
    "$(grep -E '^--user (start|stop|restart|reset-failed)([[:space:]]|$)' \
        "$STUBDIR/systemctl.log")"

# enable is configuration and has to stay; --now is the starting half of it.
check "enable survives the boot run" "yes" \
    "$(grep -q -E '(^|[[:space:]])enable[[:space:]]' "$STUBDIR/systemctl.log" && echo yes || echo no)"
check "but --now is stripped from it" "" \
    "$(grep -- '--now' "$STUBDIR/systemctl.log")"

# Waiting for a sink is just as wrong there: the stack has not been started
# yet, so fifteen seconds later it would "fall back to standard" over a stack
# nobody had started. pactl prints no sink here and it still comes out happy.
check "boot does not judge the profile by a sink that cannot be up yet" "yes" \
    "$(run_boot | grep -q "systemd starts the stack from it" && echo yes || echo no)"

# What it does have to do: discard a test profile, and apply the stored one.
echo pw-hal > "$STUBDIR/state/profile.try"
run_boot >/dev/null 2>&1
check "boot discards the test-mode marker" "gone" \
    "$([ -e "$STUBDIR/state/profile.try" ] && echo there || echo gone)"

# standard is applied like any other profile - a test profile leaves its masks
# behind, and applying standard is what clears them.
mkdir -p "$STUBDIR/etc/pipewire.service.d"
: > "$STUBDIR/etc/pipewire.service.d/50-furios-audio.conf"
ln -sf /dev/null "$STUBDIR/etc/pulseaudio.service"
run_boot >/dev/null 2>&1
check "and it clears what a test profile left behind" "gone" \
    "$([ -e "$STUBDIR/etc/pipewire.service.d/50-furios-audio.conf" ] && echo there || echo gone)"
check "including the mask over PulseAudio" "gone" \
    "$([ -e "$STUBDIR/etc/pulseaudio.service" ] && echo there || echo gone)"

check "with no stored profile it falls back to standard" "yes" \
    "$(rm -f "$STUBDIR/state/profile"; run_boot | grep -q -- '-> standard (boot)' && echo yes || echo no)"

# And the counter-check: a switch from the command line still restarts things.
# A suppression that caught the interactive path too would leave every switch
# writing configuration nobody acts on.
echo standard > "$STUBDIR/state/profile"
stub_logging_systemctl
stub pactl 0 "60	droid-sink	PipeWire	s16le 2ch 48000Hz	SUSPENDED"
AUDIOCTL_STATE_DIR="$STUBDIR/state" AUDIOCTL_ETCU="$STUBDIR/etc" \
    AUDIOCTL_WPCONF_DIR="$STUBDIR/wp" VERIFY_TRIES=1 \
    bash ${AUDIOCTL_TRACE:+-x} "$HERE/../audioctl" set standard >/dev/null 2>&1
check "a switch from the command line does restart the stack" "yes" \
    "$(grep -qx -- '--user restart pipewire.service' "$STUBDIR/systemctl.log" \
        && echo yes || echo no)"

# --- "boot-check": the half that runs after the stack ------------------------
#
# The boot run above writes configuration and cannot judge it - nothing is up
# yet to ask. So a stored profile that comes up silent needs catching from the
# other side, ordered After= the stack, and that is this. Without it a pw-hal
# that breaks under a new PipeWire leaves the phone mute with no way back but
# a shell.

# A pactl with no sink for the first N calls, and a real one after that - so
# the fallback can be watched changing the answer.
stub_pactl_silent_for() {
    # stub_pactl_silent_for <how many calls answer nothing>
    rm -f "$STUBDIR/pactl.calls"
    cat > "$STUBDIR/pactl" <<STUB
#!/bin/sh
n=\$(cat "$STUBDIR/pactl.calls" 2>/dev/null || echo 0)
n=\$((n+1)); printf '%s' "\$n" > "$STUBDIR/pactl.calls"
[ "\$n" -le "$1" ] && exit 0
printf '60\tdroid-sink\tPipeWire\ts16le 2ch 48000Hz\tSUSPENDED\n'
STUB
    chmod +x "$STUBDIR/pactl"
}

run_boot_check() {
    AUDIOCTL_STATE_DIR="$STUBDIR/state" AUDIOCTL_ETCU="$STUBDIR/etc" \
        AUDIOCTL_WPCONF_DIR="$STUBDIR/wp" \
        VERIFY_TRIES=1 BOOT_VERIFY_TRIES=1 \
        bash ${AUDIOCTL_TRACE:+-x} "$HERE/../audioctl" boot-check 2>&1
}

# A sink is there: it says so and leaves the stack alone. Restarting a working
# stack at every boot is the other way to get this wrong.
stub_logging_systemctl
echo pw-hal > "$STUBDIR/state/profile"
stub pactl 0 "60	droid-sink	PipeWire	s16le 2ch 48000Hz	SUSPENDED"
check "boot-check passes a profile that has a sink" "yes" \
    "$(run_boot_check | grep -q "profile pw-hal has a sink" && echo yes || echo no)"
check "and leaves a working stack alone" "" \
    "$(grep -E '^--user (restart|stop) ' "$STUBDIR/systemctl.log")"

# No sink: this is what the unit exists for.
stub_logging_systemctl
stub_pactl_silent_for 1
echo pw-hal > "$STUBDIR/state/profile"
echo pw-hal > "$STUBDIR/state/profile.try"
out=$(run_boot_check)
check "a silent boot falls back to standard" "yes" \
    "$(printf '%s' "$out" | grep -q "produced no phone output" && echo yes || echo no)"
check "and says so once it has sound again" "yes" \
    "$(printf '%s' "$out" | grep -q "standard restored" && echo yes || echo no)"
check "the fallback really restarts the stack" "yes" \
    "$(grep -qx -- '--user restart pipewire.service' "$STUBDIR/systemctl.log" \
        && echo yes || echo no)"
check "it discards the test profile" "gone" \
    "$([ -e "$STUBDIR/state/profile.try" ] && echo there || echo gone)"

# Changed 28.9.: the fallback is recorded. A profile that does not come up
# after an update would otherwise be retried at every boot, each time half a
# minute of silence - the worst case is to be the shipped default, with a note
# saying when and from what.
check "the fallback is recorded as standard" "standard" \
    "$(cat "$STUBDIR/state/profile")"
check "with a note of when and from what" "yes" \
    "$(grep -q ' pw-hal$' "$STUBDIR/state/fell-back" 2>/dev/null && echo yes || echo no)"
check "WirePlumber is killed before it is stopped" "yes" \
    "$(grep -q -- '--user kill -s KILL wireplumber.service' "$STUBDIR/systemctl.log" && echo yes || echo no)"
check "status tells about it" "yes" \
    "$(AUDIOCTL_STATE_DIR="$STUBDIR/state" bash "$HERE/../audioctl" status 2>/dev/null \
       | grep -q '^Fell back: ' && echo yes || echo no)"
rm -f "$STUBDIR/state/fell-back"

# A headset is not the phone. Under pw-hal a Bluetooth sink that comes up
# while the HAL gave PipeWire nothing must not pass the check.
stub_logging_systemctl
echo pw-hal > "$STUBDIR/state/profile"
stub pactl 0 "71	bluez_output.F4_9D_8A_00_00_01.1	PipeWire	s16le 2ch 48000Hz	SUSPENDED"
out=$(run_boot_check)
check "a Bluetooth sink alone is not the phone's output" "yes" \
    "$(printf '%s' "$out" | grep -q "produced no phone output" && echo yes || echo no)"
stub_logging_systemctl
echo standard > "$STUBDIR/state/profile"
check "under standard any sink still counts" "yes" \
    "$(run_boot_check | grep -q "profile standard has a sink" && echo yes || echo no)"
echo pw-hal > "$STUBDIR/state/profile"

# Nothing worked. Left failing on purpose: no sound is the one state nobody
# can hear their way out of, so it belongs in "systemctl --user --failed".
stub_logging_systemctl
stub pactl 0 ""
check "with no sound at all it reports failure" "1" \
    "$(run_boot_check >/dev/null 2>&1; echo $?)"
check "and names the profile that did not help either" "yes" \
    "$(run_boot_check 2>&1 | grep -q "standard delivers no sink either" && echo yes || echo no)"

# The boot check waits longer than an interactive switch, and does it through
# an argument: as an environment variable the larger value would have stayed in
# force for the verify() after the fallback as well.
# The count goes through a file: verify() runs pactl inside a pipeline, so a
# shell function counting in a variable would be counting in a subshell.
: > "$STUBDIR/tries.txt"
( AUDIOCTL_LIB=1 . "$HERE/../audioctl"
  pactl() { echo x >> "$STUBDIR/tries.txt"; return 0; }
  sleep() { :; }
  verify 4 >/dev/null 2>&1 ) 2>/dev/null
check "verify tries as often as it is told to" "4" "$(wc -l < "$STUBDIR/tries.txt" | tr -d ' ')"

# --- what it refuses, and how it leaves the state directory ------------------
#
# The profile written into the state directory decides what
# furios-audio-apply.service applies at the next login, and that runs audioctl
# again. So the name has to be one of ours, and the directory must not be
# something anyone on the device can write to. Found at 1777 with the profile
# file at 0666 on the phone this was developed on.

# preflight() already refuses these - this is here so it stays that way. The
# name ends up in the state file, and from there in the next login's audioctl.
check "an unknown profile is refused rather than stored" "yes" \
    "$(run_audioctl --dry-run set boesartig 2>&1 | grep -q 'unknown profile' && echo yes || echo no)"
check "and a made-up one for try as well" "yes" \
    "$(run_audioctl --dry-run try nonsense 2>&1 | grep -q 'unknown profile' && echo yes || echo no)"
check "the three real ones are not refused" "no" \
    "$(for p in standard pw-tunnel pw-hal; do
          run_audioctl --dry-run set "$p" 2>&1 | grep -q 'unknown profile' && echo yes
       done | grep -q yes && echo yes || echo no)"

# --- the state directory it leaves behind -----------------------------------

( load_audioctl >/dev/null 2>&1
  STATE_DIR=$STUBDIR/state; STICKY=$STATE_DIR/profile
  rm -rf "$STATE_DIR"
  write_state "$STICKY" pw-hal >/dev/null 2>&1
  stat -c '%a' "$STATE_DIR" "$STICKY" 2>/dev/null ) > "$STUBDIR/perms.txt" 2>&1
check "a fresh state directory is not writable by others" "755" \
    "$(sed -n 1p "$STUBDIR/perms.txt")"
check "and the profile file neither" "644" \
    "$(sed -n 2p "$STUBDIR/perms.txt")"

( load_audioctl >/dev/null 2>&1
  STATE_DIR=$STUBDIR/wide; rm -rf "$STATE_DIR"; mkdir -p "$STATE_DIR"; chmod 0777 "$STATE_DIR"
  state_dir_ready >/dev/null 2>&1
  stat -c '%a' "$STATE_DIR" ) > "$STUBDIR/wide.txt" 2>&1
# And the package must not undo it. This was the actual source: postinst set
# the directory to 1777 and the profile file to 0666, so every account on the
# phone could pick what audioctl applies at the next login.
check "the package does not open the state directory to everyone" "no" \
    "$(grep -qE 'chmod +(1777|777|0777|666|0666) +/var/lib/furios-audio' \
        "$HERE/../packaging/build-deb.sh" && echo yes || echo no)"
check "and it gives the directory an owner" "yes" \
    "$(grep -q 'chown "\$owner" /var/lib/furios-audio' \
        "$HERE/../packaging/build-deb.sh" && echo yes || echo no)"
# ... but never recursively. The directory belongs to an unprivileged user who
# can put anything in it, a hard link to a file elsewhere included - and a
# recursive chown run by root as part of an upgrade would hand them that file.
check "and it does not chown whatever it finds in there" "no" \
    "$(grep -qE '^[[:space:]]*chown -R' "$HERE/../packaging/build-deb.sh" && echo yes || echo no)"

check "a directory anyone could write to is narrowed" "no" \
    "$(case "$(tail -1 "$STUBDIR/wide.txt")" in *[2367]) echo yes ;; *) echo no ;; esac)"

# The dispatcher's own view of root: in for the migration, out for everything
# else. Down here because run_audioctl is defined above this point.
cat > "$STUBDIR/id" <<'IDEOF'
#!/bin/sh
case "${1:-}" in
-un) echo root ;;
-u)  echo 0 ;;
*)   echo "uid=0(root)" ;;
esac
IDEOF
chmod +x "$STUBDIR/id"
# migrate is the one command root is let in for, and it deletes files. That
# combination is why every AUDIOCTL_* override is refused as root: with one
# honoured, migrate would delete whatever it was pointed at. The consequence
# for this suite is that the root path cannot be exercised with stubs at all -
# the same reason the sibling gps project runs its tests unprivileged - so what
# is checked here is the judgement, not the deletion.
check "root with an override is refused, naming the variable" "yes" \
    "$(run_audioctl migrate 2>&1 | grep -q 'refusing to honour AUDIOCTL_' && echo yes || echo no)"
check "and turned away from every other command" "yes" \
    "$(run_audioctl status 2>&1 | grep -q 'not as root' && echo yes || echo no)"
# Without the guard the previous check would pass for the wrong reason, so
# make sure the refusal is about the override and not about the command.
check "the refusal says what it is protecting" "yes" \
    "$(run_audioctl migrate 2>&1 | grep -q 'deleting arbitrary files' && echo yes || echo no)"
rm -f "$STUBDIR/id"

# --- the Bluetooth music codec ------------------------------------------------
#
# The headset as this phone sees it: plain a2dp-sink is AAC, and only its
# description says so.
cat > "$STUBDIR/pactl" <<'PACTL'
#!/bin/sh
case "$*" in
"list short cards") printf '61\tdroid\tmodule\n81\tbluez_card.F4_9D_8A_00_00_01\tmodule\n' ;;
"list cards") cat <<'OUT'
Card #61
	Name: droid
	Profiles:
		default: Playback and Capture (sinks: 1, sources: 1, priority: 100, available: yes)
	Active Profile: default

Card #81
	Name: bluez_card.F4_9D_8A_00_00_01
	Profiles:
		a2dp-sink: High Fidelity Playback (A2DP Sink, codec AAC) (sinks: 1, sources: 1, priority: 133, available: yes)
		a2dp-sink-sbc: High Fidelity Playback (A2DP Sink, codec SBC) (sinks: 1, sources: 1, priority: 130, available: yes)
		a2dp-sink-sbc_xq: High Fidelity Playback (A2DP Sink, codec SBC-XQ) (sinks: 1, sources: 1, priority: 131, available: yes)
		a2dp-sink-aptx_hd: High Fidelity Playback (A2DP Sink, codec aptX HD) (sinks: 1, sources: 1, priority: 132, available: no)
		headset-head-unit: Headset Head Unit (HSP/HFP, codec mSBC) (sinks: 1, sources: 1, priority: 3, available: yes)
	Active Profile: a2dp-sink-sbc
OUT
;;
esac
PACTL
chmod +x "$STUBDIR/pactl"
stub wpctl 0 'Value: "sbc" (Saved: true)'
status_out=$(with_audioctl 'bt_codec_status')
check "the preference is read from WirePlumber" "yes" \
    "$(printf '%s\n' "$status_out" | grep -qx 'preference=sbc' && echo yes || echo no)"
check "the active codec comes from the profile, not its name" "yes" \
    "$(printf '%s\n' "$status_out" | grep -qx 'active=sbc' && echo yes || echo no)"
check "plain a2dp-sink is offered as what it is, and SBC-XQ by its name" "yes" \
    "$(printf '%s\n' "$status_out" | grep -qx 'offered=aac sbc sbc_xq' && echo yes || echo no)"
check "a profile that is not available is not offered, hands-free never" "no" \
    "$(printf '%s\n' "$status_out" | grep -q 'aptx_hd\|msbc' && echo yes || echo no)"
stub wpctl 0 "Setting 'furios.bluetooth-codec' not found"
check "a WirePlumber without the setting says so rather than 'auto'" "yes" \
    "$(with_audioctl 'bt_codec_status' | grep -qx 'preference=unsupported' && echo yes || echo no)"
check "and setting it fails loudly - wpctl itself answers 0" "yes" \
    "$(says 'bt_codec sbc' 'did not take the setting')"
check "an unknown codec is refused before anything is asked" "yes" \
    "$(says 'bt_codec mp3' 'bt-codec needs one of')"
make_recording_stub wpctl 0 'Value: "aac" (Saved: true)'
rm -f "$STUBDIR/wpctl.args"
with_audioctl 'bt_codec aac' >/dev/null 2>&1
check "a choice is saved, so it outlives WirePlumber" "yes" \
    "$(grep -q -- '--save furios.bluetooth-codec aac' "$STUBDIR/wpctl.args" && echo yes || echo no)"
rm -f "$STUBDIR/wpctl" "$STUBDIR/wpctl.args"

# --- one headset, its own codec ------------------------------------------------
#
# A WirePlumber that keeps what it is told, one file per setting, and prints
# values the way wpctl does: unquoted, "" when empty.
mkdir -p "$STUBDIR/wp"
cat > "$STUBDIR/wpctl" <<WPCTL
#!/bin/sh
d="$STUBDIR/wp"
[ "\$1" = settings ] || exit 0
shift
if [ "\$1" = --save ]; then
    shift
    printf '%s' "\$2" | sed 's/^""\$//' > "\$d/\$1"
    exit 0
fi
case "\$1" in
furios.bluetooth-codec) echo 'Value: sbc_xq (Saved: sbc_xq)' ;;
furios.bluetooth-codec-devices)
    v=\$(cat "\$d/\$1" 2>/dev/null)
    echo "Value: \${v:-\"\"} (Saved: \${v:-\"\"})" ;;
*) echo "Setting '\$1' not found" ;;
esac
WPCTL
chmod +x "$STUBDIR/wpctl"
rm -f "$STUBDIR/bt-codecs"
status_out=$(with_audioctl 'bt_codec_status')
check "a WirePlumber that knows the per-headset setting says so" "yes" \
    "$(printf '%s\n' "$status_out" | grep -qx 'per_device=yes' && echo yes || echo no)"
check "the connected headset is named by its address" "yes" \
    "$(printf '%s\n' "$status_out" | grep -qx 'device=F4:9D:8A:00:00:01' && echo yes || echo no)"
check "what it offers is remembered for when it is gone" "yes" \
    "$(grep -q '^F4:9D:8A:00:00:01	aac sbc sbc_xq	' "$STUBDIR/bt-codecs" 2>/dev/null && echo yes || echo no)"
check "and listed, following the setting for all" "yes" \
    "$(printf '%s\n' "$status_out" | grep -q '^known=F4:9D:8A:00:00:01|.*|default|aac,sbc,sbc_xq$' && echo yes || echo no)"

with_audioctl 'bt_codec sbc --device f4:9d:8a:00:00:01' >/dev/null 2>&1
check "a headset gets its own codec, address in any case" "F4:9D:8A:00:00:01=sbc" \
    "$(cat "$STUBDIR/wp/furios.bluetooth-codec-devices")"
with_audioctl 'bt_codec aac --device 98:52:3D:00:00:02' >/dev/null 2>&1
with_audioctl 'bt_codec sbc_xq --device F4:9D:8A:00:00:01' >/dev/null 2>&1
check "a second headset is added, a new choice replaces the old" \
    "98:52:3D:00:00:02=aac;F4:9D:8A:00:00:01=sbc_xq" \
    "$(cat "$STUBDIR/wp/furios.bluetooth-codec-devices")"
check "status shows the headset's own choice" "yes" \
    "$(with_audioctl 'bt_codec_status' | grep -q '^known=F4:9D:8A:00:00:01|.*|sbc_xq|' && echo yes || echo no)"
with_audioctl 'bt_codec default --device 98:52:3D:00:00:02' >/dev/null 2>&1
check "default takes a headset out again" "F4:9D:8A:00:00:01=sbc_xq" \
    "$(cat "$STUBDIR/wp/furios.bluetooth-codec-devices")"
with_audioctl 'bt_codec default --device F4:9D:8A:00:00:01' >/dev/null 2>&1
check "and the last one leaves an empty list" "" \
    "$(cat "$STUBDIR/wp/furios.bluetooth-codec-devices")"
check "a malformed address is refused" "yes" \
    "$(says 'bt_codec sbc --device F4:9D;rm' 'needs a Bluetooth address')"
check "default alone, without a headset, is refused" "yes" \
    "$(says 'bt_codec default' 'bt-codec needs one of')"
stub wpctl 0 "Setting 'furios.bluetooth-codec-devices' not found"
check "an older WirePlumber says it cannot, not that it did" "yes" \
    "$(says 'bt_codec sbc --device F4:9D:8A:00:00:01' 'does not know furios.bluetooth-codec-devices')"
check "and the status says per_device=no" "yes" \
    "$(with_audioctl 'bt_codec_status' | grep -qx 'per_device=no' && echo yes || echo no)"
rm -rf "$STUBDIR/pactl" "$STUBDIR/wpctl" "$STUBDIR/wp" "$STUBDIR/bt-codecs"

# --- the same choice under PulseAudio -----------------------------------------
#
# A PulseAudio that switches when told to and keeps what it was told in a
# file, the way the real one answers send-message: JSON for list-codecs, a
# quoted name for get-codec. It offers SBC and the three SBC-XQ rates - what
# the phone's own PulseAudio 17 offers the soundcore, measured 29.9.2026.
cat > "$STUBDIR/pactl" <<PACTL
#!/bin/sh
d="$STUBDIR"
echo "\$*" >> "\$d/pactl.args"
case "\$*" in
info) echo 'Server Name: pulseaudio' ;;
"list cards")
    avail=yes; [ -e "\$d/sink-stuck" ] && avail=no
    src=no; [ -e "\$d/source-read" ] && src=yes
    printf 'Card #5\n\tName: bluez_card.F4_9D_8A_00_00_01\n\tProperties:\n\t\tbluez.path = "/org/bluez/hci0/dev_F4_9D_8A_00_00_01"\n\tProfiles:\n\t\ta2dp_source: High Fidelity Capture (A2DP Source) (sinks: 0, sources: 1, priority: 20, available: %s)\n\t\ta2dp_sink: High Fidelity Playback (A2DP Sink) (sinks: 1, sources: 0, priority: 40, available: %s)\n\tActive Profile: %s\n\n' "\$src" "\$avail" "\$(cat "\$d/pa-profile" 2>/dev/null || echo a2dp_sink)" ;;
"list modules short") printf '12\tmodule-bluez5-discover\t\n26\tmodule-loopback\tsource="bluez_source.F4_9D_8A_00_00_01.a2dp_source" source_dont_move="true"\n27\tmodule-loopback\tsource="alsa_input.other"\n' ;;
"list short cards") [ -e "\$d/no-card" ] || printf '5\tbluez_card.F4_9D_8A_00_00_01\tmodule-bluez5-device.c\n' ;;
*" list-codecs") echo '[{"name":"sbc","description":"SBC"},{"name":"sbc_xq_453","description":"SBC XQ 453kbps"},{"name":"sbc_xq_512","description":"SBC XQ 512kbps"},{"name":"sbc_xq_552","description":"SBC XQ 552kbps"}]' ;;
*" get-codec") [ -e "\$d/hfp" ] && exit 1; echo "\"\$(cat "\$d/pa-codec" 2>/dev/null || echo sbc)\"" ;;
*" switch-codec "*) echo "\$4" | tr -d '"' > "\$d/pa-codec" ;;
esac
PACTL
chmod +x "$STUBDIR/pactl"
make_recording_stub systemctl 0 ""
rm -f "$STUBDIR/pa-codec" "$STUBDIR/pactl.args" "$STUBDIR/bt-codec-pulse" "$STUBDIR/systemctl.args" \
      "$STUBDIR/state/bt-extras"
status_out=$(with_audioctl 'bt_codec status')
check "under PulseAudio the status comes from PulseAudio, not WirePlumber" "yes" \
    "$(printf '%s\n' "$status_out" | grep -qx 'server=pulseaudio' && echo yes || echo no)"
check "nothing chosen reads as automatic, not as unsupported" "yes" \
    "$(printf '%s\n' "$status_out" | grep -qx 'preference=auto' && echo yes || echo no)"
check "the three SBC-XQ rates are the one sbc_xq" "yes" \
    "$(printf '%s\n' "$status_out" | grep -qx 'offered=sbc sbc_xq' && echo yes || echo no)"
check "and only those are offered for choosing" "yes" \
    "$(printf '%s\n' "$status_out" | grep -qx 'choices=auto sbc sbc_xq' && echo yes || echo no)"
check "the headsets seen under PipeWire are left alone" "no" \
    "$([ -e "$STUBDIR/bt-codecs" ] && echo yes || echo no)"

with_audioctl 'echo standard > "$STICKY"; rm -f "$TRY"; bt_codec sbc_xq' >/dev/null 2>&1
check "sbc_xq switches to the highest rate the headset takes" "sbc_xq_552" \
    "$(cat "$STUBDIR/pa-codec" 2>/dev/null)"
check "the choice is kept for the next connect" "sbc_xq" \
    "$(cat "$STUBDIR/bt-codec-pulse" 2>/dev/null)"
check "and the watcher that puts it back is started" "yes" \
    "$(grep -q 'start furios-audio-bt-pulse.service' "$STUBDIR/systemctl.args" && echo yes || echo no)"
check "the status then says what plays" "yes" \
    "$(with_audioctl 'bt_codec status' | grep -qx 'active=sbc_xq' && echo yes || echo no)"
check "the watcher may run under standard with a choice made" "0" \
    "$(with_audioctl 'echo standard > "$STICKY"; rm -f "$TRY"; bt_pulse wanted' >/dev/null 2>&1; echo $?)"

rm -f "$STUBDIR/pactl.args"
with_audioctl 'bt_codec sbc_xq' >/dev/null 2>&1
check "a codec already playing is not switched again - no dropout" "no" \
    "$(grep -q switch-codec "$STUBDIR/pactl.args" && echo yes || echo no)"

echo sbc > "$STUBDIR/pa-codec"
with_audioctl 'bt_pulse_apply' >/dev/null 2>&1
check "a reconnect on PulseAudio's default gets the choice back" "sbc_xq_552" \
    "$(cat "$STUBDIR/pa-codec")"

echo a2dp_source > "$STUBDIR/pa-profile"; rm -f "$STUBDIR/pactl.args"
check "a headset taken for a sound source plays nothing to switch" "no" \
    "$(with_audioctl 'bt_codec status' | grep -q '^active=' && echo yes || echo no)"
with_audioctl 'bt_pulse_apply' >/dev/null 2>&1
check "and nothing is sent to it" "no" \
    "$(grep -q switch-codec "$STUBDIR/pactl.args" && echo yes || echo no)"
rm -f "$STUBDIR/pa-profile"

touch "$STUBDIR/hfp"; echo handsfree_head_unit > "$STUBDIR/pa-profile"; rm -f "$STUBDIR/pactl.args"
check "on hands-free there is nothing to switch, and that is no error" "0" \
    "$(with_audioctl 'bt_pulse_apply' >/dev/null 2>&1; echo $?)"
check "and nothing is sent" "no" \
    "$(grep -q switch-codec "$STUBDIR/pactl.args" && echo yes || echo no)"
rm -f "$STUBDIR/hfp" "$STUBDIR/pa-profile"

check "AAC is refused where PulseAudio has none, and says what plays" "yes" \
    "$(says 'bt_codec aac' 'does not offer aac under PulseAudio')"
check "and is not kept" "sbc_xq" "$(cat "$STUBDIR/bt-codec-pulse" 2>/dev/null)"
check "a codec per headset is refused under PulseAudio" "yes" \
    "$(says 'bt_codec sbc --device F4:9D:8A:00:00:01' 'needs pw-hal')"
check "an unknown codec is refused here too" "yes" \
    "$(says 'bt_codec mp3' 'bt-codec needs one of')"

rm -f "$STUBDIR/systemctl.args"
with_audioctl 'bt_codec auto' >/dev/null 2>&1
check "automatic forgets the choice" "no" \
    "$([ -e "$STUBDIR/bt-codec-pulse" ] && echo yes || echo no)"
check "stops the watcher - nothing else asks for it" "yes" \
    "$(grep -q 'stop furios-audio-bt-pulse.service' "$STUBDIR/systemctl.args" && echo yes || echo no)"
check "and goes back to PulseAudio's own default" "sbc" \
    "$(cat "$STUBDIR/pa-codec")"
check "with nothing chosen the watcher does not run" "1" \
    "$(with_audioctl 'echo standard > "$STICKY"; rm -f "$TRY"; bt_pulse wanted' >/dev/null 2>&1; echo $?)"
echo sbc_xq > "$STUBDIR/bt-codec-pulse"
check "nor under pw-hal, whatever the file says" "1" \
    "$(with_audioctl 'echo pw-hal > "$STICKY"; bt_pulse wanted' >/dev/null 2>&1; echo $?)"

echo on > "$STUBDIR/state/bt-extras"
check "with the Bluetooth helpers on the watcher runs even without a codec" "0" \
    "$(with_audioctl 'echo standard > "$STICKY"; rm -f "$TRY"; bt_pulse wanted' >/dev/null 2>&1; echo $?)"

# --- the headset PulseAudio takes the wrong way round --------------------------
#
# BlueZ as busctl answers it: the soundcore opens two sink endpoints, though
# its list of services names AudioSource as well (measured 29.9.2026); ofono
# has one modem, with or without a call.
cat > "$STUBDIR/busctl" <<BUSCTL
#!/bin/sh
d="$STUBDIR"
echo "\$*" >> "\$d/busctl.args"
case "\$*" in
*"--list tree org.bluez") printf '/org/bluez\n/org/bluez/hci0\n/org/bluez/hci0/dev_F4_9D_8A_00_00_01\n/org/bluez/hci0/dev_F4_9D_8A_00_00_01/fd0\n/org/bluez/hci0/dev_F4_9D_8A_00_00_01/sep1\n/org/bluez/hci0/dev_F4_9D_8A_00_00_01/sep3\n/org/bluez/hci0/dev_98_52_3D_00_00_02/sep1\n' ;;
*"dev_F4_9D_8A_00_00_01/sep3 org.bluez.MediaEndpoint1 UUID")
    [ -e "\$d/source-sep" ] && echo 's "0000110a-0000-1000-8000-00805f9b34fb"' || echo 's "0000110b-0000-1000-8000-00805f9b34fb"' ;;
*"MediaEndpoint1 UUID") echo 's "0000110b-0000-1000-8000-00805f9b34fb"' ;;
# The soundcore's list of services names AudioSource too - which must not count.
*" UUIDs") echo 'as 3 "0000110a-0000-1000-8000-00805f9b34fb" "0000110b-0000-1000-8000-00805f9b34fb" "0000111e-0000-1000-8000-00805f9b34fb"' ;;
*GetModems*) echo 'a(oa{sv}) 1 "/ril_0" 1 "Online" b true' ;;
*GetCalls*) [ -e "\$d/in-call" ] && echo 'a(oa{sv}) 1 "/ril_0/voicecall01" 0' || echo 'a(oa{sv}) 0' ;;
esac
BUSCTL
chmod +x "$STUBDIR/busctl"
role() {
    rm -f "$STUBDIR/busctl.args" "$STUBDIR/pactl.args" "$STUBDIR/tried".*
    with_audioctl "BT_PULSE_SETTLE=0; BT_PULSE_TRIED=\"$STUBDIR/tried\"; bt_pulse_fix_role bluez_card.F4_9D_8A_00_00_01" 2>&1
}
dialled() { grep -q 'Device1 Connect$' "$STUBDIR/busctl.args" 2>/dev/null && echo yes || echo no; }

echo a2dp_sink > "$STUBDIR/pa-profile"
role >/dev/null
check "a headset playing music is left alone" "no" "$(dialled)"

touch "$STUBDIR/sink-stuck" "$STUBDIR/source-read"; echo a2dp_source > "$STUBDIR/pa-profile"
out=$(role)
check "taken for a sound source, it is dialled from the phone" "yes" "$(dialled)"
check "AudioSource in its list of services does not keep it from that" "yes" "$(dialled)"
check "after being taken down first" "yes" \
    "$(grep -q 'Device1 Disconnect$' "$STUBDIR/busctl.args" && echo yes || echo no)"
check "its loopback goes before the card - that order crashed PulseAudio" "yes" \
    "$(grep -qx 'unload-module 26' "$STUBDIR/pactl.args" && echo yes || echo no)"
check "and no other loopback" "no" \
    "$(grep -qx 'unload-module 27' "$STUBDIR/pactl.args" && echo yes || echo no)"
check "and it says why" "yes" \
    "$(case "$out" in *"without its music profile (a2dp_source)"*) echo yes ;; *) echo no ;; esac)"

echo handsfree_head_unit > "$STUBDIR/pa-profile"
role >/dev/null
check "on hands-free with the music read as a source, too (18:47)" "yes" "$(dialled)"
rm -f "$STUBDIR/source-read"
role >/dev/null
check "hands-free with no music connection is the reconnect helper's" "no" "$(dialled)"
touch "$STUBDIR/source-read"

echo a2dp_source > "$STUBDIR/pa-profile"
touch "$STUBDIR/in-call"
role >/dev/null
check "never during a call" "no" "$(dialled)"
rm -f "$STUBDIR/in-call"

touch "$STUBDIR/source-sep"
role >/dev/null
check "a device with a source endpoint of its own is left alone" "no" "$(dialled)"
rm -f "$STUBDIR/source-sep"

role >/dev/null
rm -f "$STUBDIR/busctl.args"
out=$(with_audioctl "BT_PULSE_SETTLE=0; BT_PULSE_TRIED=\"$STUBDIR/tried\"; bt_pulse_fix_role bluez_card.F4_9D_8A_00_00_01" 2>&1)
check "a second time within a minute it is not dialled again" "no" "$(dialled)"
check "and says so" "yes" \
    "$(case "$out" in *"still has no music profile"*) echo yes ;; *) echo no ;; esac)"

rm -f "$STUBDIR/state/bt-extras" "$STUBDIR/tried".* "$STUBDIR/busctl.args"
with_audioctl "BT_PULSE_SETTLE=0; BT_PULSE_TRIED=\"$STUBDIR/tried\"; bt_pulse_check" >/dev/null 2>&1
check "with the Bluetooth helpers off the watcher dials nothing" "no" "$(dialled)"
echo on > "$STUBDIR/state/bt-extras"
with_audioctl "BT_PULSE_SETTLE=0; BT_PULSE_TRIED=\"$STUBDIR/tried\"; bt_pulse_check" >/dev/null 2>&1
check "and with them on it does" "yes" "$(dialled)"
rm -f "$STUBDIR/sink-stuck" "$STUBDIR/source-read" "$STUBDIR/pa-profile" "$STUBDIR/busctl" "$STUBDIR/busctl.args" \
      "$STUBDIR/tried".* "$STUBDIR/state/bt-extras"

touch "$STUBDIR/no-card"
check "without a headset the list is what every PulseAudio here can do" "yes" \
    "$(with_audioctl 'bt_codec status' | grep -qx 'choices=auto sbc sbc_xq' && echo yes || echo no)"
rm -f "$STUBDIR/no-card" "$STUBDIR/pa-codec" "$STUBDIR/pactl.args" "$STUBDIR/bt-codec-pulse" \
      "$STUBDIR/systemctl.args" "$STUBDIR/pactl"
stub systemctl 0 ""

# --- our Bluetooth helpers belong to pw-hal ---------------------------------
#
# Under PulseAudio the phone is to behave as shipped, so the shipped behaviour
# can be tested on its own. The units stay enabled; their ExecCondition asks
# "audioctl is pw-hal", and a switch stops or starts what runs now.
run_is() {
    AUDIOCTL_STATE_DIR="$STUBDIR/state" bash "$HERE/../audioctl" is "$1"
}
mkdir -p "$STUBDIR/state"; rm -f "$STUBDIR/state/profile.try"
echo standard > "$STUBDIR/state/profile"
check_status "is: standard stored, asked for pw-hal -> no" 1 run_is pw-hal
check_status "is: standard stored, asked for standard -> yes" 0 run_is standard
echo pw-hal > "$STUBDIR/state/profile.try"
check_status "is: a test profile counts until the reboot" 0 run_is pw-hal
rm -f "$STUBDIR/state/profile.try"
check_status "is: without a profile name it refuses" 1 run_is ""

: > "$STUBDIR/systemctl.log"
cat > "$STUBDIR/systemctl" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >> "$STUBDIR/systemctl.log"
case "\$2" in is-active) exit 3 ;; esac
exit 0
STUB
chmod +x "$STUBDIR/systemctl"
( AUDIOCTL_LIB=1 AUDIOCTL_STATE_DIR="$STUBDIR/state" AUDIOCTL_ETCU="$STUBDIR/etc" \
    . "$HERE/../audioctl"; apply standard ) >/dev/null 2>&1
for u in pause-on-disconnect sco-hold bt-mic bt-reconnect; do
    check "switching to PulseAudio stops furios-audio-$u" "yes" \
        "$(grep -qx -- "--user stop furios-audio-$u.service" "$STUBDIR/systemctl.log" && echo yes || echo no)"
done
check "and disables none of them - the condition keeps them quiet" "" \
    "$(grep -E -- '--user disable furios-audio-(sco|bt|pause)' "$STUBDIR/systemctl.log")"
for u in furios-audio-pause-on-disconnect furios-audio-bt-reconnect furios-audio-sco-hold furios-audio-bt-mic; do
    check "$u.service asks whether it may run" "yes" \
        "$(grep -q "^ExecCondition=.* helper-allowed $u.service" "$HERE/../$u.service" && echo yes || echo no)"
done

# --- the two BlueZ-only helpers as an option outside pw-hal ------------------
run_ctl() {
    AUDIOCTL_STATE_DIR="$STUBDIR/state" bash "$HERE/../audioctl" "$@" 2>/dev/null
}
: > "$STUBDIR/systemctl.log"
echo standard > "$STUBDIR/state/profile"; rm -f "$STUBDIR/state/bt-extras"
check "off by default under PulseAudio" "bt-extras=off" "$(run_ctl bt-extras | head -1)"
check "and nothing runs" "effective=none" "$(run_ctl bt-extras | grep effective)"
check_status "pause-on-disconnect may not run" 1 run_ctl helper-allowed furios-audio-pause-on-disconnect.service
run_ctl bt-extras on >/dev/null
check "on writes the choice" "on" "$(cat "$STUBDIR/state/bt-extras")"
check "and says what runs" "effective=basic" "$(run_ctl bt-extras | grep effective)"
check_status "pause-on-disconnect may run now" 0 run_ctl helper-allowed furios-audio-pause-on-disconnect.service
check_status "reconnect too" 0 run_ctl helper-allowed furios-audio-bt-reconnect.service
check_status "but not the SCO hold - that is WirePlumber" 1 run_ctl helper-allowed furios-audio-sco-hold.service
check "on starts both at once" "yes" \
    "$(grep -qx -- '--user start furios-audio-bt-reconnect.service' "$STUBDIR/systemctl.log" && echo yes || echo no)"
: > "$STUBDIR/systemctl.log"
( AUDIOCTL_LIB=1 AUDIOCTL_STATE_DIR="$STUBDIR/state" AUDIOCTL_ETCU="$STUBDIR/etc" \
    . "$HERE/../audioctl"; apply standard ) >/dev/null 2>&1
check "a switch to PulseAudio leaves the chosen ones running" "" \
    "$(grep -E -- '--user stop furios-audio-(pause-on-disconnect|bt-reconnect)' "$STUBDIR/systemctl.log")"
check "and still stops the WirePlumber ones" "yes" \
    "$(grep -qx -- '--user stop furios-audio-sco-hold.service' "$STUBDIR/systemctl.log" && echo yes || echo no)"
: > "$STUBDIR/systemctl.log"
run_ctl bt-extras off >/dev/null
check "off stops them" "yes" \
    "$(grep -qx -- '--user stop furios-audio-pause-on-disconnect.service' "$STUBDIR/systemctl.log" && echo yes || echo no)"
check "and records off" "off" "$(cat "$STUBDIR/state/bt-extras")"

# Under pw-hal: on unless switched off - the stack as it was worked out.
rm -f "$STUBDIR/state/bt-extras"
echo pw-hal > "$STUBDIR/state/profile"
check "under pw-hal nothing chosen means everything runs" "effective=all" \
    "$(run_ctl bt-extras | grep effective)"
check_status "the SCO hold included" 0 run_ctl helper-allowed furios-audio-sco-hold.service
make_recording_stub wpctl 0 ""
rm -f "$STUBDIR/wpctl.args"
: > "$STUBDIR/systemctl.log"
run_ctl bt-extras off >/dev/null
check "off under pw-hal stops every helper" "yes" \
    "$(grep -qx -- '--user stop furios-audio-sco-hold.service' "$STUBDIR/systemctl.log" \
       && grep -qx -- '--user stop furios-audio-bt-mic.service' "$STUBDIR/systemctl.log" && echo yes || echo no)"
check "and tells WirePlumber's call routing to stand down" "yes" \
    "$(grep -q -- '--save furios.bluetooth-helpers false' "$STUBDIR/wpctl.args" && echo yes || echo no)"
check "nothing runs now" "effective=none" "$(run_ctl bt-extras | grep effective)"
check_status "not even the SCO hold" 1 run_ctl helper-allowed furios-audio-sco-hold.service
: > "$STUBDIR/systemctl.log"; rm -f "$STUBDIR/wpctl.args"
run_ctl bt-extras on >/dev/null
check "on starts them again" "yes" \
    "$(grep -qx -- '--user start furios-audio-sco-hold.service' "$STUBDIR/systemctl.log" && echo yes || echo no)"
check "and lets the routing act" "yes" \
    "$(grep -q -- '--save furios.bluetooth-helpers true' "$STUBDIR/wpctl.args" && echo yes || echo no)"
check "the routing choice itself is never touched" "no" \
    "$(grep -q 'bluetooth-call-routing' "$STUBDIR/wpctl.args" && echo yes || echo no)"
rm -f "$STUBDIR/wpctl" "$STUBDIR/wpctl.args"

# Leaving pw-hal with nothing chosen: off under PulseAudio, as before.
rm -f "$STUBDIR/state/bt-extras"
: > "$STUBDIR/systemctl.log"
( AUDIOCTL_LIB=1 AUDIOCTL_STATE_DIR="$STUBDIR/state" AUDIOCTL_ETCU="$STUBDIR/etc" \
    . "$HERE/../audioctl"; apply standard ) >/dev/null 2>&1
check "without a choice a switch to PulseAudio stops them all" "yes" \
    "$(grep -qx -- '--user stop furios-audio-bt-reconnect.service' "$STUBDIR/systemctl.log" && echo yes || echo no)"
check_status "an unknown word is refused" 1 run_ctl bt-extras maybe
rm -f "$STUBDIR/systemctl"

summary
