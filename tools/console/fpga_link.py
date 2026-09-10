# -*- coding: utf-8 -*-
"""fpga_link.py — FPGA 播控终端的串口协议层（上位机侧 + 假板子）

这是什么：
  把“跟板子说话”这件事单独关在一个文件里。分三层：
    1. build_frame()      —— 把一条命令字符串变成要发到串口线上的字节
                            （GBK/GB2312 编码 + 结尾 \\n，和板子 msg_ink.v 一致）
    2. FakeSerial         —— 一个纯软件的“假板子”：你给它发命令，它回 OK / ERR / V2。
                            永远不碰任何真实串口，专门给 selftest 和 --mock 模式用。
    3. SerialLink         —— “真板子/假板子”通用驱动：一个后台线程按顺序把命令
                            队列里的命令发出去（一次一条），等板子回执，1.2 秒超时。
                            串口对象是可注入的（构造时传进来），所以测试用 FakeSerial，
                            实机用 serial.Serial，代码一行都不用改。

怎么启动（一般不直接用这个文件，用 console.py）：
  python console.py --mock      # 用这里的 FakeSerial，无需板子
  python console.py             # 用这里的 SerialLink 包 serial.Serial("COM4")

重要约定（照 msg_ink.v v9.1 实现，别自创）：
  - 命令大小写不敏感；每条命令一行，以 \\n 结尾；回执逐行：OK / ERR / V2 ...
  - INFO? / STAT? 是“查询”，不加命令计数；其它成功命令让计数 +1（0..255 循环）。
  - PLY：一位数字 = 前几张(2^d-1)；两位纯数字 = 十进制掩码；含 A-F 字母 = 十六进制；
    最终掩码 & 0x7F，结果为 0 一律 ERR。
  - MSG 的中文按 GB2312 双字节传输，一个中文=1 个整格，英文/标点也占 1 格，共 22 格。
"""
import re
import threading
import queue
import time
from collections import deque

# 回执超时（秒）。板子 115200 波特率下一条回执几毫秒就到，1.2s 非常宽裕。
RESP_TIMEOUT = 1.2
# 查询类命令 → 期望应答前缀。板子对 INFO?/STAT? 回 V2…、对 WHY? 回 W…、对 LIST? 回 L…。
# 普通命令不在表里 → 等 OK/ERR。这是"回执分类"的唯一真源。
QUERY_RESP = {"INFO?": "V2", "STAT?": "V2", "WHY?": "W", "LIST?": "L"}


# ---------------------------------------------------------------------------
# 1) 命令编码 / 宽度计算（发之前在本机校验，省得板子回 ERR 用户还看不懂）
# ---------------------------------------------------------------------------

def cells(text):
    """数“整格”：中文算 1 格、英文/数字/标点各算 1 格。大屏一行 22 格。"""
    return len(text)


def msg_body_bytes(text):
    """把 MSG 的文本编成板子认识的字节的字节（GB2312）。编不下就抛 ValueError。"""
    try:
        return text.encode("gb2312")
    except UnicodeEncodeError:
        bad = [ch for ch in text if not _gb_ok(ch)]
        raise ValueError("这些字不在板子 GB2312 字库里：%s" % "".join(sorted(set(bad))))


def _gb_ok(ch):
    try:
        ch.encode("gb2312")
        return True
    except UnicodeEncodeError:
        return False


def validate_msg_text(text):
    """返回 (格子数, 错误说明或 None)。板子上限 22 整格 / 44 字节，超了会被截。"""
    if not text or not text.strip():
        return 0, "文字是空的，发上去大屏啥也不会显示"
    n = cells(text)
    if n > 22:
        return n, "超过 22 格了（现在 %d 格），大屏一行放不下" % n
    try:
        b = msg_body_bytes(text)
    except ValueError as e:
        return n, str(e)
    if len(b) > 44:
        return n, "字节数 %d 超过板子上限 44" % len(b)
    return n, None


def build_frame(cmd_text):
    """命令字符串 -> 串口线上的字节。例：'NEXT' -> b'NEXT\\n'，
    'MSG 应急ABC' -> b'MSG \\xd3\\xa6\\xbc\\xb1ABC\\n'。"""
    return msg_body_bytes(cmd_text) + b"\n"


# ---------------------------------------------------------------------------
# PLY 掩码 <-> 线上字符串（v9.1 十进制解码规则）
# ---------------------------------------------------------------------------

