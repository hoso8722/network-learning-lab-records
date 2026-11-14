#!/usr/bin/env bash
# 実験8: TLS 証明書エラー（C09）。自己署名・期限切れ・未来・ホスト名不一致・信頼されない CA を、curl と openssl s_client で切り分ける
#
# 対象ノード : client / server（AlmaLinux 9）。ベースライン（labs/common/baseline.sh up）と、server の httpd（実験7で導入済み）が前提。
# 使い方     : ./tls-test.sh <client|server> <action> [args...]
#
# 構成: client 192.168.31.10 – R1 – R2 – server 192.168.32.20（TCP 443。httpd + mod_ssl）。DNS は使わず、curl の --resolve で
#       www.lab.example を server の IP に対応づける（/etc/hosts は変更しない）。
#
# server の actions:
#   install-plan | install        mod_ssl の導入計画（--assumeno）/導入（sudo dnf install -y mod_ssl）。復旧: sudo dnf remove -y mod_ssl
#   ca init                       実験用の CA を ~/tls-lab/ca に作る（鍵と証明書）。CA の証明書を /var/www/html/lab-ca.crt に置く
#   cert make <ok|expired|future|mismatch|selfsigned>   証明書と鍵を ~/tls-lab/certs/<名前>.{crt,key} に作る
#        ok         CA 署名、www.lab.example、30日有効
#        expired    CA 署名、www.lab.example、有効期間が 2026-01-01〜2026-01-10（期限切れ）
#        future     CA 署名、www.lab.example、有効期間が 2027-11-01〜2027-12-01（まだ有効でない）
#        mismatch   CA 署名、other.lab.example（www.lab.example と名前が違う）、30日有効
#        selfsigned 自己署名、www.lab.example、30日有効
#   cert use <名前>               その証明書を /etc/pki/tls/lab/server.{crt,key} に置き、httpd を再起動
#                                 （初回は /etc/httpd/conf.d/lab-tls.conf = www.lab.example の 443 の VirtualHost も作る）
#   cert show                     いま使っている証明書（subject・issuer・有効期間・SAN・フィンガープリント）
#   ca fingerprint                CA 証明書の SHA-256 フィンガープリント（client が取得した CA と見比べる）
#   site <setup|show|teardown>   /var/www/html/index.html を作る/一覧/消す（実験7の teardown で消えているため。無いと 403 になる）
#   start | stop | status | logs [行数] | fw <open|close|reset> | capture | teardown
#                                 実験7と同じ（fw は http と https の両方）。teardown は、httpd を止め、~/tls-lab、conf、証明書を削除
# client の actions:
#   teardown                      ~/lab-ca.crt（取得した CA の証明書。公開情報）を削除
#   fetch-ca                      http://192.168.32.20/lab-ca.crt を ~/lab-ca.crt に保存し、フィンガープリントを表示
#   curl <ホスト名> [default|ca|insecure]   curl -sv https://<ホスト名>/（最大5秒、--resolve で server の IP）
#                                 default=システムの信頼ストア / ca=~/lab-ca.crt を信頼 / insecure=-k（検証しない）
#   sclient <ホスト名>            openssl s_client（-CAfile ~/lab-ca.crt、-verify_hostname）の検証結果と、証明書の内容
#
# 状態変更の方針: パッケージの導入（install）と /etc/ 配下のファイル、~/tls-lab 以外は、実行時のみ（systemctl start、firewall-cmd）。
#   永続設定は変更しない（--permanent / systemctl enable は使わない）。
# 鍵の扱い: 証明書の鍵は実験用で、記録（出力）には鍵の内容を出さない。~/tls-lab は 700、鍵は 600。リポジトリには入れない。
# ホスト名: 役割と一致しなければ全操作を中止する（例外なし）。引数の誤り（終了コード 2）と、証明書がない（6）は記録を残さない。
# 合否は判定しない。結果（終了コードと出力）を記録するのみ。

