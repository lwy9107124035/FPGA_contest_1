import json
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

def bits():
    p = api({"action": "poll", "since": 999999})
    st = p.get("status") or {}
    return st.get("bits", "????????"), st

cur = "-"
bad = 0
t0 = time.time()
for i in range(15):
    api({"action": "cmd", "cmd": "NEXT"})
    ok_load = False
    for _ in range(6):                      # 最多等 ~9s
        time.sleep(1.5)
        b, st = bits()
        lst = api({"action": "cmd", "cmd": "LIST?"}).get("resp", "")
        parts = lst.split()
        c = parts[2] if len(parts) > 2 else "?"
        # 帧写完 或 (源传完且不在加载) 都算这步 OK
        if len(b) == 8 and b[3] == "1" and b[5] == "0":
            ok_load = True
            break
    tag = "OK " if ok_load else "TIMEOUT"
    if not ok_load:
        bad += 1
    print("[%2ds] img#%s -> LIST cur=%s bits=%s %s" % (time.time() - t0, i, c, b, tag))
    cur = c
print("== 走查完成: %d/15 张加载确认, 卡点 %d ==" % (15 - bad, bad))
print("final poll:", json.dumps(bits()[1], ensure_ascii=False)[:260])
