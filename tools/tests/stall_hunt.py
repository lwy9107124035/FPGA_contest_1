# -*- coding: utf-8 -*-
"""stall_hunt.py v2 — 40Hz STAT? 采样录像机 + 事件自动分类。
用法:  python stall_hunt.py [秒数=300] [raw文件=stall_hunt_raw.txt]
签名:
  正常加载   busy↑ ... busy↓ 且 img 与上次提交不同
  重试(v7.3) busy↓(img=X) -> ~0.8s -> busy↑ -> busy↓(img=X)  同一 img 连续两次提交
  重扫黑屏   scan(bit7) 或 valid(bit3) 掉零
"""
import serial, time, sys

DUR = float(sys.argv[1]) if len(sys.argv) > 1 else 300.0
RAW = sys.argv[2] if len(sys.argv) > 2 else r"C:\td_batch\lab_pro\tools\tests\stall_hunt_raw.txt"
s = serial.Serial("COM4", 115200, timeout=0.03)
s.reset_input_buffer()

hist = []          # (t, dbg) 仅变化沿
prev = None
t0 = time.time(); n_ok = n_bad = 0
while time.time() - t0 < DUR:
    tw = time.time() - t0
    s.reset_input_buffer(); s.write(b"STAT?\r\n"); time.sleep(0.012)
    r = s.read(40).decode("ascii", "ignore").split()
    dbg = None
    if len(r) >= 3 and r[0] == "V2":
        try: dbg = int(r[2], 16); n_ok += 1
        except ValueError: n_bad += 1
    else:
        n_bad += 1
    if dbg is not None and dbg != prev:
        hist.append((round(tw, 3), dbg)); prev = dbg
    dt = 0.025 - (time.time() - t0 - tw)
    if dt > 0: time.sleep(dt)
s.close()

# ---- 边沿重建 ----
ev = []            # (t, kind) kind: LS LE
busy = False; last = None
for t, d in hist:
    b = bool(d & 0x04)
    if b and not busy: ev.append((t, "LS", d))
    if busy and not b: ev.append((t, "LE", d))
    busy = b
ends = [(t, d & 3) for t, k, d in ev if k == "LE"]
starts = [t for t, k, d in ev if k == "LS"]

retries = 0; rescans = 0; loads = len(ends)
report = []
for k in range(1, len(ends)):
    if ends[k][1] == ends[k-1][1] and 0.05 < ends[k][0] - ends[k-1][0] < 120.0:
        retries += 1
        report.append("RETRY-SUSPECT  t=%.2fs  img=%d 提交两次 间隔 %.2fs" %
                      (ends[k][0], ends[k][1], ends[k][0] - ends[k-1][0]))
inrs = False
for t, d in hist:
    dead = not (d & 0x88 == 0x88)
    if dead and not inrs:
        rescans += 1; report.append("RESCAN/BLANK   t=%.2fs  dbg=%02X" % (t, d)); inrs = True
    elif not dead: inrs = False

head = ("stall_hunt v2  dur=%.0fs  samples ok/bad=%d/%d  loads=%d  retries=%d  rescans=%d  edges=%d"
        % (DUR, n_ok, n_bad, loads, retries, rescans, len(ev)))
open(RAW, "w", encoding="utf-8").write(
    head + "\n" + "\n".join("%s %02X" % (t, d) for t, d in hist) + "\n" + "\n".join(report) + "\n")
print(head)
for l in report[:40]: print(" ", l)
print("raw timeline ->", RAW)
