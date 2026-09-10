# soak_run.py — 可配置时长 AUTO 轮播拷机（1h 稳定性验收）
# 每 ~1.5s 一次 AUTO 开关切换（制造扫描/加载/链锁边界），全程监测：
#   scan_done 掉 0 且持续不回的"真冻结"、stall 黑匣子计数增长、自愈触发（stall_cnt 跳变）。
# PASS 判据：全程无永久冻结（每次都能回到 scan_done=1），最终状态健康。
import serial, time, sys
DUR = int(sys.argv[1]) if len(sys.argv) > 1 else 3600
s = serial.Serial("COM4", 115200, timeout=0.15)
def cmd(c, w=0.25):
    s.reset_input_buffer(); s.write((c + "\r\n").encode()); time.sleep(w)
    return s.read(60).decode("ascii", "ignore").strip()
def dbg():
    s.reset_input_buffer(); s.write(b"STAT?\r\n"); time.sleep(0.02)
    r = s.read(40).decode("ascii", "ignore").split()
    return int(r[2], 16) if len(r) >= 3 and r[0] == "V2" else None
def stallcnt():
    s.reset_input_buffer(); s.write(b"WHY?\r\n"); time.sleep(0.02)
    r = s.read(40).decode("ascii", "ignore").split()
    return int(r[4]) if len(r) >= 5 and r[0] == "W" else -1
SD = lambda d: (d >> 7) & 1
VAL = lambda d: (d >> 3) & 1
print("soak start dur=%ds" % DUR)
s.write(b"AUTO\r\n"); time.sleep(0.3); s.read(16)   # 开自动
frozen_events = 0; black_events = 0; max_scanlow_ms = 0; samples = 0
t_end = time.time() + DUR
last_cmd = time.time()
cmd_idx = 0
cmds = ["VID 4", "VID 0", "SCAN7", "SCAN4", "NEXT", "PLYALL", "SPD 2", "COL 3", "COL 0"]
cur_low_since = None
while time.time() < t_end:
    d = dbg()
    if d is None:
        continue
    samples += 1
    if SD(d) == 0:
        if cur_low_since is None: cur_low_since = time.time()
        else:
            held = (time.time() - cur_low_since) * 1000
            if held > max_scanlow_ms: max_scanlow_ms = held
            if held > 8000:            # >8s scan_done=0 = 真冻结（自愈应在 ~6s 内救回）
                frozen_events += 1; cur_low_since = None
                print("  [t=%4ds] FROZEN detected, waiting for self-heal... dbg=%02X" % (int(time.time()-(t_end-DUR)), d))
    else:
        cur_low_since = None
    if VAL(d) == 0:
        black_events += 1
    if time.time() - last_cmd > 4.0:
        cmd(cmds[cmd_idx % len(cmds)]); cmd_idx += 1; last_cmd = time.time()
    time.sleep(0.05)
s.write(b"AUTO\r\n"); time.sleep(0.3); s.read(16)   # 关自动
d = dbg(); sc = stallcnt()
print("soak done: samples=%d frozen_events=%d black_samples=%d max_scanlow_ms=%.0f final=%02X stall_cnt=%d"
      % (samples, frozen_events, black_events, max_scanlow_ms, d or 0, sc))
print("VERDICT:", "SOAK CLEAN" if (frozen_events == 0 and d and SD(d)) else "SOAK FAIL")
s.close()
