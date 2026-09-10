import serial, time
s = serial.Serial("COM4", 115200, timeout=0.25)
def stat():
    s.reset_input_buffer(); s.write(b"STAT?\n"); s.flush()
    t0=time.time(); buf=b""
    while time.time()-t0<0.15:
        d=s.read(16)
        if d: buf+=d
    p=buf.split()
    return int(p[2],16) if len(p)>=3 else 0x88
def send(c):
    s.reset_input_buffer(); s.write((c+"\n").encode()); s.flush(); time.sleep(0.2); s.read(16)
send("AUTO")           # ON
prev_scan=1; rescan=0; offc=0; seq=[]
t0=time.time()
while time.time()-t0 < 60:
    dd=stat()
    scan=(dd>>7)&1; auto=(dd>>6)&1; img=dd&3
    if scan==0: offc+=1
    if prev_scan==1 and scan==0: rescan+=1
    prev_scan=scan
    seq.append("%d%d%d"%(scan,auto,img))
    time.sleep(0.4)
send("AUTO")           # OFF
s.close()
print("60s soak: rescan_events=%d  scan_low_samples=%d" % (rescan, offc))
print("timeline (scan,auto,img) every 0.4s:")
print(" ".join(seq))
