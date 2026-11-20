# 実験8: TLS 証明書エラー（C09）

> `*-test.sh` という名前ですが、テストではありません。実験の操作と観測をまとめた補助スクリプトで、合否は判定せず、結果と終了コードを記録するだけです(名前は、過去の記事との対応のため、変えていません)。

- 目的: 証明書の問題（自己署名、期限切れ、まだ有効でない、ホスト名の不一致、信頼されない CA）を、`curl` の終了コードとメッセージ、`openssl s_client` の検証結果で切り分ける素材を採取する。
- 状態: **進行中**（2026-10-25 13:31 に `mod_ssl` を導入済み）。スクリプトは `tls-test.sh`（server / client の役割を引数で指定。ホスト名が役割と一致しなければ中止。引数の誤りでは記録を残さない）。出力は VM 側の `exp8-<役割>-<動作>-<時刻>.txt`。
- 追加で導入するもの: server の `mod_ssl`（`install-plan` でサイズを先に確認する。見込みは小さいが未確認）。実験7で導入済みの `httpd` を使う。

## 構成と名前の扱い
- client 192.168.31.10 – R1 – R2 – server 192.168.32.20、TCP 443。
- DNS は使わない。client の `curl --resolve www.lab.example:443:192.168.32.20` で名前を対応づける（`/etc/hosts` は変更しない）。
- server は、実験用の CA（`~/tls-lab/ca`）で署名した証明書を差し替える（`cert use <名前>`）。client は CA の証明書を `http://192.168.32.20/lab-ca.crt` から取得する（HTTP。フィンガープリントを server の `ca fingerprint` と見比べる。ラボ内の簡易な配布で、実運用では別経路で確認する）。

## 証明書の種類と、予想される症状 [予想。実測で確認する]
| 名前 | 内容 | curl（`ca` で CA を信頼）| s_client の検証 |
|---|---|---|---|
| ok | CA 署名、www.lab.example、30日 | 成功（200） | `Verification: OK`、return code 0 |
| expired | 有効期間 2026-01-01〜01-10 | 終了コード 60（certificate has expired） | return code 10（certificate has expired） |
| future | 有効期間 2027-11-01〜12-01 | 60（not yet valid） | return code 9（certificate is not yet valid） |
| mismatch | SAN が other.lab.example | 60（no alternative certificate subject name matches） | `-verify_hostname` で 62（Hostname mismatch） |
| selfsigned | 自己署名、www.lab.example | 60（self-signed certificate） | return code 18 |
| ok（CA を信頼しない = `default`） | — | 60（unable to get local issuer certificate、または self-signed certificate in certificate chain） | return code 20 または 19 |
| すべて（`insecure` = `-k`） | — | 200（検証しない。警告の意味を示す素材） | — |

- 上の検証コード（10 / 9 / 62）は、この開発環境（WSL、OpenSSL 3.0.13）で `openssl verify -CAfile ... -verify_hostname` により、CA 署名の期限切れ・未来・名前不一致の3つが期待どおりのエラーになることを確認した（VM 上の実験ではない。**VM の OpenSSL は 3.5.5 で、この確認の 3.0.13 とは異なる**ため、VM で `openssl ca` の `-startdate` / `-enddate` などが同じ動作をするかは実測で確認する）。
- curl の終了コード・メッセージ、error_log の内容、`s_client` の出力は、VM での実測が必要。

## 手順（WSL の端末。ラボ用 ssh-agent に鍵が載っていること）
1. ベースライン: `labs/common/baseline.sh up`。時刻: `labs/common/sync-all-auto.sh --check-only`（証明書の有効期限の判定に、VM の時刻が重要）。
2. スクリプトを送る: `labs/common/transfer.sh push --exp-dir exp-tls-certs --files tls-test.sh --only client,server`
3. server（`ssh -p 2223 127.0.0.1`）で、順に実行:
   - `./tls-test.sh server install-plan` → `install`
   - `./tls-test.sh server ca init`
   - `./tls-test.sh server cert make ok`（続けて `expired`、`future`、`mismatch`、`selfsigned`）
   - `./tls-test.sh server cert use ok` → `start` → `fw open`
