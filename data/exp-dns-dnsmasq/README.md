# 実験9: DNS（dnsmasq、B09 / C07）

> `*-test.sh` という名前ですが、テストではありません。実験の操作と観測をまとめた補助スクリプトで、合否は判定せず、結果と終了コードを記録するだけです(名前は、過去の記事との対応のため、変えていません)。

- 目的: 名前解決の失敗を、`dig`、`getent hosts`、`curl` の終了コードとログで切り分ける素材を採取する（ロードマップ B09 DNS、C07 DNS誤設定）。IP 直指定との比較も行う。
- 状態: **準備済み（未実行）**。スクリプトは `dns-test.sh`（server / client の役割を引数で指定。ホスト名の確認あり。引数の誤りと前提なしでは記録を残さない）。出力は VM 側の `exp9-<役割>-<動作>-<時刻>.txt`。
- 追加で導入するもの: server に `dnsmasq`、client に `bind-utils`（`dig`）。どちらも `install-plan` でサイズを先に確認する。`httpd` は導入済み（実験7）。
- DHCP（B10）は、別の実験（実験10）にする予定（R1 で `dnsmasq` の DHCP を動かし、client に配布。未着手）。

## 構成と設計の判断
- client 192.168.31.10 – R1 – R2 – server 192.168.32.20。ドメインは `lab.example`。server の `dnsmasq` が DNS（UDP/TCP 53）。上流（forwarder）は**設定しない**（実環境の DNS に問い合わせない。AGENTS.md の隔離ルール）。外部名への問い合わせは、REFUSED になる想定 [予想]。
- **client の `/etc/resolv.conf` は変更しない。** NAT 側の名前解決（`dnf`、SSH）に影響させないため。`resolve` は、一時的なマウント名前空間（`unshare -m`）の中だけで `/etc/resolv.conf` を差し替え、コマンドの終了で元に戻る。手元の開発環境で、マウントの差し替えが動くことは確認した（VM では未確認）。
- `dig` は `@192.168.32.20` に直接問い合わせる（resolv.conf を使わない）。`getent hosts` と `curl` は、アプリが通常使う経路（resolv.conf、search ドメイン）を通る。
- レコード: `www.lab.example`、`client.lab.example`（`/etc/lab-hosts`）、`web.lab.example`（`www` への CNAME、conf で設定）、PTR（hosts から自動）。

## 再現する症状 [予想。実測で確認する]
| 操作 | 期待する症状 | 見るもの |
|---|---|---|
| `record ok`、`dig www.lab.example` | status: NOERROR、ANSWER に 192.168.32.20、`aa`（権威）フラグ（`local=` のため）| dig の出力、dnsmasq のログ |
| `dig web.lab.example` | CNAME → www → A | dig の出力 |
| `dig -x 192.168.32.20`（`dig ptr`） | PTR www.lab.example | |
| `record missing`、`dig www.lab.example` | status: NXDOMAIN | `getent` 終了コード 2、`curl` 終了コード 6 |
| `record wrongip`、`resolve ok www.lab.example` | 名前は解決する（192.168.32.21）が、接続できない（ARP 失敗: `No route to host` か、タイムアウト）。IP 直指定（`direct`）は成功 | **名前解決と接続の層の切り分け**（curl の終了コードと経過時間） |
| `resolve nosearch www`（短い名前） | 解決できない（search ドメインなし）。`resolve ok www` は成功（`www.lab.example` が補完される） | resolv.conf の search |
| `resolve wrongns www.lab.example` | 約1秒でタイムアウト（timeout:1 attempts:1）。`getent` の終了コード 2、`curl` の終了コード 6 | 経過時間（NXDOMAIN は即座に返る、との違い） |
| `stop`（dnsmasq 停止）、`dig` | `communications error ... connection refused`（ICMP port unreachable）| exp6 の UDP の表と比較 |
| `fw close`、`dig` | `communications error ... host unreachable`、または timeout | firewalld の既定の拒否（ICMP admin-prohibited）か drop か |
| `dig ... example.com`（外部名） | REFUSED（上流なし）| |

