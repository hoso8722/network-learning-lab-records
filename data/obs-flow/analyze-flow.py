#!/usr/bin/env python3
"""conntrack の累積(packets=、bytes=)の行と、ip -s link のカウンターを、run1-router.txt から読み、比較する。標準ライブラリのみ。
使い方: python3 data/obs-flow/analyze-flow.py
"""
import re
L = open('data/obs-flow/run1-router.txt', encoding='utf-8').read().split('\n')
FILES = {'1 MB': 1048576, '10 MB': 10485760, '100 MB': 104857600}
rows = []
for l in L:
    m = re.match(r'^(tcp|icmp)\s+\d+\s+(\d+)\s*(\S*)\s.*?(?:sport=(\d+) dport=(\d+)|type=8 code=0 id=(\d+)) packets=(\d+) bytes=(\d+) .*?(?:sport=\d+ dport=\d+|type=0 code=0 id=\d+) packets=(\d+) bytes=(\d+)', l)
    if m: rows.append((m.group(1), ('' if m.group(3).startswith('src=') else m.group(3)), m.group(4) or m.group(6), int(m.group(7)), int(m.group(8)), int(m.group(9)), int(m.group(10))))
print('conntrack の行(要求の向き: client → server、応答の向き: server → client)')
print('種類 状態        sport/id  要求 packets  要求 bytes  応答 packets  応答 bytes  応答 bytes/packet')
seen = set()
for r in rows:
    k = (r[0], r[2], r[3], r[5])
    if k in seen: continue
    seen.add(k)
    print(f'{r[0]:4s} {r[1] or "-":11s} {r[2]:8s} {r[3]:12d} {r[4]:11d} {r[5]:13d} {r[6]:11d} {r[6] / r[5]:10.1f}')
print()
print('ファイルの大きさと、応答の向きの bytes の比')
for r in rows:
    if r[0] == 'tcp':
        for n, sz in FILES.items():
            if 0.95 * sz < r[6] < 1.1 * sz:
                print(f'sport {r[2]}: 応答 {r[6]} バイト ÷ {n}({sz})= {r[6] / sz:.4f}(packets {r[5]})'); break
print()
# ip -s link(enp0s9)の RX
snaps = []
for i, l in enumerate(L):
    if l.startswith('### $ ip -s link show enp0s9'):
        m = re.match(r'^\s+(\d+)\s+(\d+)\s', L[i + 4]); snaps.append((int(m.group(1)), int(m.group(2))))
print('ip -s link show enp0s9 の RX(bytes、packets)の、記録の順:', snaps)
b = snaps
print(f'GRO on の 100 MB(1 回目の前 → GRO を切った直後。ダウンロードは、この間に終わった): RX の増加 {b[2][0] - b[0][0]} バイト、{b[2][1] - b[0][1]} パケット(1 パケット {(b[2][0] - b[0][0]) / (b[2][1] - b[0][1]):.1f} バイト)')
print(f'GRO off の 100 MB(切った直後 → 後。ダウンロードの途中): RX の増加 {b[3][0] - b[2][0]} バイト、{b[3][1] - b[2][1]} パケット(1 パケット {(b[3][0] - b[2][0]) / (b[3][1] - b[2][1]):.1f} バイト)')
