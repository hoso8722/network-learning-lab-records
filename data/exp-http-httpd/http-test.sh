#!/usr/bin/env bash
# 実験7: HTTP 応答エラー（httpd）。ステータスコード（200/301/403/404/500）と、接続の失敗（拒否・無応答）を、curl とログで切り分ける
#
# 対象ノード : client / server（AlmaLinux 9）。ルーター(router, router2)は実験4の route-test.sh（または labs/common/baseline.sh up）で
#              正しい状態にしておく。
# 使い方     : ./http-test.sh <client|server> <action> [args...]
#
# 構成（実験4〜6と同じ）: client 192.168.31.10 – R1 – R2 – server 192.168.32.20（TCP 80。httpd）
#
# server の actions:
#   install-plan                  dnf install --assumeno httpd（何も入れない。ダウンロードのサイズを見る。NAT 有効が必要）
#   install                       sudo dnf install -y httpd（パッケージを入れる。復旧: sudo dnf remove -y httpd）
#   site <setup|show|teardown>    実験用のコンテンツ・設定を作る/一覧/片付ける（下の「実験用のURL」）
#   start | stop | status         httpd の起動・停止・状態（systemctl。enable はしない: 再起動で止まる）
#   fw <open|close|reset>         firewalld の http サービスを実行時だけ許可/解除（--permanent なし）。reset は --reload
#   logs [行数]                   access_log と error_log の末尾（既定 15行）
#   selinux                       getenforce、実験用ファイルの SELinux コンテキスト(ls -Z)、最近の AVC 拒否
#   fix-selinux                   restorecon で /var/www/html/selinux.html のコンテキストを直す
#   capture                       tcpdump(25秒、TCP 80)。pcap は時刻付きの名前
#   teardown                      httpd を止め、実験用のファイルと設定を消し、firewalld をリロード（パッケージは残す）
# client の actions:
#   curl <パス>                   curl -sv（最大5秒）。終了コードと http_code・応答ヘッダーの先頭を表示。例: ./http-test.sh client curl /nofile
#   head <パス>                   curl -sI（ヘッダーのみ）
#
# 実験用のURL（site setup で作る。server の /var/www/html/ ほか）:
#   /index.html (/)   200 通常
#   /nofile           404 存在しないパス
#   /perm.html        403 ファイル権限（root:root 0600 で、apache が読めない）
#   /selinux.html     403 SELinux のコンテキスト違い（ホーム配下から mv したため user_home_t のまま。権限は 0644 で正しい）
#   /old              301 → /index.html（/etc/httpd/conf.d/lab-http.conf の Redirect）
#   /cgi-bin/ok.cgi   200 CGI が正しいヘッダーを返す
#   /cgi-bin/bad.cgi  500 CGI がヘッダーなしで出力する（error_log に "malformed header" または "Premature end of script headers"）
#
# 状態変更の方針: パッケージの導入（install）と /var/www/ 配下のファイル、/etc/httpd/conf.d/lab-http.conf 以外は、実行時のみ
#   （systemctl start、firewall-cmd）。永続設定は変更しない（--permanent / systemctl enable は使わない）。
# firewall の変更（fw open/close/reset）:
#   対象=server の firewalld（実行時のみ） / 影響=server への TCP 80 の通信の可否 / 復旧=fw reset または teardown
# 公開範囲: httpd は全アドレスで待ち受ける（Listen 80）。NAT 側(enp0s3)は firewalld の public ゾーンで 80 が閉じている想定（未確認）。
# ホスト名: 役割と一致しなければ全操作を中止する（例外なし）。
# 合否は判定しない。結果（終了コードと出力）を記録するのみ。

set -u
set -o pipefail
role="${1:-}"; action="${2:-}"; a3="${3:-}"
SERVER_IP=192.168.32.20
ts=$(date +%Y%m%dT%H%M%S)
out="exp7-${role}-${action}${a3:+-${a3//\//_}}-${ts}.txt"
pcap="exp7-server-${ts}.pcap"
CONF=/etc/httpd/conf.d/lab-http.conf

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }

body() {
  echo "# exp7 ${role} ${action} ${a3}  $(date -Is)  host=$(hostname -s)"
  case "$role" in client|server) ;; *) usage;; esac
  if [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"; exit 4
  fi
  echo "# ホスト名の確認: OK（host=$(hostname -s) と role=$role が一致）"
  case "$role:$action" in
    server:install-plan) run sudo dnf install --assumeno httpd;;
    server:install)      run sudo dnf install -y httpd; run rpm -q httpd; run httpd -v;;
    server:site)
      case "$a3" in
        setup)
          run sudo sh -c 'echo "index: ok" > /var/www/html/index.html'
          run sudo sh -c 'echo "perm: secret" > /var/www/html/perm.html && chown root:root /var/www/html/perm.html && chmod 0600 /var/www/html/perm.html'
          # ホーム配下で作ったファイルを mv する（コピーと違い、コンテキストが user_home_t のまま残る）
          echo "selinux: mislabeled" > "$HOME/selinux.html"; chmod 0644 "$HOME/selinux.html"
          run sudo mv "$HOME/selinux.html" /var/www/html/selinux.html
          run sudo chmod 0644 /var/www/html/selinux.html
          run sudo sh -c "printf 'Redirect 301 /old /index.html\n' > $CONF"
          run sudo sh -c 'printf "#!/bin/sh\nprintf \"Content-Type: text/plain\\n\\n\"\necho cgi-ok\n" > /var/www/cgi-bin/ok.cgi && chmod 0755 /var/www/cgi-bin/ok.cgi'
          run sudo sh -c 'printf "#!/bin/sh\necho no-header-here\n" > /var/www/cgi-bin/bad.cgi && chmod 0755 /var/www/cgi-bin/bad.cgi'
          run sudo restorecon -v /var/www/cgi-bin/ok.cgi /var/www/cgi-bin/bad.cgi /var/www/html/index.html /var/www/html/perm.html
          run sudo httpd -t
          run ls -lZ /var/www/html /var/www/cgi-bin;;
        show) run ls -lZ /var/www/html /var/www/cgi-bin; run cat $CONF;;
        teardown)
          run sudo rm -f /var/www/html/index.html /var/www/html/perm.html /var/www/html/selinux.html "$HOME/selinux.html" /var/www/cgi-bin/ok.cgi /var/www/cgi-bin/bad.cgi $CONF
          run ls -lZ /var/www/html /var/www/cgi-bin;;
        *) usage;;
      esac;;
    server:start)  run sudo systemctl start httpd; run systemctl is-active httpd; run sudo ss -tlnp 'sport = :80';;
    server:stop)   run sudo systemctl stop httpd; run systemctl is-active httpd;;
    server:status) run systemctl status httpd --no-pager -l; run sudo ss -tlnp 'sport = :80';;
    server:fw)
      case "$a3" in
        open)  run sudo firewall-cmd --add-service=http;;
        close) run sudo firewall-cmd --remove-service=http;;
        reset) run sudo firewall-cmd --reload;;
        *) usage;;
      esac
      run sudo firewall-cmd --get-active-zones
      run sudo firewall-cmd --list-all;;
    server:logs)
      n="${a3:-15}"
      echo "### \$ sudo tail -n $n /var/log/httpd/access_log"; sudo tail -n "$n" /var/log/httpd/access_log 2>&1; echo
      echo "### \$ sudo tail -n $n /var/log/httpd/error_log";  sudo tail -n "$n" /var/log/httpd/error_log 2>&1; echo;;
    server:selinux)
      run getenforce
      run ls -lZ /var/www/html /var/www/cgi-bin
      echo "### \$ sudo grep -a AVC /var/log/audit/audit.log | tail -n 5"; sudo grep -a AVC /var/log/audit/audit.log 2>&1 | tail -n 5; echo;;
    server:fix-selinux) run sudo restorecon -v /var/www/html/selinux.html; run ls -lZ /var/www/html/selinux.html;;
    server:capture)
      command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump が未導入です"; exit 5; }
      echo "### \$ sudo timeout -s INT 25 tcpdump -i any -nn -w $pcap 'tcp port 80'   (25秒以内に client から curl)"
      sudo timeout -s INT 25 tcpdump -i any -nn -w $pcap 'tcp port 80' 2>&1
      echo; echo "### \$ tcpdump -nn -r $pcap"; tcpdump -nn -r $pcap 2>&1;;
    server:teardown)
      run sudo systemctl stop httpd
      run sudo rm -f /var/www/html/index.html /var/www/html/perm.html /var/www/html/selinux.html "$HOME/selinux.html" /var/www/cgi-bin/ok.cgi /var/www/cgi-bin/bad.cgi $CONF
      run sudo firewall-cmd --reload
      run systemctl is-active httpd;;
    client:curl)
      [ -n "$a3" ] || usage
      echo "### \$ curl -sv --max-time 5 -o /dev/null -w 'http_code=%{http_code}\n' http://${SERVER_IP}${a3}"
      curl -sv --max-time 5 -o /dev/null -w 'http_code=%{http_code}\n' "http://${SERVER_IP}${a3}" 2>&1 | sed -n '1,30p'
      echo "curl_exit=${PIPESTATUS[0]}   (7=接続できない/拒否、28=タイムアウト)"; echo
      echo "### \$ curl -s --max-time 5 http://${SERVER_IP}${a3}   (本文)"; curl -s --max-time 5 "http://${SERVER_IP}${a3}" 2>&1 | head -n 5; echo;;
    client:head)
      [ -n "$a3" ] || usage
      run curl -sI --max-time 5 "http://${SERVER_IP}${a3}";;
    *) usage;;
  esac
}

body | tee "$out"
rc=${PIPESTATUS[0]}
# 引数の誤り（usage、終了コード 2）は、記録を残さない。ホスト名の不一致（4）などは、安全上の記録として残す
[ "$rc" -eq 2 ] && rm -f "$out"
exit "$rc"
