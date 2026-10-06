# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# What a path looked like before furios_audio first touched it - and putting
# it back from exactly that.
#
# Sourced, not run: by install.sh, install-hal.sh, uninstall.sh,
# tools/build-plugin.sh (and an older tools/build-bluez5-aac.sh) for the system side, and
# by audioctl for what it writes under $HOME.
#
# Why this exists
# ---------------
# uninstall.sh used to restore the phone from what it BELIEVED the phone
# looked like as shipped. It recreated three masks in /etc/systemd/user
# whether or not they had been there, deleted ~/.local/state/wireplumber
# whatever was in it, removed every want for wireplumber.service under
# ~/.config - also one somebody had set up long before this repo existed - and
# took every "*.wants/furios-*" link, which since furios_gps and the battery
# plugin also means other repositories' units. Each of those is a guess about
# somebody else's phone, and the rule this file implements is that nothing is
# guessed:
#
#   1. Before the FIRST change to a path, what is there is written down:
#      absent, a file (copied, mode and all), a link (copied as a link), a
#      directory. A later install or a second switch never overwrites that
#      record - the first original is the one that counts.
#   2. Putting it back uses the record, and only while the path is still what
#      WE made it. If somebody changed it since, it is left alone and the
#      output says so.
#   3. No record at all - the phone was set up by a version older than this
#      file - means the old behaviour, announced rather than silent.
#
# A path that already holds something OURS when it is first recorded (an older
# install of this repo put it there) is recorded as "unknown": what was there
# before that older install is not knowable any more, and pretending our own
# file was the original would make every later uninstall put it back.
#
# Layout under $ORIG_DIR, one entry per absolute path P:
#   meta/P.@   one line: absent | unknown | file <mode> <sha256> | link <target>
#              | dir <hash> | container | container-absent | container-unknown
#   data/P     the copy of a file, link or directory tree
#   ours/P.@   what we last wrote there (same format), so "still ours" can be
#              decided by comparison rather than by name
# The ".@" suffix keeps a directory's record from colliding with the records
# of paths inside it.
#
# Two callers, two places (see README, "What an uninstall puts back"):
#   system  ORIG_DIR=/var/lib/furios-audio-original  ORIG_SU=sudo
#           root-owned on purpose - it decides what gets written into /etc and
#           /usr on the way out, so it must not be writable by the account
#           whose phone it is (/var/lib/furios-audio is, for the profile).
#   user    ORIG_DIR=~/.config/furios-audio/original  ORIG_SU=
#           beside the headsets audioctl remembers; nothing there needs root.

ORIG_SU=${ORIG_SU-}

# Run with or without sudo. Unquoted on purpose: an empty ORIG_SU disappears.
_orig() { $ORIG_SU "$@"; }

_orig_meta() { printf '%s/meta%s.@' "$ORIG_DIR" "$1"; }
_orig_ours() { printf '%s/ours%s.@' "$ORIG_DIR" "$1"; }
_orig_data() { printf '%s/data%s' "$ORIG_DIR" "$1"; }

# Messages go to stdout, one line each, so an uninstall log reads as a list.
_orig_say() { printf '  %s\n' "$*"; }

# What is at a path now, in the record's words.
orig_fingerprint() {
    local p=$1
    if _orig test -L "$p"; then
        printf 'link %s\n' "$(_orig readlink "$p")"
    elif _orig test -d "$p"; then
        # A tree: every entry's type, mode, name and link target, and every
        # file's content. Enough to tell "as it was" from "anything else".
        printf 'dir %s\n' "$(_orig sh -c 'cd "$1" && { find . -printf "%y %m %p %l\n" | LC_ALL=C sort
            find . -type f -exec sha256sum {} + | LC_ALL=C sort; }' _ "$p" \
            | sha256sum | cut -c1-64)"
    elif _orig test -e "$p"; then
        printf 'file %s %s\n' "$(_orig stat -c %a "$p")" \
            "$(_orig sha256sum "$p" | cut -c1-64)"
    else
        printf 'absent\n'
    fi
}

orig_has_record() { _orig test -e "$(_orig_meta "$1")"; }
orig_recorded()   { _orig cat "$(_orig_meta "$1")" 2>/dev/null; }

_orig_write() {
    # _orig_write <file> <line>
    _orig mkdir -p "$(dirname "$1")" || return 1
    printf '%s\n' "$2" | _orig tee "$1" >/dev/null
}

# orig_record <path> [--ours-if-present]
#
# Before the first write to a file, link or directory tree. With
# --ours-if-present the caller says that anything found there can only be an
# older install of ours, so it becomes "unknown" rather than an original.
orig_record() {
    local p=$1 flag=${2:-} fp
    orig_has_record "$p" && return 0
    fp=$(orig_fingerprint "$p")
    if [ "$fp" != absent ] && [ "$flag" = --ours-if-present ]; then
        fp=unknown
    fi
    case "$fp" in
    file*|link*|dir*)
        _orig mkdir -p "$(dirname "$(_orig_data "$p")")" || return 1
        _orig rm -rf "$(_orig_data "$p")"
        _orig cp -a "$p" "$(_orig_data "$p")" || return 1 ;;
    esac
    _orig_write "$(_orig_meta "$p")" "$fp"
}

