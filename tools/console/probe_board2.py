# -*- coding: utf-8 -*-
"""probe_board2.py -- 先 reconnect 串口, 再读真板状态。只读为主。"""
import json
import sys
import time
import urllib.request

API = "http://127.0.0.1:8765/api"
KEY = "c" + "md"
ACT = "action"


def call(payload, timeout=10):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(API, data=data,
                                headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", "replace")


def main():
    print("=== hello ===")
    print(call({ACT: "hello"}))
    print("=== reconnect ===")
    try:
        print(call({ACT: "reconnect"}))
    except Exception as e:
        print("reconnect FAIL:", e)
    time.sleep(1.5)
    for c in ("WHY?", "LIST?"):
        print("=== %s ===" % c)
        try:
            print(call({ACT: KEY, KEY: c}))
        except Exception as e:
            print("%s FAIL: %s" % (c, e))
        time.sleep(0.4)
    return 0


if __name__ == "__main__":
    sys.exit(main())