4. client（`ssh -p 2222 127.0.0.1`）で:
   - `./tls-test.sh client fetch-ca`（フィンガープリントを server の `ca fingerprint` と見比べる）
   - `./tls-test.sh client curl www.lab.example default`（CA を信頼しない状態の症状）
   - `./tls-test.sh client curl www.lab.example ca`、`./tls-test.sh client sclient www.lab.example`
5. 証明書を切り替えて繰り返す: server で `cert use expired`（→ `future`、`mismatch`、`selfsigned`）→ client で `curl ... ca` と `sclient`。各回のあと server で `logs` を取る。`insecure` も1回試す。
6. （任意）server で `capture` → 25 秒以内に client から `curl`。TLS のハンドシェイクのパケット（Client Hello など）を取る。TLS 1.3 では証明書の中身は暗号化されて見えない見込み（未確認）。
7. 片付け: `./tls-test.sh server teardown`（`httpd` と `mod_ssl` のパッケージは残す）。記録の回収: `labs/common/transfer.sh pull --exp-dir exp-tls-certs --pattern 'exp8-*'`。

## 影響と復旧（AGENTS.md の規則）
- 対象: server のパッケージ（`mod_ssl`）、`/etc/pki/tls/lab/`、`/etc/httpd/conf.d/lab-tls.conf`、`/var/www/html/lab-ca.crt`、`~/tls-lab/`（CA の鍵・証明書。実験用）、実行時の firewalld と httpd の状態。
- 復旧: `teardown`、`sudo dnf remove -y mod_ssl`（必要なら httpd も）、またはスナップショット。`systemctl enable` と `--permanent` は使わない。
- 鍵: 実験用の CA とサーバー証明書の鍵は `~/tls-lab`（700）と `/etc/pki/tls/lab`（600）にだけ置く。出力には鍵の内容を出さない。**リポジトリには鍵を入れない**（回収対象は `exp8-*` の記録と pcap のみ）。
- 公開範囲: 443 は全アドレスで待ち受ける。`fw open` で、`public` ゾーン（NAT 側の `enp0s3` を含む）に https を許可する（実験7と同じ注意。NAT の外からは届かない構成。確認はしていない）。
- 未確認: `mod_ssl` 導入後の `ssl.conf` の既定の仮想ホスト（`_default_:443`）と、`lab-tls.conf` の `*:443` の関係（設定の読み込み順で `lab-tls.conf` が先になる想定）、SELinux が `/etc/pki/tls/lab` の鍵を httpd に読ませるか（`restorecon` で `cert_t` になる想定）。

## 実施記録
### 2026-10-25 13:28〜13:31（導入）
- `install-plan`（13:28）: `mod_ssl` 1:2.4.62-13.el9_8.9（112 k）と依存の `sscg` 4.0.3-2.el9（49 k）の2パッケージ。**ダウンロード 161 k、導入後 390 k**。`Operation aborted.`（exit=1、`--assumeno` の仕様どおり）。
- `install`（13:31）: 終了コード 0。`rpm -q`: `mod_ssl-2.4.62-13.el9_8.9`、`openssl-3.5.5-2.el9_8`。`openssl version`: **OpenSSL 3.5.5 27 Jan 2026**（VM）。
- 通信量は 161 kB で、実験7（httpd、2.0 MB）より小さい。

