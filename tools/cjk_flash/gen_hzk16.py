# -*- coding: utf-8 -*-
"""
gen_hzk16.py — GB2312 全量 16x16 点阵字模镜像生成器（标准 HZK16 格式）

产出:
  hzk16.bin（与本脚本同目录），大小固定 282,752 字节 = 8836 槽 x 32 字节。

布局约定（与 FPGA 侧 glyph_fetch 的地址计算严格一致）:
  · 槽位数: 94 区(qu=1..94) x 94 位(wei=1..94) = 8836 槽。
    GB2312 实际只有 87 个区; qu=88..94 及 qu=10..15 等未定义位置保持全 0,
    保留完整 94x94 布局是为了让 FPGA 里 "偏移=((qu-1)*94+(wei-1))*32"
    对任意双字节码位都成立, 不需要额外限幅逻辑。
  · 每槽 32 字节 = 16 行 x 每行 2 字节; 高位字节在前。
    每行 16bit: bit15 = 最左像素, bit8 = 左半字节最左像素(bit7..0 为右 8 像素)。
  · 文件偏移 = ((qu-1)*94 + (wei-1)) * 32
  · 空位（GB2312 未定义位, 解码失败）填全 0。

字符来源: bytes([0xA0+qu, 0xA0+wei]).decode('gb2312')。
点阵来源: PIL + 宋体 simsun.ttc 16px, 灰度阈值 >=128; draw.text 偏移 (0,0)
          —— 主线会话已用同参数验证 "台风预警立即撤离" 等字 16x16 完整无裁切。

用法:
  & C:\\Users\\lwy\\miniconda3\\envs\\fpga_batch\\python.exe gen_hzk16.py

自验(运行末尾自动执行, 全部通过才打印 ALL PASS):
  a) 文件大小 == 282752
  b) 抽查 '啊' / '警' / '台' / '撤': 由 GB2312 编码反查区位 -> 算偏移 -> 回读
     32 字节打 ASCII 点阵预览（肉眼应为完整汉字, 且末两行有笔画防止裁切）
  c) GB2312 标准共 7445 个码位(682 符号 + 3755 一级字 + 3008 二级字), 因此
     判据修正为: 解码成功数 == 7445; 非全零槽位 > 7400 (全角空格等极少数
     空白字符合法全零); 且汉字区(qu>=16)不允许任何全零槽 —— 任何一个汉字
     渲染成空白都视为 FAIL。(任务书 ">8000" 的预估不成立: 8836 槽中只有
     7445 个有定义字符, 上限即 7445。)
"""

import os
import sys
from PIL import Image, ImageDraw, ImageFont

# ---------------------------------------------------------------- 参数区
HERE      = os.path.dirname(os.path.abspath(__file__))
OUT_PATH  = os.path.join(HERE, "hzk16.bin")
FONT_PATH = r"C:\Windows\Fonts\simsun.ttc"
FONT_SIZE = 16
THRESH    = 128          # 灰度阈值, 与主线已验证的 tools/cjk_gen.py 一致
OFFSET    = (0, 0)       # 渲染偏移, 主线已验证 (0,0) 点阵完整居中
QU_MAX    = 87           # GB2312 实际存在 87 个区 (1..9 符号区, 16..55 一级, 56..87 二级)
REGIONS   = 94           # 文件布局保留 94 个区 (88..94 全 0, 仅为地址公式完整性)
WEI_MAX   = 94           # 每区 94 个位
SLOT_BYTES = 32          # 每槽 32 字节 (16 行 x 2)
FILE_SIZE  = REGIONS * WEI_MAX * SLOT_BYTES   # 94*94*32 = 282,752

_font = ImageFont.truetype(FONT_PATH, FONT_SIZE)


def render_slot(ch):
    """把一个字符渲染成 HZK16 槽位的 32 字节。"""
    img = Image.new("L", (16, 16), 0)
    d = ImageDraw.Draw(img)
    d.text(OFFSET, ch, fill=255, font=_font)
    px = img.tobytes()                    # 256 字节行主序灰度图
    out = bytearray(SLOT_BYTES)
    for y in range(16):
        v = 0
        row = px[y * 16:(y + 1) * 16]
        for x in range(16):
            if row[x] >= THRESH:
                v |= 1 << (15 - x)        # bit15 = 最左像素
        out[y * 2]     = (v >> 8) & 0xFF  # 每行高字节 = 左 8 像素
        out[y * 2 + 1] = v & 0xFF         # 每行低字节 = 右 8 像素
    return out


def slot_offset(qu, wei):
    """区位码 -> 文件偏移。qu/wei 均为 1 基。"""
    return ((qu - 1) * WEI_MAX + (wei - 1)) * SLOT_BYTES


def quwei_of(ch):
    """汉字 -> (qu, wei)：GB2312 双字节编码各减 0xA0。"""
    b = ch.encode("gb2312")
    return b[0] - 0xA0, b[1] - 0xA0


