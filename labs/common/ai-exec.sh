#!/usr/bin/env bash
# AI(Claude Code)が、ラボの VM で「確認の実験」のコマンドを実行し、コマンドの文字列を、そのまま記録に書く(WSL2 の bash 版)
#
# 対象ノード : WSL2(mirrored)から、NAT のポートフォワード経由で client / server / switch / router / router2
# 実行ユーザー: 一般ユーザー(VM 側は user アカウント)。sudo は、実験の間だけ lab-sudo.sh on でパスワードなしにしておく
# 目的       : 過去の記事の「確認の実験」(スクリプトの内容を、手で打つ形で確かめ直す実験)を、AI が実行するときの記録を採る。
#              script + script2record.py の記録は、ターミナルのエコーが混ざることがあるが、この記録は、与えたコマンドの文字列を
#              そのまま「### $ <コマンド>   (<ノード>)」の行にする(引用符も含めて、そのまま)。
# 使い方     : labs/common/ai-exec.sh --init <記録のファイル> "<題名>" ["<注>" ...]   記録のヘッダーを作る(ファイルがなければ)
#              labs/common/ai-exec.sh <記録のファイル> <ノード> '<コマンド>'          VM でコマンドを実行し、記録に追記し、画面にも出す
# 動作       : ssh -o BatchMode=yes で、VM の user アカウントのシェルに、コマンドの文字列をそのまま渡す。
#              コマンドの前に、ホスト名がノード名と一致するかを確認する(違えば、何も実行せず、終了コード 4)。
#              この確認のコードは、記録の「### $」の行には出さない(ヘッダーに書く)。
#              出力の後に「exit=<終了コード>」を書く。標準入力は渡さない(/dev/null)。
# 制約       : コマンドが終わるまで待つ。バックグラウンドで動かしたいコマンドは、VM の中で「… > ~/x.txt 2>&1 < /dev/null &」の形で渡す
#              (ssh の接続が切れても、続く)。tcpdump などは、timeout を付ける。
# 状態変更   : 渡したコマンドによる。このスクリプト自身は、記録のファイル(WSL2 側)に追記するだけで、VM の設定は変えない。
# 安全装置   : 実行するのは、人間が承認した「確認の実験」の手順だけ(AGENTS.md「実験手順書ルール」)。新しい実験には使わない。
# 記録       : 引数で指定したファイル(data/ の下を想定。パスワードは扱わない)。

set -u
here="$(cd "$(dirname "$0")" && pwd)"
LAB_ENV_NO_UP=1 source "$here/lab-env.sh"
lab_agent_use || echo "注意: ラボ用 ssh-agent が使えません。現在の SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-なし}" >&2
declare -A PORT=( [client]=2222 [server]=2223 [switch]=2224 [router]=2225 [router2]=2226 )
USER_VM=user

if [ "${1:-}" = "--init" ]; then
  rec="${2:?記録のファイルを指定してください}"; title="${3:?題名を指定してください}"; shift 3
  [ -e "$rec" ] && { echo "記録のファイルが、すでにあります: $rec(追記します)"; exit 0; }
  mkdir -p "$(dirname "$rec")"
  {
    echo "# $title"
    echo "# 出所: AI(Claude Code)が、WSL2 から ssh で実行した、確認の実験の記録($(date +%F) JST)。labs/common/ai-exec.sh が、コマンドの文字列を、そのまま「### \$」の行に書いた"
    echo "# 注: 各コマンドの前に、ホスト名が役割と一致するかの確認を、ラッパーが行っている(その確認のコードは、「### \$」の行には出ない)"
    for n in "$@"; do echo "# 注: $n"; done
  } > "$rec"
  echo "記録のヘッダーを作りました: $rec"; exit 0
fi

rec="${1:?記録のファイルを指定してください}"; node="${2:?ノードを指定してください}"; cmd="${3:?コマンドを指定してください}"
[ -n "${PORT[$node]:-}" ] || { echo "不明なノード: $node(利用可能: ${!PORT[*]})" >&2; exit 2; }
[ -f "$rec" ] || { echo "先に --init で、記録のヘッダーを作ってください: $rec" >&2; exit 2; }
guard="[ \"\$(hostname -s)\" = $node ] || { echo \"中止: このVMのホスト名は '\$(hostname -s)' ですが、指定のノードは '$node' です。\"; exit 4; }"
tmp="$(mktemp)"
{ printf '### $ %s   (%s)\n' "$cmd" "$node"
  ssh -o BatchMode=yes -o ConnectTimeout=10 -p "${PORT[$node]}" "$USER_VM@127.0.0.1" "$guard; $cmd" < /dev/null 2>&1
  echo "exit=$?"; echo
} > "$tmp"
cat "$tmp" | tee -a "$rec"
rm -f "$tmp"