## 手順（WSL の端末。ラボ用 ssh-agent に鍵が載っていること）
1. ベースライン: `labs/common/baseline.sh up`。時刻: `labs/common/sync-all-auto.sh --check-only`。
2. スクリプトを送る: `labs/common/transfer.sh push --exp-dir exp-dns-dnsmasq --files dns-test.sh --only client,server`
3. 導入: server で `./dns-test.sh server install-plan` → `install`。client で `./dns-test.sh client install-plan` → `install`。
4. server で `conf` → `start` → `fw open` → `web on`。
5. client で `dig www.lab.example`、`dig web.lab.example`、`dig ptr 192.168.32.20`、`resolve ok www.lab.example`、`resolve ok www`、`resolve nosearch www`、`direct`。
6. 症状の再現: server で `record missing` → client で `dig`・`resolve ok www.lab.example`。`record wrongip` → `resolve ok www.lab.example` と `direct`。`record ok` に戻す。client で `resolve wrongns www.lab.example`。
7. サービスの失敗: server で `stop` → client で `dig`。`start`。`fw close` → client で `dig`。`fw open`。
8. 各段階のあと server で `logs` を取る。パケット: server で `capture` → 25 秒以内に client から `dig`。
9. 片付け: server で `teardown`（パッケージは残す）。client で `~/dns-lab/` は残る（resolv.conf の一時ファイル。不要なら削除）。回収: `labs/common/transfer.sh pull --exp-dir exp-dns-dnsmasq --pattern 'exp9-*'`。

## 影響と復旧（AGENTS.md の規則）
- 対象: server のパッケージ（`dnsmasq`）、`/etc/dnsmasq.d/lab-dns.conf`、`/etc/lab-hosts`、`/var/www/html/index.html`、実行時の firewalld・dnsmasq・httpd の状態。client のパッケージ（`bind-utils`）、`~/dns-lab/`。
- 復旧: `teardown`、`sudo dnf remove -y dnsmasq`（server）、`sudo dnf remove -y bind-utils`（client）、またはスナップショット。`systemctl enable` と `--permanent` は使わない。
- 公開範囲: `dnsmasq` は `192.168.32.20` と `lo` だけで待ち受ける。`fw open` は `public` ゾーン（NAT 側 enp0s3 を含む）に dns サービスを許可する（実験7・8と同じ注意）。
- 未確認: `dnsmasq` の既定の設定（`/etc/dnsmasq.conf`）との関係、`unshare -m` + `runuser` が VM（SELinux Enforcing）で動くか、`dnsmasq` の SIGHUP でのレコード再読み込み、`log-facility=-` のジャーナル出力。

## 実施記録
### 2026-10-26 04:49〜05:04（準備の確認と install-plan）
- 時刻（`sync-all-auto.sh`、04:49）: 5台とも差 -0.07 秒、補正不要。ベースライン（`baseline.sh status`、04:53）: ping 成功、ttl=62（構築済み）。
- `dns-test.sh` を server と client に push（05:0x、`remote_host` の一致を確認）。
- server の `install-plan`（05:03）: `dnsmasq` 2.85-18.el9_8.2 の1パッケージ。**ダウンロード 325 k、導入後 702 k**。`Operation aborted.`（exit=1、`--assumeno` の仕様どおり）。
- client の `install-plan`（05:04）: `bind-utils` 32:9.16.23-40.el9_8.10（199 k）と依存6つ（`bind-libs` 1.2 M、`bind-license`、`fstrm`、`libmaxminddb`、`libuv`、`protobuf-c`）の計7パッケージ。**ダウンロード 1.7 M、導入後 4.7 M**。
- 通信量の合計は約 2.0 MB（実験7の httpd と同程度）。

### 2026-10-26 05:31〜05:44（server の準備、正常系の確認）
**server の準備（05:31）[実測]**: `conf`: `dnsmasq --test` は `syntax check OK`。`start`: active。`ss`: UDP と TCP の 53 で、`192.168.32.20`、`127.0.0.1`、`[::1]` を待ち受け（`[::1]` は dnsmasq の既定の設定による、と読める。候補）。`fw open`: `public` ゾーンに `dns` を許可（`services: cockpit dhcpv6-client dns ssh`）。`web on`: httpd 起動、`index.html` 作成、`http` を許可。

