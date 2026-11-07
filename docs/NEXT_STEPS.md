# 今後の手順(2026-10-20 時点。以降は追記。最新の状況は §18)

- 区分: **完了** = 実測で確認済み / **次** = 準備済みで実行待ち / **未着手** / **要判断** = 人間の判断が必要
- 実行担当: 人間(ホストと VM の操作)、AI(スクリプト・記録・文書)

## 1. 現在地

| 段階 | 状態 | 根拠 |
|---|---|---|
| PoC-0 ホスト確認 | 完了 | `data/poc-0-host/`、`docs/POC0_ANALYSIS.md` |
| PoC-1 AlmaLinux 2台の隔離LAN | 完了(項目1〜7。旧項目6は削除) | `data/poc-1-almalinux-lan/` |
| 実験A VLANタグ通過 | 完了 | `data/exp-vlan-tag-vbox/` |
| 実験2 スイッチ役VM(VLAN分離・許可VLAN・タグ除去・MTU) | 完了(手順13を除く) | `data/exp-vlan-switch/` |
| A案(AlmaLinux を機器役)の確定 | 完了(2026-10-20、人間の承認) | 仕様書 0.1.2 §2.3 |
| 実験3 Router-on-a-Stick | **次**(準備済み・未実行) | `data/exp-router-on-a-stick/` |

## 2. PoC-2 の残り(実証)

| # | 内容 | 状態 | メモ |
|---|---|---|---|
| 2-1 | 実験3: VLAN 間ルーティング(4台目 router、静的ルート、ttl 減少、tracepath、トランクでのタグ観測、許可 VLAN 不足) | **次** | README の手順 A→B。512MB のメモリ試験を router で兼ねる |
| 2-2 | 静的ルート(複数サブネット、ルーター2台、Phase 3 の構成) | 未着手 | VM の追加(5台目)が必要になる見込み。メモリ 512MB の結果次第 |
| 2-3 | 機能の公式資料確認: Linux bridge の VLAN フィルタリング/STP、FRR の AlmaLinux 9 向けパッケージ、OSPF | 一部完了(2026-10-22、`docs/RESEARCH_NOTES.md` §6)。FRR は EL9 対象（AlmaLinux 名は無し）、bridge VLAN は第三者資料のみ、STP は未確認 | STP/OSPF は MVP 後(Stage D 寄り)だが、PoC の合格基準の「機能を公式資料で確認」に必要 |
| 2-4 | 故障演習の種類を揃える(MVP は3種類以上) | 一部完了 | 済み: VLAN不一致(C03)、トランク許可VLAN不足(C04)。次: IP/マスク誤り(C01)、経路欠落(C02)、ポート未待受(C05)など |
| 2-5 | HTTP/TCP サービス、DNS の基本(MVP の範囲) | 未着手 | PoC-2 の範囲外だが、MVP 受け入れ基準 4 に必要。サーバー役に httpd/bind 等を入れる(パッケージ導入は NAT 有効で実施) |
| 2-6 | PoC の判定(Go / Conditional Go / No-Go) | 2-1〜2-3 後 | `docs/PROOF_OF_CONCEPT.md` の基準。未確認項目を明記して判定 |

## 3. シリーズ計画と仕様の確定(人間の承認が必要)

| # | 内容 | 状態 |
|---|---|---|
| 3-1 | `specs/ROADMAP.md` を A案(AlmaLinux 機器役)に合わせて更新(GNS3 前提の記述の見直し、記事の並びの再検討) | 未着手 |
| 3-2 | 記事 Spec のスキーマ(`_series.yaml` と記事 Spec)の確定 | 未着手。サンプルは仕様 §10 |
| 3-3 | O-13: SITE_SPEC_SUMMARY.md(Java サイト)のルールのうち流用するもの(題名形式、太字禁止、箇条書きは「まとめ」だけ、コード4本以上、タグ埋め込み、yomiyasu、規模) | **要判断** |
| 3-4 | O-14: 文体 lint(yomiyasu)が使えるか | 調査(AI) |
| 3-5 | O-07: 記事数と順序のレビュー | **要判断**(承認ゲート①: シリーズ計画) |