set -u
set -o pipefail
role="${1:-}"; action="${2:-}"; a3="${3:-}"; a4="${4:-}"
SERVER_IP=192.168.32.20
ts=$(date +%Y%m%dT%H%M%S)
out="exp8-${role}-${action}${a3:+-${a3//\//_}}${a4:+-$a4}-${ts}.txt"
pcap="exp8-server-${ts}.pcap"
LAB="$HOME/tls-lab"; CA="$LAB/ca"; CERTS="$LAB/certs"
CONF=/etc/httpd/conf.d/lab-tls.conf; PKI=/etc/pki/tls/lab
HOSTOK=www.lab.example

run() { echo "### \$ $*"; "$@" 2>&1; echo "exit=$?"; echo; }
usage() { sed -n '4,/^set -u/{/^set -u/!p}' "$0" >&2; exit 2; }

mkcert() { # mkcert <名前> <CN/SAN> <signed|self> [startdate enddate]
  local n=$1 cn=$2 mode=$3 sd=${4:-} ed=${5:-}
  mkdir -p "$CERTS"; chmod 700 "$LAB"
  if [ "$mode" = self ]; then
    run openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CERTS/$n.key" -out "$CERTS/$n.crt" -days 30 -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn"
  else
    run openssl req -new -newkey rsa:2048 -nodes -keyout "$CERTS/$n.key" -out "$CERTS/$n.csr" -subj "/CN=$cn" -addext "subjectAltName=DNS:$cn"
    if [ -n "$sd" ]; then run openssl ca -batch -config "$CA/ca.cnf" -in "$CERTS/$n.csr" -out "$CERTS/$n.crt" -notext -startdate "$sd" -enddate "$ed"
    else run openssl ca -batch -config "$CA/ca.cnf" -in "$CERTS/$n.csr" -out "$CERTS/$n.crt" -notext -days 30; fi
  fi
  chmod 600 "$CERTS/$n.key"
  run openssl x509 -in "$CERTS/$n.crt" -noout -subject -issuer -dates -ext subjectAltName
}

body() {
  echo "# exp8 ${role} ${action} ${a3} ${a4}  $(date -Is)  host=$(hostname -s)"
  case "$role" in client|server) ;; *) usage;; esac
  if [ "$(hostname -s)" != "$role" ]; then
    echo "中止: このVMのホスト名は '$(hostname -s)' ですが、指定の役割は '$role' です。正しいVMで実行してください。"; exit 4
  fi
  echo "# ホスト名の確認: OK（host=$(hostname -s) と role=$role が一致）"
  case "$role:$action" in
    server:install-plan) run sudo dnf install --assumeno mod_ssl;;
    server:install)      run sudo dnf install -y mod_ssl; run rpm -q mod_ssl openssl; run openssl version;;
    server:ca)
      case "$a3" in
        init)
          mkdir -p "$CA/newcerts" "$CERTS"; chmod 700 "$LAB"; : > "$CA/index.txt"; echo 1000 > "$CA/serial"
          cat > "$CA/ca.cnf" <<CNF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = $CA
