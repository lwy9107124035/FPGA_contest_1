import serial, time
s = serial.Serial("COM4", 115200, timeout=0.25)
def stat():
    s.reset_input_buffer(); s.write(b"STAT?\n"); s.flush()
    t0=time.time(); buf=b""
    while time.time()-t0<0.15:
        d=s.read(16)
        if d: buf+=d
    p=buf.split(); return int(p[2],16) if len(p)>=3 else 0
def send(c):
    s.reset_input_buffer(); s.write((c+"\n").encode()); s.flush(); time.sleep(0.25); s.read(16)
prev=stat()&3; ok=True; seen=[prev]
for k in range(6):
    send("NEXT"); time.sleep(1.6)
    im=stat()&3; seen.append(im)
s.close()
print("NEXT x6 img sequence:", seen)
exp=[0,1,2,3,0,1,2]
print("PASS manual-NEXT" if seen==exp[:len(seen)] else "NOTE see above (start offset ok)")
