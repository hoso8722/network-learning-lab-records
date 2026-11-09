# 全VMの時刻補正を、ホストの PowerShell からまとめて実行する
#
# 対象ノード : Windows ホスト（PowerShell）から、NAT のポートフォワード経由で client / server / switch / router の各 VM
# 実行権限   : 一般ユーザー
# 目的       : 実験の前に、各VMの sync-time.sh を実行し、ホストと VM の時刻を見比べる
# 状態変更   : 各VMのシステム時計を補正する（sync-time.sh による）。ホストの設定は変更しない。
# 前提       : 各VMが起動していて NAT が有効。各VMのホームに sync-time.sh がある。
#              パスワードは対話入力（SSH 用と sudo 用の2回/台）。スクリプトにパスワードを書かない。
# 使い方     : .\sync-all.ps1                    # 4台すべて
#              .\sync-all.ps1 -Only client,router  # 一部
# 安全装置   : 各VMで「ホスト名が想定と一致するか」を先に確認し、違えば何もせずに終了する（誤ったポートへの接続を防ぐ）。
# 判定       : このスクリプトは合否を判定しない。出力される host_utc と、VM側の date_utc の行を目で比べる。

param(
    [string[]]$Only = @(),
    [string]$User = "user"
)

# powershell -File で起動すると、-Only a,b,c は1つの文字列として渡される。カンマで分割して配列にする
$Only = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ })

$vms = [ordered]@{ client = 2222; server = 2223; switch = 2224; router = 2225; router2 = 2226 }
$done = 0

foreach ($name in $vms.Keys) {
    if ($Only.Count -gt 0 -and $Only -notcontains $name) { continue }
    $done++
    $port = $vms[$name]
    Write-Host ""
    Write-Host "=== $name (port $port) ==="
    Write-Host ("host_utc_before: " + (Get-Date).ToUniversalTime().ToString("o"))
    # 二重引用符を使わない（Windows PowerShell 5.1 は外部コマンドの引数内の二重引用符を崩すため）
    $remote = '[ $(hostname -s) = __NAME__ ] || { echo host-mismatch: $(hostname -s); exit 4; }; ./sync-time.sh'.Replace('__NAME__', $name)
    & ssh -t -p $port "${User}@127.0.0.1" $remote
    Write-Host ("ssh_exit: " + $LASTEXITCODE + "   (4 = ホスト名の不一致)")
    Write-Host ("host_utc_after:  " + (Get-Date).ToUniversalTime().ToString("o"))
}

Write-Host ""
if ($done -eq 0) { Write-Host ("警告: 対象のVMがありません。-Only の名前を確認してください（利用可能: " + ($vms.Keys -join ", ") + "）。") }
Write-Host "完了。各VMの『補正後』の date_utc と、host_utc_after を比べてください（数秒以内が目安）。"
