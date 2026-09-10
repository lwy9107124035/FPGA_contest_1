# -*- coding: ascii -*-
# send_msg.py -- PC-side sender for "any Chinese onto OSD" test.
# Encodes a UTF-8 argument string to GB2312 double-bytes, wraps it in the
# MSG command of LOAD_PROTOCOL, sends over COM, and prints the board ACK.
#
# Usage (argument is any Chinese text; pass it as-is on a UTF-8 shell):
#   python send_msg.py -p COM4 -b 115200 <text>
#   python send_msg.py --raw "ABC"        # force ASCII, no GB2312
#   python send_msg.py --dry <text>       # print bytes only, no serial
#
# Why GB2312 (plain-language note):
#   The on-board glyph ROM / W25Q64 font is indexed by GB2312 qu-wei codes.
#   Each Chinese char = 2 bytes, both in range A1..F7. The msg_ink pairing
#   engine (WP-C) turns each >=0xA1 byte-pair into one full-width slot.
import sys, time, argparse

def build_frame(text, raw_ascii):
    if raw_ascii:
        body = text.encode('ascii', 'replace')
    else:
        try:
            body = text.encode('gb2312')
        except UnicodeEncodeError:
            # fall back to GBK (superset) so rare chars still try to map
            body = text.encode('gbk', 'replace')
    # msg_ink payload is limited; 22 slots => up to ~44 bytes is safe
    if len(body) > 44:
        print("WARN: body %d bytes > 44 (22 full-width slots); board will truncate"
              % len(body))
        body = body[:44]
    return b"MSG " + body + b"\n", body

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("text")
    ap.add_argument("-p", "--port", default="COM4")
    ap.add_argument("-b", "--baud", type=int, default=115200)
    ap.add_argument("--raw", action="store_true", help="send as ASCII, no GB2312")
    ap.add_argument("--dry", action="store_true", help="print bytes only, no serial")
    a = ap.parse_args()

    frame, body = build_frame(a.text, a.raw)
    hexs = " ".join("%02X" % x for x in body)
    print("text : %s" % a.text)
    print("body : %d bytes GB2312 -> %s" % (len(body), hexs))
    # decode pairs back for a sanity view
    view = []
    i = 0
    while i < len(body):
        if body[i] >= 0xA1 and i + 1 < len(body):
            view.append(body[i:i+2].decode('gb2312', 'replace'))
            i += 2
        else:
            view.append(chr(body[i]))
            i += 1
    print("slots: %d (%s)" % (len(view), " ".join(view)))
    if a.dry:
        return
    import serial
    s = serial.Serial(a.port, a.baud, timeout=0.3)
    s.reset_input_buffer()
    s.write(frame)
    s.flush()
    t0 = time.time()
    ack = b""
    while time.time() - t0 < 0.4:
        d = s.read(16)
        if d:
            ack += d
    s.close()
    print("ack  : %s" % repr(ack))

if __name__ == "__main__":
    main()
