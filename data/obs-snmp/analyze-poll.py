#!/usr/bin/env python3
"""実験 2(折り返し)の、server のポーリングの記録(run1-server.txt の poll-snmp の出力)から、区間ごとの増加量を計算する。標準ライブラリのみ。
使い方: python3 data/obs-snmp/analyze-poll.py [run1-server.txt]
出力: 区間ごとの、32 ビットと 64 ビットのカウンターの増加(IN: enp0s9 の受信、OUT: enp0s8 の送信)、折り返しの検出、合計の比較。
"""
import re, sys
path = sys.argv[1] if len(sys.argv) > 1 else 'data/obs-snmp/run1-server.txt'
L = open(path, encoding='utf-8').read().split('\n')
i = next(k for k, l in enumerate(L) if l.startswith('### $ cat ~/poll-snmp.txt'))
j = next(k for k, l in enumerate(L) if k > i and l.startswith('### '))
OID = {'2.2.1.10.4': 'in32', '31.1.1.1.6.4': 'in64', '2.2.1.16.3': 'out32', '31.1.1.1.10.3': 'out64'}
rows = []; cur = None
for l in L[i + 1:j]:
    if re.match(r'^\d\d:\d\d:\d\d$', l): cur = {'t': l}; rows.append(cur); continue
    if cur is None: continue
    m = re.match(r'^\.1\.3\.6\.1\.2\.1\.1\.3\.0 (\d+):(\d+):(\d+):(\d+)\.(\d+)$', l)
    if m: d, h, mi, s, c = map(int, m.groups()); cur['up'] = ((d * 24 + h) * 60 + mi) * 60 + s + c / 100; continue
    m = re.match(r'^\.1\.3\.6\.1\.2\.1\.(' + '|'.join(re.escape(k) for k in OID) + r') (\d+)$', l)
    if m: cur[OID[m.group(1)]] = int(m.group(2))
rows = [r for r in rows if len(r) == 6]
W = 2 ** 32
print(f'ポーリング {len(rows)} 回: {rows[0]["t"]} 〜 {rows[-1]["t"]}(sysUpTime の差 {rows[-1]["up"] - rows[0]["up"]:.2f} 秒)')
print('時刻      間隔(秒)  IN32の差      IN64の差      OUT32の差      OUT64の差      備考')
wraps = {'in': 0, 'out': 0}
for a, b in zip(rows, rows[1:]):
    dt = b['up'] - a['up']; di32 = b['in32'] - a['in32']; di64 = b['in64'] - a['in64']; do32 = b['out32'] - a['out32']; do64 = b['out64'] - a['out64']
    note = []
    if di32 < 0: wraps['in'] += 1; note.append(f'IN32 が減った(折り返し。補正 {di32 + W})')
    if do32 < 0: wraps['out'] += 1; note.append(f'OUT32 が減った(折り返し。補正 {do32 + W}、OUT64 の差と{"一致" if do32 + W == do64 else "不一致"})')
    print(f'{b["t"]}  {dt:6.2f}  {di32:12d}  {di64:12d}  {do32:13d}  {do64:13d}  {"; ".join(note)}')
f, l = rows[0], rows[-1]
print()
for k in ('in', 'out'):
    t64 = l[k + '64'] - f[k + '64']; n32 = l[k + '32'] - f[k + '32']
    print(f'{k.upper()}: 64 ビットの合計 {t64} / 32 ビットの差(最初と最後だけ。補正なし){n32} / 5 秒おきの折り返し {wraps[k]} 回 / 補正した合計 {n32 + wraps[k] * W}({"64 ビットと一致" if n32 + wraps[k] * W == t64 else "不一致"})')
print(f'最初と最後だけ(約 {l["up"] - f["up"]:.0f} 秒間隔)で、OUT を 32 ビットで引くと {(l["out32"] - f["out32"]) % W}、64 ビットでは {l["out64"] - f["out64"]}(折り返し {(l["out64"] - f["out64"]) // W} 回分が、見えない)')
