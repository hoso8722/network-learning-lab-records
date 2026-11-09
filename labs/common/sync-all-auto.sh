#!/usr/bin/env bash
# 全VMの時刻のずれを自動で判定し、ずれているVMだけ補正する（WSL2 の bash 版。sync-all-auto.ps1 と同じ仕様）
#
# 対象ノード : WSL2（mirrored）から、VirtualBox NAT のポートフォワード経由で client / server / switch / router / router2
# 実行ユーザー: 一般ユーザー（VM 側は user アカウント）
# 目的       : 実験の前に、ホストと各 VM の時刻差を測り、しきい値を超えた VM だけ sync-time.sh で補正する
# 状態変更   : 判定は読み取りのみ（VM で date を実行するだけ）。しきい値を超えた VM だけ sync-time.sh を実行して
#              システム時計を補正する（--check-only なら補正しない）。
# 前提       : WSL の鍵設定が完了（data/exp-ssh-key-wsl/）、ラボ用 ssh-agent に鍵が載っていること（labs/common/lab-env.sh）。
#              A-5（chronyc の sudo NOPASSWD）済み。各 VM のホームに sync-time.sh があること（baseline.ps1 の up などで送信済み）。
# 使い方     : labs/common/sync-all-auto.sh [--only client,router] [--threshold 2] [--check-only] [--parallel] [--retries 2]
# 再試行     : 補正後も差が残る VM は、20秒待って再度補正する（既定 2回まで）。2026-10-25 に、ホスト休止後の約7時間のずれで、
#              1回目に makestep が効かない VM があった（chrony が時刻源を選ぶ前だった可能性。候補）ための対策。
# 判定       : 時刻差 = VM の UTC − 応答を受け取った時刻（WSL 側の UTC）。WSL と Windows の時計は同じ元（ホスト）に追従する前提
#              （未確認: WSL の時計がホストと一致しているかは別に確認が必要）。
# 安全装置   : 各 VM で「ホスト名が想定と一致するか」を先に確認し、違えば何もしない。
# 記録       : data/time-sync/sync-all-auto-sh-<時刻>.txt（パスワードは記録しない）。

set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
LAB_ENV_NO_UP=1 source "$here/lab-env.sh"
lab_agent_use || echo "注意: ラボ用 ssh-agent が使えません（鍵が載っていない可能性）。現在の SSH_AUTH_SOCK=${SSH_AUTH_SOCK:-なし}" >&2

declare -A PORT=( [client]=2222 [server]=2223 [switch]=2224 [router]=2225 [router2]=2226 )
ORDER=(client server switch router router2)
USER_VM=user; RETRIES=2; THRESHOLD=2; CHECK_ONLY=0; PARALLEL=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="$2"; shift 2;;
    --threshold) THRESHOLD="$2"; shift 2;;
    --check-only) CHECK_ONLY=1; shift;;
    --parallel) PARALLEL=1; shift;;
    --retries) RETRIES="$2"; shift 2;;
    *) sed -n '4,19p' "$0"; exit 2;;
  esac
done
targets=()
for n in "${ORDER[@]}"; do
  if [ -z "$ONLY" ] || [[ ",$ONLY," == *",$n,"* ]]; then targets+=("$n"); fi
