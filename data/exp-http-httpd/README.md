# 実験7: HTTP 応答エラー（httpd、C08）

> `*-test.sh` という名前ですが、テストではありません。実験の操作と観測をまとめた補助スクリプトで、合否は判定せず、結果と終了コードを記録するだけです(名前は、過去の記事との対応のため、変えていません)。

- 目的: Web サーバー（httpd）の応答を、ステータスコードとログ、curl の終了コードで切り分ける練習の素材を採取する。実務で多い原因（権限、SELinux、設定、CGI、サービス停止、ファイアウォール）を再現する。
- 状態: **準備済み（未実行）**。`httpd` を server に導入する（NAT 経由の `dnf`。サイズは `install-plan` で先に確認する）。
- スクリプト: `http-test.sh`（server / client の役割を引数で指定。ホスト名が役割と一致しなければ中止）。出力は VM 側に `exp7-<役割>-<動作>-<時刻>.txt`。

## 再現する症状と、切り分けの手がかり
| URL / 操作 | 期待する症状 [予想。実測で確認する] | 切り分けの手がかり |
|---|---|---|
| `/` | 200 | access_log |
| `/nofile` | 404 | access_log、error_log（File does not exist） |
| `/perm.html` | 403（ファイル権限） | error_log（Permission denied）、`ls -l` |
| `/selinux.html` | 403（権限は正しいが SELinux） | `ls -Z`（user_home_t）、AVC、`getenforce`。`restorecon` で直る |
| `/old` | 301、Location: /index.html | `curl -v` の応答ヘッダー |
| `/cgi-bin/ok.cgi` / `bad.cgi` | 200 / 500 | error_log（ヘッダー不正のメッセージ） |
| httpd 停止 | curl 終了コード 7（RST） | `ss -tlnp`、`systemctl status` |
| firewalld で 80 を閉じる | 既定の拒否なら curl 終了コード 7（`No route to host`、ICMP admin-prohibited）。無応答（28）になるのは drop のときだけ、と予想（exp6 の結果から） | exp6 の表と比較、`firewall-cmd --list-all` |

## 手順（WSL の端末で。ラボ用 ssh-agent に鍵が載っていること）
1. ベースライン: `labs/common/baseline.sh up`（ping で ttl=62 を確認）。時刻: `labs/common/sync-all-auto.sh --check-only`。
2. スクリプトを送る: `labs/common/transfer.sh push --exp-dir  exp-http-httpd --files http-test.sh --only client,server`
3. （任意）server のスナップショットを取る（`snapshot-all.ps1 -Name pre-httpd -Vms "Alma9mini-server"`）。復旧は `sudo dnf remove -y httpd` でもよい。
4. server に入って（`ssh -p 2223 127.0.0.1`。`~/.ssh/config` の設定で鍵が使われる）実行:
   - `./http-test.sh server install-plan`（何も入れない。サイズを確認）
   - `./http-test.sh server install`
   - `./http-test.sh server site setup` → `./http-test.sh server start` → `./http-test.sh server fw open`
5. client に入って（`ssh -p 2222 127.0.0.1`）実行: `./http-test.sh client curl /`、`/nofile`、`/perm.html`、`/selinux.html`、`/old`、`/cgi-bin/ok.cgi`、`/cgi-bin/bad.cgi`。各 curl のあとに server で `./http-test.sh server logs` を取る。
6. SELinux: `./http-test.sh server selinux` → `fix-selinux` → client で `/selinux.html` を再度 curl。
7. 接続の失敗: server で `stop` → client で `curl /`（終了コード 7 の予想）→ `start`。`fw close` → client で `curl /`（7 の予想。上の表）→ `fw open`。
8. パケット: server で `capture` を実行して 25 秒以内に client から `curl /`。
9. 片付け: `./http-test.sh server teardown`（パッケージは残す）。記録の回収: `labs/common/transfer.sh pull --exp-dir exp-http-httpd --pattern 'exp7-*'`。

## 影響と復旧（AGENTS.md の規則）
- 対象: server のパッケージ（`httpd`、依存を含む。数十MBの見込み、実測は install-plan）、`/var/www/` 配下、`/etc/httpd/conf.d/lab-http.conf`、実行時の firewalld と httpd の状態。
- 復旧: `teardown`（ファイル・設定・実行時の状態）、`sudo dnf remove -y httpd`（パッケージ）、またはスナップショット。`systemctl enable` と `--permanent` は使わない（再起動で httpd は止まり、firewalld は元に戻る）。
- 公開範囲: httpd は全アドレスで待ち受ける。NAT 側 (enp0s3) は firewalld の public ゾーンで 80 が閉じている想定（未確認。`fw open` はインターフェースのゾーンにのみ適用される。`server base` の後の enp0s9 のゾーンは、実行して確認する）。
- 未確認: server (512MB) で httpd が問題なく動くか、`audit` が有効で AVC が `audit.log` に出るか、`bad.cgi` の error_log の文言。

