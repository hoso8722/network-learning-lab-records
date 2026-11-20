# 実験10: DHCP（dnsmasq、B10）

> `*-test.sh` という名前ですが、テストではありません。実験の操作と観測をまとめた補助スクリプトで、合否は判定せず、結果と終了コードを記録するだけです(名前は、過去の記事との対応のため、変えていません)。

- 目的: DHCP のアドレス配布の流れ（DISCOVER / OFFER / REQUEST / ACK）と、配布されないときの症状を、パケット・ログ・リース情報で切り分ける素材を採取する（ロードマップ B10 DHCP）。DHCP リレーの概念（ルーターを越えない）にもつなげる。
- 状態: **準備済み（未実行）**。スクリプトは `dhcp-test.sh`（router / client の役割を引数で指定。ホスト名の確認あり。引数の誤りと前提なしでは記録を残さない）。出力は VM 側の `exp10-<役割>-<動作>-<時刻>.txt`。
- 追加で導入するもの: router（R1）に `dnsmasq`（実験9では server に入れたもの。R1 は未導入。`install-plan` でサイズを確認。server と同じなら 325 k の見込み）。

## 設計の判断
- **DHCP サーバーは R1 に置く**: DHCP の DISCOVER はブロードキャストで、ルーターを越えない。client のいる lan-a 側にサーバーが必要で、R1 の enp0s8（192.168.31.1/24）が自然（実務でもルーターが DHCP サーバーやリレーを担う）。server（lan-b）に置くと、リレーが必要になる（今回は扱わない）。
- **client の enp0s9 は NetworkManager の DHCP クライアントを使う**: AlmaLinux 9 に `dhclient` は無い。プロファイル `lab-dhcp` を作る（`autoconnect no`）。`ipv4.never-default yes`（既定ルートを適用しない: NAT の既定ルートとの競合・漏れを避ける）、`ipv4.ignore-auto-dns yes`（配られた DNS を `/etc/resolv.conf` に適用しない: 実験9と同じ理由）。オプション（ルーター、DNS、検索ドメイン）は `nmcli device show` で見られる。
- **隔離**: dnsmasq は `interface=enp0s8` + `bind-interfaces` で lan-a だけに出す。NAT 側（enp0s3）には出さない。DNS は `port=0` で無効（DHCP のみ）。範囲は 192.168.31.100〜150（client の静的アドレス 192.168.31.10 と重ならない）。
- **firewalld**: R1 の enp0s8 は internal ゾーン（baseline で割り当て済み）。internal には `dhcp` サービス（UDP 67）が無い想定で、`fw open` で実行時だけ許可する。**許可しない状態も症状として観察する**。

## 再現する症状 [予想。実測で確認する]
| 状態 | client の `lease-start` | R1 のパケット（enp0s8） | R1 の dnsmasq ログ |
|---|---|---|---|
| 正常（start + fw open） | 数秒で成功。192.168.31.1xx/24、リース 600 秒。ルーター 192.168.31.1、DNS 192.168.32.20、検索ドメイン lab.example | DISCOVER（0.0.0.0 → 255.255.255.255、宛先 MAC は ff:ff:ff:ff:ff:ff）→ OFFER → REQUEST → ACK | DHCPDISCOVER / OFFER / REQUEST / ACK |
| dnsmasq 停止（`stop`） | 約 20 秒後に失敗（`IP configuration could not be reserved (no available address, timeout, etc.)`） | DISCOVER が再送されるだけ。OFFER なし | なし（動いていない） |
| fw を閉じる（`fw close`、dnsmasq は動作） | 同上（約 20 秒後に失敗） | **DISCOVER は見える**（tcpdump はファイアウォールより前）が OFFER なし | **なし**（ファイアウォールで止まる）。`ss -lunp :67` では dnsmasq が待ち受け中 |
| 固定割り当て（`reserve <MAC> <IP>`） | 指定した IP が配られる | | `dhcp-host` の行 |
| リース 2 分（`lease 2m`）+ 長い capture（150 秒） | 約 1 分後（T1）に更新 | ユニキャストの REQUEST → ACK | |

- **「停止」と「fw close」はクライアントからは同じ症状**（実験9の DNS の `stop` / `fw close` と同じ型）。区別は、R1 の `ss`、`firewall-cmd`、ログの有無で行う。

