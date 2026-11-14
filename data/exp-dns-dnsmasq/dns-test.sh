#!/usr/bin/env bash
# 実験9: DNS（dnsmasq）。名前解決の失敗を、dig と getent、curl の終了コードで切り分ける（B09 / C07）
#
# 対象ノード : client / server（AlmaLinux 9）。ベースライン（labs/common/baseline.sh up）が前提。
# 使い方     : ./dns-test.sh <client|server> <action> [args...]
#
# 構成: client 192.168.31.10 – R1 – R2 – server 192.168.32.20（UDP/TCP 53 = dnsmasq、TCP 80 = httpd）。ドメインは lab.example。
#       client の /etc/resolv.conf は変更しない（NAT 側の名前解決、dnf、SSH に影響させない）。lab 用の名前解決は、
#       一時的なマウント名前空間の中だけで /etc/resolv.conf を差し替えて行う（resolve / run。コマンドの終了で元に戻る）。
#
# server の actions:
#   install-plan | install        dnsmasq の導入計画（--assumeno）/導入。復旧: sudo dnf remove -y dnsmasq
#   conf                          /etc/dnsmasq.d/lab-dns.conf と /etc/lab-hosts を作る（listen は 192.168.32.20、上流なし、log-queries）
#   record <ok|wrongip|missing|show>   www.lab.example の A レコードを切り替える（/etc/lab-hosts を書き換えて dnsmasq に HUP）
#        ok      www.lab.example = 192.168.32.20（server の実アドレス）。client.lab.example = 192.168.31.10 も登録
#        wrongip www.lab.example = 192.168.32.21（誰もいないアドレス）
#        missing www.lab.example のレコードなし（client.lab.example だけ）
#        ※ web.lab.example は www.lab.example への CNAME（conf で設定）
#   web <on|off>                  httpd を起動して index.html を置く / 止めて消す（dns の名前で curl するため）。http を許可/解除
#   start | stop | status | logs [行数]   dnsmasq（systemctl。enable しない）/ journalctl -u dnsmasq の末尾
#   fw <open|close|reset>         firewalld の dns サービス（53）を実行時だけ許可/解除。reset は --reload
#   capture                       tcpdump(25秒、UDP/TCP 53)。pcap は時刻付き
#   teardown                      dnsmasq と httpd を止め、設定・レコード・index.html を消し、firewalld をリロード（パッケージは残す）
# client の actions:
#   teardown                      ~/dns-lab/（resolve が作った一時的な resolv.conf）を削除
#   install-plan | install        bind-utils（dig）の導入計画 / 導入。復旧: sudo dnf remove -y bind-utils
#   dig <名前> [タイプ]           dig @192.168.32.20（+time=2 +tries=1）。タイプの既定は A（PTR は -x を使う: dig の第2引数に ptr <IP>）
#   resolve <ok|nosearch|wrongns> <名前>
#                                 lab 用の resolv.conf（下記）の下で getent hosts と curl を実行し、終了コードと時間を表示
#        ok       search lab.example / nameserver 192.168.32.20 / timeout:1 attempts:1
#        nosearch search なし（短い名前 www が解決できない）
#        wrongns  nameserver 192.168.32.99（誰もいないアドレス）→ タイムアウト
#   direct                         IP 直指定の curl（http://192.168.32.20/）。名前解決との比較用
#
# 状態変更の方針: パッケージの導入と /etc/ 配下のファイル以外は、実行時のみ（systemctl start、firewall-cmd）。永続設定は変更しない
#   （--permanent / systemctl enable は使わない）。client の resolve は、マウント名前空間の中だけで /etc/resolv.conf を差し替える。
# firewall の変更（fw / web）: 対象=server の firewalld（実行時のみ） / 影響=server への TCP/UDP 53、TCP 80 / 復旧=fw reset または teardown
# 公開範囲: dnsmasq は 192.168.32.20 と lo だけで待ち受ける（listen-address）。上流（forwarder）は設定しない（実環境の DNS に問い合わせない）。
# ホスト名: 役割と一致しなければ全操作を中止する（例外なし）。引数の誤り（終了コード 2）と、前提なし（6）は記録を残さない。
# 合否は判定しない。結果（終了コードと出力）を記録するのみ。

