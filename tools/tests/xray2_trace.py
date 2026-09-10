# -*- coding: utf-8 -*-
"""xray2_trace.py — XRAY2 固件: dbg = {done, cont, first_committed, two_or_more, ready, busy, abort, retry}"""
import serial, time, sys
s = serial.Serial("COM4", 115200, timeout=0.05)
def cmd(c, w=0.3):
    s.reset_input_buffer(); s.write((c + "\r\n").encode()); time.sleep(w)
    return s.read(80).decode("ascii", "ignore").strip()
def dbg():
    s.reset_input_buffer(); s.write(b"STAT?\r\n"); time.sleep(0.014)
    r = s.read(40).decode("ascii", "ignore").split()
    return int(r[2], 16) if len(r) >= 3 and r[0] == "V2" else None
N = lambda x, b: (x >> b) & 1
def show(tag):
    d = dbg() or 0
    print("%-22s %02X  done=%d CONT=%d first=%d 2more=%d ready=%d busy=%d abort=%d retry=%d" % (
        tag, d, N(d,7), N(d,6), N(d,5), N(d,4), N(d,3), N(d,2), N(d,1), N(d,0)))
print("boot wait 14s"); time.sleep(14)
show("boot settled")
cmd("SCAN32")
for t in range(0, 24):
    time.sleep(0.5); show("SCAN32 t=%.1fs" % (t * 0.5 + 0.5))
    d = dbg() or 0
    if N(d, 7) and not N(d, 6): break
cmd("VID 4")
time.sleep(1.5); show("after VID4 +1.5s")
time.sleep(1.5); show("after VID4 +3.0s")
time.sleep(2.0); show("after VID4 +5.0s")
s.close()
