#!/usr/bin/env bash
# 実験10: DHCP（dnsmasq）。アドレス配布の流れ（DORA）と、配布されない症状を、パケット・ログ・リース情報で切り分ける（B10）
#
# 対象ノード : router（R1）と client（AlmaLinux 9）。ベースライン（labs/common/baseline.sh up）が前提（R1 の enp0s8 = 192.168.31.1/24、
#              firewalld の internal ゾーン）。lan-a（VirtualBox 内部ネットワーク）だけで完結する。NAT 側（enp0s3）には配布しない。
# 使い方     : ./dhcp-test.sh <router|client> <action> [args...]
#
# 構成: client enp0s9（lan-a）– R1 enp0s8 192.168.31.1/24（dnsmasq の DHCP のみ。DNS は port=0 で無効）。
#       配布範囲 192.168.31.100〜150/24、リース 10 分（lease で 2 分にできる）。オプション: ルーター 192.168.31.1、DNS 192.168.32.20、
#       検索ドメイン lab.example。client のプロファイルは ipv4.never-default / ipv4.ignore-auto-dns（既定ルートと DNS は適用しない）。
#
# router の actions:
#   install-plan | install        dnsmasq の導入計画（--assumeno）/導入。復旧: sudo dnf remove -y dnsmasq（実験9で導入済みなら不要）
#   conf                          /etc/dnsmasq.d/lab-dhcp.conf を作る（interface=enp0s8、port=0、dhcp-range、dhcp-option、log-dhcp）
#   lease <2m|10m>                リース時間を書き換えて dnsmasq を再起動
#   reserve <MAC> <IP>            固定割り当て（dhcp-host）を追加して再起動 / reserve clear で解除
#   start | stop | status         dnsmasq（systemctl。enable しない）
#   fw <open|close|reset>         firewalld の internal ゾーンに dhcp サービス（UDP 67）を実行時だけ許可/解除。reset は --reload
#   leases                        /var/lib/dnsmasq/dnsmasq.leases の内容
#   logs [行数]                   journalctl -u dnsmasq の末尾（log-dhcp の DHCPDISCOVER / OFFER / REQUEST / ACK）
#   capture [秒]                  tcpdump(既定 25 秒、enp0s8、UDP 67/68、-e -nn -v)。pcap は時刻付き
#   teardown                      dnsmasq を止め、設定とリース、固定割り当てを消し、firewalld をリロード（パッケージは残す）
# client の actions:
#   mac                           enp0s9 の MAC（reserve に使う）
#   lease-start                   enp0s9 の静的アドレスを外し、DHCP のプロファイル lab-dhcp を作って有効化（最大 20 秒待つ）
#   lease-show                    enp0s9 のアドレス・ルート・DHCP4 のオプション（nmcli device show）
#   lease-stop                    enp0s9 を unmanaged にして lab-dhcp を削除し、enp0s9 を元（unmanaged、アドレスなし）に戻す。続けて baseline.sh up で静的に戻せる
#
# 状態変更の方針: パッケージと /etc/ 配下のファイル、client の NetworkManager のプロファイル（lab-dhcp）以外は実行時のみ。永続設定は変更しない
#   （--permanent / systemctl enable は使わない）。lab-dhcp は autoconnect no。
# 安全装置: dnsmasq は enp0s8（lan-a）だけで待ち受ける（interface + bind-interfaces）。NAT 側（enp0s3）には出さない。
# ホスト名: 役割と一致しなければ全操作を中止する（例外なし）。引数の誤り（終了コード 2）と、前提なし（6）は記録を残さない。
# 合否は判定しない。結果（終了コードと出力）を記録するのみ。

set -u
set -o pipefail
role="${1:-}"; action="${2:-}"; a3="${3:-}"; a4="${4:-}"
ts=$(date +%Y%m%dT%H%M%S)
out="exp10-${role}-${action}${a3:+-${a3//[\/:]/-}}${a4:+-${a4//[\/:]/-}}-${ts}.txt"   # MAC の「:」はファイル名に使わない（Windows でチェックアウトできなくなるため）
pcap="exp10-router-${ts}.pcap"
DCONF=/etc/dnsmasq.d/lab-dhcp.conf; LEASES=/var/lib/dnsmasq/dnsmasq.leases
IFR=enp0s8; IFC=enp0s9; PROF=lab-dhcp

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }

write_conf() { # write_conf <リース時間> [固定割り当ての行]
  printf 'interface=%s\nbind-interfaces\nport=0\ndhcp-range=192.168.31.100,192.168.31.150,255.255.255.0,%s\ndhcp-option=option:router,192.168.31.1\ndhcp-option=option:dns-server,192.168.32.20\ndhcp-option=option:domain-search,lab.example\nlog-dhcp\nlog-facility=-\n' "$IFR" "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2"
  return 0
}
cur_lease() { sed -n 's/^dhcp-range=[^,]*,[^,]*,[^,]*,\(.*\)$/\1/p' $DCONF 2>/dev/null; }
cur_host()  { grep '^dhcp-host=' $DCONF 2>/dev/null | head -1; }

