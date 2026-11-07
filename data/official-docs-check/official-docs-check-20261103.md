# 公式資料との照合(2026-11-03、Claude Code が WebFetch / WebSearch で実施)

- 性格: 取得ツールが返した**要約**(小さなモデルによる要約)。原文の逐語ではない。引用の形で書かれた文も、ツールの返答のまま(原文との一字一句の照合は、していない)。重要な主張は、公開の前に、人が原文で確認する。
- 対象バージョン: OpenSSH は upstream(OpenBSD のマニュアル)。AlmaLinux 9.8 の `openssh-server-9.9p1-7.el9_8.alma.1`(e2b-2 の記録)との差は、確認していない。VirtualBox は 7.1(使用している 7.1.10)の公式ガイド。
- 判定: **確認**(公式資料の記述と、記事の主張が一致)／**一部確認**／**記載なし**(公式資料に記述がない)／**未確認**(取得できなかった)。

| # | 主張(記事) | 参照先 | 判定 | 要点 |
|---|---|---|---|---|
| O1 | `PermitRootLogin prohibit-password`(古い別名 `without-password`)は、root のパスワードと keyboard-interactive 認証を無効にする。既定は `prohibit-password`。`PasswordAuthentication` の既定は yes | https://man.openbsd.org/sshd_config | 確認 | 「If this option is set to prohibit-password (or its deprecated alias, without-password), password and keyboard-interactive authentication are disabled for root.」。AlmaLinux 9.8 の OpenSSH 9.9p1 との差は未確認 |
| O2 | `ssh-keygen -R <host>` は、known_hosts から該当ホストの鍵をすべて消す(ポート付きも可)。`-F` は検索のみで変更しない。`-l` は公開鍵のフィンガープリントを表示 | https://man.openbsd.org/ssh-keygen | 確認 | `known_hosts.old` が作られることは、マニュアルの `-R` の記述にない(`-H` では `.old` に退避すると書いてある)。記事の `.old` は、**実測**(e2b-6)。 |
| O3 | known_hosts の各行は、ホスト名、鍵の種類、base64 の公開鍵(フィンガープリントではない)。非標準ポートは `[host]:port` | https://man.openbsd.org/sshd.8 (SSH_KNOWN_HOSTS FILE FORMAT) | 確認 | 「The keytype and base64-encoded key are taken directly from the host key」。 |
| O4 | `ssh-add` の終了コードは、0 が成功、1 がコマンドの失敗、2 が agent に接続できないとき。`ssh-add -d` は引数に公開鍵のファイルのパスを取り、`.pub` を補う | https://man.openbsd.org/ssh-add | 確認 | `-l` で鍵がないときの終了コード 1 は、マニュアルの「1 if the specified command fails」に含まれるかどうかは、明記なし(実測では 1 を想定。e2b-8 では未測定)。 |
| O5 | `AddKeysToAgent yes` は、ファイルから鍵を読んだとき、鍵を agent に追加する。agent がないときの動作は記載なし。`IdentitiesOnly` は、agent が他の鍵を示しても、設定した鍵だけを使う | https://man.openbsd.org/ssh_config | 一部確認 | agent がないときの挙動は、マニュアルに記載なし(E4 では「記載なし」と書く)。 |
| O6 | `chronyc makestep` は、システム時計を一度に補正する(跳ばす)。跳びで影響を受けるソフトがある、との警告。`tracking` の `RMS offset` は、offset の長期平均。`System time` は、chronyd の NTP 時計とシステム時計の差 | https://chrony-project.org/doc/4.5/chronyc.html | 確認 | 補正の基準は chronyd の時刻(時刻源に同期した時計)。ホストの時刻ではない。RMS offset の説明は、「測定は時刻の跳びを含むかもしれない」という記事の候補と矛盾しない(長期平均のため)。 |
| O7 | `hostnamectl set-hostname ""` で、静的ホスト名が未設定に戻るか | https://www.freedesktop.org/software/systemd/man/latest/hostnamectl.html 、https://man7.org/linux/man-pages/man1/hostnamectl.1.html | 記載なし | 取得したページは `set-hostname` を載せず(新しい版では `hostname [NAME]` の形)、空文字の扱いの記述がない。静的・一時的(transient)・pretty の区別は確認(「If a static hostname is set to a valid value, then the transient hostname is not used.」)。空文字は未確認のまま |
| O8 | NAT のポートフォワードは `modifyvm` の VM 電源オフ時の設定。起動中は `controlvm` | https://docs.oracle.com/en/virtualization/virtualbox/7.1/user/vboxmanage.html (7.1。先頭 10 万字) | 一部確認 | 7.1 のページの表記は `--nat-pf<N>`(`--nat-pfN=[rule-name],tcp\|udp,[host-IP],hostport,[guest-IP],guestport`、削除は `--nat-pfN=delete=rule-name` の形。要約)。記事の `--natpf1`(旧表記)は、実測で 7.1.10 でも通った(e2b-4)。`controlvm` の natpf の構文は、要約のため未確認。削除コマンドは未実行 |
| O9 | 内部ネットワークの説明と、ネットワークモードの表(列: VM→Host、VM←Host、VM1↔VM2、VM→Net/LAN、VM←Net/LAN。Internal は – – + – –、NAT は + / Port forward / – / + / Port forward) | https://docs.oracle.com/en/virtualization/virtualbox/7.1/user/networkingdetails.html | 確認 | 「Internal Networking. This can be used to create a different kind of software-based network which is visible to selected virtual machines, but not to applications running on the host or to the outside world.」。E1 の転記(user-supplied [8])と一致。「同じ名前の内部ネットワークの VM 同士だけ」という文言は、取得した範囲では未確認 |
| O10 | `firewall-cmd --change-interface` は、`--remove-interface` のあとの `--add-interface` と同じ。`--reload` は、永続設定にない実行時だけの変更を失わせる | https://firewalld.org/documentation/man-pages/firewall-cmd.html | 確認 | `--add-interface` で、すでに別のゾーンにあるインターフェースの扱いは、マニュアルに記載なし(記事の `ZONE_CONFLICT` は、実測の記録)。NetworkManager が管理するインターフェースは、NetworkManager 経由でゾーンを変えようとする、との記述あり |
| O11 | VirtualBox の `snapshot take / restore / delete` の挙動 | VirtualBox 7.1 のユーザーガイド「Taking, Restoring, and Deleting Snapshots」の原文(ユーザーが 2026-11-03 にブラウザで読んで貼り付け)。ローカルの VirtualBox マネージャーでの確認(ユーザー) | 確認 | restore: 「The current state of the machine is lost, and the machine is restored to the exact state it was in when the snapshot was taken.」、仮想ハードディスクも元に戻るため、スナップショットの後に作ったファイルとファイルの変更は失われる。「To avoid losing the current state when restoring a snapshot, you can create a new snapshot before the restore operation.」。delete: VM の状態には影響せず、ディスクを解放する。実行中の VM でも削除できるが、時間がかかる場合があり、VM の停止中に行う必要がある場合もある。take: 実行中の VM は取得中に一時停止する。各スナップショットはディスク容量を使う。ローカルで、復元を選ぶと「現在の状態が失われる」との警告が出ることも確認(ユーザー、実行せずキャンセル)。restore が電源オフを要するかは、貼られた範囲に記述なし |