## 手順（WSL の端末。ラボ用 ssh-agent に鍵が載っていること）
1. ベースライン: `labs/common/baseline.sh up`。時刻: `labs/common/sync-all-auto.sh --check-only`。
2. スクリプトを送る: `labs/common/transfer.sh push --exp-dir exp-dhcp-dnsmasq --files dhcp-test.sh --only router,client`
3. router（`ssh -p 2225 127.0.0.1`）: `./dhcp-test.sh router install-plan` → `install` → `conf` → `start` → `fw open`
4. client（`ssh -p 2222 127.0.0.1`）: `./dhcp-test.sh client mac`（MAC を控える）→ `lease-start` → `lease-show`
5. router: `leases`、`logs 30`
6. パケット: router で `./dhcp-test.sh router capture` を実行し、25 秒以内に client で `lease-stop` → `lease-start`。
7. 失敗: router で `stop` → client で `lease-start`（約 20 秒かかる）→ router で `start`。`fw close` → client で `lease-start` → router で `capture` / `logs` / `ss` / `fw open`。
8. 固定割り当て: router で `reserve <client の MAC> 192.168.31.77` → client で `lease-stop` → `lease-start`。router で `reserve clear`。
9. （任意）更新: router で `lease 2m` → client で `lease-start` → router で `capture 150`。
10. 片付け: router で `teardown`（パッケージは残す）。client で `lease-stop`。ベースラインに戻す: `labs/common/baseline.sh up`（静的なアドレスに戻る）または `down`。回収: `labs/common/transfer.sh pull --exp-dir exp-dhcp-dnsmasq --pattern 'exp10-*' --only router,client`。

## 影響と復旧（AGENTS.md の規則）
- 対象: router のパッケージ（`dnsmasq`）、`/etc/dnsmasq.d/lab-dhcp.conf`、リースファイル、実行時の firewalld（internal ゾーンの dhcp）と dnsmasq の状態。client の NetworkManager のプロファイル `lab-dhcp`、enp0s9 のアドレス。
- 復旧: `router teardown`、`client lease-stop`、`baseline.sh up/down`、`sudo dnf remove -y dnsmasq`、またはスナップショット。`enable` と `--permanent` は使わない。
- **client の enp0s9 の静的なアドレス（baseline）は `lease-start` で外れる**。`lease-stop` のあと、`baseline.sh up` で戻す。途中で SSH が切れても、SSH は NAT（enp0s3）経由なので影響しない。
- 未確認: `dnsmasq` の既定設定（`/etc/dnsmasq.conf` の `interface=lo` など）と `port=0` の組み合わせ、internal ゾーンに `dhcp` サービスが無いか、NetworkManager の DHCP 失敗時の挙動（再試行の間隔）、`dhcp-host` と MAC の指定形式、`nmcli connection add` の各オプション名（`ipv4.dhcp-timeout`）。

## 実施記録
### 2026-10-26 11:35〜11:38（router の準備）
- `install-plan`（11:35）/ `install`（11:37）: `dnsmasq` 2.85-18.el9_8.2 の1パッケージ。**ダウンロード 325 k、導入後 702 k**（実験9の server と同じ）。終了コード 0。
- `conf`（11:38:12）: `dnsmasq --test` は **`syntax check OK`**（`port=0` と `interface=enp0s8`、`dhcp-range` などの組み合わせは問題なし）。
- `start`（11:38:22）: active。`ss -lunp 'sport = :67'`: **`0.0.0.0%enp0s8:67`**（UDP 67 を **enp0s8 にだけ** バインド。`%enp0s8` は、特定のインターフェースに結びつけた待ち受けを示す、と読める）。→ **隔離の確認**: NAT 側（enp0s3）と transit（enp0s9）には出ていない。DNS（53）は `port=0` により待ち受けなし。
- `fw open`（11:38:29）: internal ゾーンの `services` が `cockpit dhcp dhcpv6-client mdns samba-client ssh` になった（`dhcp` が追加された。追加前の一覧は取っていない。firewalld の internal ゾーンの既定には `dhcp` が無い、というのは一般知識で未確認）。アクティブなゾーン: `internal`（enp0s8、enp0s9）、`public`（enp0s3）。
- 参考: `sudo` なしの `ss` では、プロセス名の列が出ない（権限がないため）。

