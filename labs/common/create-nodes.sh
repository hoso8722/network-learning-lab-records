#!/usr/bin/env bash
# common-ready のスナップショットから、router / router2 / switch の VM をクローンして、VM ごとの設定を済ませる
#
# 対象ノード : WSL2 のシェル(一般ユーザー)から、VirtualBox の VM(Alma9mini-router / -router2 / -switch)と、その VM への SSH
# 実行権限   : 一般ユーザー(VM 側の sudo は、パスワードを対話で入力する。このスクリプトはパスワードを扱わない)
# 状態変更   : あり。
#   (1) VirtualBox に VM を 3 台、新しく作る(クローン元 Alma9mini-cli は変更しない)。
#   (2) 新しい VM の NAT ポートフォワード(127.0.0.1 のみ)と、内部ネットワークの NIC を設定する。
#   (3) 新しい VM の中で、ホスト名の設定とホスト鍵の再生成を行う(sudo)。
#   (4) WSL 側の ~/.ssh/known_hosts を更新する(該当ポートの項目の削除と追加。~/.ssh/known_hosts.old に退避される)。
#   (5) 新しい VM を停止し、スナップショット node-ready を取る。
# 前提       : ・クローン元の VM(既定 Alma9mini-cli)に、スナップショット common-ready があること。
#              ・ssh-agent に、VM の user へ入れる鍵が登録済みであること(ssh-add -l で確認)。登録がなければ中断する。
#              ・VM に入る一般ユーザー(既定 user)が sudo を使えること。
#              ・内部ネットワークは、ホスト LAN・インターネットに接続されない(VirtualBox の intnet)。外部へのブリッジは作らない。
# 復旧       : 作った VM を消すには、VBoxManage unregistervm "<VM名>" --delete(ディスクも削除。元に戻せない)。
#              スナップショットの削除は VBoxManage snapshot "<VM名>" delete node-ready。
#              known_hosts は ~/.ssh/known_hosts.old に直前の状態がある(実行ごとに上書きされるので、実行前に自分でも控えること)。
# 使い方     :
#   labs/common/create-nodes.sh --dry-run            # 実行内容を表示するだけ(VM は変更しない)
#   labs/common/create-nodes.sh                       # 3 台を作る(最初に確認の入力あり)
#   labs/common/create-nodes.sh router router2        # 対象を指定して作る
#   環境変数 SRC_VM, SRC_SNAP, SNAP_NAME, VM_USER, VBOXMANAGE で、既定値を変えられる。
# 注意       : switch は NAT の 1 枚だけで作る。ラボ側の NIC は、この VM を使う記事で決まってから足す(ここでは決めない)。

set -u

SRC_VM="${SRC_VM:-Alma9mini-cli}"
SRC_SNAP="${SRC_SNAP:-common-ready}"
SNAP_NAME="${SNAP_NAME:-node-ready}"
VM_USER="${VM_USER:-user}"
VBOXMANAGE="${VBOXMANAGE:-/mnt/c/Program Files/Oracle/VirtualBox/VBoxManage.exe}"
WAIT_SSH_SEC=180
WAIT_OFF_SEC=120

DRY=0
NODES=()
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    router|router2|switch) NODES+=("$a") ;;
    *) echo "不明な引数: $a(使えるのは --dry-run, router, router2, switch)"; exit 1 ;;
  esac
done
[ ${#NODES[@]} -eq 0 ] && NODES=(router router2 switch)

vb() { "$VBOXMANAGE" "$@" | tr -d '\r'; }

# ノードごとの設定: ポート、NIC2 の内部ネットワーク、NIC3 の内部ネットワーク(空なら none のまま)
node_cfg() {
  case "$1" in
    router)  PORT=2225; NIC2=lan-a;   NIC3=transit ;;
    router2) PORT=2226; NIC2=transit; NIC3=lan-b ;;
    switch)  PORT=2224; NIC2="";      NIC3="" ;;
  esac
}

