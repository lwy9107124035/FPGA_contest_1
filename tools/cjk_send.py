import serial, time
# payload ? hex ???????? ASCII ?? ?? ???????
# ??: "Hello, ???v9 ???"  (GB2312: C4E3 BAC3 A3AC | C8AB C2CC A1A3)
body = bytes.fromhex("48656C6C6F2C20" "C4E3 BAC3 A3AC".replace(" ","") + "7639 20".replace(" ","") + "C8AB C2CC A1A3".replace(" ",""))
s=serial.Serial("COM4",115200,timeout=1)
s.reset_input_buffer(); s.write(b"COL 3\r\n"); time.sleep(0.4)
print("col ack:", s.read(40).decode("ascii","ignore").strip())
s.reset_input_buffer(); s.write(b"msg "+body+b"\r\n"); time.sleep(0.8)
print("msg ack:", s.read(40).decode("ascii","ignore").strip(), "| sent", len(body), "bytes")
s.close()