### 2026-10-25 13:36〜13:48（CA、5種類の証明書、ok の確認）
- `ca init`（13:36）: 終了コード 0。CA `CN=Lab Test CA`、有効期間 2026-10-25〜2036-10-22、SHA-256 フィンガープリント `A6:42:96:CC:...:28:A8:01`（`client fetch-ca` で取得した CA のものと**一致**）。OpenSSL 3.5.5 で `openssl ca` が動作した [実測]。
- `cert make`（13:36〜13:40）: 5種類とも作成できた [実測]。`openssl ca` の出力に `Certificate is to be certified until Jan 10 00:00:00 2026 GMT (-288 days)`（expired）、`... Dec 1 00:00:00 2027 GMT (401 days)`（future）。subject は `ASN.1 12:'...'`（UTF8String）と表示される。
  | 名前 | notBefore | notAfter | subject / SAN |
  |---|---|---|---|
  | ok | 2026-10-25 04:36:36 GMT | 2026-11-24 04:36:36 GMT | CN=www.lab.example / DNS:www.lab.example |
  | expired | 2026-01-01 00:00:00 | 2026-01-10 00:00:00 | 同上 |
  | future | 2027-11-01 00:00:00 | 2027-12-01 00:00:00 | 同上 |
  | mismatch | 2026-10-25 04:39:48 | 2026-11-24 04:39:48 | CN=other.lab.example / DNS:other.lab.example |
  | selfsigned | 2026-10-25 04:40:09 | 2026-11-24 04:40:09 | issuer = subject = CN=www.lab.example |
  - 時刻: 証明書の GMT（04:36）と、実行時の JST（13:36）は 9 時間差で矛盾しない。
- `cert use ok`（13:44）: ファイルの配置（`/etc/pki/tls/lab/`）、`restorecon -Rv`（出力なし = 変更なし）、`lab-tls.conf` の作成は成功。**`httpd -t` は終了コード 1**: `AH00526: Syntax error on line 85 of /etc/httpd/conf.d/ssl.conf: SSLCertificateFile: file '/etc/pki/tls/certs/localhost.crt' does not exist or is empty`。ところが続く `systemctl restart httpd` は成功（active）で、443 を待ち受けた。
  - 原因は候補: `mod_ssl` 導入直後は `ssl.conf` が参照する自己署名の `localhost.crt` がまだなく、httpd の起動時（`sscg` を使う `httpd-init` などのサービス）に生成される。未確認（`localhost.crt` の作成時刻と、`systemctl status` で確認できる）。設定ミスではなかった（restart 後に client が `lab-tls.conf` の証明書で接続できた）。
  - スクリプトを修正: `restart` の後にも `httpd -t` を実行する。
- client（13:48）[実測]:
  - `curl www.lab.example default`（システムの信頼ストア）: **終了コード 60**、`SSL certificate problem: unable to get local issuer certificate`。curl 側が `TLS alert, unknown CA (560)` を送って接続を閉じた。`CAfile: /etc/pki/tls/certs/ca-bundle.crt`。`http_code=000`。
  - `curl ... ca`（`--cacert ~/lab-ca.crt`）: **終了コード 0**。`SSL connection using TLSv1.3 / TLS_AES_256_GCM_SHA384`、`subjectAltName: host "www.lab.example" matched cert's "www.lab.example"`、`SSL certificate verify ok.`。**`http_code` の行が記録に出ていない**（`sed -n '1,45p'` による表示の打ち切り。スクリプトを修正済み: 結果の行は必ず出す）。成功時の `http_code` は再実行で取る。
  - `sclient`: `depth=1 CN=Lab Test CA` / `depth=0 CN=www.lab.example` ともに `verify return:1`、`Verification: OK`、`Verify return code: 0 (ok)`、`Protocol: TLSv1.3`。

