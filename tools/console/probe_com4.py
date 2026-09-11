# -*- coding: utf-8 -*-
"""probe_com4.py -- 直接开 COM4 读板卡。只读(WHY?/LIST?), 不发任何改变板子的命令。"""
import sys
import time

try:
    import serial
except Exception as e:
    print("no pyserial:", e)
    sys.exit(2)

PORT = "COM4"


def main():
    try:
        ser = serial.Serial(PORT, 115200, timeout=0.3)
    except Exception as e:
        print("OPEN_FAIL %s: %s" % (PORT, e))
        return 1
    print("OPEN_OK", PORT)
    time.sleep(0.3)
    for c in ("WHY?", "LIST?"):
        ser.reset_input_buffer()
        ser.write((c + "\r\n").encode())
        ser.flush()
        time.sleep(1.2)
        buf = ser.read(512)
        print("%s -> %r" % (c, buf))
    ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