def ply_token(mask):
    """把 0..127 的勾选掩码变成 'PLY xx' 的 xx 部分。
    规则（和 msg_ink.v v9.1 一致）：两位纯数字=十进制；含 A-F=十六进制。
    掩码 <=99：直接两位十进制（'07'=第1,2,3张；'35'=第1,2,4,6张）。
    掩码 100..127：必须走十六进制字母形式（'7F'=全部7张）。
    100..105 / 112..121 的十六进制写法全是数字（如 64），板子会按十进制读，
    这几个组合协议上无法精确表达 —— 抛 ValueError，页面上会解释。"""
    if not isinstance(mask, int) or mask < 1 or mask > 0x7F:
        raise ValueError("掩码必须在 1..127（至少勾 1 张，最多 7 张全勾）")
    if mask <= 99:
        return "%02d" % mask
    tok = "%02X" % mask          # 100..127 走十六进制
    if re.fullmatch(r"[0-9A-F]{2}", tok) and re.fullmatch(r"\d{2}", tok):
        raise ValueError("掩码 %d 的十六进制写法(=%s)全是数字，板子会按十进制误读；"
                         "请调整勾选（100~105 与 112~121 这几个组合协议上发不了）" % (mask, tok))
    return tok


# ---------------------------------------------------------------------------
# 2) FakeSerial —— 纯软件的“假板子”，行为对齐 msg_ink.v v9.1
# ---------------------------------------------------------------------------

