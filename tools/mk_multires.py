# -*- coding: utf-8 -*-
"""multires_demo: 明日常规卡用的多分辨率演示图（扩展3 验收图组）。
   输出 24bit 未压缩 BMP，bottom-up（板子唯一认的 BMP 形态）。
   命名对齐板子扫描规则 BMPnnnn.BMP，同目录 README.txt 写对照表。"""
import os
from PIL import Image, ImageDraw

OUT = os.path.join(os.path.dirname(__file__), "multires_demo")
os.makedirs(OUT, exist_ok=True)

def label(im, text):
    d = ImageDraw.Draw(im)
    fs = max(16, im.height // 8)
    d.rectangle([0, 0, im.width - 1, fs + 18], fill=(0, 0, 0))
    d.text((10, 8), text, fill=(255, 255, 255))

def grid_bg(im, step=64):
    d = ImageDraw.Draw(im)
    w, h = im.size
    base = [(40, 90, 160), (250, 250, 250)]
    for y in range(0, h, step):
        for x in range(0, w, step):
            c = base[((x // step) + (y // step)) % 2]
            d.rectangle([x, y, min(x + step, w) - 1, min(y + step, h) - 1], fill=c)
    for y in range(0, h, step):          # 亮分隔线，肉眼可数
        d.line([0, y, w - 1, y], fill=(255, 210, 60), width=2)
    for x in range(0, w, step):
        d.line([x, 0, x, h - 1], fill=(255, 210, 60), width=2)

IMAGES = [
    ("BMP0000.BMP", 640, 480, "标准图（不该缩放）"),
    ("BMP0001.BMP", 1280, 720, "16:9 横图 -> 上下黑边"),
    ("BMP0002.BMP", 800, 600, "4:3 缩小 -> 铺满"),
    ("BMP0003.BMP", 400, 800, "竖图 1:2 -> 左右黑边"),
    ("BMP0004.BMP", 1024, 768, "XGA -> 铺满"),
    ("BMP0005.BMP", 320, 240, "小图 2x 放大"),
    ("BMP0006.BMP", 640, 200, "极扁横条 -> 缩放居中黑边(b-19)"),
    ("BMP0007.BMP", 1280, 360, "扁横条 -> 缩放居中黑边(b-19)"),
]
readme = ["扩展3 多分辨率演示图组 · 明天拷 TF 卡根目录（先跑 TF卡一键修复.bat）", ""]
for name, w, h, desc in IMAGES:
    im = Image.new("RGB", (w, h), (30, 30, 30))
    grid_bg(im, step=max(16, min(w, h) // 8))
    # 四角色块：上=红/绿 下=黑/白 —— 缩放后边界与黑带一眼可辨
    s = max(10, min(w, h) // 10)
    d = ImageDraw.Draw(im)
    label(im, "%dx%d %s" % (w, h, desc))           # 标题带先画，角块压在带角上更醒目
    d.rectangle([0, h - s, s - 1, h - 1], fill=(0, 0, 0))
    d.rectangle([w - s, h - s, w - 1, h - 1], fill=(255, 255, 255))
    d.rectangle([0, 0, s - 1, s - 1], fill=(230, 40, 40))      # 左上红
    d.rectangle([w - s, 0, w - 1, s - 1], fill=(40, 200, 80))  # 右上绿
    im.save(os.path.join(OUT, name))
    readme.append("%-12s %5dx%-5d %s" % (name, w, h, desc))
with open(os.path.join(OUT, "README.txt"), "w", encoding="gbk") as f:
    f.write("\n".join(readme) + "\n")
    f.write("\n!! 使用顺序（插卡后，仿真实证的坑）：先 `SC 1`（智能缩放开关），再点【扫满 32 张】，最后 `LIST?` 核对=13。\n")
    f.write("   SC=0 时扫描器只登记 640×480 标准图，本组多分辨率图会在登记那一刻被拒；顺序反了重扫一次即可恢复。\n")
    f.write("   权威步骤见 17 号播控台手册『明天板测验收清单』第 0 步。\n")
print("wrote", len(IMAGES), "images to", OUT)