## 4. サイト実装(承認後)

1. Astro + TypeScript の骨格(一覧、記事、前後ナビ、モバイル対応、色だけに頼らない表現)。
2. `published` の既定を `false` にし、公開一覧は `true` だけ(AI は `true` にしない)。
3. 検証スクリプト: Spec のスキーマ、記事メタデータ、内部リンク、未公開記事へのリンク禁止、コマンド抽出と危険度分類、記事内出力と `data/` の照合。
4. 単体テスト(Vitest 等、必要最小限)とビルド。
5. Cloudflare Pages 向けのビルド設定。push とリリースは承認ゲート。

## 5. 記事制作(1シリーズずつ)

| 手順 | 内容 |
|---|---|
| 1 | シリーズ計画 → 人間が承認 → `_series.yaml` と記事 Spec |
| 2 | 記事ごとにラボで実験し、`data/<記事ID>/` に生出力・環境記録・`collect.sh` を保存 |
| 3 | 本文はデータをファイルから埋め込む。`prompts/generate.md` を使う |
| 4 | `prompts/fact-check.md` で別工程の照合 → 指摘は確認して直す、確認できなければ削除 |
| 5 | `prompts/review.md` でレビュー、`published: false` で保管 |
| 6 | 承認ゲート②: 人間が1シリーズずつ確認して公開を決める |

### 既存データの扱い(記事化の前に整理が必要)
- 仮ID(`a02`、`a03`、`a04`、`a06`、`a07`、`exp-*`)は、記事 ID が決まったら `git mv` で付け替える。
- `a03`・`a04` の転記は `<WSL_USER>` アカウントのまま。公開前に `user` アカウントで再採取するか判断する(O-15)。
- VM の時計が NTP 未同期の状態で採ったデータがある。`labs/common/sync-time.sh` を実験前に実行する運用に統一する。
- 回収時は、VM ごとにフォルダーを分けて `scp` する(同名ファイルの上書きを防ぐ)。

## 6. 共通の運用

- スナップショット: 状態を変える実験の前に取る。
- 実験の前に: NAT 有効で時刻同期 → 実験 → 隔離が必要な確認は NAT を切って行う。
- Git: コミットは人間が依頼したときに行う（2026-10-20 時点では、コミットが無かった。現在の状態は §18）。
- 公開リポジトリへの push、`published: true`、外部ネットワーク接続設定は承認ゲート。公開用リポジトリへの同期は、§18 の GitHub Actions（手動実行）。

## 7. メモリ(512MB)の判断材料

- 測定値(server、idle、設定 1024MB): `total 764 / used 304 / free 252 / buff/cache 329 / available 459 / Swap 2047(未使用)`(MB、`data/exp-router-on-a-stick/guest-memory-before.txt`)。
- 設定 1024MB に対し VM 内で見える合計は 764MB(約 260MB は見えない。理由は未確認)。
- `used` 304MB は、設定を 512MB にしたときの見える合計が不明なため、余裕があるとは言えない。見える合計が 250〜500MB 程度に縮むと、`used` 304MB は厳しい。
- スワップが 2GB あるため、メモリ不足でもすぐに強制終了(OOM)するとは限らないが、遅くなる。
- 結論: **router(新規 VM)で 512MB を試して測る**。結果を見て、他の VM に広げるかを判断する。

## 8. 次の一歩

1. VirtualBox の準備(`data/exp-router-on-a-stick/README.md` A): switch に NIC4、server をクローンして router、SSH ポート 2225、`nic3 none`、router は `--memory 512`。
2. 4台を起動し、スクリプトを転送、NIC 名を確認。
3. 実験3の手順 0〜11 を実行。

## 9. 追記(2026-10-20 夜)

- router(設定 512MB、server のクローン): アイドルで `total 453 / used 158 / available 294`、`dnf makecache` 後に `used 162 / available 290 / swap 使用 4MB`。OOM なし(`data/exp-router-on-a-stick/guest-memory-512.txt`)。
  未確認: tcpdump の長時間キャプチャ、パッケージのインストール、httpd/FRR。他の VM は実験3の後に測って決める。
