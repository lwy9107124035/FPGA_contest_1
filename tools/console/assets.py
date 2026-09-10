# -*- coding: utf-8 -*-
"""assets.py — 素材发现 / 缩略图 / 导入转换（全部只写在 console 目录里）

这是什么：
  1. 找图：优先找插在电脑上的 TF 卡（可移动盘根目录下的 BMP*.BMP —— 那就是板子
     正在播的图）；没有卡就用 sd_prep\\bmp_out（最近转换产物）；再没有就用
     console\\bmp_out（本工具自己的输出目录）。
  2. 缩略图：Pillow 把每张图缩到 160px，缓存到 console\\thumbs\\，网页 <img> 直接用。
  3. 导入：任意 jpg/png/gif/bmp/webp/视频 -> 板卡能播的 640x480 24bit BMP。
     图片转换直接“借用”sd_prep\\make_bmp.py 里的函数（只读它，一个字都不改它）；
     视频抽帧需要本机 ffmpeg —— 没装就明确告诉用户，并禁用相应按钮（不报错崩溃）。

铁律：本文件只在 tools\\console\\ 下面写文件（thumbs/、bmp_out/），
以及按用户点按钮的意愿往 TF 卡根目录拷 BMP —— 绝不碰工程其它目录。
"""
import ctypes
import glob
import hashlib
import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
THUMB_DIR = os.path.join(HERE, "thumbs")
LOCAL_BMP_OUT = os.path.join(HERE, "bmp_out")          # 本工具的转换输出目录
SDPREP_BMP_OUT = r"C:\td_batch\lab_pro\tools\sd_prep\bmp_out"   # 只读：最近转换产物
MAKE_BMP_PY = r"C:\td_batch\lab_pro\tools\sd_prep\make_bmp.py"  # 只读：借用它的函数

IMG_EXT = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tif", ".tiff"}
VID_EXT = {".mp4", ".avi", ".mkv", ".mov", ".wmv", ".flv", ".webm"}

VIDEO_FRAME_CAP = 32  # v10：板子 SCAN32 候选表 + VID 连播上限都是 32 帧，导入抽帧对齐到 32（@2fps≈16 秒源片）


# ---------------------------------------------------------------------------
# 环境探测
# ---------------------------------------------------------------------------

def ffmpeg_path():
    """找 ffmpeg.exe（PATH 里）。找不到返回 None —— 调用方负责“优雅降级”。"""
    return shutil.which("ffmpeg") or shutil.which("ffmpeg.exe")


def detect_card():
    """找 TF 卡盘：可移动盘（GetDriveTypeW==2）根目录有任意 *.bmp（板子扫描认
    文件内容不认名字，卡上文件常是 01_01_apple.bmp 这类自取名字 —— 以前只认
    BMP 开头，卡插了也"看不见"，这就是网页读不到卡的真凶，v10.2.1 修正）。
    若整个电脑只有唯一可移动盘且没 bmp，也当"空新卡"返回（files 空表，
    方便一键拷卡按钮往格式化后的空卡里写首批图）。
    返回 {'root': 'E:\\\\', 'files': [...]} 或 None。"""
    try:
        kernel32 = ctypes.windll.kernel32
        mask = kernel32.GetLogicalDrives()
    except Exception:
        return None
    removable = []
    for i in range(26):
        if not (mask >> i) & 1:
            continue
        letter = chr(ord("A") + i)
        root = letter + ":\\"
        try:
            if kernel32.GetDriveTypeW(root) != 2:      # 2 = DRIVE_REMOVABLE
                continue
            files = sorted(set(glob.glob(os.path.join(root, "*.bmp"))))
        except Exception:
            continue
        removable.append((root, files))
    for root, files in removable:                      # 优先：根目录有 bmp 的
        if files:
            return {"root": root, "files": files}
    if len(removable) == 1:                            # 唯一可移动盘且没 bmp：空卡
        return {"root": removable[0][0], "files": []}
    return None


