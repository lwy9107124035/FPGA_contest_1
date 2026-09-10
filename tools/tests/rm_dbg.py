# -*- coding: utf-8 -*-
import io, re
P = r"C:\td_batch\lab_pro\tools\tests\tb_img_scaler.v"
s = io.open(P, encoding="utf-8").read()
m = re.search(r'\x24display\("   DBG geo[^;]*;', s)
if m:
    s = s[:m.start()] + s[m.end():]
    io.open(P, "w", encoding="utf-8", newline="\n").write(s)
    print("DBG line removed")
else:
    print("no DBG line")
