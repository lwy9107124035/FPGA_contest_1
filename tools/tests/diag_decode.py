import serial, time
s = serial.Serial("COM4", 115200, timeout=0.5)
def cmd(c, w=1.2):
    s.reset_input_buffer(); s.write((c+"\n").encode()); s.flush()
    t0=time.time(); buf=b""
    while time.time()-t0 < w:
        d=s.read(32)
        if d: buf+=d
        elif buf: break
    return buf
def diag(tag):
    r = cmd("STAT?")
    try:
        dd = int(r.split()[2],16)
    except:
        print("%-22s RAW %s" % (tag, repr(r))); return None
    scan=(dd>>7)&1; busy=(dd>>6)&1; auto=(dd>>5)&1; disp=(dd>>4)&1
    img=(dd>>2)&3; ld=dd&3
    print("%-22s V2=%s scan=%d busy=%d auto=%d disp=%d img=%d load=%d" % (tag, r.split()[1].decode(), scan,busy,auto,disp,img,ld))
    return dd
print("=== baseline ===")
cmd("CLR"); time.sleep(1)
diag("idle")
print("=== manual NEXT x3 ===")
for k in range(3):
    cmd("NEXT"); time.sleep(0.6); diag("after NEXT %d (busy?)"%(k+1)); time.sleep(1.6); diag("  NEXT %d settled"%k)
print("=== AUTO on ===")
cmd("AUTO"); diag("just after AUTO")
for k in range(8):
    time.sleep(1.0); diag("auto t+%ds"%(k+1))
cmd("AUTO")
s.close()
print("done")
