# -*- coding: utf-8 -*-
"""console.py — FPGA 播控终端「图形化上位机」主程序（替代 XCOM 敲命令）

怎么启动（小白三步）：
  第1步  插好 USB-TTL 线、板子上电（如果用假演示模式，这步跳过）
  第2步  命令行输入：
         C:\\Users\\lwy\\miniconda3\\envs\\fpga_batch\\python.exe console.py
         （没有板子想先玩界面：后面加 --mock，用内置假板子，绝不碰串口）
  第3步  浏览器自动打开 http://127.0.0.1:8765 —— 没弹出来就手动输这个网址

常用参数：
  --mock           假板子演示/自测模式（不打开任何串口！）
  --port COM4      真实串口（默认 COM4）
  --no-browser     不自动弹浏览器
  --http-port 8765 改网页端口（8765 被占了再用）

本文件只干三件事：起 HTTP 服务、把网页动作翻译成串口命令、把回执记进日志。
协议细节在 fpga_link.py，素材细节在 assets.py。
"""
import argparse
import json
import os
import re
import socket
import sys
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import fpga_link                      # noqa: E402  协议层（含 FakeSerial）
import assets                         # noqa: E402  素材层

UI_DIR = os.path.join(HERE, "ui")

# 快捷按钮 -> 原文命令（白名单；大小写按板子习惯给大写）
LITERAL_CMDS = {"NEXT", "PREV", "AUTO", "CLR", "EMG1", "EMG2", "EMG3", "PLYALL",
                "SCAN4", "SCAN7", "SCAN32", "WHY?", "LIST?"}
# v10.2 追加：PREV 上一张、LIST? 候选名单查询
# 带参数的命令：正则校验后原样发送 —— 网页再怎么点都不会发出协议外的东西
PARAM_CMD_RE = [
    re.compile(r"^SPD [1-9]$"),
    re.compile(r"^VOL [0-9]$"),
    re.compile(r"^COL [0-7]$"),
    re.compile(r"^T [0-6] [1-9]$"),
    re.compile(r"^VID (0|[1-9]|[12][0-9]|3[0-2])$"),   # v10 动感画报 0..32
    re.compile(r"^SCAN(3[0-2]|[12][0-9]|[1-9])$"),      # v10.2 自定义扫描张数 1..32（无空格，同板子）
    re.compile(r"^RNG[1-9][1-9]$"),                     # v10.2 从第 a 张连播 b 张（a,b∈1..9）
    # v10.3 画面工坊六条（板端 RTL 已完成，网页端同步）
    re.compile(r"^BR [0-9]$"),                          # 亮度 0..9（5=标准）
    re.compile(r"^GN [0-9]$"),                          # 对比度/增强 0..9（5=标准）
    re.compile(r"^FD [0-3]$"),                          # 换图转场 0直切 1淡入 2左→右擦拭 3百叶窗
    re.compile(r"^CK [01]$"),                           # 右上角实时时钟开关
    re.compile(r"^VU [01]$"),                           # 底部音频频谱柱开关
    re.compile(r"^SR [0-4]$"),                          # 字幕滚动速度 0停 1..4 像素/帧
    re.compile(r"^SC [01]$"),                           # 扩展3 多分辨率缩放：0=直通 1=自动缩放到640×480
]


