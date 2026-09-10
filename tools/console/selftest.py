# -*- coding: utf-8 -*-
"""selftest.py — 一键验收：假板子协议单测 + 起真服务 HTTP 端到端测试

怎么跑：
  C:\\Users\\lwy\\miniconda3\\envs\\fpga_batch\\python.exe selftest.py
全部通过打印 ALL PASS（退出码 0）。任何一步红了打印 FAIL 原因（退出码 1）。

安全声明：本测试从头到尾只用 FakeSerial（纯内存假板子），
绝对不会打开 COM4 或任何真实串口 —— 主线在用串口测量时可以放心并发跑。
"""
import json
import os
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from urllib.error import URLError, HTTPError

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import fpga_link                      # noqa: E402
import assets                         # noqa: E402

PASS = FAILN = 0


def check(name, cond, detail=""):
    global PASS, FAILN
    if cond:
        PASS += 1
        print("  PASS  " + name)
    else:
        FAILN += 1
        print("  FAIL  " + name + ("   <-- " + detail if detail else ""))


def read_all(fake, limit=200):
    """把假板子攒的回执一次性读干净。"""
    out = b""
    for _ in range(limit):
        d = fake.read(64)
        if not d:
            break
        out += d
    return out


# ===========================================================================
# A. FakeSerial 协议单测（字节级预期，直接对齐 msg_ink.v v9.1）
# ===========================================================================

