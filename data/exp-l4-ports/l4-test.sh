#!/usr/bin/env bash
# 実験6: L4（TCP/UDP とポート）。待ち受け、接続、ファイアウォールの違いを、症状と capture で区別する
#
# 対象ノード : client / server（AlmaLinux 9）。ルーター(router, router2)は実験4の route-test.sh で正しい状態にしておく。
# 使い方     : ./l4-test.sh <client|server> <action> [args...]
#
# 構成（実験4・5と同じ）: client 192.168.31.10 – R1 – R2 – server 192.168.32.20（TCP 8080 / UDP 9999 を使う）
#
# server の actions:
#   listen <start|stop>           HTTP サーバー(python3 -m http.server、TCP 8080、192.168.32.20 にだけ bind、~/l4-www/ のみを公開)
#   udp-listen <start|stop>       UDP エコー(python3、9999、192.168.32.20 にだけ bind)
#   ss                            待ち受け・接続の状態(ss -tlnp / -ulnp / -tn)
#   fw show                       firewalld の既定ゾーンの設定
#   fw open <ポート> <tcp|udp>    実行時だけポートを許可（--permanent なし）
#   fw close <ポート> <tcp|udp>   許可を外す
#   fw rule <drop|reject|reset|udp-drop>  client(192.168.31.10) からの TCP 8080（udp-drop は UDP 9999）に対する rich rule を追加（実行時のみ）
#                                   drop=破棄(無応答) / reject=既定の拒否(ICMP) / reset=TCP RST で拒否 / udp-drop=UDP 9999 を破棄
#   fw reset                      実行時の変更を破棄（firewall-cmd --reload）
#   capture                       tcpdump(25秒、TCP 8080 / UDP 9999 / ICMP)。pcap は時刻付きの名前
#   teardown                      待ち受けを止め、~/l4-www を片付け、firewalld をリロード
# client の actions:
#   curl [URL]                    curl -v（最大5秒）。既定の URL は http://192.168.32.20:8080/ 。curl の終了コードと http_code を表示
#   udp <IP> <ポート> <文字列>    python3 で UDP を送り、返信 / エラー / タイムアウトを表示
#   ss                            ss -tn（SYN-SENT などの状態を見る）
#
# 状態変更の方針: 起動するのはユーザー権限のプロセスのみ。firewalld は実行時だけ変更する（再起動か fw reset で戻る）。
# firewall の変更（fw open/close/rule/reset）:
#   対象=server の firewalld の既定ゾーン（実行時のみ） / 影響=server への TCP 8080 / UDP 9999 の通信の可否 / 復旧=fw reset または teardown
# ホスト名: 役割と一致しなければ全操作を中止する（例外なし）。
# 合否は判定しない。結果（終了コードと出力）を記録するのみ。

set -u
set -o pipefail
role="${1:-}"; action="${2:-}"; a3="${3:-}"; a4="${4:-}"; a5="${5:-}"
SERVER_IP=192.168.32.20; CLIENT_IP=192.168.31.10
HTTP_PORT=8080; UDP_PORT=9999
WWW="$HOME/l4-www"; PIDF="$HOME/l4-http.pid"; UPIDF="$HOME/l4-udp.pid"; UPY="$HOME/l4-udp-echo.py"
ts=$(date +%Y%m%dT%H%M%S)
out="exp6-${role}-${action}${a3:+-$a3}-${ts}.txt"
pcap="exp6-server-${ts}.pcap"

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }

body() {
  echo "# exp6 ${role} ${action} ${a3} ${a4} ${a5}  $(date -Is)  host=$(hostname -s)"
  case "$role" in client|server) ;; *) usage;; esac
  if [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"; exit 4
  fi
  echo "# ホスト名の確認: OK（host=$(hostname -s) と role=$role が一致）"
  # 一般ユーザーでは firewall-cmd --get-default-zone が空になる（2026-10-23 に実測）ため sudo で取り、空なら中止する
  zone() { sudo firewall-cmd --get-default-zone 2>/dev/null; }

  case "$role:$action" in
    server:listen)
      case "$a3" in
        start)
          mkdir -p "$WWW"; echo "hello from server" > "$WWW/index.html"
          if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then echo "すでに起動中（pid $(cat "$PIDF")）"; else
            nohup python3 -m http.server $HTTP_PORT --bind $SERVER_IP --directory "$WWW" >"$HOME/l4-http.log" 2>&1 &
            echo $! > "$PIDF"; sleep 1; echo "起動: pid $(cat "$PIDF")"; fi
          run ss -tlnp;;
        stop)
          if [ -f "$PIDF" ]; then run kill "$(cat "$PIDF")"; rm -f "$PIDF"; else echo "起動していません"; fi
          sleep 1; run ss -tlnp;;
        *) usage;;
      esac;;
    server:udp-listen)
      case "$a3" in
        start)
          cat > "$UPY" <<'PY'
import socket, sys
ip, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind((ip, port))
while True:
    d, a = s.recvfrom(1024)
    s.sendto(b"echo: " + d, a)