### 2026-10-26 11:53〜11:57（client の lease-start: 正常系）
- `mac`: `enp0s9` = `08:00:27:5a:8e:0e`（固定割り当て `reserve` に使う）。
- `lease-start`（11:53:30）[実測]: `nmcli connection delete lab-dhcp` は初回のため `unknown connection`（exit 10。想定された無害なエラー）。`nmcli connection add ...` は成功（`ipv4.dhcp-timeout 20` などのオプション名は通った）。`nmcli connection up lab-dhcp` は **`successfully activated`、exit 0、elapsed=3.51 秒**。
- 配布されたアドレス: **192.168.31.101/24**（範囲 .100〜.150 の2番目。dnsmasq は MAC などに基づいて選ぶため、先頭の .100 とは限らない。候補。未確認）。
- ルート [実測]: `192.168.31.0/24 dev enp0s9 proto kernel scope link src 192.168.31.101 metric 102` が増えた。**既定ルートは増えていない**（`IP4.GATEWAY: --`）。リースには `routers = 192.168.31.1` があるのに、`ipv4.never-default yes` により適用されなかった。NAT の既定ルート（`via 10.0.2.2 dev enp0s3`）は変わらず。
- `nmcli -f IP4,DHCP4 device show enp0s9` の DHCP4 オプション [実測]:
  | オプション | 値 | 意味 |
  |---|---|---|
  | dhcp_lease_time | 600 | リース 10 分 |
  | expiry | 1792983816 | 失効時刻（エポック秒。= 2026-10-26 12:03:36 JST。取得 11:53:36 + 600 秒と一致） |
  | dhcp_server_identifier | 192.168.31.1 | DHCP サーバー（R1） |
  | routers | 192.168.31.1 | ルーター（適用はしていない） |
  | domain_name_servers | 192.168.32.20 | DNS（`ignore-auto-dns` により適用していない） |
  | domain_search | lab.example | 検索ドメイン |
  | subnet_mask / broadcast_address | 255.255.255.0 / 192.168.31.255 | |
  | dhcp_client_identifier | 01:08:00:27:5a:8e:0e | 01（ハードウェアタイプ = Ethernet）+ MAC |
  | next_server | 192.168.31.1 | サーバーのアドレス（`siaddr`） |
  - `requested_*` の行は、NetworkManager がクライアントとして要求したオプションの一覧（1 = 要求した）。サーバーが返した値ではない。
- アクティブな接続: `lab-dhcp`（enp0s9）が `activated`。`enp0s3`（NAT）、`enp0s8`（poc1-lan）、`lo` は変わらず。
- 参考: `lease-show` を実行した 11:57:53 は、取得（11:53:36）から約4分後。リースの T1（50% = 5 分後 = 約 11:58:36）に近い。**更新（unicast の DHCPREQUEST）が router のログに出る可能性がある**（`router logs` で確認する）。

### 2026-10-26 12:34〜12:39（リース、DHCP のパケット）
**router の `leases`（12:36）[実測]**: `1792986252 08:00:27:5a:8e:0e 192.168.31.101 client 01:08:00:27:5a:8e:0e`（失効時刻、MAC、IP、ホスト名、クライアント ID）。失効 = **12:44:12 JST**（`1792986252`）。ファイルの更新は 12:34。→ 最初の取得（11:53:36、失効 12:03:36）から 1 時間近く経っても、**更新（リースの延長）が繰り返されている**（直近の更新は 12:34:12 ごろ = 失効の 10 分前。T1 = 300 秒 = 5 分ごとの更新、と読める。更新の1回ごとの時刻は `logs` で確認する）。
- `router log 30`（`logs` の打ち間違い）は、使い方の表示のみ（記録は作られない）。そのとき表示された「使い方」が、ヘッダーを超えてスクリプトの本体まで出ていた → 表示の範囲を「`set -u` の手前まで」に直した（全スクリプト）。

**capture（router の enp0s8、`udp port 67 or 68`、25 秒、`exp10-router-20261026T123831.pcap`）[実測]**: 10 パケット = **3 回の DHCP のやり取り**（xid が3つ）。client の操作は `lease-stop; lease-start`（12:38:37 〜）。
| # | 時刻 | xid | 内容 | 備考 |
|---|---|---|---|---|
| 1 | 37.847 → 37.884 | 0xe0d70676 | **DISCOVER → OFFER → REQUEST → ACK**（完全な DORA） | lease-stop の最中（lease-start より前）に起きた |
| 2 | 38.822 → 38.841 | 0xfde3f5fa | **REQUEST → ACK**（DISCOVER なし。Requested-IP = .101、Server-ID なし） | 前のリースを覚えている状態の再確認（INIT-REBOOT）と読める。lease-start の `nmcli connection up` は **0.54 秒**で完了（初回は 3.51 秒） |
| 3 | 39.742 → 39.761 | 0xc30f837a | **DISCOVER → OFFER → REQUEST → ACK**（完全な DORA） | lease-start が終わった後に起きた |