def test_protocol():
    print("[A] FakeSerial 协议单测（字节级）")

    # --- 命令编码字节级 ---
    check("build_frame NEXT 字节", fpga_link.build_frame("NEXT") == b"NEXT\n")
    f = fpga_link.build_frame("MSG 应急ABC")
    check("MSG GB2312 字节级", f == b"MSG \xd3\xa6\xbc\xb1ABC\n", f.hex())

    # --- 板子解析/回执 ---
    fake = fpga_link.FakeSerial()
    fake.write(b"NEXT\n")
    check("NEXT -> OK\\r\\n", read_all(fake) == b"OK\r\n")
    fake.write(b"next\r\n")                            # 大小写不敏感 + 容忍 \r
    check("小写 next(+CR) -> OK", read_all(fake) == b"OK\r\n")
    fake.write(b"BOGUS\n")
    check("未知命令 -> ERR 不计数", read_all(fake) == b"ERR\r\n" and fake.cmd_count == 2)
    fake.write(b"MSG \xd3\xa6\xbc\xb1ABC\n")
    read_all(fake)
    check("MSG 中文回 OK 且板子解出文本", fake.last_text == "应急ABC" and fake.cmd_count == 3)

    # --- INFO? / STAT? 精确帧 + 不计数 ---
    fake = fpga_link.FakeSerial()
    for c in (b"SCAN7\n", b"AUTO\n", b"NEXT\n"):
        fake.write(c)
        read_all(fake)                                 # count=3 dbg: 扫描|自动|源完|帧完|屏|img1
    fake.write(b"INFO?\n")
    info = read_all(fake)
    check("INFO? 17字节帧", info == b"V2 003 11111001\r\n", repr(info))
    fake.write(b"INFO?\n"); fake.write(b"STAT?\n")
    s = read_all(fake)
    check("查询不加计数", b"V2 003 11111001\r\nV2 03 F9\r\n" == s, repr(s))
    check("COL/SPD/T 合法性",
          (_simple(b"COL 7\n") and _simple(b"SPD 9\n") and _simple(b"T 6 9\n")
           and not _simple(b"COL 8\n") and not _simple(b"T 7 9\n") and not _simple(b"SPD 0\n")))
    check("VOL 0-9 合法, A 非法", _simple(b"VOL 0\n") and _simple(b"VOL 9\n") and not _simple(b"VOL A\n"))
    check("EMG1/2/3 + CLR", _simple(b"EMG1\n") and _simple(b"EMG 2\n") and _simple(b"CLR\n"))

    # --- v10.3 画面工坊七条（BR/GN/FD/CK/VU/SR/SC）：字节级 + 落库 ---
    fake = fpga_link.FakeSerial()
    for c in (b"BR 7\n", b"GN 2\n", b"FD 3\n", b"CK 1\n", b"VU 1\n", b"SR 4\n", b"SC 1\n"):
        fake.write(c)
        read_all(fake)
    check("v10.3 七条全合法 -> OK 且落库+计数",
          fake.br == 7 and fake.gn == 2 and fake.fd == 3 and fake.ck == 1
          and fake.vu == 1 and fake.sr == 4 and fake.sc == 1 and fake.cmd_count == 7,
          "br=%d gn=%d fd=%d ck=%d vu=%d sr=%d sc=%d cnt=%d" % (fake.br, fake.gn, fake.fd,
                                                           fake.ck, fake.vu, fake.sr, fake.sc, fake.cmd_count))
    f0 = fpga_link.FakeSerial()
    check("v10.3 上电默认 BR=5 GN=5 FD=0 CK=0 VU=0 SR=0 SC=0（与板子 msg_ink 复位值一致）",
          f0.br == 5 and f0.gn == 5 and f0.fd == 0 and f0.ck == 0
          and f0.vu == 0 and f0.sr == 0 and f0.sc == 0)
    check("BR/GN 端点 0/9 合法",
          _simple(b"BR 0\n") and _simple(b"BR 9\n") and _simple(b"GN 0\n") and _simple(b"GN 9\n"))
    check("FD 0..3 全合法", all(_simple(b"FD %d\n" % i) for i in range(4)))
    check("CK/VU/SC 0/1 合法",
          _simple(b"CK 0\n") and _simple(b"CK 1\n") and _simple(b"VU 0\n") and _simple(b"VU 1\n")
          and _simple(b"SC 0\n") and _simple(b"SC 1\n"))
    check("SR 0..4 全合法", all(_simple(b"SR %d\n" % i) for i in range(5)))
    check("v10.3 非法值板子全 ERR：BR 10 / GN A / FD 4 / CK 2 / VU 2 / SR 9 / SC 2",
          not any(_simple(x) for x in (b"BR 10\n", b"GN A\n", b"FD 4\n", b"CK 2\n",
                                       b"VU 2\n", b"SR 9\n", b"SC 2\n")))
    fake = fpga_link.FakeSerial()
    fake.write(b"br 5\r\n")                            # 板子大小写不敏感 + 容忍 CR
    fake.write(b"BR 10\n")                             # 非法：ERR 且不计数
    acks = read_all(fake)
    check("v10.3 小写 br 5 -> OK；BR 10 -> ERR 不计数",
          acks == b"OK\r\nERR\r\n" and fake.cmd_count == 1 and fake.br == 5)

    # --- PLY 解码规则（v9.1 十进制/十六进制双路）---
    for line, want in [(b"PLY 3\n", 0x07), (b"PLY 7\n", 0x7F), (b"PLY 07\n", 0x07),
                       (b"PLY 44\n", 0x2C), (b"PLY 7F\n", 0x7F), (b"PLY 0f\n", 0x0F),
                       (b"PLYALL\n", 0x7F)]:
        fake = fpga_link.FakeSerial()
        fake.write(line)
        ack = read_all(fake)
        check("板子 %r -> 掩码0x%02X" % (line, want),
              ack == b"OK\r\n" and fake.ply_mask == want, "got %r mask=0x%02X" % (ack, fake.ply_mask))
    for bad in (b"PLY 0\n", b"PLY 00\n", b"PLY GG\n", b"PLY 7G\n", b"PLY 123\n"):
        fake = fpga_link.FakeSerial()
        fake.write(bad)
        check("板子 %r -> ERR" % bad, read_all(fake) == b"ERR\r\n")

    # --- UI 侧掩码 -> 线上字符串（3张=07 / 7张=7F 是需求里的验收例子）---
    check("ply_token 前3张 -> 'PLY 07'", "PLY " + fpga_link.ply_token(0b0000111) == "PLY 07")
    check("ply_token 全7张 -> 'PLY 7F'", "PLY " + fpga_link.ply_token(0b1111111) == "PLY 7F")
    check("ply_token 掩码10 -> '10'(十进制)", fpga_link.ply_token(10) == "10")
    check("ply_token 掩码35 -> '35'(十进制)", fpga_link.ply_token(35) == "35")
    for m in (100, 105, 112, 121):
        try:
            fpga_link.ply_token(m)
            bad = True
        except ValueError:
            bad = False
        check("ply_token 歧义区 %d 明确报错" % m, not bad)

    # --- 22 格宽度算法（中英混排）---
    check("cells 中英混排=逐字计数", fpga_link.cells("应急ABC。123") == 9)
    n, err = fpga_link.validate_msg_text("应急ABC。123")
    check("9 格合法", n == 9 and err is None)
    n, err = fpga_link.validate_msg_text("中" * 22)
    check("22 格正好合法", err is None and n == 22)
    n, err = fpga_link.validate_msg_text("中" * 23)
    check("23 格被拒", err is not None and "22" in err)
    n, err = fpga_link.validate_msg_text("😀哈哈")
    check("emoji(不在GB2312)被拒", err is not None and "字库" in err)
    n, err = fpga_link.validate_msg_text("ALL CLEAR 1730")
    check("纯英文标点合法", err is None and n == 14)
    n, err = fpga_link.validate_msg_text("   ")
    check("全空格被拒", err is not None)

    # --- SerialLink 队列 + 乱序/空行鲁棒性 ---
    fake = fpga_link.FakeSerial()
    link = fpga_link.SerialLink(fake, mock=True)
    link.start()
    r = link.submit("NEXT")
    check("SerialLink submit NEXT -> OK", r["ok"] and r["resp"] == "OK")
    fake.inject_tx(b"\r\n\r\n\n")                      # 多余空行
    r = link.submit("CLR")
    check("空行夹缝里 CLR 照常", r["ok"] and r["resp"] == "OK")
    fake.inject_tx(b"V2 099 10110011\r\n")              # 乱序：先冒出一条 V2
    r = link.submit("SCAN7")
    check("V2 抢跑不打断命令回执", r["ok"] and r["resp"] == "OK")
    time.sleep(0.1)
    check("乱序 V2 被记录为状态原文", link.last_v2.startswith("V2"))
    fake.inject_tx(b"OK\r\n")                          # 乱序：没人认领的 OK
    r = link.submit("VOL 3")
    check("野生的 OK 不会把下条命令带错", r["ok"] and fake.vol == 3)
    r = link.submit("INFO?")
    check("查询走 V2 回执", r["ok"] and r["resp"].startswith("V2 ") and
          fpga_link.parse_v2(r["resp"])["dbg"] is not None)
    r = link.submit("BOGUS")
    check("ERR 回执 ok=False", (not r["ok"]) and r["resp"] == "ERR")
    link.stop()
    p = fpga_link.parse_v2("V2 003 11111001")
    check("parse_v2 info", p and p["count"] == 3 and p["scan_ok"] and p["auto_play"] and
          p["img"] == 1 and p["load_busy"] is False)
    q = fpga_link.parse_v2("V2 0F F3")
    check("parse_v2 stat(十六进制)", q and q["count"] == 15 and q["dbg"] == 0xF3)
    check("parse_v2 垃圾返回 None", fpga_link.parse_v2("V2 xyz") is None)