database = $CA/index.txt
new_certs_dir = $CA/newcerts
serial = $CA/serial
certificate = $CA/ca.crt
private_key = $CA/ca.key
default_md = sha256
policy = policy_any
copy_extensions = copy
unique_subject = no
x509_extensions = v3_server
[ policy_any ]
commonName = supplied
[ v3_server ]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
CNF
          run openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CA/ca.key" -out "$CA/ca.crt" -days 3650 -subj "/CN=Lab Test CA" -addext basicConstraints=critical,CA:TRUE -addext keyUsage=keyCertSign,cRLSign
          chmod 600 "$CA/ca.key"
          run sudo cp "$CA/ca.crt" /var/www/html/lab-ca.crt
          run sudo chmod 644 /var/www/html/lab-ca.crt
          run sudo restorecon -v /var/www/html/lab-ca.crt
          run openssl x509 -in "$CA/ca.crt" -noout -subject -dates -fingerprint -sha256;;
        fingerprint) run openssl x509 -in "$CA/ca.crt" -noout -fingerprint -sha256;;
        *) usage;;
      esac;;
    server:cert)
      case "$a3" in
        make)
          [ -f "$CA/ca.crt" ] || { echo "先に ./tls-test.sh server ca init を実行してください"; exit 6; }
          case "$a4" in
            ok)         mkcert ok "$HOSTOK" signed;;
            expired)    mkcert expired "$HOSTOK" signed 20260101000000Z 20260110000000Z;;
            future)     mkcert future "$HOSTOK" signed 20271101000000Z 20271201000000Z;;
            mismatch)   mkcert mismatch other.lab.example signed;;
            selfsigned) mkcert selfsigned "$HOSTOK" self;;
            *) usage;;
          esac;;
        use)
          [ -f "$CERTS/$a4.crt" ] || { echo "証明書がありません: $CERTS/$a4.crt（先に cert make $a4）"; exit 6; }
          run sudo mkdir -p $PKI
          run sudo cp "$CERTS/$a4.crt" $PKI/server.crt
          run sudo cp "$CERTS/$a4.key" $PKI/server.key
          run sudo chown root:root $PKI/server.crt $PKI/server.key
          run sudo chmod 644 $PKI/server.crt
          run sudo chmod 600 $PKI/server.key
          run sudo restorecon -Rv $PKI
          if [ ! -f $CONF ]; then
            run sudo sh -c "printf '<VirtualHost *:443>\n    ServerName $HOSTOK\n    DocumentRoot /var/www/html\n    SSLEngine on\n    SSLCertificateFile $PKI/server.crt\n    SSLCertificateKeyFile $PKI/server.key\n    ErrorLog logs/lab_ssl_error_log\n    CustomLog logs/lab_ssl_access_log combined\n</VirtualHost>\n' > $CONF"
          fi
          run sudo httpd -t
          run sudo systemctl restart httpd
          run systemctl is-active httpd
          # 初回は、restart の前の httpd -t が ssl.conf 既定の localhost.crt の不在で失敗することがある（実験8で観測）。起動後にもう一度検査する
          run sudo httpd -t
          run sudo ss -tlnp 'sport = :443';;
        show)
          run openssl x509 -in $PKI/server.crt -noout -subject -issuer -dates -ext subjectAltName -fingerprint -sha256;;
        *) usage;;
      esac;;
    server:site)
      case "$a3" in
        setup)    run sudo sh -c 'echo "tls-test: index ok" > /var/www/html/index.html'; run sudo restorecon -v /var/www/html/index.html; run ls -lZ /var/www/html;;
        show)     run ls -lZ /var/www/html;;
        teardown) run sudo rm -f /var/www/html/index.html; run ls -lZ /var/www/html;;
        *) usage;;
      esac;;
    server:start)  run sudo systemctl start httpd; run systemctl is-active httpd; run sudo ss -tlnp 'sport = :80 or sport = :443';;
    server:stop)   run sudo systemctl stop httpd; run systemctl is-active httpd;;
    server:status) run systemctl status httpd --no-pager -l; run sudo ss -tlnp 'sport = :80 or sport = :443';;
    server:fw)
      case "$a3" in
        open)  run sudo firewall-cmd --add-service=http; run sudo firewall-cmd --add-service=https;;
        close) run sudo firewall-cmd --remove-service=http; run sudo firewall-cmd --remove-service=https;;
        reset) run sudo firewall-cmd --reload;;
        *) usage;;
      esac
      run sudo firewall-cmd --list-all;;
    server:logs)
      n="${a3:-15}"
      for f in /var/log/httpd/error_log /var/log/httpd/lab_ssl_error_log /var/log/httpd/lab_ssl_access_log; do
        echo "### \$ sudo tail -n $n $f"; sudo tail -n "$n" "$f" 2>&1; echo
      done;;
    server:capture)
      command -v tcpdump >/dev/null 2>&1 || { echo "tcpdump が未導入です"; exit 5; }
      echo "### \$ sudo timeout -s INT 25 tcpdump -i any -nn -w $pcap 'tcp port 443'   (25秒以内に client から curl)"
      sudo timeout -s INT 25 tcpdump -i any -nn -w $pcap 'tcp port 443' 2>&1
      echo; echo "### \$ tcpdump -nn -r $pcap"; tcpdump -nn -r $pcap 2>&1;;
    server:teardown)
      run sudo systemctl stop httpd
      run sudo rm -rf $PKI $CONF /var/www/html/lab-ca.crt /var/www/html/index.html "$LAB"
      run sudo firewall-cmd --reload
      run systemctl is-active httpd;;
    client:teardown) run rm -f "$HOME/lab-ca.crt"; run ls -l "$HOME/lab-ca.crt";;
    client:fetch-ca)
      run curl -s --max-time 5 -o "$HOME/lab-ca.crt" "http://${SERVER_IP}/lab-ca.crt"
      run openssl x509 -in "$HOME/lab-ca.crt" -noout -subject -dates -fingerprint -sha256;;
    client:curl)
      [ -n "$a3" ] || usage
      case "${a4:-default}" in
        default)  opt=();;
        ca)       opt=(--cacert "$HOME/lab-ca.crt");;
        insecure) opt=(-k);;
        *) usage;;
      esac
      echo "### \$ curl -sv --max-time 5 ${opt[*]} --resolve ${a3}:443:${SERVER_IP} -o /dev/null -w 'http_code=%{http_code}\n' https://${a3}/"
      errf=$(mktemp)
      codeline=$(curl -sv --max-time 5 "${opt[@]}" --resolve "${a3}:443:${SERVER_IP}" -o /dev/null -w 'http_code=%{http_code}' "https://${a3}/" 2>"$errf")
      crc=$?
      # 詳細（stderr）は長いので、TLS の細部の行（ヘッダーの種別だけの行）を除いて表示し、結果の行は最後に必ず出す
      grep -v '^{ \[\|^} \[' "$errf"
      rm -f "$errf"
      echo "${codeline}"
      echo "curl_exit=${crc}   (0=成功、35=TLS ハンドシェイク失敗、60=証明書の検証失敗、7=接続できない、28=タイムアウト)"; echo;;
    client:sclient)
      [ -n "$a3" ] || usage
      echo "### \$ openssl s_client -connect ${SERVER_IP}:443 -servername ${a3} -CAfile ~/lab-ca.crt -verify_hostname ${a3} </dev/null"
      openssl s_client -connect "${SERVER_IP}:443" -servername "${a3}" -CAfile "$HOME/lab-ca.crt" -verify_hostname "${a3}" </dev/null 2>&1 | grep -E "^(depth|verify|Verification|Verify return code|subject|issuer)|^ *(Protocol|Cipher)|^New,|error|Certificate chain|^ [0-9] s:|   i:|   v:|   a:" | sed -n '1,30p'
      echo "s_client_exit=${PIPESTATUS[0]}"; echo
      echo "### \$ openssl s_client ... | openssl x509 -noout -subject -issuer -dates -ext subjectAltName"
      openssl s_client -connect "${SERVER_IP}:443" -servername "${a3}" </dev/null 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName 2>&1; echo;;
    *) usage;;
  esac
}

body | tee "$out"
rc=${PIPESTATUS[0]}
# 引数の誤り（usage、終了コード 2）と、前提がない（証明書が未作成などの、名前の打ち間違い、終了コード 6）は、記録を残さない。
# ホスト名の不一致（4）は、安全上の記録として残す
[ "$rc" -eq 2 ] || [ "$rc" -eq 6 ] && rm -f "$out"
exit "$rc"
