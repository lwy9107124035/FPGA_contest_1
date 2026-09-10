# -*- coding: utf-8 -*-
# ROM glyph census: which ASCII codes carry real dot-matrix in ascii_rom?
import re, io, sys, json

ROM = r"C:\td_batch\lab_pro\user_source\hdl_source\osd_banner.v"
t = io.open(ROM, encoding="utf-8").read()
m = re.findall(r"ascii_rom\[12'h([0-9A-Fa-f]{3})\]\s*=\s*8'h([0-9A-Fa-f]{2})", t)
rom = {int(a, 16): int(v, 16) for a, v in m}
print("parsed entries:", len(rom))

# WP-G said addr = {ch[7:0], row[3:0]} i.e. ch*16 + row
def addr(ch, r):
    return ch * 16 + r

def has_glyph(ch):
    return any(rom.get(addr(ch, r), 0) for r in range(16))

groups = {
    "UPPER A-Z": [chr(c) for c in range(0x41, 0x5B)],
    "digit 0-9": [chr(c) for c in range(0x30, 0x3A)],
    "lower a-z": [chr(c) for c in range(0x61, 0x7B)],
    "punct !-/( ,-/, :-/?  etc": ["!",'"',"#","$","%","&","'","(",")","*","+",
                                  ",","-",".","/",";",":","<",">","?","@",
                                  "[","\\","]","^","_","`","{","|","}","~"],
}
for label, chars in groups.items():
    have = [c for c in chars if has_glyph(ord(c))]
    miss = [c for c in chars if not has_glyph(ord(c))]
    print(f"{label:26s} present {len(have):3d}/{len(chars):3d}  "
          f"missing: {''.join(miss) if miss else '(none)'}")

# sample render 'a' and ',' to eyeball
for ch in (0x61, 0x2C):
    print(chr(ch), "glyph:")
    for r in range(16):
        v = rom.get(addr(ch, r), 0)
        print("   " + "".join("#" if v & (1 << (7 - b)) else "." for b in range(8)))