def _simple(line):
    fake = fpga_link.FakeSerial()
    fake.write(line)
    return read_all(fake) == b"OK\r\n"


# ===========================================================================
# B/C/D. 起真服务（--mock）走 HTTP 端到端
# ===========================================================================

def _free_port():
    for p in range(8791, 8900):
        s = socket.socket()
        try:
            s.bind(("127.0.0.1", p))
            return p
        except OSError:
            continue
        finally:
            s.close()
    raise RuntimeError("找不到空闲端口")


class Http:
    def __init__(self, port):
        self.base = "http://127.0.0.1:%d" % port

    def api(self, action, **kw):
        data = json.dumps(dict(action=action, **kw)).encode("utf-8")
        req = urllib.request.Request(self.base + "/api", data=data,
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read().decode("utf-8"))

    def get(self, path):
        try:
            r = urllib.request.urlopen(self.base + path, timeout=15)
            with r:
                return r.status, dict(r.headers.items()), r.read()
        except HTTPError as e:                 # 400/404 也是合法应答，测试要能读码
            return e.code, dict(e.headers.items()), e.read()


def test_e2e():
    print("[B] HTTP 端到端（console.py --mock）")
    port = _free_port()
    proc = subprocess.Popen(
        [sys.executable, os.path.join(HERE, "console.py"), "--mock",
         "--no-browser", "--http-port", str(port)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        creationflags=0x08000000)                      # CREATE_NO_WINDOW
    http = Http(port)
    deadline = time.time() + 15
    while time.time() < deadline:                      # 等服务起来
        try:
            http.api("hello")
            break
        except (URLError, ConnectionError, OSError):
            time.sleep(0.15)
    else:
        proc.kill()
        raise AssertionError("console.py --mock 15 秒没起来")

    try:
        h = http.api("hello")
        check("GET /api hello ok+mock", h["ok"] and h["mock"] is True)
        check("hello 报告 ffmpeg 探测结果", "ffmpeg" in h)

        code, hdr, body = http.get("/")
        html = body.decode("utf-8")
        check("GET / 返回 200 HTML", code == 200 and "text/html" in hdr.get("Content-Type", ""))
        check("<title> 正确", "<title>FPGA 播控终端 · 图形控制页</title>" in html)
        check("页面无外部资源引用", "http://" not in html.replace("http://127.0.0.1", "")
              and "<script src" not in html and "@import" not in html
              and 'href="http' not in html)

        r = http.api("reset_board")                    # 假板子清零 -> 命令序列可精确断言
        check("reset_board（仅mock）", r["ok"])

        seq = [
            ("cmd", dict(cmd="NEXT")), ("cmd", dict(cmd="AUTO")),
            ("msg", dict(text="应急广播ABC。123", col=1)),
            ("ply", dict(mask=0b0000111)), ("ply", dict(mask=0b1111111)),
            ("cmd", dict(cmd="SPD 3")), ("cmd", dict(cmd="T 2 5")),
            ("cmd", dict(cmd="SCAN7")), ("cmd", dict(cmd="VOL 8")),
            ("cmd", dict(cmd="EMG2")), ("cmd", dict(cmd="CLR")),
            ("cmd", dict(cmd="PLYALL")), ("cmd", dict(cmd="SCAN4")),
            ("raw", dict(line="next")),                # 小写原样上线，板子认
            ("raw", dict(line="BOGUS")),               # 期望 ERR
        ]
        results = []
        for action, kw in seq:
            results.append((action, http.api(action, **kw)))
        check("快捷/广播/PLY 全成功", all(r["ok"] for a, r in results if a != "raw"
                                    or r.get("cmd") == "next"))
        bogus = [r for a, r in results if a == "raw" and r.get("cmd") == "BOGUS"][0]
        check("BOGUS -> ERR 且 ok=False", bogus["ok"] is False and bogus["resp"] == "ERR")
        badcmd = http.api("cmd", cmd="RM -RF /")
        check("白名单外的 cmd 被 UI 侧拦截", not badcmd["ok"])

        st = http.api("stat_raw")
        check("stat_raw 返回 V2 原文", st["ok"] and st["resp"].startswith("V2 "))
        poll = http.api("poll", since=0)
        s = poll["status"]
        check("poll 连接+状态", poll["ok"] and poll["connected"])
        check("命令计数 15（ERR不计数/查询不计数）", s["count"] == 15, str(s))
        # 两位 NEXT（按钮+小写raw）-> 图号2；SCAN4 最后把扫描/屏有效拉回 1
        check("状态位 11111010", s["bits"] == "11111010" and s["img"] == 2 and
              s["scan_ok"] and s["auto_play"] and s["frame_done"], str(s))
        check("poll 捎带回执日志", len(poll["log"]) > 20)

        rx = http.api("rx")
        got = [l["hex"] for l in rx["lines"]]
        # MSG 那条按 GB2312：应=D3A6 急=BCB1 广=B9E3 播=B2A5 。=A1A3
        msg_hex = (b"MSG " + "应急广播ABC。123".encode("gb2312")).hex()
        want = ["4e455854", "4155544f", "434f4c2031", msg_hex,
                "504c59203037", "504c59203746", "5350442033", "5420322035",
                "5343414e37", "564f4c2038", "454d4732", "434c52",
                "504c59414c4c", "5343414e34", "6e657874", "424f475553", "535441543f"]
        # stat_raw 的 STAT? 与 poll 的 INFO? 也在序列尾部
        want += ["494e464f3f"]
        check("FakeSerial 收到的字节序列与参数完全一致", got == want,
              "\n   got  %s\n   want %s" % (got, want))
        board = rx["board"]
        check("板子落库：PLY 7F 掩码", board["ply_mask"] == 0x7F)
        check("板子落库：VOL=8 COL=1 文本", board["vol"] == 8 and board["col"] == 1
              and board["text"] == "应急广播ABC。123")
        check("INFO?/STAT? 未计入计数", board["count"] == 15)

        # ---- v10 命令同步回归（放在所有"精确计数/字节序列"断言之后，免得扰动基线）----
        #      确保无板模拟下 SCAN32/VID/WHY? 也走得通，且 WHY? 不再误报超时。
        s32 = http.api("cmd", cmd="SCAN32")
        check("SCAN32 -> OK", s32["ok"] and s32["resp"] == "OK")
        v8 = http.api("cmd", cmd="VID 8")
        check("VID 8 -> OK", v8["ok"] and v8["resp"] == "OK")
        v0 = http.api("cmd", cmd="VID 0")
        check("VID 0 -> OK", v0["ok"] and v0["resp"] == "OK")
        why = http.api("cmd", cmd="WHY?")
        check("WHY? 返回 W 行且 ok（不再是超时）",
              why["ok"] is True and (why.get("resp") or "").startswith("W"))
        vbad = http.api("cmd", cmd="VID 99")
        check("VID 99 越界被白名单拦截", not vbad["ok"])
        # ---- v10.2 命令同步回归：PREV / SCAN n / RNGab / LIST? ----
        pr = http.api("cmd", cmd="PREV")
        check("PREV -> OK", pr["ok"] and pr["resp"] == "OK")
        sn = http.api("cmd", cmd="SCAN12")
        check("SCAN12 -> OK（自定义张数走白名单）", sn["ok"] and sn["resp"] == "OK")
        s33 = http.api("cmd", cmd="SCAN33")
        check("SCAN33 越界被白名单拦截", not s33["ok"])
        rg = http.api("cmd", cmd="RNG58")
        check("RNG58 -> OK", rg["ok"] and rg["resp"] == "OK")
        rg0 = http.api("cmd", cmd="RNG0A")
        check("RNG0A 非法被白名单拦截", not rg0["ok"])
        li = http.api("cmd", cmd="LIST?")
        check("LIST? 返回 L 行且 ok（查询类前缀分派）",
              li["ok"] is True and (li.get("resp") or "").startswith("L "))
        # 假板子语义抽查：SCAN12 后 LIST? 的深度字段应为 0x12；PREV 图号回绕合法
        _lp = (li.get("resp") or "").split()
        check("LIST? 深度字段回显 SCAN12 之 12",
              len(_lp) == 4 and int(_lp[3], 16) == 12)
        pr2 = http.api("cmd", cmd="PREV")   # img_idx 从当前再退一格：只要求仍 OK（回绕合法）
        check("PREV 连按合法（环上回绕不报错）", pr2["ok"])
        hello2 = http.api("hello")
        check("hello 带 out_dir（导入引导用）", bool(hello2.get("out_dir")))
        of = http.api("open_folder")
        check("open_folder mock 不弹窗仍返回路径", of["ok"] and of.get("mock") and of.get("path"))
        ccx = http.api("copy_card", names=["BMP0000.BMP"])
        check("copy_card 模拟保险丝：绝不碰真实卡",
              ccx["ok"] is False and ccx.get("dry_run") is True)
        ocx = http.api("open_card")
        check("open_card mock 不弹窗且分支合法",
              (ocx["ok"] and str(ocx.get("path", "")).endswith(":\\") and ocx.get("mock"))
              or (not ocx["ok"] and "卡" in (ocx.get("error") or "")))

        # ---- v10.3 画面工坊回归：BR/GN/FD/CK/VU/SR/SC 端到端 ----
        #      （放在所有"精确计数/字节序列"断言之后，不扰动 v10.2 基线）
        fx = [http.api("cmd", cmd=c) for c in ("BR 8", "GN 3", "FD 2", "CK 1", "VU 1", "SR 4", "SC 1")]
        check("v10.3 七条走白名单 -> 板子回 OK",
              all(r["ok"] and r["resp"] == "OK" for r in fx), str(fx))
        fx_bad = [http.api("cmd", cmd=c) for c in ("BR 10", "GN 10", "FD 4", "CK 2", "VU 2", "SR 9", "SC 2")]
        check("v10.3 非法值 BR 10/GN 10/FD 4/CK 2/VU 2/SR 9/SC 2 全被白名单拦截",
              not any(r["ok"] for r in fx_bad), str(fx_bad))
        brr = http.api("raw", line="BR 10")             # 绕开白名单直达板子：应 ERR 且不改状态
        check("raw 发 BR 10 -> 板子回 ERR", brr["ok"] is False and brr["resp"] == "ERR")
        rb = http.api("rx")["board"]
        check("v10.3 板子落库经 /api rx 可见（br/gn/fd/ck/vu/sr/sc）",
              rb["br"] == 8 and rb["gn"] == 3 and rb["fd"] == 2 and rb["ck"] == 1
              and rb["vu"] == 1 and rb["sr"] == 4 and rb["sc"] == 1, str(rb))

        # ---- C. 资源墙 + 缩略图（现造 3 张 640x480 测试图） ----
        print("[C] 资源墙缩略图")
        tmpdir = os.path.join(HERE, "_selftest_tmp")
        os.makedirs(tmpdir, exist_ok=True)
        out = None
        from PIL import Image
        thumb_snapshot = set(os.listdir(assets.THUMB_DIR)) if os.path.isdir(assets.THUMB_DIR) else set()
        try:
            for i in range(3):
                im = Image.new("RGB", (640, 480), (i * 70, 200 - i * 60, 90 + i * 40))
                im.save(os.path.join(tmpdir, "BMP%04d.BMP" % i), "BMP")
            r = http.api("setdir", path=tmpdir)
            check("setdir 指到临时目录", r["ok"])
            w = http.api("assets")
            check("资源墙发现 3 张", w["ok"] and len(w["items"]) == 3)
            check("板卡可播判据(640x480 24bit)", all(it["playable"] for it in w["items"]))
            check("板上编号 0,1,2", [it["board_index"] for it in w["items"]] == [0, 1, 2])
            for it in w["items"]:
                code, hdr, body = http.get(it["thumb"])
                okj = False
                try:
                    import io
                    im2 = Image.open(io.BytesIO(body))
                    okj = (code == 200 and im2.size[0] <= 160 and im2.size[1] <= 160)
                except Exception:
                    pass
                check("缩略图 %s 160px 可打开" % it["name"], okj)
            code, _, _ = http.get("/thumb/..%2F..%2Fconsole.py")
            check("/thumb 目录穿越被拒(400)", code == 400)

            # ---- D. 导入工坊（图片转换 + 视频 ffmpeg 降级） ----
            print("[D] 导入工坊")
            # hermetic v10.1: 先记账目录里的存量（含上次半途中断留下的），只断言"净增量"，
            # 收尾把本轮产物全删——杜绝"目录里多一张测试图就永久红"的脆弱性。
            if not os.path.isdir(assets.LOCAL_BMP_OUT):
                os.makedirs(assets.LOCAL_BMP_OUT)
            pre_files = set(os.listdir(assets.LOCAL_BMP_OUT))
            src_png = os.path.join(tmpdir, "photo_src.png")
            Image.new("RGB", (128, 96), (255, 0, 128)).save(src_png)
            fake_mp4 = os.path.join(tmpdir, "clip.mp4")
            with open(fake_mp4, "wb") as fp:
                fp.write(b"\x00\x00\x00\x18ftypmp42junkjunk")
            imp = http.api("import", paths=[src_png, fake_mp4], fit="cover")
            check("图片转成 BMP 成功", len(imp.get("converted", [])) == 1, str(imp))
            out = None
            if imp.get("converted"):
                out = os.path.join(assets.LOCAL_BMP_OUT, imp["converted"][0])
                check("产物 640x480 板卡可播", os.path.isfile(out) and assets.bmp_is_playable(out))
            if assets.ffmpeg_path():
                check("有 ffmpeg 时坏视频给出错误说明", any("失败" in e["why"] for e in imp["errors"]))
            else:
                check("无 ffmpeg 时视频明确降级提示",
                      any("ffmpeg" in e["why"] for e in imp["errors"]), str(imp["errors"]))
            w2 = http.api("assets")
            check("导入后资源墙自动切到新目录且净增 1 张",
                  w2["ok"] and w2["root_kind"] == "custom" and
                  len(w2["items"]) == len(pre_files) + 1)
            r = http.api("copy_card", names=[])
            check("无卡时拷卡按钮逻辑给出提示而非崩溃",
                  r["ok"] is False and ("TF" in (r.get("error") or "") or "卡" in (r.get("error") or "")))
        finally:
            _out = locals().get("out")
            _imp = locals().get("imp") or {}
            for cn in ([_out] if _out else []) + (_imp.get("converted", []) if isinstance(_imp, dict) else []):
                try:
                    fp2 = os.path.join(assets.LOCAL_BMP_OUT, cn)
                    if os.path.isfile(fp2):
                        os.remove(fp2)
                except OSError:
                    pass
            for tn in (set(os.listdir(assets.THUMB_DIR)) - thumb_snapshot):
                try:
                    os.remove(os.path.join(assets.THUMB_DIR, tn))
                except OSError:
                    pass
            import shutil
            shutil.rmtree(tmpdir, ignore_errors=True)
            http.api("setdir", path="")                # 清掉自选目录
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            proc.kill()


def main():
    t0 = time.time()
    test_protocol()
    test_e2e()
    print("-" * 60)
    print("共 %d 项：PASS %d, FAIL %d   用时 %.1fs" % (PASS + FAILN, PASS, FAILN, time.time() - t0))
    if FAILN == 0:
        print("ALL PASS")
        return 0
    print("存在失败项，请检查上面的 FAIL")
    return 1


if __name__ == "__main__":
    sys.exit(main())
