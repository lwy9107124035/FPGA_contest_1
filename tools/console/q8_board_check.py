# -*- coding: utf-8 -*-
"""Q8 v2 七步板测自动走查（命令串全部对齐板协议+console 白名单实测）
判"命令链+状态机"层面；转场/字幕/时钟等观感仍需人眼看显示器。
用法: python -X utf8 q8_board_check.py [--skip-scan]
"""
import json, time, urllib.request, sys

def api(b):
    r = urllib.request.Request('http://127.0.0.1:8765/api', data=json.dumps(b).encode(),
                               headers={'Content-Type': 'application/json'})
    return json.loads(urllib.request.urlopen(r, timeout=15).read().decode())

def cmd(c):
    try:
        d = api({'action': 'cmd', 'cmd': c})
        return d.get('resp', '') or d.get('error', '') or ''
    except Exception as e:
        return 'ERR %s' % e

R = [0, 0]
def ok(name, cond, detail=''):
    R[0 if cond else 1] += 1
    print(('[OK] ' if cond else '[XX] ') + name + (' | ' + str(detail)[:90] if detail else ''))

def fields():
    p = cmd('LIST?').split()
    try:
        return int(p[1], 16), int(p[2], 16), int(p[3], 16)
    except Exception:
        return None, None, None

def ack(name, c):
    ok(name, cmd(c).strip().upper().startswith('OK'), c)

skip_scan = '--skip-scan' in sys.argv
print('板当前:', cmd('LIST?'), cmd('WHY?'))

if not skip_scan:
    cmd('SC 1'); cmd('SCAN32')
    n, cur, dep = None, None, None
    t0 = time.time()
    while time.time() - t0 < 95:
        time.sleep(3)
        n, cur, dep = fields()
        if n and n >= 13:
            break
    ok('步0 SCAN32 登记>=13 且稳定', n is not None and n >= 13, '登记=%s' % (hex(n) if n is not None else '?'))
else:
    n, cur, dep = fields()
    ok('步0 已有登记', n and n >= 13, '登记=%s' % (hex(n) if n else '?'))

# 1 CK 时钟（带空格；人眼核屏幕右上角）
ack('步1 CK 1 时钟开', 'CK 1'); time.sleep(0.5)
ack('步1 CK 0 时钟关', 'CK 0')

# 2 字幕：速度档 + MSG 文本通道（COL 蓝 + 文字 + SR 2 滚动）
ack('步2 SR 2 字幕速度', 'SR 2')
try:
    d = api({'action': 'msg', 'text': '七步走查测试', 'col': 3})
    ok('步2 MSG 上屏 ack', d.get('ok') is True, str(d.get('acks', d))[:60])
except Exception as e:
    ok('步2 MSG 上屏 ack', False, e)
time.sleep(2)
ack('步2 SR 0 停滚动', 'SR 0')
cmd('CLR')

# 3 FD 转场方式（0直切1淡入2擦拭3百叶）+ NEXT 移动
ack('步3 FD 2 擦拭', 'FD 2')
c0 = fields()[1]
cmd('NEXT'); time.sleep(2.7)
c1 = fields()[1]
ok('步3 NEXT 光标移动(擦拭转场生效需人眼)', c0 != c1, '%s->%s' % (c0, c1))
ack('步3 FD 0 归直切', 'FD 0')

# 4 BR/GN
ack('步4 BR 5', 'BR 5'); ack('步4 GN 2', 'GN 2')
cmd('BR 0'); cmd('GN 0'); cmd('BR 5'); cmd('GN 5')

# 5 EMG 横幅 + CLR 解除 + VU 频谱柱开关
ack('步5 EMG1 弹应急', 'EMG1'); time.sleep(1.2)
ack('步5 VU 1 频谱开', 'VU 1'); time.sleep(1)
ack('步5 CLR 解除应急', 'CLR')
ack('步5 VU 0 频谱关', 'VU 0')

# 6 SC1 缩放走查：NEXT 轨迹（间隔≥2.5s 防吞）；只判"移动步数"，卡点交 tb_v103_load 分析
n0, _, _ = fields()
seen = []
for k in range(min(15, n0 or 13)):
    cmd('NEXT'); time.sleep(2.7)
    _, c, _ = fields()
    seen.append(c)
distinct = len(set(x for x in seen if x is not None))
print('  步6 NEXT 轨迹:', [hex(x) if x is not None else '?' for x in seen], cmd('WHY?'))
ok('步6 移动 >=8 档(b20 基准)', distinct >= 8, 'distinct=%d' % distinct)

# 7 归位（保持 SC 1——SC 0 下重扫只会登 6 张）
for c in ['BR 5', 'GN 5', 'FD 0', 'AUTO 0', 'CK 0', 'VU 0', 'SR 0', 'SC 1', 'PLYALL', 'CLR']:
    cmd(c)
cmd('SCAN32')
time.sleep(75)
n2, cur2, _ = fields()
ok('步7 SC1 归位后重扫仍 >=13', n2 and n2 >= 13, '登记=%s' % (hex(n2) if n2 else '?'))
print('终态:', cmd('LIST?'), cmd('WHY?'))
print('== Q8 v2 走查 %d OK / %d FAIL ==' % (R[0], R[1]))