# orig_record_dir <dir> [--ours-if-present]
#
# For a directory we only put things INTO (/usr/local/share/wireplumber,
# ~/.config/systemd/user). Its content is not copied - it is not ours - only
# whether it was there, so that the way out removes it only if we made it.
orig_record_dir() {
    local p=$1 flag=${2:-} kind
    orig_has_record "$p" && return 0
    if _orig test -d "$p"; then
        kind=container
        [ "$flag" = --ours-if-present ] && kind=container-unknown
    else
        kind=container-absent
    fi
    _orig_write "$(_orig_meta "$p")" "$kind"
}

# After writing: what we put there, so the way out can tell whether it is
# still ours. Overwritten at every write - it is the LAST thing we wrote that
# counts here, not the first.
orig_mark_ours() {
    _orig_write "$(_orig_ours "$1")" "$(orig_fingerprint "$1")"
}

# orig_restore <path> [is-ours-function]
#
# Returns 0 when the path is as recorded afterwards (put back, or nothing to
# do), 1 when it was left alone because it is no longer ours, 3 when there is
# no record. The function, if given, is asked "is what is here now ours?"
# when there is no fingerprint of our own to compare with - audioctl uses it
# for masks, copies and wants, which it recognises by what they are.
orig_restore() {
    local p=$1 ours_fn=${2:-} was cur mine
    orig_has_record "$p" || return 3
    was=$(orig_recorded "$p")
    case "$was" in
    container) return 0 ;;
    container-absent|container-unknown)
        if _orig test -d "$p" && ! _orig test -L "$p"; then
            _orig rmdir "$p" 2>/dev/null \
                || { [ "$was" = container-absent ] \
                     && _orig_say "left in place - not empty, and not only ours: $p"; }
        fi
        return 0 ;;
    esac
    cur=$(orig_fingerprint "$p")
    [ "$cur" = "$was" ] && return 0
    # Unknown before, gone now: the old way out would have removed it too.
    [ "$was" = unknown ] && [ "$cur" = absent ] && return 0
    # Still ours? Our own fingerprint first; the caller's judgement where we
    # never took one; nothing at all is ours by default only when the record
    # itself says our older install was all there ever was.
    if _orig test -e "$(_orig_ours "$p")"; then
        mine=$(_orig cat "$(_orig_ours "$p")")
        if [ "$cur" != "$mine" ] && ! { [ -n "$ours_fn" ] && "$ours_fn" "$p"; }; then
            _orig_say "left alone - changed since furios_audio wrote it: $p"
            return 1
        fi
    elif [ -n "$ours_fn" ]; then
        if ! "$ours_fn" "$p"; then
            _orig_say "left alone - changed since furios_audio wrote it: $p"
            return 1
        fi
    elif [ "$cur" = absent ]; then
        # Gone, and we never wrote it: somebody else removed it. Not ours to
        # put back.
        _orig_say "left alone - removed by somebody else since: $p"
        return 1
    elif [ "$was" != unknown ]; then
        _orig_say "left alone - changed since furios_audio first saw it: $p"
        return 1
    fi
    _orig rm -rf "$p" || return 1
    case "$was" in
    absent) ;;
    unknown)
        _orig_say "removed, with no record of what was there before (an older version installed it): $p" ;;
    *)
        _orig mkdir -p "$(dirname "$p")" || return 1
        _orig cp -a "$(_orig_data "$p")" "$p" || return 1
        _orig_say "put back as it was before furios_audio: $p" ;;
    esac
    return 0
}

# Every recorded path, files before directories and the deepest directory
# first - so a directory is only looked at once what we put in it is gone.
orig_recorded_paths() {
    _orig test -d "$ORIG_DIR/meta" || return 0
    _orig find "$ORIG_DIR/meta" -name '*.@' -printf '%P\n' 2>/dev/null \
        | sed 's/\.@$//; s|^|/|' \
        | while IFS= read -r p; do
            case "$(orig_recorded "$p")" in
            container*) printf '1 %05d %s\n' "$((99999 - $(printf '%s' "$p" | tr -cd / | wc -c)))" "$p" ;;
            *)          printf '0 00000 %s\n' "$p" ;;
            esac
        done | LC_ALL=C sort | cut -d' ' -f3-
}

orig_restore_all() {
    local p rc=0
    while IFS= read -r p; do
        orig_restore "$p" "${1:-}" || rc=1
    done < <(orig_recorded_paths)
    return "$rc"
}