### 2026-10-25 13:53〜13:56（expired）
- 修正版のスクリプトで再実行 [実測]。`cert use expired`: `restart` の前の `httpd -t` も `Syntax OK`（`ok` のときの AH00526 は出なかった）。`localhost.crt` が最初の起動で生成された、という候補（上記）と矛盾しない。確認はしていない。
- client `curl ... ca`: **終了コード 60**、`TLS alert, certificate expired (557)`、`SSL certificate problem: certificate has expired`、`http_code=000`。修正後は `http_code` の行も出る。
- client `sclient`: `verify error:num=10:certificate has expired`、`Verification error: certificate has expired`、`Verify return code: 10 (certificate has expired)`。`NotBefore: Jan 1 2026` / `NotAfter: Jan 10 2026`。**`s_client` は検証に失敗しても接続を続け（`New, TLSv1.3`、`s_client_exit=0`）、終了コードでは失敗を判定できない**。判定は `Verify return code` の行で行う。
- 参考: `-bash: syntax error near unexpected token '('` は、`curl_exit=... (0=成功...)` の出力行をシェルに貼ったための表示で、スクリプトの問題ではない。

### 2026-10-25 14:09〜14:27（future、mismatch、selfsigned）
すべて `curl ... ca`（`--cacert ~/lab-ca.crt`）と `sclient` の結果 [実測]。server 側は各回とも `cert use <名前>` → `httpd -t` は `Syntax OK`（AH00558 の ServerName の警告のみ）→ restart → 443 で待ち受け。

| 証明書 | curl 終了コード | curl のメッセージ | curl が送った TLS alert | s_client の `Verify return code` |
|---|---|---|---|---|
| expired | 60 | `certificate has expired` | `certificate expired (557)` | 10 (certificate has expired) |
| future | 60 | `certificate is not yet valid` | `bad certificate (554)` | 9 (certificate is not yet valid) |
| mismatch | 60 | `no alternative certificate subject name matches target host name 'www.lab.example'`（`subjectAltName does not match www.lab.example`） | `close notify (256)`（ハンドシェイクは完了してから閉じた） | 62 (hostname mismatch) |
| selfsigned | 60 | `self-signed certificate` | `unknown CA (560)` | 18 (self-signed certificate) |
| （CA を信頼しない）default の ok | 60 | `unable to get local issuer certificate` | `unknown CA (560)` | （未取得） |

- 観察:
  - curl の終了コードはどれも 60 で、**終了コードだけでは原因を切り分けられない**。メッセージ（`SSL certificate problem: ...`）と s_client の `Verify return code` で区別する。
  - **mismatch だけ、TLS のハンドシェイクが最後まで進み（`CERT verify`、`Finished`、`SSL connection using TLSv1.3`）、そのあとで curl がホスト名の不一致を判定して閉じた**。他の3つは、サーバーの Certificate を受け取った時点で、curl が alert を送って中断した。ホスト名の検証が、証明書チェーンの検証とは別の段階で行われている、と読める（候補）。
  - mismatch の `s_client` では、`depth=0 CN=other.lab.example` で `verify error:num=62:hostname mismatch` が先に出て、そのあとに `depth=1 CN=Lab Test CA` の検証が続く（チェーン自体は有効）。
  - curl が表示する alert の番号（557、554、560、256）は、TLS の alert の値に curl が 512 や 256 を足した表示、と読める（例: 557 = 512 + 45 `certificate_expired`）。一般知識で、未確認。
  - `s_client` は検証に失敗しても接続を続け、終了コード 0 で終わる。判定は `Verify return code` の行（既述）。
  - `future` の alert は `bad certificate (554)` で、`expired` とは別の alert になった。

### 2026-10-25 15:38（ok の再確認: http_code=403）
- `cert use ok` のまま `curl ... ca`: TLS は成功（`SSL certificate verify ok`、TLS 1.3）したが、**`HTTP/1.1 403 Forbidden`**（`http_code=403`、`curl_exit=0`）。`Content-Length: 5760`、`Last-Modified: Mon, 24 Mar 2025 16:15:24 GMT`、`Server: Apache/2.4.62 (AlmaLinux) OpenSSL/3.5.5`。
- キャッシュではない（curl は応答をキャッシュしない。`Date` は現在の時刻）。
- 原因は候補: `/var/www/html/index.html` が無い。実験7の `teardown` で削除したため（今回の実験では作っていない）。ディレクトリに index がないとき、httpd は 403 を返し、パッケージの標準ページ（`Last-Modified` が 2025-03 のパッケージ内のファイル、サイズ約 5.7 KB）を表示する、と読める。未確認（`ls -l /var/www/html` と error_log の `Directory index forbidden by Options directive` で確認する）。
- 切り分けとしての意味: **TLS（証明書）の成功と、HTTP の応答（コンテンツ）は別の層**。`curl_exit=0` は「TLS と HTTP のやり取りが完了した」ことを示し、`http_code` が 2xx とは限らない。
- 対応: `tls-test.sh` に `server site setup|show|teardown` を追加（`index.html` を作る）。

