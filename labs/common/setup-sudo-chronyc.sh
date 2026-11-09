#!/usr/bin/env bash
# 各 VM で、一般ユーザーが chronyc の 2 つのコマンドだけ、sudo のパスワードなしで実行できるようにする(WSL2 の bash 版。setup-sudo-chronyc.ps1 と同じ仕様)
#
# 対象ノード : WSL2(mirrored)から、NAT のポートフォワード経由で client / server / switch / router / router2
# 実行ユーザー: 一般ユーザー(VM 側で sudo を使う。apply / remove は sudo のパスワードを聞かれる)
# 目的       : sync-time.sh(sudo chronyc burst 4/4、sudo chronyc makestep)を、パスワードなしで実行できるようにする
#              (sync-all-auto.sh は BatchMode の ssh で補正するため、この設定がないと補正できない)
# 状態変更   : apply  = 各 VM に /etc/sudoers.d/lab-chronyc(<user> ALL=(root) NOPASSWD: <chronyc> burst 4/4, <chronyc> makestep)を作る
#              remove = そのファイルを削除する
#              check  = 変更なし(sudo -n -l <コマンド> で、パスワードなしで実行できるかを調べるだけ。コマンド自体は実行しない)
# 影響       : このユーザーは、パスワードなしで「システム時計を NTP に合わせる」操作ができる。他の sudo は従来どおりパスワードが必要。
# 安全装置   : (1) ホスト名が想定と一致しなければ何もしない。(2) 一時ファイルを visudo -cf で構文検査し、通った場合だけ設置する
#              (構文が壊れた sudoers は sudo 自体を使えなくするため)。(3) ファイルは root:root、権限 440。
# 事前条件   : VM のコンソールで入れること(vb startvm "Alma9mini-<名前>" --type gui)。node-ready のスナップショットがあること。
# 復旧       : remove。sudo が使えなくなった場合は、VM のコンソールから root でログインし /etc/sudoers.d/lab-chronyc を削除する。
# 使い方     : labs/common/setup-sudo-chronyc.sh check [--only client,server]
#              labs/common/setup-sudo-chronyc.sh apply
#              labs/common/setup-sudo-chronyc.sh remove
# 記録       : data/time-sync/setup-sudo-chronyc-sh-<動作>-<時刻>.txt(パスワードは記録しない)。

set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
LAB_ENV_NO_UP=1 source "$here/lab-env.sh"
lab_agent_use || echo "注意: ラボ用 ssh-agent が使えません。現在の SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-なし}" >&2
action="${1:-}"; shift || true
case "$action" in check|apply|remove) ;; *) sed -n '2,22p' "$0"; exit 2;; esac
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
mkdir -p "$root/data/time-sync"
out="$root/data/time-sync/setup-sudo-chronyc-sh-${action}-$(date +%Y%m%dT%H%M%S).txt"
log() { echo "$*" | tee -a "$out"; }
log "# setup-sudo-chronyc.sh  action=$action  $(date -Is)"
n_done=0
for n in "${ORDER[@]}"; do
  if [ -n "$only" ] && [[ ",$only," != *",$n,"* ]]; then continue; fi
  n_done=$((n_done + 1)); p=${PORT[$n]}
  log ""; log "=== $n (port $p) : $action ==="
  guard="test \$(hostname -s) = $n"
  case "$action" in
    check)
      cmd="$guard && P=\$(command -v chronyc) && echo chronyc_path:\$P && sudo -n -l \$P burst 4/4 && sudo -n -l \$P makestep"
      ssh -o BatchMode=yes -p "$p" "$USER_VM@127.0.0.1" "$cmd"; code=$?
      log "  終了コード: $code(0 = 2 つとも、パスワードなしで実行可能)";;
    apply)
      cmd="$guard && P=\$(command -v chronyc) && printf '%s ALL=(root) NOPASSWD: %s burst 4/4, %s makestep\\n' $USER_VM \$P \$P > /tmp/lab-chronyc.sudoers && sudo visudo -cf /tmp/lab-chronyc.sudoers && sudo install -o root -g root -m 440 /tmp/lab-chronyc.sudoers /etc/sudoers.d/lab-chronyc && rm -f /tmp/lab-chronyc.sudoers && echo apply-ok:\$(hostname -s)"
      ssh -t -p "$p" "$USER_VM@127.0.0.1" "$cmd"; code=$?
      log "  終了コード: $code(0 で apply-ok:$n が表示されていれば成功)";;
    remove)
      cmd="$guard && sudo rm -f /etc/sudoers.d/lab-chronyc && echo remove-ok:\$(hostname -s)"
      ssh -t -p "$p" "$USER_VM@127.0.0.1" "$cmd"; code=$?
      log "  終了コード: $code(0 で remove-ok:$n が表示されていれば成功)";;
  esac
done
[ $n_done -gt 0 ] || log "警告: 対象の VM がありません(利用可能: ${ORDER[*]})。"
log ""; log "記録: $out"
