import serial, time
s = serial.Serial("COM4", 115200, timeout=0.25)
def send(c_bytes):
    s.reset_input_buffer(); s.write(c_bytes); s.flush(); time.sleep(0.25)
    ack=b""; t0=time.time()
    while time.time()-t0<0.5:
        d=s.read(16)
        if d: ack+=d
    return ack
# boot line
print("boot STAT:", send(b"STAT?\n").strip())
# 1) pure Chinese: ?????? (GB2312)
msg = "MSG " + "??????"
print("send CN  ->", send(msg.encode("gb2312")+b"\n").strip())
time.sleep(1.5)   # let refresh FSM fetch 6 glyphs
print("after CN ->", send(b"STAT?\n").strip())
# 2) mixed ASCII+Chinese
msg2 = "MSG ABC??123"
print("send MIX ->", send(msg2.encode("gb2312")+b"\n").strip())
time.sleep(1.5)
# 3) full line of 13 chars
msg3 = "MSG ????????????"
print("send FULL->", send(msg3.encode("gb2312")+b"\n").strip())
time.sleep(2)
print("final    ->", send(b"STAT?\n").strip())
s.close()
