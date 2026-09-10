import serial, time
s = serial.Serial("COM4", 115200, timeout=0.25)
def stat():
    s.reset_input_buffer(); s.write(b"STAT?\n"); s.flush()
    t0=time.time(); buf=b""
    while time.time()-t0 < 0.15:
        d=s.read(16)
        if d: buf+=d
    p=buf.split()
    return int(p[2],16) if len(p)>=3 else None
def dec(dd):
    return "scan=%d auto=%d k1=%d k2=%d disp=%d busy=%d img=%d" % ((dd>>7)&1,(dd>>6)&1,(dd>>5)&1,(dd>>4)&1,(dd>>3)&1,(dd>>2)&1,dd&3)
def send(c):
    s.reset_input_buffer(); s.write((c+"\n").encode()); s.flush(); time.sleep(0.2); s.read(16)
print("=== boot stable check ===")
time.sleep(2); print("boot   %02X %s" % (stat(), dec(stat())))
print("=== NEXT: sample busy+img every 0.3s for 4s (does img change?) ===")
send("NEXT")
for k in range(13):
    dd=stat()
    if dd is not None: print("t+%-4d %02X %s" % (round(k*0.3,1), dd, dec(dd)))
    time.sleep(0.25)
print("=== NEXT again, expect img to keep cycling 0..3 ===")
for r in range(4):
    send("NEXT"); time.sleep(2.2)
    dd=stat(); print("after next#%d %02X %s" % (r+2, dd, dec(dd)))
s.close()
