"""
cjk_gen.py — 应急字库生成器 (宋体 16x16 -> Verilog case ROM + 预览)
输出:
  cjk_font16.vh   : function [15:0] cjk16(input [4:0] gid, input [3:0] row)
  终端预览         : 把默认应急词按 16x16 拼出来肉眼校验
字库内容 = 应急广播常用词。gid 顺序即 CHARS 顺序。
"""
from PIL import Image, ImageDraw, ImageFont

FONT = ImageFont.truetype(r"C:\Windows\Fonts\simsun.ttc", 16)
OUT = r"C:\td_batch\lab_pro\user_source\hdl_source\cjk_font16.vh"

# gid 顺序（0 保留为空格）
CHARS = " 台风预警立即撤离紧急疏散危险区域集合点保持冷静禁止通行"

def render(ch):
    img = Image.new("L", (16, 16), 0)
    d = ImageDraw.Draw(img)
    d.text((0, 0), ch, fill=255, font=FONT)
    rows = []
    for y in range(16):
        v = 0
        for x in range(16):
            if img.getpixel((x, y)) >= 128:
                v |= (1 << (15 - x))   # bit15 = 最左像素
        rows.append(v)
    return rows

# 生成 gid -> rows
table = {}
for gid, ch in enumerate(CHARS):
    table[gid] = render(ch)

# ---- 预览拼词: "台风预警 立即撤离" ----
phrase = "台风预警 立即撤离"
gid_of = {c: i for i, c in enumerate(CHARS)}
print("== 预览 %s ==" % phrase)
for band in range(16):
    line = []
    for ch in phrase:
        rows = table[gid_of.get(ch, 0)]
        bits = rows[band]
        line.append("".join("#" if bits & (1 << (15 - x)) else "." for x in range(16)))
    print("|" + "|".join(line) + "|")

# ---- 输出 Verilog function: case({gid,row}) 16位 ----
with open(OUT, "w", encoding="utf-8") as f:
    f.write("// 自动生成，勿手改 — 由 tools/cjk_gen.py 产出 (宋体16x16点阵)\n")
    f.write("// gid 表: \"%s\"  (gid0=空格)\n" % CHARS)
    f.write("function [15:0] cjk16;\n")
    f.write("    input [4:0] gid;\n")
    f.write("    input [3:0] rw;\n")
    f.write("    case ({gid, rw})\n")
    for gid, ch in enumerate(CHARS):
        for band in range(16):
            f.write("        9'd%d: cjk16 = 16'h%04X; // \\\"%s\\\" row %d\n"
                    % (gid * 16 + band, table[gid][band], ch, band))
    f.write("        default: cjk16 = 16'h0000;\n")
    f.write("    endcase\n")
    f.write("endfunction\n")

print("\n[OK] 写出 %s  (字数=%d, gid位宽=%d)" % (OUT, len(CHARS), (len(CHARS)-1).bit_length()))
print("gid 映射:", {c: i for i, c in enumerate(CHARS)})
