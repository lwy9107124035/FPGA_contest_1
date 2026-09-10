# -*- coding: utf-8 -*-
import io
P = r"C:\td_batch\lab_pro\tools\console\card_reformat.ps1"
raw = io.open(P, "rb").read()
if raw.startswith(b"\xef\xbb\xbf"):
    print("BOM already present")
else:
    io.open(P, "wb").write(b"\xef\xbb\xbf" + raw)
    print("UTF-8 BOM added (%d bytes)" % len(raw))
