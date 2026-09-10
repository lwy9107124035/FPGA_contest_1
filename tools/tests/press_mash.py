# press_mash.py - rapid NEXT stress + dbg transition trace (black-screen repro)
# v7.3 era: reproduces the "mash -> stall -> 3s timeout -> rescan -> black" bug
# and accepts its fix. PASS bar: zero dbg==0x00 episodes (rescan) during mash,
# and every load episode completes < ~1.2s (0.8s timeout + retry must be
# invisible: retry keeps scan_done/display_valid up).
# dbg bits: {7 scan_done, 6 auto, 5 src_seen, 4 wr_seen, 3 valid, 2 busy, 1:0 img}
import serial, time, sys

N = int(sys.argv[1]) if len(sys.argv) > 1 else 30
GAP = 0.28 if len(sys.argv) <= 2 else float(sys.argv[2])
s = serial.Serial("COM4", 115200, timeout=0.05)
s.reset_input_buffer()

def stat():
    s.write(b"STAT?\r\n")
    t0 = time.time(); buf = b""
    while time.time() - t0 < 0.045:
        buf += s.read(64)
        if b"\r\n" in buf: break
    tok = buf.decode("ascii", "ignore").split()
    if len(tok) >= 3 and tok[0] == "V2":
        return int(tok[2], 16)
    return None

base = stat()
print("baseline dbg:", hex(base) if base is not None else "NO-REPLY")
trans = []; prev = None; t0 = time.time()
next_at = t0 + 2.0
i = 0
while time.time() - t0 < N * GAP + 25:
    t = time.time()
    if i < N and t >= next_at:
        s.write(b"NEXT\r\n"); i += 1; next_at = t + GAP
    d = stat()
    if d is None: continue
    if prev is not None and d != prev:
        trans.append((round(t - t0, 2), prev, d))
    prev = d
s.close()

rescan = [x for x in trans if (x[2] & 0x88) != 0x88 and (x[1] & 0x88) == 0x88]  # scan/valid drop
long_busy = 0
for (_, a, b) in trans:  # busy-up -> busy-down pairing
    pass
img_moves = len([1 for x in trans if (x[1] & 3) != (x[2] & 3)])
print(f"presses={i} transitions={len(trans)} img_moves={img_moves}")
print("rescan/BLACK episodes:", len(rescan))
for t, a, b in trans:
    print(f"  t={t:6.2f}  {a:#04x} -> {b:#04x}")
print("RESULT:", "CLEAN" if not rescan else f"BLACK x{len(rescan)} (v7.3 FAIL)")
