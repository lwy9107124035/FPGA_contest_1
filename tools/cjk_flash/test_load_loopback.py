#!/usr/bin/env python3
# -*- coding: ascii -*-
"""
test_load_loopback.py -- offline loopback / unit tests for load_font.py.

Layers of verification (the real board is NOT touched):
  1. CRC table vs an INDEPENDENT bit-serial reference implementation,
     random payloads, both candidate init values, published vectors
     0x31C3 / 0x29B1.
  2. build_frame(): sync/version bytes, LEN big-endian, CRC coverage,
     LEN=0 end frame.
  3. LineAccumulator: split lines across read chunks, CRLF tolerance,
     junk-cap, reset().
  4. FULL SESSION LOOPBACK: LoaderSim -- a byte-level firmware simulator
     (text phase "LOAD\\n" -> "RDY\\r\\n" + "ERASED\\n", then the binary
     frame state machine with its own bit-serial CRC check, CERR-on-bad,
     P40 every 40 frames, ABORT on 3-strike, DONE/BAD after the end
     frame) -- is wired to run_session() through an in-memory serial
     object. The reassembled payload is compared byte-for-byte against
     the real hzk16.bin. Failure paths exercised: CERR resend,
     3-consecutive-CERR abort, BAD verdict, ERASED timeout.

Run:  python test_load_loopback.py     (exit 0 = all pass)
"""

import io
import os
import random
import re
import sys
import time
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import load_font as L  # noqa: E402


# ------------------------------------------------------- reference CRC (bit-serial, independent of the table code)
def crc_ref(data, init):
    crc = init
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ 0x1021) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
    return crc


class LoaderSim:
    """Behavioural model of uart_loader.v per protocol sections 2..4.
    Deliberately uses crc_ref() (different code path than the PC's
    lookup table) so the two implementations cross-validate."""

    def __init__(self, expect, *, skip_erased=False, force_cerr_n=0,
                 force_cerr_always=False, bad_verify=False):
        self.expect = expect
        self.pending = bytearray()        # board -> PC
        self.payload = bytearray()        # reassembled image
        self.phase = "text"
        self.rx_line = bytearray()
        self.frames_done = 0              # accepted payload frames
        self.crc_fails = 0
        self.skip_erased = skip_erased
        self.force_cerr_n = force_cerr_n
        self.force_cerr_always = force_cerr_always
        self.bad_verify = bad_verify
        self._f = bytearray()             # current frame under assembly
        self._need = -1                   # total bytes needed, -1 = header

    # ---- PC -> board -------------------------------------------------
    def consume(self, data):
        for b in data:
            self._byte(b)

    def _byte(self, b):
        if self.phase == "text":
            self.rx_line.append(b)
            if b == 0x0A:
                line = bytes(self.rx_line).rstrip(b"\r\n")
                del self.rx_line[:]
                if line == b"LOAD":
                    self.pending += b"RDY\r\n"        # section 2.2: 4 B incl CRLF
                    if not self.skip_erased:
                        self.pending += b"ERASED\n"   # section 4
                    self.phase = "bin"
            return
        if self.phase != "bin":
            return                                    # section 2.3: silent drop
        # frame state machine: A5 | 01 | LENh | LENl | payload | crc x2
        self._f.append(b)
        f = self._f
        if len(f) == 1 and f[0] != L.SYNC_BYTE:
            del f[:]                                  # resync
            return
        if len(f) == 2 and f[1] != L.PROTO_VER:
            del f[:]
            if f == b"":
                return
        if len(f) < 4:
            return
        if self._need < 0:
            n = (f[2] << 8) | f[3]
            self._need = 4 + n + 2 if n <= L.MAX_PAYLOAD else -2
            if self._need == -2:
                self._finish_frame_corrupt()
                return
        if len(f) >= self._need:
            frame = bytes(f[:self._need])
            del f[:]
            self._need = -1
            self._finish_frame(frame)

    def _finish_frame_corrupt(self):
        # oversized LEN: treat as a bad frame, resync
        del self._f[:]
        self._need = -1
        self.crc_fails += 1
        self.pending += b"CERR\n"

    def _finish_frame(self, frame):
        n = (frame[2] << 8) | frame[3]
        if self.force_cerr_always or self.force_cerr_n > 0:
            if self.force_cerr_n > 0:
                self.force_cerr_n -= 1
            self.crc_fails += 1
            self.pending += b"CERR\n"                 # section 3
            return
        given = (frame[-2] << 8) | frame[-1]
        if given != crc_ref(frame[:-2], 0x0000):
            self.crc_fails += 1
            self.pending += b"CERR\n"
            return
        self.payload += frame[4:4 + n]
        self.frames_done += 1
        if n == 0:                                     # END frame
            ok = (not self.bad_verify) and bytes(self.payload) == self.expect
            self.pending += b"DONE\n" if ok else b"BAD\n"
            self.phase = "post"
        elif self.frames_done % 40 == 0:               # progress row (opt.)
            self.pending += ("P%d\n" % self.frames_done).encode("ascii")


