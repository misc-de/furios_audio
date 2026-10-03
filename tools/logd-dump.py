#!/usr/bin/env python3
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
"""Dump the Android log (HAL messages included) without logcat, which does
not link on the host. Usage: logd-dump.py [tail-lines]"""
# Read Android logd without logcat: logdr speaks a tiny text protocol.
import socket, struct, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
s.connect("/dev/socket/logdr")
s.send(b"dumpAndClose lids=0,1,2,3,4 tail=%d" % (int(sys.argv[1]) if len(sys.argv) > 1 else 5000))
while True:
    d = s.recv(5 * 1024 + 64)
    if not d: break
    ln, hs, pid, tid, sec, nsec = struct.unpack("<HHiIII", d[:20])
    p = d[hs:hs+ln]
    if len(p) < 2: continue
    pri = p[0]; rest = p[1:]
    tag, _, msg = rest.partition(b"\0")
    print("%s %5d %s: %s" % (time.strftime("%H:%M:%S", time.localtime(sec)), pid,
          tag.decode(errors="replace"), msg.rstrip(b"\0\n").decode(errors="replace")))