- ホスト休止後の VM の時計: 約9時間遅れ。`sync-time.sh`（旧版）は OK と出たが時刻が変わらず、手動の `burst 4/4` + `makestep` で補正できた。`sync-time.sh` に burst を追加（要再転送）。

## 10. 追記(2026-10-22): メモリ 512MB への変更後の起動失敗(訂正あり)

- 事象: client・server・switch のメモリを 1024MB → 512MB に変更したところ、**変更後の初回の起動**が失敗した（ユーザー申告）。
- client の VirtualBox ログ（ユーザー提出）: `VMState="aborted"`、`memory=512`、`cpus=4`。起動の約9.8秒後に
  `!!Assertion Failed!! Expression: RT_VALID_PTR(pVM)  Location: VMMR3\VM.cpp(602) vmR3CreateU`、`pVM=0000000000000000`。
  VM の作成段階の失敗で、ゲスト OS の起動前。`VERR_` のエラーコードはログに出ていない。
- 追加の観測（ユーザー申告）: **server と switch は、512MB のまま2回目の起動で成功した**。
- 訂正: 先に「client を 1024MB に戻したら起動できたので、512MB が引き金の可能性が高い」と述べたが、**その比較は交絡していた**
  （client の成功も2回目の起動だったため、メモリ値の違いと「2回目であること」を区別できない）。この推論は取り下げる。
- 現在の見立て（ユーザーの観察）: **スナップショットを取った後の、初回の起動で失敗する**ように見える。
  3台とも「初回失敗 → 2回目成功」の同じパターンで、server と switch は 512MB で動いているため、512MB 自体は動作する。
  ただし原因（スナップショット、設定変更、その他）は**未特定**。router は最初から 512MB で、同じ失敗は報告されていない（スナップショット後に起動したかは未確認）。
- 方針: 512MB 化を継続してよい（server・switch は 512MB で起動成功）。初回の起動に失敗したら、もう一度起動する。
  確認が残る項目: client を 512MB にして起動できるか（現在 1024MB）、各 VM の `free -m`。
- 注意: 現在のスナップショットは `change memory`（ユーザー作成）。`exp3-done` へ復元すると VM の設定（メモリ等）も戻る。

- 追記(2026-10-22): client も 512MB で起動成功（初回は失敗、再起動で成功）。client の `free -m`: `total 453 / used 157 / available 295`、swap 未使用。server・switch も近い数値（ユーザー申告）。
  4台とも 512MB で動作している。アイドル時の `available` は約 290MB（`data/exp-router-on-a-stick/guest-memory-512.txt`）。tcpdump の長時間キャプチャやパッケージのインストール時の挙動は未確認。
- 追記: クローンの確認: router・switch とも `enp0s8` のプロファイルは `manual` / `192.168.10.20/24`（server 由来）。switch には `Wired connection 1/2`（enp0s9/enp0s10 用とみられる自動プロファイル）もある。

## 11. 追記(2026-10-22): クローンの整理とスナップショット

- クローンの整理（ユーザー実行・提出）: router・switch で `sudo nmcli connection modify enp0s8 ipv4.method disabled ipv4.addresses ""` と `nmcli connection up enp0s8`。
  実行後の `ip -br addr`: 両方とも `enp0s8 UP`（アドレスなし）。`192.168.10.20/24` は消えた。
  未確認: 再起動後も保持されること（プロファイルを永続的に変更したので保持される見込み）。
- スナップショット `base-clean` を4台に取得（ユーザー提出。説明: 512MB、クローン整理済み、スクリプト更新済み、電源OFF）。UUID: 73b92abb-… / 252a4ecb-… / 6139cac9-… / b44a64c1-…（VM名との対応は出力に無い）。
- スナップショットの一覧（申告・提出ベース）:
  | VM | スナップショット |
  |---|---|
  | Alma9mini-cli | poc1-ip-configured、pre-exp2、exp3-done、change memory、base-clean |
  | Alma9mini-server | poc1-ip-configured、pre-exp2、exp3-done、(change memory の有無は未確認)、base-clean |
  | Alma9mini-switch | exp3-done、(change memory の有無は未確認)、base-clean |
  | Alma9mini-router | exp3-done、base-clean |
