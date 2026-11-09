# VM へのスクリプト送信（push）と、実験結果の回収（pull）を、ホストの PowerShell からまとめて行う
#
# 対象ノード : Windows ホスト（PowerShell）から、NAT のポートフォワード経由で client / server / switch / router の各 VM
# 実行権限   : 一般ユーザー
# 状態変更   : push = 各VMのホームにスクリプトを置く（同名なら上書き）と実行権限を付ける。pull = ホスト側のフォルダーにファイルを作る。
#              VM の設定は変えない。
# パスワード : 対話入力（scp 用と ssh 用、台ごとに最大2回）。スクリプトにパスワードを書かない。
#
# 使い方:
#   送信: .\transfer.ps1 -Mode push -ExpDir exp-router-on-a-stick -Files router-test.sh -IncludeSync
#   回収: .\transfer.ps1 -Mode pull -ExpDir exp-router-on-a-stick -Pattern "exp3-*"
#   一部のVMだけ: -Only router,switch
#
# push : data\<ExpDir>\<Files> を各VMの ~/ に送る。-IncludeSync で labs\common\sync-time.sh も送る。
# pull : 各VMの ~/<Pattern> を、data\<ExpDir>\from-<VM名>\ に回収する（VMごとにフォルダーを分けるので、同名ファイルが混ざらない）。
#
# 注意: 誤ったポートに送らないよう、push 後に各VMのホスト名を表示する（表示された名前が VM名と一致するか目で確認する）。
#       pull は、回収先がVMごとに分かれるため、誤実行ファイルは該当VMのフォルダーに留まる。

param(
    [Parameter(Mandatory = $true)][ValidateSet("push", "pull")][string]$Mode,
    [string]$ExpDir = "exp-router-on-a-stick",
    [string[]]$Files = @("router-test.sh"),
    [string]$Pattern = "exp3-*",
    [string[]]$Only = @(),
    [string]$User = "user",
    [switch]$IncludeSync
)

# powershell -File で起動すると、-Only a,b,c は1つの文字列として渡される。カンマで分割して配列にする
$Only = @($Only | ForEach-Object { $_ -split "," } | Where-Object { $_ })

$vms  = [ordered]@{ client = 2222; server = 2223; switch = 2224; router = 2225; router2 = 2226 }
$done = 0
# UNC の場合、.Path は "Microsoft.PowerShell.Core\FileSystem::" 付きで返り、scp がコロンをホスト指定と解釈して失敗する。.ProviderPath を使う
$root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).ProviderPath
$dataDir = Join-Path $root ("data\" + $ExpDir)
if (-not (Test-Path $dataDir)) { Write-Host "データディレクトリが見つかりません: $dataDir"; exit 1 }

foreach ($name in $vms.Keys) {
    if ($Only.Count -gt 0 -and $Only -notcontains $name) { continue }
    $done++
    $port = $vms[$name]
    Write-Host ""
    Write-Host "=== $name (port $port) : $Mode ==="
    if ($Mode -eq "push") {
        $src = @()
        foreach ($f in $Files) { $src += (Join-Path $dataDir $f) }
        if ($IncludeSync) { $src += (Join-Path $root "labs\common\sync-time.sh") }
        $missing = $src | Where-Object { -not (Test-Path $_) }
        if ($missing) { Write-Host "ファイルが見つかりません: $missing"; continue }
        & scp -P $port @src "${User}@127.0.0.1:~/"
        Write-Host ("scp_exit: " + $LASTEXITCODE)
        if ($LASTEXITCODE -ne 0) { Write-Host "失敗: $name への転送に失敗しました。ファイルは更新されていません（次の手順は実行しません）。"; continue }
        # 実行権限を付け、ホスト名を表示（二重引用符を使わない: Windows PowerShell 5.1 の引数処理のため）
        $names = ($src | ForEach-Object { '~/' + (Split-Path $_ -Leaf) }) -join ' '
        & ssh -p $port "${User}@127.0.0.1" ("chmod +x " + $names + '; echo remote_host=$(hostname -s)')
        Write-Host ("ssh_exit: " + $LASTEXITCODE + "   （上の remote_host が '$name' と一致するか確認）")
    }
    else {
        $dest = Join-Path $dataDir ("from-" + $name)
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        & scp -P $port ("${User}@127.0.0.1:~/" + $Pattern) $dest
        Write-Host ("scp_exit: " + $LASTEXITCODE + "   回収先: " + $dest)
    }
}
Write-Host ""
if ($done -eq 0) { Write-Host ("警告: 対象のVMがありません。-Only の名前を確認してください（利用可能: " + ($vms.Keys -join ", ") + "）。") }
Write-Host "完了。"
