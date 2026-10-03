#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""Turns the unmodified droid-util.c into a version usable from SPA.

The only code excluded is code that dereferences PulseAudio graph objects
(pa_sink, pa_card, hooks). Those functions have no counterpart in the SPA
plugin - there the SPA device handles port and profile management.

Reproducible: can be run again after an upstream update.
"""
import re
import sys

# Whole functions that dereference PA graph objects.
EXCLUDE_FUNCS = [
    "add_ports",                  # creates a pa_device_port
    "pa_droid_add_ports",         # card->core, card->ports
    "pa_droid_add_card_ports",    # pa_card_profile
    "update_sink_types",          # sink->...
    "sink_put_hook_cb",           # PA hook callback
    "sink_unlink_hook_cb",        # PA hook callback
    "pa_source_is_droid_source",  # source->proplist
    "pa_sink_is_droid_sink",      # sink->proplist
]

# Individual statements inside functions we keep.
REPLACEMENTS = [
    (
        """    hw->sink_put_hook_slot      = pa_hook_connect(&core->hooks[PA_CORE_HOOK_SINK_PUT], PA_HOOK_EARLY-10,
                                                  sink_put_hook_cb, hw);
    hw->sink_unlink_hook_slot   = pa_hook_connect(&core->hooks[PA_CORE_HOOK_SINK_UNLINK], PA_HOOK_EARLY-10,
                                                  sink_unlink_hook_cb, hw);
""",
        """    /* SPA port: PulseAudio sink hooks are gone; in the SPA plugin the
     * device maintains the sink type itself. */
    hw->sink_put_hook_slot = NULL;
    hw->sink_unlink_hook_slot = NULL;
""",
    ),
    (
        """    if (hw->sink_put_hook_slot)
        pa_hook_slot_free(hw->sink_put_hook_slot);
    if (hw->sink_unlink_hook_slot)
        pa_hook_slot_free(hw->sink_unlink_hook_slot);
""",
        """    /* SPA port: no hook slots to release. */
""",
    ),
    (
        # In a call upstream takes the first route that has the telephony
        # receive device among its sources - and on the FLX1 the first such
        # route is the device-to-device one into "Earpiece" (Voice Call In
        # feeds the speakers too). Opening an input on an output device
        # fails ("invalid mix_port type for Earpiece"), so a voice-call
        # recording never started. Only a route into a mix port names the
        # input to open: here "voice tx".
        """        DM_LIST_FOREACH_DATA(route, stream->module->enabled_module->routes, state1) {
            DM_LIST_FOREACH_DATA(port, route->sources, state2) {
                if (port->role != DM_CONFIG_ROLE_SOURCE)
                    continue;

                if (port->type == AUDIO_DEVICE_IN_TELEPHONY_RX) {""",
        """        DM_LIST_FOREACH_DATA(route, stream->module->enabled_module->routes, state1) {
            /* SPA port: only a route into a mix port names an input. */
            if (route->sink->port_type != DM_CONFIG_TYPE_MIX_PORT)
                continue;
            DM_LIST_FOREACH_DATA(port, route->sources, state2) {
                if (port->role != DM_CONFIG_ROLE_SOURCE)
                    continue;

                if (port->type == AUDIO_DEVICE_IN_TELEPHONY_RX) {""",
    ),
    (
        # In a call upstream turns every input into AUDIO_SOURCE_VOICE_CALL.
        # An answering machine wants the caller only: its uplink is muted,
        # and on this MediaTek "voice call" came back at noise level (peak
        # 357 while the caller spoke). The HAL has a downlink-only provider
        # (AudioALSACaptureDataProviderVoiceDL) - a source asking for one
        # direction keeps it.
        """        case AUDIO_MODE_IN_CALL:
            audio_source_override = AUDIO_SOURCE_VOICE_CALL;
            break;""",
        """        case AUDIO_MODE_IN_CALL:
            /* SPA port: a tap on one direction of the call keeps it. */
            if (audio_source == AUDIO_SOURCE_VOICE_UPLINK ||
                audio_source == AUDIO_SOURCE_VOICE_DOWNLINK)
                audio_source_override = audio_source;
            else
                audio_source_override = AUDIO_SOURCE_VOICE_CALL;
            break;""",
    ),
]


def exclude_function(text, name):
    """Wraps the definition of *name* in #if 0 ... #endif."""
    # Definition line: starts in column 0, contains name( and ends with {
    pattern = re.compile(
        r"^((?:[A-Za-z_][\w \t\*]*?)\b" + re.escape(name) + r"\s*\([^;]*?\)\s*\{)$",
        re.MULTILINE,
    )
    m = pattern.search(text)
    if not m:
        return text, False
    start = m.start()
    # End of function: the next line that is exactly "}"
    end = text.index("\n}\n", m.end()) + len("\n}\n")
    body = text[start:end]
    guarded = (
        "#if 0 /* SPA-Port: dereferenziert PulseAudio-Graphobjekte */\n"
        + body
        + "#endif\n"
    )
    return text[:start] + guarded + text[end:], True


def main():
    src, dst = sys.argv[1], sys.argv[2]
    text = open(src).read()

    missing = []
    for name in EXCLUDE_FUNCS:
        text, ok = exclude_function(text, name)
        if not ok:
            missing.append(name)

    for old, new in REPLACEMENTS:
        if old not in text:
            missing.append("<statement block>")
            continue
        text = text.replace(old, new, 1)

    if missing:
        print("ERROR: not found: %s" % ", ".join(missing), file=sys.stderr)
        print("Upstream has changed - check EXCLUDE_FUNCS/REPLACEMENTS.",
              file=sys.stderr)
        return 1

    header = (
        "/* Generated by tools/port-droid-util.py from %s\n"
        " * Do NOT edit by hand. */\n" % src
    )
    open(dst, "w").write(header + text)
    print("%s -> %s (%d functions excluded)" % (src, dst, len(EXCLUDE_FUNCS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
