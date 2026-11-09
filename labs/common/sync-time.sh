#!/usr/bin/env bash
# VM の時計を NTP(chrony)に合わせ、補正前後の状態を記録する
#
# 対象ノード : client / server の各 AlmaLinux 9 VM
# 実行ユーザー: root、または sudo が使える一般ユーザー
# 目的       : 実験データの時刻(実行日・ログの対応づけ)を信頼できる状態にする
# 状態変更   : あり。`chronyc makestep` でシステム時計を即時に補正する(時刻が飛ぶ)。
#              キャプチャなどの実験の「開始前」に実行すること。
# 復旧       : 補正は戻さない。誤って補正した場合は再度 NTP に合わせる。
# 前提       : NTP サーバーに到達できること(NAT アダプターが有効)。
#              内部ネットワークだけの状態では補正できない。その場合は補正せず、
#              現状を記録して終了コード 3 で終わる。
# 環境変数   : SKIP_TIME_SYNC=1 なら補正せず記録のみ行う(隔離テスト時など)。
# 終了コード : 0 = 同期確認 / 2 = chronyc なし / 3 = 同期を確認できず
# 限界       : "sync_result: OK" は chrony が自分の測定に追従していることを示すだけで、ホストの時刻との一致の保証ではない。
#              2026-10-20、ホストの休止からの再開直後に OK と出たが、VM の時計は約9時間遅れていた（原因は候補: 再開直後の
#              chrony の推定が古い）。実験の前にホストの時刻（PowerShell の Get-Date）と VM の `date` を目で比べること。
# 注意       : timedatectl の "System clock synchronized" は、補正直後に no のまま
#              なことがある(2026-10-18 の server で観測)。同期の判定には
#              chronyc waitsync の結果を使い、timedatectl の値は参考として併記する。

set -u
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

record() {
  echo "### $1"
  echo "date: $(date -Is)"
  echo "date_utc: $(date -u -Is)"
  timedatectl 2>&1 | grep -E "Time zone|System clock synchronized|NTP service|RTC time"
  chronyc tracking 2>&1 | grep -E "Reference ID|Ref time|System time|Leap status"
}

echo "# sync-time.sh  $(date -Is)"
if ! command -v chronyc >/dev/null 2>&1; then
  echo "chronyc が見つかりません(未補正)"; record "現状"; exit 2
fi

record "補正前"

if [ "${SKIP_TIME_SYNC:-0}" = "1" ]; then
  echo "SKIP_TIME_SYNC=1: 補正をスキップしました"; exit 3
fi

echo "### \$ ${SUDO} chronyc burst 4/4; sleep 15   (新しい NTP 測定を促す。ホスト休止後の再開直後は chrony の推定が古いため)"
$SUDO chronyc burst 4/4 2>&1
sleep 15
echo "### \$ chronyc sources"
chronyc sources 2>&1
echo
echo "### \$ ${SUDO} chronyc makestep   (状態変更: システム時計を補正)"
$SUDO chronyc makestep 2>&1

echo "### \$ chronyc waitsync 6 0.5   (最大約60秒待つ。読み取りのみ)"
if chronyc waitsync 6 0.5 2>&1; then
  record "補正後"
  echo "sync_result: OK"
  exit 0
else
  record "補正後"
  echo "sync_result: NOT_SYNCED (NTP に到達できない可能性。原因は未特定)"
  exit 3
fi