DHCP メッセージの中身（#1 の例）[実測]:
- **DISCOVER**: client MAC → `ff:ff:ff:ff:ff:ff`（ブロードキャスト）、`0.0.0.0.68 > 255.255.255.255.67`、`secs 1`、`Flags [none]`（ブロードキャスト応答を要求しない）、Client-ID = `ether 08:00:27:5a:8e:0e`、Parameter-Request（要求するオプションの一覧: サブネットマスク、ドメインネームサーバー、ホスト名、ドメイン名、ゲートウェイ、NTP など）、Hostname = "client"。
- **OFFER**（R1 → client、3 ミリ秒後）: R1 の MAC `08:00:27:88:5c:75` → client の MAC（**L2 ユニキャスト**）、`192.168.31.1.67 > 192.168.31.101.68`（**IP ユニキャスト**。ブロードキャストフラグが無いため）、`tos 0xc0`。Your-IP = 192.168.31.101、Server-ID = 192.168.31.1。
  - オプション: **Lease-Time (51) = 600**、**RN (58) = 300**（更新時間 T1 = 50%）、**RB (59) = 525**（再バインド時間 T2 = 87.5%）、Subnet-Mask、Broadcast、Domain-Name-Server (6) = 192.168.32.20、Default-Gateway (3) = 192.168.31.1、**Unknown (119)** = `3.108.97.98.7.101.120.97.109.112.108.101.0`（= `\x03lab\x07example\x00`、ドメイン検索リストのエンコード = `lab.example`）。
- **REQUEST**（#1）: 再びブロードキャスト。**Requested-IP (50) = .101、Server-ID (54) = 192.168.31.1**（どのサーバーの OFFER を受けるかを示す）。
- **ACK**（15 ミリ秒後）: 上のオプションに加えて **Hostname (12) = "client"** が付く（OFFER にはない）。
- → **#1 の DORA 全体で約 37 ミリ秒**。同じアドレス（.101）が、3 回とも配られた（dnsmasq がクライアント ID / MAC でリースを覚えている）。
- **DHCPRELEASE は観測されなかった**（`nmcli connection down` は、解放のメッセージを送らなかった）。

**予想外の点（#1 と #3）**
- #1 は `lease-stop` の最中、`lease-start` の前に起きた。候補: `nmcli connection down lab-dhcp` のあと `managed no` にするまでの間に、**NetworkManager が enp0s9 の別の自動接続のプロファイル（もとの `Wired connection` 系）を有効化し、DHCP を始めた**。確認していない（確認方法: client で `nmcli connection show` と `nmcli -f NAME,DEVICE connection show --active` を、`lease-stop` の途中で見る）。
- #3 が lease-start の後に起きた理由は不明（候補: 同じ自動接続のプロファイルの再有効化）。
- 対応: `lease-stop` を、先に `managed no`（NetworkManager の管理から外す）→ プロファイルの削除、の順に変更した（`down` を廃止）。変更後の確認は未実施。