set -u
set -o pipefail
role="${1:-}"; action="${2:-}"; a3="${3:-}"; a4="${4:-}"
SERVER_IP=192.168.32.20
ts=$(date +%Y%m%dT%H%M%S)
out="exp9-${role}-${action}${a3:+-${a3//\//_}}${a4:+-${a4//\//_}}-${ts}.txt"
pcap="exp9-server-${ts}.pcap"
DCONF=/etc/dnsmasq.d/lab-dns.conf; HOSTSF=/etc/lab-hosts
DLAB="$HOME/dns-lab"

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }
timed() { # timed <コマンド...>: 実行し、終了コードと経過秒を表示
  local t0 t1 rc; echo "### \$ $*"; t0=$(date +%s.%N); "$@" 2>&1; rc=$?; t1=$(date +%s.%N)
  printf 'exit=%s  elapsed=%.2fs\n\n' "$rc" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')"
}
# lab_ns <resolv.conf> <コマンド...>: マウント名前空間の中だけで /etc/resolv.conf を差し替えて、一般ユーザー権限でコマンドを実行する
lab_ns() { local rf=$1; shift; sudo unshare -m sh -c 'mount --bind "$1" /etc/resolv.conf && shift && exec runuser -u "$1" -- "${@:2}"' _ "$rf" "$USER" "$@"; }

write_hosts() { # write_hosts <ok|wrongip|missing>
  case "$1" in
    ok)      printf '192.168.32.20 www.lab.example\n192.168.31.10 client.lab.example\n';;
    wrongip) printf '192.168.32.21 www.lab.example\n192.168.31.10 client.lab.example\n';;
    missing) printf '192.168.31.10 client.lab.example\n';;
    *) return 1;;
  esac
}

