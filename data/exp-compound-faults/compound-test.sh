#!/usr/bin/env bash
# 実験12: 複合障害（C11）。実験4・5・11の単独の障害を2つ組み合わせ、症状の重なりと、切り分け・復旧の順序を採取する
#
# 対象ノード : router（R1）/ router2（R2）/ client（AlmaLinux 9）。ベースライン（labs/common/baseline.sh up）が前提。
#              単独の障害の投入・復旧は既存のスクリプトを使う（route-test.sh = 実験4、ospf-test.sh = 実験11）。このスクリプトは不足分だけ持つ。
# 使い方     : ./compound-test.sh <router|router2|client> <action> [args...]
#
# actions:
#   router|router2 : fw-block <on|off>   internal ゾーンのゾーン内転送（--remove-forward / --add-forward）を実行時だけ止める/戻す。
#                                        on の間、internal の2つの NIC（enp0s8 と enp0s9）の間の転送が firewalld に拒否される。--query-forward を併せて記録する。
#                                        （最初は ICMP を拒否する rich rule を試したが、転送される ICMP には効かなかった: 2026-10-29 に実測、README 参照）
#                    state               ip_forward / ip route / ゾーン / ゾーン内転送 / rich rule / OSPF（動いていれば neighbor と OSPF 経路）を1回で記録
#   client         : obs                 server(192.168.32.20) への ping 3 回、tracepath -n、ip route get を1回で記録（各ステップの観測用）
#
# firewall の変更（fw-block）: 対象=該当ルーターの firewalld（実行時のみ） / 影響=そのルーターを通る転送（client ⇔ server）がすべて拒否される。
#   SSH は NAT 側（enp0s3、public）なので影響しない / 復旧=fw-block off、または labs/common/baseline.sh up（ゾーン割り当ても戻る）。
#   firewall-cmd --reload は使わない（baseline の実行時ゾーン割り当てを失う）。
# ホスト名: 役割と一致しなければ全操作を中止する（例外なし）。引数の誤り（終了コード 2）は記録を残さない。ホスト名の不一致（4）は残す。
# 合否は判定しない。結果（終了コードと出力）を記録するのみ。

set -u
set -o pipefail
role="${1:-}"; action="${2:-}"; a3="${3:-}"
ts=$(date +%Y%m%dT%H%M%S)
out="exp12-${role}-${action}${a3:+-${a3}}-${ts}.txt"

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }

body() {
  echo "# exp12 ${role} ${action} ${a3}  $(date -Is)  host=$(hostname -s)"
  case "$role" in router|router2|client) ;; *) usage;; esac
  if [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"; exit 4
  fi
  echo "# ホスト名の確認: OK（host=$(hostname -s) と role=$role が一致）"
  case "$role:$action" in
    router:fw-block|router2:fw-block)
      case "$a3" in
        on)  run sudo firewall-cmd --zone=internal --remove-forward;;
        off) run sudo firewall-cmd --zone=internal --add-forward;;
        *) usage;;
      esac
      run sudo firewall-cmd --zone=internal --query-forward;;
    router:state|router2:state)
      run sysctl net.ipv4.ip_forward
      run ip route
      run sudo firewall-cmd --get-active-zones
      run sudo firewall-cmd --zone=internal --query-forward
      run sudo firewall-cmd --zone=internal --list-rich-rules
      run sudo firewall-cmd --zone=internal --list-protocols
      if systemctl is-active --quiet frr; then
        echo "### \$ sudo vtysh -c 'show ip ospf neighbor' -c 'show ip route ospf'"
        sudo vtysh -c 'show ip ospf neighbor' -c 'show ip route ospf' 2>&1; echo "exit=$?"; echo
      else echo "frr は停止中（OSPF の記録なし）"; fi;;
    client:obs)
      run ping -c 3 -W 2 192.168.32.20
      run tracepath -n -m 6 192.168.32.20
      run ip route get 192.168.32.20;;
    *) usage;;
  esac
}

body | tee "$out"
rc=${PIPESTATUS[0]}
[ "$rc" -eq 2 ] && rm -f "$out"
exit "$rc"
