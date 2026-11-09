#!/usr/bin/env bash
# 実験4: ルーター2台と静的ルート（複数サブネット、経路欠落・戻り経路の欠落の確認）
#
# 対象ノード : client / server / router(R1) / router2(R2)（各 AlmaLinux 9 VM）
# 使い方     : ./route-test.sh <client|server|router|router2> <action> [args...]
#
# 構成（アドレスは実験用。仕様の例示 192.168.10.0/24 等は既存の poc1-lan と重なるため使わない）:
#   client(enp0s9 192.168.31.10/24) -[lan-a]- R1 enp0s8 192.168.31.1/24
#   R1 enp0s9 192.168.30.1/30 -[transit]- R2 enp0s8 192.168.30.2/30
#   R2 enp0s9 192.168.32.1/24 -[lan-b]- server(enp0s9 192.168.32.20/24)
#   client は 192.168.32.0/24 宛 via 192.168.31.1、server は 192.168.31.0/24 宛 via 192.168.32.1
#   R1 は 192.168.32.0/24 宛 via 192.168.30.2（route add で設定）、R2 は 192.168.31.0/24 宛 via 192.168.30.1（同）
#
# actions:
#   client|server : prepare | ping-gw | ping-peer | trace | teardown
#   router|router2: prepare | fwd <on|off> | fw-zone <on|off> | defroute <off|on> | route <add|del> <ネットワーク/長さ> <次ホップ> | ping <IP> | show | capture | teardown
#
# 状態変更の方針: ip / sysctl -w / nmcli device set / firewall-cmd（実行時のみ）。再起動で元に戻る範囲。永続設定は変更しない。
# firewall の変更（fw-zone）: 対象=該当ルーターの firewalld（実行時のみ） / 内容=2つのインターフェースを internal ゾーンへ(on)/外す(off)
#   影響=2つのインターフェース間の転送が許可される（public(NAT側)には入れない） / 復旧=fw-zone off、または firewall-cmd --reload
# ホスト名: 役割と一致しなければ全操作を中止する（例外なし）。router2 の VM は事前にホスト名を router2 に設定しておくこと。
# 合否は判定しない。結果（終了コードと出力）を記録するのみ。

set -u
set -o pipefail
role="${1:-}"; action="${2:-}"; a3="${3:-}"; a4="${4:-}"; a5="${5:-}"
IFA=enp0s8; IFB=enp0s9     # router/router2 の NIC（要確認: ip -br link）。client/server は IFB（enp0s9）を使う
HIF=enp0s9
ts=$(date +%Y%m%dT%H%M%S)
out="exp4-${role}-${action}${a3:+-${a3//\//_}}-${ts}.txt"
pcap="exp4-${role}-${ts}.pcap"

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
need_if() { for i in "$@"; do ip link show "$i" >/dev/null 2>&1 || { echo "インターフェース $i が見つかりません。ip -br link で確認してください"; exit 3; }; done; }
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }

body() {
  echo "# exp4 ${role} ${action} ${a3} ${a4}  $(date -Is)  host=$(hostname -s)"
  case "$role" in client|server|router|router2) ;; *) usage;; esac
  if [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"; exit 4
  fi
  echo "# ホスト名の確認: OK（host=$(hostname -s) と role=$role が一致）"
  case "$role:$action" in
    client:prepare|server:prepare)
      need_if $HIF
      if [ "$role" = client ]; then me=192.168.31.10; gw=192.168.31.1; net=192.168.32.0/24
      else me=192.168.32.20; gw=192.168.32.1; net=192.168.31.0/24; fi
      run sudo nmcli device set $HIF managed no
      run sudo ip link set $HIF up
      run sudo ip addr add ${me}/24 dev $HIF
      run sudo ip route add $net via $gw dev $HIF
      run ip -br addr
      run ip route;;
    client:ping-gw)   run ping -c 3 -W 2 192.168.31.1;;
    server:ping-gw)   run ping -c 3 -W 2 192.168.32.1;;
    client:ping-peer) run ping -c 3 -W 2 192.168.32.20;;
    server:ping-peer) run ping -c 3 -W 2 192.168.31.10;;
    client:trace)     run tracepath -n 192.168.32.20;;
    server:trace)     run tracepath -n 192.168.31.10;;
    client:teardown|server:teardown)
      if [ "$role" = client ]; then me=192.168.31.10; net=192.168.32.0/24
      else me=192.168.32.20; net=192.168.31.0/24; fi
      run sudo ip route del $net dev $HIF
      run sudo ip addr del ${me}/24 dev $HIF
      run sudo nmcli device set $HIF managed yes
      run ip -br addr;;

    router:prepare|router2:prepare)
      need_if $IFA $IFB
      if [ "$role" = router ]; then a=192.168.31.1/24; b=192.168.30.1/30; else a=192.168.30.2/30; b=192.168.32.1/24; fi
      for i in $IFA $IFB; do run sudo nmcli device set $i managed no; run sudo ip addr flush dev $i; run sudo ip link set $i up; done
      run sudo ip addr add $a dev $IFA
      run sudo ip addr add $b dev $IFB
      run sysctl net.ipv4.ip_forward
      run ip -br addr;;
    router:fwd|router2:fwd)
      case "$a3" in on) run sudo sysctl -w net.ipv4.ip_forward=1;; off) run sudo sysctl -w net.ipv4.ip_forward=0;; *) usage;; esac;;
    router:fw-zone|router2:fw-zone)
      case "$a3" in
        # --add-interface は、すでに別ゾーン(public)に属するインターフェースで ZONE_CONFLICT になる（2026-10-23 に実測）。
        # --change-interface で移す。on の後は enp0s8/enp0s9 とも internal、enp0s3(NAT)だけが public。
        on)  run sudo firewall-cmd --zone=internal --change-interface=$IFA
             run sudo firewall-cmd --zone=internal --change-interface=$IFB;;
        off) run sudo firewall-cmd --zone=public --change-interface=$IFA
             run sudo firewall-cmd --zone=public --change-interface=$IFB;;
        *) usage;;
      esac
      run sudo firewall-cmd --get-active-zones;;
    router:defroute|router2:defroute)
      # NAT の既定ルートを実行時だけ外す/戻す。ルーターの転送を有効にした状態で既定ルートが残っていると、
      # 経路がない宛先のラボの通信が NAT 側へ漏れる（実験4で観測）。SSH は 10.0.2.0/24 の直結で継続できる。
      case "$a3" in
        off) run sudo ip route del default via 10.0.2.2 dev enp0s3;;
        on)  run sudo ip route add default via 10.0.2.2 dev enp0s3 metric 100;;
        *) usage;;
      esac
      run ip route;;
    router:route|router2:route)
      [ -n "$a4" ] && [ -n "$a5" ] || usage
      case "$a3" in
        add) run sudo ip route add "$a4" via "$a5";;
        del) run sudo ip route del "$a4" via "$a5";;
        *) usage;;
      esac
      run ip route;;
    router:ping|router2:ping)
      [ -n "$a3" ] || usage
      run ping -c 3 -W 2 "$a3";;
    router:show|router2:show)
      run ip -br addr
      run ip route
      run sysctl net.ipv4.ip_forward
      run sudo firewall-cmd --get-active-zones;;
    router:capture|router2:capture)
      command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump が未導入です。NAT 有効で sudo dnf install -y tcpdump（クローン元には入っている）"; exit 5; }
      echo "### \$ sudo timeout -s INT 25 tcpdump -i any -n -w $pcap 'not tcp port 22'   (25秒以内に client から server へ ping。SSH は除外)"
      sudo timeout -s INT 25 tcpdump -i any -n -w $pcap 'not tcp port 22' 2>&1
      echo; echo "### \$ tcpdump -n -r $pcap"
      tcpdump -n -r $pcap 2>&1;;
    router:teardown|router2:teardown)
      run sudo firewall-cmd --reload     # 実行時のゾーン変更を破棄し、永続設定（enp0s8 は public）に戻す
      # 既定ルートが無いときだけ戻す（DHCP 由来の既定ルートが既にあると、replace は別エントリを追加して二重になる: 2026-10-23 に router で観測）
      if [ -z "$(ip route show default)" ]; then run sudo ip route add default via 10.0.2.2 dev enp0s3 metric 100; else echo "既定ルートあり（復旧不要）"; fi
      run sudo sysctl -w net.ipv4.ip_forward=0
      for i in $IFA $IFB; do run sudo ip addr flush dev $i; run sudo nmcli device set $i managed yes; done
      run ip -br addr;;
    *) usage;;
  esac
}

body | tee "$out"
rc=${PIPESTATUS[0]}
# 引数の誤り（usage、終了コード 2）は、記録を残さない。ホスト名の不一致（4）などは、安全上の記録として残す
[ "$rc" -eq 2 ] && rm -f "$out"
exit "$rc"
