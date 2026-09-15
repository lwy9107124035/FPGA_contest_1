# -*- coding: utf-8 -*-
"""scan_ports.py -- 逐个打开所有 COM 口，发 LIST? 看哪个板子在应答。只读。"""
import sys
import time

import serial
from serial.tools import list_ports

BAUD = 115200
CMDS = ["LIST?", "WHY?"]


def try_port(dev):
    try:
        ser = serial.Serial(dev, BAUD, timeout=0.3)
    except Exception as e:
        print("  %-6s OPEN_FAIL %s" % (dev, e))
        return False
    print("  %-6s OPEN_OK" % dev)
    got = False
    try:
        time.sleep(0.4)
        for c in CMDS:
            ser.reset_input_buffer()
            ser.write((c + "\n").encode("gb2312", "replace"))
            ser.flush()
            time.sleep(1.2)
            buf = ser.read(1024)
            print("    %-6s -> %r" % (c, buf))
            if buf:
                got = True
    finally:
        ser.close()
    return got


def main():
    ports = sorted({p.device for p in list_ports.comports()})
    print("candidate ports:", ports)
    any_ok = False
    for dev in ports:
        if try_port(dev):
            any_ok = True
            print("  ^^^ %s 有应答（板子在线）" % dev)
    if not any_ok:
        print("结论: 所有串口都无应答 -> 板子未上电/未配置，或串口线/驱动问题")
    return 0


if __name__ == "__main__":
    sys.exit(main())