# --- packages ---------------------------------------------------------------
#
# tools/build-plugin.sh installs what the build needs. What was NOT installed
# before - the named packages and whatever apt pulled in with them - is
# written down, once, with what dpkg had on it ("absent" or "config-files"),
# and the way out removes exactly those again.

orig_installed_packages() {
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null \
        | awk '$1 ~ /^.i/ {print $2}' | LC_ALL=C sort -u
}

# orig_packages_snapshot <file>: what is installed now, and beside it
# (<file>.rc) what is only left as configuration files.
orig_packages_snapshot() {
    orig_installed_packages > "$1"
    dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null \
        | awk '$1 ~ /^rc/ {print $2}' | LC_ALL=C sort -u > "$1.rc"
}

# orig_packages_added <snapshot taken before the install>
orig_packages_added() {
    local before=$1 list pkg state
    list=$ORIG_DIR/packages
    _orig mkdir -p "$ORIG_DIR" || return 1
    LC_ALL=C comm -13 "$before" <(orig_installed_packages) | while read -r pkg; do
        _orig grep -q "^$pkg " "$list" 2>/dev/null && continue
        state=absent
        grep -qx "$pkg" "$before.rc" 2>/dev/null && state=config-files
        printf '%s %s\n' "$pkg" "$state" | _orig tee -a "$list" >/dev/null
    done
}

# Remove them again - but only if apt would take nothing else with them. A
# package the user has since built on is not ours to pull out from under it.
orig_restore_packages() {
    local list=$ORIG_DIR/packages have purge=() remove=() extra pkg state
    _orig test -s "$list" || return 0
    have=$(orig_installed_packages)
    while read -r pkg state; do
        printf '%s\n' "$have" | grep -qx "$pkg" || continue
        if [ "$state" = config-files ]; then remove+=("$pkg"); else purge+=("$pkg"); fi
    done < <(_orig cat "$list")
    [ $((${#purge[@]} + ${#remove[@]})) -gt 0 ] || return 0
    extra=$(apt-get -s purge ${purge[@]+"${purge[@]}"} ${remove[@]+"${remove[@]}"} 2>/dev/null \
        | sed -n 's/^\(Purg\|Remv\) \([^ ]*\).*/\2/p' \
        | grep -vxF -f <(printf '%s\n' ${purge[@]+"${purge[@]}"} ${remove[@]+"${remove[@]}"}))
    if [ -n "$extra" ]; then
        _orig_say "left installed - removing them would also take: $(printf '%s' "$extra" | paste -sd' ' -)"
        _orig_say "  what the build installed: ${purge[*]:-} ${remove[*]:-}"
        return 1
    fi
    [ ${#purge[@]} -gt 0 ] && { _orig env DEBIAN_FRONTEND=noninteractive apt-get purge -y -q "${purge[@]}" >/dev/null || return 1; }
    [ ${#remove[@]} -gt 0 ] && { _orig env DEBIAN_FRONTEND=noninteractive apt-get remove -y -q "${remove[@]}" >/dev/null || return 1; }
    _orig_say "removed what the plugin build had installed: ${purge[*]:-} ${remove[*]:-}"
    return 0
}

# --- the system side, as the install scripts use it -------------------------

# Root-owned and closed: see the top of this file for why this is not
# /var/lib/furios-audio.
orig_use_system() {
    ORIG_DIR=/var/lib/furios-audio-original
    ORIG_SU=sudo
    sudo mkdir -p "$ORIG_DIR" && sudo chmod 0700 "$ORIG_DIR"
}

# orig_install <mode> <source> <destination>
#
# "sudo install", with the record before and our fingerprint after. Every
# destination the install scripts write is a name only this repo uses, so
# anything already there is an older install of ours.
orig_install() {
    orig_record "$3" --ours-if-present || return 1
    sudo install -m"$1" "$2" "$3" || return 1
    orig_mark_ours "$3"
}

# orig_install_stdin <mode> <destination> - the same, for generated content.
orig_install_stdin() {
    orig_record "$2" --ours-if-present || return 1
    sudo tee "$2" >/dev/null || return 1
    sudo chmod "$1" "$2" || return 1
    orig_mark_ours "$2"
}

# orig_mkdir <dir>... - "sudo mkdir -p", remembering which of them (and of
# their parents) we are the ones to create.
orig_mkdir() {
    local d parts
    for d in "$@"; do
        parts=$d
        # Up to the first one that is already there, and that one too: its
        # parents exist as surely as it does, and a record saying so keeps
        # the way out from removing it merely because it has become empty.
        while [ "$parts" != / ] && [ -n "$parts" ]; do
            orig_record_dir "$parts"
            _orig test -d "$parts" && break
            parts=$(dirname "$parts")
        done
        sudo mkdir -p "$d" || return 1
    done
}
