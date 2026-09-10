# -*- coding: utf-8 -*-
"""make_bmp.py — 任意图片/视频 → 板卡可播的 640x480 24bit BMP 序列

板卡固件的取图条件（bmp_read 扫描判据）：
  BMP 头 "BM" + 宽=640 + 高=480 + 24bit 色深 + 未压缩。
任何手机照片、网图、视频，先经本工具"标准化"，拷进 TF 卡即可播。

用法（fpga_batch 环境）：
  python make_bmp.py 图片1.jpg 图片2.png ...        # 直接转，输出到 bmp_out\\
  python make_bmp.py --video 短片.mp4               # 视频抽帧成图序列（需 ffmpeg）
  python make_bmp.py --fit cover 大图.jpg           # 裁剪填满（默认 contain=留黑边）
  python make_bmp.py --fps 2 --seconds 20 片.mp4    # 视频每 0.5s 取一帧，最多 20 秒
输出命名：BMP0000.BMP, BMP0001.BMP...（按传入顺序），拷到 TF 卡根目录即可，
板上扫描最多收 32 张（SCAN32 命令链式续扫），PLY 命令挑 subset（前 8 张里选），
VID <1-32> 进入"动感画报"连播（0.3 秒/帧，最多 32 帧）。

大白话：FPGA 是"死心眼"的放映机——只认 640x480、24 位、不压缩的标准 BMP。
本工具就是"剪辑师"，把任何素材预先裁成统一尺寸。这比在 FPGA 里塞一个
缩放器（resizer，要多花几千 LUT + 一行几毫秒的实时计算）划算得多——
展陈内容本来就是提前备好的，改在 PC 侧一秒钟处理完。
"""
import argparse, os, subprocess, sys, glob

W, H = 640, 480
MAX_FRAMES = 32          # 板上 img_sector 表深度（v10：7→32，动感画报 0.3s/帧）

def convert_image(src, dst, fit="contain", bg=(0, 0, 0)):
    from PIL import Image
    im = Image.open(src)
    im = im.convert("RGB")
    if fit == "cover":
        # 等比放大到填满，再居中裁掉超出部分
        scale = max(W / im.width, H / im.height)
        im = im.resize((int(round(im.width * scale)), int(round(im.height * scale))),
                       Image.LANCZOS)
        l = (im.width - W) // 2
        t = (im.height - H) // 2
        im = im.crop((l, t, l + W, t + H))
    else:
        # contain: 等比缩放到装得下，空隙填黑
        im.thumbnail((W, H), Image.LANCZOS)
        canvas = Image.new("RGB", (W, H), bg)
        canvas.paste(im, ((W - im.width) // 2, (H - im.height) // 2))
        im = canvas
    im.save(dst, "BMP")   # Pillow BMP 默认 24bit 未压缩 bottom-up —— 正是板卡要的
    return dst

def video_frames(video, outdir, fps=1.0, seconds=None, fit="contain"):
    """ffmpeg 抽帧 → 逐帧走 convert_image 管线"""
    tmp = os.path.join(outdir, "_frames")
    os.makedirs(tmp, exist_ok=True)
    cmd = ["ffmpeg", "-y", "-i", video, "-vf", "fps=%g" % fps]
    if seconds:
        cmd += ["-t", str(seconds)]
    cmd += [os.path.join(tmp, "f%05d.png")]
    print("[ffmpeg]", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit("ffmpeg 失败（没装？路径错？）：\n" + r.stderr[-800:])
    return sorted(glob.glob(os.path.join(tmp, "*.png")))

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="图片路径 / --video 时为单个视频")
    ap.add_argument("--outdir", default="bmp_out", help="输出目录（默认 bmp_out）")
    ap.add_argument("--fit", choices=["contain", "cover"], default="contain",
                    help="contain=完整+黑边(默认) cover=填满+裁边")
    ap.add_argument("--video", action="store_true", help="输入是视频，抽帧成图序列")
    ap.add_argument("--fps", type=float, default=1.0, help="视频抽帧率（默认每秒1帧）")
    ap.add_argument("--seconds", type=float, default=None, help="只取前 N 秒")
    a = ap.parse_args()

    os.makedirs(a.outdir, exist_ok=True)
    srcs = []
    if a.video:
        srcs = video_frames(a.inputs[0], a.outdir, a.fps, a.seconds, a.fit)
        print("抽帧 %d 张" % len(srcs))
    else:
        srcs = [p for p in a.inputs if os.path.isfile(p)]

    # v10：板上扇区表 32 深，超过则警告并截断前 32 帧（默认仍按 --seconds/--fps 抽）
    if len(srcs) > MAX_FRAMES:
        print("警告：待处理 %d 张 > 板卡上限 %d 张，"
              "已截断保留前 %d 帧（动感画报 VID 最多连播 32 帧）。"
              % (len(srcs), MAX_FRAMES, MAX_FRAMES))
        srcs = srcs[:MAX_FRAMES]

    n = 0
    for s in srcs:
        dst = os.path.join(a.outdir, "BMP%04d.BMP" % n)
        convert_image(s, dst, a.fit)
        print("%-40s -> %s" % (os.path.basename(s), dst))
        n += 1
    print("完成 %d 张。整盘拷到 TF 卡根目录（FAT32），板上 NEXT/AUTO/PLY 播放。" % n)
    print("提醒：板卡固件按扫描顺序收前 %d 张（SCAN32 命令链式续扫）；一张 ~900KB，普通卡秒切。" % MAX_FRAMES)
    print("     动感画报：SCAN32 后发 VID <1-32> 进入 0.3 秒/帧连播（会动的海报）。")

if __name__ == "__main__":
    main()
