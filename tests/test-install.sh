#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Do the three ways in and out of this repo still agree with each other?
#
# They did not. install.sh knew three units while audioctl knew seven, so a
# script install left the Bluetooth call hold, the Bluetooth microphone, the
# pause-on-disconnect watcher and the callaudiod refresh on the floor - and
# the plugin that makes PipeWire talk to the HAL was not installed at all,
# only described in the README. uninstall.sh had drifted the same way, and
# packaging/build-deb.sh had gone on installing an app that had moved to its
# own repository, so the package could not be built at all.
#
# Nothing here needs root, a phone or a build tree: it reads the scripts.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
# shellcheck source=lib.sh
. "$HERE/lib.sh"

cd "$ROOT"

contains() {
    # contains <file> <word> -> "yes" / "no"
    if grep -q -- "$2" "$1"; then echo yes; else echo no; fi
}

echo "-- every unit in this repo is installed, removed and packaged"
for unit in furios-*.service; do
    name=${unit%.service}
    check "install.sh installs $name"   yes "$(contains install.sh "$unit")"
    check "uninstall.sh removes $name"  yes "$(contains uninstall.sh "$unit")"
    check "the package ships $name"     yes "$(contains packaging/build-deb.sh "$unit")"
done

echo
echo "-- every program a unit starts is installed, removed and packaged"
# The name in ExecStart is the contract. A unit whose program nobody installs
# fails at the first start with status=203/EXEC, which reads like a broken
# program rather than a missing one.
programme=$(grep -h "^ExecStart=/usr/bin/furios" furios-*.service \
            | sed 's|^ExecStart=/usr/bin/||' | sort -u)
# Started with sudo, install.sh used to build the plugin, copy half the files
# and then stop at the first "systemctl --user" - root has no session bus. The
# chown further down is worse than the abort: it takes its owner from "id -un",
# so as root the state directory would end up owned by root and audioctl, which
# never runs as root, could not write its profile. The guard has to sit before
# any of that happens, so this checks that it is in the first few lines.
check "install.sh weist root ab" "yes" \
    "$(grep -q 'id -u.*= *0' "$ROOT/install.sh" && echo yes || echo no)"
check "and before anything at all is installed" "yes" \
    "$(awk '/id -u.*= *0/{guard=NR} /^[[:space:]]*sudo /{if(!guard){print "no"; exit}} END{if(guard)print "yes"}' \
        "$ROOT/install.sh")"

for prog in $programme; do
    check "install.sh installs $prog"  yes "$(contains install.sh "$prog")"
    check "uninstall.sh removes $prog" yes "$(contains uninstall.sh "$prog")"
    check "the package ships $prog"    yes "$(contains packaging/build-deb.sh "$prog")"
done

