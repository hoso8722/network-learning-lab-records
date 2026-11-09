#!/usr/bin/env bash
# 実験5: IP アドレス・マスク・ゲートウェイの誤り（client の設定を壊して、症状から原因を切り分ける練習）
#
# 対象ノード : client / server（AlmaLinux 9）。ルーター(router, router2)は実験4の route-test.sh で設定する。
# 使い方     : ./fault-test.sh <client|server> <action> [arg]
#
# 前提の構成（実験4と同じ。VirtualBox の変更は不要）:
#   client(enp0s9 192.168.31.10/24) -[lan-a]- R1 -[transit]- R2 -[lan-b]- server(enp0s9 192.168.32.20/24)
#   R1/R2 には、実験4の手順（prepare、fwd on、fw-zone on、route add）で、全経路をそろえておく。
#
# actions:
#   base              正しい設定を入れる（client: 192.168.31.10/24 と 192.168.32.0/24 via 192.168.31.1。server は対称）
#   fault <mask|gw|ip> (client のみ) 設定を壊す
#                       mask: 192.168.31.10/16（マスクが広すぎる）。静的ルートなし
#                       gw  : 192.168.32.0/24 via 192.168.31.254（存在しないゲートウェイ）
#                       ip  : 192.168.131.10/24（サブネット違いのアドレス）。静的ルートの追加はエラーになる想定
#   fix               正しい設定に戻す（base と同じ）
#   guard <on|off>    192.168.0.0/16 宛の「到達不能」ルートを実行時だけ追加/削除する（metric 4000）。
#                     経路がないラボ宛の通信が NAT の既定ルートで外へ漏れるのを防ぐ（実験4で漏れを観測した対策）。
#   show              ip -br addr / ip route / ip route get <相手> / ip neigh
#   ping <IP>         ping -c 3 -W 2 <IP>
#   teardown          アドレスとルートを外し、NetworkManager の管理に戻し、guard を外す
#
# 状態変更の方針: ip / nmcli device set（実行時のみ。再起動で元に戻る）。永続設定は変更しない。
# ホスト名: 役割と一致しなければ全操作を中止する（例外なし）。
# 合否は判定しない。結果（終了コードと出力）を記録するのみ。

set -u
set -o pipefail
role="${1:-}"; action="${2:-}"; arg="${3:-}"
HIF=enp0s9
ts=$(date +%Y%m%dT%H%M%S)
out="exp5-${role}-${action}${arg:+-$arg}-${ts}.txt"

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }

body() {
  echo "# exp5 ${role} ${action} ${arg}  $(date -Is)  host=$(hostname -s)"
  case "$role" in client|server) ;; *) usage;; esac
  if [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"; exit 4
  fi
  echo "# ホスト名の確認: OK（host=$(hostname -s) と role=$role が一致）"
  ip link show $HIF >/dev/null 2>&1 || { echo "インターフェース $HIF が見つかりません。ip -br link で確認してください"; exit 3; }
  if [ "$role" = client ]; then me=192.168.31.10; gw=192.168.31.1; net=192.168.32.0/24; peer=192.168.32.20
  else me=192.168.32.20; gw=192.168.32.1; net=192.168.31.0/24; peer=192.168.31.10; fi

  apply_base() {
    run sudo nmcli device set $HIF managed no
    run sudo ip link set $HIF up
    run sudo ip addr flush dev $HIF
    run sudo ip addr add ${me}/24 dev $HIF
    run sudo ip route add $net via $gw dev $HIF
  }
  show() {
    run ip -br addr
    run ip route
    run ip route get $peer
    run ip neigh show dev $HIF
  }

  case "$action" in
    base|fix) apply_base; show;;
    fault)
      [ "$role" = client ] || usage
      run sudo nmcli device set $HIF managed no
      run sudo ip link set $HIF up
      run sudo ip addr flush dev $HIF
      case "$arg" in
        mask) run sudo ip addr add 192.168.31.10/16 dev $HIF;;
        gw)   run sudo ip addr add 192.168.31.10/24 dev $HIF
              run sudo ip route add 192.168.32.0/24 via 192.168.31.254 dev $HIF;;
        ip)   run sudo ip addr add 192.168.131.10/24 dev $HIF
              run sudo ip route add 192.168.32.0/24 via 192.168.31.1 dev $HIF;;
        *) usage;;
      esac
      show;;
    guard)
      case "$arg" in
        on)  run sudo ip route add unreachable 192.168.0.0/16 metric 4000;;
        off) run sudo ip route del unreachable 192.168.0.0/16 metric 4000;;
        *) usage;;
      esac
      run ip route;;
    show) show;;
    ping) [ -n "$arg" ] || usage; run ping -c 3 -W 2 "$arg";;
    teardown)
      run sudo ip route del unreachable 192.168.0.0/16 metric 4000   # 未設定ならエラーでよい
      run sudo ip addr flush dev $HIF
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
