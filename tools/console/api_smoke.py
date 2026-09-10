import json
import urllib.request

def api(body):
    req = urllib.request.Request(
        "http://127.0.0.1:8765/api",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=8) as r:
        return json.loads(r.read().decode())

print("hello:", json.dumps(api({"action": "hello"}), ensure_ascii=False)[:220])
print("poll :", json.dumps(api({"action": "poll"}), ensure_ascii=False)[:220])
for c in ["LIST?", "INFO?"]:
    try:
        print(c, "->", json.dumps(api({"action": "cmd", "cmd": c}), ensure_ascii=False)[:220])
    except Exception as e:
        print(c, "ERR", e)
