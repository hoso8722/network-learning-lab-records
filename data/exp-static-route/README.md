# 実験4: ルーター2台と静的ルート（仮ID: exp-static-route）

- 目的: 2つの LAN をルーター2台でつなぎ、静的ルートの有無で通信がどう変わるか（経路欠落、戻り経路の欠落、成功）を確認する。
- 状態: **実行中**。手順0〜4を実行。手順4で、ラボの通信が NAT 側へ漏れる事象を観測（下記）。
- **データ通信は不要**（`dnf` やダウンロードを使わない）。モバイル回線の制約に合わせた設計。
- 前提: A案確定。標準状態は各 VM の `base-clean`（512MB、ラボ設定なし）。

## 構成

```text
client(enp0s9)        R1 = router                         R2 = router2                  server(enp0s9)
192.168.31.10/24 -[lan-a]- enp0s8 192.168.31.1/24
                           enp0s9 192.168.30.1/30 -[transit]- enp0s8 192.168.30.2/30
                                                              enp0s9 192.168.32.1/24 -[lan-b]- 192.168.32.20/24
```

- 内部ネットワーク名: `lan-a`、`transit`、`lan-b`（ホスト・NAT・外部には非接続）。switch VM は使わない（電源OFFのままでよい）。
- アドレスは実験用。仕様の例示（192.168.10.0/24 等）は、既存の `poc1-lan`（client/server の enp0s8）と重なるため使わない。
- SSH ポート: client 2222、server 2223、switch 2224、router 2225、**router2 2226（新規）**。

## A. VirtualBox 側の準備（PowerShell、人間が実行、`$vb = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"`）

**関係する VM（client、server、router）は電源OFFで。**（`startvm` 直後の初回起動が失敗することがある。失敗したら再度起動する。）

1. router2 を作る（router の full クローン。512MB を継承。クローン元の router は NM プロファイルの整理済み）
   ```
   & $vb clonevm "Alma9mini-router" --name "Alma9mini-router2" --register
   & $vb modifyvm "Alma9mini-router2" --natpf1 delete ssh
   & $vb modifyvm "Alma9mini-router2" --natpf1 "ssh,tcp,127.0.0.1,2226,,22"
   ```
2. NIC の付け替え（状態変更。復旧: 各 VM を `base-clean` に復元、または元の接続先に戻す）
   ```
   & $vb modifyvm "Alma9mini-cli"     --nic3 intnet --intnet3 "lan-a"
   & $vb modifyvm "Alma9mini-router"  --nic2 intnet --intnet2 "lan-a" --nic3 intnet --intnet3 "transit" --nictype3 82540EM
   & $vb modifyvm "Alma9mini-router2" --nic2 intnet --intnet2 "transit" --nic3 intnet --intnet3 "lan-b" --nictype3 82540EM
   & $vb modifyvm "Alma9mini-server"  --nic3 intnet --intnet3 "lan-b"
   ```
   （router2 の NIC2 は、クローン時点で `sw-p3`（router のコピー）なので、`transit` に付け替える。）
3. 確認（読み取りのみ。結果を `host-nic-config.txt` として保存）
   ```
   foreach ($n in "Alma9mini-cli","Alma9mini-router","Alma9mini-router2","Alma9mini-server") { "== $n"; & $vb showvminfo $n --machinereadable | Select-String "^memory=|^nic[0-9]=|^intnet[0-9]=|^Forwarding" }
   ```
4. 4台を起動する。router2 のホスト名を設定する（**初回のみ。永続**。復旧: 元の名前 `router` に戻す。`router` と重ならないよう注意）
   ```
   ssh -p 2226 user@127.0.0.1        # 入って、次を実行
   sudo hostnamectl set-hostname router2
   ```