- 現在の標準状態: `base-clean`（4台とも 512MB、ラボ設定なし、スクリプト更新済み、クローン整理済み）。復元すると、ここに戻る。
- 注意: スナップショット後の初回起動が失敗することがある（§10）。失敗したら再度起動する。

## 12. 追記(2026-10-23): 次の実験の順序、記事生成の時期、規模の見積もり

### 12.1 次の実験のおすすめ順（実験4まで完了）
| 順 | 内容 | 通信 | 理由 |
|---|---|---|---|
| 1 | L4: TCP/UDP とポート（`ss`、`curl -v`、`python3 -m http.server`。接続成功 / 拒否(RST) / タイムアウト(DROP)の違い、firewalld の reject と drop） | 不要 | 仕様 §3.2 の到達目標。MVP 受け入れ基準 4・Stage C05/C06 に直結。追加パッケージなし（`python3`・`curl` は導入済みの見込み。未確認） |
| 2 | IP/マスク誤り、ゲートウェイ誤り（Stage C01/C02） | 不要 | 短時間。ARP・経路・ping の組み合わせで切り分けを練習 |
| 3 | TLS 証明書（自己署名、期限切れ、ホスト名不一致。`openssl s_client`、`curl`） | 不要の見込み | Stage C09。`openssl` は導入済みの見込み（未確認） |
| 4 | HTTP 応答エラー（403/404/500。`python3` の簡易サーバーで再現） | 不要 | Stage C08 |
| 5 | DHCP / DNS（`dnsmasq` または `bind` の導入） | 必要（メタデータ約78MB/VM + パッケージ） | MVP の範囲。導入前に `dnf -C install --assumeno` で量を確認 |
| 6 | FRR / OSPF（Stage B11 / C10） | 必要 | AlmaLinux 9.8 での動作は未確認。外部リポジトリの取得に承認 |
| 7 | STP と L2 ループ（Stage D） | 不要 | Linux bridge の STP の公式資料が未取得 |

### 12.2 記事生成を始める時期
- **シリーズ計画の草案づくりは、今から始められる**（通信不要・実験と並行可）。ただし、記事本文の生成は **承認ゲート①（シリーズ計画の承認）の後**（AGENTS.md: 記事 Spec を先に確認する）。
- 順序: (1) ROADMAP を A案に合わせて更新、(2) シリーズ計画の草案 → 人間が承認、(3) O-13（Java サイトのルールの流用範囲）を決める、(4) 記事 Spec のスキーマ、(5) **パイロット記事を1〜2本**（データが揃っている題材。例: 経路欠落と戻り経路の欠落〔実験4〕、VLAN トランクと許可 VLAN〔実験2〕）を `published: false` で生成して、生成 → Fact Check → レビューの工程を試す、(6) 工程の問題を直してから量産。
- 記事の根拠にするデータは、可能なら当該スクリプトで再採取する（時刻付きのファイル名、ホスト名の確認、`user` アカウント、時刻同期済み）。a03/a04 の転記は `<WSL_USER>` のまま。

### 12.3 大規模に近い構成の見積もり（未検証。実測前の見積もり）
- 可能性はある。ただし、VM を増やすだけでなく、**軽量な方法を併用する**のが現実的。
- VM 方式: 実測した 512MB の VM は、ゲスト内 `used` 約160MB、アイドル時の `available` 約290MB。ホスト 30.8GB のうち、WSL2 等で約2〜3GB を使用。
  VM 1台あたりのホスト側の使用量は、1024MB 設定のとき 700〜916MB（実測、Working Set）。512MB 設定時のホスト側の値は未測定。
  概算では 10〜15 台程度（ルーター8〜10台 + ホスト数台）は、メモリ上は現実的な範囲（要実測）。CPU は 8コア/16スレッド。