### 2026-10-26 14:06〜14:09（dnsmasq のログ: 更新、lease-stop の再実行）
**`router logs 60`（`log-dhcp`）[実測]**: 表示されたのは 12:38:39 〜 12:48:14（60 行に収まる範囲）。
- 12:38:39（#3 の DORA の ACK）: `sent ... option: 51 lease-time 10m`、`option: 58 T1 5m`、`option: 59 T2 8m45s`、`option: 12 hostname client`、`option:119 domain-search 03:6c:61:62:07:65:78:61:6d:70:6c:65:00`、`option: 6 dns-server 192.168.32.20`、`option: 3 router 192.168.31.1`。`requested options:` の行は、client が要求したオプションの一覧（`1:netmask, 2:time-offset, 6:dns-server, 12:hostname, 15:domain-name, ... 119:domain-search ...`）。`next server: 192.168.31.1`。
- **12:43:40 と 12:48:14 の更新（unicast の `DHCPREQUEST(enp0s8) 192.168.31.101 08:00:27:5a:8e:0e` → `DHCPACK`）**: `client provides name: client`、`available DHCP range: 192.168.31.100 -- 192.168.31.150`、`tags: enp0s8`。12:38:39 の約 **5 分後**（T1 = 5m）に更新、次は 4 分 34 秒後（12:43:40 の ACK が示した T1 = 4m34s と一致）。
- **ACK が示す T1 / T2 は更新のたびに変わる**: 12:38:39 は T1 5m / T2 8m45s、12:43:40 は T1 4m34s / T2 8m19s、12:48:14 は T1 4m24s / T2 8m9s（リース時間は常に 10m）。T2 − T1 は約 3m45s 前後（3m45s、3m45s、3m45s）。dnsmasq が更新を分散させるための調整と思われる（候補。未確認）。
- **12:48:14 の次の記録がなく、14:06 まで DHCP の活動がない**（約 1 時間 18 分）。リースは 12:58:14 に失効するはずで、client が動いていれば更新が続くはず。候補: **ホスト PC のスリープなどで、VM が止まっていた**（以前の時刻のずれの原因の候補と同じ）。確認していない（`sync-all-auto.sh --check-only` で時刻のずれを見る、`lease-show` で今のリースを見る）。

**`lease-stop` の変更版（`managed no` を先に）での再実行（14:09）**
- ユーザーの報告: 「`lease-stop` → `lease-start` は 20 秒もかからず数秒で終了した」。→ **20 秒は失敗時（応答がないとき）の上限**で、成功なら数秒（`ipv4.dhcp-timeout 20` の意味）。
- `lease-start`（14:09:29）[実測]: exit 0、**elapsed=3.35 秒**、`192.168.31.101/24`（同じアドレス）。ルートは同じ（既定ルートなし）。
- 3.35 秒は、初回（3.51 秒）に近く、前の 0.54 秒（INIT-REBOOT の REQUEST のみ）より長い。完全な DORA を行った、と読める。DORA 自体は 37 ミリ秒なので、残りの約 3 秒の内訳は不明（候補: NetworkManager のアドレス競合の検出などの待ち）。
- **変更の効果（`lease-stop` の最中に DORA が起きないこと）は、この回は capture をしていないため未確認**。

### 2026-10-26 14:16〜14:25（lease-stop の効果、dnsmasq 停止、fw close）
- **ユーザーの報告（12:48 〜 14:06 の空白の理由）**: 「しばらく PC が休止状態だった。起動後に時刻を修正して実験を再開した」→ **ホスト PC の休止中に VM が止まっていた**（候補が裏づけられた）。
- **`lease-stop` の変更版の効果（capture、14:16:05、6 パケット）[実測]**: `lease-stop`（14:16:12）の最中の DHCP のやり取りは**なくなった**（最初のパケットは 14:16:13.550 = `lease-start` の開始後）。変更の効果を確認できた。
  - ただし `lease-start` の中で、**2 回のやり取り**が起きた: (1) `REQUEST`（Requested-IP .101、Server-ID なし = INIT-REBOOT）→ `ACK`（14:16:13.550 → .564）、(2) 0.8 秒後に **`DISCOVER → OFFER → REQUEST → ACK`**（14:16:14.381 → .401）。`nmcli connection up` の `elapsed=0.39 秒`。
  - (1) は、`managed yes` にした直後に、NetworkManager が `enp0s9` の別の自動接続のプロファイルを有効化し、以前のリースの再確認（INIT-REBOOT）を送った、と読める（候補。未確認）。(2) は、その後に有効化した `lab-dhcp`（リースの記憶がない）の最初の DHCP。確認方法: client で `nmcli connection show` を実行し、`enp0s9` に紐づく他のプロファイルと autoconnect の有無を見る（読み取りのみ）。
