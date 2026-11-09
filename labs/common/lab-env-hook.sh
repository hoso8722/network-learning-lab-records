# このプロジェクト（network-learning-handoff）の下にいるときだけ、ラボ専用の ssh-agent を使う（~/.bashrc から source する）
#
# 対象ノード : WSL2 の対話 bash
# 目的       : プロジェクトのフォルダーに入ると、自動でラボ専用 agent に切り替え（必要なら起動・鍵の追加）、出ると元に戻す。
# 仕組み     : PROMPT_COMMAND で、プロンプトのたびに $PWD がプロジェクトの下かを調べる（文字列の比較だけで軽い）。
# 状態変更   : 環境変数 SSH_AUTH_SOCK を、プロジェクトの下にいる間だけ ラボ専用 agent のソケットに置き換える。
#              プロジェクトの外へ出ると、元の値（なければ unset）に戻す。ファイルは変更しない。
# 復旧       : ~/.bashrc の読み込み行を消して、端末を開き直す。

LAB_PROJECT_DIR="${LAB_PROJECT_DIR:-$HOME/network-learning-handoff}"

__lab_env_hook() {
  case "$PWD/" in
    "$LAB_PROJECT_DIR"/*)
      if [ "${SSH_AUTH_SOCK:-}" != "$HOME/.ssh/agent-lab.sock" ]; then
        __LAB_PREV_SOCK_SET=${SSH_AUTH_SOCK+x}; __LAB_PREV_SOCK="${SSH_AUTH_SOCK:-}"
        # shellcheck source=/dev/null
        source "$LAB_PROJECT_DIR/labs/common/lab-env.sh"
      fi;;
    *)
      if [ "${SSH_AUTH_SOCK:-}" = "$HOME/.ssh/agent-lab.sock" ]; then
        if [ -n "${__LAB_PREV_SOCK_SET:-}" ]; then export SSH_AUTH_SOCK="$__LAB_PREV_SOCK"; else unset SSH_AUTH_SOCK; fi
        unset __LAB_PREV_SOCK __LAB_PREV_SOCK_SET
      fi;;
  esac
}
case ";${PROMPT_COMMAND:-};" in *";__lab_env_hook;"*) ;; *) PROMPT_COMMAND="__lab_env_hook${PROMPT_COMMAND:+;$PROMPT_COMMAND}";; esac
