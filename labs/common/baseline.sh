#!/usr/bin/env bash
# ベースライン（実験4〜6の構成: client – R1(router) – R2(router2) – server）を、WSL2 の bash から一括で構築・撤去・確認する
# （baseline.ps1 の bash 版。仕様と安全装置は同じ）
#
# 対象ノード : WSL2（mirrored）から、NAT のポートフォワード経由で client / server / router / router2
# 実行ユーザー: 一般ユーザー（VM 側は user アカウント。VM ごとに sudo のパスワードを1回聞かれる）
# 使い方     : labs/common/baseline.sh <up|down|status> [--skip-push]
# 動作:
#   up     = スクリプトを各 VM に送り（--skip-push で省略）、各 VM を設定し、client から server への ping で確認する
#              router : route-test.sh router  prepare → fwd on → fw-zone on → route add 192.168.32.0/24 192.168.30.2
#              router2: route-test.sh router2 prepare → fwd on → fw-zone on → route add 192.168.31.0/24 192.168.30.1
#              client : fault-test.sh client base → guard on     server: fault-test.sh server base
#              確認   : client から 192.168.32.20 へ ping（成功し ttl=62 が基準）
#   down   = 各 VM の teardown（アドレス・ルート・guard・ip_forward・ゾーンを元に戻し、NetworkManager の管理に戻す）
#   status = 各 VM の show（読み取りのみ）と、client から server への ping
# 状態変更   : up / down は各 VM の実行時の設定を変える（ip・sysctl・nmcli device set・firewall-cmd。永続設定は変えない）。
#              復旧: down、または VM の再起動。影響: ラボの NIC（enp0s8 / enp0s9）のみ。NAT（enp0s3）と SSH は変えない。
# 前提       : WSL の鍵設定が完了し、ラボ用 ssh-agent に鍵が載っていること（labs/common/lab-env.sh）。
#              VirtualBox の NIC の接続先（lan-a / transit / lan-b）が実験4のとおりであること。
# 安全装置   : 各 VM でホスト名が想定と一致しなければ何もしない。実体の各スクリプトも、役割と一致しなければ中止する。
# 記録       : data/baseline/baseline-sh-<動作>-<時刻>.txt（パスワードは記録しない）。

set -u
here="$(cd "$(dirname "$0")" && pwd)"; root="$(cd "$here/../.." && pwd)"
LAB_ENV_NO_UP=1 source "$here/lab-env.sh"
lab_agent_use || echo "注意: ラボ用 ssh-agent が使えません。現在の SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-なし}" >&2
action="${1:-}"; shift || true
case "$action" in up|down|status) ;; *) sed -n '4,22p' "$0"; exit 2;; esac
skip_push=0; [ "${1:-}" = "--skip-push" ] && skip_push=1

declare -A PORT=( [router]=2225 [router2]=2226 [client]=2222 [server]=2223 )
ORDER=(router router2 client server)
USER_VM=user
declare -A SCRIPT=( [router]=data/exp-static-route/route-test.sh [router2]=data/exp-static-route/route-test.sh [client]=data/exp-fault-ip/fault-test.sh [server]=data/exp-fault-ip/fault-test.sh )
declare -A UP=(
  [router]='./route-test.sh router prepare && ./route-test.sh router fwd on && ./route-test.sh router fw-zone on && ./route-test.sh router route add 192.168.32.0/24 192.168.30.2'
  [router2]='./route-test.sh router2 prepare && ./route-test.sh router2 fwd on && ./route-test.sh router2 fw-zone on && ./route-test.sh router2 route add 192.168.31.0/24 192.168.30.1'
  [client]='./fault-test.sh client base && ./fault-test.sh client guard on'
  [server]='./fault-test.sh server base' )
declare -A DOWN=( [router]='./route-test.sh router teardown' [router2]='./route-test.sh router2 teardown' [client]='./fault-test.sh client teardown' [server]='./fault-test.sh server teardown' )
declare -A STATUS=( [router]='./route-test.sh router show' [router2]='./route-test.sh router2 show' [client]='./fault-test.sh client show' [server]='./fault-test.sh server show' )

mkdir -p "$root/data/baseline"
out="$root/data/baseline/baseline-sh-${action}-$(date +%Y%m%dT%H%M%S).txt"
log() { echo "$*" | tee -a "$out"; }
log "# baseline.sh  action=$action  $(date -Is)  wsl=$(wslinfo --networking-mode 2>&1)"
results=()

if [ "$action" = up ] && [ $skip_push -eq 0 ]; then
  log ""; log "## スクリプトの送信（scp。鍵認証。同名のファイルは上書き）"
  for n in "${ORDER[@]}"; do
    p=${PORT[$n]}; f="$root/${SCRIPT[$n]}"; leaf=$(basename "$f")
    scp -o BatchMode=yes -P "$p" "$f" "$USER_VM@127.0.0.1:" ; c1=$?
    r=$(ssh -o BatchMode=yes -p "$p" "$USER_VM@127.0.0.1" "test \$(hostname -s) = $n && chmod +x ./$leaf && echo pushed:\$(hostname -s):$leaf"); c2=$?
    log "  $n: scp=$c1 chmod/確認=$c2 $r"
  done
fi

declare -n CHAIN=$(echo "$action" | tr a-z A-Z)
for n in "${ORDER[@]}"; do
  p=${PORT[$n]}; log ""; log "=== $n (port $p) : $action ==="
  pre="test \$(hostname -s) = $n && "
  [ "$action" != status ] && pre+="sudo -v && "
  ssh -t -p "$p" "$USER_VM@127.0.0.1" "${pre}${CHAIN[$n]}"; code=$?
  log "  ssh 終了コード: $code（0 = 一連のコマンドを最後まで実行。個々のコマンドの成否は VM 側の記録 exp4-* / exp5-* を参照）"
  results+=("$n: 終了コード $code")
done

if [ "$action" != down ]; then
  log ""; log "## 確認: client から 192.168.32.20 へ ping（基準: 成功、ttl=62）"
  r=$(ssh -o BatchMode=yes -p "${PORT[client]}" "$USER_VM@127.0.0.1" 'test $(hostname -s) = client && ./fault-test.sh client ping 192.168.32.20' 2>&1)
  echo "$r" | sed 's/^/  /' | tee -a "$out" >/dev/null; echo "$r" | sed 's/^/  /'
  if grep -q "ttl=62" <<<"$r"; then v="基準どおり（ttl=62 で応答あり）"
  elif grep -q "ttl=" <<<"$r"; then v="応答あり、ただし ttl が基準と違う（要確認）"
  else v="【応答なし】要確認（各 VM の記録を参照）"; fi
  log "  判定: $v"; results+=("ping client→server: $v")
fi
log ""; log "## まとめ"; for r in "${results[@]}"; do log "  $r"; done
log "記録: $out"
