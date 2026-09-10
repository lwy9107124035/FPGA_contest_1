# -*- coding: ascii -*-
# 10-cycle AUTO on/off probe: detect eaten toggles (auto-bit phase drift).
import serial, time, sys

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM4"

def decode(dbg):
    return dict(scan=(dbg >> 7) & 1, auto=(dbg >> 6) & 1, src=(dbg >> 5) & 1,
                wr=(dbg >> 4) & 1, valid=(dbg >> 3) & 1, busy=(dbg >> 2) & 1, img=dbg & 3)

sp = serial.Serial(PORT, 115200, timeout=0.5)

def stat():
    for _ in range(6):
        sp.reset_input_buffer()
        sp.write(b"STAT?\r\n")
        t0 = time.time()
        buf = b""
        while time.time() - t0 < 0.5:
            buf += sp.read(64)
        s = buf.decode("ascii", "ignore")
        if s.startswith("V2"):
            try:
                return int(s.split()[1], 16), int(s.split()[2], 16)
            except Exception:
                pass
    return None, None

bad = 0
for k in range(10):
    sp.reset_input_buffer(); sp.write(b"AUTO\r\n"); time.sleep(0.8)
    cnt, dbg = stat()
    d = decode(dbg) if dbg is not None else {}
    on_ok = (dbg is not None) and d.get("auto") == 1
    # let it advance at least once (1s cadence)
    img0 = d.get("img")
    moved = False
    t0 = time.time()
    while time.time() - t0 < 6:
        time.sleep(0.5)
        cnt, dbg = stat()
        if dbg is not None and decode(dbg)["img"] != img0:
            moved = True
            break
    sp.reset_input_buffer(); sp.write(b"AUTO\r\n"); time.sleep(0.8)
    cnt, dbg = stat()
    d2 = decode(dbg) if dbg is not None else {}
    off_ok = (dbg is not None) and d2.get("auto") == 0
    ok = on_ok and moved and off_ok
    if not ok:
        bad += 1
    print("cycle %2d: on=%s moved=%s off=%s dbg=%02x->%02x %s" % (
        k, on_ok, moved, off_ok, dbg, d2.get("img", -1), "" if ok else "  <== EATEN/FAIL"))
    # settle: ensure img stays put 2s after off
    imgA = d2.get("img")
    time.sleep(2.2)
    cnt, dbg = stat()
    if dbg is not None and decode(dbg)["img"] != imgA:
        bad += 1
        print("   ghost advance after off! ->", decode(dbg)["img"])
print("RESULT: bad=%d / 10 cycles" % bad)
sp.close()