5. スクリプトを送る（`router2` を含む。手元のスクリプトは更新済み）
   ```
   cd "\\wsl.localhost\Ubuntu-24.04\home\<WSL_USER>\network-learning-handoff\labs\common"
   powershell -ExecutionPolicy Bypass -File .\transfer.ps1 -Mode push -ExpDir exp-static-route -Files route-test.sh -Only client,server,router,router2
   ```
6. 各 VM で `ip -br link` を実行し、NIC 名を確認する（想定: client/server は enp0s9、router/router2 は enp0s8 と enp0s9）。

## B. 実験の手順（SSH セッション 4つ）

| # | 対象 | コマンド | 予想（未検証） |
|---|---|---|---|
| 0 | router, router2, client, server | 各 `prepare` | エラーなし |
| 1 | router, router2 | 各 `fwd on` と `fw-zone on` | 転送の有効化、ゾーン割り当て |
| 2 | client / server | `ping-gw` | 成功（自分側のルーターに届く） |
| 3 | router | `ping 192.168.30.2` | 成功（R1 ↔ R2 の直結） |
| 4 | client | `ping-peer` | **失敗**（R1 に 192.168.32.0/24 の経路がない）。R1 が `Destination Net Unreachable` を返すか記録 |
| 5 | router | `route add 192.168.32.0/24 192.168.30.2` | |
| 6 | client | `ping-peer` | **失敗**（R2 に戻り経路がない）。client にはエラーが出ないか記録 |
| 7 | router2 | `capture` を起動、25秒以内に client で `ping-peer` | R2 に request が届き、server の応答が R2 から返らない（経路なし）様子 |
| 8 | router2 | `route add 192.168.31.0/24 192.168.30.1` | |
| 9 | client | `ping-peer`、`trace` | 成功、`ttl=62`（ルーター2台）、tracepath のホップ 1〜2 がルーター |
| 10 | 全 | `teardown`（client → server → router → router2） | |

「予想」は未検証。食い違ったら、そのまま記録し、原因は候補として扱う。

## C. 復旧
- VM 内の設定は `teardown` か再起動で消える（router2 のホスト名は永続）。
- VirtualBox: 各 VM を `base-clean` に復元すれば、NIC の接続先も元に戻る。復元後の初回起動が失敗したら、再度起動する。
- router2 は削除してよい。

## D. 記録すること
- 各動作の `exp4-*.txt`、pcap、`host-nic-config.txt`。回収は VM ごとのフォルダー（`from-client` など）。
- 予想と実測の食い違い。原因が証明できなければ「候補」。

## 結果と安全上の発見（手順 1〜4、2026-10-23、ユーザー実行・提出。`run1-raw-transcribed.txt`）

- 手順1: `fw-zone on` が、`enp0s8` で `ZONE_CONFLICT: 'enp0s8' already bound to 'public'`（exit=18）。`enp0s9` だけが `internal` に移った（router、router2 とも同じ）。
  `--add-interface` は、すでに別のゾーンに属するインターフェースではエラーになる。`--change-interface` で移す必要がある。
- 手順2〜3: ping-gw は client・server とも 3/3（ttl=64）、router → router2 の直結も 3/3。
- 手順4: client の ping-peer は 100% loss（エラーメッセージなし）。
  - router の capture: client の echo request が `enp0s8` で入り、**`enp0s3`（NAT 側）から出ている**（3回とも）。
  - 解釈（推定、未検証）: R1 に `192.168.32.0/24` の経路がないため、NAT の既定ルート（`default via 10.0.2.2 dev enp0s3`）に従って転送された。
    `enp0s8` と `enp0s3` が同じ `public` ゾーンのままなので、ゾーン内転送が許可されて NAT 側に出た。
  - 期待していた `Destination Net Unreachable` は、既定ルートがあるため出なかった。
