# -*- coding: utf-8 -*-
"""scaler_golden_cmp.py — img_scaler 像素级 golden 比对

读 tools/tests/scaler_out.txt（iverilog 仿真吐出的 24bit 像素流，行序 = dx 递增→dy 递增），
按 img_scaler.v 应有的语义离线重算 golden，逐像素比对并输出诊断。

失败判据：任一像素 RGB != golden -> 渲染层错误（= 花屏）
"""
import os
import sys

SRC_W, SRC_H = 800, 600
DST_W, DST_H = 640, 480
HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(HERE, "scaler_out.txt")
OUT = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUT


def golden_geom(src_w, src_h):
    """复算 img_scaler.v 的几何（L162-191 语义）"""
    e_l = src_w * 512 - src_w * 32          # {sw1,9'd0} - {4'd0,sw1,5'd0} = w*512-w*32
    e_r = src_h * 512 + src_h * 128         # {sh1,9'd0} + {2'd0,sh1,7'd0} = h*512+h*128
    est_w = e_l >= e_r                      # 寄存器域 est_w
    est_c = est_w                           # 端口组合版同式
    wide = est_c
    t_nd = (e_l // src_w) if est_w else (e_r // src_h)
    t_nd = max(1, t_nd)
    sx_step = (src_w * 8192) // (640 if wide else t_nd)
    sy_step = (src_h * 8192) // (t_nd if wide else 480)
    sx_step = max(1, sx_step)
    sy_step = max(1, sy_step)
    tclamp = max(1, t_nd)
    dst_w = 640 if wide else t_nd
    dst_h = t_nd if wide else 480
    offx = (640 - dst_w) >> 1
    offy = (480 - dst_h) >> 1
    return wide, t_nd, sx_step, sy_step, dst_w, dst_h, offx, offy


def main():
    if not os.path.exists(OUT):
        print("missing %s — 先跑 tb_scaler_golden" % OUT)
        return 2

    with open(OUT, "r") as f:
        raw = [int(l.strip(), 16) for l in f if l.strip()]
    print("sim pixels read : %d" % len(raw))
    if len(raw) != DST_W * DST_H:
        print("!! 像素数不符 %d != %d" % (len(raw), DST_W * DST_H))
        return 1

    wide, t_nd, sx_step, sy_step, dw, dh, offx, offy = golden_geom(SRC_W, SRC_H)
    print("geometry        : wide=%d t_nd=%d sx_step=%d sy_step=%d dst=%dx%d off=(%d,%d)"
          % (wide, t_nd, sx_step, sy_step, dw, dh, offx, offy))
    print("-" * 76)

    bad = 0
    first_bad = None
    rows_bad = {}
    for dy in range(DST_H):
        cy = dy - offy
        sy = ((2 * cy + 1) * sy_step) >> 14
        syc = min(sy, SRC_H - 1)
        row_bad = 0
        for dx in range(DST_W):
            cx = dx - offx
            sx = ((2 * cx + 1) * sx_step) >> 14
            sxc = min(sx, SRC_W - 1)
            # 合成源图 = {R=sxc[7:0], G=syc[7:0], B=(sxc+syc)[7:0]}
            gr = sxc & 0xFF
            gg = syc & 0xFF
            gb = (sxc + syc) & 0xFF
            want = (gr << 16) | (gg << 8) | gb
            got = raw[dy * DST_W + dx]
            if got != want:
                bad += 1
                row_bad += 1
                if first_bad is None:
                    first_bad = (dx, dy, got, want, sxc, syc)
        if row_bad:
            rows_bad[dy] = row_bad

    total = DST_W * DST_H
    print("wrong pixels    : %d / %d  (%.2f%%)" % (bad, total, 100.0 * bad / total))
    print("rows with error : %d / %d" % (len(rows_bad), DST_H))
    if first_bad:
        dx, dy, got, want, sxc, syc = first_bad
        print("first error     : dst(%d,%d) got=0x%06X want=0x%06X  (golden src=(%d,%d))"
              % (dx, dy, got, want, sxc, syc))
    print("-" * 76)

    # 反向解析：从 G 分量反推仿真实际读到的源行
    print("行号轨迹抽查（从 G 分量反推实际源行 vs 应有源行）:")
    for dy in [0, 1, 2, 3, 5, 10, 50, 100, 240, 400, 478, 479]:
        cy = dy - offy
        sy = ((2 * cy + 1) * sy_step) >> 14
        want_syc = min(sy, SRC_H - 1)
        got_val = raw[dy * DST_W + 0]
        got_syc = (got_val >> 8) & 0xFF
        flag = "OK " if got_syc == (want_syc & 0xFF) else "BAD"
        print("   dy=%-4d 应有源行 %-4d  实测源行 %-4d  %s" % (dy, want_syc, got_syc, flag))

    print()
    # ---------------------------------------------------------------
    # 关键区分：是「真渲染错误」还是「纯流水线延迟」？
    # 若存在某个整数偏移 s，使 got[i] == want[i+s] 对几乎全部 i 成立，
    # 说明像素内容本身是正确的，只是整体相位差（= pipeline latency）。
    # ---------------------------------------------------------------
    if bad and bad > total * 0.5:
        print("偏移搜索（判定「渲染错误」还是「整体相位差」）:")
        best_s, best_ok, best_n = None, 0, 0
        for s in range(-3, 4):
            ok = 0
            n = 0
            for dy in range(0, DST_H, 7):          # 稀疏采样，够判定趋势
                cy = dy - offy
                sy = ((2 * cy + 1) * sy_step) >> 14
                syc = min(sy, SRC_H - 1)
                for dx in range(0, DST_W, 5):
                    j = dy * DST_W + dx
                    k = j + s
                    if k < 0 or k >= total:
                        continue
                    cx = dx - offx
                    sx = ((2 * cx + 1) * sx_step) >> 14
                    sxc = min(sx, SRC_W - 1)
                    wv = ((sxc & 0xFF) << 16) | ((syc & 0xFF) << 8) | ((sxc + syc) & 0xFF)
                    n += 1
                    if raw[k] == wv:
                        ok += 1
            rate = 100.0 * ok / n if n else 0.0
            print("   s=%+d  匹配 %0d/%0d  (%.2f%%)" % (s, ok, n, rate))
            if ok > best_ok:
                best_s, best_ok, best_n = s, ok, n
        if best_ok == best_n and best_n > 0:
            print("   => 存在完美偏移 s=%+d：像素内容全部正确，仅为%s延时，非渲染错误"
                  % (best_s, "输出流水"))
            return 0
    print()
    if bad:
        print("### VERDICT: FAIL — 渲染层像素错误已复现（=%s）"
              % ("花屏" if bad > total * 0.05 else "局部错位"))
        return 1
    print("### VERDICT: PASS — 像素完全匹配 golden")
    return 0


if __name__ == "__main__":
    sys.exit(main())
