#!/usr/bin/env bash
# VM へのスクリプト送信（push）と、実験結果の回収（pull）を、WSL2 の bash からまとめて行う（transfer.ps1 の bash 版）
#
# 対象ノード : WSL2（mirrored）から、NAT のポートフォワード経由で client / server / switch / router / router2
# 実行ユーザー: 一般ユーザー（VM 側は user アカウント）
# 状態変更   : push = 各VMのホームにスクリプトを置く（同名なら上書き）と実行権限を付ける。pull = ホスト側のフォルダーにファイルを作る。
#              VM の設定は変えない。
# 前提       : WSL の鍵設定が完了し、ラボ用 ssh-agent に鍵が載っていること（labs/common/lab-env.sh）。
# 使い方     :
#   送信: labs/common/transfer.sh push --exp-dir exp-static-route --files route-test.sh [--include-sync] [--only router,router2]
#   回収: labs/common/transfer.sh pull --exp-dir exp-l4-ports --pattern 'exp6-*' [--only client,server]
# push : data/<exp-dir>/<files> を各VMの ~/ に送る。--include-sync で labs/common/sync-time.sh も送る。--files はカンマ区切り。
# pull : 各VMの ~/<pattern> を data/<exp-dir>/from-<VM名>/ に回収する（VMごとに分けるので同名ファイルが混ざらない）。
# 安全装置   : 転送の前に各VMのホスト名が想定と一致するか確認し、違えばその VM をスキップする（PowerShell 版にない追加）。

set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
LAB_ENV_NO_UP=1 source "$here/lab-env.sh"
lab_agent_use || echo "注意: ラボ用 ssh-agent が使えません。現在の SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-なし}" >&2
declare -A PORT=( [client]=2222 [server]=2223 [switch]=2224 [router]=2225 [router2]=2226 )
ORDER=(client server switch router router2)
USER_VM=user
mode="${1:-}"; shift || true
exp_dir="exp-router-on-a-stick"; files="router-test.sh"; pattern="exp3-*"; only=""; include_sync=0
while [ $# -gt 0 ]; do
  case "$1" in
    --exp-dir) exp_dir="$2"; shift 2;;
    --files) files="$2"; shift 2;;
    --pattern) pattern="$2"; shift 2;;
    --only) only="$2"; shift 2;;
    --include-sync) include_sync=1; shift;;
    *) sed -n '4,17p' "$0"; exit 2;;
  esac
done
case "$mode" in push|pull) ;; *) sed -n '4,17p' "$0"; exit 2;; esac
data_dir="$root/data/$exp_dir"
[ -d "$data_dir" ] || { echo "データディレクトリが見つかりません: $data_dir"; exit 1; }
done_n=0
for n in "${ORDER[@]}"; do
  if [ -n "$only" ] && [[ ",$only," != *",$n,"* ]]; then continue; fi
  done_n=$((done_n + 1)); p=${PORT[$n]}
  echo; echo "=== $n (port $p) : $mode ==="
  got=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$p" "$USER_VM@127.0.0.1" 'hostname -s' 2>&1); code=$?
  if [ $code -ne 0 ] || [ "$got" != "$n" ]; then echo "スキップ: ホスト名の確認に失敗（終了コード=$code, 応答='${got:0:60}', 想定='$n'）"; continue; fi
  if [ "$mode" = push ]; then
    src=(); IFS=',' read -ra fl <<< "$files"; for f in "${fl[@]}"; do src+=("$data_dir/$f"); done
    [ $include_sync -eq 1 ] && src+=("$root/labs/common/sync-time.sh")
    missing=0; for f in "${src[@]}"; do [ -f "$f" ] || { echo "ファイルが見つかりません: $f"; missing=1; }; done
    [ $missing -eq 0 ] || continue
    scp -o BatchMode=yes -P "$p" "${src[@]}" "$USER_VM@127.0.0.1:~/"; sc=$?
    echo "scp_exit: $sc"
    [ $sc -eq 0 ] || { echo "失敗: $n への転送に失敗しました。"; continue; }
    names=""; for f in "${src[@]}"; do names+=" ~/$(basename "$f")"; done
    ssh -o BatchMode=yes -p "$p" "$USER_VM@127.0.0.1" "chmod +x$names; echo remote_host=\$(hostname -s)"
    echo "ssh_exit: $?"
  else
    dest="$data_dir/from-$n"; mkdir -p "$dest"
    scp -o BatchMode=yes -P "$p" "$USER_VM@127.0.0.1:~/$pattern" "$dest/"
    echo "scp_exit: $?   回収先: $dest"
  fi
done
echo
[ $done_n -gt 0 ] || echo "警告: 対象のVMがありません（利用可能: ${ORDER[*]}）"
echo "完了。"
