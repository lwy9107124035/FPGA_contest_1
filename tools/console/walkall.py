# walkall.py — v10.3b-18 验收走查：SCAN32 自动开池后，NEXT 应走遍全部已登记图。
# 用法: C:\Users\lwy\miniconda3\envs\fpga_batch\python.exe -u walkall.py  （播控台需已启动）
import json
import sys
import time
import urllib.request


def api(body):
    req = urllib.request.Request(
        "http://127.0.0.1:8765/api",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read().decode())


def lst():
    return api({"action": "cmd", "cmd": "LIST?"}).get("resp", "").split()


try:
    if len(sys.argv) > 1 and sys.argv[1] == "--no-scan":
        pass
    else:
        api({"action": "cmd", "cmd": "SC 1"})
        api({"action": "cmd", "cmd": "SCAN32"})
        t0 = time.time()
        while time.time() - t0 < 90:
            time.sleep(4)
            p = lst()
            n = int(p[1], 16) if len(p) > 1 else 0
            done = (api({"action": "poll", "since": 99999999})
                    .get("status") or {}).get("scan_ok")
            print("[%3ds] LIST=%s scan_ok=%s" % (time.time() - t0, " ".join(p), done))
            if done and n >= 13:
                break
    p = lst()
    total = int(p[1], 16)
    # b-19 教训修正：total=0（空窗/风暴态抓到的瞬间）时 need=∅ 会假 PASS——必须硬门槛
    if total < 1:
        print("== FAIL: 登记数为 0（扫描未落定或板处风暴态），走查前提不成立 ==")
        sys.exit(1)
    print("== 登记 %d 张，开始 NEXT 全走 ==" % total)
    seen = set()
    for k in range(total + 3):          # 全环 + 回绕余量
        api({"action": "cmd", "cmd": "NEXT"})
        time.sleep(2.5)      # 装载期 ~0.55s+切换窗；1.2s 实测会被吞（板子装载保护）
        cur = int(lst()[2], 16)
        seen.add(cur)
        sys.stdout.write(".")
        sys.stdout.flush()
    print()
    need = set(range(total))
    print("到达过 %d 个不同槽位: %s" % (len(seen), sorted(seen)))
    if need <= seen:
        print("== PASS: NEXT 走遍全部 %d 张（播放池已开）==" % total)
    else:
        print("== FAIL: 缺槽位 %s ==" % sorted(need - seen))
except Exception as e:
    print("!! 走查中断（播控台在跑吗？）：", e)
    sys.exit(2)