**client の正常系 [実測]**
| 操作 | 結果 |
|---|---|
| `dig www.lab.example` | `status: NOERROR`、`flags: qr aa rd ra`（`aa` = 権威応答。`local=` のため）、ANSWER: `192.168.32.20`、**TTL 0**、Query time 5 msec |
| `dig web.lab.example` | ANSWER 2件: `web CNAME www.lab.example.`、`www A 192.168.32.20` |
| `dig ptr 192.168.32.20` | `20.32.168.192.in-addr.arpa. PTR www.lab.example.`（hosts から自動で作られた） |
| `resolve ok www.lab.example` | `getent hosts`: 192.168.32.20（exit 0）、`curl`: 200、curl_exit 0 |
| `resolve ok www`（短い名前） | `getent hosts www` → `192.168.32.20 www.lab.example`（search ドメインで補完）、`curl`: `Connected to www (192.168.32.20)`、200 |
| `resolve nosearch www` | `getent hosts`: **exit 2**（結果なし）、`curl`: `Could not resolve host: www`、**curl_exit 6**、0.14 秒 |
| `direct`（IP 直指定） | 200、curl_exit 0 |

- **TTL が 0 であることに注意**: `addn-hosts` のレコードは、dnsmasq の既定では TTL 0 で返る（キャッシュされない）。キャッシュの効果を見る実験をするときは、`local-ttl` の設定が必要（候補。確認していない）。
- **経過時間の記録の問題（修正済み）**: 最初の `resolve ok www.lab.example` の `getent` が `elapsed=4.99s` になったのは、`sudo` のパスワード入力の待ち時間を含んでいたため（2回目以降は 0.16 秒）。この値は DNS の応答時間ではない。`resolve` の先頭で `sudo -v` を行い、待ち時間を経過時間に含めないように修正した。タイムアウトの測定（`wrongns`）に影響するための修正。
- `unshare -m` + `runuser` は、SELinux Enforcing の VM で動いた [実測]。
- 参考: `./dns-tes.sh`（打ち間違い）は、シェルが `No such file` を返しただけで、記録は作られない。`ssuccess` は、端末に出た `success` の先頭の余分な `s`（表示の乱れ）。

### 2026-10-26 07:51〜07:53（record missing: 途中）
- `server record missing`（07:51:32）: `/etc/lab-hosts` は `192.168.31.10 client.lab.example` の1行だけになり、`systemctl kill -s HUP dnsmasq` は終了コード 0。**HUP でレコードの変更が反映された** [実測]（次の dig が NXDOMAIN）。
- client `dig www.lab.example`（07:51:56）: **`status: NXDOMAIN`**、ANSWER 0、`flags: qr rd ra`、Query time 4 msec、`elapsed=0.11s` [実測]。**正常時にあった `aa` フラグが無い**（同じ `local=/lab.example/` の下でも、NXDOMAIN の応答には `aa` が付かない。確認はこの1回のみ）。
- client `resolve ok www.lab.example`（07:53:50）: resolv.conf の表示までで、貼られた出力が途切れている（`getent` と `curl` の結果は未取得）。ユーザーから「server の操作を途中で間違えた」との連絡があり、状態の確認を先に行う。

### 2026-10-26 08:33〜08:37（missing、wrongip、direct、wrongns）
先頭の `sudo -v` により、パスワード入力の待ち時間は `elapsed` に含まれなくなった（修正の効果を確認）。

| 状態 | 操作 | 結果 [実測] |
|---|---|---|
| record missing（08:33） | `resolve ok www.lab.example` | `getent hosts`: **exit 2**、0.17 秒。`curl`: `Could not resolve host: www.lab.example`、**curl_exit 6**、0.15 秒 |
| record wrongip（08:35:18、`www` = 192.168.32.21） | `resolve ok www.lab.example` | `getent hosts`: **192.168.32.21**（exit 0）、0.13 秒。`curl`: `http_code=000`、**curl_exit 28（タイムアウト）**、**8.13 秒**（`--max-time 8`） |
| 同上 | `direct`（IP 直指定、08:36:15） | `Connected to 192.168.32.20`、**200**、curl_exit 0 |
| record ok（08:36:40） | （戻した） | |
| wrongns（`nameserver 192.168.32.99`、08:37） | `resolve wrongns www.lab.example` | `getent hosts`: **exit 2**、**4.14 秒**。`curl`: `Could not resolve host`、**curl_exit 6**、**2.16 秒** |