# ---------------------------------------------------------------------------
# make_bmp.py 的函数复用（只读导入；失败则退化为 subprocess 调用）
# ---------------------------------------------------------------------------

_makebmp_mod = None
_makebmp_tried = False


def _load_makebmp():
    """把 sd_prep/make_bmp.py 当模块读进来（不执行它的 main）。失败返回 None。"""
    global _makebmp_mod, _makebmp_tried
    if _makebmp_tried:
        return _makebmp_mod
    _makebmp_tried = True
    try:
        spec = importlib.util.spec_from_file_location("sd_prep_make_bmp", MAKE_BMP_PY)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        if hasattr(mod, "convert_image"):
            _makebmp_mod = mod
    except Exception:
        _makebmp_mod = None
    return _makebmp_mod


def convert_image(src, dst, fit="contain"):
    """任意图片 -> 640x480 24bit BMP（板卡可播）。优先用 make_bmp 的原函数。"""
    mod = _load_makebmp()
    if mod is not None:
        return mod.convert_image(src, dst, fit)
    # 退路：Pillow 自己按同样规则做一遍（等比缩放填黑边 / 裁剪填满）
    from PIL import Image
    W, H = 640, 480
    im = Image.open(src).convert("RGB")
    if fit == "cover":
        scale = max(W / im.width, H / im.height)
        im = im.resize((int(round(im.width * scale)), int(round(im.height * scale))),
                       Image.LANCZOS)
        l, t = (im.width - W) // 2, (im.height - H) // 2
        im = im.crop((l, t, l + W, t + H))
    else:
        im.thumbnail((W, H), Image.LANCZOS)
        canvas = Image.new("RGB", (W, H), (0, 0, 0))
        canvas.paste(im, ((W - im.width) // 2, (H - im.height) // 2))
        im = canvas
    im.save(dst, "BMP")
    return dst


def extract_video_frames(video, fps=2.0, max_frames=VIDEO_FRAME_CAP):
    """视频抽帧 -> 临时目录里的 png 列表。没有 ffmpeg 抛 RuntimeError（调用方变提示）。"""
    ff = ffmpeg_path()
    if not ff:
        raise RuntimeError("本机没找到 ffmpeg —— 视频抽帧用不了。装好 ffmpeg 并加入 PATH 后重启本工具。")
    outdir = tempfile.mkdtemp(prefix="console_frames_")
    cmd = [ff, "-hide_banner", "-loglevel", "error", "-y", "-i", video,
           "-vf", "fps=%g" % fps, "-frames:v", str(max_frames),
           os.path.join(outdir, "f%05d.png")]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        shutil.rmtree(outdir, ignore_errors=True)
        raise RuntimeError("ffmpeg 抽帧失败：%s" % (r.stderr or "")[-300:])
    frames = sorted(glob.glob(os.path.join(outdir, "*.png")))
    if not frames:
        shutil.rmtree(outdir, ignore_errors=True)
        raise RuntimeError("ffmpeg 没抽到帧（视频是空的？格式不支持？）")
    return outdir, frames


# ---------------------------------------------------------------------------
# BMP“板卡可播”判据（bmp_read 扫描条件）+ 缩略图缓存
# ---------------------------------------------------------------------------

def bmp_is_playable(path):
    """读 54 字节 BMP 头判断：BM + 宽640 + 高480 + 24bit + 未压缩。"""
    try:
        with open(path, "rb") as f:
            h = f.read(54)
        if len(h) < 54 or h[:2] != b"BM":
            return False
        w = int.from_bytes(h[18:22], "little")
        hh = int.from_bytes(h[22:26], "little", signed=True)
        bpp = int.from_bytes(h[28:30], "little")
        comp = int.from_bytes(h[30:34], "little")
        return w == 640 and abs(hh) == 480 and bpp == 24 and comp == 0
    except Exception:
        return False


def thumb_url_for(path):
    """给一张图生成（或复用）160px 缩略图，返回 /thumb/xxx 的 URL；失败返回 None。
    缓存键 = 完整路径+mtime+大小 的 md5 —— 文件换了/改了自动重做。"""
    try:
        st = os.stat(path)
        key = hashlib.md5(("%s|%d|%d" % (path, int(st.st_mtime_ns), st.st_size)).encode()).hexdigest()[:16]
        jpg = os.path.join(THUMB_DIR, key + ".jpg")
        if not os.path.isfile(jpg):
            from PIL import Image
            im = Image.open(path)
            im = im.convert("RGB")
            im.thumbnail((160, 160), Image.LANCZOS)
            tmp = jpg + ".part"
            im.save(tmp, "JPEG", quality=82)
            os.replace(tmp, jpg)
        return "/thumb/" + key + ".jpg"
    except Exception:
        return None


# ---------------------------------------------------------------------------
# 素材清单
# ---------------------------------------------------------------------------

def pick_default_root(card):
    """发现优先级：TF 卡根目录 > sd_prep\\bmp_out（有货才算）> console\\bmp_out。"""
    if card:
        return card["root"], "card"
    if os.path.isdir(SDPREP_BMP_OUT) and _has_media(SDPREP_BMP_OUT):
        return SDPREP_BMP_OUT, "bmp_out"
    return LOCAL_BMP_OUT, "local"


def _has_media(d):
    for name in os.listdir(d):
        if os.path.splitext(name)[1].lower() in IMG_EXT | VID_EXT:
            return True
    return False


def list_assets(root):
    """目录里的图片/视频清单（按文件名排序）。idx = 板卡扫描意义上的“第几张”。"""
    items = []
    try:
        names = sorted(os.listdir(root))
    except Exception:
        return items
    for name in names:
        p = os.path.join(root, name)
        if not os.path.isfile(p):
            continue
        ext = os.path.splitext(name)[1].lower()
        if ext in IMG_EXT:
            kind = "image"
        elif ext in VID_EXT:
            kind = "video"
        else:
            continue
        st = os.stat(p)
        items.append({
            "name": name,
            "path": p,
            "kind": kind,
            "size_kb": round(st.st_size / 1024, 1),
            "mtime": int(st.st_mtime),
            "thumb": thumb_url_for(p),
            "playable": (ext == ".bmp" and bmp_is_playable(p)),
        })
    return items


# ---------------------------------------------------------------------------
# 导入工坊
# ---------------------------------------------------------------------------

def import_files(paths, fit="contain"):
    """把用户选的文件转成板卡 BMP，输出到 console\\bmp_out（序号接着排）。
    返回 {'converted': [新文件], 'errors': [{'file':..,'why':..}]}。"""
    os.makedirs(LOCAL_BMP_OUT, exist_ok=True)
    existing = [os.path.basename(p) for p in
                glob.glob(os.path.join(LOCAL_BMP_OUT, "BMP????.BMP"))]
    # v10.2.1: 读卡器里插着卡（板子按 BMP0000 起连续编号读）时，新图序号
    # 接着卡上最大号往后排 —— 默认"追加"，不悄悄覆盖展陈中的老图
    card = detect_card()
    if card:
        for _p in card["files"]:
            _b = os.path.basename(_p)
            if len(_b) == 11 and _b[:3].upper() == "BMP" and _b[3:7].isdigit():
                existing.append(_b)
    next_n = 0
    for name in existing:
        try:
            next_n = max(next_n, int(name[3:7]) + 1)
        except ValueError:
            pass
    converted, errors = [], []
    tmpdirs = []
    try:
        for p in paths:
            p = os.path.abspath(p)
            ext = os.path.splitext(p)[1].lower()
            if not os.path.isfile(p):
                errors.append({"file": os.path.basename(p), "why": "文件不存在（被移动了？）"})
                continue
            try:
                if ext in IMG_EXT:
                    dst = os.path.join(LOCAL_BMP_OUT, "BMP%04d.BMP" % next_n)
                    convert_image(p, dst, fit)
                    converted.append(os.path.basename(dst))
                    next_n += 1
                elif ext in VID_EXT:
                    if not ffmpeg_path():
                        errors.append({"file": os.path.basename(p),
                                       "why": "视频抽帧需要 ffmpeg，本机没装 —— 先转图片吧"})
                        continue
                    tdir, frames = extract_video_frames(p)
                    tmpdirs.append(tdir)
                    made = 0
                    for fr in frames[:VIDEO_FRAME_CAP]:
                        dst = os.path.join(LOCAL_BMP_OUT, "BMP%04d.BMP" % next_n)
                        convert_image(fr, dst, fit)
                        converted.append(os.path.basename(dst))
                        next_n += 1
                        made += 1
                    if len(frames) > VIDEO_FRAME_CAP:
                        errors.append({"file": os.path.basename(p),
                                       "why": "抽了 %d 帧，板上一段最多 7 帧≈3.5 秒，只取前 7 帧"
                                              % len(frames)})
                else:
                    errors.append({"file": os.path.basename(p),
                                   "why": "不支持的文件类型 %s（支持图片 jpg/png/gif/bmp/webp 与视频 mp4/avi/mkv）" % ext})
            except Exception as e:
                errors.append({"file": os.path.basename(p), "why": "转换失败：%s" % e})
    finally:
        for td in tmpdirs:
            shutil.rmtree(td, ignore_errors=True)
    return {"converted": converted, "errors": errors}


def copy_to_card(source_dir, names, card_root):
    """把 source_dir 里的这些 BMP 拷到 TF 卡根目录（同名覆盖 —— UI 已让用户确认过）。
    返回 {'copied':[...], 'errors':[{'file','why'}]}。"""
    copied, errors = [], []
    if not card_root:
        return {"copied": [], "errors": [{"file": "-", "why": "没检测到 TF 卡（读卡器插了吗？）"}]}
    for name in names:
        src = os.path.join(source_dir, name)
        if not os.path.isfile(src):
            errors.append({"file": name, "why": "源文件不见了"})
            continue
        try:
            shutil.copy2(src, os.path.join(card_root, name))
            copied.append(name)
        except Exception as e:
            errors.append({"file": name, "why": "拷贝失败：%s" % e})
    return {"copied": copied, "errors": errors}


# ---------------------------------------------------------------------------
# 文件夹/多选文件选择（tkinter 弹窗）
# 用 subprocess 起一个一次性小 python 进程弹窗：不干扰主服务的线程模型。
# ---------------------------------------------------------------------------

_PICK_CODE = r'''
import sys, json
import tkinter as tk
from tkinter import filedialog
mode, outfile = sys.argv[1], sys.argv[2]
r = tk.Tk(); r.withdraw(); r.attributes("-topmost", True)
img_types = [("图片/视频", "*.jpg *.jpeg *.png *.gif *.bmp *.webp *.tif *.tiff "
                          "*.mp4 *.avi *.mkv *.mov *.wmv *.flv *.webm"), ("所有文件", "*.*")]
if mode == "files":
    got = list(filedialog.askopenfilenames(title="选择要导入的图片/视频（可多选）",
                                           filetypes=img_types))
elif mode == "dir":
    got = [filedialog.askdirectory(title="选择素材文件夹（里面有 BMP 最好）", mustexist=True)]
    got = [g for g in got if g]
else:
    got = []
open(outfile, "w", encoding="utf-8").write(json.dumps(got))
sys.exit(0)
'''


def open_picker(mode="files", timeout=180):
    """弹系统文件选择框。mode='files' 多选文件 / 'dir' 选目录。取消返回 []。"""
    out = tempfile.NamedTemporaryFile(prefix="console_pick_", suffix=".json", delete=False)
    out.close()
    try:
        subprocess.run([sys.executable, "-c", _PICK_CODE, mode, out.name],
                       timeout=timeout, capture_output=True)
        import json as _json
        with open(out.name, "r", encoding="utf-8") as f:
            data = _json.load(f)
        return [p for p in data if p]
    except Exception:
        return []
    finally:
        try:
            os.unlink(out.name)
        except OSError:
            pass
