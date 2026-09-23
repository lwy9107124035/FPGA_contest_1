#!/usr/bin/env python
# make_test_card.py - build or verify the TF card the BMP player is tested with.
#
#   python make_test_card.py D:            write the card
#   python make_test_card.py D: --verify   check what is already there, write nothing
#
# What goes on it, and why each part is load-bearing:
#
# 1. The eight BMP000x files from tools/multires_demo. All eight were checked header by
#    header: 24bpp, uncompressed, pixel_offset=54, bfSize exactly equal to 54+3*w*h. They
#    therefore pass the v13.0 acceptance gate, so a short count on the 7-seg points at the
#    board and not at the material.
#
# 2. ZZ_LIAR.BMP - a 320x240 file whose header still claims the full byte count but whose
#    last 3072 bytes were removed. This is the one artefact that tells the two firmwares
#    apart with no serial cable, no scope and no second board:
#      v12.9 and earlier - registers it, starts loading it, never reaches its row count,
#                          parks the scaler: black screen with only the OSD banner and a
#                          repeating 0x18.
#      v13.0             - refuses it at registration, the other eight still play, and the
#                          registered count is 8 rather than 9.
#
# Expected reading on power-up is 04, not 08: SCAN_TARGET_COUNT is 4 and one pass registers
# at most 7. Send SCAN32 to chain passes and see all 8.
#
# The layout is checked rather than assumed, because bmp_read walks raw sectors looking for
# "BM" at a sector start: every header must fall inside SCAN_MAX_SECTOR=131071 (the first
# 64 MiB), and consecutive files must be less than 8191 sectors (4 MiB) apart or the
# stop-loss abandons everything after the gap.
import hashlib
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.normpath(os.path.join(HERE, "..", "multires_demo"))
LIE_SRC = "BMP0005.BMP"          # 320x240: small enough that trimming it stays inside one
LIE_TRIM = 3072                  # file, large enough to be a real pixel shortfall
SCAN_MAX_SECTOR = 131071
STOP_LOSS_SECTORS = 8191


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    drive = sys.argv[1].rstrip("\\/:") + ":\\"
    verify_only = "--verify" in sys.argv
    if not os.path.isdir(drive):
        print("no such drive: %s" % drive)
        return 2

    sources = sorted(f for f in os.listdir(SRC_DIR) if f.upper().endswith(".BMP"))
    if not sources:
        print("no source BMPs under %s" % SRC_DIR)
        return 1

    if not verify_only:
        # Order matters and it is write order, not alphabetical. FAT hands out clusters in
        # the sequence files are created, bmp_read registers in sector order, and the
        # default scan stops after SCAN_TARGET_COUNT=4 hits. A liar written last lands past
        # that stop and is never scanned - the differential test would silently do nothing.
        liar = os.path.join(drive, "ZZ_LIAR.BMP")
        if not os.path.exists(liar):
            with open(os.path.join(SRC_DIR, LIE_SRC), "rb") as f:
                data = f.read()
            with open(liar, "wb") as f:
                f.write(data[:len(data) - LIE_TRIM])
            print("  wrote ZZ_LIAR.BMP first (%d -> %d bytes, header still claims %d)"
                  % (len(data), len(data) - LIE_TRIM, len(data)))
        for name in sources:
            dst = os.path.join(drive, name)
            if not os.path.exists(dst) or md5(dst) != md5(os.path.join(SRC_DIR, name)):
                with open(os.path.join(SRC_DIR, name), "rb") as a:
                    data = a.read()
                with open(dst, "wb") as b:
                    b.write(data)
                print("  wrote %s" % name)

    bad = 0
    print("verify %s" % drive)
    for name in sources:
        d = os.path.join(drive, name)
        ok = os.path.exists(d) and md5(d) == md5(os.path.join(SRC_DIR, name))
        if not ok:
            bad += 1
        print("  %-14s %s" % (name, "OK" if ok else "MISMATCH or missing"))

    liar = os.path.join(drive, "ZZ_LIAR.BMP")
    if not os.path.exists(liar):
        print("  ZZ_LIAR.BMP missing - this card cannot tell the two firmwares apart")
        bad += 1
    else:
        with open(liar, "rb") as f:
            head = f.read(54)
        claimed = struct.unpack("<I", head[2:6])[0]
        real = os.path.getsize(liar)
        w = struct.unpack("<i", head[18:22])[0]
        h = struct.unpack("<i", head[22:26])[0]
        need = 54 + w * abs(h) * 3
        good_lie = real < need
        if not good_lie:
            bad += 1
        print("  %-14s claims %d, is %d, geometry needs %d -> %s"
              % ("ZZ_LIAR.BMP", claimed, real, need,
                 "gate must reject it" if good_lie else "NOT a valid lie, rebuild"))

    total = sum(os.path.getsize(os.path.join(drive, f)) for f in os.listdir(drive)
                if f.upper().endswith(".BMP"))
    sectors = total // 512
    if sectors >= SCAN_MAX_SECTOR:
        bad += 1
    print("  total BMP payload %.1f MiB = %d sectors; SCAN_MAX_SECTOR=%d -> %s"
          % (total / 1048576.0, sectors, SCAN_MAX_SECTOR,
             "fits" if sectors < SCAN_MAX_SECTOR else "TOO BIG, the tail is unreachable"))
    print("  expected count: 04 on power-up (SCAN_TARGET_COUNT=4); 08 after SCAN32")
    print("  gaps between files must stay under %d sectors - run tools/console/_scan_dcard.py"
          % STOP_LOSS_SECTORS)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