観察:
- **終了コードだけでは原因を絞れない**: 「レコードがない」（missing）と「DNS サーバーに届かない」（wrongns）は、`getent` が exit 2、`curl` が 6 で**同じ**。違いは**経過時間**（約0.15秒 と 2〜4秒）。NXDOMAIN は即座に返り、サーバー不達は待たされる。
- **wrongip は「名前解決は成功、接続が失敗」**: curl の終了コードは 6 ではなく **28（タイムアウト）**。`getent` は正しく（レコードどおり）192.168.32.21 を返している。IP 直指定は成功。この組み合わせ（名前では失敗、IP 直指定では成功、でも名前は解決している）で、DNS の問題ではなく、**解決した先のアドレスに到達できない**問題と分かる。
- **wrongns の時間が `timeout:1 attempts:1` の1秒より長い理由は候補**: `search lab.example` と glibc の名前解決が、名前ごと・アドレス種別（A と AAAA）ごとに問い合わせるため。`www.lab.example`（ドット2つ。ndots=1 の既定より多い）は、まず絶対名として、次に search ドメインを付けた名前（`www.lab.example.lab.example`）で試す。`getent hosts` は AAAA → A を順に待ち（約 4 回 × 1 秒 = 4.14 秒）、`curl`（`getaddrinfo`）は A と AAAA を並行して待つ（2 名前 × 1 秒 = 2.16 秒）、と読める。**パケットで確認していない**（確認方法: R2 で capture して、192.168.32.99 宛の問い合わせの数を数える）。
- **wrongip がタイムアウトで、`No route to host` にならない理由は候補**: 192.168.32.21 の ARP に誰も答えず、R2 が SYN を転送できず、ICMP（host unreachable）が返っても、TCP の接続試行ではこの種の ICMP を「一時的なエラー」として扱い、接続は最後まで待たされる（Linux の一般的な動作。確認していない）。ping では `Destination Host Unreachable` が見えた（実験4・5）のと対照的。確認方法: R2 で capture して、ARP who-has と SYN の再送、ICMP を見る。
- スクリプトの問題: `curl` の表示の絞り込みで、`* Trying ...` の行が出ない（`*   Trying` のように `*` の後に空白が複数あるため、正規表現が一致しなかった）。修正した（`* +Trying`）。`wrongip` の `curl` の出力に、`Trying 192.168.32.21:80...` と `Connection timed out after 8001 milliseconds` が出るようになる。

### 2026-10-26 08:48〜08:54（R2 での capture: 候補の検証）
R2（router2）で `route-test.sh router2 capture`（`tcpdump -i any -n 'not tcp port 22'`、25秒）を取りながら、client の `resolve` を実行 [実測]。ファイル名の接頭辞は、スクリプトの都合で `exp4-router2-<時刻>.pcap` / `.txt`（`route-test.sh` の出力）。

**1. wrongip（`exp4-router2-20261026T084919.*`、38パケット）** — 「名前は解決できるが接続できない」の内訳
- DNS（`getent`）: `AAAA? www.lab.example.` → **`0/0/0`（NOERROR、回答なし）**、`AAAA? www.lab.example.lab.example.`（search ドメイン付き）→ **NXDomain**、`A? www.lab.example.` → **`A 192.168.32.21`**（`*` = 権威応答）。3回の問い合わせ。AAAA が「回答なし」でも、search ドメインの名前を続けて試している。
- DNS（`curl`）: `A?` と `AAAA?` を**同時**（同じ送信元ポート 34698）に送り、`A 192.168.32.21` と `0/0/0` が返る。
- 接続: client の SYN が 08:49:40.860 に R2 へ。R2 は同時に `ARP Request who-has 192.168.32.21 tell 192.168.32.1` を出し、**約1秒間隔で3回**（40.860 / 41.918 / 42.943）。誰も答えない。**約3秒後（43.965）、R2 が client へ `ICMP host 192.168.32.21 unreachable` を返す（2通）。**
- **client の SYN は、ICMP のあとも再送を続けた**: 40.860 → 41.924（+1 秒）→ 43.972（+2 秒、ICMP の 7 ミリ秒後）。ICMP（host unreachable）が来ても、TCP の接続試行は止まらず、`curl` は `--max-time 8` まで待って終了コード 28 になった。→ **候補「ICMP host unreachable を一時的なエラーとして扱い、接続を続ける」が、パケットで裏づけられた**（client 側の挙動は、再送が続いたことから読んだ。client で取ったパケットではない）。
- ARP の失敗から ICMP が返るまでに約3秒かかる（ping の `Destination Host Unreachable` の遅れと同じ型。実験4・5）。

