#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""Give PipeWire's hands-free gateway a call index a car kit will accept.

PipeWire answers a car's AT+CLCC ("which calls are there?") with
"+CLCC: <idx>,<dir>,<state>,...", and <idx> comes from call->index - which
spa/plugins/bluez5/modemmanager.c never sets. Every call therefore goes out as
call 0. 3GPP TS 27.007 numbers calls from 1, and a strict hands-free unit drops
the entry: measured on 2026-09-25 with an Audi A6 (2013, MMI 3G, HFP 1.5),
which polls AT+CLCC once a second. The phone showed an active call, the SCO
link was up, the HAL routed to "BT SCO" - and the car displayed nothing, kept
the radio playing and neither played nor recorded a word. With index 1 the
display, the radio and both directions of speech were right at once. Earbuds
never look at the list, which is why they always worked.

Still true in PipeWire 1.6.6 and on master. The real fix belongs upstream: give
each call a number when ModemManager announces it. Until then, this.

What it does: before WirePlumber starts, it copies the system's
libspa-bluez5.so to $XDG_RUNTIME_DIR/furios-audio/spa-0.2/bluez5/ and changes
one instruction in the copy - the load of call->index for the +CLCC reply,
"ldr w2, [x20, #16]", becomes "mov w2, #1". Nothing under /usr is touched, and
no string is edited: the format strings may share their tails with other
literals (the linker merges string suffixes), so editing one could change text
somewhere else.

WirePlumber's drop-in puts that directory IN FRONT of the system one in
SPA_PLUGIN_DIR. PipeWire walks the list, so everything else - the codecs, the
droid plugin, every other SPA plugin - still comes from the system, and when
there is no copy WirePlumber simply loads the original.

That is also the safety rule, and it has three parts. The library must be an
aarch64 ELF on an aarch64 machine - the bytes below are aarch64 instructions.
Its GNU build-id must be one listed in KNOWN_LIBRARIES: a library somebody
looked at, disassembled around the match and tried in the car. And the
instruction sequence around the load has to appear exactly once, byte for
byte. The sequence check alone was the first version; it is a good guard
against a changed compiler output, but it says nothing about whether the
struct around it still has the index at offset 16 - a rebuild that moved the
field and kept the sequence would be patched without a word. The build-id
closes that: any rebuild, even of the same source, is a different library
until somebody has checked it and added it here.

On any mismatch no copy is written, and WirePlumber loads the unpatched
plugin - the car goes quiet again, but nothing else breaks. The reason goes
to the journal once per library (not at every WirePlumber restart), into
$XDG_RUNTIME_DIR/furios-audio/bluez5-fix.state, and "audioctl status" asks
this script (--check) and shows "bluez5 fix not applied: library changed",
so a PipeWire update cannot drop the fix silently. The copy lives on tmpfs and
is rebuilt at every WirePlumber start, so it can never outlive the library it
was made from.