### 2026-10-25 15:45〜16:01（403 の原因、200、insecure）
- 原因の確認 [実測]: `http-test.sh server site show`（15:45）で、`/var/www/html` には `lab-ca.crt` しかなく、**`index.html` が無かった**。先の 403 は、index が無いディレクトリへのアクセスだった、という候補を裏づける（error_log は未確認）。
- 15:48、実験7の `http-test.sh server site setup` で `index.html` ほか（`perm.html`、`selinux.html`、CGI、`lab-http.conf`）を作った（TLS の実験用には `tls-test.sh server site setup` が追加されている）。
- 15:49 `curl ... ca`（ok）: **`http_code=200`**、`curl_exit=0`。`Content-Length: 10`、`Last-Modified: Sun, 25 Oct 2026 06:48:24 GMT`。`Server: Apache/2.4.62 (AlmaLinux) OpenSSL/3.5.5`。
- 15:59 `cert use selfsigned` → 16:00 `curl ... insecure`（`-k`）: **`http_code=200`**、`curl_exit=0`。curl は `SSL certificate verify result: self-signed certificate (18), continuing anyway.` と表示した（検証の結果は出すが、続行する）。同じ証明書は、`ca` では終了コード 60 で失敗していた。`-k` は証明書の問題を隠す。**表示される「verify result」の行が、隠された問題の手がかり**。
- 16:01 `cert use ok` で元に戻した。
- 注意: `http-test.sh server log 30`（`logs` のタイプミス）が実行され、使い方が表示された。その時点の server 上のスクリプトは古い版（引数の誤りでも記録ファイルが残る）のため、`~/exp7-server-log-30-*.txt` が server に残っている可能性がある（回収の対象外。不要なら削除する）。

### 2026-10-25 16:10〜16:13（サーバーのログ、capture、片付け、回収）
**サーバー側のログ（`server logs 80`、`from-server/exp8-server-logs-80-20261025T161011.txt`）[実測]**
- `lab_ssl_access_log`: 記録されたのは、HTTP まで届いた5件だけ（13:48 / 15:35 / 15:38 が **403**、15:49 / 16:00 が **200**）。**証明書の検証に失敗した接続（default、expired、future、mismatch、selfsigned の各 `ca`）は、サーバーのログに何も残っていない**。サーバーからは「クライアントが途中で切った」だけで、理由は見えない。
- `lab_ssl_error_log`:
  - `AH01276: Cannot serve directory /var/www/html/: No matching DirectoryIndex (index.html) found, and server-generated directory index forbidden by Options directive`（13:48、15:35、15:38）。**403 の原因が確認できた**（index.html が無い）。13:48 の `ok` の初回の `curl ... ca` は、`http_code` の行が記録から落ちていたが、実際は **403** だった（アクセスログの `13:48:08 ... 403 5760`）。
  - `AH01909: www.lab.example:443:0 server certificate does NOT include an ID which matches the server name`（14:22:43、mismatch の証明書での起動時）。予想どおり、**サーバーが名前の不一致に気づける唯一の機会**（起動時の警告）。
  - `AH01906: ... server certificate is a CA certificate (BasicConstraints: CA == TRUE !?)`（14:25、14:27、15:59、selfsigned の証明書での起動時）。`openssl req -x509` の既定で `CA:TRUE` が付くため、と読める（候補）。
  - **expired と future の証明書では、起動時も接続時も、サーバー側のログに何も出なかった**。
