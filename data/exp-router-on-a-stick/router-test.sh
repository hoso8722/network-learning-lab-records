#!/usr/bin/env bash
# 実験3: Router-on-a-Stick（AlmaLinux VM をルーターにして、VLAN 間ルーティングを確認する）
#
# 対象ノード : client / server / switch / router（各 AlmaLinux 9 VM）
# 使い方     : ./router-test.sh <client|server|switch|router> <action> [arg]
#
# 構成:
#   client(enp0s9, 192.168.110.10/24) -[sw-p1]- switch enp0s8（アクセス VLAN 10）
#   server(enp0s9, 192.168.120.20/24) -[sw-p2]- switch enp0s9（アクセス VLAN 20）
#   router(enp0s8) -[sw-p3]- switch enp0s10（トランク VLAN 10,20 タグ付き）
#   router: enp0s8.10 = 192.168.110.1/24, enp0s8.20 = 192.168.120.1/24
#   client は 192.168.120.0/24 宛の静的ルート（via 192.168.110.1）、server は 192.168.110.0/24 宛（via 192.168.120.1）。
#   ※ NAT 側の既定ルートを壊さないよう、既定ゲートウェイではなく静的ルートを使う。
#
# actions:
#   switch : prepare | build | show | p3-vlan20 <off|on> | teardown
#   router : prepare | fwd <on|off> | fw-zone <on|off> | capture | teardown
#   client : prepare | ping-gw | ping-peer | trace | teardown
#   server : prepare | ping-gw | ping-peer | trace | teardown
#
# 状態変更の方針: ip / bridge / nmcli device set / sysctl -w（再起動で元に戻る範囲）。永続設定は変更しない。
# ホスト名: 役割と一致しなければ全操作を中止する（例外なし）。switch / router のVMは、事前にホスト名を設定しておくこと。
# 注記: switch prepare の `ip addr flush` は、目的=クローン元のIPをポートから外す / 影響=該当ポートのみ /
#       復旧=再起動または nmcli connection up。teardown の `ip link del br0` は、復旧=build の再実行。
# firewall の変更（router fw-zone）:
#   対象=router の firewalld（実行時の設定のみ。--permanent なし） / 内容=enp0s8.10 と enp0s8.20 を internal ゾーンに入れる(on)/外す(off)
#   影響=2つのサブインターフェース間の転送がゾーンの forward 設定（internal は yes）にしたがって許可される。public（NAT側）には入れない
#   復旧=fw-zone off、または sudo firewall-cmd --reload（実行時の変更が破棄される）。永続化は未検証。
# 合否は判定しない。結果（終了コードと出力）を記録するのみ。

set -u
set -o pipefail   # body | tee のパイプで、body の終了コード（中止の 4 など）を隠さない
role="${1:-}"; action="${2:-}"; arg="${3:-}"
P1=enp0s8; P2=enp0s9; P3=enp0s10   # switch のポート名（要確認: ip -br link）
RIF=enp0s8                          # router の NIC（トランク側）
HIF=enp0s9                          # client / server の NIC
ts=$(date +%Y%m%dT%H%M%S)   # 実行ごとに別のファイル名にする（同名の上書きを防ぐ）
out="exp3-${role}-${action}${arg:+-$arg}-${ts}.txt"
pcap="exp3-router-${ts}.pcap"

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
need_if() { for i in "$@"; do ip link show "$i" >/dev/null 2>&1 || { echo "インターフェース $i が見つかりません。ip -br link で確認してください"; exit 3; }; done; }
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }

body() {
  echo "# exp3 ${role} ${action} ${arg}  $(date -Is)  host=$(hostname -s)"
  # 誤実行の防止: 第1引数の役割と、このVMのホスト名が一致しなければ、何もせずに中止する（例外なし）。
  # 前提: switch / router の VM は、事前にホスト名が switch / router に設定されていること。
  case "$role" in client|server|switch|router) ;; *) usage;; esac
  if [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"; exit 4
  fi
  echo "# ホスト名の確認: OK（host=$(hostname -s) と role=$role が一致）"
  case "$role:$action" in
    switch:prepare)
      need_if $P1 $P2 $P3
      for p in $P1 $P2 $P3; do
        run sudo nmcli device set $p managed no
        run sudo ip addr flush dev $p
        run sudo ip link set $p up
      done
      run ip -br link;;
    switch:build)
      run sudo ip link add name br0 type bridge vlan_filtering 1 vlan_default_pvid 0
      for p in $P1 $P2 $P3; do run sudo ip link set $p master br0; done
      run sudo ip link set br0 up
      run sudo bridge vlan add vid 10 dev $P1 pvid untagged
      run sudo bridge vlan add vid 20 dev $P2 pvid untagged
      run sudo bridge vlan add vid 10 dev $P3
      run sudo bridge vlan add vid 20 dev $P3
      run bridge vlan show;;
    switch:show)
      run bridge vlan show
      run bridge fdb show br br0;;
    switch:p3-vlan20)
      case "$arg" in
        off) run sudo bridge vlan del vid 20 dev $P3;;
        on)  run sudo bridge vlan add vid 20 dev $P3;;
        *) usage;;
      esac
      run bridge vlan show;;
    switch:teardown)
      run sudo ip link del br0
      for p in $P1 $P2 $P3; do run sudo nmcli device set $p managed yes; done
      run ip -br link;;

    router:prepare)
      need_if $RIF
      run sudo nmcli device set $RIF managed no
      run sudo ip addr flush dev $RIF
      run sudo ip link set $RIF up
      run sudo ip link add link $RIF name ${RIF}.10 type vlan id 10
      run sudo ip link add link $RIF name ${RIF}.20 type vlan id 20
      run sudo ip addr add 192.168.110.1/24 dev ${RIF}.10
      run sudo ip addr add 192.168.120.1/24 dev ${RIF}.20
      run sudo ip link set ${RIF}.10 up
      run sudo ip link set ${RIF}.20 up
      run sysctl net.ipv4.ip_forward
      run ip -br addr;;
    router:fwd)
      case "$arg" in
        on)  run sudo sysctl -w net.ipv4.ip_forward=1;;
        off) run sudo sysctl -w net.ipv4.ip_forward=0;;
        *) usage;;
      esac;;
    router:fw-zone)
      case "$arg" in
        on)  run sudo firewall-cmd --zone=internal --add-interface=${RIF}.10
             run sudo firewall-cmd --zone=internal --add-interface=${RIF}.20;;
        off) run sudo firewall-cmd --zone=internal --remove-interface=${RIF}.10
             run sudo firewall-cmd --zone=internal --remove-interface=${RIF}.20;;
        *) usage;;
      esac
      run sudo firewall-cmd --get-active-zones;;
    router:capture)
      command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump が未導入です。NAT 有効で sudo dnf install -y tcpdump"; exit 5; }
      echo "### \$ sudo timeout -s INT 25 tcpdump -i $RIF -n -e -w $pcap   (25秒以内に client から server へ ping)"
      sudo timeout -s INT 25 tcpdump -i $RIF -n -e -w $pcap 2>&1
      echo; echo "### \$ tcpdump -n -e -r $pcap"
      tcpdump -n -e -r $pcap 2>&1;;
    router:teardown)
      run sudo firewall-cmd --zone=internal --remove-interface=${RIF}.10   # 未割り当てならエラーでよい
      run sudo firewall-cmd --zone=internal --remove-interface=${RIF}.20
      run sudo ip link del ${RIF}.10
      run sudo ip link del ${RIF}.20
      run sudo sysctl -w net.ipv4.ip_forward=0
      run sudo nmcli device set $RIF managed yes
      run ip -br addr;;

    client:prepare|server:prepare)
      need_if $HIF
      if [ "$role" = client ]; then me=192.168.110.10; gw=192.168.110.1; net=192.168.120.0/24
      else me=192.168.120.20; gw=192.168.120.1; net=192.168.110.0/24; fi
      run sudo nmcli device set $HIF managed no
      run sudo ip link set $HIF up
      run sudo ip addr add ${me}/24 dev $HIF
      run sudo ip route add $net via $gw dev $HIF
      run ip -br addr
      run ip route;;
    client:ping-gw)   run ping -c 3 -W 2 192.168.110.1;;
    server:ping-gw)   run ping -c 3 -W 2 192.168.120.1;;
    client:ping-peer) run ping -c 3 -W 2 192.168.120.20;;
    server:ping-peer) run ping -c 3 -W 2 192.168.110.10;;
    client:trace)     run tracepath -n 192.168.120.20;;
    server:trace)     run tracepath -n 192.168.110.10;;
    client:teardown|server:teardown)
      if [ "$role" = client ]; then me=192.168.110.10; net=192.168.120.0/24
      else me=192.168.120.20; net=192.168.110.0/24; fi
      run sudo ip route del $net dev $HIF
      run sudo ip addr del ${me}/24 dev $HIF
      run sudo nmcli device set $HIF managed yes
      run ip -br addr;;
    *) usage;;
  esac
}

body | tee "$out"
rc=${PIPESTATUS[0]}
# 引数の誤り（usage、終了コード 2）は、記録を残さない。ホスト名の不一致（4）などは、安全上の記録として残す
[ "$rc" -eq 2 ] && rm -f "$out"
exit "$rc"