run() { # 状態を変えるコマンド。--dry-run では表示だけ
  if [ "$DRY" -eq 1 ]; then echo "[dry-run] $*"; return 0; fi
  echo "+ $*"; "$@"
}

die() { echo "中断: $*" >&2; exit 1; }

[ -x "$VBOXMANAGE" ] || die "VBoxManage.exe が見つかりません: $VBOXMANAGE"

# --- 事前確認(読み取りのみ) ---
vms="$(vb list vms)"
echo "$vms" | grep -q "^\"$SRC_VM\" " || die "クローン元 $SRC_VM が登録されていません"
vb snapshot "$SRC_VM" list --machinereadable 2>/dev/null | grep -q "=\"$SRC_SNAP\"" \
  || die "$SRC_VM にスナップショット $SRC_SNAP がありません"
for n in "${NODES[@]}"; do
  node_cfg "$n"
  echo "$vms" | grep -q "^\"Alma9mini-$n\" " && die "Alma9mini-$n は既に存在します(上書きしません)"
  # 他の VM が同じポートを使っていないか(登録済み VM すべての Forwarding を確認)
  while read -r name; do
    vb showvminfo "$name" --machinereadable | grep -q "^Forwarding.*,127.0.0.1,$PORT," \
      && die "ポート $PORT は VM $name が使っています"
  done < <(echo "$vms" | sed -E 's/^"([^"]+)".*/\1/')
done
if [ "$DRY" -eq 0 ]; then
  ssh-add -l >/dev/null 2>&1 || die "ssh-agent に鍵が登録されていません(ssh-add -l が失敗)。鍵を登録してから再実行してください"
fi

echo "作成する VM: ${NODES[*]}(クローン元 $SRC_VM のスナップショット $SRC_SNAP から)"
if [ "$DRY" -eq 0 ]; then
  read -r -p "続けますか? (yes/no) " ans
  [ "$ans" = "yes" ] || die "ユーザーが中止しました"
fi

wait_state() { # $1=VM 名 $2=期待する VMState $3=最大秒数
  local i=0
  while [ $i -lt "$3" ]; do
    vb showvminfo "$1" --machinereadable | grep -q "^VMState=\"$2\"" && return 0
    sleep 2; i=$((i + 2))
  done
  return 1
}

