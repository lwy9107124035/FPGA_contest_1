# -*- coding: utf-8 -*-
"""xray5_trace.py — XRAY5 固件: dbg = {bmp_st[2:0], done, cont, kick, stick, ready}
   bmp_st: 0=rst 1=IDLE 2=SCAN或LOAD_HDR 3=LOAD_WAIT 4=LOAD_DATA
   40Hz 采样，打印一切变化沿。"""
import serial, time
s = serial.Serial("COM4", 115200, timeout=0.05)
def cmd(c, w=0.3):
    s.reset_input_buffer(); s.write((c + "\r\n").encode()); time.sleep(w)
    return s.read(80).decode("ascii", "ignore").strip()
def dbg():
    s.reset_input_buffer(); s.write(b"STAT?\r\n"); time.sleep(0.014)
    r = s.read(40).decode("ascii", "ignore").split()
    return int(r[2], 16) if len(r) >= 3 and r[0] == "V2" else None
NAMES = {0: "RST ", 1: "IDLE", 2: "SCAN", 3: "WAIT", 4: "DATA"}
def fmt(d):
    st = (d >> 5) & 7
    return ("st=%s(%d) done=%d CONT=%d kick=%d stick=%d ready=%d" %
            (NAMES.get(st, "?%d" % st), st, (d >> 4) & 1, (d >> 3) & 1, (d >> 2) & 1, (d >> 1) & 1, d & 1))
print("boot wait 14s"); time.sleep(14)
prev = dbg(); print("t= 0.0 %02X %s" % (prev, fmt(prev)))
cmd("SCAN32"); t0 = time.time()
last = prev
while time.time() - t0 < 12:
    d = dbg()
    if d is not None and d != last:
        print("t=%4.2f %02X %s" % (time.time() - t0, d, fmt(d)))
        last = d
    time.sleep(0.018)
print("frozen snapshot x3:")
for _ in range(3):
    d = dbg(); print("    %02X %s" % (d, fmt(d))); time.sleep(0.8)
s.close()