- **安全上の評価**: ラボの通信（私設アドレス宛）が、ルーターの既定ルート経由で NAT 側（ホスト側のネットワークにつながる経路）に出た。応答なし、3 パケットで実害は観測していないが、演習ネットワークの隔離の観点で要対処（AGENTS.md の規則）。
- 対処: (1) `enp0s8` も `internal` ゾーンへ移す（`--change-interface`）。(2) ルーターの既定ルートを実験中は外す（`defroute off`）。(3) スクリプトを修正済み。
- スクリプトの変更: `fw-zone` を `--change-interface` に、`defroute off|on` を追加、`capture` に `not tcp port 22` を追加、`teardown` で `firewall-cmd --reload` と既定ルートの復旧。

## 結果: 経路欠落と戻り経路の欠落（手順 C・D、2026-10-23、ユーザー実行・提出）

| 状態 | client の ping | 観測 |
|---|---|---|
| R1 に経路なし、既定ルートなし、`enp0s8` は internal | 失敗。`From 192.168.31.1 Destination Net Unreachable` ×3 | R1 の capture に `ICMP net 192.168.32.20 unreachable`（R1 → client）。`enp0s3` への出力なし（NAT 側へ漏れていない） |
| R1 に経路追加、R2 に戻り経路なし | 失敗（無言、100% loss） | R2 の capture: `enp0s8` で echo request 3回入るが、**`enp0s9` から server へ出ていない**（予想: 転送して server の応答が戻れない、は外れた） |
| R2 にも戻り経路追加 | 成功、`ttl=62`（rtt 3.267/3.987/4.699/0.584 ms） | ルーター2台で ttl が 64 → 62。tracepath: ホップ1＝192.168.31.1、ホップ2＝`no reply`、ホップ3＝192.168.32.20（`!H`） |

- 予想外1: 戻り経路が無いとき、R2 は request を server へ転送していない。
  診断（router2）: `net.ipv4.conf.enp0s8.rp_filter = 1`（厳密）、`all` は 0、`default` は 1。`nstat`: `TcpExtIPReversePathFilter = 7`（逆方向経路フィルターによる破棄の累積数）。
  → 候補（R2 の rp_filter が、送信元に戻る経路が無いパケットを破棄した）を**強く支持**する観測。ただし、累積値で、経路の削除前後の比較は未実施のため確定はしない。
- 予想外2: R2 の NAT の既定ルートが、`defroute off`（01:14:27）の約7分後（01:21:48 の時点）に復活していた。候補: NetworkManager の DHCP リース更新が既定ルートを入れ直した（未検証）。
  `defroute off` は一時的な効果しかない。隔離は、ゾーンの修正（`enp0s8` を internal へ）が確実。D1 の時点で復活していたかは不明。
- 予想外3: tracepath のホップ2（R2）が `no reply`。理由は未確認。
- 隔離の確認: ゾーン修正後（手順A）の capture（R1）に、ラボの通信が `enp0s3` から出る行はない。

## 後片付け（teardown）と回収（2026-10-23）

- teardown は4台とも exit=0（`run1-raw-transcribed.txt`）。ラボのアドレスは外れ、ルーターの `firewall-cmd --reload` も success。
- 観測: router の teardown 後、既定ルートが**二重**になっていた（`ip route replace` が追加した行と、DHCP 由来の `proto dhcp` の行）。害はないが整っていない。
  → スクリプトの teardown を「既定ルートが無いときだけ戻す」に変更した。router2 は DHCP 由来の行がなく、追加した行だけだった。
- 中間の結論: NAT の既定ルートは、`defroute off` で外しても約7分で復活した。隔離は、ゾーンの設定（`enp0s8` を internal へ）で担保する。

## 記録の移動について（2026-10-23）
実験5（`data/exp-fault-ip/`）の準備と capture に使った router / router2 の記録（時刻 02:44 以降の16ファイル）は、`data/exp-fault-ip/from-router`・`from-router2` へ移した。
このディレクトリの `from-router`・`from-router2` に残るのは、実験4（00:xx〜01:xx）の記録だけ。