body() {
  echo "# exp10 ${role} ${action} ${a3} ${a4}  $(date -Is)  host=$(hostname -s)"
  case "$role" in router|client) ;; *) usage;; esac
  if [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"; exit 4
  fi
  echo "# ホスト名の確認: OK（host=$(hostname -s) と role=$role が一致）"
  case "$role:$action" in
    router:install-plan) run sudo dnf install --assumeno dnsmasq;;
    router:install)      run sudo dnf install -y dnsmasq; run rpm -q dnsmasq;;
    router:conf)
      echo "### \$ (write_conf 10m) | sudo tee $DCONF"; write_conf 10m | sudo tee $DCONF >/dev/null; echo "exit=${PIPESTATUS[1]}"; echo
      run sudo restorecon -v $DCONF; run cat $DCONF; run sudo dnsmasq --test;;
    router:lease)
      case "$a3" in 2m|10m) ;; *) usage;; esac
      [ -f $DCONF ] || { echo "先に ./dhcp-test.sh router conf を実行してください"; exit 6; }
      h=$(cur_host)
      echo "### \$ (write_conf $a3 '$h') | sudo tee $DCONF"; write_conf "$a3" "$h" | sudo tee $DCONF >/dev/null; echo "exit=${PIPESTATUS[1]}"; echo
      run sudo systemctl restart dnsmasq; run systemctl is-active dnsmasq; run grep -E '^dhcp-range|^dhcp-host' $DCONF;;
    router:reserve)
      [ -f $DCONF ] || { echo "先に ./dhcp-test.sh router conf を実行してください"; exit 6; }
      l=$(cur_lease); [ -n "$l" ] || l=10m
      if [ "$a3" = clear ]; then h=""; else [ -n "$a3" ] && [ -n "$a4" ] || usage; h="dhcp-host=$a3,$a4"; fi
      echo "### \$ (write_conf $l '$h') | sudo tee $DCONF"; write_conf "$l" "$h" | sudo tee $DCONF >/dev/null; echo "exit=${PIPESTATUS[1]}"; echo
      run sudo systemctl restart dnsmasq; run grep -E '^dhcp-range|^dhcp-host' $DCONF;;
    router:start)  [ -f $DCONF ] || { echo "先に ./dhcp-test.sh router conf を実行してください"; exit 6; }
                   run sudo systemctl start dnsmasq; run systemctl is-active dnsmasq; run sudo ss -lunp 'sport = :67';;
    router:stop)   run sudo systemctl stop dnsmasq; run systemctl is-active dnsmasq;;
    router:status) run systemctl status dnsmasq --no-pager -l; run sudo ss -lunp 'sport = :67';;
    router:fw)
      case "$a3" in
        open)  run sudo firewall-cmd --zone=internal --add-service=dhcp;;
        close) run sudo firewall-cmd --zone=internal --remove-service=dhcp;;
        reset) run sudo firewall-cmd --reload;;
        *) usage;;
      esac
      run sudo firewall-cmd --get-active-zones
      run sudo firewall-cmd --zone=internal --list-all;;
    router:leases) run sudo cat $LEASES; run sudo ls -l $LEASES;;
    router:logs)   n="${a3:-30}"; echo "### \$ sudo journalctl -u dnsmasq -n $n --no-pager"; sudo journalctl -u dnsmasq -n "$n" --no-pager 2>&1; echo;;
    router:capture)
      command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump が未導入です"; exit 5; }
      sec="${a3:-25}"
      echo "### \$ sudo timeout -s INT $sec tcpdump -i $IFR -e -nn -v -w $pcap 'udp port 67 or udp port 68'   ($sec 秒以内に client で lease-start)"
      sudo timeout -s INT "$sec" tcpdump -i $IFR -e -nn -w $pcap 'udp port 67 or udp port 68' 2>&1
      echo; echo "### \$ tcpdump -e -nn -v -r $pcap"; tcpdump -e -nn -v -r $pcap 2>&1;;
    router:teardown)
      run sudo systemctl stop dnsmasq
      run sudo rm -f $DCONF
      run sudo sh -c ": > $LEASES"
      run sudo firewall-cmd --reload
      run systemctl is-active dnsmasq;;
    client:mac) run ip -br link show $IFC;;
    client:lease-start)
      run sudo nmcli device set $IFC managed yes
      run sudo nmcli connection delete $PROF
      run sudo nmcli connection add type ethernet ifname $IFC con-name $PROF ipv4.method auto ipv4.never-default yes ipv4.ignore-auto-dns yes ipv4.dhcp-timeout 20 ipv6.method disabled connection.autoconnect no
      run sudo ip addr flush dev $IFC
      echo "### \$ sudo nmcli connection up $PROF   （最大 約20秒）"; t0=$(date +%s.%N)
      sudo nmcli connection up $PROF 2>&1; rc=$?; t1=$(date +%s.%N)
      printf 'exit=%s  elapsed=%.2fs\n\n' "$rc" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')"
      run ip -br addr show $IFC; run ip route;;
    client:lease-show)
      run ip -br addr show $IFC; run ip route
      run nmcli -f IP4,DHCP4 device show $IFC
      run nmcli -f NAME,DEVICE,STATE connection show --active;;
    client:lease-stop)
      # 先に unmanaged にする（down / delete の間に、NetworkManager が別のプロファイルを自動で有効化して DHCP を始めるのを防ぐ。
      # 2026-10-26 の capture で、lease-stop の最中に完全な DHCP のやり取りが観測された）
      run sudo nmcli device set $IFC managed no
      run sudo nmcli connection delete $PROF
      run sudo ip addr flush dev $IFC
      run ip -br addr show $IFC;;
    *) usage;;
  esac
}

body | tee "$out"
rc=${PIPESTATUS[0]}
# 引数の誤り（usage、終了コード 2）と、前提なし（6）は記録を残さない。ホスト名の不一致（4）は、安全上の記録として残す
[ "$rc" -eq 2 ] || [ "$rc" -eq 6 ] && rm -f "$out"
exit "$rc"