- 軽量方式: 1つの VM の中に Linux の network namespace（veth、bridge）で多数のルーター・ホストを作る。メモリの消費が小さく、数十〜数百ノードの論理構成を作れる見込み。FRR などを namespace ごとに動かす構成も考えられる（要検証）。
- 限界: ベンダー機器 OS の CLI・ハードウェアの挙動・本物の性能は再現できない。大規模網の設計（BGP 設計、データセンターファブリック等）は MVP の範囲外（仕様 §12.2）。
- 制約: VirtualBox の VM は 1台あたり GUI では NIC 4つ（コマンドでは8つ）。構成はスクリプト化（トポロジー定義 → VM 作成）しないと運用が重い。VM の初回起動が失敗する現象（§10）もある。

## 13. 追記(2026-10-23): 実験4の回収、スナップショット、通信量を問わない場合の実験の順序

- 実験4の回収: 完了（`data/exp-static-route/from-client`、`from-server`、`from-router`、`from-router2`。時刻付きのファイル名のため上書きなし）。
  貼り付けに無い記録: 00:43:01 の client ping-peer（失敗）、00:50:39 の router の capture（未分析）。
- スナップショット `exp4-done`: 取得済み（ユーザー申告）。
- 通信量を問わない場合の実験の順序（難易度は主観の目安 ★1〜★5）:
  1. IP・マスク・ゲートウェイの誤り（C01/C02、★1）→ 2. L4 TCP/UDP とポート（C05/C06、★2）→ 3. HTTP 応答エラー（C08、★2）
  → 4. TLS 証明書（C09、★3）→ 5. DHCP と DNS（`dnsmasq`、C07、★3）→ 6. FRR と OSPF（C10、★4）→ 7. 複合障害（C11、★4）→ 8. STP（Stage D、★4）→ 9. 多ノード構成（★5）。
  方針: 下の層から上の層へ、同じ道具（`ping`、`ip route`、`tcpdump`、`ss`）を繰り返し使う。

## 14. 追記(2026-10-23): STP / L2 ループの実現可能性と、大規模構成から広がる実験の案

### 14.1 STP と L2 ループは実現可能か（見込み。未検証）
- 実現可能とみられる。Linux bridge に STP がある（`stp_state`）。実測で、実験2の bridge は `stp_state 0` と、既定のタイマー値（15秒・2秒・20秒）を持つ。
- 最小構成: スイッチ役 VM 2台 + 並行リンク2本（これだけでループ）。標準的な構成: スイッチ役 VM 3台の三角形 + ホスト2台（ルートブリッジの選出とブロックポートの観察に向く）。
  各スイッチ役 VM は、NAT + 2リンク + ホスト用 = NIC 4（GUI の上限内）。
- 観察できること: STP なしでのストーム（短時間に制限）、`stp_state 1` でのルート選出（`priority` で制御）、ブロックされたポート（`bridge link` の `state`）、BPDU の capture、リンク切断後の収束時間。
- 注意・リスク: (1) ストームでホストの CPU が占有される可能性。短時間に限り、`controlvm setlinkstate` または電源OFFで止める。VM の `cpus` を減らす。実験前にスナップショット。(2) カーネル STP の版は未確認（RSTP は `mstpd` が必要な見込み）。(3) 難易度 ★4。MVP の範囲外（Stage D）。
- 判断: 実現可能。優先順位は低い（実験の順序の8番）。

