#!/usr/bin/env python3
# -*- coding: ascii -*-
"""
load_font.py -- PC-side host sender for the "LOAD" v1 protocol.

Implements the PC side of LOAD_PROTOCOL.md sections 2..5:
  send "LOAD\\n" -> wait "RDY\\n" -> wait "ERASED\\n" (batch erase done)
  -> stream hzk16.bin as 256-byte frames (0xA5 0x01 LEN16 payload CRC16,
     all big-endian) -> LEN=0 end frame -> wait "DONE\\n"/"BAD\\n".

Binary framing is strict per protocol section 3. Output is ASCII-only
(Windows GBK console safety, section 5).

Serial stack: pyserial (3.5 confirmed installed in
C:\\Users\\lwy\\miniconda3\\envs\\fpga_batch on the build host; the ctypes
CreateFile fallback was therefore NOT needed and is not implemented).

===========================================================================
FIRMWARE INTEGRATION POINTS (marked [IP-x], pending joint debug on real
board -- these are the places where PC-side choices must be re-checked
against uart_loader.v / msg_ink.v behaviour):

[IP-1] CRC16 init-value CONTRADICTION inside LOAD_PROTOCOL.md.
       Section 3 text says "poly 0x1021, init 0xFFFF, no reflection",
       but the MANDATORY self-check vector in section 5,
       CRC16("123456789") == 0x31C3, is mathematically produced ONLY by
       init 0x0000 (CRC-16/XMODEM flavour). init 0xFFFF yields 0x29B1.
       "Self-check fails -> refuse to run" makes the VECTOR
       authoritative: default CRC_INIT = 0x0000. If the firmware was
       written to the section-3 wording (init 0xFFFF), run this tool with
       "-crc-init ffff" (its own self-check then demands 0x29B1 so a
       broken table is still caught). Symptom of mismatch: CERR on EVERY
       frame -> flip the flag or the one constant in the firmware.

[IP-2] ERASED timeout: task brief says 35 s, protocol section 4
       parenthetical says 30 s. The larger (35 s) is used; it covers the
       5x 64KiB block-erase worst case (5 x 3 s = 15 s).

[IP-3] RDY timeout is not fixed anywhere; 10 s chosen.

[IP-4] CERR attribution: section 3 says the board answers CERR right
       after the bad frame's last byte. PC does write()+flush() (bytes
       really on the wire), then peeks RX with a ~4 ms settle window
       before starting the NEXT frame, so a CERR is attributed to the
       frame that caused it. If firmware delays CERR beyond ~4 ms it
       would be mis-attributed to the following frame. Firmware must
       answer CERR quickly (one UART line = 0.52 ms @115200).

[IP-5] Board replies nothing per accepted frame (section 3, bandwidth).
       So "no CERR within the settle window" == frame accepted.
       3 consecutive CERR for the SAME frame -> PC aborts (exit 1) in
       lockstep with the board's own ABORT (section 3).

[IP-6] PROTOCOL ARITHMETIC ERROR: section 5 claims "282752 = 1105*256
       exactly, no residue frame". FALSE: 1105*256 = 282880. The real
       split is 1104 frames x 256 B + ONE RESIDUE FRAME LEN=128
       (282752 = 94*94*32 bytes exactly). The PC sends that short final
       frame (section 3 explicitly allows a residue last frame). The
       uart_loader.v RX path MUST accept LEN < 256 on the last payload
       frame; if it hardcodes 256, every session dies there with CERR.
       Same family: section 3's "tail address = 282752-32 = 0x457E0" --
       the true value is 282720 = 0x45060. Firmware must compute the
       spot-check address from its RECEIVED byte count, not 0x457E0.
===========================================================================
"""

import argparse
import os
import sys
import time

# ---------------------------------------------------------------- constants
SYNC_BYTE = 0xA5              # frame sync, byte0 (protocol section 3)
PROTO_VER = 0x01              # version,    byte1
MAX_PAYLOAD = 256             # LEN field max
EXPECTED_IMAGE_SIZE = 282752  # HZK16 = 94*94*32 B (protocol section 1)
PROGRESS_EVERY = 110          # one " 10%"-style line (protocol section 5)