PY
          if [ -f "$UPIDF" ] && kill -0 "$(cat "$UPIDF")" 2>/dev/null; then echo "すでに起動中（pid $(cat "$UPIDF")）"; else
            nohup python3 "$UPY" $SERVER_IP $UDP_PORT >"$HOME/l4-udp.log" 2>&1 &
            echo $! > "$UPIDF"; sleep 1; echo "起動: pid $(cat "$UPIDF")"; fi
          run ss -ulnp;;
        stop)
          if [ -f "$UPIDF" ]; then run kill "$(cat "$UPIDF")"; rm -f "$UPIDF"; else echo "起動していません"; fi
          sleep 1; run ss -ulnp;;
        *) usage;;
      esac;;
    server:ss) run ss -tlnp; run ss -ulnp; run ss -tn;;
    server:fw)
      Z=$(zone); echo "# 既定ゾーン: $Z"
      [ -n "$Z" ] || { echo "中止: 既定ゾーンを取得できませんでした（空のゾーンで firewall-cmd を実行しません）"; exit 6; }
      case "$a3" in
        show)  run sudo firewall-cmd --get-active-zones; run sudo firewall-cmd --zone="$Z" --list-all;;
        open)  [ -n "$a4" ] && [ -n "$a5" ] || usage; run sudo firewall-cmd --zone="$Z" --add-port="$a4/$a5";;
        close) [ -n "$a4" ] && [ -n "$a5" ] || usage; run sudo firewall-cmd --zone="$Z" --remove-port="$a4/$a5";;
        rule)
          case "$a4" in
            drop)   R="rule family=\"ipv4\" source address=\"$CLIENT_IP\" port port=\"$HTTP_PORT\" protocol=\"tcp\" drop";;
            reject) R="rule family=\"ipv4\" source address=\"$CLIENT_IP\" port port=\"$HTTP_PORT\" protocol=\"tcp\" reject";;
            reset)  R="rule family=\"ipv4\" source address=\"$CLIENT_IP\" port port=\"$HTTP_PORT\" protocol=\"tcp\" reject type=\"tcp-reset\"";;
            udp-drop) R="rule family=\"ipv4\" source address=\"$CLIENT_IP\" port port=\"$UDP_PORT\" protocol=\"udp\" drop";;
            *) usage;;
          esac
          run sudo firewall-cmd --zone="$Z" --add-rich-rule="$R";;
        reset) run sudo firewall-cmd --reload;;
        *) usage;;
      esac
      case "$a3" in reset|show) ;; *) run sudo firewall-cmd --zone="$Z" --list-all;; esac;;
    server:capture)
      command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump が未導入です"; exit 5; }
      echo "### \$ sudo timeout -s INT 25 tcpdump -i enp0s9 -nn -w $pcap 'tcp port $HTTP_PORT or udp port $UDP_PORT or icmp'   (25秒以内に client から接続)"
      sudo timeout -s INT 25 tcpdump -i enp0s9 -nn -w $pcap "tcp port $HTTP_PORT or udp port $UDP_PORT or icmp" 2>&1
      echo; echo "### \$ tcpdump -nn -r $pcap"
      tcpdump -nn -r $pcap 2>&1;;
    server:teardown)
      for pf in "$PIDF" "$UPIDF"; do [ -f "$pf" ] && { kill "$(cat "$pf")" 2>/dev/null; rm -f "$pf"; }; done
      rm -rf "$WWW" "$UPY"
      run sudo firewall-cmd --reload
      run ss -tlnp;;

    client:curl)
      url="${a3:-http://$SERVER_IP:$HTTP_PORT/}"
      echo "### \$ curl -v --no-progress-meter --max-time 5 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}s\\n' $url"
      curl -v --no-progress-meter --max-time 5 -o /dev/null -w 'http_code=%{http_code} time_total=%{time_total}s\n' "$url" 2>&1
      echo "curl_exit=$?   (0=成功 / 7=接続できない(拒否・到達不能) / 28=タイムアウト)";;
    client:udp)
      [ -n "$a3" ] && [ -n "$a4" ] && [ -n "$a5" ] || usage
      python3 - "$a3" "$a4" "$a5" <<'PY'
import socket, sys, errno
ip, port, msg = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.connect((ip, port))
try:
    s.send(msg.encode())
    print("reply:", s.recv(1024).decode())
except socket.timeout:
    print("timeout (3秒、応答なし)")
except OSError as e:
    print("OSError errno=%s (%s)" % (e.errno, errno.errorcode.get(e.errno, "?")), "-", e)
PY
      echo "py_exit=$?";;
    client:ss) run ss -tn;;
    *) usage;;
  esac
}

body | tee "$out"
rc=${PIPESTATUS[0]}
# 引数の誤り（usage、終了コード 2）は、記録を残さない。ホスト名の不一致（4）などは、安全上の記録として残す
[ "$rc" -eq 2 ] && rm -f "$out"
exit "$rc"