## 実施記録
### 2026-10-25 06:05〜06:07（手順4: 導入とコンテンツの作成）
- 2026-10-25 06:05、server で `install` を実行（直前の 06:05:28 に `install-plan` も実行済み）。**12パッケージ、ダウンロード 2.0 MB、導入後 6.1 MB**。`httpd` 2.4.62-13.el9_8.9、`httpd-core` 1.4 MB が大部分。弱い依存の `mod_http2`、`mod_lua` も入った。終了コード 0。記録は `from-server/exp7-server-install-20261025T060547.txt`。`install-plan`（`from-server/exp7-server-install-plan-20261025T060528.txt`）は `Total download size: 2.0 M`、`Installed size: 6.1 M`、`Operation aborted.`、exit=1（`--assumeno` の仕様どおりで、何も入らない）。
- 06:07、`site setup`: 終了コード 0 で完了。`httpd -t` は `Syntax OK`（ServerName 未設定の警告 AH00558 は出た。実験には影響しない見込み）。
- ファイルのコンテキスト [実測]: `index.html` と `perm.html` は `httpd_sys_content_t`、CGI は `httpd_sys_script_exec_t`、`selinux.html` は `user_home_t`（意図どおり。権限は 0644 で、所有者は user）。
- 注意: 画面に出る `### $ sudo sh -c echo "index: ok" > ...` の表示は引用符が落ちているが、`run` が配列で実行するため、実行内容には影響しない（表示だけの問題）。`ok.cgi` のサイズは 58 バイトで、`\n\n` が実際の改行になった形になる（シェルの二重引用符内の改行でも `printf` の出力は同じになる見込み。実行結果で確認）。

### 2026-10-25 06:15〜06:21（手順5〜6の一部: 起動と7つのURL）
- 06:15 `start`: httpd は `*:80` で待ち受け（`ss -tlnp`、4プロセス）。06:16 `fw open`: `firewall-cmd --add-service=http`（実行時のみ）。
  - 有効なゾーンは `public`（`enp0s3` と `enp0s8`）。**`enp0s9`（ラボ側）はどのゾーンにも載っていない**のに、client から届いた [実測]。未割り当てのインターフェースの入力は、既定ゾーン（public）の規則で処理される、と読める（候補。exp3 の「転送は拒否」とは別の経路）。
  - `public` に `enp0s3`（NAT）も載っているので、`http` の許可はそのインターフェースにも及ぶ（NAT の外からは届かない構成。確認はしていない）。
- **`fw open` の前の `curl /`（閉じた状態の症状）は、観察していない**（先に開けたため）。`fw close` の手順で観察する。
- 7つのURLの結果 [実測、client の `curl`、すべて curl 終了コード 0]:

| URL | http_code | 追加の観察 |
|---|---|---|
| `/` | 200 | `Content-Length: 10`、`Server: Apache/2.4.62 (AlmaLinux)`、`Last-Modified`、`ETag` |
| `/nofile` | 404 | 本文は標準のエラーページ。error_log には出ない（既定のログレベルが warn のため。候補） |
| `/perm.html` | 403 | error_log: `(13)Permission denied: ... AH00132: file permissions deny server access: /var/www/html/perm.html` |
| `/selinux.html` | 403 | error_log は perm.html と**同じ文言**（AH00132）。区別は `ls -Z`（`user_home_t`）と AVC（`avc: denied { read } ... name="selinux.html" ... scontext=...httpd_t tcontext=...user_home_t ... permissive=0`）。`getenforce` は `Enforcing` |
| `/old` | 301 | `Location: http://192.168.32.20/index.html` |
| `/cgi-bin/ok.cgi` | 200 | `Transfer-Encoding: chunked`。本文 `cgi-ok`（`\n\n` が実改行になった形でも正常に動作） |
| `/cgi-bin/bad.cgi` | 500 | `Connection: close`。error_log: `[cgid:error] malformed header from script 'bad.cgi': Bad header: no-header-here` |