body() {
  echo "# exp9 ${role} ${action} ${a3} ${a4}  $(date -Is)  host=$(hostname -s)"
  case "$role" in client|server) ;; *) usage;; esac
  if [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"; exit 4
  fi
  echo "# ホスト名の確認: OK（host=$(hostname -s) と role=$role が一致）"
  case "$role:$action" in
    server:install-plan) run sudo dnf install --assumeno dnsmasq;;
    server:install)      run sudo dnf install -y dnsmasq; run rpm -q dnsmasq; run dnsmasq --version;;
    server:conf)
      run sudo sh -c "printf 'listen-address=192.168.32.20\nbind-interfaces\nno-resolv\ndomain=lab.example\nlocal=/lab.example/\nno-hosts\naddn-hosts=$HOSTSF\ncname=web.lab.example,www.lab.example\nlog-queries\nlog-facility=-\n' > $DCONF"
      run sudo sh -c "printf '192.168.32.20 www.lab.example\n192.168.31.10 client.lab.example\n' > $HOSTSF"
      run sudo restorecon -v $DCONF $HOSTSF
      run cat $DCONF
      run sudo dnsmasq --test;;
    server:record)
      case "$a3" in
        ok|wrongip|missing)
          echo "### \$ (write_hosts $a3) | sudo tee $HOSTSF"; write_hosts "$a3" | sudo tee $HOSTSF >/dev/null; echo "exit=${PIPESTATUS[1]}"; echo
          run sudo systemctl kill -s HUP dnsmasq
          run cat $HOSTSF;;
        show) run cat $HOSTSF;;
        *) usage;;
      esac;;
    server:web)
      case "$a3" in
        on)  run sudo sh -c 'echo "dns-test: index ok" > /var/www/html/index.html'; run sudo restorecon -v /var/www/html/index.html
             run sudo systemctl start httpd; run sudo firewall-cmd --add-service=http; run systemctl is-active httpd;;
        off) run sudo systemctl stop httpd; run sudo rm -f /var/www/html/index.html; run sudo firewall-cmd --reload;;
        *) usage;;
      esac;;
    server:start)  [ -f $DCONF ] || { echo "先に ./dns-test.sh server conf を実行してください"; exit 6; }
                   run sudo systemctl start dnsmasq; run systemctl is-active dnsmasq; run sudo ss -lunp 'sport = :53'; run sudo ss -ltnp 'sport = :53';;
    server:stop)   run sudo systemctl stop dnsmasq; run systemctl is-active dnsmasq;;
    server:status) run systemctl status dnsmasq --no-pager -l; run sudo ss -lunp 'sport = :53';;
    server:logs)
      n="${a3:-30}"; echo "### \$ sudo journalctl -u dnsmasq -n $n --no-pager"; sudo journalctl -u dnsmasq -n "$n" --no-pager 2>&1; echo;;
    server:fw)
      case "$a3" in
        open)  run sudo firewall-cmd --add-service=dns;;
        close) run sudo firewall-cmd --remove-service=dns;;
        reset) run sudo firewall-cmd --reload;;
        *) usage;;
      esac
      run sudo firewall-cmd --list-all;;
    server:capture)
      command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump が未導入です"; exit 5; }
      echo "### \$ sudo timeout -s INT 25 tcpdump -i any -nn -w $pcap 'port 53'   (25秒以内に client から dig / resolve)"
      sudo timeout -s INT 25 tcpdump -i any -nn -w $pcap 'port 53' 2>&1
      echo; echo "### \$ tcpdump -nn -r $pcap"; tcpdump -nn -r $pcap 2>&1;;
    server:teardown)
      run sudo systemctl stop dnsmasq
      run sudo systemctl stop httpd
      run sudo rm -f $DCONF $HOSTSF /var/www/html/index.html
      run sudo firewall-cmd --reload
      run systemctl is-active dnsmasq;;
    client:teardown) run rm -rf "$DLAB"; run ls -d "$DLAB";;
    client:install-plan) run sudo dnf install --assumeno bind-utils;;
    client:install)      run sudo dnf install -y bind-utils; run rpm -q bind-utils; run dig -v;;
    client:dig)
      [ -n "$a3" ] || usage; command -v dig >/dev/null 2>&1 || { echo "dig が未導入です（./dns-test.sh client install）"; exit 6; }
      if [ "$a3" = ptr ]; then [ -n "$a4" ] || usage; timed dig @${SERVER_IP} +time=2 +tries=1 +nocmd -x "$a4"
      else timed dig @${SERVER_IP} +time=2 +tries=1 +nocmd "$a3" "${a4:-A}"; fi;;
    client:resolve)
      [ -n "$a3" ] && [ -n "$a4" ] || usage
      mkdir -p "$DLAB"; rf="$DLAB/resolv-$a3.conf"
      case "$a3" in
        ok)       printf 'search lab.example\nnameserver %s\noptions timeout:1 attempts:1\n' "$SERVER_IP" > "$rf";;
        nosearch) printf 'nameserver %s\noptions timeout:1 attempts:1\n' "$SERVER_IP" > "$rf";;
        wrongns)  printf 'search lab.example\nnameserver 192.168.32.99\noptions timeout:1 attempts:1\n' > "$rf";;
        *) usage;;
      esac
      echo "### lab 用の resolv.conf（$a3）:"; cat "$rf"; echo
      sudo -v     # パスワード入力の待ち時間を、下の経過時間（elapsed）に含めないため、先に認証する
      timed lab_ns "$rf" getent hosts "$a4"
      echo "### \$ curl -sv --max-time 8 -o /dev/null -w 'http_code=%{http_code}\n' http://$a4/   （resolv.conf = $a3）"
      t0=$(date +%s.%N)
      lab_ns "$rf" curl -sv --max-time 8 -o /dev/null -w 'http_code=%{http_code}\n' "http://$a4/" 2>&1 | grep -E "^\* +(Could not resolve|Trying|Connected|connect to|Failed|Resolving|Host |Connection timed out|Closing connection)|^< HTTP|^http_code|curl:" | head -12
      rc=${PIPESTATUS[0]}; t1=$(date +%s.%N)
      printf 'curl_exit=%s  elapsed=%.2fs   (0=成功、6=名前が解決できない、7=接続できない、28=タイムアウト)\n\n' "$rc" "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')";;
    client:direct)
      echo "### \$ curl -sv --max-time 8 -o /dev/null -w 'http_code=%{http_code}\n' http://${SERVER_IP}/"
      curl -sv --max-time 8 -o /dev/null -w 'http_code=%{http_code}\n' "http://${SERVER_IP}/" 2>&1 | grep -E "^\* +(Trying|Connected|connect to|Failed|Connection timed out)|^< HTTP|^http_code|curl:" | head -12
      echo "curl_exit=${PIPESTATUS[0]}"; echo;;
    *) usage;;
  esac
}

body | tee "$out"
rc=${PIPESTATUS[0]}
# 引数の誤り（usage、終了コード 2）と、前提なし（6）は記録を残さない。ホスト名の不一致（4）は、安全上の記録として残す
[ "$rc" -eq 2 ] || [ "$rc" -eq 6 ] && rm -f "$out"
exit "$rc"