class LoopbackSerial:
    """duck-typed pyserial.Serial over a LoaderSim (no OS resources)."""

    def __init__(self, sim):
        self.sim = sim
        self.writes = 0

    @property
    def in_waiting(self):
        return len(self.sim.pending)

    def read(self, n):
        b = bytes(self.sim.pending[:n])
        del self.sim.pending[:n]
        return b

    def write(self, data):
        self.writes += 1
        self.sim.consume(data)
        return len(data)

    def flush(self):
        pass

    def discard_input_buffer(self):
        del self.sim.pending[:]

    def close(self):
        pass


# ------------------------------------------------------------------ harness
FAILS = []
COUNT = [0]


def check(name, cond, detail=""):
    COUNT[0] += 1
    if cond:
        print("PASS  %s" % name, flush=True)
    else:
        FAILS.append(name)
        print("FAIL  %s  %s" % (name, detail), flush=True)


def load_image():
    path = os.path.join(HERE, "hzk16.bin")
    if os.path.isfile(path):
        with open(path, "rb") as fh:
            return fh.read(), path
    # deterministic fallback so the suite also runs without the image
    rnd = random.Random(20260905)
    return bytes(rnd.randrange(256) for _ in range(L.EXPECTED_IMAGE_SIZE)), \
        "(synthetic 282752 B)"


def run_loopback(sim, image, **kw):
    ser = LoopbackSerial(sim)
    log_lines = []
    t_rdy = kw.pop("t_rdy", L.T_RDY_S)
    t_erased = kw.pop("t_erased", L.T_ERASED_S)
    table = L.build_crc_table()
    stats = L.run_session(ser, image, table, 0x0000, log_lines.append,
                          t_rdy=t_rdy, t_erased=t_erased,
                          settle_s=0.002, **kw)
    return ser, stats, log_lines


# ------------------------------------------------------------------- tests
def test_crc():
    table = L.build_crc_table()
    check("crc table length 256", len(table) == 256)
    check("every table entry matches bit-serial of that byte (init 0)",
          all(table[i] == crc_ref(bytes([i]), 0) for i in range(256)))
    # published check vectors ([IP-1])
    c0 = L.crc16(b"123456789", table, 0x0000)
    c1 = L.crc16(b"123456789", table, 0xFFFF)
    check("table CRC('123456789',init0) == 0x31C3", c0 == 0x31C3, hex(c0))
    check("table CRC('123456789',initFFFF) == 0x29B1", c1 == 0x29B1, hex(c1))
    rnd = random.Random(7)
    ok = True
    for ln in list(range(0, 300)) + [rnd.randrange(4096) for _ in range(20)]:
        data = bytes(rnd.randrange(256) for _ in range(ln))
        for init in (0x0000, 0xFFFF):
            if L.crc16(data, table, init) != crc_ref(data, init):
                ok = False
    check("table == bit-serial reference (all lens 0..299 + random, "
          "both inits)", ok)
    check("crc of empty data == init",
          L.crc16(b"", table, 0xABCD) == 0xABCD)


