#!/usr/bin/env python3
"""追加の確認の記録(followup-*.txt)から、各 NIC の、ダウンロードの前後の ip -s link の RX/TX(バイト、パケット)の差を計算する。標準ライブラリのみ。
使い方: python3 data/obs-snmp/followup/analyze-hops.py
"""
import re, glob, os
base = os.path.dirname(os.path.abspath(__file__))
data = {}   # (node, nic) -> [ (rx_bytes, rx_pk, tx_bytes, tx_pk), ... ] (前、後)
for node in ('client', 'router', 'router2', 'server'):
    L = open(f'{base}/followup-{node}.txt', encoding='utf-8').read().split('\n')
    for i, l in enumerate(L):
        m = re.match(r'^\d+: (enp0s\d+):', l)
        if not m: continue
        rx = re.match(r'^\s+(\d+)\s+(\d+)\s', L[i + 3]); tx = re.match(r'^\s+(\d+)\s+(\d+)\s', L[i + 5])
        data.setdefault((node, m.group(1)), []).append((int(rx.group(1)), int(rx.group(2)), int(tx.group(1)), int(tx.group(2))))
order = [('server', 'enp0s9'), ('router2', 'enp0s9'), ('router2', 'enp0s8'), ('router', 'enp0s9'), ('router', 'enp0s8'), ('client', 'enp0s9')]
print('経路(server → client)の順。1 GiB = 1073741824 バイト')
print('NIC                 RXの増加(バイト)  TXの増加(バイト)  RXパケット  TXパケット  TXバイト/パケット  TX÷1GiB')
for k in order:
    b, a = data[k]
    drx, dtx, prx, ptx = a[0] - b[0], a[2] - b[2], a[1] - b[1], a[3] - b[3]
    print(f'{k[0]:8s} {k[1]:8s} {drx:16d} {dtx:16d} {prx:11d} {ptx:11d} {dtx / ptx if ptx else 0:16.1f} {dtx / 1073741824:9.3f}')