# A unit is copied as it is into both installs, so a path under /usr/local in
# its ExecStart has to come with the /usr one the package uses. The tunnel unit
# named /usr/local alone and could never start from the .deb.
for unit in furios-*.service systemd/*.service; do
    one_place=0
    while read -r line; do
        for p in $(printf '%s\n' "$line" | grep -oE '/usr/local/[^ ";]+'); do
            case "$line" in *"/usr/${p#/usr/local/}"*) ;; *) one_place=$((one_place + 1)) ;; esac
        done
    done < <(grep -E '^Exec(Start|Stop)(Pre|Post)?=' "$unit")
    check "$(basename "$unit") finds its files in both installs" 0 "$one_place"
done

echo
echo "-- every WirePlumber script is installed, removed and packaged"
for lua in wireplumber/*.lua wireplumber/*.conf; do
    name=$(basename "$lua")
    check "install-hal.sh installs $name" yes "$(contains install-hal.sh "$name")"
    check "uninstall.sh removes $name"    yes "$(contains uninstall.sh "$name")"
    check "the package ships $name"       yes "$(contains packaging/build-deb.sh "$name")"
done

echo
echo "-- the WirePlumber drop-in and the helper it starts"
for name in furios-bluez5-fix.conf furios-audio-bluez5-fix; do
    check "install-hal.sh installs $name" yes "$(contains install-hal.sh "$name")"
    check "uninstall.sh removes $name"    yes "$(contains uninstall.sh "$name")"
    check "the package ships $name"       yes "$(contains packaging/build-deb.sh "$name")"
done
check "both fill in the architecture" yes \
    "$(grep -q '@TRIPLET@' install-hal.sh && grep -q '@TRIPLET@' packaging/build-deb.sh \
       && echo yes || echo no)"

echo
echo "-- the one entry point does the whole job"
check "install.sh builds the plugin" yes "$(contains install.sh build-plugin.sh)"
check "install.sh installs the HAL side" yes "$(contains install.sh install-hal.sh)"
check "the plugin build pins its upstream commit" yes \
    "$(contains tools/build-plugin.sh 'COMMIT=')"
# Nothing the package ships may come from a directory that is not here any
# more: that is how build-deb.sh broke without anybody noticing.
missing=0
while read -r source_file; do
    [ -e "$source_file" ] || { missing=$((missing + 1)); echo "       not in this repo: $source_file"; }
done < <(grep -oE '^install -Dm[0-9]+ [^ "]+' packaging/build-deb.sh | awk '{print $3}')
check "the package installs only files that exist here" 0 "$missing"

# The same for the two install scripts. A source path that is one letter off
# fails in the middle of an install, with half the stack in place - and on a
# phone, half a stack is a phone without sound.
missing=0
while read -r source_file; do
    case "$source_file" in *'$'*) continue ;; esac
    [ -e "$source_file" ] || { missing=$((missing + 1)); echo "       not in this repo: $source_file"; }
done < <(grep -hoE 'sudo install -[Dm0-9]+ +[^ "$]+' install.sh install-hal.sh | awk '{print $4}'
         grep -hoE '^ *orig_install [0-9]+ +[^ "$]+' install.sh install-hal.sh | awk '{print $3}')
check "both install scripts copy only files that exist here" 0 "$missing"
# And they do copy something - through orig_install, which records what was
# there first. A plain "sudo install" would write without a record, and the
# check above, which looks for either, would not notice the difference.
check "no plain \"sudo install\" left - every write goes through the record" 0 \
    "$(grep -hcE '^[^#]*sudo (install|tee|cp|ln) ' install.sh install-hal.sh | awk '{s+=$1} END {print s+0}')"
check "and orig_install is what copies" yes \
    "$([ "$(grep -hcE '^ *orig_install ' install.sh install-hal.sh | awk '{s+=$1} END {print s+0}')" -gt 20 ] && echo yes || echo no)"

echo
echo "-- the package's postinst does not write through a link it finds"
# Run as root on an upgrade, in a directory that by then belongs to the user.
# "profile" there is whatever they made it, and a symlink to /etc/shadow used
# to come out world-readable: [ -e ] followed it, skipped the write, and the
# chmod 0644 after it followed it as well. Run here unprivileged against a
# stand-in directory - the chmod follows a link for anyone who owns the target.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
awk '/^cat > "\$STAGE\/DEBIAN\/postinst" <</{on=1; next} on && /^EOF$/{exit} on' \
    packaging/build-deb.sh > "$T/postinst.in"
run_postinst() {
    sed -e "s|/var/lib/furios-audio|$1|g" -e "s|/usr/bin/audioctl|$T/no-audioctl|g" \
        "$T/postinst.in" > "$T/postinst"
    SUDO_USER=$(id -un) sh "$T/postinst" configure >/dev/null 2>&1
}
check "postinst found in build-deb.sh" yes "$([ -s "$T/postinst.in" ] && echo yes || echo no)"

mkdir "$T/a"
: > "$T/victim"; chmod 0600 "$T/victim"
ln -s "$T/victim" "$T/a/profile"
run_postinst "$T/a"
check "a linked profile's target keeps its mode" 600 "$(stat -c %a "$T/victim")"
check "the profile is a file of its own afterwards" "standard" \
    "$([ -f "$T/a/profile" ] && [ ! -L "$T/a/profile" ] && cat "$T/a/profile")"

mkdir "$T/b"
ln -s "$T/created-by-root" "$T/b/profile"
run_postinst "$T/b"
check "a dangling link creates nothing" no \
    "$([ -e "$T/created-by-root" ] && echo yes || echo no)"


echo
echo "-- the version a plugin is built against, without libpipewire-0.3-dev"
# pw_version with stand-ins for pkg-config, dpkg-query and pipewire. The FLX1
# that wrote "unknown" (4.10.2026) had libspa-0.2-dev but no libpipewire-0.3-dev.
pwv() {
    # pwv <pkg-config answer|-> <dpkg-query answer|-> <pipewire answer|->
    local d="$T/pwv.$RANDOM" tool answer
    mkdir -p "$d"
    for tool in pkg-config dpkg-query pipewire; do
        answer=$1; shift
        if [ "$answer" = - ]; then
            printf '#!/bin/sh\nexit 1\n' > "$d/$tool"
        else
            printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$answer" > "$d/$tool"
        fi
        chmod +x "$d/$tool"
    done
    ( PATH="$d:$PATH"; . "$ROOT/tools/pw-version.sh"; pw_version )
}
check "pkg-config first, when it knows" 1.6.6 "$(pwv 1.6.6 1.5.0-1 -)"
check "the libspa headers' package without libpipewire-0.3-dev" 1.6.6 "$(pwv - 1.6.6-1 -)"
check "an epoch and a Debian revision are not part of it" 1.6.6 "$(pwv - 2:1.6.6-1+b2 -)"
check "the compiled-in version as the last answer" 1.6.6 \
    "$(pwv - - 'Compiled with libpipewire 1.6.6')"
check "nothing at all is nothing, not a guess" "" "$(pwv - - -)"
check "install-hal.sh asks pw_version" yes "$(contains install-hal.sh 'pw_version')"
check "the package build asks pw_version" yes "$(contains packaging/build-deb.sh 'pw_version')"
check "and the package has no fixed version to fall back on" no \
    "$(contains packaging/build-deb.sh '|| echo 1\.')"

summary