def build():
    """遍历全部 94x94 槽, 填充 qu=1..87 的有效内容; 返回 (buf, 解码数, 未定义数)。
    同时记录 '解码成功但渲染全零' 的槽(仅允许出现在符号/空白类), 汉字区出现即报错。"""
    buf = bytearray(FILE_SIZE)            # 未写入处天然全 0
    n_decoded = 0
    n_undef   = 0
    blank_hanzi = []                      # 汉字区(qu>=16)渲染全零 = 异常
    for qu in range(1, QU_MAX + 1):
        for wei in range(1, WEI_MAX + 1):
            code = bytes([0xA0 + qu, 0xA0 + wei])
            try:
                ch = code.decode("gb2312")
            except UnicodeDecodeError:
                n_undef += 1              # GB2312 未定义位: 保持全 0
                continue
            n_decoded += 1
            slot = render_slot(ch)
            off = slot_offset(qu, wei)
            buf[off:off + SLOT_BYTES] = slot
            if qu >= 16 and not any(slot):
                blank_hanzi.append((qu, wei, ch))
        if qu % 10 == 0:
            print("  ... 已生成到第 %d 区 (解码成功 %d, 未定义 %d)" % (qu, n_decoded, n_undef))
    if blank_hanzi:
        print("  !! 汉字区渲染全零(不应发生): %s" % blank_hanzi)
    return buf, n_decoded, n_undef, blank_hanzi


def preview(buf, qu, wei):
    """按槽位偏移回读并打印 16x16 ASCII 点阵预览。"""
    off = slot_offset(qu, wei)
    s = buf[off:off + SLOT_BYTES]
    print("  偏移 0x%05X (%d):" % (off, off))
    for y in range(16):
        v = (s[y * 2] << 8) | s[y * 2 + 1]
        print("  |" + "".join("#" if v & (1 << (15 - x)) else "." for x in range(16)) + "|")


def self_check(path):
    """重开文件做独立回读校验（不依赖 build 的内存 buf），返回是否全部通过。"""
    ok = True
    with open(path, "rb") as f:
        buf = f.read()

    # a) 文件大小
    size = len(buf)
    print("[a] 文件大小 = %d 字节 (要求 %d) -> %s"
          % (size, FILE_SIZE, "PASS" if size == FILE_SIZE else "FAIL"))
    ok &= (size == FILE_SIZE)

    # b) 抽查: 由 GB2312 编码反查区位, 回读点阵
    #     注: '啊' 实为区 16 位 1 (区位码 1601), 偏移 45216; 任务书中
    #     "3201/偏移2914?" 是示意, 一切以编码反查的程序计算为准。
    print("[b] 抽查点阵预览:")
    for ch in ("啊", "警", "台", "撤"):
        qu, wei = quwei_of(ch)
        code = ch.encode("gb2312")
        print('  字符 "%s' % ch + '"  GB2312=0x%02X%02X  区位=%d%02d  偏移=%d'
              % (code[0], code[1], qu, wei, slot_offset(qu, wei)))
        preview(buf, qu, wei)
        off = slot_offset(qu, wei)
        nz = any(buf[off:off + SLOT_BYTES])
        # 末两行(第14/15行)应有笔画落位, 防止整体上移被裁的假阳性
        tail_nz = any(buf[off + 28:off + 30]) or any(buf[off + 30:off + 32])
        print("    -> 非全零: %s, 末两行有笔画: %s" % ("有" if nz else "无", "有" if tail_nz else "无"))
        ok &= bool(nz and tail_nz)

    # c) 非全零槽位统计
    #    说明: 任务书原口径 ">8000" 不成立 —— GB2312 全标准只有 7445 个有效
    #    码位(682 符号 + 3755 一级字 + 3008 二级字), 非全零槽上限即 7445,
    #    再减去全角空格等渲染为空白的合法字符。正确判据: 解码槽数恰为 7445,
    #    且非全零槽 >7400。
    n_nonzero = 0
    for i in range(FILE_SIZE // SLOT_BYTES):
        if any(buf[i * SLOT_BYTES:(i + 1) * SLOT_BYTES]):
            n_nonzero += 1
    print("[c] 非全零槽位数 = %d (期望区间 7401..7445; 任务书 '>8000' 不成立, 因 GB2312 仅有 7445 个定义码位) -> %s"
          % (n_nonzero, "PASS" if 7400 < n_nonzero <= 7445 else "FAIL"))
    ok &= (7400 < n_nonzero <= 7445)

    n_zero = FILE_SIZE // SLOT_BYTES - n_nonzero
    print("    (参考: 全零槽 %d 个 = GB2312 未定义位 + qu88..94 保留区 + 全角空格等空白字符)" % n_zero)
    return ok


def main():
    print("== gen_hzk16.py: 生成标准 HZK16 镜像 ==")
    print("字体: %s  %dpx  阈值>=%d  偏移%s" % (FONT_PATH, FONT_SIZE, THRESH, OFFSET))
    buf, n_decoded, n_undef, blank_hanzi = build()
    print("遍历 %d 槽: 解码成功 %d, 未定义(全0) %d" % (FILE_SIZE // SLOT_BYTES, n_decoded, n_undef))
    # 国标总码位数校验: GB2312 定义 7445 字符(682 符号 + 6763 汉字), 恰 1601='啊' 5589='准'... 等
    if n_decoded != 7445 or blank_hanzi:
        print("SELF-CHECK FAILED (解码数=%d 应为7445; 汉字区全零=%s)" % (n_decoded, blank_hanzi))
        sys.exit(1)
    with open(OUT_PATH, "wb") as f:
        f.write(buf)
    print("已写出 %s" % OUT_PATH)
    print("-- 自验 --")
    ok = self_check(OUT_PATH)
    print("ALL PASS" if ok else "SELF-CHECK FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
