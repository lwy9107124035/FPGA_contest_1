# -*- coding: utf-8 -*-
"""
convert_font_image.py — 把 hzk16.bin 拼接成 W25Q64 可直接烧录的整片镜像

背景说明:
  W25Q64 是本板的"用户 FLASH", 不参与 FPGA 上电配置(boot 走的是挂在 MSPI
  专用引脚上的另一颗 W25Q16, 与本方案无关)。因此它不需要安路 TD bit 流
  拼接格式(那种 hdr/bin 级联只针对 MSPI 启动链), 烧录路径是:
    安路上位机烧写工具(TD 自带 Programmer / Flash Programmer, 选 SPI NOR
    W25Q64) 或 厂商 SVF(经 FPGA JTAG 间接驱动 FLASH),
  目标起始地址固定 0x000000 —— 本 FPGA 字模取模地址公式即按此假设。
  详见 README_cjk_flash.md 第 3 节。

本脚本做三件事:
  1) 校验 hzk16.bin 大小 == 282,752 字节;
  2) 产出烧录镜像:
     - w25q64_cjk_full.bin   : 整片 8MiB, 字库放 0x000000, 其余填 0xFF
                               (=擦除态, 全片写入一步到位, 推荐烧这个)
     - w25q64_cjk_sector.bin : 仅字库+补齐到 4KiB 扇区边界(70 扇区, 286,720B),
                               供支持"指定偏移+部分扇区"烧写的高级用法
  3) 回读自检(不依赖内存缓存, 从最终文件按地址公式再查一遍字模), 并写
     cjk_flash_manifest.txt(尺寸/md5/布局说明), 供烧录工具核对。

用法:
  & C:\\Users\\lwy\\miniconda3\\envs\\fpga_batch\\python.exe convert_font_image.py
  & ... convert_font_image.py --check "台风预警立即撤离"   # 从整片镜像回读预览
"""

import hashlib
import os
import sys

HERE   = os.path.dirname(os.path.abspath(__file__))
HZK    = os.path.join(HERE, "hzk16.bin")
OUT_FULL = os.path.join(HERE, "w25q64_cjk_full.bin")
OUT_SECT = os.path.join(HERE, "w25q64_cjk_sector.bin")
MANIFEST = os.path.join(HERE, "cjk_flash_manifest.txt")

FLASH_SIZE  = 8 * 1024 * 1024        # W25Q64 = 8 MiB
BASE_ADDR   = 0x000000               # 字库烧录起始地址(与 FPGA 地址公式一致)
FONT_SIZE   = 282752                 # 94区 x 94位 x 32B
SECTOR      = 4096                   # W25Q64 最小擦除单位

SLOT_BYTES  = 32
WEI_MAX     = 94


def slot_offset_of_char(ch, buf=None):
    """由字符求镜像内偏移(先 GB2312 编码反查区位)。buf 仅用于校验长度。"""
    code = ch.encode("gb2312")
    qu, wei = code[0] - 0xA0, code[1] - 0xA0
    return BASE_ADDR + ((qu - 1) * WEI_MAX + (wei - 1)) * SLOT_BYTES


def preview_from_image(path, chars):
    """烧录镜像回读自检: 打开最终 bin, 按地址公式取字模并打点阵。"""
    with open(path, "rb") as f:
        data = f.read()
    ok = True
    for ch in chars:
        off = slot_offset_of_char(ch)
        s = data[off:off + SLOT_BYTES]
        nz = any(s)
        print('  "%s' % ch + '" 镜像偏移 0x%06X  非全零=%s' % (off, "有" if nz else "无!!"))
        for y in range(16):
            v = (s[y * 2] << 8) | s[y * 2 + 1]
            print("    |" + "".join("#" if v & (1 << (15 - x)) else "." for x in range(16)) + "|")
        ok &= nz
    return ok


