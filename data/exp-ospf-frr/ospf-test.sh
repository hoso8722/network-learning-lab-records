#!/usr/bin/env bash
# 実験11: OSPF（FRR）。実験4の静的ルートを OSPF に置き換え、隣接の確立・経路の自動学習・障害時の変化・隣接できない症状を採取する（C10）
#
# 対象ノード : router（R1）/ router2（R2）/ client / server（AlmaLinux 9）。ベースライン（labs/common/baseline.sh up）が前提。
#              R1 の enp0s8 = 192.168.31.1/24（lan-a）、enp0s9 = 192.168.30.1/30（transit）、R2 の enp0s8 = 192.168.30.2/30、enp0s9 = 192.168.32.1/24（lan-b）。
# 使い方     : ./ospf-test.sh <router|router2|client|server> <action> [args...]
#
# router / router2 の actions:
#   install-plan | install        frr の導入計画（--assumeno）/導入（AppStream、8.5.3 の見込み）。復旧: sudo dnf remove -y frr
#   daemons                       /etc/frr/daemons の ospfd=no を ospfd=yes にする（元を daemons.lab-orig に退避。teardown で戻す）
#   start | stop | status         frr（systemctl。enable しない）
#   ospf <on|off> [エリア]        vtysh で router ospf を設定/削除（実行時のみ。write は使わない）。router-id は R1=1.1.1.1、R2=2.2.2.2。
#                                 network は自分の2つのサブネット（R1: 192.168.31.0/24 と 192.168.30.0/30、R2: 192.168.30.0/30 と 192.168.32.0/24）。エリア既定は 0
#   hello <秒|clear>              transit 側のインターフェースの hello-interval を変更/解除（不一致の再現用）
#   static <del|add>              実験4の静的ルート（R1: 192.168.32.0/24 via 192.168.30.2、R2: 192.168.31.0/24 via 192.168.30.1）を外す/戻す
#   fw <open|close>               firewalld の internal ゾーンに OSPF（プロトコル 89）を実行時だけ許可/解除（--add-protocol=ospf）
#   link <down|up>                transit 側のインターフェースを ip link で落とす/上げる（SSH は NAT 経由なので影響しない）
#   show                          アドレス / ip_forward / interface / OSPF の interface・neighbor・database・経路 / ip route / ファイアウォールの状態
#   watch [秒]                    2 秒ごとに neighbor と対象の経路を時刻付きで表示（既定 60 秒。障害時の変化の測定用）
#   logs [行数]                   journalctl -u frr の末尾
#   capture [秒]                  tcpdump(既定 60 秒、transit 側、ip proto 89、-nn -v)。pcap は時刻付き
#   teardown                      OSPF を削除、frr を停止、daemons を元に戻し、OSPF の許可を外し、静的ルートを戻す（パッケージは残す）
# client / server の actions:
#   ping | trace | routes         相手側（server / client）への ping・tracepath・ip route
#   pingloop [秒]                 1 秒間隔の ping を時刻付きで（既定 90 秒。-D -O。障害時の断の時間を測る）
#
# 状態変更の方針: パッケージと /etc/frr/daemons 以外は実行時のみ（--permanent / systemctl enable / write memory は使わない）。
# 安全装置: OSPF は network 文で指定した 2 つのサブネットの上だけで動く（NAT 側 enp0s3 には出さない）。
#   ただし FRR の zebra は、NAT の既定ルートなど既存の経路を触る可能性が未確認。show で ip route を毎回記録する。
# ホスト名: 役割と一致しなければ全操作を中止する（例外なし）。引数の誤り（終了コード 2）と、前提なし（6）は記録を残さない。
# 合否は判定しない。結果（終了コードと出力）を記録するのみ。

set -u
set -o pipefail
role="${1:-}"; action="${2:-}"; a3="${3:-}"; a4="${4:-}"
ts=$(date +%Y%m%dT%H%M%S)
out="exp11-${role}-${action}${a3:+-${a3//[\/:]/-}}-${ts}.txt"
pcap="exp11-${role}-${ts}.pcap"
DAEMONS=/etc/frr/daemons

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }
vt() { # vt <vtysh コマンド>...  各引数を -c にして実行（記録には実際のコマンドを出す）
  local args=() c; for c in "$@"; do args+=(-c "$c"); done
  echo "### \$ sudo vtysh $(printf -- "-c '%s' " "$@")"; sudo vtysh "${args[@]}" 2>&1; echo "exit=$?"; echo
}