CRC_POLY = 0x1021
# [IP-1] init -> mandatory CRC16(b"123456789") self-check vector.
CRC_VECTORS = {0x0000: 0x31C3,   # default: section-5 vector (XMODEM init)
               0xFFFF: 0x29B1}   # section-3 literal wording (CCITT-FALSE)

T_RDY_S = 10.0                # [IP-3]
T_ERASED_S = 35.0             # [IP-2]
T_DONE_S = 40.0               # task brief: DONE/BAD timeout 40 s
FRAME_GAP_S = 0.0005          # task pacing: sleep(0.5ms) after each write
CERR_SETTLE_S = 0.004         # [IP-4] RX settle window per frame
MAX_CERR_STREAK = 3           # [IP-5]

FATAL_LINES = frozenset(("ABORT", "TIMEOUT"))   # board-initiated death


class LoadError(Exception):
    """Fatal protocol / transport error -> exit code 1."""


# ------------------------------------------------------------------- CRC16
def build_crc_table(poly=CRC_POLY):
    """CRC16 lookup table, MSB-first (no reflection), poly 0x1021."""
    table = []
    for i in range(256):
        crc = i << 8
        for _ in range(8):
            if crc & 0x8000:
                crc = ((crc << 1) ^ poly) & 0xFFFF
            else:
                crc = (crc << 1) & 0xFFFF
        table.append(crc)
    return table


def crc16(data, table, init=0x0000):
    """Table-driven CRC16-CCITT over a byte sequence."""
    crc = init
    for b in data:
        crc = ((crc << 8) & 0xFFFF) ^ table[((crc >> 8) ^ b) & 0xFF]
    return crc


def crc_selfcheck(table, init):
    """Return (computed, expected) CRC16 of b'123456789' for this init."""
    return crc16(b"123456789", table, init), CRC_VECTORS[init]


# ------------------------------------------------------------------ framing
def hexdump(data):
    return " ".join("%02X" % b for b in data)


def build_frame(payload, table, crc_init):
    """One protocol frame: A5 01 LENhi LENlo <payload> CRChi CRClo.
    CRC covers byte0..last payload byte (all bytes before the CRC)."""
    n = len(payload)
    if n > MAX_PAYLOAD:
        raise LoadError("payload longer than %d bytes" % MAX_PAYLOAD)
    body = bytes([SYNC_BYTE, PROTO_VER, (n >> 8) & 0xFF, n & 0xFF]) + payload
    crc = crc16(body, table, crc_init)
    return body + bytes([(crc >> 8) & 0xFF, crc & 0xFF])


def split_frames(image):
    """Payload -> list of <=256B chunks. 282752B -> 1104x256 + 1x128
    (see [IP-6] -- protocol's '1105*256, no residue' claim is false)."""
    return [image[o:o + MAX_PAYLOAD] for o in range(0, len(image), MAX_PAYLOAD)]


# ---------------------------------------------------- tolerant line parsing
class LineAccumulator:
    """Splits the board's ASCII text stream into lines. Any \\n ends a
    line, a trailing \\r is stripped (board rows may be CRLF, protocol
    section 2.2 says RDY is 4 bytes incl. CRLF), empty lines are ignored.
    The unterminated tail is capped so binary junk left in the UART by a
    previous session can never grow the buffer unboundedly."""

    CAP = 512
    KEEP = 32   # on overflow keep this many newest bytes

    def __init__(self):
        self._buf = bytearray()

    def reset(self):
        self._buf.clear()

    def feed(self, data):
        """Append bytes; return list of complete decoded text lines."""
        self._buf += data
        lines = []
        while True:
            cut = self._buf.find(b"\n")
            if cut < 0:
                break
            raw = bytes(self._buf[:cut])
            del self._buf[:cut + 1]
            text = raw.rstrip(b"\r").decode("ascii", errors="replace").strip()
            if text:
                lines.append(text)
        if len(self._buf) > self.CAP:
            del self._buf[:-self.KEEP]
        return lines