- access_log は、curl を2回（`-v` のヘッダー用と本文用）実行したため、各URLが2行ずつ。クライアントのアドレスは `192.168.31.10`（ルーターを経由しても、NAT されずに server に届く）。
- 時刻: 応答の `Date` ヘッダー（GMT）は client の時刻に一致（補正済み）。

### 2026-10-25 06:28〜06:34（SELinux の修復、サービス停止、ファイアウォール、capture）
| 操作 | client の `curl /` の結果 [実測] | 読み取り |
|---|---|---|
| `fix-selinux`（`restorecon`）後の `/selinux.html` | 200（本文 `selinux: mislabeled`） | コンテキストが `user_home_t` → `httpd_sys_content_t` に直り、権限・内容は変えずに 403 が解消。`restorecon -v` が `Relabeled ... from ...user_home_t... to ...httpd_sys_content_t...` を表示 |
| httpd 停止（`systemctl stop`） | `connect to 192.168.32.20 port 80 failed: Connection refused`、curl 終了コード 7、`http_code=000` | 待ち受けがない → 即座に拒否（TCP RST）。exp6 の「待ち受けなし」と同じ症状 |
| `fw close`（`http` サービスを外す） | `connect to ... failed: No route to host`、curl 終了コード 7、`http_code=000` | 既定の拒否（`target: default`）で、ICMP（admin-prohibited）が返った、と読める。**ICMP のパケット自体は取っていない**（capture のフィルターが `tcp port 80` のため）。予想（終了コード 7）どおり。タイムアウト（28）ではない |
| `fw open` 後 | 200 | 元に戻る |

- 切り分けの表（`curl` の症状別）:
  | 症状 | curl 終了コード | メッセージ | 疑う場所 |
  |---|---|---|---|
  | HTTP 応答あり（200/301/403/404/500） | 0 | `HTTP/1.1 xxx` | アプリ・設定・権限・SELinux（ログで切り分け） |
  | 接続が拒否される | 7 | `Connection refused` | サービスの停止・待ち受けなし |
  | 接続が拒否される（経路上の拒否） | 7 | `No route to host` | ファイアウォールの reject（ICMP）。ルーティングの欠落でも出る（exp4/5 の `Destination Net Unreachable`）ため、`ip route get` で区別 |
  | 無応答 | 28 | タイムアウト | ファイアウォールの drop、経路上の欠落（exp6 の drop 規則では 28） |
- `capture`（server、`tcp port 80`、25秒）: 20パケット、2接続（`curl` を2回実行）。各接続で、3-way handshake → `GET / HTTP/1.1`（77 バイト）→ `HTTP/1.1 200 OK`（254 バイト = ヘッダー + 本文 10 バイト）→ FIN は client 側が先に送信。`Warning: interface names might be incorrect`（`-i any` の cooked キャプチャの注意）。インターフェースは `enp0s9`。
- 未実施: `ICMP` を含めた capture（`No route to host` の ICMP の種類の確認）。必要なら `capture` のフィルターに `or icmp` を足して再実施。

### 回収と片付け（2026-10-25 06:41〜）
- `teardown`（`from-server/exp7-server-teardown-20261025T064147.txt`）: 終了コード 0。httpd は inactive、実験用のファイルと設定は削除、firewalld はリロード。**パッケージ `httpd` は残してある**（次の TLS の実験で使う。消すときは `sudo dnf remove -y httpd`）。
- 回収: `transfer.sh pull --exp-dir exp-http-httpd --pattern 'exp7-*'` → `from-client/`（11ファイル）、`from-server/`（回収時は 19 ファイル、pcap 1つ。2026-11-07 の確認で、リポジトリにあるのは 15 ファイルで、pcap は含まれていない。capture の `tcpdump -r` の出力は `exp7-server-capture-20261025T063356.txt` に残っている）。switch・router・router2 には記録がなく、空のフォルダーは削除した。
- 引数の誤りで終了した3つの記録（役割の引数を省略した `site setup` と `fw close`、`server site start`）は、ホスト名の確認の前に終了した内容のない記録だったため、**削除した**（ユーザーの判断、2026-10-25）。VM の状態は変わっていない。
- 今後は、引数の誤り（`usage`、終了コード 2）では記録を残さない。`http-test.sh`、`route-test.sh`、`fault-test.sh`、`l4-test.sh`、`switch-test.sh`、`router-test.sh`、`lab-ssh-key-wsl.sh` を修正した。ホスト名の不一致（終了コード 4）は、安全上の記録として残す。確認は、手元で誤った引数を与えて、ファイルが作られないことを見た。VM 上の実機での確認は未実施。