## 実機・ローカルでの確認(2026-11-03、Claude Code。読み取りのみ)
| # | 内容 | 方法 | 判定 | 要点 |
|---|---|---|---|---|
| L1 | VirtualBox 7.1.10 の `modifyvm` の NAT のポートフォワードの表記 | `VBoxManage.exe modifyvm`(引数なしの usage) | 確認 | `[--nat-pfN= [rule-name],tcp \| udp,[host-IP],hostport,[guest-IP],guestport] [--nat-pfN=delete=rule-name]`。記事で使った旧表記 `--natpf1`(`... delete ssh`)は usage に出ない。`--natpf1` の追加が通ったのは実測(e2b-4)。`delete` の旧表記が通るかは、未確認(未実行) |
| L2 | 起動中の VM のポートフォワード | `VBoxManage.exe controlvm`(usage) | 確認 | `VBoxManage controlvm <uuid \| vmname> natpfN` と `natpfNdelete <rulename>` がある(構文の実行は、未確認) |
| L3 | スナップショットのコマンド | `VBoxManage.exe snapshot`(usage) | 確認(構文のみ) | `take <name> [--description] [--live] [--uniquename …]`、`delete <name>`、`restore <name>`、`restorecurrent` がある。restore や delete の動作の説明は、usage にはない(O11 のまま未確認) |
| L4 | `ssh-copy-id` の動作 | WSL 側の `man ssh-copy-id`(版は未確認。AlmaLinux 9.8 の OpenSSH 9.9p1 のものではない) | 確認 | 「By default it adds the keys by appending them to the remote user's ~/.ssh/authorized_keys (creating the file, and directory, if necessary).」。すでに入っている鍵を、ログインを試して除く、という説明もある |
| L5 | `hostnamectl` の man | WSL 側の `man hostnamectl` | 取得できず | WSL に man のページがなく、確認できなかった |

## ユーザー判断(2026-11-03)
O11(snapshot)以外の未確認の項目(「同じ名前の内部ネットワーク」の文言、`hostnamectl set-hostname ""`、OpenSSH 9.9p1 との差、`explicit` の意味、旧表記 `--natpf1 delete` と `controlvm natpf` の動作確認、VM の `ssh-copy-id` の版)は、確認しない。記事からは、該当する記述を外した(E1、E2b、E4)。

## 取得できなかった・照合していないもの
- VirtualBox 7.1 の `snapshot` の節、`controlvm natpf` の構文、`clonevm` の記述(ページの後半が、取得範囲の外)。
- AlmaLinux 9.8 の OpenSSH 9.9p1 のパッケージ固有の差。
- AlmaLinux 9.8(OpenSSH 9.9p1)の `ssh-copy-id` のマニュアル(L4 は WSL 側の版)。