class BoardText:
    """Serial RX -> logged text lines -> consumption queue.

    Every received line is echoed immediately (protocol section 5:
    "print each ASCII line read"), then queued so that several lines
    arriving in ONE read chunk (e.g. "RDY\\r\\nERASED\\n") are all seen by
    the corresponding successive wait() calls. ABORT/TIMEOUT raise at
    once, wherever they appear."""

    def __init__(self, ser, log):
        self.ser = ser
        self.log = log
        self.acc = LineAccumulator()
        self._pending = []

    def reset(self):
        """Purge any fragments left from a previous session [task]."""
        self.acc.reset()
        del self._pending[:]

    def _pump(self, settle_s=0.0):
        deadline = time.monotonic() + settle_s
        while True:
            n = getattr(self.ser, "in_waiting", 0)
            if n:
                for line in self.acc.feed(self.ser.read(n)):
                    self.log("[board] %s" % line)
                    if line in FATAL_LINES:
                        raise LoadError("board returned %s" % line)
                    self._pending.append(line)
            if time.monotonic() >= deadline:
                return
            time.sleep(0.0005)

    def wait(self, want, timeout_s, label):
        """Wait for one of `want` rows; raise LoadError on timeout."""
        deadline = time.monotonic() + timeout_s
        while True:
            for k, line in enumerate(self._pending):
                if line in want:
                    del self._pending[:k + 1]
                    return line
            if time.monotonic() >= deadline:
                raise LoadError("timeout %.0fs waiting for %s (%s); "
                                "last rows: %s"
                                % (timeout_s, "/".join(sorted(want)), label,
                                   self._pending[-5:] or "nothing received"))
            self._pump(0.005)

    def clear(self):
        """Drop queued rows (already logged; board P## progress lines)."""
        del self._pending[:]

    def poll_after_frame(self, settle_s=CERR_SETTLE_S):
        """One non-blocking RX peek after a frame write. Returns True if
        the board rejected THAT frame with CERR ([IP-4]/[IP-5]). Queued
        rows are left in place: the frame loop clears them for payload
        frames, but the END frame keeps them so a fast DONE/BAD (board
        can answer inside the settle window!) is not swallowed."""
        self._pump(settle_s)
        return "CERR" in self._pending


# ------------------------------------------------------------ serial plumbing
def open_serial(com, baud):
    """pyserial route (confirmed on the build host). timeout=0 -> reads
    are non-blocking; we only ever read in_waiting bytes.
    DTR/RTS deliberately NOT touched (protocol section 5: defaults)."""
    try:
        import serial  # lazy: -dry and unit tests need no pyserial
    except ImportError:
        raise LoadError("pyserial not installed for this interpreter "
                        "(python -m pip install pyserial)")
    try:
        return serial.Serial(port=com, baudrate=baud,
                             bytesize=8, parity="N", stopbits=1,
                             timeout=0, write_timeout=10)
    except Exception as exc:
        raise LoadError("cannot open %s @ %d: %s" % (com, baud, exc))


