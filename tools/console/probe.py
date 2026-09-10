# -*- coding: utf-8 -*-
"""一次性串口小助手：发一串命令，逐条打印板子回应。用于板测/诊断。
用法: python probe.py "STAT?" "WHY?" "SCAN32" "LIST?"
不指定则跑默认诊断序列。持有 COM 独占，跑完即释放。"""
import sys, time
import serial

PORT, BAUD = "COM4", 115200
cmds = sys.argv[1:] or ["*?", "STAT?", "WHY?", "LIST?"]

try:
    s = serial.Serial(PORT, BAUD, timeout=1.0)
except Exception as e:
    print("OPEN FAIL:", type(e).__name__, e)
    sys.exit(2)

def send(cmd, wait=0.6, extra=0.0):
    s.reset_input_buffer()
    s.write((cmd + "\r\n").encode("ascii"))
    time.sleep(wait + extra)
    buf = b""
    while True:
        chunk = s.read(256)
        if not chunk:
            break
        buf += chunk
    reply = buf.decode("ascii", "replace").replace("\r\n", " | ").strip()
    print("%-10s -> %s" % (cmd, reply if reply else "(no reply)"))
    return reply

for c in cmds:
    # 扫描/导入类命令耗时长，多给时间
    send(c, wait=0.6 if not any(k in c for k in ("SCAN", "VID")) else 6.0)
    time.sleep(0.1)

s.close()