**2. wrongns（`exp4-router2-20261026T085217.*`、26パケット）** — タイムアウトが 4.13 秒と 2.17 秒だった理由
- `getent`: **4回の問い合わせ（約1秒間隔）**: `AAAA? www.lab.example.`（23.236）→ `AAAA? www.lab.example.lab.example.`（24.242）→ `A? www.lab.example.`（25.245）→ `A? www.lab.example.lab.example.`（26.247）。いずれも `192.168.32.99` 宛。`timeout:1` × 4 = 約 4 秒（`getent` の 4.13 秒と一致）。
- `curl`: **2回の問い合わせ（A と AAAA を同時、約1秒間隔）**: 27.412（`www.lab.example.`）→ 28.414（`www.lab.example.lab.example.`）。`timeout:1` × 2 = 約 2 秒（`curl` の 2.17 秒と一致）。
- → **候補「名前ごと・アドレス種別ごとの問い合わせの数 × timeout」が、パケットで裏づけられた**。
- R2 は 192.168.32.99 の ARP に約1秒間隔で3回出し（23.236 / 24.285 / 25.310）、約3秒後（26.337）に `ICMP host 192.168.32.99 unreachable` を4通返した。ICMP は client に届いているが、DNS の待ち時間（4.13 秒）は短くならなかった（`timeout:1` の待ちが優先される形）。

**補足**: 正常な `aa` フラグの有無（`*`）: A の回答は `13279*` のように `*` が付き、NODATA（`0/0/0`）と NXDomain には付かない。→ 先の「NXDOMAIN に `aa` が無い」観察と一致する（dnsmasq の動作）。

### 2026-10-26 09:23〜09:38（サービス停止、ファイアウォール、サーバーのログ、片付け、回収）
**サービス停止（`server stop`、09:23:50）とファイアウォール（`fw close`、09:33:52）[実測]**

| 状態 | `dig @server`（`+time=2 +tries=1`） | `getent hosts`（resolv.conf = ok） | `curl` |
|---|---|---|---|
| 正常（record ok） | NOERROR、`192.168.32.20`、0.09 秒 | `192.168.32.20`、0.16 秒 | 200、0.18 秒 |
| record missing | **NXDOMAIN**、0.11 秒 | exit 2、0.17 秒 | **6**、0.15 秒 |
| record wrongip | NOERROR、`192.168.32.21`（08:35、dig は未実行） | `192.168.32.21`、0.13 秒 | **28**、8.13〜8.18 秒 |
| wrongns（`192.168.32.99`） | （対象外） | exit 2、**4.13 秒** | **6**、**2.17 秒** |
| dnsmasq 停止（`stop`） | **`connection timed out; no servers could be reached`**（終了コード 9）、2.06 秒 | exit 2、**0.14 秒** | **6**、**1.20 秒** |
| `fw close`（dns を外す） | **同上（タイムアウト、終了コード 9）**、2.08 秒 | exit 2、**0.18 秒** | **6**、**1.17 秒** |