- `error_log`: 起動のたびに `AH01882: Init: this version of mod_ssl was compiled against a newer library (OpenSSL 3.5.8 25 Aug 2026 (OpenSSL 3.5.5 27 Jan 2026), version currently loaded is 0x30500050) - may result in undefined or erroneous behavior`（`mod_ssl` が 3.5.8 でビルドされ、読み込まれているライブラリは 3.5.5）。原因は候補: パッケージの更新の時間差（`mod_ssl` が `openssl` より新しい）。影響は未確認。動作には問題がなかった。
- `AH00558`（ServerName 未設定）は毎回出る。

**capture（server、`tcp port 443`、25秒、ok の証明書での `curl ... ca` 1回、`from-server/exp8-server-20261025T161118.pcap`）[実測]**
- 22パケット captured（26 received by filter。差の4つは、終了時の取りこぼしと読める。候補。未確認）。1つの TCP 接続。
- 順序: SYN → SYN/ACK → ACK、client から 517 バイト（Client Hello）、server から 1404 バイト（Server Hello と、暗号化された Certificate 等）、client から 80 バイトと 101 バイト（Finished、HTTP の GET）、server から 319 + 319 + 290 バイト（NewSessionTicket、HTTP 応答）、client から 24 バイト、server から 24 バイト（TLS の close_notify）、server が FIN、client が FIN、**client から RST が3つ**。
- TLS 1.3 では、ハンドシェイクの途中から暗号化されるため、`tcpdump` ではパケットの数と長さしか分からない。**証明書の中身は見えない**（想定どおり）。
- RST が3つ出る理由は不明（候補: curl がソケットを閉じるときの動作）。確認していない。
- 失敗の場合（selfsigned での capture）との比較は、実施していない。

**片付けと回収**
- `http-test.sh server teardown`（16:12:35）→ `tls-test.sh server teardown`（16:12:52）: どちらも終了コード 0（`is-active` の exit=3 は inactive のため）。`~/tls-lab`（CA と鍵）、`/etc/pki/tls/lab`、`lab-tls.conf`、`lab-ca.crt`、`index.html` などを削除。パッケージ（`httpd`、`mod_ssl`、`sscg`）は残してある。
- **`push` と `teardown` の順番の入れ替わり**: server は `site`（追加済み）を含む版で動いたため問題なし。**client は古い版の `tls-test.sh` で `client teardown` を実行したため、`teardown` が未定義**（使い方の表示のみ。記録は作られない）。`~/lab-ca.crt` が client に残っているので、更新版（push 済み）で `./tls-test.sh client teardown` を再実行する。
- 回収（`transfer.sh pull --exp-dir exp-tls-certs --pattern 'exp8-*'`）: `from-client/`（27ファイル）、`from-server/`（回収時は pcap を含む27ファイル。2026-11-07 の確認で、リポジトリにあるのは 26 ファイルで、pcap は含まれていない(`.gitignore` の対象)。capture の `tcpdump -r` の出力は `exp8-server-capture-20261025T161118.txt` に残っている）。空の `from-switch` / `from-router` / `from-router2` は削除した。
- 削除した記録（ユーザーの判断）: 名前の打ち間違いで、内容のない `from-server/exp8-server-cert-use-mismatchd-20261025T142235.txt` と `...cert-use-sclient-20261025T142003.txt`（`cert use` の引数の誤り）。`tls-test.sh` を修正し、証明書がないとき（終了コード 6）も、記録を残さないようにした。
- 残してある: `from-server/exp8-client-curl-www.lab.example-ca-20261025T135443.txt`（client 用のコマンドを server で実行した記録。ホスト名の不一致のため中止された。安全装置が働いた記録）。
- server の `~/exp7-server-log-30-20261025T154634.txt`（`logs` の打ち間違い、132 バイト）を、ユーザーの依頼で削除した。