class FakeSerial:
    """假板子的串口接口（接口形状和 pyserial.Serial 一致）。

    - write(字节)  ：模拟板子收到线上字节，按 \\n 分行解析，回执排队。
    - read(n)      ：模拟 PC 从线上读回执（没数据返回空字节，不阻塞）。
    - rx_lines     ：本假板子收到过的“原始行字节”列表（不含 \\n），selftest 断言用。
    - inject_tx()  ：往“下行方向”（板子->PC）塞任意字节，用来测乱序/空行鲁棒性。

    状态位（dbg，8 位，对应 INFO? 里 8 个 0/1，从左到右）：
      bit7 扫描好  bit6 自动播  bit5 源传完  bit4 帧写完  bit3 屏有效  bit2 加载忙
      bit1:0 图号（协议只有 2 位，0..3 循环 —— 这是板子本身如此，不是模拟的锅）
    模拟规则（简单、确定性）：
      SCAN4/7 -> 扫描好=1、屏有效=1；AUTO -> 翻转自动播；
      NEXT -> 图号+1、源传完=1、帧写完=1；
      MSG/EMG 上屏 -> 屏有效=1；CLR -> 清应急、屏有效=0；
      加载忙恒 0（本模拟不支持 LOAD 字库加载流程）。
    """

    def __init__(self, port="FAKE"):
        self.port = port
        self.is_open = True
        self._inbuf = bytearray()          # PC 发给板子的、还没凑成整行的半截
        self._outbuf = bytearray()         # 板子攒着要发给 PC 的回执
        self.rx_lines = []                 # 板子视角：完整收到过的行（去掉 \n、保留原始字节）
        # --- 板子状态 ---
        self.cmd_count = 0                 # msgcnt：累计成功命令数 0..255
        self.dbg = 0x00                    # 8 位状态
        self.vol = 5
        self.spd = 2
        self.txt_col = 0
        self.emg_sel = 0
        self.last_text = ""                # 大屏当前第 2 行内容（解码后）
        self.ply_mask = 0x7F
        self.scan_depth = 4
        self.vid_n = 0                    # v10 动感画报最近一次设定帧数
        # ---- v10.2 深扫 32 帧语义：img_idx 是板内 5bit 真图号（0..31），
        #      dbg[1:0] 只是它的低两位投影（协议位布局所限，向后兼容）。
        self.img_idx = 0                  # 真实游标，PREV/NEXT 在此环 0..found-1 上走
        self.found = 4                    # 已登记张数（默认按 4 张卡）
        self.rng_mask = None              # RNGab 设置的 32bit 区间掩码（None=未用）
        # ---- v10.3 画面工坊状态（不进 INFO? 状态位，只落库供 /api rx 断言）----
        self.br = 5                       # 亮度 0..9（5=标准）
        self.gn = 5                       # 对比度/增强 0..9（5=标准）
        self.fd = 0                       # 换图转场 0直切 1淡入 2左→右擦拭 3百叶窗
        self.ck = 0                       # 右上角实时时钟开关 0/1
        self.vu = 0                       # 底部音频频谱柱开关 0/1
        self.sr = 0                       # 字幕滚动速度 0停 1..4 像素/帧（=板子复位默认，勿改）
        self.sc = 0                       # 扩展3 缩放开关 0直通/1自动缩放（=板子复位默认，勿改）

    # ---- 模拟 pyserial 的最小接口 ----
    def in_waiting(self):
        return len(self._outbuf)

    def read(self, n=1):
        chunk = bytes(self._outbuf[:n])
        del self._outbuf[:len(chunk)]
        return chunk

    def write(self, data):
        if not self.is_open:
            raise OSError("FAKE port closed")
        self._inbuf += data
        while b"\n" in self._inbuf:
            line, rest = self._inbuf.split(b"\n", 1)
            self._inbuf = bytearray(rest)
            self._rx_line(line)
        return len(data)

    def flush(self):
        pass

    def reset_input_buffer(self):
        self._outbuf.clear()

    def reset_output_buffer(self):
        self._inbuf.clear()

    def close(self):
        self.is_open = False

    def inject_tx(self, raw: bytes):
        """测试用：往 PC 的接收方向塞任意字节（模拟乱序/多余空行等）。"""
        self._outbuf += raw

    # ---- 板子逻辑：解析一行、生成回执 ----
    def _ack(self, kind):
        self._outbuf += {
            "OK": b"OK\r\n",
            "ERR": b"ERR\r\n",
        }[kind]

    def _dbg_set(self, bit, val=1):
        if val:
            self.dbg |= (1 << bit)
        else:
            self.dbg &= ~(1 << bit)

    def _img(self):
        return self.dbg & 0x03

    def _rx_line(self, raw):
        self.rx_lines.append(raw)
        # 板子收行时会吃掉 \r，并把 ASCII 字母变大写影子（>=0xA1 的 GB2312 字节原样）
        body = raw.replace(b"\r", b"")
        u = bytes((b - 32) if 0x61 <= b <= 0x7A else b for b in body)   # 大写影子
        s = u.decode("latin-1")
        ln = len(u)

        def ok(count=True):
            if count:
                self.cmd_count = (self.cmd_count + 1) & 0xFF
            self._ack("OK")

        if ln >= 4 and s.startswith("MSG ") and s[3] == " ":
            pay = body[4:4 + 44]                       # 板子按 44 字节截
            self.last_text = pay.decode("gbk", "replace")
            ok()
        elif s.startswith("EMG"):
            sel = 0
            if ln >= 4 and "1" <= s[3] <= "3":
                sel = int(s[3])
            self.emg_sel = sel
            self._dbg_set(3)                           # 应急横幅上屏 -> 屏有效
            ok()
        elif s.startswith("CLR"):
            self.emg_sel = 0
            self._dbg_set(3, 0)                        # 清屏回常态
            ok()
        elif ln >= 5 and s[0:3] == "VOL" and s[3] == " " and "0" <= s[4] <= "9":
            self.vol = int(s[4])                       # VOL 分支不看长度，多余尾巴被忽略（板子如此）
            ok()
        elif ln == 5 and s[0:3] == "COL" and s[3] == " " and "0" <= s[4] <= "7":
            self.txt_col = int(s[4])
            ok()
        elif s.startswith("NEXT"):
            # v10.2：真图号游标在 0..found-1 环上前进一格，dbg 低两位只是投影
            self.img_idx = (self.img_idx + 1) % max(self.found, 1)
            self.dbg = (self.dbg & ~0x03) | (self.img_idx & 0x03)
            self._dbg_set(5)
            self._dbg_set(4)
            ok()
        elif s.startswith("PREV"):                     # v10.2 上一张：环上退一格
            self.img_idx = (self.img_idx - 1) % max(self.found, 1)
            self.dbg = (self.dbg & ~0x03) | (self.img_idx & 0x03)
            self._dbg_set(5)
            self._dbg_set(4)
            ok()
        elif s.startswith("AUTO"):
            self.dbg ^= (1 << 6)                       # 翻转自动播
            ok()
        elif ln == 5 and s[0:3] == "SPD" and s[3] == " " and "1" <= s[4] <= "9":
            self.spd = int(s[4])
            ok()
        elif ln == 4 and s[0:2] == "BR" and s[2] == " " and "0" <= s[3] <= "9":
            self.br = int(s[3])                      # v10.3 亮度（非法值落到末尾 else -> ERR）
            ok()
        elif ln == 4 and s[0:2] == "GN" and s[2] == " " and "0" <= s[3] <= "9":
            self.gn = int(s[3])                      # v10.3 对比度/增强
            ok()
        elif ln == 4 and s[0:2] == "FD" and s[2] == " " and "0" <= s[3] <= "3":
            self.fd = int(s[3])                      # v10.3 换图转场
            ok()
        elif ln == 4 and s[0:2] == "CK" and s[2] == " " and "0" <= s[3] <= "1":
            self.ck = int(s[3])                      # v10.3 实时时钟开关
            ok()
        elif ln == 4 and s[0:2] == "VU" and s[2] == " " and "0" <= s[3] <= "1":
            self.vu = int(s[3])                      # v10.3 音频频谱开关
            ok()
        elif ln == 4 and s[0:2] == "SR" and s[2] == " " and "0" <= s[3] <= "4":
            self.sr = int(s[3])                      # v10.3 字幕滚动速度
            ok()
        elif ln == 4 and s[0:2] == "SC" and s[2] == " " and "0" <= s[3] <= "1":
            self.sc = int(s[3])                      # v10.3 扩展3 缩放开关
            ok()
        elif ln == 5 and s[0] == "T" and s[1] == " " and "0" <= s[2] <= "6" \
                and s[3] == " " and "1" <= s[4] <= "9":
            ok()
        elif s.startswith("SCAN") and s[4:].isdigit() and 1 <= int(s[4:]) <= 32:
            # v10.2：SCAN4/7/32 旧臂与 SCAN1..31 新臂统一入口（板子同款语义）
            self.scan_depth = int(s[4:])
            self._dbg_set(7)                           # 扫描好
            self._dbg_set(3)                           # 屏有效
            ok()
        elif ln == 5 and s.startswith("RNG") and "1" <= s[3] <= "9" and "1" <= s[4] <= "9":
            # v10.2 RNGab：从第 a 张连播 b 张 -> 32bit 区间掩码；同拍退出 VID
            a, b = int(s[3]), int(s[4])
            self.rng_mask = (((1 << b) - 1) << (a - 1)) & 0xFFFFFFFF
            self.vid_n = 0
            ok()
        elif ln >= 5 and s.startswith("VID ") and s[4:].isdigit() and 0 <= int(s[4:]) <= 32:
            self.vid_n = int(s[4:])                    # v10 动感画报：记住帧数，模拟连播出图
            if self.vid_n > 0:
                self._dbg_set(7); self._dbg_set(3)
            ok()
        elif ln == 4 and s == "WHY?":                  # v10 黑匣子查询：回 W 行，不计数
            self._outbuf += ("W %02X %02X %02X %03d\r\n"
                             % (0, 0, 0, 0)).encode("ascii")
        elif ln == 5 and s == "LIST?":                 # v10.2 名单查询：L <张数> <当前> <深度>
            self._outbuf += ("L %02X %02X %02X\r\n" % (self.found, self.img_idx,
                                                       self.scan_depth)).encode("ascii")
        elif ln == 5 and s.startswith("PLY ") and "1" <= s[4] <= "9":
            self.ply_mask = ((1 << int(s[4])) - 1) & 0x7F   # PLY 3 -> 前3张 -> 0x07
            ok()
        elif s == "INFO?" and ln == 5:
            bits = format(self.dbg, "08b")
            self._outbuf += ("V2 %03d %s\r\n" % (self.cmd_count, bits)).encode("ascii")
        elif s.startswith("STAT?"):
            self._outbuf += ("V2 %02X %02X\r\n" % (self.cmd_count, self.dbg)).encode("ascii")
        elif ln == 6 and s == "PLYALL":
            self.ply_mask = 0x7F
            ok()
        elif ln == 6 and s.startswith("PLY "):
            t = s[4:6]
            mask = None
            if re.fullmatch(r"\d{2}", t):
                val = int(t, 10)                       # v9.1：两位纯数字 = 十进制掩码
                mask = None if val == 0 else (val & 0x7F)
            elif re.fullmatch(r"[0-9A-F]{2}", t):
                mask = int(t, 16) & 0x7F               # 含字母 = 十六进制
            if mask is None or mask == 0:
                self._ack("ERR")
            else:
                self.ply_mask = mask
                ok()
        else:
            self._ack("ERR")                           # 未知命令：ERR，且不计数