Adding a library after a PipeWire update: "furios-audio-bluez5-fix --check"
prints its build-id and whether the sequence still fits. If it does, look at
the disassembly around it (objdump -d, the loop that formats +CLCC in
rfcomm_send_reply's caller) before adding the build-id to KNOWN_LIBRARIES.

Why not build the plugin from source instead, the way
tools/build-bluez5-aac.sh builds the AAC module: that script builds ONE codec
module from upstream's tag, which loads beside Debian's libspa-bluez5. A fixed
libspa-bluez5 would replace Debian's whole Bluetooth plugin - the backends,
every codec's interface, Debian's patches and build options - with our own
build, on every phone, with the Bluetooth plugin's whole set of build
dependencies, for what is a one-word fix. The copy changes four bytes of Debian's own library and
falls back to it on any doubt; the source patch belongs upstream
(upstream/pipewire-1-clcc-call-index.md), not in a second Bluetooth stack.

Known limit: every call is number 1. With a second call waiting, a car shows
both as the same call. One call at a time - the case this is for - is right.
"""

import glob
import os
import struct
import sys
import tempfile

# The loop in backend-native.c that answers AT+CLCC, as built in Debian's
# PipeWire 1.6.6 (aarch64). It loads the fields of struct call for
# rfcomm_send_reply():
#   ldr  x22, [x20, #48]     number
#   ldp  w3, w4, [x20, #60]  direction, state
#   ldrb w5, [x20, #68]      multiparty
#   ldr  w2, [x20, #16]      index            <- this one
#   cbnz x22, ...            with or without a number
SIGNATURE = bytes.fromhex("961a40f9 83924729 85124139 821240b9 16fdffb5"
                          .replace(" ", ""))
LOAD_INDEX = bytes.fromhex("821240b9")   # ldr w2, [x20, #16]
INDEX_ONE = bytes.fromhex("22008052")    # mov w2, #1
OFFSET_IN_SIGNATURE = 12

SYSTEM_GLOB = "/usr/lib/*/spa-0.2/bluez5/libspa-bluez5.so"

# The libraries this was checked against, by GNU build-id. A build-id names one
# build: a Debian rebuild of the same version gets a new one, and has to be
# looked at again before it is added. See the module docstring for how.
KNOWN_LIBRARIES = {
    "090228d001b04f7c681058df94d4e3b3d7614f28":
        "Debian libspa-0.2-bluetooth 1.6.6-1 arm64 (checked 2026-09-25, Audi A6)",
}

EM_AARCH64 = 183
PT_NOTE = 4
NT_GNU_BUILD_ID = 3

# Where the result of the last run is kept, so the journal hears about a
# library that does not fit once rather than at every WirePlumber restart.
STATE_NAME = "bluez5-fix.state"


def log(message):
    print(f"furios-audio-bluez5-fix: {message}", file=sys.stderr)


def elf_identity(data):
    """(e_machine, build-id as hex or None) of a little-endian ELF64 file.

    Raises ValueError for anything else. Reads the program headers only:
    PT_NOTE is what the loader maps, and that is where the build-id lives."""
    if data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise ValueError("not a little-endian 64-bit ELF file")
    machine, = struct.unpack_from("<H", data, 18)
    phoff, = struct.unpack_from("<Q", data, 32)
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    for i in range(phnum):
        at = phoff + i * phentsize
        p_type, = struct.unpack_from("<I", data, at)
        if p_type != PT_NOTE:
            continue
        offset, = struct.unpack_from("<Q", data, at + 8)
        size, = struct.unpack_from("<Q", data, at + 32)
        end = min(offset + size, len(data))
        while offset + 12 <= end:
            namesz, descsz, ntype = struct.unpack_from("<III", data, offset)
            name_at = offset + 12
            desc_at = name_at + ((namesz + 3) & ~3)
            if ntype == NT_GNU_BUILD_ID \
                    and data[name_at:name_at + namesz] == b"GNU\x00":
                return machine, data[desc_at:desc_at + descsz].hex()
            offset = desc_at + ((descsz + 3) & ~3)
    return machine, None


def host_machine():
    return os.uname().machine


def evaluate(data, known=None, machine=None):
    """(patched library or None, reason or None, build-id or None).

    Every check has to pass, in this order: the machine, the file's
    architecture, its build-id, and the instruction sequence."""
    known = KNOWN_LIBRARIES if known is None else known
    machine = host_machine() if machine is None else machine
    if machine != "aarch64":
        return None, f"this is {machine}, not aarch64", None
    try:
        e_machine, build_id = elf_identity(data)
    except (ValueError, struct.error) as e:
        return None, f"library changed: {e}", None
    if e_machine != EM_AARCH64:
        return None, f"library changed: not an aarch64 library " \
                     f"(e_machine {e_machine})", build_id
    if build_id is None:
        return None, "library changed: it has no build-id", None
    if build_id not in known:
        return None, f"library changed: build-id {build_id} is not one " \
                     "this fix was checked against", build_id
    patched, why = patch(data)
    if patched is None:
        return None, f"library changed: {why}", build_id
    return patched, None, build_id


def patch(data):
    """The patched library, or None with the reason when it does not fit."""
    first = data.find(SIGNATURE)
    if first < 0:
        return None, "the +CLCC code is not the one this was made for"
    if data.find(SIGNATURE, first + 1) >= 0:
        return None, "the +CLCC code appears more than once"
    at = first + OFFSET_IN_SIGNATURE
    assert data[at:at + 4] == LOAD_INDEX
    return data[:at] + INDEX_ONE + data[at + 4:], None


def overlay_path(runtime_dir):
    return os.path.join(runtime_dir, "furios-audio", "spa-0.2", "bluez5",
                        "libspa-bluez5.so")


def state_path(runtime_dir):
    return os.path.join(runtime_dir, "furios-audio", STATE_NAME)


def state_text(reason, build_id):
    lines = [f"clcc={'not-applied' if reason else 'applied'}"]
    if reason:
        lines.append(f"clcc-reason={reason}")
    lines.append(f"build-id={build_id or ''}")
    return "\n".join(lines) + "\n"


def remember(runtime_dir, text):
    """Write the state file; True when it says something new."""
    path = state_path(runtime_dir)
    try:
        with open(path) as f:
            if f.read() == text:
                return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    return True


def read_library(system_glob):
    """(path, bytes) of the one system library, or (None, reason)."""
    found = glob.glob(system_glob)
    if len(found) != 1:
        return None, f"expected one libspa-bluez5.so, found {len(found)}"
    with open(found[0], "rb") as f:
        return found[0], f.read()


def check(system_glob=SYSTEM_GLOB, known=None, machine=None, out=sys.stdout):
    """What the next WirePlumber start would do, written nowhere but out.

    For "audioctl status" and for whoever adds a library to the list."""
    path, data = read_library(system_glob)
    if path is None:
        reason, build_id = f"library changed: {data}", None
    else:
        _, reason, build_id = evaluate(data, known, machine)
    out.write(state_text(reason, build_id))
    if path is not None:
        out.write(f"library={path}\n")
    return 0


def run(system_glob=SYSTEM_GLOB, runtime_dir=None, known=None, machine=None):
    runtime_dir = runtime_dir or os.environ.get("XDG_RUNTIME_DIR")
    if not runtime_dir:
        log("no XDG_RUNTIME_DIR - leaving the plugin as it is")
        return 0
    target = overlay_path(runtime_dir)

    # Whatever happens next, an old copy must not survive: it was made from a
    # library that may since have been replaced.
    try:
        os.unlink(target)
    except FileNotFoundError:
        pass

    path, data = read_library(system_glob)
    if path is None:
        patched, reason, build_id = None, f"library changed: {data}", None
    else:
        patched, reason, build_id = evaluate(data, known, machine)

    news = remember(runtime_dir, state_text(reason, build_id))
    if patched is None:
        # Once per library, not at every WirePlumber restart - and then loud
        # enough to be found: this is the moment the car goes quiet.
        if news:
            log(f"bluez5 fix not applied: {reason} - WirePlumber loads the "
                "original, and a car kit will not see calls. "
                "See furios-audio-bluez5-fix --check")
        return 0

    os.makedirs(os.path.dirname(target), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(patched)
        os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    except BaseException:
        os.unlink(tmp)
        raise
    log(f"+CLCC call index fixed in {target}")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--check"]:
        try:
            sys.exit(check())
        except Exception as e:
            print(f"clcc=not-applied\nclcc-reason=check failed ({e})")
            sys.exit(0)
    try:
        sys.exit(run())
    except Exception as e:  # never keep WirePlumber from starting
        log(f"failed ({e}) - WirePlumber loads the original")
        sys.exit(0)