done
[ ${#targets[@]} -gt 0 ] || { echo "対象の VM がありません（利用可能: ${ORDER[*]}）"; exit 2; }

mkdir -p "$root/data/time-sync"
out="$root/data/time-sync/sync-all-auto-sh-$(date +%Y%m%dT%H%M%S).txt"
log() { echo "$*" | tee -a "$out"; }

# measure <名前>: VM の UTC を取得し、差（VM − 応答の受信時刻、秒）を DIFF に入れる。失敗なら return 1
measure() {
  local n=$1 p=${PORT[$1]} res code t1
  res=$(ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$p" "$USER_VM@127.0.0.1" "test \$(hostname -s) = $n && date -u +%s.%N" 2>&1); code=$?
  t1=$(date -u +%s.%N)
  if [ $code -ne 0 ] || ! [[ "$res" =~ ^[0-9]+\.[0-9]+$ ]]; then
    log "  測定失敗: ssh 終了コード=$code（255=接続・認証の失敗、1=ホスト名の不一致の可能性） ${res:0:80}"; return 1
  fi
  DIFF=$(awk -v a="$res" -v b="$t1" 'BEGIN{printf "%.3f", a-b}')
  log "  vm_utc=$res  差(VM−ホスト)=${DIFF}秒"
}
over() { awk -v d="$1" -v t="$THRESHOLD" 'BEGIN{ if (d<0) d=-d; exit !(d>t) }'; }

log "# sync-all-auto.sh  $(date -Is)  しきい値=${THRESHOLD}秒  check_only=$CHECK_ONLY  parallel=$PARALLEL  wsl=$(wslinfo --networking-mode 2>&1)"
summary=(); need=(); declare -A before last
for n in "${targets[@]}"; do
  log ""; log "=== $n (port ${PORT[$n]}) ==="
  if ! measure "$n"; then summary+=("$n: 測定できず"); continue; fi
  if ! over "$DIFF"; then summary+=("$n: 補正不要（差 ${DIFF} 秒）"); continue; fi
  if [ $CHECK_ONLY -eq 1 ]; then summary+=("$n: 【ずれあり】差 ${DIFF} 秒（--check-only のため補正せず）"); continue; fi
  before[$n]=$DIFF; need+=("$n")
done

sync_one() { # sync_one <名前> <出力ファイル>
  ssh -o BatchMode=yes -p "${PORT[$1]}" "$USER_VM@127.0.0.1" "test \$(hostname -s) = $1 && ./sync-time.sh" >"$2" 2>&1
  echo "__exit__:$?" >>"$2"
}
if [ ${#need[@]} -gt 0 ]; then
  pending=("${need[@]}")
  for attempt in $(seq 1 $((RETRIES + 1))); do
    [ ${#pending[@]} -gt 0 ] || break
    log ""; log "## 補正（${attempt}回目）: ${pending[*]}（$([ $PARALLEL -eq 1 ] && echo 並列 || echo 順番)、BatchMode。sudo のパスワードは聞かない）"
    tmpd=$(mktemp -d)
    for n in "${pending[@]}"; do
      if [ $PARALLEL -eq 1 ]; then sync_one "$n" "$tmpd/$n.txt" & else sync_one "$n" "$tmpd/$n.txt"; fi
    done
    wait
    for n in "${pending[@]}"; do log ""; log "=== $n : 補正の出力（${attempt}回目）==="; sed 's/^/  /' "$tmpd/$n.txt" | tee -a "$out"; done
    rm -rf "$tmpd"
    still=()
    for n in "${pending[@]}"; do
      log ""; log "=== $n : 補正後の再測定（${attempt}回目）==="
      if ! measure "$n"; then summary+=("$n: 補正後に測定できず【要確認】")
      elif over "$DIFF"; then still+=("$n"); last[$n]=$DIFF
      else summary+=("$n: 補正した（差 ${before[$n]} → ${DIFF} 秒、${attempt}回目）"); fi
    done
    pending=("${still[@]}")
    if [ ${#pending[@]} -gt 0 ] && [ $attempt -le $RETRIES ]; then log ""; log "## まだずれている VM があります: ${pending[*]}。chrony が時刻源を選び直すのを待ってから、もう一度補正します（20秒待つ）"; sleep 20; fi
  done
  for n in "${pending[@]}"; do summary+=("$n: 【要確認】補正を$((RETRIES + 1))回行っても差 ${last[$n]} 秒"); done
fi

log ""; log "## まとめ"
for s in "${summary[@]}"; do log "  $s"; done
log "記録: $out"