### 14.2 大規模構成から広がる、実務に沿った実験の案（未着手の構想）
| 分類 | 実験の例 | 方式 | 難易度 | パッケージ |
|---|---|---|---|---|
| 冗長・収束 | OSPF の複数経路（ECMP）、リンク障害後の収束時間、経路のコスト調整 | FRR（VM または namespace） | ★4 | 要（FRR） |
| 3層構成 | コア / ディストリビューション / アクセスの VLAN と L3 | VM 8〜12 台 | ★4 | 不要〜 |
| 第一ホップ冗長 | VRRP 相当（`keepalived`）でゲートウェイを二重化、障害時の切り替え | VM | ★3 | 要（keepalived） |
| リンク冗長 | LACP（Linux bonding）、STP の併用 | VM | ★4 | 不要 |
| 拠点間 | 複数拠点 + 中央、`tc netem` で遅延・損失・帯域を付与（WAN 品質） | VM または namespace | ★3 | 不要の見込み |
| MTU / MSS | 経路上の MTU の違い、PMTUD が失敗する状況（ICMP を遮断） | VM | ★3 | 不要 |
| NAT / DMZ | SNAT / DNAT、DMZ、firewalld の rich rules、conntrack の観察 | VM | ★3 | 不要 |
| サービス層 | DNS の階層（権威 / キャッシュ）、DHCP リレー、リバースプロキシ、負荷分散 | VM | ★4 | 要 |
| 運用 | 変更前後の状態採取と差分、ロールバック（スナップショット）、ランブック作成（Stage C12） | VM | ★2 | 不要 |
| 自動化 | トポロジー定義（YAML）から VM / namespace を作る、Ansible で一括設定、ラボのテスト自動化 | スクリプト | ★4 | 要（Ansible 等） |
| 規模 | namespace で数十ノードの OSPF、ルート数の増加、LSDB サイズ | namespace + FRR | ★5 | 要（FRR） |
| 防御 | ARP の不正検知、MAC 数の制限（bridge の機能）、rp_filter・uRPF（実験4で遭遇） | VM | ★3 | 不要の見込み |
- 防御系の実験は、**隔離ラボ内に限る**（AGENTS.md: 第三者網への攻撃・スキャンを含めない）。
- ベンダー機器との対応（Cisco の `spanning-tree`、`ip route` などの対比表）は、公式資料での確認が必要。記事の補足として、後で検討。

## 15. 追記(2026-10-23): 実験5（IP・マスク・ゲートウェイの誤り）の結果

- S0〜S3 を実行（`data/exp-fault-ip/`）。いずれも予想どおり。ping の表示は S1・S2 で同じ（`From` が client 自身）で、`ip route get` の `via` と ARP の相手で見分ける。S3 は ARP が出ず、ローカルの OS が `No route to host` を即座に返す。
- 実験4で観測した NAT 側への漏れを防ぐため、guard（`unreachable 192.168.0.0/16 metric 4000`）を client に入れて実施した。S3 でも漏れはなく、R1 の capture は 0 パケット。
- 残り: client の `fix`、各 `teardown`、回収、スナップショット（任意）。
- 次の実験: 実験6 = L4（TCP/UDP とポート。`ss`、`curl -v`、成功 / 拒否(RST) / firewalld の reject / drop(タイムアウト)）。

- 追記: 実験5の後片付け: client を `fix`（`ttl=62` に復旧）、回収完了（`data/exp-fault-ip/from-*`、実験4の router / router2 の記録も追加で回収）。
- 追記: 実験6（L4）の手順書とスクリプトを用意（`data/exp-l4-ports/`）。T0〜T8（成功 / 待ち受けなし / 許可なし / drop / RST / UDP）。未実行。

## 16. 追記(2026-10-23): ホスト再起動後の実験6の準備

- ホスト PC が自動で再起動し、VM の実行時の設定が消えたため、実験4・5のベースラインを再構築した（`docs/LAB_RESTART.md`）。
- ユーザー申告: 実験6の準備が整い、client から server への ping で `ttl=62` を確認済み。**再構築の出力は提出されていない**（ユーザーが今回は割愛）。
  VM 内にスクリプトの出力ファイル（時刻付き）が残っているはずなので、必要なら実験6の終了時に回収できる。
- 実験6は、実験5の構成（client – R1 – R2 – server）を流用する。
- 実験6の終了後に、SSH 鍵の導入と一括構築のスクリプトを導入する（`docs/TODO.md` の A）。

## 17. 追記(2026-10-24): 実験6（L4）の結果

- T0〜T8 を実行（`data/exp-l4-ports/`）。TCP の成功 / 待ち受けなし(RST) / 許可なし(ICMP) / 破棄(タイムアウト、SYN 再送) / RST で拒否(T2 と同じ見た目)、UDP の正常 / 待ち受けなし(ICMP port unreachable) / 破棄(無応答)。いずれも予想どおり。
- 残り: server の `teardown`、回収、スナップショット（任意）。その後、SSH 鍵の導入と一括構築のスクリプト（`docs/TODO.md` の A、ユーザー決定）。
- 次の実験の候補（順序）: 3. HTTP 応答エラー（C08）→ 4. TLS 証明書（C09）→ 5. DHCP / DNS → 6. FRR / OSPF → …（§13）。

