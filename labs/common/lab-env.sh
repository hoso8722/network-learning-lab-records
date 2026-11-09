#!/usr/bin/env bash
# ラボ専用の ssh-agent を用意し、ラボの鍵（id_ed25519_lab_wsl）を載せる（source して使う）
#
# 対象ノード : WSL2（Ubuntu-24.04）
# 実行ユーザー: 一般ユーザー
# 目的       : 端末ごとの eval "$(ssh-agent -s)" と ssh-add を不要にする。専用の固定ソケットの agent を1つだけ動かし、
#              どの端末（と、そこから実行するスクリプト）からも同じ agent を使う。パスフレーズの入力は、agent の起動後の最初の1回だけ。
# 状態変更   : agent が無ければ起動する（ソケット: ~/.ssh/agent-lab.sock、権限は所有者のみ）。鍵が載っていなければ ssh-add する
#              （端末から対話で実行しているときだけ。パスフレーズを聞く）。ファイルの内容は変更しない。
# 復旧       : agent を止める: SSH_AUTH_SOCK=~/.ssh/agent-lab.sock ssh-agent -k、またはソケットの持ち主の ssh-agent を kill。
#              WSL の再起動でも消える（鍵はメモリ上にあるだけ）。
# 使い方     : source labs/common/lab-env.sh          （手動）
#              自動で使うには labs/common/lab-env-hook.sh を ~/.bashrc から読み込む（README の説明を参照）。
# 限界       : agent が動いている間は、このユーザーのプロセスなら誰でも agent 経由で鍵を使える（パスフレーズなしで署名できる）。
#              共有 PC や、信頼できないプロセスを動かす環境では、-t の期限付きで載せる（LAB_KEY_LIFETIME=3600 など）。

LAB_AGENT_SOCK="$HOME/.ssh/agent-lab.sock"
LAB_KEY="$HOME/.ssh/id_ed25519_lab_wsl"

lab_agent_up() {
  [ -f "$LAB_KEY" ] || { echo "lab-env: ラボの鍵がありません: $LAB_KEY" >&2; return 1; }
  # 接続できるか（ssh-add -l: 0=鍵あり、1=鍵なし、2=接続できない）
  SSH_AUTH_SOCK="$LAB_AGENT_SOCK" ssh-add -l >/dev/null 2>&1
  if [ $? -eq 2 ]; then
    rm -f "$LAB_AGENT_SOCK"
    ssh-agent -a "$LAB_AGENT_SOCK" >/dev/null || { echo "lab-env: ssh-agent を起動できません" >&2; return 1; }
    chmod 600 "$LAB_AGENT_SOCK" 2>/dev/null
  fi
  export SSH_AUTH_SOCK="$LAB_AGENT_SOCK"
  local fp; fp=$(ssh-keygen -l -f "$LAB_KEY.pub" 2>/dev/null | awk '{print $2}')
  if ! ssh-add -l 2>/dev/null | grep -qF "$fp"; then
    if [ -t 0 ] && [ -t 1 ]; then
      echo "lab-env: ラボの鍵を ssh-agent に載せます（パスフレーズを入力）"
      ssh-add ${LAB_KEY_LIFETIME:+-t "$LAB_KEY_LIFETIME"} "$LAB_KEY"
    else
      echo "lab-env: 鍵が agent に載っていません（対話端末ではないため ssh-add しません）" >&2
    fi
  fi
}

# 非対話で使う側（スクリプト）向け: ラボの agent が動いていれば、それを使う（起動も ssh-add もしない）
lab_agent_use() {
  if [ -S "$LAB_AGENT_SOCK" ] && SSH_AUTH_SOCK="$LAB_AGENT_SOCK" ssh-add -l >/dev/null 2>&1; then export SSH_AUTH_SOCK="$LAB_AGENT_SOCK"; return 0; fi
  return 1
}

# source されたときは、起動と鍵の追加まで行う（LAB_ENV_NO_UP=1 なら関数の定義だけ）
if [ "${BASH_SOURCE[0]}" != "$0" ] && [ -z "${LAB_ENV_NO_UP:-}" ]; then lab_agent_up; fi
