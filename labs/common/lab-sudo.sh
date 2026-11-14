#!/usr/bin/env bash
# 各 VM で、一般ユーザーの sudo を、実験の間だけパスワードなしにする(WSL2 の bash 版)
#
# 対象ノード : WSL2(mirrored)から、NAT のポートフォワード経由で client / server / switch / router / router2
# 実行ユーザー: 一般ユーザー(VM 側で sudo を使う。on は sudo のパスワードを、ノードごとに 1 回聞く)
# 目的       : 実験の中で sudo を何度も使うとき、パスワード入力に後続の行が取り込まれて実行されない問題(複数行の貼り付け)を避ける。
# 状態変更   : on    = 各 VM に /etc/sudoers.d/lab-nopasswd(Defaults:<user> !use_pty と、<user> ALL=(root) NOPASSWD: ALL)を作る
#              (すでにある場合は上書きする。何回実行してもよい)
#              off   = そのファイルを削除し、パスワードが必要に戻ったことを確かめる
#              check = 変更なし(sudo -n true で、パスワードなしで実行できるかを調べるだけ)
# 影響       : on の間は、このユーザーが、パスワードなしですべての sudo を実行できる。
#              !use_pty は、sudo が端末に溜まった入力(複数行の貼り付けの後ろの行)を捨てる現象を避けるため(推定。off で一緒に消える)。ラボの中だけの VM で使い、実験が終わったら off にする。
#              (setup-sudo-chronyc.sh の lab-chronyc は、chronyc の 2 コマンドだけの別の設定で、このスクリプトは触れない)
# 安全装置   : (1) ホスト名が想定と一致しなければ何もしない。(2) 一時ファイルを visudo -cf で構文検査し、通った場合だけ設置する
#              (構文が壊れた sudoers は sudo 自体を使えなくするため)。(3) ファイルは root:root、権限 440。(4) 失敗しても一時ファイルを消す。
# 事前条件   : スナップショットがあること。VM のコンソールが使えること(vb startvm "Alma9mini-<名前>" --type gui)。
# 復旧       : off。sudo が使えなくなった場合は、VM のコンソールから root でログインし /etc/sudoers.d/lab-nopasswd を削除する
#              (root でログインできることは、確認していない)。root が使えない場合は、スナップショットへの復元(取得後の変更は失われる)。
# 使い方     : labs/common/lab-sudo.sh on    [--only router,router2,server]
#              labs/common/lab-sudo.sh off   [--only router,router2,server]
#              labs/common/lab-sudo.sh check [--only router,router2,server]
#              --only を省略すると、5 台すべてが対象。
# 記録       : data/lab-sudo/lab-sudo-sh-<動作>-<時刻>.txt(パスワードは記録しない)。

set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
LAB_ENV_NO_UP=1 source "$here/lab-env.sh"
lab_agent_use || echo "注意: ラボ用 ssh-agent が使えません。現在の SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-なし}" >&2
action="${1:-}"; shift || true
case "$action" in on|off|check) ;; *) sed -n '2,23p' "$0"; exit 2;; esac
only=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) only="$2"; shift 2;;
    *) echo "不明な引数: $1"; exit 2;;
  esac
done
declare -A PORT=( [client]=2222 [server]=2223 [switch]=2224 [router]=2225 [router2]=2226 )
ORDER=(client server switch router router2)
USER_VM=user
F=/etc/sudoers.d/lab-nopasswd; T=/tmp/lab-nopasswd.sudoers
mkdir -p "$root/data/lab-sudo"
out="$root/data/lab-sudo/lab-sudo-sh-${action}-$(date +%Y%m%dT%H%M%S).txt"
log() { echo "$*" | tee -a "$out"; }
log "# lab-sudo.sh  action=$action  $(date -Is)"
n_done=0
for n in "${ORDER[@]}"; do
  if [ -n "$only" ] && [[ ",$only," != *",$n,"* ]]; then continue; fi
  n_done=$((n_done + 1)); p=${PORT[$n]}
  log ""; log "=== $n (port $p) : $action ==="
  guard="test \"\$(hostname -s)\" = $n"
  case "$action" in
    check)
      cmd="$guard && { sudo -k; if sudo -n true 2>/dev/null; then echo passwordless:$n; else echo password-required:$n; fi; }"
      ssh -o BatchMode=yes -p "$p" "$USER_VM@127.0.0.1" "$cmd"; code=$?
      log "  終了コード: $code(表示が passwordless なら on、password-required なら off)";;
    on)
      cmd="$guard && printf 'Defaults:%s !use_pty\\n%s ALL=(root) NOPASSWD: ALL\\n' \"\$(id -un)\" \"\$(id -un)\" > $T && sudo visudo -cf $T && sudo install -o root -g root -m 440 $T $F && sudo -k && sudo -n true && echo on-ok:$n; rc=\$?; rm -f $T; exit \$rc"
      ssh -t -p "$p" "$USER_VM@127.0.0.1" "$cmd"; code=$?
      log "  終了コード: $code(0 で on-ok:$n が表示されていれば成功)";;
    off)
      cmd="$guard && sudo rm -f $F && sudo -k && ! sudo -n true 2>/dev/null && echo off-ok:$n"
      ssh -t -p "$p" "$USER_VM@127.0.0.1" "$cmd"; code=$?
      log "  終了コード: $code(0 で off-ok:$n が表示されていれば成功。パスワードが必要に戻っている)";;
  esac
done
[ $n_done -gt 0 ] || log "警告: 対象の VM がありません(利用可能: ${ORDER[*]})。"
log ""; log "記録: $out"
