#!/usr/bin/env bash
# 実験の端末を 1 つ開き、script で記録を取る(WSL2 の bash 版)
#
# 対象ノード : WSL2(mirrored)の端末。node に wsl を指定するとその端末自体を、VM を指定すると ssh でログインした先を記録する
# 実行ユーザー: 一般ユーザー
# 目的       : 実験の記録(script)の起動、プロンプトの設定、ログイン、古い記録の退避を、1 行で済ませる。
#              学習の対象は、実験のコマンドであって、記録の取り方ではないため。
# 状態変更   : (1) 記録のファイル ~/<実験名>-<ノード>.txt を作る。同名のファイルがあれば ~/<実験名>-old/ に移す(上書きしない)。
#              (2) VM のとき、~/.lab-rec-rc(プロンプトの設定。PS1、PROMPT_COMMAND、貼り付けの設定)を VM に置く。VM の設定は変えない。
#              (3) 端末の中は bash --noprofile --rcfile で起動し、プロンプトを「<ノード>:$ 」、各コマンドの後に「exit=<終了コード>」を出す
#                  (scripts/script2record.py が、この形を記録に変換する)。貼り付けは、1 行ずつ実行される形(bracketed paste を無効)にする。
# 影響       : なし(ラボの設定は変えない)。記録には、端末に表示されたものがすべて入る。パスワードは、画面に出ないので入らない。
# 終了       : 端末で exit を 1 回(VM から抜けると、script も終わる)。
# 復旧       : 記録を捨てるなら、~/<実験名>-<ノード>.txt を削除する。~/.lab-rec-rc は VM に残るが、無害(rm で削除してよい)。
# 使い方     : labs/common/rec-term.sh <実験名> <wsl|client|server|switch|router|router2>
#              例: labs/common/rec-term.sh fwnat router2     (記録: ~/fwnat-router2.txt)
#              WSL2 の作業ディレクトリは、実行した場所のままになる(リポジトリの直下で実行すると、labs/common/baseline.sh を相対パスで使える)。

set -u
here="$(cd "$(dirname "$0")" && pwd)"
exp="${1:-}"; node="${2:-}"
case "$node" in wsl|client|server|switch|router|router2) ;; *) sed -n '2,19p' "$0"; exit 2;; esac
[ -n "$exp" ] || { sed -n '2,19p' "$0"; exit 2; }
declare -A PORT=( [client]=2222 [server]=2223 [switch]=2224 [router]=2225 [router2]=2226 )
USER_VM=user
rec="$HOME/${exp}-${node}.txt"
if [ -e "$rec" ]; then
  mkdir -p "$HOME/${exp}-old"
  old="$HOME/${exp}-old/${exp}-${node}-$(date +%Y%m%dT%H%M%S).txt"
  mv "$rec" "$old" && echo "前の記録を移しました: $old"
fi
rc="$(mktemp)"; trap 'rm -f "$rc"' EXIT
cat > "$rc" <<EOF
PS1='${node}:\$ '
PROMPT_COMMAND='echo "exit=\$?"'
bind 'set enable-bracketed-paste off'
EOF
echo "記録を開始します: $rec(終わるときは exit を 1 回)"
if [ "$node" = wsl ]; then
  script -q -f "$rec" -c "bash --noprofile --rcfile $rc -i"
else
  LAB_ENV_NO_UP=1 source "$here/lab-env.sh"
  lab_agent_use || echo "注意: ラボ用 ssh-agent が使えません。現在の SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-なし}" >&2
  p=${PORT[$node]}
  ssh -p "$p" "$USER_VM@127.0.0.1" 'cat > ~/.lab-rec-rc' < "$rc" || { echo "中止: ${node} にプロンプトの設定を置けませんでした。"; exit 3; }
  script -q -f "$rec" -c "ssh -t -p $p $USER_VM@127.0.0.1 'test \"\$(hostname -s)\" = $node && exec bash --noprofile --rcfile ~/.lab-rec-rc -i'"
fi
echo "記録: $rec"
