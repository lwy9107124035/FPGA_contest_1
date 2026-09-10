#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""card_fix.py —— TF 卡“板子扫不到新图”诊断 + 一键整卡重建。

背景：本 FPGA 播图器不读 FAT，而是从卡起始扇区开始、逐段“内容签名”扫描
      (BM + 640x480 + 24bit + comp0)，靠“头扇区 + 文件长度”连续跳读。
      因此它对两点敏感：① 文件数据必须在其头扇区之后【连续】；② 相邻两图
      之间的“空扇区”若 >8191，扫描会误判目录到尾而提前止损。
      反复增删/碎片化就可能让第 N 张“卡里明明有、板子扫不到”。

用法：
  python card_fix.py scan                 # 只诊断：打印 FAT 目录表 + 原始扇区里
                                          #   每个合法 BMP 头的物理位置，并对比
                                          #   相邻间隙是否超 8191、是否碎片
  python card_fix.py rebuild --keep 4     # 修复：先把卡上所有 .bmp 备份到 PC，
                                          #   再把卡清空，按序整块连续重写
                                          #   （默认重写扫描到的全部，--keep 限张数）
需要管理员权限（裸卷读 \\.\X:）。若拒绝访问，请以管理员身份重跑本脚本。
"""
import argparse
import ctypes
import glob
import os
import shutil
import struct
import sys

kernel32 = ctypes.windll.kernel32
kernel32.CreateFileW.restype = ctypes.c_void_p
kernel32.SetFilePointerEx.argtypes = [ctypes.c_void_p, ctypes.c_longlong,
                                      ctypes.c_void_p, ctypes.c_uint]
GENERIC_READ = 0x80000000
FILE_SHARE_RW = 3
OPEN_EXISTING = 3
INVALID = ctypes.c_void_p(-1).value


def find_card():
    mask = kernel32.GetLogicalDrives()
    for i in range(26):
        if not (mask >> i) & 1:
            continue
        letter = chr(ord("A") + i)
        root = letter + ":\\"
        try:
            if kernel32.GetDriveTypeW(root) != 2:      # REMOVABLE
                continue
        except Exception:
            continue
        if glob.glob(os.path.join(root, "*.bmp")):
            return root, letter
    return None, None


class RawVol:
    """裸卷按扇区读取（需管理员）。sector 号是【分区内】(volume) LBA。"""

    def __init__(self, letter):
        self.h = kernel32.CreateFileW("\\\\.\\%s:" % letter, GENERIC_READ,
                                      FILE_SHARE_RW, None, OPEN_EXISTING, 0x80, None)
        if self.h in (0, None, INVALID):
            raise OSError("打不开裸卷 \\\\.\\%s: （需要管理员权限；或卡已拔出）" % letter)

    def read(self, sec, n=1):
        if kernel32.SetFilePointerEx(self.h, sec * 512, None, 0) == 0:
            return b""
        buf = ctypes.create_string_buffer(n * 512)
        got = ctypes.c_ulong(0)
        ok = kernel32.ReadFile(self.h, buf, n * 512, ctypes.byref(got), None)
        return buf.raw[:got.value] if ok else b""

    def close(self):
        if self.h not in (0, None, INVALID):
            kernel32.CloseHandle(self.h)


def bpb_info(raw):
    spc = raw[13]
    rs = struct.unpack("<H", raw[14:16])[0]
    nfat = raw[16]
    spf = struct.unpack("<I", raw[36:40])[0]
    root = struct.unpack("<I", raw[44:48])[0]
    data_start = rs + nfat * spf
    return dict(spc=spc, reserved=rs, spf=spf, nfat=nfat, root=root, data_start=data_start)


def fat_chain(rawfat, start):
    ch = [start]
    c = start
    for _ in range(400000):
        c = struct.unpack("<I", rawfat[c * 4:c * 4 + 4])[0] & 0x0FFFFFFF
        if c < 2 or c >= 0x0FFFFFF8:
            break
        ch.append(c)
    return ch


def dir_entries(vol, info):
    """遍历根目录簇链，返回 (shortname, startcl, size, contig) 列表。"""
    ds = info["data_start"]
    spc = info["spc"]
    rawfat = vol.read(info["reserved"], info["spf"] * info["nfat"])
    chain = fat_chain(rawfat, info["root"])
    rd = b"".join(vol.read(ds + (ci - 2) * spc, spc) for ci in chain)
    out = []
    for i in range(0, len(rd) - 32, 32):
        e = rd[i:i + 32]
        if e[0] == 0:
            break
        if e[0] in (0xE5, 0x05) or e[11] in (0x0F, 0x05):
            continue
        if e[11] != 0x20:
            continue
        nm = e[:11].decode("ascii", "replace")
        if not nm.lower().endswith("bmp"):
            continue
        clus = struct.unpack("<H", e[20:22])[0] * 65536 + struct.unpack("<H", e[26:28])[0]
        size = struct.unpack("<I", e[28:32])[0]
        contig = fat_chain(rawfat, clus)
        out.append((nm, clus, size, contig))
    return sorted(out)


def is_bmp_header(b):
    return (len(b) >= 54 and b[:2] == b"BM"
            and struct.unpack("<H", b[28:30])[0] == 24
            and struct.unpack("<I", b[30:34])[0] == 0
            and abs(struct.unpack("<i", b[18:22])[0]) == 640
            and abs(struct.unpack("<i", b[22:26])[0]) == 480)


def scan_cmd():
    root, letter = find_card()
    if not letter:
        print("没检测到插着且含 .bmp 的可移动盘（卡插回读卡器？或以管理员运行？）")
        return 1
    vol = RawVol(letter)
    try:
        info = bpb_info(vol.read(0, 1))
        print("卡 %s  数据区: 扇区/簇=%d 保留=%d 数据区起扇区=%d" %
              (root, info["spc"], info["reserved"], info["data_start"]))
        print("\n[A] FAT 目录里的 BMP（起始簇 -> 卷内头扇区 -> 是否连续）：")
        for nm, clus, size, contig in dir_entries(vol, info):
            start = info["data_start"] + (clus - 2) * info["spc"]
            need = (size + 511) // 512
            got = len(contig) * info["spc"]
            frag = len(contig) > 1 and any(
                contig[k + 1] - contig[k] != 1 for k in range(len(contig) - 1))
            print("   %-16s startcl=%-6d 头扇区=%-8d 需%d扇区 连%d %s"
                  % (nm, clus, start, need, got, "碎片!" if frag else "连续"))
        print("\n[B] 原始扇区内容扫描（模拟板子逐段跳读，找所有合法 BMP 头）：")
        hits = []
        sec = 0
        # 只在数据区附近扫，省时间：从第一个文件头扇区-2000 到 +20万
        files = dir_entries(vol, info)
        if files:
            lo = info["data_start"]
            hi = lo + 220000
        else:
            lo, hi = 0, 220000
        sec = lo
        miss = 0
        while sec < hi:
            b = vol.read(sec, 1)
            if len(b) < 54:
                break
            if is_bmp_header(b):
                hits.append(sec)
                miss = 0
                sec += 1801
                continue
            miss += 1
            if hits and miss > 8191:      # 与板子同款止损，别爬空区
                break
            sec += 1
        print("   合法 BMP 头物理位置(卷内扇区)：", hits)
        print("   共 %d 个；板子会按此顺序登记为第 1..N 张" % len(hits))
        for k in range(1, len(hits)):
            gap = hits[k] - (hits[k - 1] + 1801)
            flag = "  ⚠ 间隙>8191 会提前止损！" if gap > 8191 else ""
            print("   #%d->#%d 跳读间隙=%d 扇区%s" % (k, k + 1, gap, flag))
        return 0
    finally:
        vol.close()


def rebuild_cmd(keep):
    root, letter = find_card()
    if not letter:
        print("没检测到含 .bmp 的可移动卡；abort。")
        return 1
    # 备份
    bdir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "card_backup")
    os.makedirs(bdir, exist_ok=True)
    srcs = sorted(glob.glob(os.path.join(root, "*.bmp")))
    if keep:
        srcs = srcs[:keep]
    print("备份 %d 张 -> %s" % (len(srcs), bdir))
    datas = []
    for p in srcs:
        with open(p, "rb") as f:
            datas.append((os.path.basename(p), f.read()))
        shutil.copy2(p, os.path.join(bdir, os.path.basename(p)))
    # 清空卡根目录所有 bmp
    for p in glob.glob(os.path.join(root, "*.bmp")):
        os.remove(p)
    # 顺序连续重写（空卡上逐个 fsync，保证簇连续低位）
    print("重写为 BMP0000..BMP%04d 连续布局 ..." % (len(datas) - 1))
    for idx, (_nm, blob) in enumerate(datas):
        dst = os.path.join(root, "BMP%04d.BMP" % idx)
        with open(dst, "wb") as f:
            f.write(blob)
            f.flush()
            os.fsync(f.fileno())
    print("完成。请【安全弹出】→ 插回板子 → 先开【智能缩放 SC 1】→ 点【扫满 32 张】→ LIST? 看登记几张。")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan", help="诊断")
    rb = sub.add_parser("rebuild", help="整卡重建（连续低簇）")
    rb.add_argument("--keep", type=int, default=0, help="只保留前 N 张（默认全部）")
    a = ap.parse_args()
    return scan_cmd() if a.cmd == "scan" else rebuild_cmd(a.keep)


if __name__ == "__main__":
    sys.exit(main())
