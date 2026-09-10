# v102_verify.py — v10.2 四新命令板上实测
# 判据全部走 LIST? 回读（黑盒可观测），不依赖肉眼：
#   LIST? -> "L <found> <cur> <depth>"，cur 随 PREV/NEXT 变，depth 随 SCAN n 变。
import serial, time
s = serial.Serial("COM4", 115200, timeout=0.05)
def cmd(c, w=0.35):
    s.reset_input_buffer(); s.write((c + "\r\n").encode()); time.sleep(w)
    return s.read(60).decode("ascii", "ignore").strip()
def lst():
    r = cmd("LIST?")
    p = r.split()
    if len(p) == 4 and p[0] == "L":
        return int(p[1], 16), int(p[2], 16), int(p[3], 16)   # found, cur, depth
    return None
ok = 0; fail = 0
def ck(name, cond, extra=""):
    global ok, fail
    if cond: ok += 1; print("PASS", name, extra)
    else: fail += 1; print("FAIL", name, extra)

print("boot 13s ..."); time.sleep(13)
cmd("PLYALL")                       # 让全部卡内图进轮播，found 才等于实际张数
time.sleep(0.5)
base = lst()
print("baseline LIST? ->", base, "(found, cur, depth)")
ck("LIST? 可回读", base is not None)
found, cur, depth = base

# --- 轮询等图号变化的通用器（SD 换图要 ~0.8-1.5s，定长等待不可靠） ---
def wait_cur_change(tmo=4.0):
    start = lst()[1]
    t0 = time.time()
    while time.time() - t0 < tmo:
        r = lst()
        if r and r[1] != start:
            return start, r[1]
        time.sleep(0.15)
    return start, None

# --- PREV 真的退一张（方向判定：4 张卡上 0 的上一张必须是 3）---
start = lst()
before = start[1]
ack = cmd("PREV")
print("PREV ack:", repr(ack), " start state:", start)
moved = None
t0 = time.time()
while time.time() - t0 < 4.0:
    r = lst()
    if r and r[1] != before:
        moved = r[1]; break
    time.sleep(0.15)
print("PREV: cur %s -> %s" % (before, moved))
exp = (start[0] - 1) if before == 0 else (before - 1)   # 0 的上一张 = 最后一张(found-1)
ck("PREV 方向正确（环上前驱）", moved == exp, "before=%s expect=%s got=%s" % (before, exp, moved))

# --- PREV->NEXT 往返：应回到同一号 ---
p1 = lst()[1]; cmd("PREV"); time.sleep(2.0); p2 = lst()[1]; cmd("NEXT"); time.sleep(2.0); p3 = lst()[1]
ck("PREV 再 NEXT 回到原图", p1 == p3 and p1 != p2, "%s->%s->%s" % (p1, p2, p3))

# --- SCAN12：深度变 0C ---
ck("SCAN12 -> OK", cmd("SCAN12").upper().startswith("OK"), repr(cmd("SCAN12")))
time.sleep(3.0)                      # 等扫描链跑完
d = lst()
print("after SCAN12 LIST? ->", d)
ck("SCAN12 后 depth=12", d and d[2] == 12, str(d))

# --- SCAN2：深度变 2 ---
ck("SCAN2 -> OK", cmd("SCAN2").upper().startswith("OK"))
time.sleep(2.0)
d2 = lst()
ck("SCAN2 后 depth=2", d2 and d2[2] == 2, str(d2))

# --- RNG58：区间，回 OK，不污染 depth（仍应能 LIST? 读）---
r = cmd("RNG58")
ck("RNG58 -> OK", r.upper().startswith("OK"), repr(r))
ck("RNG58 后 LIST? 仍健康", lst() is not None)

# --- 越界命令必须被板子拒（SCAN33 / RNG0A）---
ck("SCAN33 -> ERR(板子侧也拦)", cmd("SCAN33").upper().startswith("ERR"))
ck("RNG0A  -> ERR", cmd("RNG0A").upper().startswith("ERR"))

# --- 健康自检 ---
print("WHY?  ->", cmd("WHY?"))
print("INFO? ->", cmd("INFO?"))
h = lst()
ck("收尾 LIST? 健康", h is not None, str(h))

# 复位到默认 4 张，避免影响后续 regress
cmd("SCAN4")
print("=" * 40)
print("V10.2 BOARD: %d PASS, %d FAIL" % (ok, fail))
s.close()