- 追記(2026-10-24): 実験6の `teardown`（server）と回収（`data/exp-l4-ports/from-client`、`from-server`）が完了。ベースライン再構築の記録（ルーター、client / server の `exp4-*` / `exp5-*`）は未回収（必要なら日付を絞って回収）。
- 追記: `labs/common/snapshot-all.ps1` を作成（停止 → スナップショット。`-DryRun` あり、同名はスキップ）。

- 追記(2026-10-24): スナップショット `exp6-done` を4台に取得（`snapshot-all.ps1`、電源OFFの状態、ユーザー提出）。UUID: client 3949d1a9-… / server bfa0e16f-… / router da68d99a-… / router2 7affff36-…（対応は出力順）。
  出力に `NativeCommandError` が表示されたが、スナップショットは成功していた。原因は、VBoxManage の進捗（標準エラー出力）を `2>&1` でまとめたため（Windows PowerShell 5.1 の仕様）。スクリプトを修正済み。

## 18. 追記(2026-11-07): 記事の状況と、公開用リポジトリへの同期

### 18.1 現在地
- 記事: `series: lab-experiments`（order 10〜120）の 12 本の下書きと、環境構築（E1〜E6）が揃った。各記事は、Spec と証拠表、独立 Fact-check、修正、修正範囲の再チェックを済ませた（`docs/ARTICLE_PLAN.md` の Q-W）。
- 公開: E1（`articles/e1-lab-overview-01.md`）だけが `published: true`（2026-11-07、ユーザーの指示。記録は `docs/ARTICLE_PLAN.md` の「公開の承認」）。ほかは `published: false`。
- 出典リンク（O-18、2026-11-07 に案 B へ変更）: 公開用リポジトリ `hoso8722/network-learning-lab-records`（Public）に、公開してよい記録とスクリプトだけを、GitHub Actions で同期する。実装と手順は `docs/PUBLIC_RECORDS_SYNC.md`。サイトの `/records/` ページは廃止した。
- 同期の設定（ユーザーの端末の出力による申告）: デプロイキーの登録、Secret（`PUBLIC_RECORDS_DEPLOY_KEY`、`REDACTION_RULES`）の登録、秘密鍵ファイルの削除は済み。ワークフローを実行しようとして HTTP 404 になった。原因は、ワークフローのファイルが原本リポジトリ（GitHub 側）にまだなかったため（push が必要）。

### 18.2 次の手順
| # | 内容 | 担当 |
|---|---|---|
| 1 | 原本リポジトリへ push（ワークフローを GitHub に載せる） | ユーザーの承認 → AI または人 |
| 2 | dry-run: `gh workflow run sync-public-records.yml -R hoso8722/network-learning-handoff` → 対象のファイルの一覧と検査の結果を確認する（`docs/NEXT_STEPS.md` を含めてよいか） | 人 |
| 3 | 公開: `-f publish=true` で実行 → 公開用リポジトリの内容を確認する | 人 |
| 4 | `npm run build`（本ビルド）が通ることを確認する（同期の前は失敗する） | AI または人 |
| 5 | 公開前の人による原文確認（取得ツールの要約は逐語でない）、ブラウザでの表示確認、Cloudflare Pages の設定（承認ゲート） | 人 |
| 6 | 再実行でしか埋まらない項目（`docs/RERUN_ITEMS.md`）を実施するかの判断 | 人 |
| 7 | 残りの記事を `articles/` に移して公開する（1 本ずつ承認。公開するたびに、同期 → 本ビルド） | 人 |

### 18.3 未解決
- E1 の本文から、未公開の記事（B05 など）への記事間リンクは、本ビルドでは文字だけになる（`src/lib.ts`）。公開されるとリンクに戻る。
- 公開リポジトリのライセンスの著作権者の表記は、アカウント名 `hoso8722`（`public-repo/LICENSE`）。
- 古い §1〜§17 は、当時の記録として残している（現在の状態と食い違う記述がある）。
