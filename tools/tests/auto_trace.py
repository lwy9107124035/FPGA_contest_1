import serial, time
s = serial.Serial("COM4", 115200, timeout=0.25)
def stat():
    s.reset_input_buffer(); s.write(b"STAT?\n"); s.flush()
    t0=time.time(); buf=b""
    while time.time()-t0<0.15:
        d=s.read(16)
        if d: buf+=d
    p=buf.split()
    return int(p[2],16) if len(p)>=3 else 0
def send(c):
    s.reset_input_buffer(); s.write((c+"\n").encode()); s.flush(); time.sleep(0.2); s.read(16)
print("=== AUTO on, watch img auto-advance ===")
send("AUTO")
for k in range(10):
    dd=stat(); print("t+%-3d %02X scan=%d auto=%d img=%d" % (k, dd,(dd>>7)&1,(dd>>6)&1,dd&3))
    time.sleep(1.0)
send("AUTO")
print("=== AUTO off, img should hold ===")
a=stat(); time.sleep(3); b=stat()
print("auto=%d img %d -> %d (should be equal, auto off)" % ((b>>6)&1, a&3, b&3))
s.close()
print("done")
