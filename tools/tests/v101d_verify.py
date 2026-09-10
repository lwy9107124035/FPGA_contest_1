# v101d_verify.py — 自愈软复位终验（板上）
# 目标：用极限施压逼出 SD 栈卡死（v10.1c 会永久冻结），验证 v10.1d 在 ~4-5s 内自动恢复，
#       随后完整回归 + 连按拷机。判据：卡死后无人工 SCAN 急救，dbg 的 scan_done(位7) 自行回 1。
import serial, time, sys
s = serial.Serial("COM4", 115200, timeout=0.05)
def cmd(c, w=0.3):
    s.reset_input_buffer(); s.write((c + "\r\n").encode()); time.sleep(w)
    return s.read(60).decode("ascii", "ignore").strip()
def dbg():
    s.reset_input_buffer(); s.write(b"STAT?\r\n"); time.sleep(0.014)
    r = s.read(40).decode("ascii", "ignore").split()
    return int(r[2], 16) if len(r) >= 3 and r[0] == "V2" else None
SD = lambda d: (d >> 7) & 1
VALID = lambda d: (d >> 3) & 1
BUSY = lambda d: (d >> 2) & 1

print("boot 13s"); time.sleep(13)
d = dbg(); print("boot:", hex(d), "SD=%d VALID=%d" % (SD(d), VALID(d)))

# --- 压力：多轮 SCAN32 -> VID -> 连打 NEXT，制造底层丢应答窗口 ---
recovers = 0; attempts = 0
for rnd in range(4):
    cmd("SCAN32"); t0 = time.time()
    while time.time() - t0 < 15:
        d = dbg()
        if d and SD(d): break
        time.sleep(0.03)
    cmd("VID 8"); time.sleep(3); cmd("VID 0")
    for i in range(16): cmd("NEXT", 0.20)
    # 此刻 v10.1c 若卡死则 scan_done 恒 0；观察 12s 内是否自愈
    attempts += 1
    stuck_seen = (SD(dbg() or 0) == 0)
    t0 = time.time(); selfheal = False
    while time.time() - t0 < 12:
        d = dbg()
        if d and SD(d): selfheal = True; break
        time.sleep(0.05)
    if stuck_seen and selfheal: recovers += 1
    print("round %d: stuck_after_mash=%s self_healed=%s (in %.1fs) dbg=%02X" %
          (rnd + 1, stuck_seen, selfheal, time.time() - t0, dbg() or 0))

d = dbg(); print("final:", hex(d or 0), "SD=%d VALID=%d" % (SD(d or 0), VALID(d or 0)))
print("WHY? ->", cmd("WHY?"))
print("INFO? ->", cmd("INFO?"))
print("VERDICT:", "SELFHEAL OK" if d and SD(d) else "STILL STUCK (FAIL)")
s.close()