class DeadSerial:
    """占位串口：真串口打不开（被 XCOM 占用/线没插）时用，任何操作都报错。
    页面会显示“已断开＋重连按钮”，而不是整个程序崩掉。"""
    is_open = False

    def read(self, n=1):
        raise OSError("串口未打开")

    def write(self, data):
        raise OSError("串口未打开")

    def flush(self):
        raise OSError("串口未打开")

    def close(self):
        pass


# ---------------------------------------------------------------------------
# 3) SerialLink —— PC 侧驱动：串行命令队列 + 后台读线程 + 回执日志
# ---------------------------------------------------------------------------

class _Job:
    __slots__ = ("cmd", "frame", "kind", "done", "resp", "timeout", "quiet")

    def __init__(self, cmd, frame, quiet=False):
        self.cmd = cmd
        self.frame = frame
        # v10.1 同步：查询类命令的"应答前缀"泛化表——板子回 V2(INFO?/STAT?)、
        # W(WHY? 黑匣子)；None 表示普通命令，等 OK/ERR。以后加新查询只改这张表。
        self.kind = QUERY_RESP.get(cmd)
        self.done = threading.Event()
        self.resp = None
        self.timeout = False
        self.quiet = quiet              # 轮询类查询不进回执流（否则每0.5秒刷屏）