def md5sum(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def main():
    args = sys.argv[1:]

    # ---- 纯回读预览模式 ----
    if "--check" in args:
        i = args.index("--check")
        text = args[i + 1] if i + 1 < len(args) else "台"
        print("== 从 %s 回读预览 ==" % OUT_FULL)
        sys.exit(0 if preview_from_image(OUT_FULL, list(text.replace(" ", ""))) else 1)

    # ---- 正常转换模式 ----
    print("== convert_font_image.py: HZK16 -> W25Q64 烧录镜像 ==")
    if not os.path.exists(HZK):
        print("找不到 %s, 请先运行 gen_hzk16.py" % HZK)
        sys.exit(1)
    with open(HZK, "rb") as f:
        font = f.read()
    if len(font) != FONT_SIZE:
        print("hzk16.bin 大小 %d != %d, 拒绝继续" % (len(font), FONT_SIZE))
        sys.exit(1)
    print("hzk16.bin 校验通过: %d 字节" % len(font))

    # 整片 8MiB: 0xFF 打底(擦除态), 字库覆写于 0x000000
    img = bytearray(b"\xFF" * FLASH_SIZE)
    img[BASE_ADDR:BASE_ADDR + FONT_SIZE] = font
    with open(OUT_FULL, "wb") as f:
        f.write(img)
    print("已写 %s (%d 字节, 整片 8MiB, 空白=0xFF)" % (OUT_FULL, os.path.getsize(OUT_FULL)))

    # 扇区对齐最小镜像: 70 x 4KiB (尾部补 0xFF)
    pad = ((FONT_SIZE + SECTOR - 1) // SECTOR) * SECTOR
    sect = bytearray(b"\xFF" * pad)
    sect[0:FONT_SIZE] = font
    with open(OUT_SECT, "wb") as f:
        f.write(sect)
    print("已写 %s (%d 字节 = %d 个 4KiB 扇区)" % (OUT_SECT, pad, pad // SECTOR))

    # ---- 回读自检 ----
    print("-- 镜像回读自检 --")
    ok = preview_from_image(OUT_FULL, ["警", "撤离"])
    ok &= preview_from_image(OUT_SECT, ["警"])

    m_full, m_sect = md5sum(OUT_FULL), md5sum(OUT_SECT)
    with open(MANIFEST, "w", encoding="utf-8") as f:
        f.write("CJK 字模 W25Q64 烧录镜像清单 (convert_font_image.py 自动生成)\n\n")
        f.write("目标芯片   : W25Q64 (U33, 板载用户 SPI NOR, 8MiB) —— 勿与 MSPI 上的 boot FLASH W25Q16 混淆\n")
        f.write("烧录基地址 : 0x%06X (FPGA 取模地址公式按此假设)\n" % BASE_ADDR)
        f.write("字库格式   : 标准 HZK16, %d 字节 = 94区x94位x32B, qu=1..87 有内容\n" % FONT_SIZE)
        f.write("地址公式   : off = ((qu-1)*94 + (wei-1)) * 32,  qu=高字节-0xA0, wei=低字节-0xA0\n")
        f.write("区划速查   : qu 1..9 符号区 | 10..15 未定义(全0) | 16..55 一级汉字 | 56..87 二级汉字 | 88..94 保留(全0)\n\n")
        f.write("w25q64_cjk_full.bin   : %10d B  md5=%s  (推荐: 整片一步烧录)\n" % (FLASH_SIZE, m_full))
        f.write("w25q64_cjk_sector.bin : %10d B  md5=%s  (4KiB 扇区对齐子集)\n" % (pad, m_sect))
        f.write("hzk16.bin             : %10d B  md5=%s  (字库本体)\n" % (len(font), md5sum(HZK)))
        f.write("\n烧录后 FPGA 侧验收: 见 README_cjk_flash.md 第 9 节。\n")
    print("已写 %s" % MANIFEST)
    print("自检结果: %s" % ("ALL PASS" if ok else "FAILED"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