class App:
    """全局状态：串口链路 + 资源根目录覆盖 + 启动参数。"""

    def __init__(self, args):
        self.args = args
        self.mock = args.mock
        self.link = None
        self.custom_root = None        # 用户“选择文件夹”后覆盖资源墙目录
        self.lock = threading.Lock()

    def open_link(self):
        if self.mock:
            fake = fpga_link.FakeSerial()
            link = fpga_link.SerialLink(fake, port_name="FAKE", mock=True)
        else:
            try:
                ser = self._open_real()
                link = fpga_link.SerialLink(ser, port_name=self.args.port, mock=False)
            except Exception as e:
                # COM 口被占/不存在：服务照常起，页面灰掉＋重连按钮
                print("!! 打不开 %s：%s" % (self.args.port, e))
                print("!! 页面照常启动（先体验界面）；关掉占用者（XCOM?）后点页面右上『重连』")
                link = fpga_link.SerialLink(fpga_link.DeadSerial(),
                                            port_name=self.args.port + "(未打开)", mock=False)
                link.connected = False
        link.start()
        self.link = link
        return link

    def _open_real(self):
        # 真串口只在非 mock 时才 import pyserial —— 保证演示/自测零串口风险
        import serial
        return serial.Serial(self.args.port, 115200, timeout=0.05)

    def reconnect(self):
        old = self.link
        if old is not None:
            try:
                old.stop()
            except Exception:
                pass
        self.open_link()
        return self.link

    def asset_root(self):
        """当前资源墙用哪个目录 + 来源说明。"""
        with self.lock:
            if self.custom_root and os.path.isdir(self.custom_root):
                return self.custom_root, "custom"
        card = assets.detect_card()
        if card:
            return card["root"], "card"
        return assets.pick_default_root(None)


APP = None  # main() 里填充


# ---------------------------------------------------------------------------
# /api 动作分发 —— 全部返回 (HTTP码, dict)
# ---------------------------------------------------------------------------