# ------------------------------------------------------------------- session
def run_session(ser, image, table, crc_init, log,
                t_rdy=T_RDY_S, t_erased=T_ERASED_S, t_done=T_DONE_S,
                settle_s=CERR_SETTLE_S, gap_s=FRAME_GAP_S,
                progress_every=PROGRESS_EVERY,
                max_cerr_streak=MAX_CERR_STREAK):
    """Full protocol section 2..5 dialogue against a serial-like object
    (needs in_waiting/read/write/flush/discard_input_buffer). Returns
    stats dict; raises LoadError on any contract violation."""
    size = len(image)
    total = (size + MAX_PAYLOAD - 1) // MAX_PAYLOAD   # payload frames
    t0 = time.monotonic()
    bt = BoardText(ser, log)

    # [section 2] session establish. Purge stale bytes from an old run.
    # pyserial real API is reset_input_buffer(); loopback mock used
    # discard_input_buffer() -- support both so offline tests stay green.
    for _m in ("reset_input_buffer", "discard_input_buffer"):
        _f = getattr(ser, _m, None)
        if callable(_f):
            _f()
            break
    bt.reset()
    ser.write(b"LOAD\n")
    ser.flush()
    bt.wait({"RDY"}, t_rdy, "session establish")        # [IP-3]
    bt.wait({"ERASED"}, t_erased, "batch erase 5x64KiB")  # [IP-2]

    # [section 3] stream payload frames, then the LEN=0 end frame.
    err_streak = 0
    i = 0            # frame index; i == total -> END frame (LEN=0)
    writes = 0
    while True:
        payload = b"" if i >= total else image[i * MAX_PAYLOAD:
                                               (i + 1) * MAX_PAYLOAD]
        frame = build_frame(payload, table, crc_init)
        ser.write(frame)
        writes += 1
        ser.flush()                    # all bytes on the wire  [IP-4]
        time.sleep(gap_s)              # task pacing: 0.5 ms
        if bt.poll_after_frame(settle_s):
            bt.clear()
            err_streak += 1
            log("CERR on frame %d (streak %d) -> resend" % (i, err_streak))
            if err_streak >= max_cerr_streak:
                raise LoadError("aborted: %d consecutive CERR at frame %d "
                                "(board goes ABORT)" % (max_cerr_streak, i))
            time.sleep(0.002)
            continue                   # resend the SAME frame
        err_streak = 0
        if i >= total:
            break                      # END frame accepted; queue KEPT so a
                                       # fast DONE/BAD is not swallowed
        i += 1
        bt.clear()                     # payload frame accepted: drop P## rows
        if i % progress_every == 0 or i == total:
            pct = int(round(100.0 * i / max(total, 1)))
            log("%3d%%  frames %d/%d  bytes %d/%d  %5.1fs"
                % (pct, i, total, min(i * MAX_PAYLOAD, size), size,
                   time.monotonic() - t0))

    # [section 3 end] board does readback spot-check, answers DONE/BAD.
    done = bt.wait({"DONE", "BAD"}, t_done, "final readback check")
    if done == "BAD":
        raise LoadError("board reported BAD (end readback spot-check "
                        "failed, protocol section 3)")
    elapsed = time.monotonic() - t0
    log("sent %d frame writes: %d payload + 1 END, %d bytes, %.1f s"
        % (writes, total, size, elapsed))
    return {"writes": writes, "payload_frames": total, "bytes": size,
            "elapsed": elapsed}


