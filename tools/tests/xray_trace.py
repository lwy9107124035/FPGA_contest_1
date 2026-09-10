# -*- coding: utf-8 -*-
"""xray_trace.py — 临时 X-RAY 固件专用读片器。
dbg = {scan_done, scan_kicked, bmp_ready, scan_cont_active, valid, busy, found[1:0]}
用法: python xray_trace.py [SCAN7|SCAN4|IDLE] [秒=25]
"""
import serial, time, sys
SEQ = (sys.argv[1] if len(sys.argv) > 1 else "SCAN7").upper()
DUR = float(sys.argv[2]) if len(sys.argv) > 2 else 25.0

s = serial.Serial("COM4", 115200, timeout=0.03)
def cmd(c):
    s.reset_input_buffer(); s.write((c + "\r\n").encode()); time.sleep(0.25)
    return s.read(60).decode("ascii", "ignore").strip()
def dbg():
    s.reset_input_buffer(); s.write(b"STAT?\r\n"); time.sleep(0.014)
    r = s.read(40).decode("ascii", "ignore").split()
    return int(r[2], 16) if len(r) >= 3 and r[0] == "V2" else None

print("pre:", cmd("WHY?"))
if SEQ != "IDLE":
    print("send", SEQ, ":", cmd(SEQ))
t0 = time.time(); prev = None; hist = []
while time.time() - t0 < DUR:
    d = dbg()
    if d is not None:
        if d != prev:
            hist.append((time.time() - t0, prev, d)); prev = d
    time.sleep(0.024)
N = lambda x, b: (x >> b) & 1
print("== timeline (changes only) ==")
for t, a, b in hist:
    print("t=%5.2f  %s -> %02X   done=%d kick=%d ready=%d cont=%d valid=%d busy=%d f=%d%d" % (
        t, "  --" if a is None else "%02X" % a, b,
        N(b, 7), N(b, 6), N(b, 5), N(b, 4), N(b, 3), N(b, 2), N(b, 1), N(b, 0)))
print("post:", cmd("WHY?"))
s.close()