for n in "${NODES[@]}"; do
  node_cfg "$n"
  VM="Alma9mini-$n"
  echo "=== $VM(ポート $PORT) ==="

  run "$VBOXMANAGE" clonevm "$SRC_VM" --snapshot "$SRC_SNAP" --name "$VM" --register || die "クローンに失敗: $VM"
  # クローンは cli の NAT ポートフォワード(ssh, 2222)を引き継ぐ。起動の前に付け替える
  run "$VBOXMANAGE" modifyvm "$VM" --natpf1 delete ssh || die "ポートフォワードの削除に失敗: $VM"
  run "$VBOXMANAGE" modifyvm "$VM" --natpf1 "ssh,tcp,127.0.0.1,$PORT,,22" || die "ポートフォワードの追加に失敗: $VM"
  if [ -n "$NIC2" ]; then
    run "$VBOXMANAGE" modifyvm "$VM" --nic2 intnet --intnet2 "$NIC2" --nictype2 82540EM || die "NIC2 の設定に失敗: $VM"
  fi
  if [ -n "$NIC3" ]; then
    run "$VBOXMANAGE" modifyvm "$VM" --nic3 intnet --intnet3 "$NIC3" --nictype3 82540EM || die "NIC3 の設定に失敗: $VM"
  fi

  run "$VBOXMANAGE" startvm "$VM" --type headless || die "起動に失敗: $VM"

  if [ "$DRY" -eq 1 ]; then
    echo "[dry-run] ssh-keygen -R \"[127.0.0.1]:$PORT\""
    echo "[dry-run] SSH で起動を待つ → ssh -t -p $PORT $VM_USER@127.0.0.1 sudo (hostnamectl set-hostname $n; ホスト鍵の再生成; sshd の再起動)"
    echo "[dry-run] ssh-keyscan の fingerprint と VM が表示した fingerprint を照合して、known_hosts に追加"
    echo "[dry-run] acpipowerbutton → 停止待ち → snapshot take $SNAP_NAME"
    continue
  fi

  # 引き継いだ(cli と同じ)ホスト鍵の項目が残っていれば消す。ここでは、まだ信頼の確認をしない
  ssh-keygen -R "[127.0.0.1]:$PORT" >/dev/null 2>&1

  # sshd の起動待ち。ホスト鍵は未確認なので、known_hosts を使わず(/dev/null)、接続できるかだけを見る
  i=0
  until ssh -p "$PORT" -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$VM_USER@127.0.0.1" true 2>/dev/null; do
    i=$((i + 3)); [ $i -ge $WAIT_SSH_SEC ] && die "$VM に SSH できません(${WAIT_SSH_SEC}秒)。VM は起動したままです"
    sleep 3
  done

  # 再生成の前のホスト鍵(クローン元と同じはず)。再生成されたかの比較に使う。ssh-keyscan で読み取るだけ
  SRC_FP="$(ssh-keyscan -p "$PORT" -t ed25519 127.0.0.1 2>/dev/null | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
  [ -n "$SRC_FP" ] || die "$VM の再生成前のホスト鍵を読み取れません(VM は起動したまま)"

  # ホスト名とホスト鍵(破壊的: この VM の /etc/ssh/ssh_host_* だけ)。sudo のパスワードは対話で入力する。
  # パイプにつなぐと sudo のパスワードの案内が画面に出なくなるため、ssh -t は出力をつながずに実行する
  echo "この後 [sudo] password for $VM_USER: が表示されます。VM の $VM_USER のパスワードを入力してください"
  ssh -t -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      "$VM_USER@127.0.0.1" \
      "sudo bash -c 'hostnamectl set-hostname $n && rm -f /etc/ssh/ssh_host_* && ssh-keygen -A >/dev/null && systemctl restart sshd'" \
      || die "$VM のホスト名・ホスト鍵の設定に失敗しました(VM は起動したまま)"
  sleep 3
  # 公開鍵の fingerprint は一般ユーザーで読める。再生成されたか(cli の値と違うか)を確認する
  fp="$(ssh -p "$PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
        "$VM_USER@127.0.0.1" 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' 2>/dev/null | awk '{print $2}')"
  [ -n "$fp" ] || die "$VM のホスト鍵の fingerprint を取得できません(VM は起動したまま)"
  [ "$fp" != "$SRC_FP" ] || die "$VM のホスト鍵が再生成の前と同じままです(再生成されていません)"
  echo "VM が表示した新しい fingerprint: $fp"

  # 実際に接続する先の鍵が、VM の表示と一致するときだけ known_hosts に追加する
  sleep 2
  scan="$(ssh-keyscan -p "$PORT" -t ed25519 127.0.0.1 2>/dev/null)"
  scan_fp="$(echo "$scan" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
  if [ "$scan_fp" = "$fp" ]; then
    ssh-keygen -R "[127.0.0.1]:$PORT" >/dev/null 2>&1
    echo "$scan" | sed "s/^127.0.0.1 /[127.0.0.1]:$PORT /" >> "$HOME/.ssh/known_hosts"
    echo "known_hosts に追加しました(fingerprint 一致)"
  else
    die "fingerprint が一致しません(VM: $fp / スキャン: $scan_fp)。known_hosts には追加していません"
  fi

  # 停止してスナップショット
  run "$VBOXMANAGE" controlvm "$VM" acpipowerbutton
  wait_state "$VM" poweroff "$WAIT_OFF_SEC" || die "$VM が ${WAIT_OFF_SEC}秒以内に停止しません。スナップショットは取っていません"
  run "$VBOXMANAGE" snapshot "$VM" take "$SNAP_NAME" --description "$n: hostname, host key, ports and NICs set; before baseline.sh up"
done

echo "完了: ${NODES[*]}"
if [ "$DRY" -eq 0 ]; then
  vb list vms
fi
