# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# shellcheck shell=sh
# Sourced, not run: the PipeWire version a plugin built here is built against.
#
# install-hal.sh used to ask pkg-config for libpipewire-0.3 alone and write
# "unknown" when that failed - and it fails on every phone without
# libpipewire-0.3-dev, which the plugin does not even need: it builds against
# libspa-0.2 (poc/spa-droid/meson.build). From then on audioctl warned at
# every switch that the plugin was "built against PipeWire unknown"
# (4.10.2026, an FLX1 that had built it the same day). libspa-0.2.pc says
# "0.2", so the version of the headers comes from their package instead.
#
# In order: pkg-config for libpipewire-0.3, the libspa-0.2-dev package
# (epoch and Debian revision stripped), the version the installed pipewire
# was compiled with. Prints nothing when none of them answers - the caller
# decides what to write then.
pw_version() {
    _v=$(pkg-config --modversion libpipewire-0.3 2>/dev/null) || _v=
    if [ -z "$_v" ]; then
        _v=$(dpkg-query -W -f='${Version}' libspa-0.2-dev 2>/dev/null \
            | sed -e 's/^[0-9]*://' -e 's/-[^-]*$//') || _v=
    fi
    if [ -z "$_v" ]; then
        _v=$(LC_ALL=C pipewire --version 2>/dev/null \
            | sed -n 's/^Compiled with libpipewire \([0-9][0-9.]*\).*/\1/p' \
            | head -n 1) || _v=
    fi
    printf '%s' "$_v"
}