# ------------------------------------------------------------------ dry run
def dry_run(image, table, crc_init, check, log):
    """Offline walk: CRC vector + simulated frame build for the WHOLE
    image + first/end frame hex dumps for eyeball byte-order check.
    No serial port touched. Returns 0 (pass) / 1 (fail)."""
    size = len(image)
    total = (size + MAX_PAYLOAD - 1) // MAX_PAYLOAD
    log("DRY RUN: no board, no serial -- protocol walk simulated only")
    if size != EXPECTED_IMAGE_SIZE:
        log("WARNING: image is %d bytes; board readback check assumes the "
            "standard %d B HZK16 -> expect BAD on real hardware"
            % (size, EXPECTED_IMAGE_SIZE))
    if size % MAX_PAYLOAD:
        log("note: [IP-6] last payload frame is a RESIDUE frame LEN=%d "
            "(protocol section 5's '282752=1105*256, no residue' claim is "
            "arithmetically wrong: 1105*256=282880; true split %d*256+%d)"
            % (size % MAX_PAYLOAD, size // MAX_PAYLOAD, size % MAX_PAYLOAD))

    frames = split_frames(image)
    bad_len = [k for k, p in enumerate(frames[:-1]) if len(p) != MAX_PAYLOAD]
    built = [build_frame(p, table, crc_init) for p in frames]
    end_frame = build_frame(b"", table, crc_init)
    crc_xor = 0
    for f in built:
        crc_xor ^= (f[-2] << 8) | f[-1]
    log("simulated frame walk: %d payload frames + 1 END frame = %d "
        "writes, rolling CRC-XOR=0x%04X%s"
        % (len(built), len(built) + 1, crc_xor & 0xFFFF,
           "" if not bad_len else "  [ERROR: short frame before the end!]"))

    f0 = built[0] if built else end_frame
    n0 = min(size, MAX_PAYLOAD)
    want_head = (bytes([SYNC_BYTE, PROTO_VER,
                        (n0 >> 8) & 0xFF, n0 & 0xFF]) + image[:4])[:8]
    log("first frame bytes 0..15 : %s" % hexdump(f0[:16]))
    log("  expect bytes 0..7     : %s   (A5 01 + LEN16 big-endian + image[0:4])"
        % hexdump(want_head))
    log("end frame (LEN=0)       : %s" % hexdump(end_frame))
    log("image[0:4]              : %s" % hexdump(image[:4]))
    if f0[:8] != want_head:
        log("ERROR: first frame head mismatch (want A5 01 01 00 + image[0:4])")
        return 1
    if len(built) != total or bad_len:
        log("ERROR: frame walk mismatch")
        return 1
    log("dry checks: CRC vector 0x%04X OK, frame count %d OK, LEN byte "
        "order OK, END frame CRC OK" % (check, total))
    return 0


# --------------------------------------------------------------------- main
def parse_args(argv=None):
    ap = argparse.ArgumentParser(
        prog="load_font.py",
        description="LOAD v1 host-side font loader (LOAD_PROTOCOL.md)")
    ap.add_argument("-com", default="COM4", help="serial port (default COM4)")
    ap.add_argument("-img", default=None,
                    help="image path (default: hzk16.bin next to this script)")
    ap.add_argument("-baud", type=int, default=115200, help="baud rate")
    ap.add_argument("-dry", action="store_true",
                    help="offline: CRC selfcheck + simulated framing, no serial")
    ap.add_argument("-crc-init", dest="crc_init", choices=("0000", "ffff"),
                    default="0000",
                    help="[IP-1] CRC16 init: 0000 (default, gives the "
                         "section-5 vector 0x31C3) or ffff (section-3 "
                         "wording, vector 0x29B1; firmware-interoperation "
                         "escape hatch)")
    return ap.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)

    def log(msg):
        # GBK console belt-and-braces: emit pure ASCII, never crash.
        sys.stdout.write(msg.encode("ascii", errors="replace")
                         .decode("ascii") + "\n")
        sys.stdout.flush()

    script_dir = os.path.dirname(os.path.abspath(__file__))
    img_path = args.img if args.img else os.path.join(script_dir, "hzk16.bin")

    log("load_font.py - LOAD v1 host sender (protocol sections 2..5)")
    try:
        with open(img_path, "rb") as fh:
            image = fh.read()
    except OSError as exc:
        log("LOAD FAILED: cannot read image %s: %s" % (img_path, exc))
        return 1

    # Mandatory CRC self-test -- refuse to run on mismatch (section 5).
    table = build_crc_table()
    crc_init = int(args.crc_init, 16)
    check, expect = crc_selfcheck(table, crc_init)
    if check != expect:
        log("LOAD FAILED: CRC selfcheck FAILED: CRC16(b'123456789') = "
            "0x%04X, expected 0x%04X for init 0x%04X -- table broken, "
            "refusing to run" % (check, expect, crc_init))
        return 1
    log("CRC selfcheck OK: CRC16(\"123456789\") = 0x%04X "
        "(poly=0x1021 MSB-first table, init=0x%04X, no reflection)"
        % (check, crc_init))
    if crc_init != 0x0000:
        log("WARNING [IP-1]: init 0xFFFF gives 0x29B1, NOT the section-5 "
            "vector 0x31C3 -- only use if the firmware implements the "
            "section-3 wording verbatim")

    total = (len(image) + MAX_PAYLOAD - 1) // MAX_PAYLOAD
    log("image: %s" % img_path)
    log("       %d bytes -> %d payload frames + 1 END frame"
        % (len(image), total))

    if args.dry:
        rc = dry_run(image, table, crc_init, check, log)
        log("LOAD OK" if rc == 0 else "LOAD FAILED: dry-run checks failed")
        return rc

    ser = None
    try:
        log("opening %s @ %d 8N1 (DTR/RTS left at pyserial defaults)"
            % (args.com, args.baud))
        ser = open_serial(args.com, args.baud)
        run_session(ser, image, table, crc_init, log)
        log("LOAD OK")
        return 0
    except LoadError as exc:
        log("LOAD FAILED: %s" % exc)
        return 1
    except KeyboardInterrupt:
        log("LOAD FAILED: interrupted by user")
        return 1
    finally:
        if ser is not None:
            try:
                ser.close()
            except Exception:
                pass


if __name__ == "__main__":
    sys.exit(main())