body() {
  echo "# exp11 ${role} ${action} ${a3} ${a4}  $(date -Is)  host=$(hostname -s)"
  case "$role" in router|router2|client|server) ;; *) usage;; esac
  if [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"; exit 4
  fi
  echo "# ホスト名の確認: OK（host=$(hostname -s) と role=$role が一致）"
  # 役割ごとの定数
  case "$role" in
    router)  RID=1.1.1.1; TIF=enp0s9; NETS="192.168.31.0/24 192.168.30.0/30"; SNET=192.168.32.0/24; SVIA=192.168.30.2; WATCHNET="192.168.32.0/24";;
    router2) RID=2.2.2.2; TIF=enp0s8; NETS="192.168.30.0/30 192.168.32.0/24"; SNET=192.168.31.0/24; SVIA=192.168.30.1; WATCHNET="192.168.31.0/24";;
  esac
  case "$role:$action" in
    client:ping)   run ping -c 3 -W 2 192.168.32.20;;
    server:ping)   run ping -c 3 -W 2 192.168.31.10;;
    client:trace)  run tracepath -n 192.168.32.20;;
    server:trace)  run tracepath -n 192.168.31.10;;
    client:routes|server:routes) run ip route;;
    client:pingloop|server:pingloop)
      sec="${a3:-90}"; case "$sec" in ''|*[!0-9]*) usage;; esac
      peer=192.168.32.20; [ "$role" = server ] && peer=192.168.31.10
      echo "### \$ ping -D -O -i 1 -W 1 -c $sec $peer   （$sec 秒。-D=時刻、-O=未応答の表示。この間に router / router2 で障害を起こす）"
      ping -D -O -i 1 -W 1 -c "$sec" "$peer" 2>&1; echo "exit=$?";;

    router:install-plan|router2:install-plan) run sudo dnf install --assumeno frr;;
    router:install|router2:install)           run sudo dnf install -y frr; run rpm -q frr;;
    router:daemons|router2:daemons)
      # /etc/frr は一般ユーザーが読めない（2026-10-27 に router で、ディレクトリは見えるのに [ -f ] が偽になった。権限が原因の候補）ため、sudo で確認する
      run ls -ld /etc/frr
      sudo test -f $DAEMONS || { echo "$DAEMONS がありません（sudo でも見つかりません）。先に install してください"; exit 6; }
      run sudo grep -nE '^(zebra|ospfd|bgpd|ripd)=' $DAEMONS
      sudo test -f $DAEMONS.lab-orig || run sudo cp -p $DAEMONS $DAEMONS.lab-orig
      run sudo sed -i 's/^ospfd=no/ospfd=yes/' $DAEMONS
      run sudo grep -nE '^(zebra|ospfd|bgpd|ripd)=' $DAEMONS;;
    router:start|router2:start)   run sudo systemctl start frr; run systemctl is-active frr; run ps -eo pid,comm,args --sort=comm;;
    router:stop|router2:stop)     run sudo systemctl stop frr; run systemctl is-active frr;;
    router:status|router2:status) run systemctl status frr --no-pager; run ss -lnp -A raw;;
    router:ospf|router2:ospf)
      case "$a3" in
        on)
          ar="${a4:-0}"
          cmds=(-c 'configure terminal' -c 'router ospf' -c "ospf router-id $RID")
          for n in $NETS; do cmds+=(-c "network $n area $ar"); done
          echo "### \$ sudo vtysh configure terminal / router ospf / ospf router-id $RID / network (${NETS// /, }) area $ar"
          sudo vtysh "${cmds[@]}" 2>&1; echo "exit=$?"; echo
          vt 'show running-config';;
        off) vt 'configure terminal' 'no router ospf'; vt 'show running-config';;
        *) usage;;
      esac;;
    router:hello|router2:hello)
      [ -n "$a3" ] || usage
      if [ "$a3" = clear ]; then vt 'configure terminal' "interface $TIF" 'no ip ospf hello-interval'
      else case "$a3" in *[!0-9]*) usage;; esac; vt 'configure terminal' "interface $TIF" "ip ospf hello-interval $a3"; fi
      vt "show ip ospf interface $TIF";;
    router:static|router2:static)
      case "$a3" in
        del) run sudo ip route del $SNET via $SVIA;;
        add) run sudo ip route add $SNET via $SVIA;;
        *) usage;;
      esac
      run ip route;;
    router:fw|router2:fw)
      case "$a3" in
        open)  run sudo firewall-cmd --zone=internal --add-protocol=ospf;;
        close) run sudo firewall-cmd --zone=internal --remove-protocol=ospf;;
        *) usage;;
      esac
      run sudo firewall-cmd --zone=internal --list-all;;
    router:link|router2:link)
      case "$a3" in down|up) ;; *) usage;; esac
      run sudo ip link set $TIF $a3
      run ip -br addr show $TIF;;
    router:show|router2:show)
      # 先にカーネル側の状態（アドレス、転送）を記録する。再起動後に baseline.sh up を実行していないと、アドレスも転送も無い（実験11の準備中に疑われた）
      run ip -br addr
      run sysctl net.ipv4.ip_forward
      vt 'show interface brief' 'show ip ospf interface' 'show ip ospf neighbor' 'show ip ospf database' 'show ip route ospf' 'show ip route'
      run ip route
      run sudo firewall-cmd --zone=internal --list-protocols;;
    router:watch|router2:watch)
      sec="${a3:-60}"; case "$sec" in ''|*[!0-9]*) usage;; esac
      sudo -v
      echo "### 2 秒ごと、$sec 秒間。neighbor（vtysh）と経路（ip route の $WATCHNET）。この間に障害を起こす"
      end=$(( $(date +%s) + sec ))
      while [ "$(date +%s)" -lt "$end" ]; do
        echo "--- $(date +%T)"
        sudo vtysh -c 'show ip ospf neighbor' 2>&1 | sed -n '1,6p'
        echo "route: $(ip route show $WATCHNET 2>&1)"
        sleep 2
      done;;
    router:logs|router2:logs)
      n="${a3:-40}"; case "$n" in ''|*[!0-9]*) usage;; esac
      run sudo journalctl -u frr --no-pager -n "$n"
      # 2026-10-28 の hello 不一致の実験で、journalctl -u frr（frr.service の出力）には OSPF の行が無かった。ospfd 自身のログの出力先は未確認のため、設定と識別子での検索も記録する
      vt 'show logging'
      run sudo journalctl -t ospfd -t zebra --no-pager -n "$n";;
    router:capture|router2:capture)
      command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump が未導入です"; exit 5; }
      sec="${a3:-60}"; case "$sec" in ''|*[!0-9]*) usage;; esac
      echo "### \$ sudo timeout -s INT $sec tcpdump -i $TIF -nn -w $pcap 'ip proto 89'   （$sec 秒）"
      sudo timeout -s INT "$sec" tcpdump -i $TIF -nn -w $pcap 'ip proto 89' 2>&1
      echo; echo "### \$ tcpdump -nn -v -r $pcap"; tcpdump -nn -v -r $pcap 2>&1;;
    router:teardown|router2:teardown)
      vt 'configure terminal' 'no router ospf'
      run sudo systemctl stop frr
      if sudo test -f $DAEMONS.lab-orig; then run sudo mv -f $DAEMONS.lab-orig $DAEMONS; else echo "daemons の退避なし（復旧不要）"; fi
      run sudo firewall-cmd --zone=internal --remove-protocol=ospf
      run sudo ip link set $TIF up
      if ip route show $SNET | grep -q via; then echo "静的ルートあり（復旧不要）"; else run sudo ip route add $SNET via $SVIA; fi
      run ip route;;
    *) usage;;
  esac
}

body | tee "$out"
rc=${PIPESTATUS[0]}
# 引数の誤り（usage、終了コード 2）と、前提なし（6）は記録を残さない。ホスト名の不一致（4）は、安全上の記録として残す
[ "$rc" -eq 2 ] || [ "$rc" -eq 6 ] && rm -f "$out"
exit "$rc"