class SerialLink:
    """所有命令排队、一条一条发；后台线程逐行收回执。

    注入 serial_obj：真机传 serial.Serial(...)，测试/演示传 FakeSerial()。
    本类内部绝不 import serial，保证 mock 模式与串口零接触。"""

    def __init__(self, serial_obj, port_name="FAKE", mock=False):
        self.ser = serial_obj
        self.port_name = port_name
        self.mock = mock
        self.connected = True
        self._q = queue.Queue()
        self._cur = None                       # 正在等回执的 job
        self._lock = threading.Lock()
        self.last_v2 = ""                      # 最近一条 V2 原文（INFO 或 STAT 都行）
        self.last_v2_ts = 0.0
        self.stop_flag = threading.Event()
        self.log = deque(maxlen=600)           # 回执流日志
        self._log_seq = 0
        self._log_lock = threading.Lock()
        self._threads = []

    # ---- 日志 ----
    def _log(self, direction, text, cls=None):
        with self._log_lock:
            self._log_seq += 1
            self.log.append({
                "seq": self._log_seq,
                "t": time.strftime("%H:%M:%S") + ".%03d" % (int(time.time() * 1000) % 1000),
                "dir": direction, "text": text, "cls": cls or direction,
            })

    def log_since(self, seq):
        with self._log_lock:
            return [e for e in self.log if e["seq"] > seq], self._log_seq

    # ---- 线程 ----
    def start(self):
        t1 = threading.Thread(target=self._writer_loop, name="cmd-queue", daemon=True)
        t2 = threading.Thread(target=self._reader_loop, name="serial-reader", daemon=True)
        t1.start(); t2.start()
        self._threads = [t1, t2]
        self._log("sys", "已连接 %s%s" % (self.port_name, "（模拟板子）" if self.mock else ""))

    def stop(self):
        self.stop_flag.set()
        try:
            self.ser.close()
        except Exception:
            pass

    # ---- 发命令（阻塞直到回执或超时）----
    def submit(self, cmd_text, timeout=RESP_TIMEOUT, frame=None, quiet=False):
        """把一条命令排队发出，返回 {'ok':bool,'cmd':...,'resp':...}。
        INFO? 有防积压合并：上一条 INFO? 还没回来就不重复入队。
        frame 可传入自己编好的线上字节（“高级”抽屉发原文用），默认按协议编码。
        quiet=True：这条命令和它的 V2 回执不写进回执流（状态轮询用，防刷屏）。"""
        if not self.connected:
            return {"ok": False, "cmd": cmd_text, "resp": "未连接"}
        job = _Job(cmd_text, frame if frame is not None else build_frame(cmd_text),
                   quiet=quiet)
        if job.kind:
            with self._lock:
                if self._cur is not None and self._cur.cmd == cmd_text and not self._cur.done.is_set():
                    job = self._cur            # 合并：跟着上一个查询等同一份回执
                    return self._wait(job, timeout)
        self._q.put(job)
        return self._wait(job, timeout)

    def _wait(self, job, timeout):
        got = job.done.wait(timeout)
        if not got and job is self._cur:
            job.timeout = True                 # 让 worker 知道这单作废
            job.done.set()
        if not got:
            if not job.quiet:
                self._log("rx", "%s —— 1.2 秒没等到回执（板子没搭理？查接线）" % job.cmd, "err")
            return {"ok": False, "cmd": job.cmd, "resp": "超时"}
        want = QUERY_RESP.get(job.cmd)
        okflag = (job.resp in ("OK",)) or (want is not None and (job.resp or "").startswith(want))
        return {"ok": okflag, "cmd": job.cmd, "resp": job.resp or "超时"}

    def _writer_loop(self):
        while not self.stop_flag.is_set():
            try:
                job = self._q.get(timeout=0.2)
            except queue.Empty:
                continue
            with self._lock:
                if job.done.is_set():          # 查询合并下被“作废”的重复单，跳过
                    continue
                if job.timeout:                # 等的人已经超时走了，别发
                    continue
                self._cur = job
            try:
                if not job.quiet:
                    self._log("tx", job.cmd)
                self.ser.write(job.frame)
            except Exception as e:
                job.resp = "串口错误"
                self.connected = False
                self._log("err", "串口写失败：%s（断开？线松了？）" % e, "err")
                job.done.set()
                with self._lock:
                    self._cur = None
                continue
            # 等回执或超时（回执由 reader 线程置位）
            deadline = time.time() + RESP_TIMEOUT
            while not job.done.wait(0.05):
                if time.time() > deadline:
                    job.timeout = True
                    job.done.set()
                    break
            with self._lock:
                self._cur = None

    # ---- 收行 ----
    def _reader_loop(self):
        buf = bytearray()
        while not self.stop_flag.is_set():
            try:
                data = self.ser.read(256)
            except Exception as e:
                self.connected = False
                self._log("err", "串口读失败：%s（断开？线松了？）" % e, "err")
                time.sleep(0.5)
                return
            if not data:
                time.sleep(0.005)          # 假串口不会阻塞；让出 CPU，真串口几乎不走到这
                continue
            buf += data
            while b"\n" in buf:
                line, rest = buf.split(b"\n", 1)
                buf = bytearray(rest)
                self._handle_line(line)

    def _handle_line(self, raw):
        """逐行解析板子回执。鲁棒性：空行直接吞；乱序/多余行不会把状态机打挂。"""
        text = raw.decode("gbk", "replace").strip()
        if not text:                                   # 多余空行：忽略
            return
        with self._lock:
            job = self._cur
        want = QUERY_RESP.get(job.cmd) if job is not None else None
        quiet_v2 = (text.startswith("V2") and job is not None
                    and job.quiet and want == "V2")
        if not quiet_v2:
            self._log("rx", text, "v2" if text.startswith("V2") else ("ok" if text == "OK" else None))
        if text.startswith("V2"):
            self.last_v2 = text
            self.last_v2_ts = time.time()
            with self._lock:
                job = self._cur
            if job is not None and job.kind == "V2" and not job.done.is_set():
                job.resp = text
                job.done.set()
            return
        if text in ("OK", "ERR"):
            with self._lock:
                job = self._cur
            if job is not None and not job.done.is_set():
                job.resp = text
                job.done.set()
            # 没有待回执的命令时（乱序/重复），只进日志，不动状态 —— 板子偶尔多回一句也挂不了
            return
        # v10.1 同步：查询类应答（如 WHY? 回 "W …"）按 kind 前缀交还给等待中的 job
        with self._lock:
            job = self._cur
        if job is not None and job.kind and job.kind != "V2" \
                and text.startswith(job.kind) and not job.done.is_set():
            job.resp = text
            job.done.set()
            return
        # 其它未知行：进日志即可，别拿它去更新 last_v2（否则黑匣子串会把状态栏 V2 冲乱）


# ---------------------------------------------------------------------------
# V2 回执解析（INFO? 与 STAT? 两种写法统一成一个字典）
# ---------------------------------------------------------------------------

def parse_v2(text):
    """'V2 003 10110011' / 'V2 03 B3' -> {kind, count, dbg, bits, ...}；解析失败返回 None。"""
    m = re.fullmatch(r"V2 (\d{3}) ([01]{8})", text.strip())
    if m:
        count, bits = int(m.group(1)), m.group(2)
        kind = "info"
    else:
        m = re.fullmatch(r"V2 ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2})", text.strip())
        if not m:
            return None
        count = int(m.group(1), 16)
        bits = format(int(m.group(2), 16), "08b")
        kind = "stat"
    dbg = int(bits, 2)
    names = ["scan_ok", "auto_play", "src_done", "frame_done", "screen_valid", "load_busy"]
    out = {"kind": kind, "count": count, "dbg": dbg, "bits": bits}
    for i, name in enumerate(names):
        out[name] = bits[i] == "1"
    out["img"] = dbg & 0x03
    return out