- **予想と違った点**: `stop` のとき、`dig` は `communications error ... connection refused` になる予想（ICMP port unreachable）だったが、**タイムアウト**だった。`fw close` も同じ（`host unreachable` かタイムアウトの予想で、タイムアウト）。**`stop` と `fw close` が、`dig` からは見分けられない**。
- 同じ条件で `getent hosts` は **0.14〜0.18 秒で失敗**した（すぐに諦めた）。つまり、拒否の応答（ICMP）は client まで届いている、と読める。`dig` は ICMP のエラーを使わず、2 秒待ってタイムアウトとした。
  - 原因は候補: `dig`（BIND 9.16）は、UDP のソケットを `connect()` せずに使うため、ICMP の宛先不到達がアプリケーションに通知されない。`glibc` の名前解決（`getent`、`curl`）は `connect()` 済みの UDP ソケットを使うため、`ECONNREFUSED` などで即座に失敗する。exp6 の UDP（python の `connect()` 済みソケット）で `ECONNREFUSED` が得られたのと整合する。**確認していない**（確認方法: R2 で capture して ICMP port unreachable が client に向かうことを見る、`strace` で `dig` の `connect` を見る）。
- `curl` の 1.2 秒は、`getent` の 0.14 秒より長い理由は未確認（候補: `curl` の名前解決のスレッド、または A と AAAA の2回の待ち）。
- **学べること**: 「DNS が引けない」ときの症状は、(1) 道具（`dig` と OS の名前解決）で異なる、(2) 原因（サービス停止、ファイアウォール、サーバー不達）でも違うが、**`dig` だけでは停止とファイアウォールを区別できない**。区別するには、server 側で `ss -lunp`（待ち受けの有無）と `firewall-cmd --list-all`、またはパケット（ICMP の種類）を見る。

**サーバーのログ（`server logs 80`、`from-server/exp9-server-logs-80-20261026T093610.txt`）[実測]**
- 起動の行: `started, version 2.85 cachesize 150`、`using only locally-known addresses for domain lab.example`（`local=/lab.example/` の効果）、`read /etc/lab-hosts - 2 addresses`。
- 問い合わせの行: `query[AAAA] www.lab.example from 192.168.31.10`、`config www.lab.example is NODATA-IPv6`（A レコードがあり AAAA がない = 回答なし）、`/etc/lab-hosts www.lab.example is 192.168.32.21`（wrongip）、`config www.lab.example is NXDOMAIN`（missing）。
- 変更の反映: `Sent signal SIGHUP to main process`（systemd）→ `read /etc/lab-hosts - N addresses`（N = 1 は missing、2 は ok か wrongip）。
- **missing の `resolve ok`（08:33:24）では、1秒以内に 8 件の問い合わせ**が記録された（`getent` 4 件 + `curl` 4 件。AAAA と A、絶対名と search 付き）。
- **wrongns（08:37、08:52、09:31）の問い合わせは、サーバーのログに1件もない**（08:35:37 の次が 08:49:40 で、08:52 の行もない）。サーバーに届かない問い合わせは、サーバー側のログからは見えない。同じことは `dig` のタイムアウト（09:31〜09:34）にも言える（09:23:53 の停止から 09:33:19 の起動までは、そもそも動いていない）。実験8（TLS）でも、検証に失敗した接続がサーバーのログに残らなかったのと同じ型。

**片付けと回収**
- `server teardown`（09:37:09）: dnsmasq と httpd を停止、`lab-dns.conf`・`lab-hosts`・`index.html` を削除、firewalld をリロード。終了コード 0（`is-active` の exit=3 は inactive のため）。`client teardown`（09:38:11）: `~/dns-lab` を削除。パッケージ（`dnsmasq`、`bind-utils` と依存）は残してある。
- 回収: `from-client/`（29ファイル）、`from-server/`（23ファイル）、`from-router2/`（pcap 2つ）。
  - `from-server/exp9-client-dig-www.lab.example-20261026T054645.txt` と `...exp9-client-resolve-ok-...054645.txt` は、client 用のコマンドを server で実行した記録（ホスト名の不一致で中止。安全装置の記録）。
  - 同じ内容の記録が複数あるのは、同じ操作を複数回実行したため（`record missing` が4回、`wrongip` が3回、`record ok` が2回など）。
  - **R2 の capture のテキスト（`exp4-router2-capture-*.txt`）は、回収のパターンが合わず、回収できていない**（pcap だけ）。パターンを `exp4-router2-capture-20261026T08*` にして回収し直す。