def test_framing():
    table = L.build_crc_table()
    end = L.build_frame(b"", table, 0)
    check("END frame = A5 01 00 00 + CRC over 4 header bytes",
          end[:4] == b"\xa5\x01\x00\x00" and
          end[4:] == bytes([crc_ref(end[:4], 0) >> 8,
                            crc_ref(end[:4], 0) & 0xFF]), L.hexdump(end))
    f1 = L.build_frame(b"\xAB", table, 0)
    check("LEN=1 encodes big-endian 00 01", f1[:4] == b"\xa5\x01\x00\x01")
    pay = bytes(range(256))
    f = L.build_frame(pay, table, 0)
    check("full frame layout A5 01 01 00 + payload", f[:4] == b"\xa5\x01\x01\x00"
          and f[4:260] == pay)
    crc = (f[-2] << 8) | f[-1]
    check("frame CRC covers byte0..last payload byte",
          crc == crc_ref(f[:-2], 0))
    try:
        L.build_frame(b"\x00" * 257, table, 0)
        check("payload >256 rejected", False)
    except L.LoadError:
        check("payload >256 rejected", True)
    img, src = load_image()
    frames = L.split_frames(img)
    check("hzk16 -> 1105 frames (1104x256 + residue 128) [IP-6]",
          len(frames) == 1105 and len(frames[-1]) == 128 and
          all(len(p) == 256 for p in frames[:-1]),
          "from %s" % src)


def test_line_parser():
    a = L.LineAccumulator()
    check("no line before LF", a.feed(b"ER") == [])
    check("CRLF row stripped", a.feed(b"ASED\r\n") == ["ERASED"])
    check("two rows in one chunk (RDY\\r\\n + P40\\n)",
          a.feed(b"RDY\r\nP40\n") == ["RDY", "P40"])
    check("bare LF row", a.feed(b"DONE\n") == ["DONE"])
    check("empty line ignored", a.feed(b"\r\n\r\n") == [])
    a2 = L.LineAccumulator()
    a2.feed(b"PART")
    a2.reset()
    check("reset() drops stale fragment", a2.feed(b"RDY\n") == ["RDY"])
    a3 = L.LineAccumulator()
    a3.feed(b"\x00\x01\x02" * 300)            # unterminated junk
    check("junk tail capped", len(a3._buf) <= a3.CAP, len(a3._buf))
    a4 = L.LineAccumulator()
    a4.feed(b"\xff\xfe")                       # binary junk, no crash
    lines = a4.feed(b"OK\n")
    check("binary junk yields one replacement line, no crash",
          len(lines) == 1 and lines[0].endswith("OK"))


def test_boardtext_queues_both_lines():
    sim = LoaderSim(b"")
    sim.pending += b"RDY\r\nERASED\n"          # both rows in ONE chunk
    ser = LoopbackSerial(sim)
    log = []
    bt = L.BoardText(ser, log.append)
    r1 = bt.wait({"RDY"}, 1.0, "t")
    r2 = bt.wait({"ERASED"}, 1.0, "t")
    check("BoardText keeps 2nd line from same chunk",
          (r1, r2) == ("RDY", "ERASED"), "%s,%s" % (r1, r2))
    check("fatal ABORT raises", _raises_fatal())


def _raises_fatal():
    sim = LoaderSim(b"")
    try:
        bt = L.BoardText(LoopbackSerial(sim), lambda s: None)
        sim.pending += b"ABORT\n"
        bt.wait({"DONE"}, 0.5, "t")
        return False
    except L.LoadError as e:
        return "ABORT" in str(e)


def test_session_clean():
    img, src = load_image()
    sim = LoaderSim(img)
    with mock.patch("time.sleep", lambda s: None):
        ser, stats, log = run_loopback(sim, img)
    check("clean session: payload reassembled byte-exact vs %s" % src,
          bytes(sim.payload) == img)
    check("clean session: 1105 payload frames + END accepted by sim",
          sim.frames_done == 1106 and ser.sim.phase == "post",
          str(sim.frames_done))
    check("clean session: 1106 frame writes (no resends), 1107 incl. LOAD line",
          ser.writes == 1107 and stats["writes"] == 1106,
          "ser=%d stats=%d" % (ser.writes, stats["writes"]))
    prog = [s for s in log if re.match(r"\s*\d+%", s)]
    check("progress line every 110 frames (10 x 110 + final = 11 lines)",
          len(prog) == 11 and prog[0].strip().startswith("10%") and
          prog[-1].strip().startswith("100%"),
          "%d lines: %r" % (len(prog), prog[:3]))
    check("board P40 rows echoed by PC", any("P40" in s for s in log))
    check("session log has RDY and ERASED echoes",
          any("[board] RDY" in s for s in log) and
          any("[board] ERASED" in s for s in log))
    first_pct = prog[0]
    check("progress shows '10%' style", re.match(r"\s*10%", first_pct),
          first_pct)