- **dnsmasq 停止（`router stop` 14:19:00）→ `lease-start`（14:19:10）[実測]**: `Error: Connection activation failed: IP configuration could not be reserved (no available address, timeout, etc.)`、**exit 4、elapsed=20.25 秒**。`enp0s9` は `UP` のままアドレスなし（`ipv6.method disabled` のため、リンクローカルもなし）。予想どおり（`ipv4.dhcp-timeout 20`）。この回は capture をしていない。
- **`fw close`（14:21:47）→ `lease-start`（14:22:33）[実測]**: 同じエラー、**exit 4、elapsed=20.26 秒**。
  - **注意（切り分けの不備）**: この時点で **dnsmasq は 14:19:00 の `stop` のまま起動していなかった**（`router logs` の最後は 14:19:00 の `exiting on receipt of SIGTERM`）。そのため、この回の失敗は「ファイアウォールが閉じていた」ためだけではなく、**dnsmasq が停止していたため**でもある。ファイアウォールの効果は分離できていない。→ `router start` の後に、`fw close` だけで再実施する。
  - capture（14:22:23、25 秒）[実測]: **3 つの DISCOVER だけ**（OFFER なし）。DISCOVER の再送の間隔: 14:22:34.164（xid 0x141e85c5、`secs 1`）→ 14:22:36.873（**+2.7 秒**、xid 0x77a2f2b1、`secs 2`）→ 14:22:41.425（**+4.6 秒**、xid 0x27e7cec9、`secs 7`）。**再送のたびに間隔が延び（約 2.7 秒、4.6 秒）、xid が新しくなり、`secs`（開始からの経過秒）が増える**。capture の窓（25 秒）が `lease-start`（14:22:33）の開始の 10 秒前から始まり、その後の約 15 秒分なので、20 秒の待ちの後半は含まれない可能性がある。
- 参考: `router` の `ss`（`sudo` なし、全ソケット）には、`udp ESTAB 10.0.2.15%enp0s3:bootpc 10.0.2.2:bootps`（NAT 側の DHCP クライアント = enp0s3 が VirtualBox の NAT から DHCP でアドレスを取得している通信）が見える。UDP 67 の待ち受け（dnsmasq）は無い（停止中のため）。
- 14:25:00 `fw open` で `dhcp` を戻した（`services` に `dhcp`）。

### 2026-10-26 18:47〜18:55（fw close だけの効果の分離）
- `router start`（18:47:10）: active、`ss -lunp`: `0.0.0.0%enp0s8:67`（dnsmasq、pid 14997）。
- `lease-start`（18:51:23、fw 開、dnsmasq 動作）: **成功、elapsed=3.34 秒**、`192.168.31.101/24`（同じアドレス）。router のログに 18:51:32 の `DHCPREQUEST(enp0s8) 192.168.31.101` → `DHCPACK`（先頭の `sudo` のパスワード入力の時間が、スクリプトの時刻と実際の DHCP の間のずれになる）。
- **`fw close`（18:53:06、dnsmasq は動作中）→ `lease-start`（18:53:23）[実測]**: 同じエラー（`IP configuration could not be reserved ...`）、**exit 4、elapsed=20.93 秒**。→ **dnsmasq 停止（14:19）のときと、client からは同じ症状**。
- **router の capture（`tcpdump -i enp0s8`、45 秒、`exp10-router-20261026T185308.pcap`、8 パケット）[実測]**: 全て client から（OFFER・ACK なし）。
  | 時刻 | 種別 | xid | `secs` | Requested-IP | 前回との間隔 |
  |---|---|---|---|---|---|
  | 18:53:23.415 | REQUEST（INIT-REBOOT） | 0x603687ed | 1 | .101 | — |
  | 23.705 | DISCOVER | 0xcb516358 | 1 | なし | +0.29 秒 |
  | 26.472 | DISCOVER | 0xb7a95704 | 2 | なし | +2.77 秒 |
  | 31.190 | DISCOVER | 0x2c58f499 | 7 | なし | +4.72 秒 |
  | 39.225 | DISCOVER | 0x1904fc8a | 15 | なし | +8.04 秒 |
  | 44.508 | REQUEST（INIT-REBOOT） | 0x46d0637d | 1 | .101 | |
  | 46.509 | DISCOVER | 0x9ed6ed1c | 1 | **.101** | +2.00 秒 |
  | 49.072 | DISCOVER | 0xb1880719 | 2 | **.101** | +2.56 秒 |
  - **DISCOVER の再送の間隔が、約 2.8 秒 → 4.7 秒 → 8.0 秒と、およそ倍々に延びる**（バックオフ）。`secs`（開始からの経過秒）は 1、2、7、15。再送のたびに xid は新しい。
  - **20 秒の待ち（`ipv4.dhcp-timeout 20`）が終わった 18:53:44 のあと、44.508 から2回目の組（REQUEST → DISCOVER → DISCOVER）が始まっている**。2回目の DISCOVER には **Requested-IP (.101)** が付く（1回目にはない）。候補: `lab-dhcp` の失敗のあと、NetworkManager が**別の自動接続のプロファイル**（以前のリースを覚えている）で DHCP を再試行した。確認していない。
