# -*- coding: utf-8 -*-
"""probe_com6.py -- 直读板卡串口(自动探测 CH340 所在 COM 口)，发只读命令 WHY?/LIST?/INFO。"""
import sys
import time

try:
    import serial
    from serial.tools import list_ports
except Exception as e:
    print("no pyserial:", e)
    sys.exit(2)

READONLY_CMDS = ("LIST?", "WHY?")


def pick_port():
    # 注意: pyserial 的 comports() 会把「残留的 COM4」也列出来且描述同为 CH340，
    # 但只有真正在位的那一个能打开。故这里逐个尝试，取第一个打得开的。
    cands = []
    for p in list_ports.comports():
        desc = (p.description or "") + " " + (p.hwid or "")
        cands.append((p.device, p.description or "", "CH340" in desc.upper()))
    cands.sort(key=lambda t: (not t[2], t[0]))        # CH340 优先
    for dev, desc, _ in cands:
        try:
            s = serial.Serial(dev, 115200, timeout=0.3)
            s.close()
            return dev, desc
        except Exception:
            continue
    return (cands[0][0] if cands else None), (cands[0][1] if cands else "")


def main():
    port, desc = pick_port()
    print("port=%s desc=%s" % (port, desc))
    if not port:
        return 1
    try:
        ser = serial.Serial(port, 115200, timeout=0.3)
    except Exception as e:
        print("OPEN_FAIL %s: %s" % (port, e))
        return 1
    print("OPEN_OK", port)
    time.sleep(0.4)
    for c in READONLY_CMDS:
        for attempt in range(3):
            ser.reset_input_buffer()
            # 板子固件按 '\n' 分行（见 fpga_link.py L84: cmd + b"\n"），不是 \r\n
            ser.write((c + "\n").encode("gb2312", "replace"))
            ser.flush()
            time.sleep(1.5)
            buf = ser.read(1024)
            if buf:
                print("%s -> %r" % (c, buf))
                break
            print("%s -> (no response, attempt %d)" % (c, attempt + 1))
    ser.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