def test_session_cerr_retry():
    img, _ = load_image()
    sim = LoaderSim(img, force_cerr_n=2)      # frames 0,1 rejected once
    with mock.patch("time.sleep", lambda s: None):
        ser, stats, log = run_loopback(sim, img)
    check("CERR resend: 2 resends -> 1108 frame writes (1110 incl. LOAD)",
          stats["writes"] == 1108 and ser.writes == 1109,
          "stats=%d ser=%d" % (stats["writes"], ser.writes))
    check("CERR resend: image still byte-exact", bytes(sim.payload) == img)
    check("CERR resend: log shows resend notice",
          any("resend" in s for s in log))


def test_session_abort3():
    img, _ = load_image()
    sim = LoaderSim(img, force_cerr_always=True)
    raised = None
    with mock.patch("time.sleep", lambda s: None):
        try:
            run_loopback(sim, img)
        except L.LoadError as e:
            raised = str(e)
    check("3 consecutive CERR aborts session",
          raised is not None and "3 consecutive CERR" in raised, str(raised))
    check("abort happened at frame 0 after exactly 3 writes",
          sim.crc_fails == 3, str(sim.crc_fails))


def test_session_bad_and_timeout():
    img, _ = load_image()
    sim = LoaderSim(img, bad_verify=True)     # reassembly "mismatch"
    raised = None
    with mock.patch("time.sleep", lambda s: None):
        try:
            run_loopback(sim, img)
        except L.LoadError as e:
            raised = str(e)
    check("BAD verdict -> LoadError", raised and "BAD" in raised, str(raised))

    sim2 = LoaderSim(img, skip_erased=True)   # board never reports ERASED
    raised = None
    with mock.patch("time.sleep", lambda s: None):
        try:
            run_loopback(sim2, img, t_erased=0.25)
        except L.LoadError as e:
            raised = str(e)
    check("missing ERASED -> timeout LoadError",
          raised and "ERASED" in raised and "timeout" in raised, str(raised))


def test_cli_dry():
    import contextlib
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = L.main(["-dry"])
    out = buf.getvalue()
    check("main -dry exit 0", rc == 0, str(rc))
    check("dry prints LOAD OK", "LOAD OK" in out)
    check("dry prints CRC selfcheck 0x31C3", "0x31C3" in out)
    check("dry prints first-frame head A5 01 01 00", "A5 01 01 00" in out)
    check("dry prints [IP-6] residue-frame warning", "LEN=128" in out)
    check("dry output is pure ASCII (GBK-console safe)",
          _is_ascii(out), "non-ascii byte in stdout")
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = L.main(["-dry", "-img", os.path.join(HERE, "no_such_file.bin")])
    check("missing image -> exit 1", rc == 1 and
          "LOAD FAILED" in buf.getvalue())
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = L.main(["-dry", "-crc-init", "ffff"])
    out = buf.getvalue()
    check("crc-init ffff: runs with 0x29B1 + IP-1 warning",
          rc == 0 and "0x29B1" in out and "WARNING" in out)


def _is_ascii(s):
    try:
        s.encode("ascii")
        return True
    except UnicodeEncodeError:
        return False


def main():
    random.seed(20260905)
    for t in (test_crc, test_framing, test_line_parser,
              test_boardtext_queues_both_lines,
              test_session_clean, test_session_cerr_retry,
              test_session_abort3, test_session_bad_and_timeout,
              test_cli_dry):
        print("--- %s" % t.__name__, flush=True)
        t()
    print("=" * 60)
    print("%d checks, %d failures" % (COUNT[0], len(FAILS)))
    if FAILS:
        for f in FAILS:
            print("  FAILED: %s" % f)
        print("LOOPBACK TEST FAIL")
        return 1
    print("LOOPBACK TEST PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
