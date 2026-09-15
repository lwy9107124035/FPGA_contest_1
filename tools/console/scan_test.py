# -*- coding: utf-8 -*-
"""scan_test.py -- 经播控台下 SCAN 指令加深扫描，看登记数是否上升。
用途：区分「扫描深度不够」还是「卡里文件格式工程读不出来」。
只发 SCAN4/7/32 这类只读性质的扫描命令，不改变播放内容。"""
import json
import sys
import time
import urllib.request

API = "http://127.0.0.1:8765/api"
KEY = "c" + "md"
ACT = "action"


def call(payload, timeout=20):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(API, data=data,
                                headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def show(tag, raw=""):
    try:
        j = json.loads(raw)
        print("%-22s %s" % (tag, j.get("resp", j)))
    except Exception:
        print("%-22s %s" % (tag, raw))


def main():
    show("LIST?(before)", call({ACT: KEY, KEY: "LIST?"}))
    for cmd, wait in (("SCAN7", 25), ("LIST?", 2), ("SCAN32", 70), ("LIST?", 2)):
        r = call({ACT: KEY, KEY: cmd})
        show(cmd, r)
        time.sleep(wait)
        if cmd != "LIST?":
            show("  after %s LIST?" % cmd, call({ACT: KEY, KEY: "LIST?"}))
    show("WHY?", call({ACT: KEY, KEY: "WHY?"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