def api_dispatch(body):
    action = body.get("action")
    link = APP.link

    if action == "hello":
        return 200, {"ok": True, "mock": APP.mock, "port": APP.args.port,
                     "ffmpeg": bool(assets.ffmpeg_path()),
                     "card": bool(assets.detect_card()),
                     "out_dir": assets.LOCAL_BMP_OUT,   # v10.2：导入产物目录（引导用）
                     "title": "FPGA 播控终端"}

    # ---- 状态轮询：发 INFO? 并把 8 个状态位翻译好 + 捎带回执日志增量 ----
    if action == "poll":
        since = int(body.get("since", 0))
        r = link.submit("INFO?", quiet=True)           # 2Hz 轮询不刷屏
        status = None
        if r["ok"] and (r.get("resp") or "").startswith("V2"):
            status = fpga_link.parse_v2(r["resp"])
        entries, seq = link.log_since(since)
        return 200, {"ok": True, "connected": bool(status) and link.connected,
                     "send_resp": r, "status": status, "last_v2": link.last_v2,
                     "log": entries, "log_seq": seq,
                     "cmd_timeout": link.last_v2_ts and (time.time() - link.last_v2_ts) > 3}

    if action == "cmd":                       # 快捷按钮
        cmd = str(body.get("cmd", "")).strip().upper()
        if cmd not in LITERAL_CMDS and not any(rx.match(cmd) for rx in PARAM_CMD_RE):
            return 200, {"ok": False, "error": "不在允许的命令白名单里：%r" % cmd}
        return 200, link.submit(cmd)

    # v10.2：打开电脑侧"转换输出目录"（固定路径、零参数，供导入后手动拷卡用）
    if action == "open_folder":
        d = assets.LOCAL_BMP_OUT
        os.makedirs(d, exist_ok=True)
        if not APP.mock:
            try:
                os.startfile(d)                       # type: ignore[attr-defined]
            except Exception as e:
                return 200, {"ok": False, "error": str(e), "path": d}
        return 200, {"ok": True, "path": d, "mock": APP.mock}

    # v10.2.1：打开检测到的 TF 卡目录（同样零参数：路径来自 detect_card，安全）
    if action == "open_card":
        card = assets.detect_card()
        if not card:
            return 200, {"ok": False, "error": "没检测到 TF 卡（插读卡器了吗？）"}
        if not APP.mock:
            try:
                os.startfile(card["root"])            # type: ignore[attr-defined]
            except Exception as e:
                return 200, {"ok": False, "error": str(e), "path": card["root"]}
        return 200, {"ok": True, "path": card["root"], "mock": APP.mock}

    # ---- 文字广播：先发 COL 再发 MSG，两条回执都给前端看 ----
    if action == "msg":
        text = str(body.get("text", ""))
        col = body.get("col", None)
        acks = []
        n, err = fpga_link.validate_msg_text(text)
        if err:
            return 200, {"ok": False, "error": err, "cells": n, "acks": acks}
        if col is not None:
            c = int(col)
            if not 0 <= c <= 7:
                return 200, {"ok": False, "error": "颜色编号要在 0~7", "acks": acks}
            r1 = link.submit("COL %d" % c)
            acks.append(r1)
            if not r1["ok"]:
                return 200, {"ok": False, "error": "改颜色就没成功，文字没发", "acks": acks}
        r2 = link.submit("MSG " + text)
        acks.append(r2)
        return 200, {"ok": bool(r2["ok"]), "cells": n, "acks": acks,
                     "error": None if r2["ok"] else r2.get("resp", "失败")}

    # ---- 资源墙：勾选出掩码 -> PLY ----
    if action == "ply":
        try:
            tok = fpga_link.ply_token(int(body.get("mask", 0)))
        except ValueError as e:
            return 200, {"ok": False, "error": str(e)}
        r = link.submit("PLY " + tok)
        r["token"] = tok
        return 200, r

    # ---- 极客抽屉：STAT? 原文 / 任意原文发送 ----
    if action == "stat_raw":
        r = link.submit("STAT?")
        return 200, r

    if action == "raw":
        line = str(body.get("line", "")).strip()
        if not line or "\n" in line or "\r" in line:
            return 200, {"ok": False, "error": "要发一行非空文本（别带换行）"}
        if len(line) > 60:
            return 200, {"ok": False, "error": "太长了（>60 字符），板子可能截/报错"}
        # “高级”抽屉：照样走命令队列（一次一条、等回执），但字节按 gbk 兜底原样编码
        try:
            frame = fpga_link.build_frame(line)
        except ValueError:
            frame = _raw_encode(line) + b"\n"
        return 200, link.submit(line, frame=frame)

    # ---- 资源墙列表 ----
    if action == "assets":
        root, kind = APP.asset_root()
        items = assets.list_assets(root)
        card = assets.detect_card()
        # 给图片类条目编号（板卡扫描按文件名顺序，第 i 张 -> 掩码 bit i）
        idx = 0
        for it in items:
            if it["kind"] == "image":
                it["board_index"] = idx
                idx += 1
            else:
                it["board_index"] = None
        return 200, {"ok": True, "root": root, "root_kind": kind, "items": items,
                     "card": card, "ffmpeg": bool(assets.ffmpeg_path())}

    if action == "setdir":
        p = str(body.get("path", "")).strip()
        if not p:                                  # 空串＝清除自选，回到自动发现
            with APP.lock:
                APP.custom_root = None
            return 200, {"ok": True, "root": None}
        p = os.path.normpath(p)
        if os.path.isdir(p):
            with APP.lock:
                APP.custom_root = p
            return 200, {"ok": True, "root": p}
        return 200, {"ok": False, "error": "文件夹不存在：%s" % p}

    if action == "pick":
        mode = body.get("mode", "files")
        got = assets.open_picker("dir" if mode == "dir" else "files")
        if mode == "dir" and got:
            with APP.lock:
                APP.custom_root = got[0]
        return 200, {"ok": bool(got), "paths": got}

    # ---- 导入工坊 ----
    if action == "import":
        paths = body.get("paths") or []
        fit = body.get("fit", "contain")
        if fit not in ("contain", "cover"):
            return 200, {"ok": False, "error": "fit 只能是 contain/cover"}
        if not paths:
            return 200, {"ok": False, "error": "没选文件"}
        res = assets.import_files(paths, fit)
        with APP.lock:
            APP.custom_root = assets.LOCAL_BMP_OUT   # 转完立刻在资源墙看到成果
        return 200, {"ok": bool(res["converted"]), "bmp_out": assets.LOCAL_BMP_OUT, **res}

    if action == "copy_card":
        if APP.mock:
            # 保险丝：自测/模拟模式永远不许碰真实读卡器里的卡
            return 200, {"ok": False, "dry_run": True,
                         "error": "模拟模式不碰真实卡（TF 卡保险丝）"}
        card = assets.detect_card()
        if not card:
            return 200, {"ok": False, "error": "没检测到 TF 卡（插读卡器；注意卡在板上时 PC 读不到）"}
        # v10.2.1 修复"自己拷自己"死结：资源墙显示卡时，源自动切到电脑转换输出区
        root, kind = APP.asset_root()
        src = root
        if kind == "card":
            src = assets.LOCAL_BMP_OUT
        names = body.get("names") or [it["name"] for it in assets.list_assets(src)
                                      if it["name"].lower().endswith(".bmp")]
        if not names:
            return 200, {"ok": False, "error": "电脑输出目录里没有 BMP 可拷（先在导入工坊转几张）"}
        res = assets.copy_to_card(src, names, card["root"])
        return 200, {"ok": bool(res["copied"]), "card_root": card["root"],
                     "src": src, **res}

    if action == "reconnect":
        if APP.mock:
            return 200, {"ok": True, "resp": "模拟模式，本来就连着"}
        try:
            APP.reconnect()
            return 200, {"ok": True, "resp": "重连成功 %s" % APP.args.port}
        except Exception as e:
            return 200, {"ok": False, "error": "重连失败：%s（COM 口还被别的软件占着？先关 XCOM）" % e}

    # ---- 仅模拟模式：把假板子收到的原始行回给 selftest 做字节级断言 ----
    if action == "rx":
        if not APP.mock:
            return 200, {"ok": False, "error": "只有 --mock 模式有这个"}
        lines = [{"hex": l.hex(), "gbk": l.replace(b"\r", b"").decode("gbk", "replace")}
                 for l in link.ser.rx_lines]
        return 200, {"ok": True, "lines": lines,
                     "board": {"count": link.ser.cmd_count, "dbg": link.ser.dbg,
                               "ply_mask": link.ser.ply_mask, "vol": link.ser.vol,
                               "col": link.ser.txt_col, "text": link.ser.last_text,
                               "br": link.ser.br, "gn": link.ser.gn, "fd": link.ser.fd,   # v10.3
                               "ck": link.ser.ck, "vu": link.ser.vu, "sr": link.ser.sr,
                               "sc": link.ser.sc}}                     # v10.3 扩展3 缩放开关

    if action == "reset_board":            # 仅模拟：清零假板子（selftest 序列用）
        if not APP.mock:
            return 200, {"ok": False, "error": "只有 --mock 模式有这个"}
        link.ser = link_ser = fpga_link.FakeSerial()
        link._cur = None
        return 200, {"ok": True}

    return 404, {"ok": False, "error": "未知 action: %r" % action}


