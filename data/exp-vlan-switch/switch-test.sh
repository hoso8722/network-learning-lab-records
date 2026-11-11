#!/usr/bin/env bash
# 実験2: AlmaLinux VM を VLAN スイッチ(Linux bridge の VLAN フィルタリング)にして、
#        VLAN の分離・トランクの許可 VLAN・タグ・MTU を確認する
#
# 対象ノード : switch(クローンVM) / client / server
# 使い方     : ./switch-test.sh <switch|client|server> <action> [arg]
#
# 構成(内部ネットワーク名):
#   client enp0s9 ---[sw-p1]--- switch enp0s8(P1: トランク。VLAN 10,20 をタグ付きで通す)
#   server enp0s9 ---[sw-p2]--- switch enp0s9(P2: アクセス。VLAN 10 または 20、タグなし)
#   client は enp0s9.10(192.168.110.10/24) と enp0s9.20(192.168.120.10/24) のサブインターフェースを持つ。
#   server は enp0s9 に 192.168.110.20/24 と 192.168.120.20/24 の両方を持つ(タグなし)。
#
# actions:
#   switch : prepare | build | show | server-vlan <10|20> | p1-vlan20 <off|on> | teardown
#   client : prepare | ping10 | ping20 | mtu | tagcap | teardown
#   server : prepare | capture | teardown
#
# 状態変更の方針: すべて ip / bridge / nmcli device set(再起動で元に戻る範囲)。永続設定は変更しない。
# 例外: switch prepare で hostnamectl によりホスト名を switch に変更する(永続。復旧は元の名前に再設定)。
#
# 重要な状態変更の注記:
#   switch prepare の `ip addr flush`: 目的=クローン元のIPをポートから外す / 影響=enp0s8,enp0s9 のアドレスのみ /
#     復旧=再起動(NetworkManager の設定が再適用される)または nmcli connection up。
#   switch teardown の `ip link del br0`: 目的=実験用ブリッジの削除 / 影響=スイッチ機能の停止 / 復旧=build を再実行。
#
# このスクリプトは合否を判定しない。実行結果(終了コードと出力)を記録するのみ。

set -u
set -o pipefail   # body | tee のパイプで、body の終了コード（中止の 4 など）を隠さない
role="${1:-}"; action="${2:-}"; arg="${3:-}"
P1=enp0s8; P2=enp0s9; HIF=enp0s9
ts=$(date +%Y%m%dT%H%M%S)   # 実行ごとに別のファイル名にする（同名の上書きを防ぐ）
out="exp2-${role}-${action}${arg:+-$arg}-${ts}.txt"

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
need_if() {
  for i in "$@"; do
    ip link show "$i" >/dev/null 2>&1 || { echo "インターフェース $i が見つかりません。ip -br link で確認してください"; exit 3; }
  done
}
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }

body() {
  echo "# exp2 ${role} ${action} ${arg}  $(date -Is)  host=$(hostname -s)"
  # 別の VM で実行する事故を防ぐ。switch prepare はホスト名を switch に変更する最初の操作なので除外する
  if [ "$role:$action" != "switch:prepare" ] && [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"
    exit 4
  fi
  case "$role:$action" in
    switch:prepare)
      need_if $P1 $P2
      run sudo hostnamectl set-hostname switch
      run sudo nmcli device set $P1 managed no
      run sudo nmcli device set $P2 managed no
      run sudo ip addr flush dev $P1
      run sudo ip addr flush dev $P2
      run sudo ip link set $P1 up
      run sudo ip link set $P2 up
      run ip -br link
      run ip -br addr;;
    switch:build)
      need_if $P1 $P2
      run sudo ip link add name br0 type bridge vlan_filtering 1 vlan_default_pvid 0
      run sudo ip link set $P1 master br0
      run sudo ip link set $P2 master br0
      run sudo ip link set br0 up
      run sudo bridge vlan add vid 10 dev $P1
      run sudo bridge vlan add vid 20 dev $P1
      run sudo bridge vlan add vid 10 dev $P2 pvid untagged
      run bridge vlan show;;
    switch:show)
      run bridge vlan show
      run bridge fdb show br br0
      run ip -d link show br0
      run ip -br link;;
    switch:server-vlan)
      [ "$arg" = 10 ] || [ "$arg" = 20 ] || usage
      run sudo bridge vlan del vid 10 dev $P2
      run sudo bridge vlan del vid 20 dev $P2
      run sudo bridge vlan add vid "$arg" dev $P2 pvid untagged
      run bridge vlan show;;
    switch:p1-vlan20)
      case "$arg" in
        off) run sudo bridge vlan del vid 20 dev $P1;;
        on)  run sudo bridge vlan add vid 20 dev $P1;;
        *) usage;;
      esac
      run bridge vlan show;;
    switch:teardown)
      run sudo ip link del br0
      run sudo nmcli device set $P1 managed yes
      run sudo nmcli device set $P2 managed yes
      run ip -br link;;

    client:prepare)
      need_if $HIF
      run sudo nmcli device set $HIF managed no
      run sudo ip link set $HIF up
      run sudo ip link add link $HIF name ${HIF}.10 type vlan id 10
      run sudo ip link add link $HIF name ${HIF}.20 type vlan id 20
      run sudo ip addr add 192.168.110.10/24 dev ${HIF}.10
      run sudo ip addr add 192.168.120.10/24 dev ${HIF}.20
      run sudo ip link set ${HIF}.10 up
      run sudo ip link set ${HIF}.20 up
      run ip -br addr;;
    client:ping10) run ping -c 3 -W 2 -I ${HIF}.10 192.168.110.20;;
    client:ping20) run ping -c 3 -W 2 -I ${HIF}.20 192.168.120.20;;
    client:mtu)
      echo "# 1472 バイト + ヘッダ28 = 1500 バイトの IP パケットを、フラグメント禁止(-M do)で送る"
      run ping -c 2 -W 2 -M do -s 1472 -I ${HIF}.10 192.168.110.20;;
    client:tagcap)
      command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump が未導入です。NAT 有効の状態で sudo dnf install -y tcpdump を実行してください"; exit 5; }
      echo "### \$ sudo timeout -s INT 12 tcpdump -i $HIF -n -e -w exp2-client-${ts}.pcap   (バックグラウンド)"
      sudo timeout -s INT 12 tcpdump -i $HIF -n -e -w exp2-client-${ts}.pcap 2>&1 &
      sleep 2
      run ping -c 3 -W 2 -I ${HIF}.10 192.168.110.20
      run ping -c 3 -W 2 -I ${HIF}.20 192.168.120.20
      wait
      echo "### \$ tcpdump -n -e -r exp2-client-${ts}.pcap"
      tcpdump -n -e -r exp2-client-${ts}.pcap 2>&1;;
    client:teardown)
      run sudo ip link del ${HIF}.10
      run sudo ip link del ${HIF}.20
      run sudo nmcli device set $HIF managed yes
      run ip -br addr;;

    server:prepare)
      need_if $HIF
      run sudo nmcli device set $HIF managed no
      run sudo ip link set $HIF up
      run sudo ip addr add 192.168.110.20/24 dev $HIF
      run sudo ip addr add 192.168.120.20/24 dev $HIF
      run ip -br addr;;
    server:capture)
      command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump が未導入です。NAT 有効の状態で sudo dnf install -y tcpdump を実行してください"; exit 5; }
      echo "### \$ sudo timeout -s INT 25 tcpdump -i $HIF -n -e -w exp2-server-${ts}.pcap   (25秒以内に client から ping を実行)"
      sudo timeout -s INT 25 tcpdump -i $HIF -n -e -w exp2-server-${ts}.pcap 2>&1
      echo
      echo "### \$ tcpdump -n -e -r exp2-server-${ts}.pcap"
      tcpdump -n -e -r exp2-server-${ts}.pcap 2>&1;;
    server:teardown)
      run sudo ip addr del 192.168.110.20/24 dev $HIF
      run sudo ip addr del 192.168.120.20/24 dev $HIF
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
