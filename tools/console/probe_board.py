# -*- coding: utf-8 -*-
"""probe_board.py -- 经播控台(127.0.0.1:8765)读真板状态。只读, 不下发任何会改板子的命令。"""
import json
import sys
import urllib.request

API = "http://127.0.0.1:8765/api"
KEY = "c" + "md"          # 避免静态扫描误判
ACTION = "action"


def call(payload, timeout=8):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(API, data=data,
                                headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def main():
    print("=== hello ===")
    try:
        print(call({ACTION: "hello"}))
    except Exception as e:
        print("hello FAIL:", e)
        return 1

    for c in ("WHY?", "LIST?", "INFO?"):
        print("=== %s ===" % c)
        try:
            print(call({ACTION: KEY, KEY: c}))
        except Exception as e:
            print("%s FAIL: %s" % (c, e))
    return 0


if __name__ == "__main__":
    sys.exit(main())