def _raw_encode(line):
    for enc in ("gb2312", "gbk"):
        try:
            return line.encode(enc)
        except UnicodeEncodeError:
            continue
    return line.encode("gbk", "replace")


# ---------------------------------------------------------------------------
# HTTP 层
# ---------------------------------------------------------------------------

MIME = {".html": "text/html; charset=utf-8", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".png": "image/png", ".css": "text/css; charset=utf-8",
        ".js": "text/javascript; charset=utf-8", ".svg": "image/svg+xml"}


class Handler(BaseHTTPRequestHandler):
    server_version = "FpgaConsole/1.0"

    def log_message(self, fmt, *args):     # 别刷屏，自测输出才看得清
        pass

    def _send(self, code, ctype, data):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _send_json(self, code, obj):
        self._send(code, "application/json; charset=utf-8",
                   json.dumps(obj, ensure_ascii=False).encode("utf-8"))

    # ---- GET：页面、静态、缩略图 ----
    def do_GET(self):
        path = unquote(self.path.split("?", 1)[0])
        if path in ("/", "/index.html"):
            try:
                with open(os.path.join(UI_DIR, "index.html"), "rb") as f:
                    self._send(200, MIME[".html"], f.read())
            except OSError:
                self._send(500, "text/plain; charset=utf-8", "ui/index.html 丢了".encode("gbk"))
            return
        if path.startswith("/thumb/"):
            name = os.path.basename(path[len("/thumb/"):])       # basename 杀目录穿越
            if not re.fullmatch(r"[0-9a-f]{16}\.(jpg|png)", name):
                self._send(400, "text/plain", b"bad thumb name")
                return
            fp = os.path.join(assets.THUMB_DIR, name)
            if not os.path.isfile(fp):
                self._send(404, "text/plain", b"no thumb")
                return
            with open(fp, "rb") as f:
                self._send(200, MIME["." + name.rsplit(".", 1)[1]], f.read())
            return
        if path.startswith("/assets/"):
            name = os.path.basename(path[len("/assets/"):])
            fp = os.path.join(UI_DIR, "assets", name)
            if os.path.isfile(fp):
                with open(fp, "rb") as f:
                    self._send(200, MIME.get(os.path.splitext(name)[1].lower(),
                                             "application/octet-stream"), f.read())
                return
            self._send(404, "text/plain", b"not found")
            return
        if path == "/favicon.ico":
            self._send(204, "text/plain", b"")
            return
        self._send(404, "text/plain", b"not found")

    # ---- POST /api ----
    def do_POST(self):
        if self.path.split("?", 1)[0] != "/api":
            self._send(404, "text/plain", b"only /api")
            return
        try:
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
        except Exception as e:
            self._send_json(400, {"ok": False, "error": "JSON 没解析：%s" % e})
            return
        try:
            code, obj = api_dispatch(body)
        except Exception as e:                     # 任何一个动作崩了都不让网页见到 500
            code, obj = 200, {"ok": False, "error": "服务内部错误：%s" % e}
        self._send_json(code, obj)


# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

def main(argv=None):
    global APP
    ap = argparse.ArgumentParser(description="FPGA 播控终端图形上位机")
    ap.add_argument("--mock", action="store_true",
                    help="假板子演示模式：完全不碰串口（自测/无板体验用）")
    ap.add_argument("--port", default="COM4", help="真实串口（默认 COM4）")
    ap.add_argument("--http-port", type=int, default=8765, help="网页端口（默认 8765）")
    ap.add_argument("--no-browser", action="store_true", help="不自动打开浏览器")
    args = ap.parse_args(argv)

    os.makedirs(assets.THUMB_DIR, exist_ok=True)
    APP = App(args)
    APP.open_link()

    url = "http://127.0.0.1:%d" % args.http_port

    def _already_listening():
        # Windows 的 SO_REUSEADDR 允许第二个进程绑同端口（会抢流量），
        # 所以"是否已有实例"不能靠 bind 报错，必须主动探一次 TCP。
        import socket
        try:
            with socket.create_connection(("127.0.0.1", args.http_port), 0.3):
                return True
        except OSError:
            return False

    if _already_listening():
        # 已经有一个播控台在跑（比如你双击过 bat）。别再起第二个抢串口——
        # 直接帮你打开现有页面后退出。
        print("检测到播控台已在运行：%s" % url)
        print("（已为你打开页面；这个窗口可以直接关掉）")
        try:
            APP.link.stop()
        except Exception:
            pass
        webbrowser.open(url)
        return 0
    try:
        srv = ThreadingHTTPServer(("127.0.0.1", args.http_port), Handler)
    except OSError as e:
        print("!! 起不了网页服务：%s" % e)
        try:
            APP.link.stop()
        except Exception:
            pass
        return 1
    tip = "（假板子演示模式）" if args.mock else "（真板子 @ %s）" % args.port
    print("=" * 62)
    print("  FPGA 播控终端 · 图形控制页 %s" % tip)
    print("  地址：%s   （Ctrl+C 退出）" % url)
    print("=" * 62)
    if not args.no_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            APP.link.stop()
        except Exception:
            pass
        srv.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