- **dnsmasq のログ（`router logs 20`、18:54:50）[実測]**: 最後の記録は **18:51:32 の `DHCPACK`** のまま。**18:53:23 〜 18:53:49 の DISCOVER / REQUEST（パケットでは8つ見えた）は、1つも記録されていない**。→ ファイアウォールが dnsmasq の手前で止めた。
- **`ss -lunp 'sport = :67'`（18:5x）**: `0.0.0.0%enp0s8:67 users:(("dnsmasq",pid=14997,fd=4))` ― dnsmasq は**待ち受け中**。
- **「停止」と「fw close」の見分け方（client からは同じ症状）**:
  | 手がかり | dnsmasq 停止（14:19） | fw close（18:53） |
  |---|---|---|
  | client の `lease-start` | exit 4、約 20 秒 | exit 4、約 20.9 秒 |
  | router の tcpdump | DISCOVER が見える（前回は停止後の capture なし。パケットは同様に到達する見込み） | DISCOVER が見える |
  | dnsmasq のログ | 停止の記録（`exiting on receipt of SIGTERM`）のあと、記録なし | **サービスは動作中だが、DISCOVER の記録がない** |
  | `ss -lunp :67` | 待ち受けなし | **dnsmasq が待ち受け中** |
  | `firewall-cmd --list-all`（internal） | `dhcp` あり | **`dhcp` なし** |
- 18:55:26 `fw open` で戻した。

### 2026-10-26 19:01〜19:06（固定割り当て、片付け、ベースラインへの復帰、回収）
- `router reserve 08:00:27:5a:8e:0e 192.168.31.77`（19:01:29）→ dnsmasq 再起動。設定: `dhcp-host=08:00:27:5a:8e:0e,192.168.31.77`。
- client の `lease-stop; lease-start`（19:02:23〜27）[実測]: **`192.168.31.77/24` が配られた**（`connection up` は **0.34 秒**）。router のログ（`logs 40`、末尾 40 行）: 19:02:28 に `DHCPOFFER(enp0s8) 192.168.31.77`、`DHCPREQUEST(enp0s8) 192.168.31.77`、`DHCPACK(enp0s8) 192.168.31.77 ... client`。**`tags: known, enp0s8`**（`dhcp-host` に登録済みのクライアントに付く `known` タグ）。前のアドレス（.101）に対する **`DHCPNAK` は、末尾 40 行には見えなかった**（それ以前の行は取っていない。未確認）。
- `reserve clear`（19:04:14）、`router teardown`（19:04:37: dnsmasq 停止、`lab-dhcp.conf` とリースを削除、firewalld リロード。終了コード 0）、`client lease-stop`（19:05:04: プロファイル削除、`enp0s9` はアドレスなし）。
- ベースラインへの復帰（`baseline.sh up`、19:05:53）: 4 台とも終了コード 0。ping は **`ttl=62`**（基準どおり）。参考: client の `guard on` は `RTNETLINK answers: File exists`（exit 2）。guard の経路が残っていたため（無害）。router の `ip_forward` は、`prepare` の時点で 1 だった（以前の `up` の設定が残っていた）。
- 回収（`transfer.sh pull --exp-dir exp-dhcp-dnsmasq --pattern 'exp10-*' --only router,client`）: `from-client/`（16 ファイル）、`from-router/`（31 ファイル、pcap 4 つ）。
  - `from-router/` の `exp10-client-lease-start-20261026T141549 / 141845 / 141846.txt` と `exp10-client-lease-stop-20261026T141549.txt` は、client 用のコマンドを router で実行した記録（ホスト名の不一致で中止。安全装置の記録）。
  - **ファイル名の「:」を置換**: MAC アドレスを引数に含む記録 `exp10-router-reserve-08:00:27:5a:8e:0e-192.168.31.77-...txt` は、ファイル名に「:」を含み、Windows でチェックアウトできなくなるため、「-」に置き換えた（`...reserve-08-00-27-5a-8e-0e-192.168.31.77-...`）。`dhcp-test.sh` を、今後は「:」を使わないように修正した。VM 上の元のファイル名は「:」のまま。
